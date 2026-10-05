#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — CAMBIAR PUERTO
# ============================================================
#
# Compatible con múltiples instancias:
#
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#
# Permite:
#
#   1. Cambiar puerto HCR
#      - Modifica --listen :PUERTO
#      - Renombra la unidad:
#          hcr-server-8080.service
#              ↓
#          hcr-server-8888.service
#
#   2. Cambiar puerto destino
#      - Modifica --target 127.0.0.1:PUERTO
#      - Mantiene el nombre de la instancia.
#
# La instancia NO se elimina ni se crea nuevamente.
# Se modifica la unidad existente.
#
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PREFIX="hcr-server"

SPINNER_PID=""

# ============================================================
# VARIABLES
# ============================================================

SELECTED_SERVICE=""
SELECTED_UNIT_PATH=""

CURRENT_PORT=""
CURRENT_TARGET_PORT=""

NEW_PORT=""
PORT_TYPE=""

OLD_SERVICE=""
OLD_UNIT_PATH=""
NEW_SERVICE=""
NEW_UNIT_PATH=""

BACKUP_PATH=""

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
    require_command mv
    require_command rm
    require_command sleep
    require_command ss
    require_command awk
    require_command sort
}

# ============================================================
# OBTENER INSTANCIAS HCR
# ============================================================

get_hcr_services() {

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
            -name 'hcr-server-[0-9]*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

    } |
    grep -E '^hcr-server(-[0-9]+)?\.service$' |
    sort -u
}

# ============================================================
# OBTENER RUTA DE UNA UNIDAD
# ============================================================

get_unit_path() {

    local service="$1"
    local path=""

    path="$(
        systemctl show \
            --property=FragmentPath \
            --value \
            "$service" \
            2>/dev/null ||
            true
    )"

    if [[ -n "$path" && -f "$path" ]]; then

        echo "$path"

        return 0
    fi

    if [[ -f "${SYSTEMD_DIR}/${service}" ]]; then

        echo "${SYSTEMD_DIR}/${service}"

        return 0
    fi

    echo ""
}

# ============================================================
# OBTENER PUERTO HCR
# ============================================================

get_service_port() {

    local path="$1"

    [[ -f "$path" ]] || return 0

    grep -oE \
        -- '--listen[[:space:]]+:[0-9]+' \
        "$path" 2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 ||
        true
}

# ============================================================
# OBTENER PUERTO DESTINO
# ============================================================

get_service_target_port() {

    local path="$1"

    [[ -f "$path" ]] || return 0

    grep -oE \
        -- '--target[[:space:]]+127\.0\.0\.1:[0-9]+' \
        "$path" 2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 ||
        true
}

# ============================================================
# COMPROBAR PUERTO ESCUCHANDO
# ============================================================

check_port_usage() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    ss -ltnH 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(:|\\])${port}$"
}

# ============================================================
# VALIDAR PUERTO
# ============================================================

validate_port() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || {

        error_message \
            "El puerto debe ser un número."

        return 1
    }

    (( port >= 1 && port <= 65535 )) || {

        error_message \
            "El puerto debe estar entre 1 y 65535."

        return 1
    }

    return 0
}

# ============================================================
# PUERTO PRIVILEGIADO
# ============================================================

is_privileged_port() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    (( port >= 1 && port <= 1023 ))
}

# ============================================================
# CONFIGURAR CAPACIDAD DE BIND
# ============================================================

