#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#          HCR SERVER — OPTIMIZADOR GLOBAL
# ============================================================
# Modifica parámetros de rendimiento de TODAS las instancias
# HCR Server creadas por el instalador.
#
# Detecta automáticamente:
#
#   hcr-server-80.service
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#   etc.
#
# IMPORTANTE:
#
# Este script NO crea ni elimina servicios.
# Este script NO modifica puertos.
# Este script NO modifica el binario.
# Este script NO habilita ni deshabilita servicios.
#
# Los cambios de rendimiento se aplican GLOBALMENTE a todas
# las instancias HCR encontradas.
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

# ============================================================
# VARIABLES
# ============================================================

SPINNER_PID=""

SERVICES=()
BACKUP_FILES=()
MODIFIED_FILES=()

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
        "${BRIGHT_CYAN}${BOLD}║                 HCR SERVER — OPTIMIZADOR                 ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║              CONFIGURACIÓN GLOBAL                         ║${RESET}"

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
# COMANDOS
# ============================================================

require_command() {

    command -v "$1" >/dev/null 2>&1 ||
        fail "No se encontró el comando requerido: $1"
}

# ============================================================
# VALIDACIÓN DEL ENTORNO
# ============================================================

validate_environment() {

    [[ "${EUID}" -eq 0 ]] ||
        fail "Este script debe ejecutarse como root."

    [[ "$(uname -s)" == "Linux" ]] ||
        fail "Este script solo funciona en Linux."

    require_command systemctl
    require_command sed
    require_command grep
    require_command cp
    require_command sleep
    require_command find
    require_command sort
    require_command head
    require_command cut
    require_command mktemp

    [[ -d "${SYSTEMD_DIR}" ]] ||
        fail "No existe el directorio de systemd."

}

# ============================================================
# DESCUBRIR SERVICIOS
# ============================================================

discover_services() {

    SERVICES=()

    while IFS= read -r service; do

        [[ -n "${service}" ]] || continue

        SERVICES+=("${service}")

    done < <(

        find "${SYSTEMD_DIR}" \
            -maxdepth 1 \
            -type f \
            -name "${SERVICE_PREFIX}*.service" \
            -printf '%f\n' \
            2>/dev/null |
            grep -E '^hcr-server-[0-9]+\.service$' |
            sort -V

    )

    ((${#SERVICES[@]} > 0)) ||
        fail \
            "No se encontraron instancias HCR Server creadas por el instalador."

}

# ============================================================
# VALIDAR SERVICIOS
# ============================================================

validate_services() {

    section "DETECTANDO INSTANCIAS HCR"

    discover_services

    success \
        "Se encontraron ${#SERVICES[@]} instancia(s) HCR."

    printf '\n'

    local service

    for service in "${SERVICES[@]}"; do

        detail "${service}"

    done

}

# ============================================================
# OBTENER VALORES DE UNA UNIDAD
# ============================================================

get_value_from_unit() {

    local unit="$1"
    local parameter="$2"

    case "${parameter}" in

        max_download_frame)

            grep -oE -- \
                '--max-download-frame[[:space:]]+[0-9]+' \
                "${unit}" |
                grep -oE '[0-9]+$' |
                head -n1 ||
                true

            ;;

        download_poll_timeout)

            grep -oE -- \
                '--download-poll-timeout[[:space:]]+[0-9]+(ms|s|m|h)' \
                "${unit}" |
                grep -oE '[0-9]+(ms|s|m|h)$' |
                head -n1 ||
                true

            ;;

        limit_nofile)

            grep -E '^LimitNOFILE=' \
                "${unit}" |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        tasks_max)

            grep -E '^TasksMax=' \
                "${unit}" |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        memory_max)

            grep -E '^MemoryMax=' \
                "${unit}" |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        memory_swap_max)

            grep -E '^MemorySwapMax=' \
                "${unit}" |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        nice)

            grep -E '^Nice=' \
                "${unit}" |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

    esac
}

# ============================================================
# MOSTRAR VALOR GLOBAL
# ============================================================

get_global_value() {

    local parameter="$1"

    local first_value=""
    local value=""
    local service
    local unit

    for service in "${SERVICES[@]}"; do

        unit="${SYSTEMD_DIR}/${service}"

        value="$(
            get_value_from_unit \
                "${unit}" \
                "${parameter}"
        )"

        if [[ -z "${first_value}" ]]; then

            first_value="${value}"

        elif [[ "${value}" != "${first_value}" ]]; then

            printf '%s' "VARÍA"

            return 0

        fi

    done

    if [[ -n "${first_value}" ]]; then

        printf '%s' "${first_value}"

    else

        printf '%s' "NO CONFIGURADO"

    fi
}

