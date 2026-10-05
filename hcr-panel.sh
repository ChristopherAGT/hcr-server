#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================
# Panel principal de administración HCR Server.
#
# OPCIONES:
#
#   01  Instalar / reinstalar
#   02  Desinstalar
#   03  Gestión de puertos
#   04  Estados de puertos
#   05  Optimizar HCR
#   06  Iniciar / Detener Servicio
#   07  Reiniciar Servicio
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

START_STOP_PORT_SCRIPT="${TEMP_DIR}/start-stop-port.sh"
ADD_PORT_SCRIPT="${TEMP_DIR}/add-port.sh"
CHANGE_PORT_SCRIPT="${TEMP_DIR}/change-port.sh"
DELETE_PORT_SCRIPT="${TEMP_DIR}/delete-port.sh"

STATUS_PORT_SCRIPT="${TEMP_DIR}/status-port.sh"
OPTIMIZE_SCRIPT="${TEMP_DIR}/optimize.sh"

START_STOP_SERVICE_SCRIPT="${TEMP_DIR}/start-stop-service.sh"
RESTART_SERVICE_SCRIPT="${TEMP_DIR}/restart-service.sh"

SYSTEMD_DIR="/etc/systemd/system"

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
# LISTAR PUERTOS PARA EL ENCABEZADO
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
# ENCABEZADO PRINCIPAL
# ============================================================
#
# IMPORTANTE:
#
# Este es el ÚNICO encabezado visual del panel.
#
# NO muestra:
#
#   INSTANCIAS HCR SERVER
#   tablas
#   FRAME
#   TIMEOUT
#   TRANSPORTE
#
# Únicamente muestra:
#
#   HCR
#   Instancias HCR
#   Puertos
#
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

    ports="$(get_hcr_ports | paste -sd ',' -)"

    if [[ -z "$ports" ]]; then
        port_line="${GRAY}---${RESET}"
    else
        port_line="${WHITE}${ports}${RESET}"
    fi

    echo
    echo -e "${CYAN}    ╭────────────────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}    │                                                        │${RESET}"
    echo -e "${CYAN}    │       ${BOLD}${WHITE}H C R   S E R V E R${RESET}                              ${CYAN}│${RESET}"
    echo -e "${CYAN}    │       ${GRAY}Premium Control Panel${RESET}                            ${CYAN}│${RESET}"
    echo -e "${CYAN}    │                                                        │${RESET}"
    echo -e "${CYAN}    ├────────────────────────────────────────────────────────┤${RESET}"
    echo -e "${CYAN}    │${RESET}  ${WHITE}HCR:${RESET} ${installed}                                      ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${RESET}  ${WHITE}Instancias HCR:${RESET} ${GREEN}${count}${RESET}                                ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${RESET}  ${WHITE}Puertos:${RESET} ${port_line}                              ${CYAN}│${RESET}"
    echo -e "${CYAN}    ╰────────────────────────────────────────────────────────╯${RESET}"
    echo
}

# ============================================================
# DESCARGAR ARCHIVO
# ============================================================

download_file() {

    local url="$1"
    local destination="$2"

    prepare_install_dir

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "${destination}.download"; then

        rm -f "${destination}.download"

        return 1
    fi

    if [[ ! -s "${destination}.download" ]]; then

        rm -f "${destination}.download"

        return 1
    fi

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

    echo

    spinner_start "Descargando ${name}..."

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "${path}.download"; then

        spinner_stop

        rm -f "${path}.download"

        error "No se pudo descargar ${name}."

        return 1
    fi

    spinner_stop

    if [[ ! -s "${path}.download" ]]; then

        rm -f "${path}.download"

        error "El archivo descargado está vacío."

        return 1
    fi

    chmod 700 "${path}.download"
    chown root:root "${path}.download"

    mv -f \
        "${path}.download" \
        "$path"

    echo

    spinner_start "Ejecutando ${name}..."

    bash "$path"
    local result=$?

    spinner_stop

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

    return 0
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

    success "Instalador descargado."

    echo

    info "Descargando binario..."

    if ! download_file \
        "${BASE_URL}/hcr-server" \
        "$BINARY_PATH"; then

        error "No se pudo descargar el binario HCR Server."

        return 1
    fi

    chmod 700 "$BINARY_PATH"

    success "Binario descargado."

    echo

    if ! prepare_certificates; then
        return 1
    fi

    echo

    [[ -s "$INSTALL_SCRIPT" ]] || return 1
    [[ -s "$BINARY_PATH" ]] || return 1
    [[ -s "$CERT_PATH" ]] || return 1
    [[ -s "$KEY_PATH" ]] || return 1

    chown root:root \
        "$INSTALL_SCRIPT" \
        "$BINARY_PATH" \
        "$CERT_PATH" \
        "$KEY_PATH"

    chmod 700 \
        "$INSTALL_SCRIPT" \
        "$BINARY_PATH"

    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"

    success "Paquete de instalación preparado correctamente."

    return 0
}

