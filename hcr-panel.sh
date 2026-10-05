#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================
# Panel compatible con:
#
#   hcr-server.service
#   hcr-server-XXXX.service
#
# Permite administrar múltiples instancias HCR Server.
#
# FUNCIONES:
#
#   01  Instalar / reinstalar
#   02  Desinstalar
#   03  Gestión de puertos
#   04  Estados de puerto
#   05  Iniciar / Detener Servicio
#   06  Reiniciar Servicio
#   07  Optimizar HCR
#
# ============================================================

set +e

BASE_URL="https://raw.githubusercontent.com/ChristopherAGT/hcr-server/main"

INSTALL_DIR="/root/.hcr-panel"
TEMP_DIR="${INSTALL_DIR}/.tmp"

INSTALL_SCRIPT="${INSTALL_DIR}/install.sh"
BINARY_PATH="${INSTALL_DIR}/hcr-server"
CERT_PATH="${INSTALL_DIR}/fullchain.pem"
KEY_PATH="${INSTALL_DIR}/privkey.pem"

UNINSTALL_SCRIPT="${TEMP_DIR}/uninstall.sh"

ADD_PORT_SCRIPT="${TEMP_DIR}/add-port.sh"
START_STOP_PORT_SCRIPT="${TEMP_DIR}/start-stop-port.sh"
CHANGE_PORT_SCRIPT="${TEMP_DIR}/change-port.sh"
DELETE_PORT_SCRIPT="${TEMP_DIR}/delete-port.sh"

STATUS_PORT_SCRIPT="${TEMP_DIR}/status-port.sh"
START_STOP_SERVICE_SCRIPT="${TEMP_DIR}/start-stop-service.sh"
RESTART_SERVICE_SCRIPT="${TEMP_DIR}/restart-service.sh"

OPTIMIZE_SCRIPT="${TEMP_DIR}/optimize.sh"

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="hcr-server"

SPINNER_PID=""

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
# UTILIDADES
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

pause() {
    echo
    read -rp "  Presiona ENTER para continuar..." _
}

success() {
    echo -e "  ${GREEN}✔${RESET} $1"
}

error() {
    echo -e "  ${RED}✖${RESET} $1"
}

warning() {
    echo -e "  ${YELLOW}⚠${RESET} $1"
}

info() {
    echo -e "  ${CYAN}●${RESET} $1"
}

detail() {
    echo -e "      ${GRAY}•${RESET} $1"
}

line() {
    echo -e "  ${DARK}────────────────────────────────────────────────────────${RESET}"
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

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$TEMP_DIR"

    chown root:root "$INSTALL_DIR" "$TEMP_DIR"

    chmod 700 "$INSTALL_DIR"
    chmod 700 "$TEMP_DIR"
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

        local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local i=0

        while true; do

            printf "\r  ${CYAN}%s${RESET} %s" \
                "${frames[$i]}" \
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

    printf "\r\033[2K"
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
            grep -E '^hcr-server(-[0-9]+)?\.service$' ||
            true

        find "$SYSTEMD_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'hcr-server-*.service' \
            -printf '%f\n' 2>/dev/null || true

    } |
    sort -u
}

# ============================================================
# CONTAR INSTANCIAS
# ============================================================

count_hcr_instances() {

    local count

    count="$(
        get_hcr_units |
        grep -E '^hcr-server(-[0-9]+)?\.service$' |
        wc -l |
        tr -d ' '
    )"

    echo "${count:-0}"
}

# ============================================================
# ESTADO GENERAL DE HCR
# ============================================================

hcr_is_installed() {

    local count

    count="$(count_hcr_instances)"

    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        return 0
    fi

    return 1
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
            2>/dev/null || true
    )"

    if [[ -n "$path" && -f "$path" ]]; then
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

    if [[ -z "$path" || ! -f "$path" ]]; then
        return 0
    fi

    grep -oE \
        -- '--listen[[:space:]]+:[0-9]+' \
        "$path" 2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# OBTENER PUERTO DESTINO
# ============================================================

