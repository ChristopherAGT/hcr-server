#!/usr/bin/env bash
set +e
set +u
set +o pipefail

# ============================================================
# HCR SERVER — PREMIUM CONTROL PANEL
# ============================================================
#
# PANEL PRINCIPAL / LAUNCHER
#
# El panel NO contiene la lógica interna de:
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
# Todas esas funciones son ejecutadas mediante scripts
# independientes descargados temporalmente desde GitHub.
#
# ============================================================
#
# ARQUITECTURA:
#
#   /root/.hcr-panel/
#   ├── install.sh
#   └── .tmp/
#       ├── uninstall.sh
#       ├── port-management.sh
#       ├── status-port.sh
#       ├── start-stop-service.sh
#       ├── restart-service.sh
#       └── optimize.sh
#
# Los archivos anteriores son recursos TEMPORALES del panel.
#
# El panel NO descarga:
#
#   /root/.hcr-panel/hcr-server
#
# El binario HCR es responsabilidad de install.sh.
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
# Recursos temporales
# ------------------------------------------------------------

INSTALL_SCRIPT="${TEMP_DIR}/install.sh"

UNINSTALL_SCRIPT="${TEMP_DIR}/uninstall.sh"
PORT_MANAGEMENT_SCRIPT="${TEMP_DIR}/port-management.sh"
STATUS_PORT_SCRIPT="${TEMP_DIR}/status-port.sh"
START_STOP_SERVICE_SCRIPT="${TEMP_DIR}/start-stop-service.sh"
RESTART_SERVICE_SCRIPT="${TEMP_DIR}/restart-service.sh"
OPTIMIZE_SCRIPT="${TEMP_DIR}/optimize.sh"

# ------------------------------------------------------------
# Lista de recursos
# ------------------------------------------------------------

declare -a PANEL_RESOURCES=(
    "install.sh"
    "uninstall.sh"
    "port-management.sh"
    "status-port.sh"
    "start-stop-service.sh"
    "restart-service.sh"
    "optimize.sh"
)

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

    local uid="${EUID:-$(id -u)}"

    if [[ "$uid" -ne 0 ]]; then

        error "Este panel debe ejecutarse como root."

        exit 1
    fi
}


# ============================================================
# COMPROBAR COMANDOS NECESARIOS
# ============================================================

