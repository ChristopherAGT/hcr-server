#!/usr/bin/env bash
set +e
set +u
set +o pipefail

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================
#
# PANEL PRINCIPAL
#
# Este script SOLO funciona como panel/launcher.
#
# NO contiene la lógica interna de:
#
#   - Añadir puertos
#   - Modificar puertos
#   - Eliminar puertos
#   - Iniciar/detener puertos
#   - Consultar estados detallados
#   - Iniciar/detener servicios
#   - Reiniciar servicios
#   - Optimizar instancias
#
# Cada función es ejecutada por su script independiente.
#
# ============================================================

# ============================================================
# CONFIGURACIÓN
# ============================================================

BASE_URL="https://raw.githubusercontent.com/ChristopherAGT/hcr-server/main"

INSTALL_DIR="/root/.hcr-panel"
TEMP_DIR="${INSTALL_DIR}/.tmp"

SYSTEMD_DIR="/etc/systemd/system"

# ------------------------------------------------------------
# Scripts independientes
# ------------------------------------------------------------

INSTALL_SCRIPT="${INSTALL_DIR}/install.sh"

UNINSTALL_SCRIPT="${TEMP_DIR}/uninstall.sh"
PORT_MANAGEMENT_SCRIPT="${TEMP_DIR}/port-management.sh"
STATUS_PORT_SCRIPT="${TEMP_DIR}/status-port.sh"
START_STOP_SERVICE_SCRIPT="${TEMP_DIR}/start-stop-service.sh"
RESTART_SERVICE_SCRIPT="${TEMP_DIR}/restart-service.sh"
OPTIMIZE_SCRIPT="${TEMP_DIR}/optimize.sh"

# ------------------------------------------------------------
# Spinner
# ------------------------------------------------------------

SPINNER_PID=""

# ============================================================
# COLORES
# ============================================================

RESET='\033[0m'
BOLD='\033[1m'

CYAN='\033[38;5;51m'
BLUE='\033[38;5;75m'
GREEN='\033[38;5;82m'
YELLOW='\033[38;5;220m'
RED='\033[38;5;203m'
MAGENTA='\033[38;5;213m'
WHITE='\033[38;5;255m'
GRAY='\033[38;5;245m'
DARK='\033[38;5;240m'

# ============================================================
# UTILIDADES
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

pause() {

    echo

    read -rp \
        "  Presiona ENTER para continuar..." _
}

success() {

    echo -e \
        "  ${GREEN}✔${RESET} $1"
}

error() {

    echo -e \
        "  ${RED}✖${RESET} $1"
}

warning() {

    echo -e \
        "  ${YELLOW}⚠${RESET} $1"
}

info() {

    echo -e \
        "  ${CYAN}●${RESET} $1"
}

detail() {

    echo -e \
        "      ${GRAY}•${RESET} $1"
}

line() {

    echo -e \
        "  ${DARK}────────────────────────────────────────────────────────${RESET}"
}

# ============================================================
# ROOT
# ============================================================

require_root() {

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then

        error "Este panel debe ejecutarse como root."

        exit 1
    fi
}

# ============================================================
# DIRECTORIOS
# ============================================================

prepare_install_dir() {

    mkdir -p "$INSTALL_DIR" || return 1
    mkdir -p "$TEMP_DIR" || return 1

    chown root:root \
        "$INSTALL_DIR" \
        "$TEMP_DIR" \
        2>/dev/null || true

    chmod 700 \
        "$INSTALL_DIR" \
        "$TEMP_DIR" \
        2>/dev/null || true
}

# ============================================================
# SPINNER
# ============================================================