# ============================================================
# OPCIÓN 1 — INSTALAR
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
# OPCIÓN 2 — DESINSTALAR
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
        success "Desinstalación finalizada."
    else
        error "El desinstalador terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 3 — GESTIÓN DE PUERTOS
# ============================================================

port_management_menu() {

    while true; do

        header

        echo -e "  ${BOLD}${WHITE}GESTIÓN DE PUERTOS${RESET}"
        echo -e "  ${GRAY}Administración de las instancias HCR Server.${RESET}"
        echo

        echo -e "  ${CYAN}01${RESET}  ${MAGENTA}↕${RESET}  ${WHITE}Iniciar / Detener Puerto${RESET}"
        echo -e "      ${GRAY}Inicia o detiene una instancia HCR${RESET}"
        echo

        echo -e "  ${CYAN}02${RESET}  ${MAGENTA}＋${RESET}  ${WHITE}Añadir Puerto${RESET}"
        echo -e "      ${GRAY}Crea una nueva instancia HCR${RESET}"
        echo

        echo -e "  ${CYAN}03${RESET}  ${MAGENTA}✎${RESET}  ${WHITE}Modificar Puerto${RESET}"
        echo -e "      ${GRAY}Modifica la configuración de una instancia${RESET}"
        echo

        echo -e "  ${CYAN}04${RESET}  ${MAGENTA}✖${RESET}  ${WHITE}Eliminar Puerto${RESET}"
        echo -e "      ${GRAY}Elimina completamente una instancia${RESET}"
        echo

        line

        echo

        echo -e "  ${GRAY}00${RESET}  ${WHITE}Volver al menú principal${RESET}"
        echo

        echo -ne "  ${CYAN}HCR / PUERTOS ›${RESET} "

        read -r option

        case "$option" in

            1|01)

                run_remote \
                    "gestor de inicio / detención de puerto" \
                    "${BASE_URL}/start-stop-port.sh" \
                    "$START_STOP_PORT_SCRIPT"

                echo
                pause
                ;;

            2|02)

                run_remote \
                    "gestor de nuevos puertos" \
                    "${BASE_URL}/add-port.sh" \
                    "$ADD_PORT_SCRIPT"

                echo
                pause
                ;;

            3|03)

                run_remote \
                    "gestor de modificación de puerto" \
                    "${BASE_URL}/change-port.sh" \
                    "$CHANGE_PORT_SCRIPT"

                echo
                pause
                ;;

            4|04)

                run_remote \
                    "eliminador de puerto" \
                    "${BASE_URL}/delete-port.sh" \
                    "$DELETE_PORT_SCRIPT"

                echo
                pause
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
# OPCIÓN 4 — ESTADOS DE PUERTOS
# ============================================================
#
# IMPORTANTE:
#
# NO se muestra ninguna tabla.
#
# NO se llama a show_instances.
#
# Se conserva únicamente el encabezado principal.
#
# ============================================================

