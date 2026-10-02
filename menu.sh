#!/usr/bin/env bash

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================

set -u

# ─────────────────────────────────────────────────────────────
# CONFIGURACIÓN
# ─────────────────────────────────────────────────────────────

SERVICE_NAME="hcr-server"
UNIT_PATH="/etc/systemd/system/hcr-server.service"

BASE_URL="https://raw.githubusercontent.com/ChristopherAGT/hcr-server/main"

INSTALL_URL="${BASE_URL}/install.sh"
UNINSTALL_URL="${BASE_URL}/uninstall.sh"
CHANGE_PORT_URL="${BASE_URL}/change-port.sh"
OPTIMIZE_URL="${BASE_URL}/optimize.sh"
RESTART_URL="${BASE_URL}/restart.sh"

# ─────────────────────────────────────────────────────────────
# COLORES
# ─────────────────────────────────────────────────────────────

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

WHITE="\033[97m"

RED="\033[91m"
GREEN="\033[92m"
YELLOW="\033[93m"
CYAN="\033[96m"

# ─────────────────────────────────────────────────────────────
# ICONOS
# ─────────────────────────────────────────────────────────────

CHECK="✓"
CROSS="✕"
DOT="●"
DIAMOND="◆"
GEAR="⚙"
ROCKET="➤"
PORT_ICON="◉"
POWER="◈"

# ─────────────────────────────────────────────────────────────
# TERMINAL
# ─────────────────────────────────────────────────────────────

clear_screen() {
    clear 2>/dev/null || printf '\033c'
}

pause_screen() {
    echo
    printf "  ${DIM}Presiona ENTER para continuar...${RESET}"
    read -r
}

print_line() {
    printf "  ${DIM}────────────────────────────────────────────────────────${RESET}\n"
}

# ─────────────────────────────────────────────────────────────
# VALIDACIONES
# ─────────────────────────────────────────────────────────────

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        clear_screen
        echo
        printf "  ${RED}${CROSS} Este panel requiere privilegios de root.${RESET}\n"
        echo
        printf "  ${DIM}Ejecuta:${RESET} ${CYAN}sudo ./menu.sh${RESET}\n"
        echo
        exit 1
    fi
}

check_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        clear_screen
        printf "  ${RED}${CROSS} Este panel está diseñado para Linux.${RESET}\n"
        exit 1
    fi
}

check_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        clear_screen
        echo
        printf "  ${RED}${CROSS} No se encontró curl.${RESET}\n"
        echo
        printf "  ${DIM}Instálalo con:${RESET} ${CYAN}apt install curl${RESET}\n"
        echo
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────
# INFORMACIÓN DEL SERVICIO
# ─────────────────────────────────────────────────────────────

service_state() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf "${GREEN}ACTIVO${RESET}"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf "${YELLOW}DETENIDO${RESET}"
    else
        printf "${RED}NO INSTALADO${RESET}"
    fi
}

service_indicator() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf "${GREEN}${DOT}${RESET}"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf "${YELLOW}${DOT}${RESET}"
    else
        printf "${RED}${DOT}${RESET}"
    fi
}

get_port() {

    if [[ ! -f "$UNIT_PATH" ]]; then
        printf "${DIM}—${RESET}"
        return
    fi

    local port

    port="$(grep -oE -- '--listen[[:space:]]+:[0-9]+' "$UNIT_PATH" 2>/dev/null \
        | tail -n1 \
        | grep -oE '[0-9]+$' || true)"

    if [[ -n "$port" ]]; then
        printf "${CYAN}${port}${RESET}"
    else
        printf "${DIM}—${RESET}"
    fi
}

# ─────────────────────────────────────────────────────────────
# CABECERA
# ─────────────────────────────────────────────────────────────

draw_header() {

    local state
    state="$(service_state)"

    printf "\n"

    printf "  ${CYAN}╭────────────────────────────────────────────────────────╮${RESET}\n"
    printf "  ${CYAN}│${RESET}                                                        ${CYAN}│${RESET}\n"

    printf "  ${CYAN}│${RESET}       ${BOLD}${WHITE}H C R   S E R V E R${RESET}                       ${CYAN}│${RESET}\n"

    printf "  ${CYAN}│${RESET}       ${DIM}Premium Control Panel${RESET}                     ${CYAN}│${RESET}\n"

    printf "  ${CYAN}│${RESET}                                                        ${CYAN}│${RESET}\n"

    printf "  ${CYAN}├────────────────────────────────────────────────────────┤${RESET}\n"

    printf "  ${CYAN}│${RESET}  $(service_indicator) Estado     ${state}"
    printf "          ${DIM}|${RESET}  ${PORT_ICON} Puerto "
    get_port
    printf "       ${CYAN}│${RESET}\n"

    printf "  ${CYAN}╰────────────────────────────────────────────────────────╯${RESET}\n"

    printf "\n"
}

# ─────────────────────────────────────────────────────────────
# MENÚ
# ─────────────────────────────────────────────────────────────

