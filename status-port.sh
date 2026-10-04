#!/usr/bin/env bash
set -u

# ============================================================
# HCR SERVER — ESTADO DE PUERTOS
# ============================================================
# Script independiente del Premium Control Panel.
#
# FUNCIONES:
#
#   - Detecta todas las instancias HCR Server.
#   - Muestra el puerto HCR.
#   - Muestra el puerto destino.
#   - Muestra el estado real de systemd.
#   - Comprueba si el puerto realmente está escuchando.
#   - Muestra Max Download Frame.
#   - Muestra Download Poll Timeout.
#   - Muestra el transporte.
#   - Permite actualizar la información.
#
# NO:
#   - instala HCR
#   - desinstala HCR
#   - modifica puertos
#   - reinicia servicios
#   - detiene servicios
#   - inicia servicios
#   - modifica configuraciones
#
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

export PATH
export LC_ALL
export LANG

SYSTEMD_DIR="/etc/systemd/system"

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

line() {
    echo -e "  ${DARK}────────────────────────────────────────────────────────────────────────────${RESET}"
}

success() {
    echo -e "  ${GREEN}✔${RESET} $1"
}

error_msg() {
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

# ============================================================
# ROOT
# ============================================================

require_root() {

    if [[ "${EUID}" -ne 0 ]]; then
        error_msg "Este script debe ejecutarse como root."
        exit 1
    fi
}

# ============================================================
# COMPROBAR DEPENDENCIAS
# ============================================================

check_dependencies() {

    local missing=0

    if ! command -v systemctl >/dev/null 2>&1; then
        error_msg "No se encontró systemctl."
        missing=1
    fi

    if ! command -v ss >/dev/null 2>&1; then
        error_msg "No se encontró ss."
        missing=1
    fi

    if (( missing != 0 )); then
        echo
        error_msg "Faltan dependencias necesarias."
        exit 1
    fi
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
            -name 'hcr-server-*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

    } |
    sort -u
}

# ============================================================
# RUTA DE LA UNIDAD
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

    echo ""
}

# ============================================================
# OBTENER PUERTO HCR
# ============================================================

get_unit_listen_port() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        return 0
    fi

    grep -oE \
        -- '--listen[[:space:]]+:[0-9]+' \
        "$path" \
        2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 ||
        true
}

# ============================================================
# OBTENER PUERTO DESTINO
# ============================================================

get_unit_target_port() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        return 0
    fi

    grep -oE \
        -- '--target[[:space:]]+127\.0\.0\.1:[0-9]+' \
        "$path" \
        2>/dev/null |
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
        "$path" \
        2>/dev/null |
        awk '{print $2}' |
        head -n1 ||
        true
}

# ============================================================
# OBTENER MAX DOWNLOAD FRAME
# ============================================================

get_unit_frame() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "---"
        return
    fi

    grep -oE \
        -- '--max-download-frame[[:space:]]+[0-9]+' \
        "$path" \
        2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 ||
        true
}

# ============================================================
# OBTENER DOWNLOAD POLL TIMEOUT
# ============================================================

get_unit_timeout() {

    local path="$1"

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "---"
        return
    fi

    grep -oE \
        -- '--download-poll-timeout[[:space:]]+[0-9]+(ms|s|m|h)' \
        "$path" \
        2>/dev/null |
        grep -oE '[0-9]+(ms|s|m|h)$' |
        head -n1 ||
        true
}

# ============================================================
# ESTADO SYSTEMD
# ============================================================

get_unit_state() {

    local unit="$1"

    systemctl is-active "$unit" \
        2>/dev/null ||
        true
}

# ============================================================
# ESTADO ENABLED / DISABLED
# ============================================================

get_unit_enabled() {

    local unit="$1"

    systemctl is-enabled "$unit" \
        2>/dev/null ||
        true
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
                address = $4

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
# OBTENER PID
# ============================================================

get_unit_main_pid() {

    local unit="$1"

    systemctl show \
        --property=MainPID \
        --value \
        "$unit" \
        2>/dev/null |
        tr -d ' ' ||
        true
}

# ============================================================
# OBTENER PROCESO DEL PUERTO
# ============================================================

get_port_process() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 0

    ss -H -lntp 2>/dev/null |
        awk -v port="$port" '
            {
                address = $4
                sub(/^.*:/, "", address)

                if (address == port) {
                    print $0
                    exit
                }
            }
        '
}