get_unit_target_port() {

    local unit="$1"
    local path="$2"

    if [[ -z "$path" || ! -f "$path" ]]; then
        return 0
    fi

    grep -oE \
        -- '--target[[:space:]]+127\.0\.0\.1:[0-9]+' \
        "$path" 2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# OBTENER TRANSPORTE
# ============================================================

get_unit_transport() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "---"
        return
    fi

    grep -oE \
        -- '--transport[[:space:]]+[a-zA-Z0-9_-]+' \
        "$path" 2>/dev/null |
        awk '{print $2}' |
        head -n1 || true
}

# ============================================================
# OBTENER DOWNLOAD FRAME
# ============================================================

get_unit_frame() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "---"
        return
    fi

    grep -oE \
        -- '--max-download-frame[[:space:]]+[0-9]+' \
        "$path" 2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# OBTENER POLL TIMEOUT
# ============================================================

get_unit_timeout() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "---"
        return
    fi

    grep -oE \
        -- '--download-poll-timeout[[:space:]]+[0-9]+(ms|s|m|h)' \
        "$path" 2>/dev/null |
        grep -oE '[0-9]+(ms|s|m|h)$' |
        head -n1 || true
}

# ============================================================
# ESTADO SYSTEMD
# ============================================================

get_unit_state() {

    local unit="$1"

    systemctl is-active "$unit" 2>/dev/null || true
}

# ============================================================
# COMPROBAR LISTENER
# ============================================================

is_port_listening() {

    local port="$1"

    [[ -n "$port" ]] || return 1

    ss -H -lnt 2>/dev/null |
        awk -v port="$port" '
            {
                address = $4

                if (
                    address ~ (":" port "$") ||
                    address ~ ("\\[" port "\\]:" port "$")
                ) {
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
# LISTAR PUERTOS ACTIVOS
# ============================================================
#
# IMPORTANTE:
#
# Esta función NO muestra simplemente los puertos definidos
# en las unidades systemd.
#
# Solo muestra aquellos puertos que realmente están escuchando
# en este momento mediante ss.
#
# Ejemplo:
#
#   hcr-server-80.service  -> activo + escucha -> 80
#   hcr-server-443.service -> detenido            -> NO aparece
#
# ============================================================

get_hcr_ports() {

    local units
    local unit
    local path
    local port

    units="$(get_hcr_units)"

    [[ -n "$units" ]] || return 0

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        path="$(get_unit_path "$unit")"

        port="$(get_unit_listen_port "$unit" "$path")"

        [[ -n "$port" ]] || continue

        if is_port_listening "$port"; then
            echo "$port"
        fi

    done <<< "$units" |
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
        installed="${RED}No Instalado${RESET} 🔴"
    fi

    # --------------------------------------------------------
    # SOLO PUERTOS REALMENTE ACTIVOS
    # --------------------------------------------------------

    ports="$(get_hcr_ports | paste -sd ', ' -)"

    if [[ -z "$ports" ]]; then
        port_line="${GRAY}---${RESET}"
    else
        port_line="${WHITE}${ports}${RESET}"
    fi

    echo
    echo -e "${CYAN}    ╭────────────────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}    │                                                        │${RESET}"
    echo -e "${CYAN}    │${BOLD}${WHITE}       H C R   S E R V E R${RESET}                              ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${GRAY}       Premium Control Panel${RESET}                            ${CYAN}│${RESET}"
    echo -e "${CYAN}    │                                                        │${RESET}"
    echo -e "${CYAN}    ├────────────────────────────────────────────────────────┤${RESET}"
    echo -e "${CYAN}    │${RESET}  ${WHITE}HCR:${RESET} ${installed}                                      ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${RESET}  ${WHITE}Instancias HCR:${RESET} ${GREEN}${count}${RESET}                                ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${RESET}  ${WHITE}Puertos:${RESET} ${port_line}                              ${CYAN}│${RESET}"
    echo -e "${CYAN}    ╰────────────────────────────────────────────────────────╯${RESET}"
    echo
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
# TABLA DE INSTANCIAS
# ============================================================

show_instances() {

    local units
    units="$(get_hcr_units)"

    echo -e "  ${BOLD}${WHITE}INSTANCIAS HCR SERVER${RESET}"
    echo

    if [[ -z "$units" ]]; then

        warning "No se detectaron instancias HCR Server."
        echo
        return 1
    fi

    printf "  ${GRAY}%-4s %-12s %-14s %-14s %-10s %-10s %-10s${RESET}\n" \
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

            SIN\ ESCUCHA)
                state_display="${YELLOW}SIN ESCUCHA${RESET}"
                ;;

            ERROR)
                state_display="${RED}ERROR${RESET}"
                ;;

            *)
                state_display="${GRAY}DETENIDO${RESET}"
                ;;
        esac

        printf "  ${CYAN}%-4s${RESET} ${WHITE}%-12s${RESET} ${WHITE}%-14s${RESET} %-14b ${WHITE}%-10s${RESET} ${WHITE}%-10s${RESET} ${WHITE}%-10s${RESET}\n" \
            "$index" \
            "${port:----}" \
            "${target:----}" \
            "$state_display" \
            "${frame:----}" \
            "${timeout:----}" \
            "${transport:----}"

    done <<< "$units"

    echo
    detail "Destino = redirección local 127.0.0.1:PUERTO"
    detail "ACTIVO = systemd activo y puerto realmente escuchando."
}

# ============================================================
# SELECCIONAR UNIDAD
# ============================================================

select_hcr_unit() {

    local title="${1:-Seleccionar instancia}"
    local units
    units="$(get_hcr_units)"

    if [[ -z "$units" ]]; then

        warning "No existen instancias HCR Server disponibles."
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

    declare -a UNIT_ARRAY

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

            SIN\ ESCUCHA)
                state_display="${YELLOW}SIN ESCUCHA${RESET}"
                ;;

            ERROR)
                state_display="${RED}ERROR${RESET}"
                ;;

            *)
                state_display="${GRAY}DETENIDO${RESET}"
                ;;
        esac

        printf "  ${CYAN}%02d${RESET}  ${WHITE}Puerto %-6s${RESET} ${GRAY}%-28s${RESET} %b\n" \
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

        read -rp "  Selecciona una instancia: " option

        if [[ "$option" == "0" || "$option" == "00" ]]; then
            return 1
        fi

        if [[ "$option" =~ ^[0-9]+$ ]] &&
           (( option >= 1 && option <= index )); then

            SELECTED_UNIT="${UNIT_ARRAY[$option]}"
            SELECTED_PATH="$(get_unit_path "$SELECTED_UNIT")"
            SELECTED_PORT="$(get_unit_listen_port "$SELECTED_UNIT" "$SELECTED_PATH")"

            return 0
        fi

        error "Selección no válida."
    done
}