spinner_start() {

    local message="${1:-Procesando}"

    # Si ya existe un spinner, no crear otro.
    if [[ -n "${SPINNER_PID:-}" ]]; then

        if kill -0 "${SPINNER_PID}" >/dev/null 2>&1; then
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

            printf \
                "\r  ${CYAN}%s${RESET} %s" \
                "${frames[$i]}" \
                "$message"

            i=$(( (i + 1) % ${#frames[@]} ))

            sleep 0.08
        done

    ) &

    SPINNER_PID=$!
}

spinner_stop() {

    local pid="${SPINNER_PID:-}"

    SPINNER_PID=""

    if [[ -n "$pid" ]]; then

        kill -TERM "$pid" \
            >/dev/null 2>&1 || true

        wait "$pid" \
            >/dev/null 2>&1 || true
    fi

    # Limpia completamente la línea del spinner.
    printf "\r\033[2K"
}

# ============================================================
# LIMPIEZA DE EMERGENCIA
# ============================================================

cleanup() {

    spinner_stop >/dev/null 2>&1 || true
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================
# OBTENER UNIDADES HCR
# ============================================================
#
# Acepta:
#
#   hcr-server.service
#   hcr-server-8080.service
#   hcr-server-8880.service
#   hcr-server-cualquier-sufijo.service
#
# ============================================================

get_hcr_units() {

    {
        systemctl list-unit-files \
            --type=service \
            --no-legend \
            --no-pager \
            2>/dev/null |
            awk '{print $1}' |
            grep -E '^hcr-server(-[^[:space:]]+)?\.service$' ||
            true

        find "$SYSTEMD_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'hcr-server*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

    } |
    grep -E '^hcr-server(-[^[:space:]]+)?\.service$' |
    sort -u
}

# ============================================================
# CONTAR INSTANCIAS HCR
# ============================================================

count_hcr_instances() {

    local count

    count="$(
        get_hcr_units |
        wc -l |
        tr -d ' '
    )"

    echo "${count:-0}"
}

# ============================================================
# ESTADO DE INSTALACIÓN
# ============================================================

hcr_is_installed() {

    local count

    count="$(count_hcr_instances)"

    [[ "$count" =~ ^[0-9]+$ ]] &&
        (( count > 0 ))
}

# ============================================================
# RUTA DE UNIDAD
# ============================================================

get_unit_path() {

    local unit="$1"
    local path=""

    path="$(
        systemctl show \
            "$unit" \
            --property=FragmentPath \
            --value \
            2>/dev/null ||
            true
    )"

    if [[ -n "$path" && -f "$path" ]]; then

        echo "$path"

        return 0
    fi

    if [[ -f "${SYSTEMD_DIR}/${unit}" ]]; then

        echo "${SYSTEMD_DIR}/${unit}"

        return 0
    fi

    echo ""
}

# ============================================================
# OBTENER PUERTO CONFIGURADO
# ============================================================

get_unit_listen_port() {

    local unit="$1"
    local path="$2"

    [[ -n "$path" ]] || return 0
    [[ -f "$path" ]] || return 0

    grep -oE \
        -- '--listen[[:space:]]+:[0-9]+' \
        "$path" \
        2>/dev/null |
        grep -oE '[0-9]+$' |
        head -n1 ||
        true
}

# ============================================================
# COMPROBAR SI UN PUERTO ESTÁ ACTIVO
# ============================================================

is_port_listening() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] ||
        return 1

    ss -H -lnt \
        2>/dev/null |
        awk -v port="$port" '
            {
                address=$4

                sub(/^.*:/, "", address)

                if (address == port) {
                    found=1
                    exit
                }
            }

            END {
                if (found)
                    exit 0

                exit 1
            }
        '
}

# ============================================================
# OBTENER PUERTOS ACTIVOS
# ============================================================

get_active_hcr_ports() {

    local unit
    local path
    local port

    while IFS= read -r unit; do

        [[ -n "$unit" ]] || continue

        path="$(get_unit_path "$unit")"

        [[ -n "$path" ]] || continue

        port="$(get_unit_listen_port "$unit" "$path")"

        [[ "$port" =~ ^[0-9]+$ ]] ||
            continue

        if is_port_listening "$port"; then

            echo "$port"
        fi

    done < <(get_hcr_units) |
    sort -n -u
}

# ============================================================
# FORMATEAR PUERTOS
# ============================================================

format_active_ports() {

    local ports

    ports="$(get_active_hcr_ports)"

    if [[ -z "$ports" ]]; then

        echo "---"

        return
    fi

    echo "$ports" |
        paste -sd ',' - |
        sed 's/,/, /g'
}

