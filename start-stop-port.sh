#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================
#
# PANEL DE CONTROL COMPATIBLE CON LOS SCRIPTS ACTUALES:
#
#   install.sh
#   uninstall.sh
#   add-port.sh
#   change-port.sh
#   delete-port.sh
#   optimize.sh
#
# COMPATIBILIDAD:
#
#   hcr-server-80.service
#   hcr-server-443.service
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#   etc.
#
# DIRECTORIO PRINCIPAL:
#
#   /root/.hcr-panel
#
# IMPORTANTE:
#
#   install.sh se ejecuta SIEMPRE desde INSTALL_DIR.
#   Esto garantiza que:
#
#       install.sh
#       hcr-server
#       fullchain.pem
#       privkey.pem
#
#   permanezcan en el mismo directorio.
#
# ============================================================

set +e

# ============================================================
# CONFIGURACIÓN
# ============================================================

BASE_URL="https://raw.githubusercontent.com/ChristopherAGT/hcr-server/main"

INSTALL_DIR="/root/.hcr-panel"
TEMP_DIR="${INSTALL_DIR}/.tmp"

INSTALL_SCRIPT="${INSTALL_DIR}/install.sh"
BINARY_PATH="${INSTALL_DIR}/hcr-server"
CERT_PATH="${INSTALL_DIR}/fullchain.pem"
KEY_PATH="${INSTALL_DIR}/privkey.pem"

UNINSTALL_SCRIPT="${TEMP_DIR}/uninstall.sh"
ADD_PORT_SCRIPT="${TEMP_DIR}/add-port.sh"
CHANGE_PORT_SCRIPT="${TEMP_DIR}/change-port.sh"
DELETE_PORT_SCRIPT="${TEMP_DIR}/delete-port.sh"
OPTIMIZE_SCRIPT="${TEMP_DIR}/optimize.sh"

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PREFIX="hcr-server"

SPINNER_PID=""

SELECTED_UNIT=""
SELECTED_PATH=""
SELECTED_PORT=""

# ============================================================
# COLORES
# ============================================================

RESET='\033[0m'
BOLD='\033[1m'

CYAN='\033[38;5;51m'
BLUE='\033[38;5;75m'
GREEN='\033[38;5;82m'
YELLOW='\033[38;5;220m'
RED='\033[38;5;203m'
MAGENTA='\033[38;5;213m'
WHITE='\033[38;5;255m'
GRAY='\033[38;5;245m'
DARK='\033[38;5;240m'

# ============================================================
# UTILIDADES VISUALES
# ============================================================

clear_screen() {
    printf '\033[2J\033[H'
}

pause() {
    echo
    read -r -p "  Presiona ENTER para continuar..." _
}

success() {
    printf "  %b✔%b %s\n" "${GREEN}" "${RESET}" "$1"
}

error() {
    printf "  %b✖%b %s\n" "${RED}" "${RESET}" "$1"
}

warning() {
    printf "  %b⚠%b %s\n" "${YELLOW}" "${RESET}" "$1"
}

info() {
    printf "  %b●%b %s\n" "${CYAN}" "${RESET}" "$1"
}

detail() {
    printf "      %b•%b %s\n" "${GRAY}" "${RESET}" "$1"
}

line() {
    printf "  %b────────────────────────────────────────────────────────%b\n" \
        "${DARK}" "${RESET}"
}

section() {
    echo
    printf "  %b◆ %s%b\n" "${CYAN}${BOLD}" "$1" "${RESET}"
    line
}

# ============================================================
# ROOT
# ============================================================

require_root() {

    if [[ "${EUID}" -ne 0 ]]; then
        error "Este panel debe ejecutarse como root."
        exit 1
    fi
}

# ============================================================
# DIRECTORIOS
# ============================================================

prepare_install_dir() {

    mkdir -p -- "$INSTALL_DIR"
    mkdir -p -- "$TEMP_DIR"

    chown root:root "$INSTALL_DIR" "$TEMP_DIR"

    chmod 700 "$INSTALL_DIR"
    chmod 700 "$TEMP_DIR"
}

# ============================================================
# LIMPIEZA DE TEMPORALES DEL PANEL
# ============================================================

cleanup_temp_scripts() {

    rm -f \
        "$UNINSTALL_SCRIPT" \
        "$ADD_PORT_SCRIPT" \
        "$CHANGE_PORT_SCRIPT" \
        "$DELETE_PORT_SCRIPT" \
        "$OPTIMIZE_SCRIPT" \
        2>/dev/null || true
}

# ============================================================
# SPINNER
# ============================================================

