#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — REINICIADOR GLOBAL
# Reinicia y verifica TODAS las instancias HCR
# creadas por el instalador.
#
# Ejemplo:
#
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#
# Todas serán reiniciadas y verificadas.
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
        "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — REINICIO                    ║${RESET}"

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
    require_command sort
}

# ============================================================
# DESCUBRIR INSTANCIAS
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
        # Solamente aceptar:
        #
        # hcr-server-8080.service
        # hcr-server-8880.service
        # hcr-server-1443.service
        #
        # No aceptar:
        #
        # hcr-server.service
        # hcr-server-test.service
        # ----------------------------------------------------

        if [[ "${service}" =~ ^hcr-server-([0-9]+)$ ]]; then

            port="${BASH_REMATCH[1]}"

            # Validar rango TCP/UDP válido.
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

    # --------------------------------------------------------
    # Validar que exista al menos una instancia.
    # --------------------------------------------------------

    if [ "${#SERVICES[@]}" -eq 0 ]; then

        fail \
            "No se encontraron instancias HCR Server instaladas."

    fi
}

# ============================================================
# VALIDACIÓN DE INSTANCIAS
# ============================================================

validate_services() {

    local service
    local fragment
    local expected

    section "VALIDANDO INSTANCIAS"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"

        expected="${SYSTEMD_DIR}/${service}"

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

        if [[ -n "${fragment}" ]]; then

            detail \
                "${service}"

            detail \
                "Unidad: ${fragment}"

        else

            fail \
                "No se pudo determinar la unidad de ${service}."

        fi

    done

    printf '\n'

    success \
        "Se encontraron ${#SERVICES[@]} instancia(s) HCR."

    printf '\n'
}

# ============================================================
# MOSTRAR ESTADO ACTUAL
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
                "Puerto ${port}: servicio no está activo."

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
# REINICIAR TODAS LAS INSTANCIAS
# ============================================================

restart_services() {

    section "REINICIANDO INSTANCIAS"

    local service
    local port

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        spinner_start \
            "Reiniciando HCR Server en puerto ${port}..."

        if systemctl restart "${service}" >/dev/null 2>&1; then

            spinner_stop

            success \
                "Puerto ${port}: comando de reinicio ejecutado."

        else

            spinner_stop

            fail \
                "systemd no pudo reiniciar ${service}."

        fi

    done
}

# ============================================================
# ESPERAR Y VERIFICAR TODAS
# ============================================================

wait_for_services() {

    section "VERIFICANDO ARRANQUE"

    local attempts
    local max_attempts=50

    local all_active
    local service
    local port

    attempts=0

    spinner_start \
        "Esperando a que todas las instancias queden activas..."

    while (( attempts < max_attempts )); do

        all_active=true

        for service in "${SERVICES[@]}"; do

            if ! systemctl is-active --quiet "${service}"; then

                all_active=false

                break

            fi

        done

        if [ "${all_active}" = true ]; then

            spinner_stop

            success \
                "Todas las instancias están activas."

            return 0

        fi

        attempts=$((attempts + 1))

        sleep 0.2

    done

    spinner_stop

    error_message \
        "No todas las instancias quedaron activas."

    return 1
}

# ============================================================
# VERIFICACIÓN INDIVIDUAL
# ============================================================

verify_services() {

    section "VERIFICACIÓN FINAL"

    local service
    local port
    local pid
    local state
    local failures=0

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        state="$(
            systemctl is-active \
                "${service}" \
                2>/dev/null ||
                true
        )"

        if [ "${state}" = "active" ]; then

            pid="$(
                systemctl show \
                    -p MainPID \
                    --value \
                    "${service}" \
                    2>/dev/null ||
                    true
            )"

            success \
                "Puerto ${port}: ACTIVO."

            detail \
                "Servicio: ${service}"

            detail \
                "PID: ${pid:-desconocido}"

        else

            error_message \
                "Puerto ${port}: ${state:-desconocido}."

            detail \
                "Servicio: ${service}"

            failures=$((failures + 1))

        fi

    done

    printf '\n'

    if [ "${failures}" -gt 0 ]; then

        error_message \
            "${failures} instancia(s) no quedaron activas."

        return 1

    fi

    return 0
}

# ============================================================
# DIAGNÓSTICO DE FALLAS
# ============================================================

show_failed_diagnostics() {

    local service
    local port

    printf '\n'

    section "DIAGNÓSTICO"

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        port="${PORTS[$i]}"

        if ! systemctl is-active --quiet "${service}"; then

            printf '\n'

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

        fi

    done
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {

    printf '\n'

    line

    printf '%b\n' \
        "${BRIGHT_GREEN}${BOLD}✔ REINICIO COMPLETADO${RESET}"

    printf '\n'

    detail \
        "Instancias reiniciadas: ${#SERVICES[@]}"

    for i in "${!SERVICES[@]}"; do

        detail \
            "Puerto ${PORTS[$i]} → ${SERVICES[$i]} → ACTIVO"

    done

    printf '\n'

    printf '%b\n' \
        "${DIM}Todas las instancias HCR Server están ejecutándose nuevamente.${RESET}"

    line

    printf '\n'
}

# ============================================================
# MAIN
# ============================================================

main() {

    header

    validate_environment

    discover_services

    validate_services

    show_current_status

    restart_services

    if ! wait_for_services; then

        show_failed_diagnostics

        fail \
            "El reinicio no pudo completarse correctamente."

    fi

    if ! verify_services; then

        show_failed_diagnostics

        fail \
            "Una o más instancias HCR no están activas."

    fi

    show_summary
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