configure_bind_capability() {

    local path="$1"
    local port="$2"

    [[ -f "$path" ]] || \
        fail "No existe la unidad seleccionada."

    # --------------------------------------------------------
    # Puerto NO privilegiado
    #
    # No necesitamos modificar la unidad.
    # Si ya tiene estas capacidades, no las eliminamos
    # automáticamente para evitar modificar configuraciones
    # que puedan haber sido agregadas por otro proceso.
    # --------------------------------------------------------

    if ! is_privileged_port "$port"; then
        return 0
    fi

    # --------------------------------------------------------
    # CAP_NET_BIND_SERVICE
    # --------------------------------------------------------

    if grep -Eq \
        '^[[:space:]]*CapabilityBoundingSet=' \
        "$path"; then

        if ! grep -Eq \
            '^[[:space:]]*CapabilityBoundingSet=.*CAP_NET_BIND_SERVICE' \
            "$path"; then

            sed -E \
                -i \
                's#^([[:space:]]*CapabilityBoundingSet=.*)$#\1 CAP_NET_BIND_SERVICE#' \
                "$path"
        fi

    else

        sed -E \
            -i \
            '/^\[Service\]/a CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
            "$path"

    fi

    if grep -Eq \
        '^[[:space:]]*AmbientCapabilities=' \
        "$path"; then

        if ! grep -Eq \
            '^[[:space:]]*AmbientCapabilities=.*CAP_NET_BIND_SERVICE' \
            "$path"; then

            sed -E \
                -i \
                's#^([[:space:]]*AmbientCapabilities=.*)$#\1 CAP_NET_BIND_SERVICE#' \
                "$path"
        fi

    else

        sed -E \
            -i \
            '/^\[Service\]/a AmbientCapabilities=CAP_NET_BIND_SERVICE' \
            "$path"

    fi
}

# ============================================================
# SELECCIONAR INSTANCIA
# ============================================================

select_service() {

    section "SELECCIONAR INSTANCIA HCR"

    local services
    local count=0
    local service
    local path
    local port
    local target
    local state

    services="$(get_hcr_services)"

    if [[ -z "$services" ]]; then

        fail \
            "No se encontraron instancias HCR Server."

    fi

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}INSTANCIAS DETECTADAS:${RESET}"

    printf '\n'

    while IFS= read -r service; do

        [[ -n "$service" ]] || continue

        count=$((count + 1))

        path="$(get_unit_path "$service")"

        port="$(get_service_port "$path")"

        target="$(get_service_target_port "$path")"

        state="$(
            systemctl is-active "$service" \
                2>/dev/null ||
                echo "inactive"
        )"

        if [[ "$state" == "active" ]]; then
            state="${BRIGHT_GREEN}ACTIVO${RESET}"
        else
            state="${YELLOW}${state^^}${RESET}"
        fi

        printf '%b\n' \
            "${BRIGHT_WHITE}${count})${RESET} ${CYAN}${service}${RESET}"

        detail \
            "Puerto HCR: ${port:-desconocido}"

        detail \
            "Puerto destino: ${target:-desconocido}"

        detail \
            "Estado: ${state}"

        printf '\n'

    done <<< "$services"

    printf '%b\n' \
        "${BRIGHT_WHITE}0)${RESET} Cancelar"

    printf '\n'

    while true; do

        read -r -p \
            "➜ Selecciona una instancia [0-${count}]: " option

        if [[ "$option" == "0" ]]; then

            info "Operación cancelada."

            exit 0
        fi

        if [[ "$option" =~ ^[0-9]+$ ]] &&
           (( option >= 1 && option <= count )); then

            local index=0

            while IFS= read -r service; do

                [[ -n "$service" ]] || continue

                index=$((index + 1))

                if (( index == option )); then

                    SELECTED_SERVICE="$service"

                    break
                fi

            done <<< "$services"

            break
        fi

        error_message \
            "Selección inválida."

    done

    SELECTED_UNIT_PATH="$(get_unit_path "$SELECTED_SERVICE")"

    if [[ -z "$SELECTED_UNIT_PATH" ||
          ! -f "$SELECTED_UNIT_PATH" ]]; then

        fail \
            "No se pudo localizar la unidad seleccionada."
    fi

    CURRENT_PORT="$(get_service_port "$SELECTED_UNIT_PATH")"

    CURRENT_TARGET_PORT="$(
        get_service_target_port "$SELECTED_UNIT_PATH"
    )"

    OLD_SERVICE="$SELECTED_SERVICE"
    OLD_UNIT_PATH="$SELECTED_UNIT_PATH"

    printf '\n'

    success \
        "Instancia seleccionada: ${SELECTED_SERVICE}"

    detail \
        "Puerto HCR actual: ${CURRENT_PORT:-desconocido}"

    detail \
        "Puerto destino actual: ${CURRENT_TARGET_PORT:-desconocido}"
}

