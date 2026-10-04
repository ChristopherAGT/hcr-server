#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — CAMBIAR PUERTO
# Cambia el puerto de escucha y el puerto destino
# del servicio hcr-server
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

BACKUP_PATH="${UNIT_PATH}.port-backup"

SPINNER_PID=""

# ============================================================
# VARIABLES
# ============================================================

CURRENT_PORT=""
CURRENT_TARGET_PORT=""

NEW_PORT=""
NEW_TARGET_PORT=""

PORT_TYPE=""

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
    printf '%b\n' \
        "${DIM}────────────────────────────────────────────────────────────${RESET}"
}

header() {
    clear_screen

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — PUERTO                      ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║              CAMBIO DE PUERTO                             ║${RESET}"

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
        local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
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
    require_command rm
    require_command sleep
    require_command ss
    require_command awk
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
    local current_target

    current_port="$(get_current_port)"
    current_target="$(get_current_target_port)"

    if [[ -n "$current_port" ]]; then
        detail "Puerto HCR actual: ${current_port}"
    else
        warning "No se pudo detectar automáticamente el puerto HCR actual."
    fi

    if [[ -n "$current_target" ]]; then
        detail "Puerto destino actual: ${current_target}"
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

    if ss -ltnH 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(:|\\])${port}$"; then

        return 0
    fi

    return 1
}

# ============================================================
# OBTENER PUERTO HCR ACTUAL
# ============================================================

get_current_port() {
    grep -oE \
        -- '--listen[[:space:]]+:[0-9]+' \
        "$UNIT_PATH" |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# OBTENER PUERTO DESTINO ACTUAL
# ============================================================

get_current_target_port() {
    grep -oE \
        -- '--target[[:space:]]+127\.0\.0\.1:[0-9]+' \
        "$UNIT_PATH" |
        grep -oE '[0-9]+$' |
        head -n1 || true
}

# ============================================================
# VERIFICAR SI UN PUERTO ES PRIVILEGIADO
# ============================================================

is_privileged_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    (( port >= 1 && port <= 1023 ))
}

# ============================================================
# CONFIGURAR CAPACIDAD PARA PUERTOS PRIVILEGIADOS
# ============================================================

configure_bind_capability() {
    local port="$1"

    # --------------------------------------------------------
    # El puerto destino NO necesita esta capacidad.
    # Solamente se aplica al puerto de escucha HCR.
    # --------------------------------------------------------

    if ! is_privileged_port "$port"; then

        # ----------------------------------------------------
        # Si existe una capacidad específica de bind,
        # se elimina para conservar la configuración mínima.
        # ----------------------------------------------------

        sed -E \
            -i \
            '/^[[:space:]]*CapabilityBoundingSet=CAP_NET_BIND_SERVICE[[:space:]]*$/d' \
            "$UNIT_PATH"

        sed -E \
            -i \
            '/^[[:space:]]*AmbientCapabilities=CAP_NET_BIND_SERVICE[[:space:]]*$/d' \
            "$UNIT_PATH"

        return 0
    fi

    # --------------------------------------------------------
    # PUERTO PRIVILEGIADO
    #
    # CAP_NET_BIND_SERVICE permite a HCR Server abrir
    # puertos inferiores a 1024, como 80 y 443.
    # --------------------------------------------------------

    if grep -Eq \
        '^[[:space:]]*CapabilityBoundingSet=' \
        "$UNIT_PATH"; then

        sed -E \
            -i \
            's#^[[:space:]]*CapabilityBoundingSet=.*$#CapabilityBoundingSet=CAP_NET_BIND_SERVICE#' \
            "$UNIT_PATH"

    else

        sed -E \
            -i \
            '/^\[Service\]/a CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
            "$UNIT_PATH"

    fi

    if grep -Eq \
        '^[[:space:]]*AmbientCapabilities=' \
        "$UNIT_PATH"; then

        sed -E \
            -i \
            's#^[[:space:]]*AmbientCapabilities=.*$#AmbientCapabilities=CAP_NET_BIND_SERVICE#' \
            "$UNIT_PATH"

    else

        sed -E \
            -i \
            '/^\[Service\]/a AmbientCapabilities=CAP_NET_BIND_SERVICE' \
            "$UNIT_PATH"

    fi

    # --------------------------------------------------------
    # VERIFICACIÓN
    # --------------------------------------------------------

    if ! grep -Eq \
        '^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$' \
        "$UNIT_PATH"; then

        fail \
            "No se pudo configurar CAP_NET_BIND_SERVICE en systemd."
    fi

    if ! grep -Eq \
        '^AmbientCapabilities=CAP_NET_BIND_SERVICE$' \
        "$UNIT_PATH"; then

        fail \
            "No se pudo configurar AmbientCapabilities para HCR Server."
    fi
}