spinner_start() {

    local message="${1:-Procesando}"

    if [[ -n "${SPINNER_PID:-}" ]]; then

        if kill -0 "${SPINNER_PID}" >/dev/null 2>&1; then
            return 0
        fi

        SPINNER_PID=""
    fi

    (
        trap 'exit 0' TERM INT HUP

        local frames=(
            "⠋"
            "⠙"
            "⠹"
            "⠸"
            "⠼"
            "⠴"
            "⠦"
            "⠧"
            "⠇"
            "⠏"
        )

        local i=0

        while true; do

            printf "\r\033[K  %b%s%b %s" \
                "${CYAN}" \
                "${frames[$i]}" \
                "${RESET}" \
                "$message"

            i=$(( (i + 1) % ${#frames[@]} ))

            sleep 0.08
        done

    ) &

    SPINNER_PID=$!
}

spinner_stop() {

    local pid="${SPINNER_PID:-}"

    SPINNER_PID=""

    if [[ -n "$pid" ]]; then

        kill -TERM "$pid" >/dev/null 2>&1 || true

        wait "$pid" >/dev/null 2>&1 || true
    fi

    printf "\r\033[K"
}

# ============================================================
# DESCARGA SEGURA
# ============================================================

download_file() {

    local url="$1"
    local destination="$2"

    local temporary="${destination}.download"

    rm -f -- "$temporary"

    if ! curl \
        -fL \
        --retry 3 \
        --retry-delay 1 \
        --connect-timeout 15 \
        --max-time 180 \
        -sS \
        "$url" \
        -o "$temporary"; then

        rm -f -- "$temporary"

        return 1
    fi

    if [[ ! -f "$temporary" || ! -s "$temporary" ]]; then

        rm -f -- "$temporary"

        return 1
    fi

    chown root:root "$temporary"

    chmod 700 "$temporary"

    mv -f -- "$temporary" "$destination"

    return 0
}

# ============================================================
# DESCARGAR SCRIPT REMOTO
# ============================================================

download_script() {

    local name="$1"
    local url="$2"
    local destination="$3"

    prepare_install_dir

    spinner_start "Descargando ${name}..."

    if download_file "$url" "$destination"; then

        spinner_stop

        chmod 700 "$destination"
        chown root:root "$destination"

        success "${name} descargado correctamente."

        return 0
    fi

    spinner_stop

    error "No se pudo descargar ${name}."

    return 1
}

# ============================================================
# EJECUTAR SCRIPT REMOTO
# ============================================================

run_remote_script() {

    local name="$1"
    local url="$2"
    local destination="$3"

    if ! download_script "$name" "$url" "$destination"; then
        return 1
    fi

    echo

    bash "$destination"

    local result=$?

    rm -f -- "$destination"

    return "$result"
}

# ============================================================
# OBTENER UNIDADES HCR
# ============================================================

get_hcr_units() {

    {
        systemctl list-unit-files \
            --type=service \
            --no-legend \
            --no-pager \
            2>/dev/null |
            awk '{print $1}' |
            grep -E '^hcr-server-[0-9]+\.service$' ||
            true

        find "$SYSTEMD_DIR" \
            -maxdepth 1 \
            \( -type f -o -type l \) \
            -name 'hcr-server-[0-9]*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

        find "$INSTALL_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'hcr-server-[0-9]*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

    } |
        sort -Vu
}

# ============================================================
# CONTAR INSTANCIAS
# ============================================================

count_hcr_instances() {

    local count

    count="$(
        get_hcr_units |
            grep -E '^hcr-server-[0-9]+\.service$' |
            wc -l |
            tr -d ' '
    )"

    echo "${count:-0}"
}

# ============================================================
# HCR INSTALADO
# ============================================================

hcr_is_installed() {

    local count

    count="$(count_hcr_instances)"

    [[ "$count" =~ ^[0-9]+$ ]] &&
        (( count > 0 ))
}

# ============================================================
# RUTA DE UNIDAD
# ============================================================

get_unit_path() {

    local unit="$1"
    local path=""

    path="$(
        systemctl show \
            --property=FragmentPath \
            --value \
            "$unit" \
            2>/dev/null ||
            true
    )"

    if [[ -n "$path" &&
          "$path" != "n/a" &&
          -f "$path" ]]; then

        echo "$path"
        return 0
    fi

    if [[ -f "${SYSTEMD_DIR}/${unit}" ]]; then

        echo "${SYSTEMD_DIR}/${unit}"
        return 0
    fi

    if [[ -f "${INSTALL_DIR}/${unit}" ]]; then

        echo "${INSTALL_DIR}/${unit}"
        return 0
    fi

    echo ""
}

# ============================================================
# OBTENER PUERTO HCR
# ============================================================

get_unit_listen_port() {

    local unit="$1"
    local path="$2"

    [[ -n "$path" && -f "$path" ]] || return 0

    sed -n \
        -E \
        's/.*--listen[[:space:]]+:([0-9]+).*/\1/p' \
        "$path" |
        head -n1
}

# ============================================================
# OBTENER PUERTO DESTINO
# ============================================================

get_unit_target_port() {

    local unit="$1"
    local path="$2"

    [[ -n "$path" && -f "$path" ]] || return 0

    sed -n \
        -E \
        's/.*--target[[:space:]]+127\.0\.0\.1:([0-9]+).*/\1/p' \
        "$path" |
        head -n1
}

# ============================================================
# OBTENER TRANSPORTE
# ============================================================

get_unit_transport() {

    local path="$1"

    [[ -n "$path" && -f "$path" ]] || {
        echo "---"
        return
    }

    sed -n \
        -E \
        's/.*--transport[[:space:]]+([^[:space:]]+).*/\1/p' \
        "$path" |
        head -n1
}

# ============================================================
# OBTENER FRAME
# ============================================================

get_unit_frame() {

    local path="$1"

    [[ -n "$path" && -f "$path" ]] || {
        echo "---"
        return
    }

    sed -n \
        -E \
        's/.*--max-download-frame[[:space:]]+([0-9]+).*/\1/p' \
        "$path" |
        head -n1
}

# ============================================================
# OBTENER TIMEOUT
# ============================================================

get_unit_timeout() {

    local path="$1"

    [[ -n "$path" && -f "$path" ]] || {
        echo "---"
        return
    }

    sed -n \
        -E \
        's/.*--download-poll-timeout[[:space:]]+([^[:space:]]+).*/\1/p' \
        "$path" |
        head -n1
}

# ============================================================
# ESTADO SYSTEMD
# ============================================================

get_unit_state() {

    local unit="$1"

    systemctl is-active "$unit" 2>/dev/null || true
}

# ============================================================
# COMPROBAR PUERTO ESCUCHANDO
# ============================================================

is_port_listening() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    ss -H -lnt 2>/dev/null |
        awk -v port="$port" '
            {
                address=$4

                sub(/^.*:/, "", address)

                if (address == port) {
                    found=1
                    exit
                }
            }

            END {
                if (found)
                    exit 0

                exit 1
            }
        '
}

