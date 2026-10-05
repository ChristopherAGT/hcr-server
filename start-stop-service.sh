#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — SERVICE CONTROL ENGINE
# Inicia o detiene TODAS las instancias HCR
# creadas por el instalador.
#
# USO:
#
#   hcr-service-control.sh start
#   hcr-service-control.sh stop
#
# EJEMPLO:
#
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#
# Todas las instancias serán controladas.
#
# ESTE SCRIPT:
#
#   - NO tiene menú.
#   - NO modifica unidades systemd.
#   - NO habilita servicios.
#   - NO deshabilita servicios.
#   - NO modifica puertos.
#   - NO modifica configuración.
#   - NO modifica el binario.
#   - NO desinstala HCR.
#
# Está diseñado para ser ejecutado por el panel principal.
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

export PATH LC_ALL LANG

# ============================================================
# CONFIGURACIÓN
# ============================================================

SERVICE_PREFIX="hcr-server-"
SYSTEMD_DIR="/etc/systemd/system"

# ============================================================
# COLORES
# ============================================================

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"

BRIGHT_CYAN="\033[96m"
BRIGHT_GREEN="\033[92m"
BRIGHT_WHITE="\033[97m"
BRIGHT_BLUE="\033[94m"

# ============================================================
# ICONOS
# ============================================================

OK="✔"
FAIL="✖"
ARROW="➜"
BULLET="•"
WARN="!"
DIAMOND="◆"

# ============================================================
# VARIABLES
# ============================================================

SPINNER_PID=""

SERVICES=()
PORTS=()

FAILED_SERVICES=()

ACTION=""

# ============================================================
# UTILIDADES VISUALES
# ============================================================

clear_screen() {

    clear 2>/dev/null || true
}

line() {

    printf '%b\n' \
        "${DIM}────────────────────────────────────────────────────────────${RESET}"
}

header() {

    clear_screen

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — CONTROL                     ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║              TODAS LAS INSTANCIAS                        ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

    printf '\n'
}

section() {

    printf '\n%b\n' \
        "${BRIGHT_BLUE}${BOLD}${DIAMOND} $1${RESET}"

    line
}

success() {

    printf '%b\n' \
        "${GREEN}${OK}${RESET} $1"
}

info() {

    printf '%b\n' \
        "${CYAN}${ARROW}${RESET} $1"
}

warning() {

    printf '%b\n' \
        "${YELLOW}${WARN}${RESET} $1"
}

error_message() {

    printf '%b\n' \
        "${RED}${FAIL}${RESET} $1" >&2
}

detail() {

    printf '%b\n' \
        "  ${DIM}${BULLET}${RESET} $1"
}

# ============================================================
# SPINNER
# ============================================================

