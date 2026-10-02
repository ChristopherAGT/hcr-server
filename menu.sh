#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================

BASE_URL="https://raw.githubusercontent.com/ChristopherAGT/hcr-server/main"

INSTALL_DIR="/root/.hcr-panel"
TEMP_DIR="${INSTALL_DIR}/.tmp"

INSTALL_SCRIPT="${INSTALL_DIR}/install.sh"
BINARY_PATH="${INSTALL_DIR}/hcr-server"
CERT_PATH="${INSTALL_DIR}/fullchain.pem"
KEY_PATH="${INSTALL_DIR}/privkey.pem"

UNINSTALL_SCRIPT="${TEMP_DIR}/uninstall.sh"
PORT_SCRIPT="${TEMP_DIR}/change-port.sh"
OPTIMIZE_SCRIPT="${TEMP_DIR}/optimize.sh"
RESTART_SCRIPT="${TEMP_DIR}/restart.sh"

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
    clear
}

pause() {
    echo
    read -rp "  Presiona ENTER para continuar..." _
}

header() {
    clear_screen

    local state
    state="$(service_state)"

    echo
    echo -e "${CYAN}    ╭────────────────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}    │                                                        │${RESET}"
    echo -e "${CYAN}    │${BOLD}${WHITE}       H C R   S E R V E R${RESET}                              ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${GRAY}       Premium Control Panel${RESET}                            ${CYAN}│${RESET}"
    echo -e "${CYAN}    │                                                        │${RESET}"
    echo -e "${CYAN}    ├────────────────────────────────────────────────────────┤${RESET}"

    if systemctl is-active --quiet hcr-server 2>/dev/null; then
        echo -e "${CYAN}    │${RESET}  ${GREEN}●${RESET} Estado     ${GREEN}ACTIVO${RESET}          ${GRAY}◉${RESET} Puerto ${WHITE}$(get_port)${RESET}            ${CYAN}│${RESET}"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^hcr-server.service'; then
        echo -e "${CYAN}    │${RESET}  ${RED}●${RESET} Estado     ${RED}DETENIDO${RESET}        ${GRAY}◉${RESET} Puerto ${WHITE}$(get_port)${RESET}            ${CYAN}│${RESET}"
    else
        echo -e "${CYAN}    │${RESET}  ${YELLOW}●${RESET} Estado     ${YELLOW}NO INSTALADO${RESET}    ${GRAY}◉${RESET} Puerto ${WHITE}---${RESET}               ${CYAN}│${RESET}"
    fi

    echo -e "${CYAN}    ╰────────────────────────────────────────────────────────╯${RESET}"
    echo
}

service_state() {
    if systemctl is-active --quiet hcr-server 2>/dev/null; then
        echo "ACTIVO"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^hcr-server.service'; then
        echo "DETENIDO"
    else
        echo "NO INSTALADO"
    fi
}

get_port() {
    local unit="/etc/systemd/system/hcr-server.service"

    if [[ -f "$unit" ]]; then
        grep -oE -- '--listen :[0-9]+' "$unit" 2>/dev/null |
            head -n1 |
            sed 's/--listen ://' || true
    else
        echo "---"
    fi
}

spinner_start() {
    local message="${1:-Procesando}"

    (
        local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local i=0

        while true; do
            printf "\r  ${CYAN}%s${RESET} %s" "${frames[$i]}" "$message"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &

    SPINNER_PID=$!
}

spinner_stop() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" >/dev/null 2>&1 || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi

    printf "\r\033[K"
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
# DESCARGAS
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

    mv -f "${destination}.download" "$destination"
}

download_binary() {
    info "Descargando binario hcr-server..."

    download_file \
        "${BASE_URL}/hcr-server" \
        "$BINARY_PATH"

    chmod 700 "$BINARY_PATH"
    chown root:root "$BINARY_PATH"

    success "Binario preparado."
}

download_install_script() {
    info "Descargando instalador..."

    download_file \
        "${BASE_URL}/install.sh" \
        "$INSTALL_SCRIPT"

    chmod 700 "$INSTALL_SCRIPT"
    chown root:root "$INSTALL_SCRIPT"

    success "Instalador preparado."
}

# ============================================================
# CERTIFICADOS TEMPORALES
# ============================================================