# ============================================================
# SELECCIONAR QUÉ CAMBIAR
# ============================================================

select_port_type() {

    while true; do

        section "SELECCIONAR CAMBIO"

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}1)${RESET} Cambiar puerto HCR"

        detail \
            "Modifica --listen y renombra la instancia."

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}2)${RESET} Cambiar puerto destino"

        detail \
            "Modifica únicamente --target."

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}3)${RESET} Salir"

        printf '\n'

        read -r -p \
            "➜ Selecciona una opción [1-3]: " option

        case "$option" in

            1)
                PORT_TYPE="hcr"
                return 0
                ;;

            2)
                PORT_TYPE="target"
                return 0
                ;;

            3)
                info "Operación cancelada."
                exit 0
                ;;

            *)
                error_message \
                    "Opción no válida."
                ;;

        esac
    done
}

# ============================================================
# COMPROBAR SI EXISTE UNA UNIDAD
# ============================================================

service_exists() {

    local service="$1"

    [[ -f "${SYSTEMD_DIR}/${service}" ]] ||
        systemctl cat "$service" >/dev/null 2>&1
}

# ============================================================
# SOLICITAR NUEVO PUERTO HCR
# ============================================================

ask_hcr_port() {

    while true; do

        printf '\n'

        read -r -p \
            "➜ Nuevo puerto HCR [actual ${CURRENT_PORT:-desconocido}]: " NEW_PORT

        if ! validate_port "$NEW_PORT"; then
            continue
        fi

        # ----------------------------------------------------
        # Si no cambia el puerto
        # ----------------------------------------------------

        if [[ "$NEW_PORT" == "$CURRENT_PORT" ]]; then

            info \
                "El puerto HCR ya está configurado como ${NEW_PORT}."

            return 0
        fi

        # ----------------------------------------------------
        # Verificar listener real
        # ----------------------------------------------------

        if check_port_usage "$NEW_PORT"; then

            warning \
                "El puerto ${NEW_PORT} ya está siendo utilizado."

            detail \
                "Debes seleccionar un puerto HCR que esté libre."

            continue
        fi

        # ----------------------------------------------------
        # Verificar nombre de unidad
        # ----------------------------------------------------

        NEW_SERVICE="${SERVICE_PREFIX}-${NEW_PORT}.service"

        if service_exists "$NEW_SERVICE"; then

            warning \
                "La unidad ${NEW_SERVICE} ya existe."

            detail \
                "No se sobrescribirá otra instancia."

            continue
        fi

        NEW_UNIT_PATH="${SYSTEMD_DIR}/${NEW_SERVICE}"

        success \
            "El puerto ${NEW_PORT} está disponible."

        break
    done
}

# ============================================================
# SOLICITAR PUERTO DESTINO
# ============================================================

ask_target_port() {

    while true; do

        printf '\n'

        read -r -p \
            "➜ Nuevo puerto destino [actual ${CURRENT_TARGET_PORT:-desconocido}]: " NEW_PORT

        if ! validate_port "$NEW_PORT"; then
            continue
        fi

        if [[ "$NEW_PORT" == "$CURRENT_TARGET_PORT" ]]; then

            info \
                "El puerto destino ya está configurado como ${NEW_PORT}."

            return 0
        fi

        if check_port_usage "$NEW_PORT"; then

            success \
                "El puerto destino ${NEW_PORT} está siendo utilizado."

            detail \
                "Esto puede ser normal si el servicio destino escucha en ese puerto."

        else

            warning \
                "No se detectó un servicio escuchando en ${NEW_PORT}."

            detail \
                "La configuración se aplicará igualmente."

        fi

        break
    done
}

# ============================================================
# SOLICITAR PUERTO
# ============================================================

ask_new_port() {

    case "$PORT_TYPE" in

        hcr)
            ask_hcr_port
            ;;

        target)
            ask_target_port
            ;;

        *)
            fail "Tipo de puerto inválido."
            ;;

    esac
}