# ============================================================
# ESTADO REAL
# ============================================================

get_port_state() {

    local unit="$1"
    local path="$2"

    local systemd_state
    local port

    systemd_state="$(get_unit_state "$unit")"

    port="$(get_unit_listen_port "$unit" "$path")"

    if [[ "$systemd_state" == "active" ]]; then

        if is_port_listening "$port"; then
            echo "ACTIVO"
        else
            echo "SIN ESCUCHA"
        fi

    elif [[ "$systemd_state" == "failed" ]]; then

        echo "ERROR"

    else

        echo "DETENIDO"
    fi
}

# ============================================================
# OBTENER PUERTOS
# ============================================================

get_hcr_ports() {

    local unit
    local path
    local port

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        path="$(get_unit_path "$unit")"

        port="$(get_unit_listen_port "$unit" "$path")"

        [[ -n "$port" ]] || continue

        echo "$port"

    done < <(get_hcr_units) |
        sort -n -u
}

# ============================================================
# HEADER
# ============================================================

header() {

    clear_screen

    local count
    local installed
    local ports
    local port_line

    count="$(count_hcr_instances)"

    if hcr_is_installed; then
        installed="${GREEN}Instalado${RESET} 🟢"
    else
        installed="${RED}No instalado${RESET} 🔴"
    fi

    ports="$(get_hcr_ports | paste -sd ',' -)"

    if [[ -z "$ports" ]]; then
        port_line="${GRAY}---${RESET}"
    else
        port_line="${WHITE}${ports}${RESET}"
    fi

    echo
    printf "%b\n" \
        "${CYAN}    ╭────────────────────────────────────────────────────────╮${RESET}"
    printf "%b\n" \
        "${CYAN}    │                                                        │${RESET}"
    printf "%b\n" \
        "${CYAN}    │${BOLD}${WHITE}       H C R   S E R V E R${RESET}                              ${CYAN}│${RESET}"
    printf "%b\n" \
        "${CYAN}    │${GRAY}       Premium Control Panel${RESET}                            ${CYAN}│${RESET}"
    printf "%b\n" \
        "${CYAN}    │                                                        │${RESET}"
    printf "%b\n" \
        "${CYAN}    ├────────────────────────────────────────────────────────┤${RESET}"
    printf "%b\n" \
        "${CYAN}    │${RESET}  ${WHITE}HCR:${RESET} ${installed}                                      ${CYAN}│${RESET}"
    printf "%b\n" \
        "${CYAN}    │${RESET}  ${WHITE}Instancias:${RESET} ${GREEN}${count}${RESET}                                ${CYAN}│${RESET}"
    printf "%b\n" \
        "${CYAN}    │${RESET}  ${WHITE}Puertos:${RESET} ${port_line}                              ${CYAN}│${RESET}"
    printf "%b\n" \
        "${CYAN}    ╰────────────────────────────────────────────────────────╯${RESET}"
    echo
}

# ============================================================
# TABLA DE INSTANCIAS
# ============================================================

show_instances() {

    local units

    units="$(get_hcr_units)"

    echo -e "  ${BOLD}${WHITE}INSTANCIAS HCR SERVER${RESET}"
    echo

    if [[ -z "$units" ]]; then

        warning "No se detectaron instancias HCR Server."
        return 1
    fi

    printf "  ${GRAY}%-4s %-12s %-14s %-16s %-10s %-10s %-10s${RESET}\n" \
        "#" \
        "PUERTO" \
        "DESTINO" \
        "ESTADO" \
        "FRAME" \
        "TIMEOUT" \
        "TRANSP."

    line

    local index=0
    local unit
    local path
    local port
    local target
    local state
    local frame
    local timeout
    local transport
    local state_display

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        index=$((index + 1))

        path="$(get_unit_path "$unit")"

        port="$(get_unit_listen_port "$unit" "$path")"
        target="$(get_unit_target_port "$unit" "$path")"
        state="$(get_port_state "$unit" "$path")"
        frame="$(get_unit_frame "$path")"
        timeout="$(get_unit_timeout "$path")"
        transport="$(get_unit_transport "$path")"

        case "$state" in

            ACTIVO)
                state_display="${GREEN}ACTIVO${RESET}"
                ;;

            "SIN ESCUCHA")
                state_display="${YELLOW}SIN ESCUCHA${RESET}"
                ;;

            ERROR)
                state_display="${RED}ERROR${RESET}"
                ;;

            *)
                state_display="${GRAY}DETENIDO${RESET}"
                ;;

        esac

        printf "  ${CYAN}%-4s${RESET} ${WHITE}%-12s${RESET} ${WHITE}%-14s${RESET} %-16b ${WHITE}%-10s${RESET} ${WHITE}%-10s${RESET} ${WHITE}%-10s${RESET}\n" \
            "$index" \
            "${port:----}" \
            "${target:----}" \
            "$state_display" \
            "${frame:----}" \
            "${timeout:----}" \
            "${transport:----}"

    done <<< "$units"

    echo
    detail "ACTIVO = systemd activo y puerto realmente escuchando."
    detail "SIN ESCUCHA = systemd activo pero no se detectó listener."
}