# ============================================================
# MOSTRAR CONFIGURACIÓN GLOBAL
# ============================================================

show_configuration() {

    section "CONFIGURACIÓN GLOBAL ACTUAL"

    detail \
        "Instancias detectadas: ${#SERVICES[@]}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}1.${RESET} Max Download Frame"

    detail \
        "Actual:      $(get_global_value max_download_frame)"

    detail \
        "Recomendado: ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}2.${RESET} Download Poll Timeout"

    detail \
        "Actual:      $(get_global_value download_poll_timeout)"

    detail \
        "Recomendado: ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}3.${RESET} LimitNOFILE"

    detail \
        "Actual:      $(get_global_value limit_nofile)"

    detail \
        "Recomendado: ${RECOMMENDED_LIMIT_NOFILE}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}4.${RESET} TasksMax"

    detail \
        "Actual:      $(get_global_value tasks_max)"

    detail \
        "Recomendado: ${RECOMMENDED_TASKS_MAX}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}5.${RESET} MemoryMax"

    detail \
        "Actual:      $(get_global_value memory_max)"

    detail \
        "Recomendado: ${RECOMMENDED_MEMORY_MAX}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}6.${RESET} MemorySwapMax"

    detail \
        "Actual:      $(get_global_value memory_swap_max)"

    detail \
        "Recomendado: ${RECOMMENDED_MEMORY_SWAP_MAX}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}7.${RESET} Nice"

    detail \
        "Actual:      $(get_global_value nice)"

    detail \
        "Recomendado: ${RECOMMENDED_NICE}"

}

# ============================================================
# VALIDACIONES
# ============================================================

validate_positive_integer() {

    [[ "$1" =~ ^[0-9]+$ ]] ||
        return 1

    (( "$1" > 0 ))

}

validate_timeout() {

    [[ "$1" =~ ^[0-9]+(ms|s|m|h)$ ]]

}

validate_memory() {

    [[ "$1" =~ ^[0-9]+(K|M|G|T)$ ]]

}

validate_nice() {

    [[ "$1" =~ ^-?[0-9]+$ ]] ||
        return 1

    (( "$1" >= -20 && "$1" <= 19 ))

}

# ============================================================
# RESPALDOS
# ============================================================

clear_backup_arrays() {

    BACKUP_FILES=()
    MODIFIED_FILES=()

}

create_backups() {

    section "CREANDO RESPALDOS"

    clear_backup_arrays

    local service
    local unit
    local backup

    for service in "${SERVICES[@]}"; do

        unit="${SYSTEMD_DIR}/${service}"

        backup="${unit}.optimization-backup"

        spinner_start \
            "Respaldando ${service}..."

        if cp -f \
            -- "${unit}" \
            "${backup}"; then

            spinner_stop

            BACKUP_FILES+=("${backup}")

            success \
                "Respaldo creado para ${service}."

        else

            spinner_stop

            fail \
                "No se pudo crear el respaldo de ${service}."

        fi

    done

}

# ============================================================
# MODIFICAR PARÁMETROS EXECSTART
# ============================================================

replace_exec_parameter_in_unit() {

    local unit="$1"
    local parameter="$2"
    local value="$3"

    sed -E -i \
        "s#(${parameter}[[:space:]]+)[^[:space:]]+#\1${value}#g" \
        "${unit}"

}

# ============================================================
# MODIFICAR PARÁMETROS SYSTEMD
# ============================================================

replace_systemd_parameter_in_unit() {

    local unit="$1"
    local parameter="$2"
    local value="$3"

    if grep -qE "^${parameter}=" "${unit}"; then

        sed -E -i \
            "s#^${parameter}=.*#${parameter}=${value}#" \
            "${unit}"

    else

        sed -i \
            "/^\[Service\]/a ${parameter}=${value}" \
            "${unit}"

    fi

}

# ============================================================
# APLICAR EXECSTART GLOBAL
# ============================================================

apply_exec_parameter_global() {

    local parameter="$1"
    local value="$2"

    local service
    local unit

    for service in "${SERVICES[@]}"; do

        unit="${SYSTEMD_DIR}/${service}"

        replace_exec_parameter_in_unit \
            "${unit}" \
            "${parameter}" \
            "${value}"

        MODIFIED_FILES+=("${unit}")

    done

}