# ============================================================
# CONFIRMACIÓN
# ============================================================

confirm_change() {

    section "CONFIRMACIÓN"

    printf '\n'

    detail \
        "Instancia actual: ${OLD_SERVICE}"

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        detail \
            "Puerto HCR: ${CURRENT_PORT:-desconocido} → ${NEW_PORT}"

        detail \
            "Nombre actual: ${OLD_SERVICE}"

        detail \
            "Nombre nuevo: ${NEW_SERVICE}"

        detail \
            "Archivo nuevo: ${NEW_UNIT_PATH}"

        if is_privileged_port "$NEW_PORT"; then

            detail \
                "Permiso: CAP_NET_BIND_SERVICE"

        fi

    else

        detail \
            "Puerto destino: ${CURRENT_TARGET_PORT:-desconocido} → ${NEW_PORT}"

        detail \
            "Nombre de instancia: se mantiene"

    fi

    printf '\n'

    warning \
        "La instancia será detenida y reiniciada para aplicar el cambio."

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
# CREAR RESPALDO
# ============================================================

create_backup() {

    section "CREANDO RESPALDO"

    BACKUP_PATH="${OLD_UNIT_PATH}.port-backup"

    spinner_start \
        "Creando respaldo..."

    if cp -f \
        -- "$OLD_UNIT_PATH" \
        "$BACKUP_PATH"; then

        spinner_stop

    else

        spinner_stop

        fail \
            "No se pudo crear el respaldo."

    fi

    success "Respaldo creado."

    detail \
        "Backup: ${BACKUP_PATH}"
}

# ============================================================
# DETENER INSTANCIA
# ============================================================

stop_selected_service() {

    section "DETENIENDO INSTANCIA"

    spinner_start \
        "Deteniendo ${OLD_SERVICE}..."

    if systemctl stop "$OLD_SERVICE"; then

        spinner_stop

        success \
            "Instancia detenida."

    else

        spinner_stop

        fail \
            "No se pudo detener ${OLD_SERVICE}."
    fi
}

# ============================================================
# MODIFICAR CONFIGURACIÓN
# ============================================================

modify_unit_configuration() {

    section "ACTUALIZANDO CONFIGURACIÓN"

    spinner_start \
        "Modificando unidad..."

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        if ! sed -E \
            -i \
            "s#(--listen[[:space:]]+):[0-9]+#\1:${NEW_PORT}#g" \
            "$OLD_UNIT_PATH"; then

            spinner_stop

            fail \
                "No se pudo modificar el puerto HCR."
        fi

        configure_bind_capability \
            "$OLD_UNIT_PATH" \
            "$NEW_PORT"

    else

        if ! sed -E \
            -i \
            "s#(--target[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${NEW_PORT}#g" \
            "$OLD_UNIT_PATH"; then

            spinner_stop

            fail \
                "No se pudo modificar el puerto destino."
        fi
    fi

    spinner_stop

    success \
        "Configuración modificada."

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        detail \
            "--listen :${NEW_PORT}"

    else

        detail \
            "--target 127.0.0.1:${NEW_PORT}"

    fi
}

# ============================================================
# VERIFICAR CONFIGURACIÓN MODIFICADA
# ============================================================

verify_modified_configuration() {

    local port

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        port="$(get_service_port "$OLD_UNIT_PATH")"

    else

        port="$(get_service_target_port "$OLD_UNIT_PATH")"

    fi

    if [[ "$port" != "$NEW_PORT" ]]; then

        fail \
            "La configuración modificada no coincide con el nuevo puerto."

    fi

    success \
        "Configuración verificada."

}

# ============================================================
# RENOMBRAR UNIDAD
# ============================================================

rename_unit() {

    section "RENOMBRANDO INSTANCIA"

    if [[ "$PORT_TYPE" != "hcr" ]]; then

        return 0
    fi

    if [[ "$OLD_UNIT_PATH" == "$NEW_UNIT_PATH" ]]; then

        return 0
    fi

    spinner_start \
        "Renombrando ${OLD_SERVICE}..."

    if ! mv \
        -- "$OLD_UNIT_PATH" \
        "$NEW_UNIT_PATH"; then

        spinner_stop

        fail \
            "No se pudo renombrar la unidad."
    fi

    spinner_stop

    success \
        "Instancia renombrada."

    detail \
        "${OLD_SERVICE}"

    detail \
        "↓"

    detail \
        "${NEW_SERVICE}"

    # --------------------------------------------------------
    # Actualizar variables internas
    # --------------------------------------------------------

    SELECTED_SERVICE="$NEW_SERVICE"
    SELECTED_UNIT_PATH="$NEW_UNIT_PATH"
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
            "No se pudo recargar systemd."
    fi

    success \
        "Configuración de systemd recargada."
}

# ============================================================
# RESTAURAR RESPALDO
# ============================================================

restore_backup() {

    printf '\n'

    warning \
        "Intentando restaurar la configuración anterior..."

    # --------------------------------------------------------
    # Si fue renombrada, eliminar la nueva unidad modificada
    # y devolverla a su nombre original.
    # --------------------------------------------------------

    if [[ "$PORT_TYPE" == "hcr" ]] &&
       [[ -f "$NEW_UNIT_PATH" ]]; then

        rm -f -- "$NEW_UNIT_PATH"
    fi

    # --------------------------------------------------------
    # Restaurar archivo original
    # --------------------------------------------------------

    if [[ -f "$BACKUP_PATH" ]]; then

        cp -f \
            -- "$BACKUP_PATH" \
            "$OLD_UNIT_PATH"

    fi

    systemctl daemon-reload 2>/dev/null || true

    systemctl stop \
        "$NEW_SERVICE" \
        2>/dev/null || true

    systemctl restart \
        "$OLD_SERVICE" \
        2>/dev/null || true

    success \
        "Se intentó restaurar la instancia anterior."
}

# ============================================================
# INICIAR NUEVA INSTANCIA
# ============================================================

start_modified_service() {

    section "INICIANDO INSTANCIA"

    local service_to_start

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        service_to_start="$NEW_SERVICE"

    else

        service_to_start="$OLD_SERVICE"

    fi

    spinner_start \
        "Iniciando ${service_to_start}..."

    if systemctl start "$service_to_start"; then

        spinner_stop

        success \
            "Instancia iniciada."

    else

        spinner_stop

        warning \
            "La instancia no pudo iniciar."

        restore_backup

        fail \
            "No se pudo aplicar el nuevo puerto."
    fi
}

# ============================================================
# ESPERAR PUERTO
# ============================================================

wait_for_port() {

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

verify_final_state() {

    section "VERIFICACIÓN FINAL"

    local service
    local path
    local active
    local final_port
    local final_target

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        service="$NEW_SERVICE"
        path="$NEW_UNIT_PATH"

    else

        service="$OLD_SERVICE"
        path="$OLD_UNIT_PATH"

    fi

    active="$(
        systemctl is-active "$service" \
            2>/dev/null ||
            true
    )"

    if [[ "$active" != "active" ]]; then

        error_message \
            "La instancia no quedó activa."

        systemctl \
            --no-pager \
            --full \
            status "$service" \
            2>&1 || true

        return 1
    fi

    success \
        "Instancia activa."

    # --------------------------------------------------------
    # Verificar puerto HCR
    # --------------------------------------------------------

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        final_port="$(get_service_port "$path")"

        if [[ "$final_port" != "$NEW_PORT" ]]; then

            error_message \
                "El puerto HCR configurado no coincide."

            detail \
                "Esperado: ${NEW_PORT}"

            detail \
                "Detectado: ${final_port:-desconocido}"

            return 1
        fi

        success \
            "Puerto HCR configurado: ${NEW_PORT}"

        info \
            "Verificando escucha del puerto..."

        if wait_for_port "$NEW_PORT"; then

            success \
                "El puerto ${NEW_PORT} está escuchando."

        else

            error_message \
                "La instancia está activa, pero no se detectó escucha en ${NEW_PORT}."

            systemctl \
                --no-pager \
                --full \
                status "$service" \
                2>&1 || true

            return 1
        fi

        # ----------------------------------------------------
        # Verificar capacidad si es privilegiado
        # ----------------------------------------------------

        if is_privileged_port "$NEW_PORT"; then

            if ! grep -Eq \
                '^[[:space:]]*CapabilityBoundingSet=.*CAP_NET_BIND_SERVICE' \
                "$path"; then

                error_message \
                    "No se detectó CAP_NET_BIND_SERVICE."

                return 1
            fi

            if ! grep -Eq \
                '^[[:space:]]*AmbientCapabilities=.*CAP_NET_BIND_SERVICE' \
                "$path"; then

                error_message \
                    "No se detectó AmbientCapabilities=CAP_NET_BIND_SERVICE."

                return 1
            fi

            success \
                "Permiso para puerto privilegiado verificado."
        fi

    # --------------------------------------------------------
    # Verificar puerto destino
    # --------------------------------------------------------

    else

        final_target="$(
            get_service_target_port "$path"
        )"

        if [[ "$final_target" != "$NEW_PORT" ]]; then

            error_message \
                "El puerto destino configurado no coincide."

            detail \
                "Esperado: ${NEW_PORT}"

            detail \
                "Detectado: ${final_target:-desconocido}"

            return 1
        fi

        success \
            "Puerto destino configurado: ${NEW_PORT}"

        if check_port_usage "$NEW_PORT"; then

            success \
                "Existe un servicio escuchando en el puerto destino."

        else

            warning \
                "No se detectó escucha en el puerto destino."

            detail \
                "La configuración de HCR sí fue aplicada."

        fi
    fi

    # --------------------------------------------------------
    # Verificar nombre
    # --------------------------------------------------------

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        if [[ ! -f "$NEW_UNIT_PATH" ]]; then

            error_message \
                "La nueva unidad ${NEW_SERVICE} no existe."

            return 1
        fi

        if [[ -f "$OLD_UNIT_PATH" ]]; then

            error_message \
                "La unidad anterior ${OLD_SERVICE} todavía existe."

            return 1
        fi

        success \
            "Nombre de instancia actualizado: ${NEW_SERVICE}"

    fi
}