# ============================================================
# ESTADO REAL DE LA INSTANCIA
# ============================================================

get_real_state() {

    local unit="$1"
    local path="$2"

    local systemd_state
    local port

    systemd_state="$(get_unit_state "$unit")"
    port="$(get_unit_listen_port "$path")"

    if [[ "$systemd_state" == "active" ]]; then

        if is_port_listening "$port"; then
            echo "ACTIVO"
        else
            echo "SIN ESCUCHA"
        fi

        return
    fi

    if [[ "$systemd_state" == "failed" ]]; then
        echo "ERROR"
        return
    fi

    if [[ "$systemd_state" == "activating" ]]; then
        echo "INICIANDO"
        return
    fi

    if [[ "$systemd_state" == "deactivating" ]]; then
        echo "DETENIENDO"
        return
    fi

    echo "DETENIDO"
}

# ============================================================
# MOSTRAR ESTADO VISUAL
# ============================================================

print_state() {

    local state="$1"

    case "$state" in

        ACTIVO)
            echo -e "${GREEN}● ACTIVO${RESET}"
            ;;

        SIN\ ESCUCHA)
            echo -e "${YELLOW}● SIN ESCUCHA${RESET}"
            ;;

        ERROR)
            echo -e "${RED}● ERROR${RESET}"
            ;;

        INICIANDO)
            echo -e "${CYAN}● INICIANDO${RESET}"
            ;;

        DETENIENDO)
            echo -e "${YELLOW}● DETENIENDO${RESET}"
            ;;

        *)
            echo -e "${GRAY}● DETENIDO${RESET}"
            ;;

    esac
}

# ============================================================
# CONTADORES
# ============================================================

TOTAL_INSTANCES=0
ACTIVE_INSTANCES=0
LISTENING_PORTS=0
STOPPED_INSTANCES=0
ERROR_INSTANCES=0

# ============================================================
# MOSTRAR TABLA
# ============================================================

show_status() {

    local units

    units="$(get_hcr_units)"

    TOTAL_INSTANCES=0
    ACTIVE_INSTANCES=0
    LISTENING_PORTS=0
    STOPPED_INSTANCES=0
    ERROR_INSTANCES=0

    echo -e "  ${BOLD}${WHITE}ESTADO DE PUERTOS HCR SERVER${RESET}"
    echo -e "  ${GRAY}Comprobación independiente de las instancias HCR.${RESET}"
    echo

    if [[ -z "$units" ]]; then

        warning "No se detectaron instancias HCR Server."
        echo

        return 0
    fi

    printf "  ${GRAY}%-3s %-16s %-9s %-11s %-16s %-10s %-10s %-10s${RESET}\n" \
        "#" \
        "INSTANCIA" \
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

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        index=$((index + 1))
        TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))

        path="$(get_unit_path "$unit")"

        port="$(get_unit_listen_port "$path")"
        target="$(get_unit_target_port "$path")"
        frame="$(get_unit_frame "$path")"
        timeout="$(get_unit_timeout "$path")"
        transport="$(get_unit_transport "$path")"

        state="$(get_real_state "$unit" "$path")"

        case "$state" in

            ACTIVO)
                ACTIVE_INSTANCES=$((ACTIVE_INSTANCES + 1))
                LISTENING_PORTS=$((LISTENING_PORTS + 1))
                ;;

            SIN\ ESCUCHA)
                ACTIVE_INSTANCES=$((ACTIVE_INSTANCES + 1))
                ;;

            ERROR)
                ERROR_INSTANCES=$((ERROR_INSTANCES + 1))
                ;;

            DETENIDO)
                STOPPED_INSTANCES=$((STOPPED_INSTANCES + 1))
                ;;

        esac

        printf "  ${CYAN}%-3s${RESET} " "$index"
        printf "${WHITE}%-16s${RESET} " "${unit%.service}"
        printf "${WHITE}%-9s${RESET} " "${port:----}"
        printf "${WHITE}%-11s${RESET} " "${target:----}"

        printf "%-16b " "$(print_state "$state")"

        printf "${WHITE}%-10s${RESET} " "${frame:----}"
        printf "${WHITE}%-10s${RESET} " "${timeout:----}"
        printf "${WHITE}%-10s${RESET}\n" "${transport:----}"

    done <<< "$units"

    echo

    line

    echo
    echo -e "  ${BOLD}${WHITE}RESUMEN${RESET}"
    echo

    printf "  ${GRAY}Instancias detectadas:${RESET}    ${WHITE}%s${RESET}\n" \
        "$TOTAL_INSTANCES"

    printf "  ${GRAY}Instancias activas:${RESET}      ${GREEN}%s${RESET}\n" \
        "$ACTIVE_INSTANCES"

    printf "  ${GRAY}Puertos escuchando:${RESET}      ${GREEN}%s${RESET}\n" \
        "$LISTENING_PORTS"

    printf "  ${GRAY}Instancias detenidas:${RESET}    ${GRAY}%s${RESET}\n" \
        "$STOPPED_INSTANCES"

    printf "  ${GRAY}Instancias con error:${RESET}    ${RED}%s${RESET}\n" \
        "$ERROR_INSTANCES"

    echo

    line

    echo
    detail "ACTIVO = systemd activo + puerto realmente escuchando."
    detail "SIN ESCUCHA = systemd activo, pero el puerto configurado no escucha."
    detail "ERROR = systemd reporta estado failed."
    detail "DETENIDO = la instancia no está activa."
}