spinner_start() {

    local message="$1"

    (
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

            printf '\r%b' \
                "${BRIGHT_CYAN}${frames[$i]}${RESET} ${message}"

            i=$(( (i + 1) % ${#frames[@]} ))

            sleep 0.08

        done

    ) &

    SPINNER_PID=$!
}

spinner_stop() {

    if [[ -n "${SPINNER_PID}" ]]; then

        kill "${SPINNER_PID}" 2>/dev/null || true

        wait "${SPINNER_PID}" 2>/dev/null || true

        SPINNER_PID=""

        printf '\r\033[K'

    fi
}

# ============================================================
# ERROR
# ============================================================

fail() {

    spinner_stop

    printf '\n'

    error_message "$1"

    exit 1
}

# ============================================================
# VALIDACIÓN DEL ENTORNO
# ============================================================

require_command() {

    command -v "$1" >/dev/null 2>&1 ||
        fail \
            "No se encontró el comando requerido: $1"
}

validate_environment() {

    [[ "${EUID}" -eq 0 ]] ||
        fail \
            "Este script debe ejecutarse como root."

    [[ "$(uname -s)" == "Linux" ]] ||
        fail \
            "Este script solo funciona en Linux."

    require_command systemctl
    require_command sleep
    require_command find
    require_command grep
    require_command sort

    [ -d "${SYSTEMD_DIR}" ] ||
        fail \
            "No existe el directorio de systemd."
}

# ============================================================
# DESCUBRIR INSTANCIAS HCR
# ============================================================

discover_services() {

    SERVICES=()
    PORTS=()

    local file
    local service
    local port

    while IFS= read -r file; do

        [ -n "${file}" ] || continue

        service="${file%.service}"

        # ----------------------------------------------------
        # SOLAMENTE:
        #
        # hcr-server-8080.service
        # hcr-server-8880.service
        # hcr-server-1443.service
        #
        # NO:
        #
        # hcr-server.service
        # hcr-server-test.service
        # ----------------------------------------------------

        if [[ "${service}" =~ ^hcr-server-([0-9]+)$ ]]; then

            port="${BASH_REMATCH[1]}"

            if (( port >= 1 && port <= 65535 )); then

                SERVICES+=("${file}")
                PORTS+=("${port}")

            fi

        fi

    done < <(
        find "${SYSTEMD_DIR}" \
            -maxdepth 1 \
            \( -type f -o -type l \) \
            -name "${SERVICE_PREFIX}*.service" \
            -printf '%f\n' \
            2>/dev/null |
            sort -V
    )

    [ "${#SERVICES[@]}" -gt 0 ] ||
        fail \
            "No se encontraron instancias HCR Server instaladas."
}

# ============================================================
# VALIDAR INSTANCIAS
# ============================================================

validate_services() {

    local service
    local fragment

    section "VALIDANDO INSTANCIAS"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"

        if ! systemctl cat "${service}" >/dev/null 2>&1; then

            fail \
                "La unidad ${service} no puede ser cargada por systemd."

        fi

        fragment="$(
            systemctl show \
                -p FragmentPath \
                --value \
                "${service}" \
                2>/dev/null ||
                true
        )"

        detail \
            "Puerto ${PORTS[$i]} → ${service}"

        if [[ -n "${fragment}" ]]; then

            detail \
                "Unidad: ${fragment}"

        fi

    done

    printf '\n'

    success \
        "Se encontraron ${#SERVICES[@]} instancia(s) HCR."

    printf '\n'
}

# ============================================================
# ESTADO ACTUAL
# ============================================================

show_current_status() {

    section "ESTADO ACTUAL"

    local service
    local port
    local enabled

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        if systemctl is-active --quiet "${service}"; then

            success \
                "Puerto ${port}: servicio activo."

        else

            warning \
                "Puerto ${port}: servicio detenido o inactivo."

        fi

        enabled="$(
            systemctl is-enabled \
                "${service}" \
                2>/dev/null ||
                true
        )"

        detail \
            "Arranque automático: ${enabled:-desconocido}"

    done
}

# ============================================================
# INICIAR TODAS LAS INSTANCIAS
# ============================================================

start_all() {

    local service
    local port
    local failures=0

    FAILED_SERVICES=()

    section "INICIANDO INSTANCIAS"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        spinner_start \
            "Iniciando HCR Server en puerto ${port}..."

        if systemctl start "${service}" >/dev/null 2>&1; then

            spinner_stop

            if systemctl is-active --quiet "${service}"; then

                success \
                    "Puerto ${port}: servicio iniciado correctamente."

            else

                error_message \
                    "Puerto ${port}: el servicio no quedó activo."

                FAILED_SERVICES+=("${service}")

                failures=$((failures + 1))

            fi

        else

            spinner_stop

            error_message \
                "Puerto ${port}: no se pudo iniciar ${service}."

            FAILED_SERVICES+=("${service}")

            failures=$((failures + 1))

        fi

    done

    printf '\n'

    if [ "${failures}" -gt 0 ]; then

        error_message \
            "${failures} instancia(s) no pudieron iniciarse."

        return 1

    fi

    success \
        "Todas las instancias HCR fueron iniciadas."

    return 0
}

# ============================================================
# DETENER TODAS LAS INSTANCIAS
# ============================================================

stop_all() {

    local service
    local port
    local failures=0

    FAILED_SERVICES=()

    section "DETENIENDO INSTANCIAS"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        spinner_start \
            "Deteniendo HCR Server en puerto ${port}..."

        if systemctl stop "${service}" >/dev/null 2>&1; then

            spinner_stop

            if ! systemctl is-active --quiet "${service}"; then

                success \
                    "Puerto ${port}: servicio detenido correctamente."

            else

                error_message \
                    "Puerto ${port}: el servicio continúa activo."

                FAILED_SERVICES+=("${service}")

                failures=$((failures + 1))

            fi

        else

            spinner_stop

            error_message \
                "Puerto ${port}: no se pudo detener ${service}."

            FAILED_SERVICES+=("${service}")

            failures=$((failures + 1))

        fi

    done

    printf '\n'

    if [ "${failures}" -gt 0 ]; then

        error_message \
            "${failures} instancia(s) no pudieron detenerse."

        return 1

    fi

    success \
        "Todas las instancias HCR fueron detenidas."

    return 0
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_final_state() {

    local service
    local port
    local failures=0

    section "VERIFICACIÓN FINAL"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        if [ "${ACTION}" = "start" ]; then

            if systemctl is-active --quiet "${service}"; then

                success \
                    "Puerto ${port}: ACTIVO."

            else

                error_message \
                    "Puerto ${port}: NO está activo."

                failures=$((failures + 1))

            fi

        else

            if systemctl is-active --quiet "${service}"; then

                error_message \
                    "Puerto ${port}: continúa ACTIVO."

                failures=$((failures + 1))

            else

                success \
                    "Puerto ${port}: DETENIDO."

            fi

        fi

    done

    return "${failures}"
}

# ============================================================
# DIAGNÓSTICO
# ============================================================

show_failed_diagnostics() {

    local service
    local port

    printf '\n'

    section "DIAGNÓSTICO"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        if [ "${ACTION}" = "start" ]; then

            if ! systemctl is-active --quiet "${service}"; then

                warning \
                    "Diagnóstico del puerto ${port}"

                printf '\n'

                systemctl \
                    --no-pager \
                    --full \
                    status \
                    "${service}" \
                    2>&1 ||
                    true

                printf '\n'

            fi

        else

            if systemctl is-active --quiet "${service}"; then

                warning \
                    "El puerto ${port} continúa activo."

                detail \
                    "Servicio: ${service}"

                printf '\n'

            fi

        fi

    done
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {

    printf '\n'

    line

    if [ "${ACTION}" = "start" ]; then

        printf '%b\n' \
            "${BRIGHT_GREEN}${BOLD}✔ HCR SERVER INICIADO${RESET}"

        printf '\n'

        detail \
            "Instancias iniciadas: ${#SERVICES[@]}"

        for i in "${!SERVICES[@]}"; do

            detail \
                "Puerto ${PORTS[$i]} → ${SERVICES[$i]} → ACTIVO"

        done

        printf '\n'

        printf '%b\n' \
            "${DIM}Todas las instancias HCR Server están ejecutándose.${RESET}"

    else

        printf '%b\n' \
            "${BRIGHT_GREEN}${BOLD}✔ HCR SERVER DETENIDO${RESET}"

        printf '\n'

        detail \
            "Instancias detenidas: ${#SERVICES[@]}"

        for i in "${!SERVICES[@]}"; do

            detail \
                "Puerto ${PORTS[$i]} → ${SERVICES[$i]} → DETENIDO"

        done

        printf '\n'

        printf '%b\n' \
            "${DIM}Todas las instancias HCR Server están detenidas.${RESET}"

    fi

    line

    printf '\n'
}

# ============================================================
# MAIN
# ============================================================

main() {

    ACTION="${1:-}"

    case "${ACTION}" in

        start)
            ;;

        stop)
            ;;

        *)
            printf '%b\n' \
                "${RED}${FAIL}${RESET} Uso: $0 {start|stop}" >&2

            exit 1

            ;;

    esac

    header

    validate_environment

    discover_services

    validate_services

    show_current_status

    if [ "${ACTION}" = "start" ]; then

        if ! start_all; then

            show_failed_diagnostics

            fail \
                "No todas las instancias HCR pudieron iniciarse."

        fi

    else

        if ! stop_all; then

            show_failed_diagnostics

            fail \
                "No todas las instancias HCR pudieron detenerse."

        fi

    fi

    if ! verify_final_state; then

        show_failed_diagnostics

        fail \
            "La verificación final detectó instancias en un estado incorrecto."

    fi

    show_summary
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