# ============================================================
# ENCABEZADO
# ============================================================

header() {

    clear_screen

    local count
    local installed
    local active_ports

    count="$(count_hcr_instances)"

    if hcr_is_installed; then

        installed="${GREEN}Instalado${RESET} 🟢"

    else

        installed="${RED}No Instalado${RESET} 🔴"
    fi

    active_ports="$(format_active_ports)"

    if [[ "$active_ports" == "---" ]]; then

        active_ports="${GRAY}---${RESET}"

    else

        active_ports="${WHITE}${active_ports}${RESET}"
    fi

    echo

    echo -e \
        "${CYAN}    ╭────────────────────────────────────────────────────────╮${RESET}"

    echo -e \
        "${CYAN}    │                                                        │${RESET}"

    echo -e \
        "${CYAN}    │       ${BOLD}${WHITE}H C R   S E R V E R${RESET}                              ${CYAN}│${RESET}"

    echo -e \
        "${CYAN}    │       ${GRAY}Premium Control Panel${RESET}                            ${CYAN}│${RESET}"

    echo -e \
        "${CYAN}    │                                                        │${RESET}"

    echo -e \
        "${CYAN}    ├────────────────────────────────────────────────────────┤${RESET}"

    echo -e \
        "${CYAN}    │${RESET}  ${WHITE}HCR:${RESET} ${installed}                                      ${CYAN}│${RESET}"

    echo -e \
        "${CYAN}    │${RESET}  ${WHITE}Instancias HCR:${RESET} ${GREEN}${count}${RESET}                                ${CYAN}│${RESET}"

    echo -e \
        "${CYAN}    │${RESET}  ${WHITE}Puertos Activos:${RESET} ${active_ports}                       ${CYAN}│${RESET}"

    echo -e \
        "${CYAN}    ╰────────────────────────────────────────────────────────╯${RESET}"

    echo
}

# ============================================================
# DESCARGAR ARCHIVO
# ============================================================

download_file() {

    local url="$1"
    local destination="$2"

    prepare_install_dir || return 1

    rm -f "${destination}.download"

    if ! curl \
        -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "${destination}.download"; then

        rm -f "${destination}.download"

        return 1
    fi

    if [[ ! -s "${destination}.download" ]]; then

        rm -f "${destination}.download"

        return 1
    fi

    chmod 700 \
        "${destination}.download"

    chown root:root \
        "${destination}.download" \
        2>/dev/null || true

    mv -f \
        "${destination}.download" \
        "$destination"
}

# ============================================================
# EJECUTAR SCRIPT REMOTO
# ============================================================
#
# IMPORTANTE:
#
# El spinner SOLO se utiliza durante la descarga.
#
# NO se utiliza mientras el script externo está ejecutándose.
#
# Esto evita que:
#
#   ⠙ Ejecutando...
#
# se mezcle con la salida del script secundario.
#
# ============================================================

run_remote() {

    local name="$1"
    local url="$2"
    local path="$3"

    prepare_install_dir || {

        error "No se pudo preparar el directorio del panel."

        return 1
    }

    echo

    # --------------------------------------------------------
    # DESCARGA
    # --------------------------------------------------------

    spinner_start \
        "Descargando ${name}..."

    if ! curl \
        -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "${path}.download"; then

        spinner_stop

        rm -f "${path}.download"

        error "No se pudo descargar ${name}."

        return 1
    fi

    spinner_stop

    # --------------------------------------------------------
    # VALIDAR ARCHIVO
    # --------------------------------------------------------

    if [[ ! -s "${path}.download" ]]; then

        rm -f "${path}.download"

        error "El archivo descargado está vacío."

        return 1
    fi

    chmod 700 \
        "${path}.download"

    chown root:root \
        "${path}.download" \
        2>/dev/null || true

    mv -f \
        "${path}.download" \
        "$path"

    # --------------------------------------------------------
    # EJECUCIÓN
    # --------------------------------------------------------
    #
    # AQUÍ NO HAY SPINNER.
    #
    # El script externo tiene control completo de la terminal.
    #

    echo
    echo -e \
        "  ${CYAN}●${RESET} ${WHITE}Ejecutando ${name}...${RESET}"

    echo

    bash "$path"

    local result=$?

    # --------------------------------------------------------
    # LIMPIEZA
    # --------------------------------------------------------

    rm -f "$path"

    echo

    return "$result"
}

