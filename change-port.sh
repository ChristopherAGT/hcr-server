#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — CAMBIAR PUERTO
# Cambia el puerto de escucha del servicio hcr-server
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

BACKUP_PATH="${UNIT_PATH}.port-backup"

SPINNER_PID=""

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
CYAN="\033[36m"

BRIGHT_BLUE="\033[94m"
BRIGHT_CYAN="\033[96m"
BRIGHT_GREEN="\033[92m"
BRIGHT_WHITE="\033[97m"

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
# UTILIDADES
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
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — PUERTO                      ║${RESET}"
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}║              CAMBIO DE PUERTO                             ║${RESET}"
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

fail() {
    spinner_stop
    printf '\n'
    error_message "$1"
    exit 1
}

# ============================================================
# COMANDOS
# ============================================================

require_command() {
    command -v "$1" >/dev/null 2>&1 || \
        fail "No se encontró el comando requerido: $1"
}

# ============================================================
# VALIDACIÓN DEL ENTORNO
# ============================================================

validate_environment() {
    [[ "${EUID}" -eq 0 ]] || \
        fail "Este script debe ejecutarse como root."

    [[ "$(uname -s)" == "Linux" ]] || \
        fail "Este script solo funciona en Linux."

    require_command systemctl
    require_command sed
    require_command grep
    require_command cp
    require_command mv
    require_command sleep
}

# ============================================================
# VALIDAR SERVICIO
# ============================================================

validate_service() {
    section "VALIDANDO SERVICIO"

    if [[ ! -f "$UNIT_PATH" ]]; then
        fail "No existe la unidad:

${UNIT_PATH}"
    fi

    if ! systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
        fail "systemd no reconoce el servicio ${SERVICE_NAME}."
    fi

    success "Servicio encontrado."

    local current_port

    current_port="$(
        grep -oE -- '--listen[[:space:]]+:[0-9]+' "$UNIT_PATH" |
        grep -oE '[0-9]+$' |
        head -n1 || true
    )"

    if [[ -n "$current_port" ]]; then
        detail "Puerto actual: ${current_port}"
    else
        warning "No se pudo detectar automáticamente el puerto actual."
    fi
}

# ============================================================
# VALIDAR PUERTO
# ============================================================

validate_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || {
        error_message "El puerto debe ser un número."
        return 1
    }

    (( port >= 1 && port <= 65535 )) || {
        error_message "El puerto debe estar entre 1 y 65535."
        return 1
    }

    return 0
}

# ============================================================
# COMPROBAR SI EL PUERTO ESTÁ EN USO
# ============================================================

check_port_usage() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        if ss -ltnH 2>/dev/null | grep -Eq ":${port}([[:space:]]|$)"; then
            return 0
        fi
    fi

    return 1
}

# ============================================================
# OBTENER PUERTO ACTUAL
# ============================================================

get_current_port() {
    grep -oE -- '--listen[[:space:]]+:[0-9]+' "$UNIT_PATH" |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# SOLICITAR PUERTO
# ============================================================

ask_new_port() {
    local current_port
    current_port="$(get_current_port)"

    printf '\n'

    if [[ -n "$current_port" ]]; then
        info "Puerto actual: ${BRIGHT_WHITE}${current_port}${RESET}"
    fi

    while true; do
        printf '\n'
        read -r -p "➜ Ingresa el nuevo puerto: " NEW_PORT

        if ! validate_port "$NEW_PORT"; then
            continue
        fi

        if [[ "$NEW_PORT" == "$current_port" ]]; then
            warning "El nuevo puerto es igual al puerto actual."
            continue
        fi

        if check_port_usage "$NEW_PORT"; then
            warning "El puerto ${NEW_PORT} ya aparece en uso."

            read -r -p "¿Deseas utilizarlo de todos modos? [s/N]: " answer

            case "${answer,,}" in
                s|si|sí|y|yes)
                    ;;
                *)
                    continue
                    ;;
            esac
        fi

        break
    done
}

# ============================================================
# CONFIRMACIÓN
# ============================================================

confirm_change() {
    printf '\n'

    section "CONFIRMACIÓN"

    detail "Servicio:       ${SERVICE_NAME}"
    detail "Puerto anterior: ${CURRENT_PORT:-desconocido}"
    detail "Puerto nuevo:    ${NEW_PORT}"

    printf '\n'

    warning "El servicio será reiniciado para aplicar el nuevo puerto."

    printf '\n'

    read -r -p "¿Deseas continuar? [s/N]: " answer

    case "${answer,,}" in
        s|si|sí|y|yes)
            ;;
        *)
            printf '\n'
            info "Operación cancelada."
            exit 0
            ;;
    esac
}

