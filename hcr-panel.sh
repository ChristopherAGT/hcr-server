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
# IMPORTANTE:
#
# Este panel funciona como PANEL / LAUNCHER.
#
# Las operaciones principales son realizadas por sus
# respectivos scripts remotos.
#
# El panel únicamente conserva:
#
#   - Detección de instalaciones
#   - Detección de instancias
#   - Detección de puertos
#   - Estado real mediante ss
#   - Interfaz
#   - Descarga y ejecución de scripts
#
# optimize.sh contiene toda la lógica de optimización.
#
# El panel NO:
#
#   - Modifica optimize.sh
#   - Inyecta UNIT_PATH
#   - Inyecta SERVICE_NAME
#   - Selecciona una instancia para optimize.sh
#   - Ejecuta lógica de optimización internamente
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
# COMPROBAR DEPENDENCIAS BÁSICAS
# ============================================================

check_dependencies() {

    local missing=0
    local command_name

    for command_name in \
        bash \
        curl \
        systemctl \
        ss \
        awk \
        grep \
        sed \
        find \
        sort \
        wc; do

        if ! command -v "$command_name" >/dev/null 2>&1; then

            error "No se encontró el comando requerido: ${command_name}"

            missing=1

        fi

    done

    if (( missing != 0 )); then

        echo
        error "Faltan dependencias necesarias para ejecutar el panel."

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
            -name 'hcr-server.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

        find "$SYSTEMD_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'hcr-server-[0-9]*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

    } |
    grep -E '^hcr-server(-[0-9]+)?\.service$' |
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

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi
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
            2>/dev/null ||
            true
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
        head -n1 ||
        true
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
        head -n1 ||
        true
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
        head -n1 ||
        true
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
        head -n1 ||
        true
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
        head -n1 ||
        true
}

# ============================================================
# COMPROBAR LISTENER
# ============================================================