# ============================================================
# SELECCIONAR INSTANCIA
# ============================================================

select_hcr_unit() {

    local title="${1:-Seleccionar instancia}"

    local units

    units="$(get_hcr_units)"

    if [[ -z "$units" ]]; then

        warning "No existen instancias HCR Server."
        return 1
    fi

    echo
    echo -e "  ${BOLD}${WHITE}${title}${RESET}"
    echo

    local index=0
    local unit
    local path
    local port
    local state
    local state_display

    declare -a UNIT_ARRAY=()

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        index=$((index + 1))

        UNIT_ARRAY[$index]="$unit"

        path="$(get_unit_path "$unit")"
        port="$(get_unit_listen_port "$unit" "$path")"
        state="$(get_port_state "$unit" "$path")"

        case "$state" in

            ACTIVO)
                state_display="${GREEN}ACTIVO${RESET}"
                ;;

            "SIN ESCUCHA")
                state_display="${YELLOW}SIN ESCUCHA${RESET}"
                ;;

            ERROR)
                state_display="${RED}ERROR${RESET}"
                ;;

            *)
                state_display="${GRAY}DETENIDO${RESET}"
                ;;

        esac

        printf "  ${CYAN}%02d${RESET}  ${WHITE}Puerto %-6s${RESET} ${GRAY}%s${RESET} %b\n" \
            "$index" \
            "${port:----}" \
            "(${unit})" \
            "$state_display"

    done <<< "$units"

    echo
    echo -e "  ${GRAY}00  Cancelar${RESET}"
    echo

    local option

    while true; do

        read -r -p "  Selecciona una instancia: " option

        if [[ "$option" == "0" || "$option" == "00" ]]; then
            return 1
        fi

        if [[ "$option" =~ ^[0-9]+$ ]] &&
            (( option >= 1 && option <= index )); then

            SELECTED_UNIT="${UNIT_ARRAY[$option]}"

            SELECTED_PATH="$(get_unit_path "$SELECTED_UNIT")"

            SELECTED_PORT="$(
                get_unit_listen_port \
                    "$SELECTED_UNIT" \
                    "$SELECTED_PATH"
            )"

            return 0
        fi

        error "Selección no válida."
    done
}

# ============================================================
# CERTIFICADOS
# ============================================================

prepare_certificates() {

    if [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]]; then

        info "Certificados TLS existentes detectados."

        return 0
    fi

    warning "No existen certificados TLS válidos."
    info "Generando certificado temporal para HCR Server..."

    rm -f \
        "$CERT_PATH" \
        "$KEY_PATH"

    if ! command -v openssl >/dev/null 2>&1; then

        error "OpenSSL no está instalado."

        return 1
    fi

    local temporary_key="${KEY_PATH}.tmp"
    local temporary_cert="${CERT_PATH}.tmp"

    rm -f \
        "$temporary_key" \
        "$temporary_cert"

    if ! openssl req \
        -x509 \
        -newkey rsa:2048 \
        -sha256 \
        -nodes \
        -days 3650 \
        -keyout "$temporary_key" \
        -out "$temporary_cert" \
        -subj "/CN=hcr-server-temporary" \
        >/dev/null 2>&1; then

        rm -f \
            "$temporary_key" \
            "$temporary_cert"

        error "No se pudo generar el certificado TLS."

        return 1
    fi

    chown root:root \
        "$temporary_key" \
        "$temporary_cert"

    chmod 600 "$temporary_key"
    chmod 644 "$temporary_cert"

    mv -f "$temporary_key" "$KEY_PATH"
    mv -f "$temporary_cert" "$CERT_PATH"

    success "Certificado TLS temporal generado."

    return 0
}

# ============================================================
# PREPARAR PAQUETE DEL INSTALADOR
# ============================================================
#
# IMPORTANTE:
#
# install.sh utiliza:
#
#   SCRIPT_DIR="$(dirname ...)"
#
# y espera encontrar:
#
#   ${SCRIPT_DIR}/hcr-server
#   ${SCRIPT_DIR}/fullchain.pem
#   ${SCRIPT_DIR}/privkey.pem
#
# Por eso NO se ejecuta desde .tmp.
#
# ============================================================