# ============================================================
# APLICAR SYSTEMD GLOBAL
# ============================================================

apply_systemd_parameter_global() {

    local parameter="$1"
    local value="$2"

    local service
    local unit

    for service in "${SERVICES[@]}"; do

        unit="${SYSTEMD_DIR}/${service}"

        replace_systemd_parameter_in_unit \
            "${unit}" \
            "${parameter}" \
            "${value}"

        MODIFIED_FILES+=("${unit}")

    done

}

# ============================================================
# MAX DOWNLOAD FRAME
# ============================================================

change_max_frame() {

    local current
    local value

    current="$(
        get_global_value \
            max_download_frame
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Valor recomendado: ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"

    printf '\n'

    read -r \
        -p "Nuevo Max Download Frame: " \
        value

    validate_positive_integer "${value}" || {

        error_message \
            "Debe ser un número entero mayor que 0."

        return 1

    }

    apply_exec_parameter_global \
        "--max-download-frame" \
        "${value}"

    success \
        "Max Download Frame actualizado globalmente a ${value}."

}

# ============================================================
# POLL TIMEOUT
# ============================================================

change_poll_timeout() {

    local current
    local value

    current="$(
        get_global_value \
            download_poll_timeout
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Valor recomendado: ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"

    printf '\n'

    read -r \
        -p "Nuevo Poll Timeout [ej. 5s]: " \
        value

    validate_timeout "${value}" || {

        error_message \
            "Formato inválido. Ejemplos: 500ms, 5s, 1m."

        return 1

    }

    apply_exec_parameter_global \
        "--download-poll-timeout" \
        "${value}"

    success \
        "Download Poll Timeout actualizado globalmente a ${value}."

}

# ============================================================
# LIMITNOFILE
# ============================================================

change_nofile() {

    local current
    local value

    current="$(
        get_global_value \
            limit_nofile
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Valor recomendado: ${RECOMMENDED_LIMIT_NOFILE}"

    printf '\n'

    read -r \
        -p "Nuevo LimitNOFILE: " \
        value

    validate_positive_integer "${value}" || {

        error_message \
            "Debe ser un número entero mayor que 0."

        return 1

    }

    apply_systemd_parameter_global \
        "LimitNOFILE" \
        "${value}"

    success \
        "LimitNOFILE actualizado globalmente a ${value}."

}

# ============================================================
# TASKSMAX
# ============================================================

change_tasks() {

    local current
    local value

    current="$(
        get_global_value \
            tasks_max
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Valor recomendado: ${RECOMMENDED_TASKS_MAX}"

    printf '\n'

    read -r \
        -p "Nuevo TasksMax: " \
        value

    validate_positive_integer "${value}" || {

        error_message \
            "Debe ser un número entero mayor que 0."

        return 1

    }

    apply_systemd_parameter_global \
        "TasksMax" \
        "${value}"

    success \
        "TasksMax actualizado globalmente a ${value}."

}

# ============================================================
# MEMORYMAX
# ============================================================

change_memory() {

    local current
    local value

    current="$(
        get_global_value \
            memory_max
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Valor recomendado: ${RECOMMENDED_MEMORY_MAX}"

    printf '\n'

    read -r \
        -p "Nuevo MemoryMax [ej. 512M]: " \
        value

    validate_memory "${value}" || {

        error_message \
            "Formato inválido. Ejemplos: 256M, 512M, 1G."

        return 1

    }

    apply_systemd_parameter_global \
        "MemoryMax" \
        "${value}"

    success \
        "MemoryMax actualizado globalmente a ${value}."

}

# ============================================================
# MEMORYSWAPMAX
# ============================================================

change_swap() {

    local current
    local value

    current="$(
        get_global_value \
            memory_swap_max
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Valor recomendado: ${RECOMMENDED_MEMORY_SWAP_MAX}"

    printf '\n'

    read -r \
        -p "Nuevo MemorySwapMax [ej. 0, 256M]: " \
        value

    if [[ "${value}" != "0" ]] &&
        ! validate_memory "${value}"; then

        error_message \
            "Formato inválido."

        return 1

    fi

    apply_systemd_parameter_global \
        "MemorySwapMax" \
        "${value}"

    success \
        "MemorySwapMax actualizado globalmente a ${value}."

}