# ============================================================
# OPCIÓN 01
# INSTALAR / REINSTALAR
# ============================================================

install_service() {

    header

    echo -e \
        "  ${BOLD}${WHITE}INSTALACIÓN / REINSTALACIÓN${RESET}"

    echo -e \
        "  ${GRAY}Instala o actualiza HCR Server.${RESET}"

    echo

    spinner_start \
        "Descargando instalador..."

    if ! download_file \
        "${BASE_URL}/install.sh" \
        "$INSTALL_SCRIPT"; then

        spinner_stop

        error "No se pudo descargar install.sh."

        pause

        return
    fi

    spinner_stop

    echo

    chmod 700 "$INSTALL_SCRIPT"

    echo -e \
        "  ${CYAN}●${RESET} ${WHITE}Ejecutando instalador...${RESET}"

    echo

    bash "$INSTALL_SCRIPT"

    local result=$?

    echo

    if [[ "$result" -eq 0 ]]; then

        success \
            "HCR Server instalado correctamente."

    else

        error \
            "La instalación terminó con errores."
    fi

    rm -f "$INSTALL_SCRIPT"

    pause
}

# ============================================================
# OPCIÓN 02
# DESINSTALAR
# ============================================================

uninstall_service() {

    header

    echo -e \
        "  ${BOLD}${WHITE}DESINSTALACIÓN${RESET}"

    echo -e \
        "  ${GRAY}Elimina la instalación principal de HCR Server.${RESET}"

    echo

    warning \
        "Esta acción puede eliminar los servicios y archivos principales."

    echo

    read -rp \
        "  ¿Deseas continuar? [s/N]: " answer

    case "${answer,,}" in

        s|si|sí|y|yes)
            ;;

        *)
            info "Operación cancelada."
            pause
            return
            ;;
    esac

    echo

    if run_remote \
        "desinstalador" \
        "${BASE_URL}/uninstall.sh" \
        "$UNINSTALL_SCRIPT"; then

        success \
            "Desinstalación finalizada."

    else

        error \
            "El desinstalador terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 03
# GESTIÓN DE PUERTOS
# ============================================================