prepare_installation() {

    prepare_install_dir

    echo

    info "Preparando instalador oficial..."

    if ! download_file \
        "${BASE_URL}/install.sh" \
        "$INSTALL_SCRIPT"; then

        error "No se pudo descargar install.sh."

        return 1
    fi

    chmod 700 "$INSTALL_SCRIPT"
    chown root:root "$INSTALL_SCRIPT"

    success "install.sh preparado."

    echo

    info "Preparando binario HCR Server..."

    if ! download_file \
        "${BASE_URL}/hcr-server" \
        "$BINARY_PATH"; then

        error "No se pudo descargar el binario HCR Server."

        return 1
    fi

    chmod 700 "$BINARY_PATH"
    chown root:root "$BINARY_PATH"

    success "Binario HCR preparado."

    echo

    if ! prepare_certificates; then
        return 1
    fi

    echo

    if [[ ! -f "$INSTALL_SCRIPT" ]]; then
        error "Falta install.sh."
        return 1
    fi

    if [[ ! -f "$BINARY_PATH" ]]; then
        error "Falta el binario HCR."
        return 1
    fi

    if [[ ! -f "$CERT_PATH" ]]; then
        error "Falta el certificado TLS."
        return 1
    fi

    if [[ ! -f "$KEY_PATH" ]]; then
        error "Falta la clave TLS."
        return 1
    fi

    success "Paquete completo preparado."

    detail "Instalador: $INSTALL_SCRIPT"
    detail "Binario:    $BINARY_PATH"
    detail "Certificado: $CERT_PATH"
    detail "Clave:       $KEY_PATH"

    return 0
}

# ============================================================
# INSTALAR / REINSTALAR
# ============================================================

install_service() {

    header

    echo -e "  ${BOLD}${WHITE}INSTALAR / REINSTALAR HCR SERVER${RESET}"
    echo -e "  ${GRAY}Utiliza directamente el instalador oficial del repositorio.${RESET}"
    echo

    if ! prepare_installation; then

        echo

        error "No se pudo preparar la instalación."

        pause

        return
    fi

    echo

    info "Ejecutando install.sh desde:"
    detail "$INSTALL_DIR"

    echo

    cd "$INSTALL_DIR"

    bash "$INSTALL_SCRIPT"

    local result=$?

    echo

    if (( result == 0 )); then

        success "El instalador finalizó correctamente."

    else

        error "El instalador terminó con código ${result}."

    fi

    pause
}

# ============================================================
# DESINSTALAR
# ============================================================

uninstall_service() {

    header

    echo -e "  ${BOLD}${WHITE}DESINSTALAR HCR SERVER${RESET}"
    echo -e "  ${GRAY}Ejecuta el desinstalador oficial compatible con múltiples instancias.${RESET}"
    echo

    warning "El desinstalador eliminará las instancias HCR, el binario y certificados."
    detail "El directorio del panel será conservado."
    echo

    read -r -p "  ¿Deseas continuar? [s/N]: " answer

    case "${answer,,}" in

        s|si|sí|y|yes)
            ;;

        *)
            info "Operación cancelada."
            pause
            return
            ;;

    esac

    echo

    if run_remote_script \
        "desinstalador" \
        "${BASE_URL}/uninstall.sh" \
        "$UNINSTALL_SCRIPT"; then

        echo
        success "Desinstalación finalizada."

    else

        echo
        error "El desinstalador terminó con errores."

    fi

    pause
}

# ============================================================
# GESTIÓN DE PUERTOS
# ============================================================

port_management_menu() {

    while true; do

        header

        echo -e "  ${BOLD}${WHITE}GESTIÓN DE PUERTOS${RESET}"
        echo -e "  ${GRAY}Administración de las instancias HCR Server.${RESET}"
        echo

        show_instances

        echo

        echo -e "  ${CYAN}01${RESET}  ${MAGENTA}＋${RESET}  ${WHITE}Añadir puerto${RESET}"
        echo -e "      ${GRAY}Utiliza add-port.sh oficial.${RESET}"
        echo

        echo -e "  ${CYAN}02${RESET}  ${MAGENTA}■${RESET}  ${WHITE}Detener puerto${RESET}"
        echo -e "      ${GRAY}Detiene una instancia sin eliminarla.${RESET}"
        echo

        echo -e "  ${CYAN}03${RESET}  ${MAGENTA}✎${RESET}  ${WHITE}Modificar puerto${RESET}"
        echo -e "      ${GRAY}Adapta change-port.sh a la instancia seleccionada.${RESET}"
        echo

        echo -e "  ${CYAN}04${RESET}  ${MAGENTA}✖${RESET}  ${WHITE}Eliminar puerto${RESET}"
        echo -e "      ${GRAY}Utiliza delete-port.sh oficial.${RESET}"
        echo

        line

        echo
        echo -e "  ${GRAY}00${RESET}  ${WHITE}Volver${RESET}"
        echo

        echo -ne "  ${CYAN}HCR / PUERTOS ›${RESET} "

        read -r option

        case "$option" in

            1|01)
                add_port
                ;;

            2|02)
                stop_port
                ;;

            3|03)
                modify_port
                ;;

            4|04)
                delete_port
                ;;

            0|00)
                return
                ;;

            *)
                echo
                error "Opción no válida."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# AÑADIR PUERTO