is_port_listening() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    ss -H -lnt 2>/dev/null |
        awk -v port="$port" '
            {
                address = $4

                sub(/^.*:/, "", address)

                if (address == port) {
                    found = 1
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
# OBTENER TODOS LOS PUERTOS HCR
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

        [[ "$port" =~ ^[0-9]+$ ]] || continue

        if is_port_listening "$port"; then
            echo "${port}|activo"
        else
            echo "${port}|inactivo"
        fi

    done <<< "$units" |
    sort -t'|' -k1,1n -u
}

# ============================================================
# HEADER
# ============================================================

header() {

    clear_screen

    local count
    local installed

    count="$(count_hcr_instances)"

    if hcr_is_installed; then
        installed="${GREEN}Instalado${RESET} 🟢"
    else
        installed="${RED}No Instalado${RESET} 🔴"
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
    echo -e "${CYAN}    │${RESET}  ${WHITE}Puertos:${RESET}                                          ${CYAN}│${RESET}"

    local port_data
    local port
    local state

    local active_ports=""
    local inactive_ports=""

    port_data="$(get_hcr_ports)"

    if [[ -n "$port_data" ]]; then

        while IFS='|' read -r port state; do

            [[ -n "$port" ]] || continue

            if [[ "$state" == "activo" ]]; then

                if [[ -n "$active_ports" ]]; then
                    active_ports+="  "
                fi

                active_ports+="${GREEN}● ${port}${RESET}"

            else

                if [[ -n "$inactive_ports" ]]; then
                    inactive_ports+="  "
                fi

                inactive_ports+="${YELLOW}● ${port}${RESET}"

            fi

        done <<< "$port_data"

    fi

    if [[ -n "$active_ports" ]]; then
        echo -e "${CYAN}    │${RESET}  ${active_ports}"
    fi

    if [[ -n "$inactive_ports" ]]; then
        echo -e "${CYAN}    │${RESET}  ${inactive_ports}"
    fi

    if [[ -z "$active_ports" && -z "$inactive_ports" ]]; then
        echo -e "${CYAN}    │${RESET}  ${GRAY}Sin puertos configurados${RESET}"
    fi

    echo -e "${CYAN}    ╰────────────────────────────────────────────────────────╯${RESET}"
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
        echo

        return 1
    fi

    printf "  ${GRAY}%-4s %-12s %-14s %-10s %-10s %-10s${RESET}\n" \
        "#" \
        "PUERTO" \
        "DESTINO" \
        "FRAME" \
        "TIMEOUT" \
        "TRANSP."

    line

    local index=0
    local unit
    local path
    local port
    local target
    local frame
    local timeout
    local transport

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        index=$((index + 1))

        path="$(get_unit_path "$unit")"

        port="$(get_unit_listen_port "$unit" "$path")"
        target="$(get_unit_target_port "$unit" "$path")"
        frame="$(get_unit_frame "$path")"
        timeout="$(get_unit_timeout "$path")"
        transport="$(get_unit_transport "$path")"

        printf "  ${CYAN}%-4s${RESET} ${WHITE}%-12s${RESET} ${WHITE}%-14s${RESET} ${WHITE}%-10s${RESET} ${WHITE}%-10s${RESET} ${WHITE}%-10s${RESET}\n" \
            "$index" \
            "${port:----}" \
            "${target:----}" \
            "${frame:----}" \
            "${timeout:----}" \
            "${transport:----}"

    done <<< "$units"

    echo
    detail "Destino = redirección local 127.0.0.1:PUERTO"
}

# ============================================================
# DESCARGA GENÉRICA
# ============================================================

download_file() {

    local url="$1"
    local destination="$2"
    local temporary="${destination}.download"

    rm -f "$temporary"

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "$temporary"; then

        rm -f "$temporary"

        return 1
    fi

    if [[ ! -s "$temporary" ]]; then

        rm -f "$temporary"

        return 1
    fi

    chmod 700 "$temporary"
    chown root:root "$temporary"

    mv -f \
        "$temporary" \
        "$destination"

    return 0
}

# ============================================================
# EJECUTAR SCRIPT REMOTO
# ============================================================
#
# Esta función únicamente:
#
#   - Descarga el script
#   - Le da permisos
#   - Lo ejecuta
#   - Pasa argumentos si existen
#   - Elimina el temporal
#
# ============================================================

run_remote() {

    local name="$1"
    local url="$2"
    local path="$3"

    shift 3

    prepare_install_dir

    rm -f "$path"

    spinner_start "Descargando ${name}..."

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "$path"; then

        spinner_stop

        rm -f "$path"

        error "No se pudo descargar ${name}."

        return 1
    fi

    spinner_stop

    if [[ ! -s "$path" ]]; then

        rm -f "$path"

        error "El archivo descargado está vacío."

        return 1
    fi

    chmod 700 "$path"
    chown root:root "$path"

    bash "$path" "$@"
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

    if ! openssl req \
        -x509 \
        -newkey rsa:2048 \
        -sha256 \
        -nodes \
        -days 3650 \
        -keyout "$temp_key" \
        -out "$temp_cert" \
        -subj "/CN=hcr-server-temporary" \
        >/dev/null 2>&1; then

        rm -f "$temp_key" "$temp_cert"

        error "No se pudo generar el certificado temporal."

        return 1
    fi

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

    if ! download_file \
        "${BASE_URL}/install.sh" \
        "$INSTALL_SCRIPT"; then

        error "No se pudo descargar install.sh."

        return 1
    fi

    chmod 700 "$INSTALL_SCRIPT"

    info "Descargando binario..."

    if ! download_file \
        "${BASE_URL}/hcr-server" \
        "$BINARY_PATH"; then

        error "No se pudo descargar el binario hcr-server."

        return 1
    fi

    chmod 700 "$BINARY_PATH"

    prepare_certificates || return 1

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

    return 0
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

    cd "$INSTALL_DIR" || {

        error "No se pudo acceder a ${INSTALL_DIR}."

        pause

        return
    }

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
        "$UNINSTALL_SCRIPT"

    local result=$?

    echo

    if (( result == 0 )); then
        success "Desinstalador ejecutado correctamente."
    else
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
        "$ADD_PORT_SCRIPT"

    local result=$?

    echo

    if (( result != 0 )); then
        error "El gestor de puertos terminó con errores."
    fi

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
        "$START_STOP_PORT_SCRIPT"

    local result=$?

    echo

    if (( result != 0 )); then
        error "El gestor de inicio / detención terminó con errores."
    fi

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
        "$CHANGE_PORT_SCRIPT"

    local result=$?

    echo

    if (( result != 0 )); then
        error "El gestor de modificación terminó con errores."
    fi

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
        "$DELETE_PORT_SCRIPT"

    local result=$?

    echo

    if (( result != 0 )); then
        error "El eliminador de puerto terminó con errores."
    fi

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
        "$STATUS_PORT_SCRIPT"

    local result=$?

    echo

    if (( result != 0 )); then
        error "El gestor de estados terminó con errores."
    fi

    pause
}

# ============================================================
# INICIAR / DETENER SERVICIO
# ============================================================

start_stop_service() {

    header

    echo -e "  ${BOLD}${WHITE}INICIAR / DETENER SERVICIO${RESET}"
    echo -e "  ${GRAY}Control del Servicio HCR.${RESET}"
    echo

    echo -e "  ${CYAN}01${RESET}  ${GREEN}Iniciar${RESET}"
    echo -e "      ${GRAY}Inicia el Servicio HCR${RESET}"
    echo

    echo -e "  ${CYAN}02${RESET}  ${RED}Detener${RESET}"
    echo -e "      ${GRAY}Detiene el Servicio HCR${RESET}"
    echo

    echo -e "  ${CYAN}03${RESET}  ${YELLOW}Toggle${RESET}"
    echo -e "      ${GRAY}Cambia automáticamente entre iniciado y detenido${RESET}"
    echo

    line

    echo

    echo -e "  ${GRAY}00${RESET}  ${WHITE}Cancelar${RESET}"
    echo

    echo -ne "  ${CYAN}HCR / SERVICIO ›${RESET} "

    local option
    local action
    local action_name

    read -r option

    case "$option" in

        1|01)
            action="start"
            action_name="iniciar"
            ;;

        2|02)
            action="stop"
            action_name="detener"
            ;;

        3|03)
            action="toggle"
            action_name="cambiar el estado"
            ;;

        0|00)
            info "Operación cancelada."
            sleep 1
            return
            ;;

        *)
            error "Opción no válida."
            sleep 1
            return
            ;;

    esac

    echo

    info "Acción seleccionada: ${action_name}."
    echo

    run_remote \
        "gestor de inicio / detención del servicio" \
        "${BASE_URL}/start-stop-service.sh" \
        "$START_STOP_SERVICE_SCRIPT" \
        "$action"

    local result=$?

    echo

    if (( result == 0 )); then

        success "Acción '${action}' ejecutada correctamente."

    else

        error "El gestor de inicio / detención del servicio terminó con errores."

    fi

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
        "$RESTART_SERVICE_SCRIPT"

    local result=$?

    echo

    if (( result != 0 )); then
        error "El gestor de reinicio terminó con errores."
    fi

    pause
}

# ============================================================
# OPTIMIZAR HCR
# ============================================================
#
# El panel NO contiene lógica de optimización.
#
# Toda la lógica pertenece exclusivamente a optimize.sh.
#
# El panel solamente descarga y ejecuta el script.
#
# ============================================================

optimize_service() {

    header

    echo -e "  ${BOLD}${WHITE}OPTIMIZAR HCR${RESET}"
    echo -e "  ${GRAY}Ejecuta el optimizador oficial de HCR Server.${RESET}"
    echo

    run_remote \
        "optimizador HCR" \
        "${BASE_URL}/optimize.sh" \
        "$OPTIMIZE_SCRIPT"

    local result=$?

    echo

    if (( result == 0 )); then

        success "El optimizador terminó correctamente."

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
    echo -e "      ${GRAY}Ejecuta el optimizador oficial.${RESET}"
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

    check_dependencies

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
