#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — CAMBIAR PUERTO
# Cambia los puertos de escucha y destino del servicio hcr-server
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
# VARIABLES
# ============================================================

CURRENT_PORT=""
CURRENT_TARGET_PORT=""

NEW_PORT=""
NEW_TARGET_PORT=""

CHANGE_TYPE=""

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
    require_command ss
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
    local current_target_port

    current_port="$(get_current_port)"
    current_target_port="$(get_current_target_port)"

    if [[ -n "$current_port" ]]; then
        detail "Puerto HCR actual: ${current_port}"
    else
        warning "No se pudo detectar automáticamente el puerto HCR actual."
    fi

    if [[ -n "$current_target_port" ]]; then
        detail "Puerto destino actual: ${current_target_port}"
    else
        warning "No se pudo detectar automáticamente el puerto destino actual."
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

    if ss -lntH 2>/dev/null | \
        awk '{print $4}' | \
        grep -Eq "(:|\\])${port}$"; then
        return 0
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
# OBTENER PUERTO DESTINO ACTUAL
# ============================================================

get_current_target_port() {
    grep -oE -- '--target[[:space:]]+127\.0\.0\.1:[0-9]+' "$UNIT_PATH" |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

select_change_type() {
    section "SELECCIONAR CAMBIO"

    printf '\n'
    printf '%b\n' "${BRIGHT_WHITE}${BOLD}¿Qué puerto deseas cambiar?${RESET}"
    printf '\n'

    printf '  ${CYAN}1${RESET} ${WHITE}Puerto HCR${RESET} ${DIM}(puerto de escucha)${RESET}\n'
    printf '  ${CYAN}2${RESET} ${WHITE}Puerto destino${RESET} ${DIM}(puerto de redirección)${RESET}\n'

    printf '\n'

    while true; do
        read -r -p "➜ Selecciona una opción [1-2]: " CHANGE_TYPE

        case "${CHANGE_TYPE}" in
            1)
                CHANGE_TYPE="listen"
                break
                ;;
            2)
                CHANGE_TYPE="target"
                break
                ;;
            *)
                error_message "Opción no válida. Selecciona 1 o 2."
                ;;
        esac
    done
}

# ============================================================
# SOLICITAR PUERTO HCR
# ============================================================

ask_listen_port() {
    local current_port
    current_port="$(get_current_port)"

    printf '\n'

    if [[ -n "$current_port" ]]; then
        info "Puerto HCR actual: ${BRIGHT_WHITE}${current_port}${RESET}"
    fi

    while true; do
        printf '\n'
        read -r -p "➜ Ingresa el nuevo puerto HCR: " NEW_PORT

        if ! validate_port "$NEW_PORT"; then
            continue
        fi

        # Si es exactamente el puerto que ya tiene HCR,
        # no se considera conflicto. Se reiniciará el servicio.
        if [[ "$NEW_PORT" == "$current_port" ]]; then
            info "El puerto ${NEW_PORT} ya está configurado para HCR Server."
            info "Se reiniciará el servicio para aplicar/verificar la configuración."
            return 0
        fi

        # El puerto es diferente al actual.
        # Debe estar libre para poder utilizarlo.
        if check_port_usage "$NEW_PORT"; then
            warning "El puerto ${NEW_PORT} ya está siendo utilizado por otro servicio."
            warning "Selecciona otro puerto."

            continue
        fi

        break
    done
}

# ============================================================
# SOLICITAR PUERTO DESTINO
# ============================================================

ask_target_port() {
    local current_target_port
    current_target_port="$(get_current_target_port)"

    printf '\n'

    if [[ -n "$current_target_port" ]]; then
        info "Puerto destino actual: ${BRIGHT_WHITE}${current_target_port}${RESET}"
    fi

    while true; do
        printf '\n'
        read -r -p "➜ Ingresa el nuevo puerto destino: " NEW_TARGET_PORT

        if ! validate_port "$NEW_TARGET_PORT"; then
            continue
        fi

        if [[ "$NEW_TARGET_PORT" == "$current_target_port" ]]; then
            info "El puerto destino ${NEW_TARGET_PORT} ya está configurado."
            info "Se reiniciará el servicio para aplicar/verificar la configuración."
            return 0
        fi

        # El puerto destino representa el servicio al cual HCR
        # redirige el tráfico. Por eso NO se bloquea si está
        # escuchando otro servicio, ya que precisamente puede
        # ser el servicio destino esperado.
        break
    done
}

# ============================================================
# SOLICITAR PUERTO
# ============================================================

ask_new_port() {
    case "${CHANGE_TYPE}" in
        listen)
            ask_listen_port
            ;;
        target)
            ask_target_port
            ;;
        *)
            fail "Tipo de cambio de puerto no reconocido."
            ;;
    esac
}

# ============================================================
# CONFIRMACIÓN
# ============================================================