# ============================================================

add_port() {

    header

    echo -e "  ${BOLD}${WHITE}AÑADIR PUERTO${RESET}"
    echo -e "  ${GRAY}Ejecutando el add-port.sh oficial.${RESET}"
    echo

    if run_remote_script \
        "gestor de nuevos puertos" \
        "${BASE_URL}/add-port.sh" \
        "$ADD_PORT_SCRIPT"; then

        echo
        success "La operación de añadir puerto terminó correctamente."

    else

        echo
        error "add-port.sh terminó con errores."

    fi

    pause
}

# ============================================================
# DETENER PUERTO
# ============================================================

stop_port() {

    header

    echo -e "  ${BOLD}${WHITE}DETENER PUERTO${RESET}"
    echo -e "  ${GRAY}Detiene únicamente la instancia seleccionada.${RESET}"
    echo

    if ! select_hcr_unit "Selecciona la instancia que deseas detener"; then

        info "Operación cancelada."
        pause
        return
    fi

    local unit="$SELECTED_UNIT"
    local port="$SELECTED_PORT"

    echo

    detail "Servicio: ${unit}"
    detail "Puerto:   ${port:-desconocido}"

    echo

    warning "La instancia será detenida, pero NO será eliminada."
    echo

    read -r -p "  ¿Deseas continuar? [s/N]: " answer

    case "${answer,,}" in

        s|si|sí|y|yes)
            ;;

        *)
            info "Operación cancelada."
            pause
            return
            ;;

    esac

    echo

    spinner_start "Deteniendo ${unit}..."

    if systemctl stop "$unit" >/dev/null 2>&1; then

        spinner_stop

        success "Servicio detenido."

    else

        spinner_stop

        error "No se pudo detener ${unit}."

        pause

        return
    fi

    echo

    if is_port_listening "$port"; then

        error "El puerto ${port} todavía aparece escuchando."

    else

        success "El puerto ${port} quedó libre."

    fi

    pause
}

# ============================================================
# INICIAR / DETENER SERVICIO
# ============================================================

toggle_service() {

    header

    echo -e "  ${BOLD}${WHITE}INICIAR / DETENER SERVICIO${RESET}"
    echo -e "  ${GRAY}Control individual de una instancia HCR Server.${RESET}"
    echo

    if ! select_hcr_unit "Selecciona la instancia"; then

        info "Operación cancelada."
        pause
        return
    fi

    local unit="$SELECTED_UNIT"
    local port="$SELECTED_PORT"

    local state

    state="$(get_unit_state "$unit")"

    echo

    detail "Servicio: $unit"
    detail "Puerto:   ${port:----}"
    detail "Estado:   ${state:-desconocido}"

    echo

    if [[ "$state" == "active" ]]; then

        warning "La instancia está ACTIVA."
        echo

        read -r -p "  ¿Deseas detenerla? [s/N]: " answer

        case "${answer,,}" in
            s|si|sí|y|yes)
                ;;
            *)
                info "Operación cancelada."
                pause
                return
                ;;
        esac

        echo

        spinner_start "Deteniendo ${unit}..."

        if systemctl stop "$unit" >/dev/null 2>&1; then

            spinner_stop

            success "Servicio detenido."

        else

            spinner_stop

            error "No se pudo detener ${unit}."

            pause
            return
        fi

    else

        warning "La instancia no está activa."
        echo

        read -r -p "  ¿Deseas iniciarla? [s/N]: " answer

        case "${answer,,}" in
            s|si|sí|y|yes)
                ;;
            *)
                info "Operación cancelada."
                pause
                return
                ;;
        esac

        echo

        spinner_start "Iniciando ${unit}..."

        systemctl daemon-reload >/dev/null 2>&1 || true

        if systemctl start "$unit" >/dev/null 2>&1; then

            spinner_stop

            success "Servicio iniciado."

        else

            spinner_stop

            error "No se pudo iniciar ${unit}."

            echo

            systemctl \
                --no-pager \
                --full \
                status "$unit" \
                2>&1 ||
                true

            pause

            return
        fi

    fi

    echo

    sleep 1

    if systemctl is-active --quiet "$unit"; then

        success "systemd confirma que ${unit} está activo."

    else

        warning "${unit} no está activo."

    fi

    if [[ -n "$port" ]]; then

        if is_port_listening "$port"; then
            success "El puerto ${port} está escuchando."
        else
            warning "El puerto ${port} no aparece escuchando."
        fi

    fi

    pause
}

# ============================================================
# PREPARAR CHANGE-PORT
# ============================================================
#
# change-port.sh actual fue diseñado originalmente para:
#
#   hcr-server.service
#
# El sistema actual utiliza:
#
#   hcr-server-80.service
#   hcr-server-443.service
#   etc.
#
# Por eso se modifica únicamente la copia temporal:
#
#   SERVICE_NAME
#   SYSTEMD_DIR
#   UNIT_PATH
#
# El script original del repositorio NO se modifica.
#
# ============================================================

