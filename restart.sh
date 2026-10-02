#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — REINICIADOR
# Reinicia y verifica el servicio hcr-server
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

SERVICE_NAME="hcr-server"

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

# ============================================================
# UTILIDADES VISUALES
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

line() {
    printf '%b\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"
}

header() {
    clear_screen

    printf '\n'
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — REINICIO                    ║${RESET}"
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}║              REINICIO DEL SERVICIO                       ║${RESET}"
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"
    printf '\n'
}

section() {
    printf '\n%b\n' "${BRIGHT_BLUE}${BOLD}${DIAMOND} $1${RESET}"
    line
}

success() {
    printf '%b\n' "${GREEN}${OK}${RESET} $1"
}

info() {
    printf '%b\n' "${CYAN}${ARROW}${RESET} $1"
}

warning() {
    printf '%b\n' "${YELLOW}${WARN}${RESET} $1"
}

error_message() {
    printf '%b\n' "${RED}${FAIL}${RESET} $1" >&2
}

detail() {
    printf '%b\n' "  ${DIM}${BULLET}${RESET} $1"
}

# ============================================================
# SPINNER
# ============================================================

spinner_start() {
    local message="$1"

    (
        local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local i=0

        while true; do
            printf '\r%b' "${BRIGHT_CYAN}${frames[$i]}${RESET} ${message}"
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
    command -v "$1" >/dev/null 2>&1 || \
        fail "No se encontró el comando requerido: $1"
}

validate_environment() {
    [[ "${EUID}" -eq 0 ]] || \
        fail "Este script debe ejecutarse como root."

    [[ "$(uname -s)" == "Linux" ]] || \
        fail "Este script solo funciona en Linux."

    require_command systemctl
    require_command sleep
}

# ============================================================
# VALIDACIÓN DEL SERVICIO
# ============================================================

validate_service() {
    section "VALIDANDO SERVICIO"

    if ! systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
        fail "El servicio ${SERVICE_NAME} no está instalado en systemd."
    fi

    success "Servicio encontrado."

    local fragment
    fragment="$(systemctl show \
        -p FragmentPath \
        --value \
        "${SERVICE_NAME}" 2>/dev/null || true)"

    if [[ -n "$fragment" ]]; then
        detail "Unidad: ${fragment}"
    fi
}

# ============================================================
# ESTADO ANTES DEL REINICIO
# ============================================================

show_current_status() {
    section "ESTADO ACTUAL"

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        success "El servicio está activo."
    else
        warning "El servicio no está activo actualmente."
    fi

    local enabled
    enabled="$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)"

    detail "Arranque: ${enabled:-desconocido}"
}

# ============================================================
# REINICIO
# ============================================================

restart_service() {
    section "REINICIANDO SERVICIO"

    spinner_start "Reiniciando ${SERVICE_NAME}..."

    if systemctl restart "${SERVICE_NAME}"; then
        spinner_stop
        success "Comando de reinicio ejecutado correctamente."
    else
        spinner_stop
        fail "systemd no pudo reiniciar ${SERVICE_NAME}."
    fi
}

# ============================================================
# ESPERA DE ARRANQUE
# ============================================================

wait_for_service() {
    section "VERIFICANDO ARRANQUE"

    local attempts=0
    local max_attempts=25

    spinner_start "Esperando a que ${SERVICE_NAME} quede activo..."

    while (( attempts < max_attempts )); do
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            spinner_stop
            success "El servicio está activo."
            return 0
        fi

        attempts=$((attempts + 1))
        sleep 0.2
    done

    spinner_stop

    error_message "El servicio no quedó activo después del reinicio."

    printf '\n'
    warning "Último estado registrado:"
    systemctl --no-pager --full status "${SERVICE_NAME}" 2>&1 || true

    return 1
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {
    printf '\n'

    line

    printf '%b\n' "${BRIGHT_GREEN}${BOLD}✔ REINICIO COMPLETADO${RESET}"

    printf '\n'

    detail "Servicio: ${SERVICE_NAME}"
    detail "Estado:   activo"

    printf '\n'

    printf '%b\n' "${DIM}HCR Server está ejecutándose nuevamente.${RESET}"

    line
    printf '\n'
}

# ============================================================
# MAIN
# ============================================================

main() {
    header

    validate_environment
    validate_service
    show_current_status

    restart_service
    wait_for_service

    show_summary
}

main "$@"
