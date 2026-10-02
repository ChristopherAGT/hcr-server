#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — OPTIMIZADOR
# Modifica parámetros de rendimiento del servicio
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

# ============================================================
# VALORES RECOMENDADOS
# ============================================================

RECOMMENDED_MAX_DOWNLOAD_FRAME="1500"
RECOMMENDED_DOWNLOAD_POLL_TIMEOUT="5s"
RECOMMENDED_LIMIT_NOFILE="16384"
RECOMMENDED_TASKS_MAX="1024"
RECOMMENDED_MEMORY_MAX="512M"
RECOMMENDED_MEMORY_SWAP_MAX="0"
RECOMMENDED_NICE="-5"

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

SPINNER_PID=""

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
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — OPTIMIZADOR                 ║${RESET}"
    printf '%b\n' "${BRIGHT_CYAN}${BOLD}║             AJUSTES DE RENDIMIENTO                        ║${RESET}"
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
# VALIDACIÓN
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
    require_command sleep
}

validate_service() {
    [[ -f "$UNIT_PATH" ]] || \
        fail "No existe la unidad:

${UNIT_PATH}"

    systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1 || \
        fail "systemd no reconoce el servicio ${SERVICE_NAME}."
}

# ============================================================
# RESPALDO
# ============================================================

BACKUP_PATH="${UNIT_PATH}.optimization-backup"

create_backup() {
    spinner_start "Creando respaldo de la configuración..."

    cp -f -- "$UNIT_PATH" "$BACKUP_PATH"

    spinner_stop

    success "Respaldo creado."
    detail "${BACKUP_PATH}"
}

# ============================================================
# OBTENER VALORES
# ============================================================

get_value() {
    local parameter="$1"

    case "$parameter" in

        max_download_frame)
            grep -oE -- \
                '--max-download-frame[[:space:]]+[0-9]+' \
                "$UNIT_PATH" |
                grep -oE '[0-9]+$' |
                head -n1 || true
            ;;

        download_poll_timeout)
            grep -oE -- \
                '--download-poll-timeout[[:space:]]+[0-9]+(ms|s|m|h)' \
                "$UNIT_PATH" |
                grep -oE '[0-9]+(ms|s|m|h)$' |
                head -n1 || true
            ;;

        limit_nofile)
            grep -E '^LimitNOFILE=' "$UNIT_PATH" |
                cut -d= -f2 |
                head -n1 || true
            ;;

        tasks_max)
            grep -E '^TasksMax=' "$UNIT_PATH" |
                cut -d= -f2 |
                head -n1 || true
            ;;

        memory_max)
            grep -E '^MemoryMax=' "$UNIT_PATH" |
                cut -d= -f2 |
                head -n1 || true
            ;;

        memory_swap_max)
            grep -E '^MemorySwapMax=' "$UNIT_PATH" |
                cut -d= -f2 |
                head -n1 || true
            ;;

        nice)
            grep -E '^Nice=' "$UNIT_PATH" |
                cut -d= -f2 |
                head -n1 || true
            ;;

    esac
}

# ============================================================
# MOSTRAR CONFIGURACIÓN
# ============================================================

show_configuration() {
    section "CONFIGURACIÓN ACTUAL"

    printf '%b\n' "${BRIGHT_WHITE}${BOLD}1.${RESET} Max Download Frame"
    detail "Actual:      $(get_value max_download_frame)"
    detail "Recomendado: ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"

    printf '\n%b\n' "${BRIGHT_WHITE}${BOLD}2.${RESET} Download Poll Timeout"
    detail "Actual:      $(get_value download_poll_timeout)"
    detail "Recomendado: ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"

    printf '\n%b\n' "${BRIGHT_WHITE}${BOLD}3.${RESET} LimitNOFILE"
    detail "Actual:      $(get_value limit_nofile)"
    detail "Recomendado: ${RECOMMENDED_LIMIT_NOFILE}"

    printf '\n%b\n' "${BRIGHT_WHITE}${BOLD}4.${RESET} TasksMax"
    detail "Actual:      $(get_value tasks_max)"
    detail "Recomendado: ${RECOMMENDED_TASKS_MAX}"

    printf '\n%b\n' "${BRIGHT_WHITE}${BOLD}5.${RESET} MemoryMax"
    detail "Actual:      $(get_value memory_max)"
    detail "Recomendado: ${RECOMMENDED_MEMORY_MAX}"

    printf '\n%b\n' "${BRIGHT_WHITE}${BOLD}6.${RESET} MemorySwapMax"
    detail "Actual:      $(get_value memory_swap_max)"
    detail "Recomendado: ${RECOMMENDED_MEMORY_SWAP_MAX}"

    printf '\n%b\n' "${BRIGHT_WHITE}${BOLD}7.${RESET} Nice"
    detail "Actual:      $(get_value nice)"
    detail "Recomendado: ${RECOMMENDED_NICE}"
}