# ============================================================
# NICE
# ============================================================

change_nice() {

    local current
    local value

    current="$(
        get_global_value \
            nice
    )"

    printf '\n'

    info \
        "Valor global actual: ${current}"

    info \
        "Rango permitido: -20 a 19"

    info \
        "Valor recomendado: ${RECOMMENDED_NICE}"

    printf '\n'

    read -r \
        -p "Nuevo Nice: " \
        value

    validate_nice "${value}" || {

        error_message \
            "Nice debe estar entre -20 y 19."

        return 1

    }

    apply_systemd_parameter_global \
        "Nice" \
        "${value}"

    success \
        "Nice actualizado globalmente a ${value}."

}

# ============================================================
# RESTAURAR RECOMENDADOS
# ============================================================

restore_recommended() {

    section \
        "RESTAURANDO VALORES RECOMENDADOS GLOBALMENTE"

    apply_exec_parameter_global \
        "--max-download-frame" \
        "${RECOMMENDED_MAX_DOWNLOAD_FRAME}"

    apply_exec_parameter_global \
        "--download-poll-timeout" \
        "${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"

    apply_systemd_parameter_global \
        "LimitNOFILE" \
        "${RECOMMENDED_LIMIT_NOFILE}"

    apply_systemd_parameter_global \
        "TasksMax" \
        "${RECOMMENDED_TASKS_MAX}"

    apply_systemd_parameter_global \
        "MemoryMax" \
        "${RECOMMENDED_MEMORY_MAX}"

    apply_systemd_parameter_global \
        "MemorySwapMax" \
        "${RECOMMENDED_MEMORY_SWAP_MAX}"

    apply_systemd_parameter_global \
        "Nice" \
        "${RECOMMENDED_NICE}"

    success \
        "Valores recomendados aplicados a todas las instancias."

}

# ============================================================
# VALIDAR CONFIGURACIÓN SYSTEMD
# ============================================================

validate_units() {

    section \
        "VALIDANDO CONFIGURACIÓN"

    local service
    local unit

    for service in "${SERVICES[@]}"; do

        unit="${SYSTEMD_DIR}/${service}"

        if systemd-analyze verify \
            "${unit}" >/dev/null 2>&1; then

            success \
                "${service}: configuración válida."

        else

            error_message \
                "${service}: configuración inválida."

            return 1

        fi

    done

}

# ============================================================
# RESTAURAR RESPALDOS
# ============================================================

restore_backups() {

    section \
        "RESTAURANDO CONFIGURACIÓN ANTERIOR"

    local backup
    local unit

    for backup in "${BACKUP_FILES[@]}"; do

        unit="${backup%.optimization-backup}"

        if [[ -f "${backup}" ]]; then

            cp -f \
                -- "${backup}" \
                "${unit}"

            success \
                "Restaurado: $(basename "${unit}")"

        fi

    done

    systemctl daemon-reload >/dev/null 2>&1 ||
        true

}

# ============================================================
# APLICAR CAMBIOS
# ============================================================

apply_changes() {

    section \
        "APLICANDO CONFIGURACIÓN GLOBAL"

    if ! validate_units; then

        warning \
            "La configuración modificada no es válida."

        restore_backups

        fail \
            "Se restauró automáticamente la configuración anterior."

    fi

    spinner_start \
        "Recargando configuración de systemd..."

    if systemctl daemon-reload >/dev/null 2>&1; then

        spinner_stop

        success \
            "Configuración de systemd recargada."

    else

        spinner_stop

        restore_backups

        fail \
            "No se pudo recargar systemd. Configuración restaurada."

    fi

    printf '\n'

    section \
        "REINICIANDO TODAS LAS INSTANCIAS"

    local service
    local failed=0

    for service in "${SERVICES[@]}"; do

        spinner_start \
            "Reiniciando ${service}..."

        if systemctl restart \
            "${service}" >/dev/null 2>&1; then

            spinner_stop

            if systemctl is-active \
                --quiet \
                "${service}"; then

                success \
                    "${service} reiniciado correctamente."

            else

                error_message \
                    "${service} no quedó activo."

                failed=$((failed + 1))

            fi

        else

            spinner_stop

            error_message \
                "No se pudo reiniciar ${service}."

            failed=$((failed + 1))

        fi

    done

    if (( failed > 0 )); then

        warning \
            "Una o más instancias no pudieron iniciar correctamente."

        warning \
            "Restaurando la configuración anterior..."

        restore_backups

        # ----------------------------------------------------
        # RECARGAR SYSTEMD
        # ----------------------------------------------------

        systemctl daemon-reload >/dev/null 2>&1 ||
            true

        # ----------------------------------------------------
        # RESTAURAR TODAS LAS INSTANCIAS
        # ----------------------------------------------------

        for service in "${SERVICES[@]}"; do

            systemctl restart \
                "${service}" >/dev/null 2>&1 ||
                true

        done

        fail \
            "La operación global falló. Se restauró la configuración anterior."

    fi

    printf '\n'

    section \
        "VERIFICACIÓN FINAL"

    for service in "${SERVICES[@]}"; do

        if systemctl is-active \
            --quiet \
            "${service}"; then

            success \
                "${service}: activo."

        else

            error_message \
                "${service}: no está activo."

            failed=$((failed + 1))

        fi

    done

    if (( failed > 0 )); then

        fail \
            "Una o más instancias no quedaron activas."

    fi

    printf '\n'

    success \
        "La configuración fue aplicada correctamente a todas las instancias."

}