# ============================================================
# LIMPIAR RESPALDO
# ============================================================

remove_backup() {

    if [[ -n "$BACKUP_PATH" &&
          -f "$BACKUP_PATH" ]]; then

        if rm -f -- "$BACKUP_PATH"; then

            success \
                "Respaldo temporal eliminado."

        else

            warning \
                "No se pudo eliminar el respaldo."

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

    printf '%b\n' \
        "${BRIGHT_GREEN}${BOLD}✔ CAMBIO COMPLETADO CORRECTAMENTE${RESET}"

    printf '\n'

    if [[ "$PORT_TYPE" == "hcr" ]]; then

        detail \
            "Instancia anterior: ${OLD_SERVICE}"

        detail \
            "Instancia nueva:    ${NEW_SERVICE}"

        detail \
            "Puerto anterior:    ${CURRENT_PORT}"

        detail \
            "Puerto nuevo:       ${NEW_PORT}"

    else

        detail \
            "Instancia:           ${OLD_SERVICE}"

        detail \
            "Puerto destino anterior: ${CURRENT_TARGET_PORT}"

        detail \
            "Puerto destino nuevo:    ${NEW_PORT}"

    fi

    detail \
        "Estado:              activo"

    printf '\n'

    printf '%b\n' \
        "${DIM}La instancia existente fue modificada; no se creó una instancia adicional.${RESET}"

    line

    printf '\n'
}

# ============================================================
# MAIN
# ============================================================

main() {

    header

    validate_environment

    select_service

    select_port_type

    ask_new_port

    confirm_change

    create_backup

    stop_selected_service

    modify_unit_configuration

    verify_modified_configuration

    rename_unit

    reload_systemd

    start_modified_service

    verify_final_state

    remove_backup

    show_summary
}

main "$@"