check_dependencies() {

    local missing=()

    command -v curl >/dev/null 2>&1 ||
        missing+=("curl")

    command -v systemctl >/dev/null 2>&1 ||
        missing+=("systemctl")

    command -v awk >/dev/null 2>&1 ||
        missing+=("awk")

    command -v grep >/dev/null 2>&1 ||
        missing+=("grep")

    command -v sed >/dev/null 2>&1 ||
        missing+=("sed")

    command -v sort >/dev/null 2>&1 ||
        missing+=("sort")

    command -v paste >/dev/null 2>&1 ||
        missing+=("paste")

    command -v ss >/dev/null 2>&1 ||
        missing+=("ss")

    if (( ${#missing[@]} > 0 )); then

        error "Faltan comandos necesarios:"

        local item

        for item in "${missing[@]}"; do
            detail "$item"
        done

        return 1
    fi

    return 0
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

    return 0
}


# ============================================================
# LIMPIAR RECURSOS TEMPORALES
# ============================================================
#
# IMPORTANTE:
#
# No elimina:
#
#   /root/.hcr-panel
#
# No elimina:
#
#   servicios
#   binarios HCR
#   certificados
#   archivos de systemd
#
# Solo elimina los recursos descargados temporalmente.
#
# ============================================================

cleanup_resources() {

    if [[ -n "${SPINNER_PID:-}" ]]; then

        spinner_stop >/dev/null 2>&1 || true
    fi

    if [[ -d "$TEMP_DIR" ]]; then

        rm -f \
            "${TEMP_DIR}/install.sh" \
            "${TEMP_DIR}/uninstall.sh" \
            "${TEMP_DIR}/port-management.sh" \
            "${TEMP_DIR}/status-port.sh" \
            "${TEMP_DIR}/start-stop-service.sh" \
            "${TEMP_DIR}/restart-service.sh" \
            "${TEMP_DIR}/optimize.sh" \
            "${TEMP_DIR}"/*.download \
            2>/dev/null || true
    fi
}


# ============================================================
# SPINNER
# ============================================================

spinner_start() {

    local message="${1:-Procesando}"

    # Si existe un spinner anterior, verificarlo.
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

    # Si no existe PID, no intentar wait.
    if [[ -z "$pid" ]]; then

        printf "\r\033[2K"

        return 0
    fi

    # Comprobar que el proceso exista antes de enviar TERM.
    if kill -0 "$pid" >/dev/null 2>&1; then

        kill -TERM "$pid" \
            >/dev/null 2>&1 || true

        # Solo hacer wait si el proceso es hijo válido.
        wait "$pid" \
            >/dev/null 2>&1 || true
    fi

    printf "\r\033[2K"
}


# ============================================================
# LIMPIEZA DE EMERGENCIA
# ============================================================

cleanup() {

    cleanup_resources
}


trap cleanup EXIT

trap 'exit 130' INT

trap 'exit 143' TERM


# ============================================================
# OBTENER UNIDADES HCR
# ============================================================

get_hcr_units() {

    {
        systemctl list-unit-files \
            --type=service \
            --no-legend \
            --no-pager \
            2>/dev/null |
            awk '{print $1}' |
            grep -E \
                '^hcr-server(-[^[:space:]]+)?\.service$' ||
            true

        find "$SYSTEMD_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'hcr-server*.service' \
            -printf '%f\n' \
            2>/dev/null ||
            true

    } |
    grep -E \
        '^hcr-server(-[^[:space:]]+)?\.service$' |
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
# COMPROBAR PUERTO ACTIVO
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
# DESCARGAR RECURSO
# ============================================================

download_resource() {

    local name="$1"
    local destination="$2"

    local url="${BASE_URL}/${name}"
    local temporary="${destination}.download"

    prepare_install_dir || return 1

    rm -f "$temporary"

    spinner_start \
        "Descargando ${name}..."

    if ! curl \
        -fL \
        --retry 3 \
        --retry-delay 1 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "$temporary"; then

        spinner_stop

        rm -f "$temporary"

        error "No se pudo descargar ${name}."

        return 1
    fi

    spinner_stop

    if [[ ! -f "$temporary" ]]; then

        error "No se recibió ${name}."

        return 1
    fi

    if [[ ! -s "$temporary" ]]; then

        rm -f "$temporary"

        error "El recurso ${name} está vacío."

        return 1
    fi

    chmod 700 "$temporary"

    chown root:root \
        "$temporary" \
        2>/dev/null || true

    mv -f \
        "$temporary" \
        "$destination"

    if [[ ! -s "$destination" ]]; then

        error "No se pudo preparar ${name}."

        return 1
    fi

    return 0
}


# ============================================================
# DESCARGAR TODOS LOS RECURSOS
# ============================================================
#
# Esta función prepara el panel completo.
#
# No descarga hcr-server.
#
# Descarga únicamente los componentes del panel.
#
# ============================================================

download_all_resources() {

    prepare_install_dir || {

        error "No se pudo preparar el directorio temporal."

        return 1
    }

    echo

    echo -e \
        "  ${BOLD}${WHITE}PREPARANDO RECURSOS DEL PANEL${RESET}"

    echo

    local failed=0

    # --------------------------------------------------------
    # install.sh
    # --------------------------------------------------------

    if download_resource \
        "install.sh" \
        "$INSTALL_SCRIPT"; then

        success "install.sh preparado."

    else

        failed=1
    fi

    # --------------------------------------------------------
    # uninstall.sh
    # --------------------------------------------------------

    if download_resource \
        "uninstall.sh" \
        "$UNINSTALL_SCRIPT"; then

        success "uninstall.sh preparado."

    else

        failed=1
    fi

    # --------------------------------------------------------
    # port-management.sh
    # --------------------------------------------------------

    if download_resource \
        "port-management.sh" \
        "$PORT_MANAGEMENT_SCRIPT"; then

        success "port-management.sh preparado."

    else

        failed=1
    fi

    # --------------------------------------------------------
    # status-port.sh
    # --------------------------------------------------------

    if download_resource \
        "status-port.sh" \
        "$STATUS_PORT_SCRIPT"; then

        success "status-port.sh preparado."

    else

        failed=1
    fi

    # --------------------------------------------------------
    # start-stop-service.sh
    # --------------------------------------------------------

    if download_resource \
        "start-stop-service.sh" \
        "$START_STOP_SERVICE_SCRIPT"; then

        success "start-stop-service.sh preparado."

    else

        failed=1
    fi

    # --------------------------------------------------------
    # restart-service.sh
    # --------------------------------------------------------

    if download_resource \
        "restart-service.sh" \
        "$RESTART_SERVICE_SCRIPT"; then

        success "restart-service.sh preparado."

    else

        failed=1
    fi

    # --------------------------------------------------------
    # optimize.sh
    # --------------------------------------------------------

    if download_resource \
        "optimize.sh" \
        "$OPTIMIZE_SCRIPT"; then

        success "optimize.sh preparado."

    else

        failed=1
    fi

    echo

    if (( failed != 0 )); then

        error "No se pudieron preparar todos los recursos."

        return 1
    fi

    success "Todos los recursos del panel fueron preparados."

    return 0
}


# ============================================================
# VALIDAR RECURSO
# ============================================================

validate_resource() {

    local path="$1"

    [[ -f "$path" ]] ||
        return 1

    [[ -s "$path" ]] ||
        return 1

    return 0
}


# ============================================================
# EJECUTAR RECURSO TEMPORAL
# ============================================================
#
# NO descarga nuevamente el script.
#
# Usa el recurso que ya fue preparado.
#
# ============================================================

run_resource() {

    local name="$1"
    local path="$2"

    if ! validate_resource "$path"; then

        error "El recurso temporal ${name} no está disponible."

        echo

        warning "Intentando descargarlo nuevamente..."

        echo

        if ! download_resource "$name" "$path"; then

            error "No se pudo preparar ${name}."

            return 1
        fi
    fi

    chmod 700 "$path" 2>/dev/null || true

    echo

    echo -e \
        "  ${CYAN}●${RESET} ${WHITE}Ejecutando ${name}...${RESET}"

    echo

    # --------------------------------------------------------
    # MUY IMPORTANTE:
    #
    # No existe spinner durante esta parte.
    #
    # El script secundario tiene control completo de la
    # terminal.
    # --------------------------------------------------------

    bash "$path"

    local result=$?

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

    if ! validate_resource "$INSTALL_SCRIPT"; then

        warning "install.sh no está preparado."

        echo

        if ! download_resource \
            "install.sh" \
            "$INSTALL_SCRIPT"; then

            error "No se pudo preparar install.sh."

            pause

            return
        fi
    fi

    echo

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

        detail "Código de salida: ${result}"
    fi

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

    if run_resource \
        "uninstall.sh" \
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

    if run_resource \
        "port-management.sh" \
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

    if run_resource \
        "status-port.sh" \
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

    if run_resource \
        "start-stop-service.sh" \
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

    if run_resource \
        "restart-service.sh" \
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

    if run_resource \
        "optimize.sh" \
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
# PREPARACIÓN INICIAL
# ============================================================

initialize_panel() {

    require_root

    if ! check_dependencies; then

        echo

        error "El entorno no tiene todos los comandos necesarios."

        exit 1
    fi

    if ! prepare_install_dir; then

        error "No se pudo preparar el directorio del panel."

        exit 1
    fi

    # --------------------------------------------------------
    # Descargar TODOS los recursos al iniciar.
    #
    # Si alguno falla, el panel no continúa porque podría
    # presentar funciones incompletas.
    # --------------------------------------------------------

    if ! download_all_resources; then

        echo

        error "No se pudo preparar completamente el panel."

        exit 1
    fi

    echo

    success "Panel preparado correctamente."

    sleep 1
}


# ============================================================
# MAIN
# ============================================================

main() {

    initialize_panel

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