# ============================================================
# MENÚ DE PUERTOS
# ============================================================

select_port_type() {
    while true; do

        section "SELECCIONAR PUERTO"

        local current_port
        local current_target

        current_port="$(get_current_port)"
        current_target="$(get_current_target_port)"

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}1)${RESET} Cambiar puerto HCR"

        detail \
            "Puerto de escucha: ${current_port:-desconocido}"

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}2)${RESET} Cambiar puerto destino"

        detail \
            "Puerto destino: ${current_target:-desconocido}"

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}3)${RESET} Salir"

        printf '\n'

        read -r -p \
            "➜ Selecciona una opción [1-3]: " PORT_OPTION

        case "${PORT_OPTION}" in

            1)
                PORT_TYPE="hcr"
                return 0
                ;;

            2)
                PORT_TYPE="target"
                return 0
                ;;

            3)
                printf '\n'
                info "Operación cancelada."
                exit 0
                ;;

            *)
                error_message \
                    "Opción no válida. Debe seleccionar 1, 2 o 3."
                ;;

        esac
    done
}

# ============================================================
# SOLICITAR PUERTO HCR
# ============================================================

ask_hcr_port() {
    local current_port

    current_port="$(get_current_port)"

    printf '\n'

    if [[ -n "$current_port" ]]; then
        info \
            "Puerto HCR actual: ${BRIGHT_WHITE}${current_port}${RESET}"
    fi

    while true; do

        printf '\n'

        read -r -p \
            "➜ Ingresa el nuevo puerto HCR: " NEW_PORT

        # ----------------------------------------------------
        # Validación numérica y rango
        # ----------------------------------------------------

        if ! validate_port "$NEW_PORT"; then
            continue
        fi

        # ----------------------------------------------------
        # Si es el mismo puerto actual:
        # NO se considera conflicto.
        # ----------------------------------------------------

        if [[ "$NEW_PORT" == "$current_port" ]]; then

            info \
                "El puerto ${NEW_PORT} ya está configurado para HCR Server."

            info \
                "Se reiniciará el servicio para aplicar/verificar la configuración."

            return 0
        fi

        # ----------------------------------------------------
        # Si es diferente, debe estar libre.
        # ----------------------------------------------------

        if check_port_usage "$NEW_PORT"; then

            warning \
                "El puerto ${NEW_PORT} ya está siendo utilizado por otro servicio."

            warning \
                "Selecciona otro puerto."

            continue
        fi

        success \
            "El puerto ${NEW_PORT} está disponible."

        break
    done
}

# ============================================================
# SOLICITAR PUERTO DESTINO
# ============================================================