port_management() {

    header

    echo -e \
        "  ${BOLD}${WHITE}GESTIÓN DE PUERTOS${RESET}"

    echo -e \
        "  ${GRAY}Abriendo administrador independiente de puertos.${RESET}"

    echo

    if run_remote \
        "gestor de puertos" \
        "${BASE_URL}/port-management.sh" \
        "$PORT_MANAGEMENT_SCRIPT"; then

        :

    else

        echo

        error \
            "El gestor de puertos terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 04
# ESTADOS DE PUERTOS
# ============================================================

status_ports() {

    header

    echo -e \
        "  ${BOLD}${WHITE}ESTADOS DE PUERTOS${RESET}"

    echo -e \
        "  ${GRAY}Abriendo comprobador independiente de estados.${RESET}"

    echo

    if run_remote \
        "comprobador de estados de puertos" \
        "${BASE_URL}/status-port.sh" \
        "$STATUS_PORT_SCRIPT"; then

        :

    else

        echo

        error \
            "El comprobador de estados terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 05
# INICIAR / DETENER SERVICIO
# ============================================================

start_stop_service() {

    header

    echo -e \
        "  ${BOLD}${WHITE}INICIAR / DETENER SERVICIO${RESET}"

    echo -e \
        "  ${GRAY}Abriendo administrador independiente del servicio.${RESET}"

    echo

    if run_remote \
        "gestor de servicio HCR" \
        "${BASE_URL}/start-stop-service.sh" \
        "$START_STOP_SERVICE_SCRIPT"; then

        :

    else

        echo

        error \
            "El gestor de servicio terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 06
# REINICIAR SERVICIO
# ============================================================

restart_service() {

    header

    echo -e \
        "  ${BOLD}${WHITE}REINICIAR SERVICIO${RESET}"

    echo -e \
        "  ${GRAY}Abriendo reiniciador independiente del servicio.${RESET}"

    echo

    if run_remote \
        "reiniciador del servicio HCR" \
        "${BASE_URL}/restart-service.sh" \
        "$RESTART_SERVICE_SCRIPT"; then

        :

    else

        echo

        error \
            "El reiniciador terminó con errores."
    fi

    pause
}

# ============================================================
# OPCIÓN 07
# OPTIMIZAR HCR
# ============================================================

optimize_service() {

    header

    echo -e \
        "  ${BOLD}${WHITE}OPTIMIZAR HCR${RESET}"

    echo -e \
        "  ${GRAY}Abriendo optimizador independiente.${RESET}"

    echo

    if run_remote \
        "optimizador HCR" \
        "${BASE_URL}/optimize.sh" \
        "$OPTIMIZE_SCRIPT"; then

        :

    else

        echo

        error \
            "El optimizador terminó con errores."
    fi

    pause
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

show_menu() {

    header

    echo -e \
        "  ${BOLD}${WHITE}CONTROL${RESET}"

    echo -e \
        "  ${GRAY}Selecciona una operación${RESET}"

    echo

    printf \
        "  ${CYAN}01${RESET}  ${MAGENTA}➤${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Instalar / reinstalar"

    echo -e \
        "      ${GRAY}Instala o actualiza HCR Server${RESET}"

    echo

    printf \
        "  ${CYAN}02${RESET}  ${MAGENTA}◈${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Desinstalar"

    echo -e \
        "      ${GRAY}Elimina la instalación principal${RESET}"

    echo

    printf \
        "  ${CYAN}03${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Gestión de puertos"

    echo -e \
        "      ${GRAY}Abre el administrador independiente de puertos${RESET}"

    echo

    printf \
        "  ${CYAN}04${RESET}  ${MAGENTA}◉${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Estados de puertos"

    echo -e \
        "      ${GRAY}Abre el comprobador independiente status-port.sh${RESET}"

    echo

    printf \
        "  ${CYAN}05${RESET}  ${MAGENTA}↕${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Iniciar / Detener Servicio"

    echo -e \
        "      ${GRAY}Inicia o detiene una instancia HCR${RESET}"

    echo

    printf \
        "  ${CYAN}06${RESET}  ${MAGENTA}↻${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Reiniciar Servicio"

    echo -e \
        "      ${GRAY}Reinicia una instancia HCR${RESET}"

    echo

    printf \
        "  ${CYAN}07${RESET}  ${MAGENTA}⚙${RESET}  ${WHITE}%-28s${RESET}\n" \
        "Optimizar HCR"

    echo -e \
        "      ${GRAY}Ajusta el rendimiento del protocolo${RESET}"

    echo

    echo -e \
        "  ${DARK}────────────────────────────────────────────────────────${RESET}"

    echo

    echo -e \
        "  ${GRAY}00${RESET}  ${WHITE}Salir del panel${RESET}"

    echo

    echo -ne \
        "  ${CYAN}HCR ›${RESET} "
}

# ============================================================
# MAIN
# ============================================================

main() {

    require_root

    prepare_install_dir || {

        error "No se pudo preparar el directorio del panel."

        exit 1
    }

    while true; do

        show_menu

        read -r option

        case "$option" in

            1|01)

                install_service
                ;;

            2|02)

                uninstall_service
                ;;

            3|03)

                port_management
                ;;

            4|04)

                status_ports
                ;;

            5|05)

                start_stop_service
                ;;

            6|06)

                restart_service
                ;;

            7|07)

                optimize_service
                ;;

            0|00)

                echo

                echo -e \
                    "  ${CYAN}HCR${RESET} ${GRAY}›${RESET} ${WHITE}Cerrando panel...${RESET}"

                echo

                exit 0
                ;;

            *)

                echo

                error "Opción no válida."

                sleep 1
                ;;

        esac

    done
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