# ============================================================
# VALIDACIONES DE VALORES
# ============================================================

validate_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( "$1" > 0 ))
}

validate_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_timeout() {
    [[ "$1" =~ ^[0-9]+(ms|s|m|h)$ ]]
}

validate_memory() {
    [[ "$1" =~ ^[0-9]+(K|M|G|T)$ ]]
}

validate_nice() {
    [[ "$1" =~ ^-?[0-9]+$ ]] || return 1
    (( "$1" >= -20 && "$1" <= 19 ))
}

# ============================================================
# MODIFICAR PARÁMETROS
# ============================================================

replace_exec_parameter() {
    local parameter="$1"
    local value="$2"

    sed -E -i \
        "s#(${parameter}[[:space:]]+)[^[:space:]]+#\1${value}#g" \
        "$UNIT_PATH"
}

replace_systemd_parameter() {
    local parameter="$1"
    local value="$2"

    if grep -qE "^${parameter}=" "$UNIT_PATH"; then
        sed -E -i \
            "s#^${parameter}=.*#${parameter}=${value}#" \
            "$UNIT_PATH"
    else
        sed -i \
            "/^\[Service\]/a ${parameter}=${value}" \
            "$UNIT_PATH"
    fi
}

# ============================================================
# CAMBIAR MAX DOWNLOAD FRAME
# ============================================================

change_max_frame() {
    local current
    current="$(get_value max_download_frame)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Valor recomendado: ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"

    printf '\n'
    read -r -p "Nuevo Max Download Frame: " value

    validate_positive_integer "$value" || {
        error_message "Debe ser un número entero mayor que 0."
        return 1
    }

    replace_exec_parameter "--max-download-frame" "$value"

    success "Max Download Frame actualizado a ${value}."
}

# ============================================================
# CAMBIAR POLL TIMEOUT
# ============================================================

change_poll_timeout() {
    local current
    current="$(get_value download_poll_timeout)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Valor recomendado: ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"

    printf '\n'
    read -r -p "Nuevo Poll Timeout [ej. 8s]: " value

    validate_timeout "$value" || {
        error_message "Formato inválido. Ejemplos: 500ms, 8s, 1m."
        return 1
    }

    replace_exec_parameter "--download-poll-timeout" "$value"

    success "Download Poll Timeout actualizado a ${value}."
}

# ============================================================
# CAMBIAR LIMITNOFILE
# ============================================================

change_nofile() {
    local current
    current="$(get_value limit_nofile)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Valor recomendado: ${RECOMMENDED_LIMIT_NOFILE}"

    printf '\n'
    read -r -p "Nuevo LimitNOFILE: " value

    validate_positive_integer "$value" || {
        error_message "Debe ser un número entero mayor que 0."
        return 1
    }

    replace_systemd_parameter "LimitNOFILE" "$value"

    success "LimitNOFILE actualizado a ${value}."
}

# ============================================================
# CAMBIAR TASKSMAX
# ============================================================

change_tasks() {
    local current
    current="$(get_value tasks_max)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Valor recomendado: ${RECOMMENDED_TASKS_MAX}"

    printf '\n'
    read -r -p "Nuevo TasksMax: " value

    validate_positive_integer "$value" || {
        error_message "Debe ser un número entero mayor que 0."
        return 1
    }

    replace_systemd_parameter "TasksMax" "$value"

    success "TasksMax actualizado a ${value}."
}

# ============================================================
# CAMBIAR MEMORYMAX
# ============================================================

change_memory() {
    local current
    current="$(get_value memory_max)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Valor recomendado: ${RECOMMENDED_MEMORY_MAX}"

    printf '\n'
    read -r -p "Nuevo MemoryMax [ej. 512M]: " value

    validate_memory "$value" || {
        error_message "Formato inválido. Ejemplos: 256M, 512M, 1G."
        return 1
    }

    replace_systemd_parameter "MemoryMax" "$value"

    success "MemoryMax actualizado a ${value}."
}

# ============================================================
# CAMBIAR MEMORYSWAPMAX
# ============================================================

change_swap() {
    local current
    current="$(get_value memory_swap_max)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Valor recomendado: ${RECOMMENDED_MEMORY_SWAP_MAX}"

    printf '\n'
    read -r -p "Nuevo MemorySwapMax [ej. 0, 256M]: " value

    if [[ "$value" != "0" ]] && ! validate_memory "$value"; then
        error_message "Formato inválido."
        return 1
    fi

    replace_systemd_parameter "MemorySwapMax" "$value"

    success "MemorySwapMax actualizado a ${value}."
}

# ============================================================
# CAMBIAR NICE
# ============================================================

