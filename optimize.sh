#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#          HCR SERVER — OPTIMIZADOR GLOBAL
# ============================================================
#
# Modifica parámetros de rendimiento de TODAS las instancias
# HCR Server detectadas.
#
# Detecta:
#
#   hcr-server.service
#   hcr-server-80.service
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#   etc.
#
# ESTE SCRIPT SOLO MODIFICA PARÁMETROS DE RENDIMIENTO.
#
# NO:
#   - crea servicios
#   - elimina servicios
#   - modifica puertos
#   - modifica el binario
#   - habilita servicios
#   - deshabilita servicios
#
# TODOS los cambios se aplican GLOBALMENTE a todas las
# instancias HCR detectadas.
#
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

export PATH LC_ALL LANG

# ============================================================
# CONFIGURACIÓN
# ============================================================

SYSTEMD_DIR="/etc/systemd/system"

SERVICE_BASE="hcr-server.service"
SERVICE_PREFIX="hcr-server-"

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
        "${BRIGHT_CYAN}${BOLD}╭────────────────────────────────────────────────────────────╮${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}│${RESET}                                                            ${BRIGHT_CYAN}${BOLD}│${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}│${RESET}              ${BRIGHT_WHITE}${BOLD}H C R   S E R V E R${RESET}                 ${BRIGHT_CYAN}${BOLD}│${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}│${RESET}              ${CYAN}Global Performance Optimizer${RESET}          ${BRIGHT_CYAN}${BOLD}│${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}│${RESET}                                                            ${BRIGHT_CYAN}${BOLD}│${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╰────────────────────────────────────────────────────────────╯${RESET}"

    printf '\n'

}

section() {

    local title="$1"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_BLUE}${BOLD}◆ ${title}${RESET}"

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

    if [[ -n "${SPINNER_PID}" ]]; then

        if kill -0 "${SPINNER_PID}" 2>/dev/null; then
            return 0
        fi

        SPINNER_PID=""

    fi

    (
        trap 'exit 0' TERM INT HUP

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

    local pid="${SPINNER_PID:-}"

    SPINNER_PID=""

    if [[ -n "${pid}" ]]; then

        kill -TERM "${pid}" 2>/dev/null || true

        wait "${pid}" 2>/dev/null || true

    fi

    printf '\r\033[K'

}

# ============================================================
# ERROR FATAL
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
# VALIDAR ENTORNO
# ============================================================

validate_environment() {

    [[ "${EUID}" -eq 0 ]] ||
        fail "Este script debe ejecutarse como root."

    [[ "$(uname -s)" == "Linux" ]] ||
        fail "Este script solo funciona en Linux."

    require_command systemctl
    require_command systemd-analyze
    require_command sed
    require_command grep
    require_command cp
    require_command sleep
    require_command find
    require_command sort
    require_command head
    require_command cut
    require_command mktemp
    require_command awk

    [[ -d "${SYSTEMD_DIR}" ]] ||
        fail "No existe el directorio de systemd."

}

# ============================================================
# DESCUBRIR SERVICIOS HCR
# ============================================================

discover_services() {

    SERVICES=()

    # --------------------------------------------------------
    # Servicio principal:
    #
    # hcr-server.service
    # --------------------------------------------------------

    if [[ -f "${SYSTEMD_DIR}/${SERVICE_BASE}" ]]; then

        SERVICES+=("${SERVICE_BASE}")

    fi

    # --------------------------------------------------------
    # Instancias por puerto:
    #
    # hcr-server-8008.service
    # hcr-server-8880.service
    # etc.
    # --------------------------------------------------------

    while IFS= read -r service; do

        [[ -n "${service}" ]] || continue

        SERVICES+=("${service}")

    done < <(

        find "${SYSTEMD_DIR}" \
            -maxdepth 1 \
            -type f \
            -name "${SERVICE_PREFIX}[0-9]*.service" \
            -printf '%f\n' \
            2>/dev/null |
            grep -E '^hcr-server-[0-9]+\.service$' |
            sort -V

    )

    ((${#SERVICES[@]} > 0)) ||
        fail "No se encontraron instancias HCR Server."

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

            grep -oE \
                -- '--max-download-frame[[:space:]]+[0-9]+' \
                "${unit}" 2>/dev/null |
                grep -oE '[0-9]+$' |
                head -n1 ||
                true

            ;;

        download_poll_timeout)

            grep -oE \
                -- '--download-poll-timeout[[:space:]]+[0-9]+(ms|s|m|h)' \
                "${unit}" 2>/dev/null |
                grep -oE '[0-9]+(ms|s|m|h)$' |
                head -n1 ||
                true

            ;;

        limit_nofile)

            grep -E \
                '^LimitNOFILE=' \
                "${unit}" 2>/dev/null |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        tasks_max)

            grep -E \
                '^TasksMax=' \
                "${unit}" 2>/dev/null |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        memory_max)

            grep -E \
                '^MemoryMax=' \
                "${unit}" 2>/dev/null |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        memory_swap_max)

            grep -E \
                '^MemorySwapMax=' \
                "${unit}" 2>/dev/null |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

        nice)

            grep -E \
                '^Nice=' \
                "${unit}" 2>/dev/null |
                cut -d= -f2 |
                head -n1 ||
                true

            ;;

    esac

}