draw_menu() {

    printf "  ${BOLD}${WHITE}CONTROL${RESET}\n"
    printf "  ${DIM}Selecciona una operación${RESET}\n"

    echo

    printf "  ${CYAN}01${RESET}  ${WHITE}${ROCKET}${RESET}  ${BOLD}Instalar / reinstalar${RESET}\n"
    printf "      ${DIM}Instala o actualiza el servicio${RESET}\n"

    echo

    printf "  ${CYAN}02${RESET}  ${WHITE}${POWER}${RESET}  ${BOLD}Desinstalar${RESET}\n"
    printf "      ${DIM}Elimina completamente la instalación${RESET}\n"

    echo

    printf "  ${CYAN}03${RESET}  ${WHITE}${PORT_ICON}${RESET}  ${BOLD}Cambiar puerto${RESET}\n"
    printf "      ${DIM}Modifica el puerto de escucha${RESET}\n"

    echo

    printf "  ${CYAN}04${RESET}  ${WHITE}${GEAR}${RESET}  ${BOLD}Optimizar${RESET}\n"
    printf "      ${DIM}Ajusta rendimiento y recursos${RESET}\n"

    echo

    printf "  ${CYAN}05${RESET}  ${WHITE}↻${RESET}  ${BOLD}Reiniciar${RESET}\n"
    printf "      ${DIM}Reinicia el servicio HCR${RESET}\n"

    echo

    print_line

    echo

    printf "  ${DIM}00${RESET}  ${DIM}Salir del panel${RESET}\n"

    echo
}

# ─────────────────────────────────────────────────────────────
# DESCARGAR Y EJECUTAR SCRIPT
# ─────────────────────────────────────────────────────────────

run_remote() {

    local url="$1"
    local title="$2"

    local temp_script
    temp_script="$(mktemp "/tmp/hcr-panel-XXXXXX.sh")"

    clear_screen

    printf "\n"
    printf "  ${CYAN}${DIAMOND}${RESET} ${BOLD}${WHITE}${title}${RESET}\n"

    print_line

    echo

    printf "  ${DIM}Conectando con GitHub...${RESET}\n"
    echo

    # Descargar el script temporalmente
    if ! curl -fsSL "$url" -o "$temp_script"; then

        rm -f "$temp_script"

        echo
        printf "  ${RED}${CROSS} No se pudo descargar el script desde GitHub.${RESET}\n"

        pause_screen
        return 1
    fi

    # Dar permisos temporales de ejecución
    chmod 700 "$temp_script"

    # Ejecutar el script como archivo normal
    if ! bash "$temp_script"; then

        rm -f "$temp_script"

        echo
        printf "  ${RED}${CROSS} La operación terminó con errores.${RESET}\n"

        pause_screen
        return 1
    fi

    # Eliminar inmediatamente el script temporal
    rm -f "$temp_script"

    echo
    printf "  ${GREEN}${CHECK} Operación finalizada correctamente.${RESET}\n"

    pause_screen
}

# ─────────────────────────────────────────────────────────────
# CONFIRMACIÓN DE DESINSTALACIÓN
# ─────────────────────────────────────────────────────────────

confirm_uninstall() {

    clear_screen

    printf "\n"

    printf "  ${RED}${BOLD}╭────────────────────────────────────────────────────────╮${RESET}\n"
    printf "  ${RED}│${RESET}  ${RED}${BOLD}⚠  DESINSTALACIÓN${RESET}                               ${RED}│${RESET}\n"
    printf "  ${RED}├────────────────────────────────────────────────────────┤${RESET}\n"
    printf "  ${RED}│${RESET}  Esta operación eliminará la instalación de HCR.    ${RED}│${RESET}\n"
    printf "  ${RED}│${RESET}  El servicio será detenido y eliminado de systemd.  ${RED}│${RESET}\n"
    printf "  ${RED}╰────────────────────────────────────────────────────────╯${RESET}\n"

    echo

    printf "  ${YELLOW}¿Deseas continuar?${RESET} ${DIM}[s/N]${RESET} "
    read -r answer

    case "$answer" in

        s|S|si|SI|sí|Sí|sÍ|SÍ)
            run_remote "$UNINSTALL_URL" "Desinstalando HCR Server"
            ;;

        *)
            printf "\n  ${GREEN}${CHECK}${RESET} Operación cancelada.\n"
            sleep 1
            ;;

    esac
}

# ─────────────────────────────────────────────────────────────
# INSTALACIÓN
# ─────────────────────────────────────────────────────────────

install_service() {
    run_remote "$INSTALL_URL" "Instalando HCR Server"
}

# ─────────────────────────────────────────────────────────────
# CAMBIAR PUERTO
# ─────────────────────────────────────────────────────────────

change_port() {
    run_remote "$CHANGE_PORT_URL" "Configuración de puerto"
}

# ─────────────────────────────────────────────────────────────
# OPTIMIZAR
# ─────────────────────────────────────────────────────────────

optimize_service() {
    run_remote "$OPTIMIZE_URL" "Optimización de HCR Server"
}

# ─────────────────────────────────────────────────────────────
# REINICIAR
# ─────────────────────────────────────────────────────────────

restart_service() {
    run_remote "$RESTART_URL" "Reiniciando HCR Server"
}

# ─────────────────────────────────────────────────────────────
# MENÚ PRINCIPAL
# ─────────────────────────────────────────────────────────────

main_menu() {

    while true; do

        clear_screen

        draw_header
        draw_menu

        printf "  ${CYAN}HCR${RESET} ${DIM}›${RESET} "
        read -r option

        case "$option" in

            1|01)
                install_service
                ;;

            2|02)
                confirm_uninstall
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

            0|00|q|Q)

                clear_screen

                printf "\n"
                printf "  ${CYAN}${DIAMOND}${RESET} ${BOLD}${WHITE}HCR Server${RESET}\n"
                printf "  ${DIM}Panel cerrado correctamente.${RESET}\n"

                echo

                exit 0
                ;;

            *)

                printf "\n"
                printf "  ${YELLOW}!${RESET} Opción no válida.\n"

                sleep 1
                ;;

        esac

    done
}

# ─────────────────────────────────────────────────────────────
# INICIO
# ─────────────────────────────────────────────────────────────

check_linux
check_root
check_curl
main_menu