confirm_change() {
    printf '\n'

    section "CONFIRMACIÓN"

    detail "Servicio: ${SERVICE_NAME}"

    if [[ "${CHANGE_TYPE}" == "listen" ]]; then
        detail "Puerto HCR anterior: ${CURRENT_PORT:-desconocido}"
        detail "Puerto HCR nuevo:    ${NEW_PORT}"
    else
        detail "Puerto destino anterior: ${CURRENT_TARGET_PORT:-desconocido}"
        detail "Puerto destino nuevo:    ${NEW_TARGET_PORT}"
    fi

    printf '\n'

    warning "El servicio será reiniciado para aplicar la configuración."

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

    if cp -f -- "$UNIT_PATH" "$BACKUP_PATH"; then
        spinner_stop
    else
        spinner_stop
        fail "No se pudo crear el respaldo de la unidad."
    fi

    success "Respaldo creado."

    detail "Backup: ${BACKUP_PATH}"
}

# ============================================================
# CAMBIAR PUERTO
# ============================================================

change_port() {
    section "CAMBIANDO PUERTO"

    spinner_start "Actualizando configuración..."

    if [[ "${CHANGE_TYPE}" == "listen" ]]; then

        sed -E \
            -i \
            "s#(--listen[[:space:]]+):[0-9]+#\1:${NEW_PORT}#g" \
            "$UNIT_PATH"

    elif [[ "${CHANGE_TYPE}" == "target" ]]; then

        sed -E \
            -i \
            "s#(--target[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${NEW_TARGET_PORT}#g" \
            "$UNIT_PATH"

    else
        spinner_stop
        fail "Tipo de cambio de puerto no válido."
    fi

    spinner_stop

    # Verificar que realmente cambió.
    local verified_port

    if [[ "${CHANGE_TYPE}" == "listen" ]]; then

        verified_port="$(get_current_port)"

        if [[ "$verified_port" != "$NEW_PORT" ]]; then
            fail "No se pudo aplicar correctamente el nuevo puerto HCR."
        fi

        success "Puerto HCR actualizado."
        detail "Nuevo puerto: ${NEW_PORT}"

    else

        verified_port="$(get_current_target_port)"

        if [[ "$verified_port" != "$NEW_TARGET_PORT" ]]; then
            fail "No se pudo aplicar correctamente el nuevo puerto destino."
        fi

        success "Puerto destino actualizado."
        detail "Nuevo puerto: ${NEW_TARGET_PORT}"

    fi
}

# ============================================================
# RECARGAR SYSTEMD
# ============================================================

reload_systemd() {
    section "RECARGANDO SYSTEMD"

    spinner_start "Recargando configuración..."

    if systemctl daemon-reload; then
        spinner_stop
    else
        spinner_stop
        fail "No se pudo recargar la configuración de systemd."
    fi

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

        if ! systemctl daemon-reload; then
            fail "No se pudo recargar systemd después de restaurar el respaldo."
        fi

        if systemctl restart "${SERVICE_NAME}"; then
            success "Configuración anterior restaurada."
            fail "No se pudo aplicar la nueva configuración."
        else
            fail "No se pudo aplicar la nueva configuración y tampoco fue posible restaurar correctamente el servicio."
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
    local final_target_port

    final_port="$(get_current_port)"
    final_target_port="$(get_current_target_port)"

    # --------------------------------------------------------
    # Verificación puerto HCR
    # --------------------------------------------------------

    if [[ "$final_port" == "$CURRENT_PORT" ]] &&
        [[ "${CHANGE_TYPE}" == "target" ]]; then

        success "Puerto HCR sin cambios: ${final_port}"

    elif [[ "$final_port" == "$NEW_PORT" ]] &&
        [[ "${CHANGE_TYPE}" == "listen" ]]; then

        success "Puerto HCR configurado correctamente: ${NEW_PORT}"

    else

        error_message "El puerto HCR detectado no coincide con la configuración esperada."
        detail "Detectado: ${final_port:-desconocido}"

        return 1
    fi

    # --------------------------------------------------------
    # Verificación puerto destino
    # --------------------------------------------------------

    if [[ "$final_target_port" == "$CURRENT_TARGET_PORT" ]] &&
        [[ "${CHANGE_TYPE}" == "listen" ]]; then

        success "Puerto destino sin cambios: ${final_target_port}"

    elif [[ "$final_target_port" == "$NEW_TARGET_PORT" ]] &&
        [[ "${CHANGE_TYPE}" == "target" ]]; then

        success "Puerto destino configurado correctamente: ${NEW_TARGET_PORT}"

    else

        error_message "El puerto destino detectado no coincide con la configuración esperada."
        detail "Detectado: ${final_target_port:-desconocido}"

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

    printf '%b\n' "${BRIGHT_GREEN}${BOLD}✔ CONFIGURACIÓN CAMBIADA CORRECTAMENTE${RESET}"

    printf '\n'

    detail "Servicio: ${SERVICE_NAME}"

    if [[ "${CHANGE_TYPE}" == "listen" ]]; then
        detail "Puerto HCR anterior:     ${CURRENT_PORT}"
        detail "Puerto HCR nuevo:        ${NEW_PORT}"
        detail "Puerto destino:          ${CURRENT_TARGET_PORT}"
    else
        detail "Puerto HCR:              ${CURRENT_PORT}"
        detail "Puerto destino anterior: ${CURRENT_TARGET_PORT}"
        detail "Puerto destino nuevo:    ${NEW_TARGET_PORT}"
    fi

    detail "Estado:                   activo"

    printf '\n'

    printf '%b\n' "${DIM}La nueva configuración ya está aplicada al servicio.${RESET}"

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
    CURRENT_TARGET_PORT="$(get_current_target_port)"

    select_change_type

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