change_nice() {
    local current
    current="$(get_value nice)"

    printf '\n'
    info "Valor actual: ${current:-no configurado}"
    info "Rango permitido: -20 a 19"
    info "Valor recomendado: ${RECOMMENDED_NICE}"

    printf '\n'
    read -r -p "Nuevo Nice: " value

    validate_nice "$value" || {
        error_message "Nice debe estar entre -20 y 19."
        return 1
    }

    replace_systemd_parameter "Nice" "$value"

    success "Nice actualizado a ${value}."
}

# ============================================================
# RESTAURAR RECOMENDADOS
# ============================================================

restore_recommended() {
    section "RESTAURANDO VALORES RECOMENDADOS"

    replace_exec_parameter \
        "--max-download-frame" \
        "$RECOMMENDED_MAX_DOWNLOAD_FRAME"

    replace_exec_parameter \
        "--download-poll-timeout" \
        "$RECOMMENDED_DOWNLOAD_POLL_TIMEOUT"

    replace_systemd_parameter \
        "LimitNOFILE" \
        "$RECOMMENDED_LIMIT_NOFILE"

    replace_systemd_parameter \
        "TasksMax" \
        "$RECOMMENDED_TASKS_MAX"

    replace_systemd_parameter \
        "MemoryMax" \
        "$RECOMMENDED_MEMORY_MAX"

    replace_systemd_parameter \
        "MemorySwapMax" \
        "$RECOMMENDED_MEMORY_SWAP_MAX"

    replace_systemd_parameter \
        "Nice" \
        "$RECOMMENDED_NICE"

    success "Valores recomendados restaurados."
}

# ============================================================
# APLICAR CAMBIOS
# ============================================================

apply_changes() {
    section "APLICANDO CONFIGURACIÓN"

    spinner_start "Recargando systemd..."

    systemctl daemon-reload

    spinner_stop

    success "Configuración de systemd recargada."

    spinner_start "Reiniciando ${SERVICE_NAME}..."

    if systemctl restart "${SERVICE_NAME}"; then
        spinner_stop
        success "Servicio reiniciado."
    else
        spinner_stop

        warning "El servicio no pudo iniciar con la configuración modificada."
        warning "Restaurando respaldo..."

        cp -f -- "$BACKUP_PATH" "$UNIT_PATH"
        systemctl daemon-reload

        if systemctl restart "${SERVICE_NAME}"; then
            success "Configuración anterior restaurada."
        else
            error_message "No se pudo restaurar automáticamente el servicio."
        fi

        return 1
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        success "HCR Server está activo."
    else
        error_message "HCR Server no quedó activo."
        return 1
    fi
}

# ============================================================
# MENÚ
# ============================================================

menu() {
    while true; do
        header

        printf '%b\n' "${BRIGHT_WHITE}${BOLD}CONFIGURACIÓN DE RENDIMIENTO${RESET}"
        printf '\n'

        printf '%b\n' "${BRIGHT_WHITE}1.${RESET} Ver configuración actual"
        printf '%b\n' "${BRIGHT_WHITE}2.${RESET} Max Download Frame"
        printf '%b\n' "${BRIGHT_WHITE}3.${RESET} Download Poll Timeout"
        printf '%b\n' "${BRIGHT_WHITE}4.${RESET} LimitNOFILE"
        printf '%b\n' "${BRIGHT_WHITE}5.${RESET} TasksMax"
        printf '%b\n' "${BRIGHT_WHITE}6.${RESET} MemoryMax"
        printf '%b\n' "${BRIGHT_WHITE}7.${RESET} MemorySwapMax"
        printf '%b\n' "${BRIGHT_WHITE}8.${RESET} Nice"
        printf '%b\n' "${BRIGHT_GREEN}9.${RESET} Restaurar valores recomendados"
        printf '%b\n' "${BRIGHT_CYAN}0.${RESET} Salir"

        printf '\n'
        line

        read -r -p "➜ Selecciona una opción: " option

        case "$option" in

            1)
                show_configuration
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            2)
                create_backup
                if change_max_frame; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            3)
                create_backup
                if change_poll_timeout; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            4)
                create_backup
                if change_nofile; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            5)
                create_backup
                if change_tasks; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            6)
                create_backup
                if change_memory; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            7)
                create_backup
                if change_swap; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            8)
                create_backup
                if change_nice; then
                    apply_changes || true
                fi
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            9)
                create_backup
                restore_recommended
                apply_changes || true
                printf '\n'
                read -r -p "Presiona ENTER para continuar..."
                ;;

            0)
                printf '\n'
                info "Saliendo del optimizador."
                printf '\n'
                exit 0
                ;;

            *)
                warning "Opción no válida."
                sleep 1
                ;;

        esac
    done
}

# ============================================================
# MAIN
# ============================================================

main() {
    header

    validate_environment
    validate_service

    menu
}

main "$@"
