#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#          HCR SERVER — OPTIMIZADOR GLOBAL
# ============================================================
#
# Compatible con el instalador HCR Server que crea:
#
#   hcr-server-80.service
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-1443.service
#   etc.
#
# Las unidades pueden ser enlaces simbólicos:
#
#   /etc/systemd/system/hcr-server-8080.service
#       ↓
#   /ruta-del-instalador/hcr-server-8080.service
#
# Este optimizador resuelve automáticamente la unidad real.
#
# SOLO modifica parámetros de rendimiento.
#
# NO:
#
#   - crea servicios
#   - elimina servicios
#   - modifica puertos
#   - modifica el binario
#   - modifica TARGET_PORT
#   - modifica TRANSPORT
#   - habilita servicios
#   - deshabilita servicios
#
# ============================================================

set -o pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

export PATH LC_ALL LANG

# ============================================================
# CONFIGURACIÓN
# ============================================================

SYSTEMD_DIR="/etc/systemd/system"

SERVICE_NAME="hcr-server"
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
BRIGHT_YELLOW="\033[93m"
BRIGHT_MAGENTA="\033[95m"
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

ICON_GLOBAL="◈"
ICON_INSTANCES="◉"
ICON_FRAME="⚡"
ICON_TIMEOUT="◌"
ICON_NOFILE="☷"
ICON_TASKS="▦"
ICON_MEMORY="▣"
ICON_SWAP="◇"
ICON_NICE="↯"
ICON_RESTORE="↻"
ICON_EXIT="■"

# ============================================================
# VARIABLES
# ============================================================

SPINNER_PID=""

SERVICES=()
UNIT_FILES=()
BACKUP_FILES=()

# ============================================================
# UTILIDADES VISUALES
# ============================================================

clear_screen() {

    printf '\033[2J\033[H'

}

line() {

    printf '%b\n' \
        "${DIM}${CYAN}────────────────────────────────────────────────────────────${RESET}"

}

header() {

    clear_screen

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║                 H C R   S E R V E R                        ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_MAGENTA}${BOLD}║                 O P T I M I Z A D O R                      ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

    printf '\n'

    printf '%b\n' \
        "${DIM}Optimizador global de rendimiento para HCR Server${RESET}"

    printf '\n'

}

section() {

    printf '\n%b\n' \
        "${BOLD}${BRIGHT_BLUE}${DIAMOND} $1${RESET}"

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

pause_screen() {

    printf '\n'

    printf '%b' \
        "${DIM}Presiona ENTER para continuar...${RESET} "

    read -r

}

# ============================================================
# ENCABEZADO DE OPCIÓN
# ============================================================

option_header() {

    local icon="$1"
    local title="$2"
    local description="$3"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╭────────────────────────────────────────────────────────────╮${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}│  ${icon}  ${title}${RESET}"

    printf '%b\n' \
        "${DIM}│     ${description}${RESET}"

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}╰────────────────────────────────────────────────────────────╯${RESET}"

}

# ============================================================
# ELEMENTO DEL MENÚ
# ============================================================

menu_item() {

    local number="$1"
    local icon="$2"
    local title="$3"
    local description="$4"
    local color="$5"

    printf '%b\n' \
        "  ${color}${BOLD}${number}${RESET}  ${color}${icon}${RESET}  ${BRIGHT_WHITE}${BOLD}${title}${RESET}"

    printf '%b\n' \
        "      ${DIM}${description}${RESET}"

    printf '\n'

}

# ============================================================
# SPINNER
# ============================================================

spinner_start() {

    local message="$1"

    if [[ -n "${SPINNER_PID}" ]]; then

        kill -0 "${SPINNER_PID}" 2>/dev/null &&
            return 0

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
    require_command awk
    require_command readlink
    require_command basename
    require_command ss

    [[ -d "${SYSTEMD_DIR}" ]] ||
        fail "No existe el directorio de systemd."

}

# ============================================================
# DESCUBRIR INSTANCIAS
# ============================================================