ask_target_port() {
    local current_target

    current_target="$(get_current_target_port)"

    printf '\n'

    if [[ -n "$current_target" ]]; then
        info \
            "Puerto destino actual: ${BRIGHT_WHITE}${current_target}${RESET}"
    fi

    while true; do

        printf '\n'

        read -r -p \
            "➜ Ingresa el nuevo puerto destino: " NEW_PORT

        # ----------------------------------------------------
        # Validación numérica y rango
        # ----------------------------------------------------

        if ! validate_port "$NEW_PORT"; then
            continue
        fi

        # ----------------------------------------------------
        # Si es el mismo puerto destino:
        # no se considera conflicto.
        # ----------------------------------------------------

        if [[ "$NEW_PORT" == "$current_target" ]]; then

            info \
                "El puerto destino ${NEW_PORT} ya está configurado."

            info \
                "Se reiniciará el servicio para aplicar/verificar la configuración."

            return 0
        fi

        # ----------------------------------------------------
        # El puerto destino puede estar ocupado.
        #
        # Esto es NORMAL si precisamente existe un servicio
        # escuchando en ese puerto.
        # ----------------------------------------------------

        if check_port_usage "$NEW_PORT"; then

            success \
                "El puerto destino ${NEW_PORT} está siendo utilizado por un servicio."

            detail \
                "Esto es normal si el servicio destino está escuchando en este puerto."

        else

            warning \
                "No se detectó ningún servicio escuchando en el puerto ${NEW_PORT}."

            detail \
                "HCR podrá configurarse, pero debes asegurarte de que el servicio destino utilice este puerto."

        fi

        break
    done
}

# ============================================================
# SOLICITAR PUERTO
# ============================================================

ask_new_port() {
    case "${PORT_TYPE}" in

        hcr)
            ask_hcr_port
            ;;

        target)
            ask_target_port
            ;;

        *)
            fail "Tipo de puerto no válido."
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

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        detail \
            "Puerto HCR anterior: ${CURRENT_PORT:-desconocido}"

        detail \
            "Puerto HCR nuevo:    ${NEW_PORT}"

        if is_privileged_port "$NEW_PORT"; then

            detail \
                "Capacidad:           CAP_NET_BIND_SERVICE"

        fi

    else

        detail \
            "Puerto destino anterior: ${CURRENT_TARGET_PORT:-desconocido}"

        detail \
            "Puerto destino nuevo:    ${NEW_PORT}"

    fi

    printf '\n'

    warning \
        "El servicio será reiniciado para aplicar la configuración."

    printf '\n'

    read -r -p \
        "¿Deseas continuar? [s/N]: " answer

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

    spinner_start \
        "Creando respaldo de la unidad..."

    if cp -f -- "$UNIT_PATH" "$BACKUP_PATH"; then

        spinner_stop

    else

        spinner_stop

        fail \
            "No se pudo crear el respaldo de la unidad."

    fi

    success "Respaldo creado."

    detail \
        "Backup: ${BACKUP_PATH}"
}

# ============================================================
# CAMBIAR PUERTO
# ============================================================

change_port() {
    section "CAMBIANDO PUERTO"

    spinner_start \
        "Actualizando configuración..."

    # --------------------------------------------------------
    # PUERTO HCR
    # --------------------------------------------------------

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        if sed -E \
            -i \
            "s#(--listen[[:space:]]+):[0-9]+#\1:${NEW_PORT}#g" \
            "$UNIT_PATH"; then

            :

        else

            spinner_stop

            fail \
                "No se pudo actualizar el puerto HCR."

        fi

        # ----------------------------------------------------
        # CONFIGURAR CAPACIDAD PARA PUERTOS PRIVILEGIADOS
        # ----------------------------------------------------

        configure_bind_capability "$NEW_PORT"

    # --------------------------------------------------------
    # PUERTO DESTINO
    # --------------------------------------------------------

    elif [[ "${PORT_TYPE}" == "target" ]]; then

        if sed -E \
            -i \
            "s#(--target[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${NEW_PORT}#g" \
            "$UNIT_PATH"; then

            :

        else

            spinner_stop

            fail \
                "No se pudo actualizar el puerto destino."

        fi

    else

        spinner_stop

        fail \
            "Tipo de puerto no válido."

    fi

    spinner_stop

    # --------------------------------------------------------
    # VERIFICAR CAMBIO
    # --------------------------------------------------------

    local verified_port

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        verified_port="$(get_current_port)"

        if [[ "$verified_port" != "$NEW_PORT" ]]; then

            fail \
                "No se pudo aplicar correctamente el nuevo puerto HCR."

        fi

        success \
            "Puerto HCR actualizado."

        detail \
            "Nuevo puerto HCR: ${NEW_PORT}"

        # ----------------------------------------------------
        # INFORMAR CAPACIDAD
        # ----------------------------------------------------

        if is_privileged_port "$NEW_PORT"; then

            success \
                "CAP_NET_BIND_SERVICE configurada para el puerto ${NEW_PORT}."

        fi

    else

        verified_port="$(get_current_target_port)"

        if [[ "$verified_port" != "$NEW_PORT" ]]; then

            fail \
                "No se pudo aplicar correctamente el nuevo puerto destino."

        fi

        success \
            "Puerto destino actualizado."

        detail \
            "Nuevo puerto destino: ${NEW_PORT}"

    fi
}