# ============================================================
# DESCARGA GENÉRICA
# ============================================================

download_file() {

    local url="$1"
    local destination="$2"

    curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "${destination}.download"

    chmod 700 "${destination}.download"
    chown root:root "${destination}.download"

    mv -f \
        "${destination}.download" \
        "$destination"
}

# ============================================================
# EJECUTAR SCRIPT REMOTO
# ============================================================

run_remote() {

    local name="$1"
    local url="$2"
    local path="$3"

    prepare_install_dir

    spinner_start "Descargando ${name}..."

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "$path"; then

        spinner_stop

        error "No se pudo descargar ${name}."

        return 1
    fi

    chmod 700 "$path"
    chown root:root "$path"

    spinner_stop

    bash "$path"
    local result=$?

    rm -f "$path"

    return "$result"
}

# ============================================================
# CERTIFICADOS
# ============================================================

prepare_certificates() {

    if [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]]; then

        info "Certificados existentes detectados."

        return 0
    fi

    warning "Certificados PEM ausentes o vacíos."
    info "Generando certificado temporal..."

    rm -f "$CERT_PATH" "$KEY_PATH"

    if ! command -v openssl >/dev/null 2>&1; then

        error "OpenSSL no está instalado."

        return 1
    fi

    local temp_key="${KEY_PATH}.tmp"
    local temp_cert="${CERT_PATH}.tmp"

    rm -f "$temp_key" "$temp_cert"

    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -sha256 \
        -nodes \
        -days 3650 \
        -keyout "$temp_key" \
        -out "$temp_cert" \
        -subj "/CN=hcr-server-temporary" \
        >/dev/null 2>&1

    chown root:root "$temp_key" "$temp_cert"

    chmod 600 "$temp_key"
    chmod 644 "$temp_cert"

    mv -f "$temp_key" "$KEY_PATH"
    mv -f "$temp_cert" "$CERT_PATH"

    success "Certificado temporal generado."
}