discover_services() {

    SERVICES=()
    UNIT_FILES=()

    while IFS= read -r service; do

        [[ -n "${service}" ]] || continue

        local link_path
        local real_path

        link_path="${SYSTEMD_DIR}/${service}"

        if [[ -L "${link_path}" ]]; then

            real_path="$(readlink -f -- "${link_path}" 2>/dev/null || true)"

            [[ -n "${real_path}" ]] ||
                continue

        elif [[ -f "${link_path}" ]]; then

            real_path="${link_path}"

        else

            continue

        fi

        [[ -f "${real_path}" ]] ||
            continue

        SERVICES+=("${service}")
        UNIT_FILES+=("${real_path}")

    done < <(

        find "${SYSTEMD_DIR}" \
            -maxdepth 1 \
            \( -type f -o -type l \) \
            -name "${SERVICE_PREFIX}*.service" \
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

    option_header \
        "${ICON_INSTANCES}" \
        "DETECTANDO INSTANCIAS HCR" \
        "Buscando servicios HCR instalados en systemd."

    discover_services

    success \
        "Se encontraron ${#SERVICES[@]} instancia(s) HCR."

    printf '\n'

    local i

    for i in "${!SERVICES[@]}"; do

        detail \
            "${SERVICES[$i]}"

        detail \
            "Unidad real: ${UNIT_FILES[$i]}"

    done

}

# ============================================================
# OBTENER UNIDAD REAL
# ============================================================

get_unit_for_service() {

    local service="$1"

    local i

    for i in "${!SERVICES[@]}"; do

        if [[ "${SERVICES[$i]}" == "${service}" ]]; then

            printf '%s' "${UNIT_FILES[$i]}"

            return 0

        fi

    done

    return 1

}

# ============================================================
# OBTENER VALOR DE UNIDAD
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
    local i
    local unit

    for i in "${!SERVICES[@]}"; do

        unit="${UNIT_FILES[$i]}"

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
# MOSTRAR CONFIGURACIÓN
# ============================================================

show_configuration() {

    option_header \
        "${ICON_GLOBAL}" \
        "CONFIGURACIÓN GLOBAL" \
        "Valores actuales y recomendados para todas las instancias."

    printf '%b\n' \
        "${BRIGHT_CYAN}${BOLD}◈ INSTANCIAS${RESET}"

    detail \
        "Instancias detectadas: ${#SERVICES[@]}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_FRAME}  Max Download Frame${RESET}"

    detail \
        "Actual:      $(get_global_value max_download_frame)"

    detail \
        "Recomendado: ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_TIMEOUT}  Download Poll Timeout${RESET}"

    detail \
        "Actual:      $(get_global_value download_poll_timeout)"

    detail \
        "Recomendado: ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_NOFILE}  LimitNOFILE${RESET}"

    detail \
        "Actual:      $(get_global_value limit_nofile)"

    detail \
        "Recomendado: ${RECOMMENDED_LIMIT_NOFILE}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_TASKS}  TasksMax${RESET}"

    detail \
        "Actual:      $(get_global_value tasks_max)"

    detail \
        "Recomendado: ${RECOMMENDED_TASKS_MAX}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_MEMORY}  MemoryMax${RESET}"

    detail \
        "Actual:      $(get_global_value memory_max)"

    detail \
        "Recomendado: ${RECOMMENDED_MEMORY_MAX}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_SWAP}  MemorySwapMax${RESET}"

    detail \
        "Actual:      $(get_global_value memory_swap_max)"

    detail \
        "Recomendado: ${RECOMMENDED_MEMORY_SWAP_MAX}"

    printf '\n'

    printf '%b\n' \
        "${BRIGHT_WHITE}${BOLD}${ICON_NICE}  Nice${RESET}"

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

    (( 10#$1 > 0 ))

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

    (( $1 >= -20 && $1 <= 19 ))

}

# ============================================================
# RESPALDOS
# ============================================================

clear_backups() {

    BACKUP_FILES=()

}

create_backups() {

    option_header \
        "▣" \
        "CREANDO RESPALDOS" \
        "Protegiendo la configuración antes de modificarla."

    clear_backups

    local unit
    local backup
    local i
    local service

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        unit="${UNIT_FILES[$i]}"
        backup="${unit}.optimization-backup"

        [[ -f "${unit}" ]] ||
            fail "No existe la unidad real de ${service}."

        spinner_start \
            "Respaldando ${service}..."

        if cp -f \
            -- "${unit}" \
            "${backup}"; then

            spinner_stop

            BACKUP_FILES+=("${backup}")

            success \
                "Respaldo creado: ${backup}"

        else

            spinner_stop

            fail \
                "No se pudo crear el respaldo de ${service}."

        fi

    done

}

# ============================================================
# MODIFICAR PARÁMETRO DE EXECSTART
# ============================================================

replace_exec_parameter_in_unit() {

    local unit="$1"
    local parameter="$2"
    local value="$3"

    local temporary

    temporary="${unit}.optimization.tmp"

    if grep -qE \
        -- "${parameter}[[:space:]]+[^[:space:]]+" \
        "${unit}"; then

        sed -E \
            "s#(${parameter}[[:space:]]+)[^[:space:]]+#\1${value}#g" \
            "${unit}" > "${temporary}"

    else

        awk \
            -v parameter="${parameter}" \
            -v value="${value}" '

            BEGIN {
                done = 0
            }

            {
                if (!done && $0 ~ /^[[:space:]]*ExecStart=/) {

                    if ($0 ~ /\\[[:space:]]*$/) {

                        sub(/[[:space:]]*\\[[:space:]]*$/, "")

                        print $0 " " parameter " " value " \\"

                    } else {

                        print $0 " " parameter " " value

                    }

                    done = 1

                    next
                }

                print
            }

            END {

                if (!done) {
                    exit 1
                }

            }

            ' \
            "${unit}" > "${temporary}"

    fi

    mv -f \
        -- "${temporary}" \
        "${unit}"

}

# ============================================================
# MODIFICAR PARÁMETRO SYSTEMD
# ============================================================

replace_systemd_parameter_in_unit() {

    local unit="$1"
    local parameter="$2"
    local value="$3"

    local temporary

    temporary="${unit}.optimization.tmp"

    if grep -qE \
        "^${parameter}=" \
        "${unit}"; then

        sed -E \
            "s#^${parameter}=.*#${parameter}=${value}#" \
            "${unit}" > "${temporary}"

    else

        awk \
            -v parameter="${parameter}" \
            -v value="${value}" '

            BEGIN {
                inserted = 0
            }

            {
                print

                if ($0 ~ /^\[Service\][[:space:]]*$/ && !inserted) {

                    print parameter "=" value

                    inserted = 1

                }

            }

            END {

                if (!inserted) {
                    exit 1
                }

            }

            ' \
            "${unit}" > "${temporary}"

    fi

    mv -f \
        -- "${temporary}" \
        "${unit}"

}

# ============================================================
# APLICAR EXECSTART A TODAS LAS INSTANCIAS
# ============================================================

apply_exec_parameter_global() {

    local parameter="$1"
    local value="$2"

    local i
    local service
    local unit

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        unit="${UNIT_FILES[$i]}"

        [[ -f "${unit}" ]] ||
            return 1

        if ! replace_exec_parameter_in_unit \
            "${unit}" \
            "${parameter}" \
            "${value}"; then

            error_message \
                "No se pudo modificar ${service}."

            return 1

        fi

    done

}

# ============================================================
# APLICAR SYSTEMD A TODAS LAS INSTANCIAS
# ============================================================

apply_systemd_parameter_global() {

    local parameter="$1"
    local value="$2"

    local i
    local service
    local unit

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        unit="${UNIT_FILES[$i]}"

        [[ -f "${unit}" ]] ||
            return 1

        if ! replace_systemd_parameter_in_unit \
            "${unit}" \
            "${parameter}" \
            "${value}"; then

            error_message \
                "No se pudo modificar ${service}."

            return 1

        fi

    done

}

# ============================================================
# MAX DOWNLOAD FRAME
# ============================================================

change_max_frame() {

    option_header \
        "${ICON_FRAME}" \
        "MAX DOWNLOAD FRAME" \
        "Controla el tamaño máximo de los bloques de descarga."

    local current
    local value

    current="$(
        get_global_value \
            max_download_frame
    )"

    info "Valor global actual: ${current}"
    info "Valor recomendado: ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "⚡ Nuevo Max Download Frame: " \
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

    option_header \
        "${ICON_TIMEOUT}" \
        "DOWNLOAD POLL TIMEOUT" \
        "Define cuánto tiempo espera HCR durante la descarga."

    local current
    local value

    current="$(
        get_global_value \
            download_poll_timeout
    )"

    info "Valor global actual: ${current}"
    info "Valor recomendado: ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "◌ Nuevo Poll Timeout [ej. 5s]: " \
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

    option_header \
        "${ICON_NOFILE}" \
        "LIMITNOFILE" \
        "Límite máximo de descriptores de archivos del servicio."

    local current
    local value

    current="$(
        get_global_value \
            limit_nofile
    )"

    info "Valor global actual: ${current}"
    info "Valor recomendado: ${RECOMMENDED_LIMIT_NOFILE}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "☷ Nuevo LimitNOFILE: " \
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

    option_header \
        "${ICON_TASKS}" \
        "TASKSMAX" \
        "Límite máximo de tareas/procesos del servicio."

    local current
    local value

    current="$(
        get_global_value \
            tasks_max
    )"

    info "Valor global actual: ${current}"
    info "Valor recomendado: ${RECOMMENDED_TASKS_MAX}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "▦ Nuevo TasksMax: " \
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

    option_header \
        "${ICON_MEMORY}" \
        "MEMORYMAX" \
        "Límite máximo de memoria RAM asignada al servicio."

    local current
    local value

    current="$(
        get_global_value \
            memory_max
    )"

    info "Valor global actual: ${current}"
    info "Valor recomendado: ${RECOMMENDED_MEMORY_MAX}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "▣ Nuevo MemoryMax [ej. 512M]: " \
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

    option_header \
        "${ICON_SWAP}" \
        "MEMORYSWAPMAX" \
        "Controla el límite de memoria swap permitido."

    local current
    local value

    current="$(
        get_global_value \
            memory_swap_max
    )"

    info "Valor global actual: ${current}"
    info "Valor recomendado: ${RECOMMENDED_MEMORY_SWAP_MAX}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "◇ Nuevo MemorySwapMax [ej. 0, 256M]: " \
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

    option_header \
        "${ICON_NICE}" \
        "NICE" \
        "Ajusta la prioridad de ejecución del servicio."

    local current
    local value

    current="$(
        get_global_value \
            nice
    )"

    info "Valor global actual: ${current}"
    info "Rango permitido: -20 a 19"
    info "Valor recomendado: ${RECOMMENDED_NICE}"
    info "Se aplicará a TODAS las instancias."

    printf '\n'

    read -r \
        -p "↯ Nuevo Nice: " \
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

    option_header \
        "${ICON_RESTORE}" \
        "RESTAURAR VALORES RECOMENDADOS" \
        "Aplica la configuración recomendada a todas las instancias."

    printf '\n'

    info "Max Download Frame     → ${RECOMMENDED_MAX_DOWNLOAD_FRAME}"
    info "Download Poll Timeout  → ${RECOMMENDED_DOWNLOAD_POLL_TIMEOUT}"
    info "LimitNOFILE             → ${RECOMMENDED_LIMIT_NOFILE}"
    info "TasksMax                → ${RECOMMENDED_TASKS_MAX}"
    info "MemoryMax               → ${RECOMMENDED_MEMORY_MAX}"
    info "MemorySwapMax           → ${RECOMMENDED_MEMORY_SWAP_MAX}"
    info "Nice                    → ${RECOMMENDED_NICE}"

    printf '\n'

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
        "Valores recomendados aplicados a TODAS las instancias."

}