# ============================================================
# MOSTRAR DETALLE DE PUERTOS
# ============================================================

show_port_details() {

    local units

    units="$(get_hcr_units)"

    [[ -n "$units" ]] || return 0

    echo
    echo -e "  ${BOLD}${WHITE}DETALLE DE ESCUCHA${RESET}"
    echo

    local unit
    local path
    local port
    local process

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        path="$(get_unit_path "$unit")"
        port="$(get_unit_listen_port "$path")"

        [[ -n "$port" ]] || continue

        if is_port_listening "$port"; then

            process="$(get_port_process "$port")"

            success "${unit} → puerto ${port} escuchando"

            if [[ -n "$process" ]]; then
                detail "$process"
            fi

        else

            warning "${unit} → puerto ${port} NO está escuchando."

        fi

    done <<< "$units"
}

# ============================================================
# HEADER
# ============================================================

header() {

    clear_screen

    echo
    echo -e "${CYAN}    ╭──────────────────────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}    │                                                              │${RESET}"
    echo -e "${CYAN}    │${BOLD}${WHITE}          H C R   S E R V E R${RESET}                              ${CYAN}│${RESET}"
    echo -e "${CYAN}    │${GRAY}             Estado de Puertos${RESET}                             ${CYAN}│${RESET}"
    echo -e "${CYAN}    │                                                              │${RESET}"
    echo -e "${CYAN}    ╰──────────────────────────────────────────────────────────────╯${RESET}"
    echo
}

# ============================================================
# ESPERA
# ============================================================

pause() {

    echo
    read -rp "  Presiona ENTER para actualizar..." _
}

# ============================================================
# MAIN
# ============================================================

main() {

    require_root
    check_dependencies

    while true; do

        header

        show_status

        echo

        show_port_details

        echo

        line

        echo
        echo -e "  ${CYAN}ENTER${RESET}  Actualizar estado"
        echo -e "  ${GRAY}0${RESET}      Salir"
        echo

        read -rp "  HCR / ESTADO › " option

        case "$option" in

            0|00|q|Q|exit|EXIT)

                echo
                echo -e "  ${CYAN}HCR${RESET} ${GRAY}›${RESET} ${WHITE}Cerrando monitor...${RESET}"
                echo

                exit 0
                ;;

            *)

                ;;

        esac

    done
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