# ============================================================
# PREPARAR INSTALACIÓN
# ============================================================

prepare_installation() {

    prepare_install_dir

    echo

    info "Descargando instalador..."

    download_file \
        "${BASE_URL}/install.sh" \
        "$INSTALL_SCRIPT"

    chmod 700 "$INSTALL_SCRIPT"

    info "Descargando binario..."

    download_file \
        "${BASE_URL}/hcr-server" \
        "$BINARY_PATH"

    chmod 700 "$BINARY_PATH"

    prepare_certificates

    echo

    [[ -s "$INSTALL_SCRIPT" ]] ||
        return 1

    [[ -s "$BINARY_PATH" ]] ||
        return 1

    [[ -s "$CERT_PATH" ]] ||
        return 1

    [[ -s "$KEY_PATH" ]] ||
        return 1

    chown root:root \
        "$INSTALL_SCRIPT" \
        "$BINARY_PATH" \
        "$CERT_PATH" \
        "$KEY_PATH"

    chmod 700 "$INSTALL_SCRIPT" "$BINARY_PATH"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"

    success "Paquete de instalación preparado correctamente."
}

# ============================================================
# INSTALAR
# ============================================================

install_service() {

    header

    echo -e "  ${BOLD}${WHITE}INSTALACIÓN / REINSTALACIÓN${RESET}"
    echo -e "  ${GRAY}Prepara e instala HCR Server.${RESET}"
    echo

    if ! prepare_installation; then

        error "No se pudo preparar la instalación."

        pause

        return
    fi

    echo

    cd "$INSTALL_DIR"

    if bash "$INSTALL_SCRIPT"; then

        echo

        success "HCR Server instalado correctamente."

    else

        echo

        error "La instalación terminó con errores."
    fi

    pause
}

# ============================================================
# DESINSTALAR
# ============================================================

uninstall_service() {

    header

    echo -e "  ${BOLD}${WHITE}DESINSTALACIÓN${RESET}"
    echo -e "  ${GRAY}Elimina la instalación principal de HCR Server.${RESET}"
    echo

    warning "Esta acción puede eliminar el servicio y los archivos principales."
    echo

    read -rp "  ¿Deseas continuar? [s/N]: " answer

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

    run_remote \
        "desinstalador" \
        "${BASE_URL}/uninstall.sh" \
        "$UNINSTALL_SCRIPT" || true

    echo

    pause
}

# ============================================================
# GESTIÓN DE PUERTOS
# ============================================================

port_management_menu() {

    while true; do

        header

        echo -e "  ${BOLD}${WHITE}GESTIÓN DE PUERTOS${RESET}"
        echo -e "  ${GRAY}Administración individual de las instancias HCR.${RESET}"
        echo

        echo -e "  ${CYAN}01${RESET}  ${MAGENTA}＋${RESET}  ${WHITE}Añadir puerto${RESET}"
        echo -e "      ${GRAY}Crear una nueva instancia HCR${RESET}"
        echo

        echo -e "  ${CYAN}02${RESET}  ${MAGENTA}■${RESET}  ${WHITE}Iniciar / Detener puerto${RESET}"
        echo -e "      ${GRAY}Iniciar o detener una instancia HCR${RESET}"
        echo

        echo -e "  ${CYAN}03${RESET}  ${MAGENTA}✎${RESET}  ${WHITE}Modificar puerto${RESET}"
        echo -e "      ${GRAY}Cambiar puerto HCR o puerto destino${RESET}"
        echo

        echo -e "  ${CYAN}04${RESET}  ${MAGENTA}✖${RESET}  ${WHITE}Eliminar puerto${RESET}"
        echo -e "      ${GRAY}Eliminar completamente una instancia${RESET}"
        echo

        line

        echo

        echo -e "  ${GRAY}00${RESET}  ${WHITE}Volver al menú principal${RESET}"
        echo

        echo -ne "  ${CYAN}HCR / PUERTOS ›${RESET} "

        read -r option

        case "$option" in

            1|01)
                add_port
                ;;

            2|02)
                start_stop_port
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
    echo -e "  ${GRAY}Crea una nueva instancia HCR Server.${RESET}"
    echo

    run_remote \
        "gestor de nuevos puertos" \
        "${BASE_URL}/add-port.sh" \
        "$ADD_PORT_SCRIPT" || true

    echo

    pause
}