prepare_certificates() {

    # Si ambos archivos existen y no están vacíos,
    # se conservan tal como están.
    if [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]]; then
        info "Certificados existentes detectados."
        return 0
    fi

    warning "Certificados PEM ausentes o vacíos."
    info "Generando certificado temporal para continuar..."

    rm -f "$CERT_PATH" "$KEY_PATH"

    if ! command -v openssl >/dev/null 2>&1; then
        error "OpenSSL no está instalado."
        error "No es posible generar los certificados temporales."
        return 1
    fi

    local temp_key
    local temp_cert

    temp_key="${KEY_PATH}.tmp"
    temp_cert="${CERT_PATH}.tmp"

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

    download_install_script
    download_binary
    prepare_certificates

    echo

    if [[ ! -s "$INSTALL_SCRIPT" ]]; then
        error "install.sh no está disponible."
        return 1
    fi

    if [[ ! -s "$BINARY_PATH" ]]; then
        error "hcr-server no está disponible."
        return 1
    fi

    if [[ ! -s "$CERT_PATH" ]]; then
        error "fullchain.pem no está disponible."
        return 1
    fi

    if [[ ! -s "$KEY_PATH" ]]; then
        error "privkey.pem no está disponible."
        return 1
    fi

    chmod 700 "$INSTALL_SCRIPT" "$BINARY_PATH"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"

    chown root:root \
        "$INSTALL_SCRIPT" \
        "$BINARY_PATH" \
        "$CERT_PATH" \
        "$KEY_PATH"

    success "Paquete de instalación preparado correctamente."
}

# ============================================================
# INSTALAR
# ============================================================

run_install() {

    echo
    info "Ejecutando instalador..."
    echo

    cd "$INSTALL_DIR"

    bash "$INSTALL_SCRIPT"
}

install_service() {

    header

    echo -e "  ${BOLD}${WHITE}INSTALACIÓN${RESET}"
    echo -e "  ${GRAY}Preparando HCR Server...${RESET}"
    echo

    if ! prepare_installation; then
        echo
        error "No se pudo preparar la instalación."
        pause
        return
    fi

    echo

    if run_install; then
        echo
        success "HCR Server instalado correctamente."
    else
        echo
        error "La instalación terminó con errores."
    fi

    pause
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
# DESINSTALAR
# ============================================================

uninstall_service() {

    header

    echo -e "  ${BOLD}${WHITE}DESINSTALACIÓN${RESET}"
    echo -e "  ${GRAY}Elimina la instalación de HCR Server.${RESET}"
    echo

    warning "Esta acción eliminará el servicio y sus archivos de instalación."
    echo

    read -rp "  ¿Deseas continuar? [s/N]: " answer

    case "$answer" in
        s|S|si|SI|Si)
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
# CAMBIAR PUERTO
# ============================================================

change_port() {

    header

    echo -e "  ${BOLD}${WHITE}CAMBIAR PUERTO${RESET}"
    echo -e "  ${GRAY}Modifica el puerto de escucha de HCR Server.${RESET}"
    echo

    run_remote \
        "gestor de puerto" \
        "${BASE_URL}/change-port.sh" \
        "$PORT_SCRIPT" || true

    echo
    pause
}

# ============================================================
# OPTIMIZAR
# ============================================================

optimize_service() {

    header

    echo -e "  ${BOLD}${WHITE}OPTIMIZACIÓN${RESET}"
    echo -e "  ${GRAY}Ajusta los parámetros de rendimiento del servicio.${RESET}"
    echo

    run_remote \
        "optimizador" \
        "${BASE_URL}/optimize.sh" \
        "$OPTIMIZE_SCRIPT" || true

    echo
    pause
}

# ============================================================
# REINICIAR
# ============================================================

restart_service() {

    header

    echo -e "  ${BOLD}${WHITE}REINICIAR SERVICIO${RESET}"
    echo -e "  ${GRAY}Reinicia HCR Server y verifica su estado.${RESET}"
    echo

    run_remote \
        "reiniciador" \
        "${BASE_URL}/restart.sh" \
        "$RESTART_SCRIPT" || true

    echo
    pause
}

# ============================================================
# MENÚ
# ============================================================

show_menu() {

    header

    echo -e "  ${BOLD}${WHITE}CONTROL${RESET}"
    echo -e "  ${GRAY}Selecciona una operación${RESET}"
    echo

    echo -e "  ${CYAN}01${RESET}  ${MAGENTA}➤${RESET}  ${WHITE}Instalar / reinstalar${RESET}"
    echo -e "      ${GRAY}Instala o actualiza el servicio${RESET}"
    echo

    echo -e "  ${CYAN}02${RESET}  ${MAGENTA}◈${RESET}  ${WHITE}Desinstalar${RESET}"
    echo -e "      ${GRAY}Elimina completamente la instalación${RESET}"
    echo

    echo -e "  ${CYAN}03${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}Cambiar puerto${RESET}"
    echo -e "      ${GRAY}Modifica el puerto de escucha${RESET}"
    echo

    echo -e "  ${CYAN}04${RESET}  ${MAGENTA}⚙${RESET}  ${WHITE}Optimizar${RESET}"
    echo -e "      ${GRAY}Ajusta rendimiento y recursos${RESET}"
    echo

    echo -e "  ${CYAN}05${RESET}  ${MAGENTA}↻${RESET}  ${WHITE}Reiniciar${RESET}"
    echo -e "      ${GRAY}Reinicia el servicio HCR${RESET}"
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
                change_port
                ;;

            4|04)
                optimize_service
                ;;

            5|05)
                restart_service
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

main "$@"