status_ports() {

    header

    echo -e "  ${BOLD}${WHITE}ESTADOS DE PUERTOS${RESET}"
    echo -e "  ${GRAY}Consulta el estado general de las instancias HCR Server.${RESET}"
    echo

    local units
    units="$(get_hcr_units)"

    if [[ -z "$units" ]]; then

        warning "No se detectaron instancias HCR Server."

    else

        local active=0
        local stopped=0
        local failed=0
        local unit
        local state

        while IFS= read -r unit; do

            [[ -n "$unit" ]] || continue

            state="$(systemctl is-active "$unit" 2>/dev/null || true)"

            case "$state" in

                active)
                    active=$((active + 1))
                    ;;

                failed)
                    failed=$((failed + 1))
                    ;;

                *)
                    stopped=$((stopped + 1))
                    ;;

            esac

        done <<< "$units"

        echo -e "  ${WHITE}Estado general:${RESET}"
        echo

        echo -e "      ${GREEN}●${RESET} Activas:   ${GREEN}${active}${RESET}"
        echo -e "      ${GRAY}●${RESET} Detenidas: ${GRAY}${stopped}${RESET}"
        echo -e "      ${RED}●${RESET} Error:     ${RED}${failed}${RESET}"

    fi

    echo

    pause
}

# ============================================================
# OPCIÓN 5 — OPTIMIZAR HCR
# ============================================================

optimize_service() {

    header

    echo -e "  ${BOLD}${WHITE}OPTIMIZAR HCR${RESET}"
    echo -e "  ${GRAY}Ajusta el rendimiento del protocolo HCR Server.${RESET}"
    echo

    run_remote \
        "optimizador HCR" \
        "${BASE_URL}/optimize.sh" \
        "$OPTIMIZE_SCRIPT"

    local result=$?

    echo

    if (( result == 0 )); then
        success "Optimización finalizada."
    else
        error "El optimizador terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 6 — INICIAR / DETENER SERVICIO
# ============================================================

start_stop_service() {

    header

    echo -e "  ${BOLD}${WHITE}INICIAR / DETENER SERVICIO${RESET}"
    echo -e "  ${GRAY}Administra el servicio HCR Server completo.${RESET}"
    echo

    run_remote \
        "gestor de servicio HCR" \
        "${BASE_URL}/start-stop-service.sh" \
        "$START_STOP_SERVICE_SCRIPT"

    local result=$?

    echo

    if (( result == 0 )); then
        success "Operación de servicio finalizada."
    else
        error "El gestor de servicio terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 7 — REINICIAR SERVICIO
# ============================================================

restart_service() {

    header

    echo -e "  ${BOLD}${WHITE}REINICIAR SERVICIO${RESET}"
    echo -e "  ${GRAY}Reinicia el servicio HCR Server completo.${RESET}"
    echo

    run_remote \
        "reiniciador del servicio HCR" \
        "${BASE_URL}/restart-service.sh" \
        "$RESTART_SERVICE_SCRIPT"

    local result=$?

    echo

    if (( result == 0 )); then
        success "Servicio reiniciado correctamente."
    else
        error "El reiniciador del servicio terminó con errores."
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

    printf "  ${CYAN}01${RESET}  ${MAGENTA}➤${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Instalar / reinstalar"
    echo -e "      ${GRAY}Instala o Actualiza HCR Server${RESET}"
    echo

    printf "  ${CYAN}02${RESET}  ${MAGENTA}◈${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Desinstalar"
    echo -e "      ${GRAY}Elimina la instalación principal${RESET}"
    echo

    printf "  ${CYAN}03${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Gestión de puertos"
    echo -e "      ${GRAY}Iniciar, añadir, modificar o eliminar instancias${RESET}"
    echo

    printf "  ${CYAN}04${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Estados de puertos"
    echo -e "      ${GRAY}Muestra el estado general de las instancias${RESET}"
    echo

    printf "  ${CYAN}05${RESET}  ${MAGENTA}⚙${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Optimizar HCR"
    echo -e "      ${GRAY}Ajusta el rendimiento del Protocolo${RESET}"
    echo

    printf "  ${CYAN}06${RESET}  ${MAGENTA}↕${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Iniciar / Detener Servicio"
    echo -e "      ${GRAY}Inicia o detiene el Servicio HCR por completo.${RESET}"
    echo

    printf "  ${CYAN}07${RESET}  ${MAGENTA}↻${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Reiniciar Servicio"
    echo -e "      ${GRAY}Reinicia el Servicio HCR por completo.${RESET}"
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

                status_ports
                ;;

            5|05)

                optimize_service
                ;;

            6|06)

                start_stop_service
                ;;

            7|07)

                restart_service
                ;;

            0|00)

                echo

                echo -e \
                    "  ${CYAN}HCR${RESET} ${GRAY}›${RESET} ${WHITE}Cerrando panel...${RESET}"

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