# ============================================================
# VALIDAR UNIDADES
# ============================================================

validate_units() {

    option_header \
        "✓" \
        "VALIDANDO CONFIGURACIÓN" \
        "Comprobando que las unidades modificadas sean válidas."

    local i
    local service
    local unit

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        unit="${UNIT_FILES[$i]}"

        if systemd-analyze verify \
            "${unit}" >/dev/null 2>&1; then

            success \
                "${service}: configuración válida."

        else

            error_message \
                "${service}: configuración inválida."

            systemd-analyze verify "${unit}" || true

            return 1

        fi

    done

}

# ============================================================
# RESTAURAR RESPALDOS
# ============================================================

restore_backups() {

    option_header \
        "↶" \
        "RESTAURANDO CONFIGURACIÓN" \
        "Recuperando los archivos respaldados anteriormente."

    local backup
    local unit

    for backup in "${BACKUP_FILES[@]}"; do

        unit="${backup%.optimization-backup}"

        if [[ -f "${backup}" ]]; then

            cp -f \
                -- "${backup}" \
                "${unit}"

            success \
                "Restaurado: ${unit}"

        fi

    done

}

# ============================================================
# APLICAR CAMBIOS
# ============================================================

apply_changes() {

    option_header \
        "⚙" \
        "APLICANDO CONFIGURACIÓN" \
        "Recargando systemd y reiniciando las instancias HCR."

    if ! validate_units; then

        warning \
            "La configuración modificada no es válida."

        restore_backups

        systemctl daemon-reload >/dev/null 2>&1 || true

        fail \
            "Se restauró automáticamente la configuración anterior."

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

        systemctl daemon-reload >/dev/null 2>&1 || true

        fail \
            "No se pudo recargar systemd. Configuración restaurada."

    fi

    printf '\n'

    section "REINICIANDO TODAS LAS INSTANCIAS"

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
            "Una o más instancias no pudieron iniciar."

        warning \
            "Restaurando automáticamente la configuración anterior..."

        restore_backups

        systemctl daemon-reload >/dev/null 2>&1 || true

        for service in "${SERVICES[@]}"; do

            systemctl restart \
                "${service}" >/dev/null 2>&1 ||
                true

        done

        fail \
            "La operación global falló. Configuración anterior restaurada."

    fi

    printf '\n'

    section "VERIFICACIÓN FINAL"

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

        return 1

    fi

    printf '\n'

    success \
        "La configuración fue aplicada correctamente a TODAS las instancias."

    return 0

}