# ============================================================
# OBTENER VALOR GLOBAL
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
# CONFIGURACIÓN GLOBAL
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

        [[ -f "${unit}" ]] ||
            fail "No existe la unidad ${unit}."

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
# COMPROBAR PARÁMETRO EXECSTART
# ============================================================

exec_parameter_exists() {

    local unit="$1"
    local parameter="$2"

    grep -qE \
        -- "${parameter}[[:space:]]+[^[:space:]]+" \
        "${unit}"

}

# ============================================================
# MODIFICAR PARÁMETRO EXECSTART
# ============================================================

replace_exec_parameter_in_unit() {

    local unit="$1"
    local parameter="$2"
    local value="$3"

    local tmp

    tmp="$(
        mktemp \
            "${unit}.tmp.XXXXXX"
    )"

    # --------------------------------------------------------
    # Si el parámetro ya existe, reemplazarlo.
    # --------------------------------------------------------

    if exec_parameter_exists \
        "${unit}" \
        "${parameter}"; then

        if sed -E \
            "s#(${parameter}[[:space:]]+)[^[:space:]]+#\1${value}#g" \
            "${unit}" > "${tmp}"; then

            mv -f \
                "${tmp}" \
                "${unit}"

            return 0

        fi

        rm -f "${tmp}"

        return 1

    fi

    # --------------------------------------------------------
    # El parámetro no existe.
    #
    # Se añade al primer ExecStart.
    # --------------------------------------------------------

    if awk \
        -v parameter="${parameter}" \
        -v value="${value}" '

        BEGIN {
            inserted = 0
        }

        {
            if (!inserted && $0 ~ /^[[:space:]]*ExecStart=/) {

                if ($0 ~ /\\[[:space:]]*$/) {

                    sub(/[[:space:]]*\\[[:space:]]*$/, "")

                    print $0 " " parameter " " value " \\"

                } else {

                    print $0 " " parameter " " value

                }

                inserted = 1

                next
            }

            print
        }

        END {

            if (!inserted) {
                exit 10
            }

        }

        ' \
        "${unit}" > "${tmp}"; then

        mv -f \
            "${tmp}" \
            "${unit}"

        return 0

    fi

    rm -f "${tmp}"

    return 1

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

        if grep -qE '^\[Service\][[:space:]]*$' "${unit}"; then

            sed -i \
                "/^\[Service\][[:space:]]*$/a ${parameter}=${value}" \
                "${unit}"

        else

            printf '\n[Service]\n%s=%s\n' \
                "${parameter}" \
                "${value}" \
                >> "${unit}"

        fi

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

        if [[ ! -f "${unit}" ]]; then

            error_message \
                "No existe ${unit}."

            return 1

        fi

        if ! replace_exec_parameter_in_unit \
            "${unit}" \
            "${parameter}" \
            "${value}"; then

            error_message \
                "No se pudo modificar ${service}."

            return 1

        fi

        MODIFIED_FILES+=("${unit}")

    done

    return 0

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

        if [[ ! -f "${unit}" ]]; then

            error_message \
                "No existe ${unit}."

            return 1

        fi

        if ! replace_systemd_parameter_in_unit \
            "${unit}" \
            "${parameter}" \
            "${value}"; then

            error_message \
                "No se pudo modificar ${service}."

            return 1

        fi

        MODIFIED_FILES+=("${unit}")

    done

    return 0

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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

    info \
        "Se aplicará a TODAS las instancias."

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
        "${value}" ||
        return 1

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
        "${RECOMMENDED_MAX_DOWNLOAD_FRAME}" ||
        return 1

    apply_exec_parameter_global \
        "--download-poll-timeout" \
        "${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}" ||
        return 1

    apply_systemd_parameter_global \
        "LimitNOFILE" \
        "${RECOMMENDED_LIMIT_NOFILE}" ||
        return 1

    apply_systemd_parameter_global \
        "TasksMax" \
        "${RECOMMENDED_TASKS_MAX}" ||
        return 1

    apply_systemd_parameter_global \
        "MemoryMax" \
        "${RECOMMENDED_MEMORY_MAX}" ||
        return 1

    apply_systemd_parameter_global \
        "MemorySwapMax" \
        "${RECOMMENDED_MEMORY_SWAP_MAX}" ||
        return 1

    apply_systemd_parameter_global \
        "Nice" \
        "${RECOMMENDED_NICE}" ||
        return 1

    success \
        "Valores recomendados aplicados a TODAS las instancias."

    return 0

}