# ============================================================
# INICIAR / DETENER PUERTO
# ============================================================

start_stop_port() {

    header

    echo -e "  ${BOLD}${WHITE}INICIAR / DETENER PUERTO${RESET}"
    echo -e "  ${GRAY}Inicia o detiene una instancia HCR Server.${RESET}"
    echo

    run_remote \
        "gestor de inicio / detención de puerto" \
        "${BASE_URL}/start-stop-port.sh" \
        "$START_STOP_PORT_SCRIPT" || true

    echo

    pause
}

# ============================================================
# MODIFICAR PUERTO
# ============================================================

modify_port() {

    header

    echo -e "  ${BOLD}${WHITE}MODIFICAR PUERTO${RESET}"
    echo -e "  ${GRAY}Cambia el puerto HCR o el puerto destino de una instancia.${RESET}"
    echo

    run_remote \
        "gestor de modificación de puerto" \
        "${BASE_URL}/change-port.sh" \
        "$CHANGE_PORT_SCRIPT" || true

    echo

    pause
}

# ============================================================
# ELIMINAR PUERTO
# ============================================================

delete_port() {

    header

    echo -e "  ${BOLD}${WHITE}ELIMINAR PUERTO${RESET}"
    echo -e "  ${GRAY}Elimina completamente una instancia HCR Server.${RESET}"
    echo

    run_remote \
        "eliminador de puerto" \
        "${BASE_URL}/delete-port.sh" \
        "$DELETE_PORT_SCRIPT" || true

    echo

    pause
}

# ============================================================
# ESTADOS DE PUERTOS
# ============================================================

show_general_status() {

    header

    echo -e "  ${BOLD}${WHITE}ESTADOS DE PUERTOS${RESET}"
    echo -e "  ${GRAY}Consulta el estado de las instancias HCR Server.${RESET}"
    echo

    run_remote \
        "gestor de estados de puertos" \
        "${BASE_URL}/status-port.sh" \
        "$STATUS_PORT_SCRIPT" || true

    echo

    pause
}

# ============================================================
# INICIAR / DETENER SERVICIO
# ============================================================

start_stop_service() {

    header

    echo -e "  ${BOLD}${WHITE}INICIAR / DETENER SERVICIO${RESET}"
    echo -e "  ${GRAY}Inicia o detiene el Servicio HCR.${RESET}"
    echo

    run_remote \
        "gestor de inicio / detención del servicio" \
        "${BASE_URL}/start-stop-service.sh" \
        "$START_STOP_SERVICE_SCRIPT" || true

    echo

    pause
}

# ============================================================
# REINICIAR SERVICIO
# ============================================================

restart_service() {

    header

    echo -e "  ${BOLD}${WHITE}REINICIAR SERVICIO${RESET}"
    echo -e "  ${GRAY}Reinicia el Servicio HCR.${RESET}"
    echo

    run_remote \
        "gestor de reinicio del servicio" \
        "${BASE_URL}/restart-service.sh" \
        "$RESTART_SERVICE_SCRIPT" || true

    echo

    pause
}

# ============================================================
# PREPARAR OPTIMIZADOR
# ============================================================

prepare_instance_optimizer() {

    local unit_path="$1"
    local unit_name="$2"

    prepare_install_dir

    spinner_start "Preparando optimizador para ${unit_name}..."

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "${BASE_URL}/optimize.sh" \
        -o "$OPTIMIZE_SCRIPT"; then

        spinner_stop

        error "No se pudo descargar el optimizador."

        return 1
    fi

    sed -E \
        -i \
        "s#^UNIT_PATH=.*#UNIT_PATH=\"${unit_path}\"#" \
        "$OPTIMIZE_SCRIPT"

    sed -E \
        -i \
        "s#^SERVICE_NAME=.*#SERVICE_NAME=\"${unit_name%.service}\"#" \
        "$OPTIMIZE_SCRIPT"

    chmod 700 "$OPTIMIZE_SCRIPT"

    chown root:root "$OPTIMIZE_SCRIPT"

    spinner_stop

    success "Optimizador preparado."

    return 0
}