prepare_change_port_script() {

    local selected_unit="$1"
    local selected_path="$2"

    if [[ -z "$selected_unit" ]]; then
        error "No se seleccionó ninguna instancia."
        return 1
    fi

    if [[ -z "$selected_path" || ! -f "$selected_path" ]]; then
        error "No se encontró la unidad systemd seleccionada."
        return 1
    fi

    if ! download_script \
        "gestor de modificación de puerto" \
        "${BASE_URL}/change-port.sh" \
        "$CHANGE_PORT_SCRIPT"; then

        return 1
    fi

    local service_without_extension="${selected_unit%.service}"

    # Escapar valores para uso seguro dentro de sed.
    local escaped_service
    local escaped_unit_path
    local escaped_systemd_dir

    escaped_service="$(
        printf '%s' "$service_without_extension" |
            sed 's/[\/&]/\\&/g'
    )"

    escaped_unit_path="$(
        printf '%s' "$selected_path" |
            sed 's/[\/&]/\\&/g'
    )"

    escaped_systemd_dir="$(
        printf '%s' "$SYSTEMD_DIR" |
            sed 's/[\/&]/\\&/g'
    )"

    # Cambiar SERVICE_NAME.
    sed -E \
        -i \
        "s#^SERVICE_NAME=.*#SERVICE_NAME=\"${escaped_service}\"#" \
        "$CHANGE_PORT_SCRIPT"

    # Cambiar SYSTEMD_DIR.
    sed -E \
        -i \
        "s#^SYSTEMD_DIR=.*#SYSTEMD_DIR=\"${escaped_systemd_dir}\"#" \
        "$CHANGE_PORT_SCRIPT"

    # Cambiar UNIT_PATH.
    sed -E \
        -i \
        "s#^UNIT_PATH=.*#UNIT_PATH=\"${escaped_unit_path}\"#" \
        "$CHANGE_PORT_SCRIPT"

    chmod 700 "$CHANGE_PORT_SCRIPT"
    chown root:root "$CHANGE_PORT_SCRIPT"

    return 0
}

# ============================================================
# MODIFICAR PUERTO
# ============================================================

modify_port() {

    header

    echo -e "  ${BOLD}${WHITE}MODIFICAR PUERTO${RESET}"
    echo -e "  ${GRAY}Adaptación automática de change-port.sh para múltiples instancias.${RESET}"
    echo

    if ! select_hcr_unit "Selecciona la instancia que deseas modificar"; then

        info "Operación cancelada."
        pause
        return
    fi

    local unit="$SELECTED_UNIT"
    local path="$SELECTED_PATH"
    local port="$SELECTED_PORT"

    echo

    detail "Servicio: ${unit}"
    detail "Puerto actual: ${port:----}"
    detail "Unidad: ${path}"

    echo

    if ! prepare_change_port_script "$unit" "$path"; then

        error "No se pudo preparar change-port.sh."

        pause

        return
    fi

    echo

    info "Ejecutando change-port.sh adaptado a:"
    detail "$unit"

    echo

    bash "$CHANGE_PORT_SCRIPT"

    local result=$?

    rm -f "$CHANGE_PORT_SCRIPT"

    echo

    if (( result == 0 )); then

        success "Cambio de puerto finalizado correctamente."

    else

        error "change-port.sh terminó con código ${result}."

    fi

    pause
}

# ============================================================
# ELIMINAR PUERTO
# ============================================================
#
# delete-port.sh actual ya detecta:
#
#   hcr-server-<puerto>.service
#
# y además selecciona únicamente instancias activas.
#
# Por eso NO hacemos una selección duplicada en el panel.
#
# ============================================================

delete_port() {

    header

    echo -e "  ${BOLD}${WHITE}ELIMINAR PUERTO${RESET}"
    echo -e "  ${GRAY}Ejecutando el delete-port.sh oficial.${RESET}"
    echo

    warning "El script mostrará las instancias activas y permitirá seleccionar una."
    detail "El binario HCR y los certificados serán conservados."

    echo

    if run_remote_script \
        "eliminador de puertos" \
        "${BASE_URL}/delete-port.sh" \
        "$DELETE_PORT_SCRIPT"; then

        echo
        success "La eliminación de la instancia terminó correctamente."

    else

        echo
        error "delete-port.sh terminó con errores."

    fi

    pause
}

# ============================================================
# OPTIMIZAR HCR
# ============================================================
#
# IMPORTANTE:
#
# optimize.sh actual es GLOBAL.
#
# No modifica una sola instancia.
# Modifica TODAS las instancias HCR detectadas.
#
# El panel lo deja explícito.
#
# ============================================================

optimize_service() {

    header

    echo -e "  ${BOLD}${WHITE}OPTIMIZAR HCR SERVER${RESET}"
    echo -e "  ${GRAY}Configuración global de rendimiento.${RESET}"
    echo

    warning "El optimizador oficial actual aplica los cambios a TODAS las instancias HCR."
    detail "No se seleccionará un puerto individual porque optimize.sh trabaja globalmente."

    echo

    if ! hcr_is_installed; then

        error "No existen instancias HCR Server instaladas."

        pause

        return
    fi

    show_instances

    echo

    read -r -p "  ¿Deseas abrir el optimizador global? [s/N]: " answer

    case "${answer,,}" in

        s|si|sí|y|yes)
            ;;

        *)
            info "Operación cancelada."
            pause
            return
            ;;

    esac

    echo

    if run_remote_script \
        "optimizador global" \
        "${BASE_URL}/optimize.sh" \
        "$OPTIMIZE_SCRIPT"; then

        echo
        success "El optimizador terminó correctamente."

    else

        echo
        error "optimize.sh terminó con errores."

    fi

    pause
}