# ============================================================
# RECARGAR SYSTEMD
# ============================================================

reload_systemd() {
    section "RECARGANDO SYSTEMD"

    spinner_start \
        "Recargando configuración..."

    if systemctl daemon-reload; then

        spinner_stop

    else

        spinner_stop

        fail \
            "No se pudo recargar la configuración de systemd."

    fi

    success \
        "Configuración de systemd recargada."
}

# ============================================================
# REINICIAR SERVICIO
# ============================================================

restart_service() {
    section "REINICIANDO SERVICIO"

    spinner_start \
        "Reiniciando ${SERVICE_NAME}..."

    if systemctl restart "${SERVICE_NAME}"; then

        spinner_stop

        success \
            "Servicio reiniciado."

    else

        spinner_stop

        warning \
            "El servicio no pudo iniciar con la nueva configuración."

        warning \
            "Intentando restaurar la configuración anterior..."

        restore_backup

        if ! systemctl daemon-reload; then

            fail \
                "No se pudo recargar systemd después de restaurar el respaldo."

        fi

        if systemctl restart "${SERVICE_NAME}"; then

            success \
                "Configuración anterior restaurada."

            fail \
                "No se pudo aplicar la nueva configuración."

        else

            fail \
                "No se pudo aplicar la nueva configuración y tampoco fue posible restaurar correctamente el servicio."

        fi
    fi
}

# ============================================================
# RESTAURAR RESPALDO
# ============================================================

restore_backup() {
    if [[ ! -f "$BACKUP_PATH" ]]; then

        fail \
            "No existe el respaldo necesario para restaurar la configuración."

    fi

    if ! cp -f -- "$BACKUP_PATH" "$UNIT_PATH"; then

        fail \
            "No se pudo restaurar la configuración anterior."

    fi
}

# ============================================================
# ESPERAR ESCUCHA DEL PUERTO HCR
# ============================================================