# ============================================================
# EJECUTAR CAMBIO GLOBAL
# ============================================================

execute_change() {

    local function_name="$1"

    create_backups

    MODIFIED_FILES=()

    if "${function_name}"; then

        if ! apply_changes; then
            return 1
        fi

    else

        warning \
            "No se realizaron cambios."

        return 1

    fi

    return 0
}

# ============================================================
# MOSTRAR INSTANCIAS
# ============================================================

show_instances() {

    section \
        "INSTANCIAS HCR DETECTADAS"

    local service

    for service in "${SERVICES[@]}"; do

        local port

        port="${service#${SERVICE_PREFIX}}"
        port="${port%.service}"

        if systemctl is-active \
            --quiet \
            "${service}"; then

            success \
                "Puerto ${port} → ${service} → ACTIVO"

        else

            warning \
                "Puerto ${port} → ${service} → INACTIVO"

        fi

    done

}

# ============================================================
# MENÚ
# ============================================================

menu() {

    while true; do

        header

        printf '%b\n' \
            "${BRIGHT_WHITE}${BOLD}CONFIGURACIÓN GLOBAL DE RENDIMIENTO${RESET}"

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_CYAN}Instancias detectadas: ${#SERVICES[@]}${RESET}"

        printf '\n'

        printf '%b\n' \
            "${BRIGHT_WHITE}1.${RESET} Ver configuración global"

        printf '%b\n' \
            "${BRIGHT_WHITE}2.${RESET} Ver instancias HCR"

        printf '%b\n' \
            "${BRIGHT_WHITE}3.${RESET} Max Download Frame"

        printf '%b\n' \
            "${BRIGHT_WHITE}4.${RESET} Download Poll Timeout"

        printf '%b\n' \
            "${BRIGHT_WHITE}5.${RESET} LimitNOFILE"

        printf '%b\n' \
            "${BRIGHT_WHITE}6.${RESET} TasksMax"

        printf '%b\n' \
            "${BRIGHT_WHITE}7.${RESET} MemoryMax"

        printf '%b\n' \
            "${BRIGHT_WHITE}8.${RESET} MemorySwapMax"

        printf '%b\n' \
            "${BRIGHT_WHITE}9.${RESET} Nice"

        printf '%b\n' \
            "${BRIGHT_GREEN}10.${RESET} Restaurar valores recomendados"

        printf '%b\n' \
            "${BRIGHT_CYAN}0.${RESET} Salir"

        printf '\n'

        line

        read -r \
            -p "➜ Selecciona una opción: " \
            option

        case "${option}" in

            1)

                show_configuration

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            2)

                show_instances

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            3)

                execute_change change_max_frame ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            4)

                execute_change change_poll_timeout ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            5)

                execute_change change_nofile ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            6)

                execute_change change_tasks ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            7)

                execute_change change_memory ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            8)

                execute_change change_swap ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            9)

                execute_change change_nice ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            10)

                create_backups

                MODIFIED_FILES=()

                restore_recommended

                apply_changes ||
                    true

                printf '\n'

                read -r \
                    -p "Presiona ENTER para continuar..."

                ;;

            0)

                printf '\n'

                info \
                    "Saliendo del optimizador."

                printf '\n'

                exit 0

                ;;

            *)

                warning \
                    "Opción no válida."

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

    validate_services

    menu

}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