# ============================================================
# EJECUTAR CAMBIO
# ============================================================

execute_change() {

    local function_name="$1"

    create_backups

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

    option_header \
        "${ICON_INSTANCES}" \
        "INSTANCIAS HCR" \
        "Estado real de cada servicio HCR detectado."

    local i
    local service
    local port
    local unit

    for i in "${!SERVICES[@]}"; do

        service="${SERVICES[$i]}"
        unit="${UNIT_FILES[$i]}"

        port="${service#${SERVICE_PREFIX}}"
        port="${port%.service}"

        if systemctl is-active \
            --quiet \
            "${service}"; then

            printf '%b\n' \
                "${BRIGHT_GREEN}${BOLD}  ◉ ${port}${RESET} ${DIM}→${RESET} ${service} ${GREEN}● ACTIVO${RESET}"

        else

            printf '%b\n' \
                "${BRIGHT_YELLOW}${BOLD}  ◌ ${port}${RESET} ${DIM}→${RESET} ${service} ${YELLOW}● INACTIVO${RESET}"

        fi

        detail \
            "Unidad: ${unit}"

        printf '\n'

    done

}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

menu() {

    while true; do

        header

        printf '%b\n' \
            "${BRIGHT_CYAN}${BOLD}${ICON_GLOBAL}  CONFIGURACIÓN GLOBAL DE RENDIMIENTO${RESET}"

        printf '\n'

        printf '%b\n' \
            "${DIM}Instancias HCR detectadas:${RESET} ${BRIGHT_GREEN}${BOLD}${#SERVICES[@]}${RESET}"

        printf '\n'

        menu_item \
            "01" \
            "${ICON_GLOBAL}" \
            "Ver configuración global" \
            "Muestra todos los valores actuales y recomendados." \
            "${BRIGHT_CYAN}"

        menu_item \
            "02" \
            "${ICON_INSTANCES}" \
            "Ver instancias HCR" \
            "Muestra puertos, servicios y estado real." \
            "${BRIGHT_BLUE}"

        menu_item \
            "03" \
            "${ICON_FRAME}" \
            "Max Download Frame" \
            "Ajusta el tamaño máximo de los bloques de descarga." \
            "${BRIGHT_MAGENTA}"

        menu_item \
            "04" \
            "${ICON_TIMEOUT}" \
            "Download Poll Timeout" \
            "Ajusta el tiempo de espera durante la descarga." \
            "${BRIGHT_MAGENTA}"

        menu_item \
            "05" \
            "${ICON_NOFILE}" \
            "LimitNOFILE" \
            "Ajusta el límite de descriptores de archivos." \
            "${BRIGHT_BLUE}"

        menu_item \
            "06" \
            "${ICON_TASKS}" \
            "TasksMax" \
            "Ajusta el límite máximo de tareas del servicio." \
            "${BRIGHT_BLUE}"

        menu_item \
            "07" \
            "${ICON_MEMORY}" \
            "MemoryMax" \
            "Ajusta el límite máximo de memoria RAM." \
            "${BRIGHT_YELLOW}"

        menu_item \
            "08" \
            "${ICON_SWAP}" \
            "MemorySwapMax" \
            "Controla el límite de memoria swap." \
            "${BRIGHT_YELLOW}"

        menu_item \
            "09" \
            "${ICON_NICE}" \
            "Nice" \
            "Ajusta la prioridad de ejecución del servicio." \
            "${BRIGHT_MAGENTA}"

        menu_item \
            "10" \
            "${ICON_RESTORE}" \
            "Restaurar valores recomendados" \
            "Aplica la configuración recomendada globalmente." \
            "${BRIGHT_GREEN}"

        printf '%b\n' \
            "${DIM}────────────────────────────────────────────────────────────${RESET}"

        printf '\n'

        printf '%b\n' \
            "  ${BRIGHT_CYAN}${BOLD}00${RESET}  ${ICON_EXIT}  ${BRIGHT_WHITE}${BOLD}Salir del optimizador${RESET}"

        printf '\n'

        line

        printf '\n'

        read -r \
            -p "➜ Selecciona una opción: " \
            option

        case "${option}" in

            1|01)

                header

                show_configuration

                pause_screen

                ;;

            2|02)

                header

                show_instances

                pause_screen

                ;;

            3|03)

                header

                execute_change change_max_frame ||
                    true

                pause_screen

                ;;

            4|04)

                header

                execute_change change_poll_timeout ||
                    true

                pause_screen

                ;;

            5|05)

                header

                execute_change change_nofile ||
                    true

                pause_screen

                ;;

            6|06)

                header

                execute_change change_tasks ||
                    true

                pause_screen

                ;;

            7|07)

                header

                execute_change change_memory ||
                    true

                pause_screen

                ;;

            8|08)

                header

                execute_change change_swap ||
                    true

                pause_screen

                ;;

            9|09)

                header

                execute_change change_nice ||
                    true

                pause_screen

                ;;

            10)

                header

                create_backups

                if restore_recommended; then

                    apply_changes ||
                        true

                fi

                pause_screen

                ;;

            0|00)

                printf '\n'

                info \
                    "Saliendo del optimizador."

                printf '\n'

                exit 0

                ;;

            *)

                printf '\n'

                warning \
                    "Opción no válida. Selecciona una opción del 00 al 10."

                sleep 1.2

                ;;

        esac

    done

}

# ============================================================
# MAIN
# ============================================================

main() {

    validate_environment

    header

    validate_services

    menu

}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