wait_for_hcr_listen() {
    local port="$1"
    local attempts=0
    local max_attempts=20

    while (( attempts < max_attempts )); do

        if check_port_usage "$port"; then
            return 0
        fi

        sleep 0.25

        attempts=$((attempts + 1))
    done

    return 1
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_service() {
    section "VERIFICACIÓN FINAL"

    local active

    active="$(
        systemctl is-active \
            "${SERVICE_NAME}" 2>/dev/null || true
    )"

    if [[ "$active" != "active" ]]; then

        error_message \
            "El servicio no quedó activo."

        printf '\n'

        systemctl \
            --no-pager \
            --full \
            status "${SERVICE_NAME}" 2>&1 || true

        return 1
    fi

    success \
        "Servicio activo."

    local final_port

    # --------------------------------------------------------
    # OBTENER PUERTO CONFIGURADO
    # --------------------------------------------------------

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        final_port="$(get_current_port)"

    else

        final_port="$(get_current_target_port)"

    fi

    # --------------------------------------------------------
    # VERIFICAR CONFIGURACIÓN
    # --------------------------------------------------------

    if [[ "$final_port" == "$NEW_PORT" ]]; then

        if [[ "${PORT_TYPE}" == "hcr" ]]; then

            success \
                "Puerto HCR configurado correctamente: ${NEW_PORT}"

        else

            success \
                "Puerto destino configurado correctamente: ${NEW_PORT}"

        fi

    else

        error_message \
            "El puerto detectado no coincide con el solicitado."

        detail \
            "Esperado: ${NEW_PORT}"

        detail \
            "Detectado: ${final_port:-desconocido}"

        return 1
    fi

    # --------------------------------------------------------
    # VERIFICAR CAPACIDAD PARA PUERTO PRIVILEGIADO
    # --------------------------------------------------------

    if [[ "${PORT_TYPE}" == "hcr" ]] &&
       is_privileged_port "$NEW_PORT"; then

        if ! systemctl cat "${SERVICE_NAME}" 2>/dev/null |
            grep -Eq \
                '^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$'; then

            error_message \
                "No se detectó CAP_NET_BIND_SERVICE en el servicio."

            return 1
        fi

        if ! systemctl cat "${SERVICE_NAME}" 2>/dev/null |
            grep -Eq \
                '^AmbientCapabilities=CAP_NET_BIND_SERVICE$'; then

            error_message \
                "No se detectó AmbientCapabilities=CAP_NET_BIND_SERVICE en el servicio."

            return 1
        fi

        success \
            "Permiso para puerto privilegiado verificado."

    fi

    # --------------------------------------------------------
    # VERIFICAR ESCUCHA DEL PUERTO HCR
    # --------------------------------------------------------

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        info \
            "Verificando escucha del puerto HCR..."

        if wait_for_hcr_listen "$NEW_PORT"; then

            success \
                "El puerto HCR ${NEW_PORT} está siendo utilizado por el servicio."

        else

            error_message \
                "El servicio está activo, pero no se detectó escucha en el puerto HCR ${NEW_PORT}."

            printf '\n'

            systemctl \
                --no-pager \
                --full \
                status "${SERVICE_NAME}" 2>&1 || true

            return 1
        fi

    # --------------------------------------------------------
    # VERIFICAR PUERTO DESTINO
    # --------------------------------------------------------

    else

        if check_port_usage "$NEW_PORT"; then

            success \
                "El puerto destino ${NEW_PORT} está siendo utilizado por un servicio."

        else

            warning \
                "No se detectó un servicio escuchando en el puerto destino ${NEW_PORT}."

            detail \
                "La configuración fue aplicada correctamente."

        fi
    fi
}

# ============================================================
# LIMPIAR RESPALDO
# ============================================================

remove_backup() {
    if [[ -f "$BACKUP_PATH" ]]; then

        if ! rm -f -- "$BACKUP_PATH"; then

            warning \
                "No se pudo eliminar el archivo de respaldo."

            detail \
                "Backup conservado: ${BACKUP_PATH}"

        fi
    fi
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {
    printf '\n'

    line

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        printf '%b\n' \
            "${BRIGHT_GREEN}${BOLD}✔ PUERTO HCR CONFIGURADO CORRECTAMENTE${RESET}"

    else

        printf '%b\n' \
            "${BRIGHT_GREEN}${BOLD}✔ PUERTO DESTINO CONFIGURADO CORRECTAMENTE${RESET}"

    fi

    printf '\n'

    detail \
        "Servicio: ${SERVICE_NAME}"

    if [[ "${PORT_TYPE}" == "hcr" ]]; then

        detail \
            "Anterior: ${CURRENT_PORT:-desconocido}"

        detail \
            "Nuevo:    ${NEW_PORT}"

        detail \
            "Tipo:     Puerto HCR"

        if is_privileged_port "$NEW_PORT"; then

            detail \
                "Permiso:  CAP_NET_BIND_SERVICE"

        fi

    else

        detail \
            "Anterior: ${CURRENT_TARGET_PORT:-desconocido}"

        detail \
            "Nuevo:    ${NEW_PORT}"

        detail \
            "Tipo:     Puerto destino"

    fi

    detail \
        "Estado:   activo"

    printf '\n'

    printf '%b\n' \
        "${DIM}La nueva configuración ya está aplicada al servicio.${RESET}"

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

    select_port_type

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