# ============================================================
# VALIDAR UNIDADES
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

    return 0

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

        error_message \
            "Se restauró automáticamente la configuración anterior."

        return 1

    fi

    printf '\n'

    spinner_start \
        "Recargando configuración de systemd..."

    if systemctl daemon-reload >/dev/null 2>&1; then

        spinner_stop

        success \
            "Configuración de systemd recargada."

    else

        spinner_stop

        restore_backups

        error_message \
            "No se pudo recargar systemd. Configuración restaurada."

        return 1

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

    # --------------------------------------------------------
    # SI UNA INSTANCIA FALLÓ
    # --------------------------------------------------------

    if (( failed > 0 )); then

        warning \
            "Una o más instancias no pudieron iniciar correctamente."

        warning \
            "Restaurando automáticamente la configuración anterior..."

        restore_backups

        systemctl daemon-reload >/dev/null 2>&1 ||
            true

        for service in "${SERVICES[@]}"; do

            systemctl restart \
                "${service}" >/dev/null 2>&1 ||
                true

        done

        error_message \
            "La operación global falló. Se restauró la configuración anterior."

        return 1

    fi

    # --------------------------------------------------------
    # VERIFICACIÓN FINAL
    # --------------------------------------------------------

    printf '\n'

    section \
        "VERIFICACIÓN FINAL"

    failed=0

    for service in "${SERVICES[@]}"; do

        if systemctl is-active \
            --quiet \
            "${service}"; then

            success \
                "${service}: ACTIVO."

        else

            error_message \
                "${service}: NO ESTÁ ACTIVO."

            failed=$((failed + 1))

        fi

    done

    if (( failed > 0 )); then

        warning \
            "La verificación final detectó instancias inactivas."

        return 1

    fi

    printf '\n'

    success \
        "La configuración fue aplicada correctamente a TODAS las instancias."

    return 0

}

# ============================================================
# EJECUTAR CAMBIO GLOBAL
# ============================================================

execute_change() {

    local function_name="$1"

    create_backups

    MODIFIED_FILES=()

    if ! "${function_name}"; then

        warning \
            "No se realizaron cambios."

        return 1

    fi

    if ! apply_changes; then

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

        if [[ "${service}" == "hcr-server.service" ]]; then

            port="principal"

        else

            port="${service#${SERVICE_PREFIX}}"
            port="${port%.service}"

        fi

        if systemctl is-active \
            --quiet \
            "${service}"; then

            success \
                "${port} → ${service} → ACTIVO"

        else

            warning \
                "${port} → ${service} → INACTIVO"

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

                if restore_recommended; then

                    apply_changes ||
                        true

                else

                    warning \
                        "No se pudieron aplicar todos los valores recomendados."

                    restore_backups

                fi

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

    validate_environment

    validate_services

    menu

}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