# ============================================================
# COPIA DE SEGURIDAD
# ============================================================

create_backup() {
    section "CREANDO RESPALDO"

    spinner_start "Creando respaldo de la unidad..."

    cp -f -- "$UNIT_PATH" "$BACKUP_PATH"

    spinner_stop

    success "Respaldo creado."

    detail "Backup: ${BACKUP_PATH}"
}

# ============================================================
# CAMBIAR PUERTO
# ============================================================

change_port() {
    section "CAMBIANDO PUERTO"

    spinner_start "Actualizando configuración..."

    sed -E \
        -i \
        "s#(--listen[[:space:]]+):[0-9]+#\1:${NEW_PORT}#g" \
        "$UNIT_PATH"

    spinner_stop

    # Verificar que realmente cambió.
    local verified_port
    verified_port="$(get_current_port)"

    if [[ "$verified_port" != "$NEW_PORT" ]]; then
        fail "No se pudo aplicar correctamente el nuevo puerto."
    fi

    success "Puerto actualizado."

    detail "Nuevo puerto: ${NEW_PORT}"
}

# ============================================================
# RECARGAR SYSTEMD
# ============================================================

reload_systemd() {
    section "RECARGANDO SYSTEMD"

    spinner_start "Recargando configuración..."

    systemctl daemon-reload

    spinner_stop

    success "Configuración de systemd recargada."
}

# ============================================================
# REINICIAR SERVICIO
# ============================================================

restart_service() {
    section "REINICIANDO SERVICIO"

    spinner_start "Reiniciando ${SERVICE_NAME}..."

    if systemctl restart "${SERVICE_NAME}"; then
        spinner_stop
        success "Servicio reiniciado."
    else
        spinner_stop

        warning "El servicio no pudo iniciar con la nueva configuración."
        warning "Intentando restaurar la configuración anterior..."

        restore_backup

        systemctl daemon-reload

        if systemctl restart "${SERVICE_NAME}"; then
            success "Configuración anterior restaurada."
            fail "No se pudo aplicar el puerto ${NEW_PORT}."
        else
            fail "No se pudo aplicar el nuevo puerto y tampoco fue posible restaurar correctamente el servicio."
        fi
    fi
}

# ============================================================
# RESTAURAR RESPALDO
# ============================================================

restore_backup() {
    if [[ -f "$BACKUP_PATH" ]]; then
        cp -f -- "$BACKUP_PATH" "$UNIT_PATH"
    fi
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_service() {
    section "VERIFICACIÓN FINAL"

    local active
    active="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"

    if [[ "$active" != "active" ]]; then
        error_message "El servicio no quedó activo."

        printf '\n'
        systemctl --no-pager --full status "${SERVICE_NAME}" 2>&1 || true

        return 1
    fi

    success "Servicio activo."

    local final_port
    final_port="$(get_current_port)"

    if [[ "$final_port" == "$NEW_PORT" ]]; then
        success "Puerto configurado correctamente: ${NEW_PORT}"
    else
        error_message "El puerto detectado no coincide con el solicitado."
        detail "Esperado: ${NEW_PORT}"
        detail "Detectado: ${final_port:-desconocido}"
        return 1
    fi
}

# ============================================================
# LIMPIAR RESPALDO
# ============================================================

remove_backup() {
    if [[ -f "$BACKUP_PATH" ]]; then
        rm -f -- "$BACKUP_PATH"
    fi
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {
    printf '\n'

    line

    printf '%b\n' "${BRIGHT_GREEN}${BOLD}✔ PUERTO CAMBIADO CORRECTAMENTE${RESET}"

    printf '\n'

    detail "Servicio: ${SERVICE_NAME}"
    detail "Anterior: ${CURRENT_PORT}"
    detail "Nuevo:    ${NEW_PORT}"
    detail "Estado:   activo"

    printf '\n'

    printf '%b\n' "${DIM}El nuevo puerto ya está aplicado al servicio.${RESET}"

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

    CURRENT_PORT="$(get_current_port)"

    ask_new_port
    confirm_change

    create_backup
    change_port
    reload_systemd
    restart_service
    verify_service

    remove_backup

    show_summary
}

main "$@"