# ============================================================
# REINICIAR INSTANCIA
# ============================================================

restart_selected_instance() {

    if ! select_hcr_unit "Selecciona la instancia que deseas reiniciar"; then

        info "Operación cancelada."
        pause
        return
    fi

    local unit="$SELECTED_UNIT"
    local port="$SELECTED_PORT"

    echo

    detail "Servicio: ${unit}"
    detail "Puerto:   ${port:----}"

    echo

    read -r -p "  ¿Deseas reiniciar esta instancia? [s/N]: " answer

    case "${answer,,}" in

        s|si|sí|y|yes)
            ;;

        *)
            info "Operación cancelada."
            pause
            return
            ;;

    esac

    echo

    spinner_start "Reiniciando ${unit}..."

    systemctl daemon-reload >/dev/null 2>&1 || true

    if systemctl restart "$unit" >/dev/null 2>&1; then

        spinner_stop

        success "Instancia reiniciada."

    else

        spinner_stop

        error "No se pudo reiniciar ${unit}."

        echo

        systemctl \
            --no-pager \
            --full \
            status "$unit" \
            2>&1 ||
            true

        pause

        return
    fi

    echo

    sleep 1

    if systemctl is-active --quiet "$unit"; then

        success "systemd confirma que la instancia está activa."

    else

        error "La instancia no quedó activa."

    fi

    if [[ -n "$port" ]]; then

        if is_port_listening "$port"; then
            success "El puerto ${port} está escuchando correctamente."
        else
            warning "El puerto ${port} no aparece escuchando."
        fi

    fi

    pause
}

# ============================================================
# ESTADO GENERAL
# ============================================================

show_general_status() {

    header

    echo -e "  ${BOLD}${WHITE}ESTADO DE HCR SERVER${RESET}"
    echo -e "  ${GRAY}Estado real de systemd y de los listeners.${RESET}"
    echo

    show_instances

    echo

    pause
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

show_menu() {

    header

    echo -e "  ${BOLD}${WHITE}CONTROL${RESET}"
    echo -e "  ${GRAY}Selecciona una operación${RESET}"
    echo

    printf "  ${CYAN}01${RESET}  ${MAGENTA}➤${RESET}  ${WHITE}Instalar / reinstalar${RESET}\n"
    echo -e "      ${GRAY}Instalador oficial + binario en el directorio correcto${RESET}"
    echo

    printf "  ${CYAN}02${RESET}  ${MAGENTA}◈${RESET}  ${WHITE}Desinstalar${RESET}\n"
    echo -e "      ${GRAY}Desinstalador oficial de múltiples instancias${RESET}"
    echo

    printf "  ${CYAN}03${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}Gestión de puertos${RESET}\n"
    echo -e "      ${GRAY}Añadir, detener, modificar o eliminar instancias${RESET}"
    echo

    printf "  ${CYAN}04${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}Estados de puertos${RESET}\n"
    echo -e "      ${GRAY}Estado real de todas las instancias${RESET}"
    echo

    printf "  ${CYAN}05${RESET}  ${MAGENTA}↕${RESET}  ${WHITE}Iniciar / Detener servicio${RESET}\n"
    echo -e "      ${GRAY}Control individual de una instancia${RESET}"
    echo

    printf "  ${CYAN}06${RESET}  ${MAGENTA}↻${RESET}  ${WHITE}Reiniciar servicio${RESET}\n"
    echo -e "      ${GRAY}Reinicia una instancia seleccionada${RESET}"
    echo

    printf "  ${CYAN}07${RESET}  ${MAGENTA}⚙${RESET}  ${WHITE}Optimizar HCR${RESET}\n"
    echo -e "      ${GRAY}Optimización global de todas las instancias${RESET}"
    echo

    line

    echo
    echo -e "  ${GRAY}00${RESET}  ${WHITE}Salir${RESET}"
    echo

    echo -ne "  ${CYAN}HCR ›${RESET} "
}

# ============================================================
# MAIN
# ============================================================

main() {

    require_root

    prepare_install_dir

    cleanup_temp_scripts

    while true; do

        show_menu

        read -r option

        case "$option" in

            1|01)
                install_service
                ;;

            2|02)
                uninstall_service
                ;;

            3|03)
                port_management_menu
                ;;

            4|04)
                show_general_status
                ;;

            5|05)
                toggle_service
                ;;

            6|06)

                header

                echo -e "  ${BOLD}${WHITE}REINICIAR SERVICIO${RESET}"
                echo -e "  ${GRAY}Selecciona la instancia HCR que deseas reiniciar.${RESET}"
                echo

                restart_selected_instance
                ;;

            7|07)
                optimize_service
                ;;

            0|00)

                echo
                echo -e "  ${CYAN}HCR${RESET} ${GRAY}›${RESET} ${WHITE}Cerrando panel...${RESET}"
                echo

                cleanup_temp_scripts

                exit 0
                ;;

            *)

                echo
                error "Opción no válida."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