# ============================================================
# OPTIMIZAR HCR
# ============================================================

optimize_service() {

    header

    echo -e "  ${BOLD}${WHITE}OPTIMIZAR HCR${RESET}"
    echo -e "  ${GRAY}Ajusta rendimiento de una instancia HCR específica.${RESET}"
    echo

    if ! select_hcr_unit "Selecciona la instancia que deseas optimizar"; then

        info "Operación cancelada."

        pause

        return
    fi

    local unit="$SELECTED_UNIT"
    local path="$SELECTED_PATH"
    local port="$SELECTED_PORT"

    local frame
    local timeout
    local target
    local transport

    frame="$(get_unit_frame "$path")"
    timeout="$(get_unit_timeout "$path")"
    target="$(get_unit_target_port "$unit" "$path")"
    transport="$(get_unit_transport "$path")"

    echo

    echo -e "  ${BOLD}${WHITE}CONFIGURACIÓN DETECTADA${RESET}"
    echo

    detail "Instancia: ${unit}"
    detail "Puerto HCR: ${port:----}"
    detail "Puerto destino: ${target:----}"
    detail "Transporte: ${transport:----}"
    detail "Max Download Frame: ${frame:-no configurado}"
    detail "Download Poll Timeout: ${timeout:-no configurado}"

    echo

    if [[ -z "$path" || ! -f "$path" ]]; then

        error "No se pudo localizar la unidad de systemd."

        pause

        return
    fi

    echo

    if ! prepare_instance_optimizer "$path" "$unit"; then

        pause

        return
    fi

    echo

    bash "$OPTIMIZE_SCRIPT"

    local result=$?

    rm -f "$OPTIMIZE_SCRIPT"

    echo

    if (( result == 0 )); then
        success "Optimización finalizada."
    else
        error "El optimizador terminó con errores."
    fi

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

    printf "  ${CYAN}01${RESET}  ${MAGENTA}➤${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Instalar / reinstalar"
    echo -e "      ${GRAY}Instala o Actualiza HCR Server${RESET}"
    echo

    printf "  ${CYAN}02${RESET}  ${MAGENTA}◈${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Desinstalar"
    echo -e "      ${GRAY}Elimina la instalación principal${RESET}"
    echo

    printf "  ${CYAN}03${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Gestión de puertos"
    echo -e "      ${GRAY}Añadir, iniciar, detener, modificar o eliminar instancias${RESET}"
    echo

    printf "  ${CYAN}04${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Estados de puertos"
    echo -e "      ${GRAY}Muestra el estado real de las instancias${RESET}"
    echo

    printf "  ${CYAN}05${RESET}  ${MAGENTA}↕${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Iniciar / Detener Servicio"
    echo -e "      ${GRAY}Inicia o detiene el Servicio HCR por completo.${RESET}"
    echo

    printf "  ${CYAN}06${RESET}  ${MAGENTA}↻${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Reiniciar Servicio"
    echo -e "      ${GRAY}Reinicia el Servicio HCR por completo.${RESET}"
    echo

    printf "  ${CYAN}07${RESET}  ${MAGENTA}⚙${RESET}  ${WHITE}%-24s${RESET}\n" \
        "Optimizar HCR"
    echo -e "      ${GRAY}Ajusta el rendimiento del Protocolo.${RESET}"
    echo

    echo -e "  ${DARK}────────────────────────────────────────────────────────${RESET}"
    echo

    echo -e "  ${GRAY}00${RESET}  ${WHITE}Salir del panel${RESET}"
    echo

    echo -ne "  ${CYAN}HCR ›${RESET} "
}

# ============================================================
# MAIN
# ============================================================

main() {

    require_root

    prepare_install_dir

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
                start_stop_service
                ;;

            6|06)
                restart_service
                ;;

            7|07)
                optimize_service
                ;;

            0|00)

                echo
                echo -e "  ${CYAN}HCR${RESET} ${GRAY}›${RESET} ${WHITE}Cerrando panel...${RESET}"
                echo

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
