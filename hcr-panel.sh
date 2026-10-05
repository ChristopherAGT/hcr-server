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
# Los recursos utilizados por el panel se descargan
# temporalmente desde el repositorio oficial.
#
# NO se instalan permanentemente los scripts auxiliares.
#
# Al cerrar el panel:
#
#   /root/.hcr-panel/.tmp.* 
#
# se elimina completamente.
#
# ============================================================


# ============================================================
# CONFIGURACIÓN
# ============================================================

BASE_URL="https://raw.githubusercontent.com/ChristopherAGT/hcr-server/main"

PANEL_DIR="/root/.hcr-panel"

TEMP_DIR=""

SYSTEMD_DIR="/etc/systemd/system"

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


# ============================================================
# ROOT
# ============================================================

require_root() {

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then

        error \
            "Este panel debe ejecutarse como root."

        exit 1
    fi
}


# ============================================================
# PREPARAR DIRECTORIOS TEMPORALES
# ============================================================

prepare_dirs() {

    mkdir -p \
        "$PANEL_DIR" ||
        return 1

    chmod 700 \
        "$PANEL_DIR" \
        2>/dev/null || true

    TEMP_DIR="$(
        mktemp -d \
            "${PANEL_DIR}/.tmp.XXXXXX"
    )" ||
        return 1

    chmod 700 \
        "$TEMP_DIR" \
        2>/dev/null || true

    chown root:root \
        "$PANEL_DIR" \
        "$TEMP_DIR" \
        2>/dev/null || true

    return 0
}


# ============================================================
# SPINNER
# ============================================================

spinner_start() {

    local message="${1:-Procesando}"

    if [[ -n "${SPINNER_PID:-}" ]]; then

        if kill -0 \
            "${SPINNER_PID}" \
            >/dev/null 2>&1; then

            return 0
        fi
    fi

    SPINNER_PID=""

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

            i=$(
                (
                    i + 1
                ) %
                ${#frames[@]}
            )

            sleep 0.08

        done

    ) &

    SPINNER_PID=$!
}


spinner_stop() {

    local pid="${SPINNER_PID:-}"

    SPINNER_PID=""

    if [[ -n "$pid" ]]; then

        kill -TERM \
            "$pid" \
            >/dev/null 2>&1 || true

        wait \
            "$pid" \
            >/dev/null 2>&1 || true
    fi

    printf "\r\033[2K"
}


# ============================================================
# LIMPIEZA
# ============================================================

cleanup() {

    spinner_stop \
        >/dev/null 2>&1 || true

    if [[ -n "${TEMP_DIR:-}" &&
          -d "${TEMP_DIR}" ]]; then

        rm -rf \
            -- \
            "$TEMP_DIR"
    fi
}


trap cleanup EXIT

trap 'exit 130' INT

trap 'exit 143' TERM


# ============================================================
# RECURSOS REALES DEL REPOSITORIO
# ============================================================
#
# Estos son los archivos que aparecen actualmente en main.
#
# NO existe:
#
#   port-management.sh
#
# La gestión de puertos se divide en:
#
#   add-port.sh
#   change-port.sh
#   delete-port.sh
#   start-stop-port.sh
#
# ============================================================

RESOURCE_NAMES=(

    "install.sh"

    "uninstall.sh"

    "add-port.sh"

    "change-port.sh"

    "delete-port.sh"

    "start-stop-port.sh"

    "status-port.sh"

    "start-stop-service.sh"

    "restart-service.sh"

    "optimize.sh"
)


# ============================================================
# DESCARGAR RECURSO
# ============================================================

download_resource() {

    local name="$1"

    local destination="${TEMP_DIR}/${name}"

    local temporary="${destination}.download"

    local url="${BASE_URL}/${name}"


    rm -f \
        -- \
        "$temporary"


    spinner_start \
        "Descargando ${name}..."


    if ! curl \
        -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        -sS \
        "$url" \
        -o "$temporary"; then

        spinner_stop

        rm -f \
            -- \
            "$temporary"

        error \
            "No se pudo descargar ${name}."

        return 1
    fi


    spinner_stop


    if [[ ! -s "$temporary" ]]; then

        rm -f \
            -- \
            "$temporary"

        error \
            "El archivo ${name} está vacío."

        return 1
    fi


    # --------------------------------------------------------
    # VALIDACIÓN BÁSICA DE SCRIPTS
    # --------------------------------------------------------

    if [[ "$name" == *.sh ]]; then

        if ! head -n 1 \
            "$temporary" |
            grep -qE \
                '^#!.*(ba|sh)'; then

            rm -f \
                -- \
                "$temporary"

            error \
                "${name} no parece ser un script Bash válido."

            return 1
        fi
    fi


    chmod 700 \
        "$temporary" \
        2>/dev/null || true


    chown root:root \
        "$temporary" \
        2>/dev/null || true


    mv -f \
        -- \
        "$temporary" \
        "$destination"


    success \
        "${name} preparado."

    return 0
}


# ============================================================
# PREPARAR TODOS LOS RECURSOS
# ============================================================

prepare_resources() {

    echo

    echo -e \
        "  ${BOLD}${WHITE}PREPARANDO RECURSOS DEL PANEL${RESET}"

    echo -e \
        "  ${GRAY}Los recursos se descargarán únicamente durante esta sesión.${RESET}"

    echo

    local failed=0

    local name


    for name in \
        "${RESOURCE_NAMES[@]}"; do

        download_resource \
            "$name" ||

            failed=1

    done


    echo


    if (( failed )); then

        error \
            "No se pudieron preparar todos los recursos."

        return 1
    fi


    success \
        "Todos los recursos fueron preparados correctamente."

    echo

    return 0
}


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


        find \
            "$SYSTEMD_DIR" \
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
# CONTAR INSTANCIAS
# ============================================================

count_hcr_instances() {

    get_hcr_units |
        wc -l |
        tr -d ' '
}


# ============================================================
# COMPROBAR INSTALACIÓN
# ============================================================

hcr_is_installed() {

    local count

    count="$(
        count_hcr_instances
    )"

    [[ "$count" =~ ^[0-9]+$ ]] &&
        (( count > 0 ))
}


# ============================================================
# RUTA DE UNIDAD
# ============================================================

get_unit_path() {

    local unit="$1"

    local path


    path="$(
        systemctl show \
            "$unit" \
            --property=FragmentPath \
            --value \
            2>/dev/null ||
            true
    )"


    if [[ -n "$path" &&
          -f "$path" ]]; then

        echo "$path"

        return 0
    fi


    if [[ -f "${SYSTEMD_DIR}/${unit}" ]]; then

        echo \
            "${SYSTEMD_DIR}/${unit}"

        return 0
    fi


    echo ""
}


# ============================================================
# OBTENER PUERTO CONFIGURADO
# ============================================================

get_unit_listen_port() {

    local path="$2"


    [[ -n "$path" ]] ||
        return 0

    [[ -f "$path" ]] ||
        return 0


    grep -oE \
        -- \
        '--listen[[:space:]]+:[0-9]+' \
        "$path" \
        2>/dev/null |

        grep -oE \
            '[0-9]+$' |

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


    ss \
        -H \
        -lnt \
        2>/dev/null |

        awk \
            -v port="$port" '

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
# PUERTOS ACTIVOS HCR
# ============================================================

get_active_hcr_ports() {

    local unit

    local path

    local port


    while IFS= read -r unit; do

        [[ -n "$unit" ]] ||
            continue


        path="$(
            get_unit_path \
                "$unit"
        )"


        [[ -n "$path" ]] ||
            continue


        port="$(
            get_unit_listen_port \
                "$unit" \
                "$path"
        )"


        [[ "$port" =~ ^[0-9]+$ ]] ||
            continue


        if is_port_listening "$port"; then

            echo "$port"

        fi

    done < <(
        get_hcr_units
    ) |

    sort -n -u
}


# ============================================================
# FORMATEAR PUERTOS
# ============================================================

format_active_ports() {

    local ports

    ports="$(
        get_active_hcr_ports
    )"


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


    count="$(
        count_hcr_instances
    )"


    if hcr_is_installed; then

        installed="${GREEN}Instalado${RESET} 🟢"

    else

        installed="${RED}No Instalado${RESET} 🔴"

    fi


    active_ports="$(
        format_active_ports
    )"


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
# EJECUTAR RECURSO TEMPORAL
# ============================================================

run_resource() {

    local name="$1"

    shift


    local path="${TEMP_DIR}/${name}"


    if [[ ! -f "$path" ]]; then

        error \
            "Recurso temporal no encontrado: ${name}."

        return 1
    fi


    echo

    echo -e \
        "  ${CYAN}●${RESET} ${WHITE}Ejecutando ${name}...${RESET}"

    echo


    (
        cd "$TEMP_DIR" || exit 1

        bash "$path" "$@"

    )

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


    run_resource \
        "install.sh"

    local result=$?


    echo


    if [[ "$result" -eq 0 ]]; then

        success \
            "HCR Server instalado correctamente."

    else

        error \
            "La instalación terminó con errores."

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
        "  ¿Deseas continuar? [s/N]: " \
        answer


    case "${answer,,}" in

        s|si|sí|y|yes)
            ;;

        *)

            info \
                "Operación cancelada."

            pause

            return

            ;;

    esac


    echo


    run_resource \
        "uninstall.sh"

    local result=$?


    echo


    if [[ "$result" -eq 0 ]]; then

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

    while true; do

        header


        echo -e \
            "  ${BOLD}${WHITE}GESTIÓN DE PUERTOS${RESET}"

        echo -e \
            "  ${GRAY}Selecciona la operación que deseas realizar.${RESET}"

        echo


        printf \
            "  ${CYAN}01${RESET}  ${MAGENTA}＋${RESET}  ${WHITE}Añadir puerto${RESET}\n"

        echo -e \
            "      ${GRAY}Crea una nueva instancia/puerto HCR${RESET}"

        echo


        printf \
            "  ${CYAN}02${RESET}  ${MAGENTA}✎${RESET}  ${WHITE}Cambiar puerto${RESET}\n"

        echo -e \
            "      ${GRAY}Modifica el puerto de una instancia${RESET}"

        echo


        printf \
            "  ${CYAN}03${RESET}  ${MAGENTA}−${RESET}  ${WHITE}Eliminar puerto${RESET}\n"

        echo -e \
            "      ${GRAY}Elimina una instancia asociada a un puerto${RESET}"

        echo


        printf \
            "  ${CYAN}04${RESET}  ${MAGENTA}↕${RESET}  ${WHITE}Iniciar / Detener puerto${RESET}\n"

        echo -e \
            "      ${GRAY}Controla el estado de una instancia por puerto${RESET}"

        echo


        echo -e \
            "  ${DARK}────────────────────────────────────────────────────────${RESET}"

        echo


        echo -e \
            "  ${GRAY}00${RESET}  ${WHITE}Volver${RESET}"

        echo


        echo -ne \
            "  ${CYAN}HCR / PUERTOS ›${RESET} "

        read -r option


        case "$option" in

            1|01)

                header

                echo -e \
                    "  ${BOLD}${WHITE}AÑADIR PUERTO${RESET}"

                echo

                run_resource \
                    "add-port.sh"

                pause

                ;;


            2|02)

                header

                echo -e \
                    "  ${BOLD}${WHITE}CAMBIAR PUERTO${RESET}"

                echo

                run_resource \
                    "change-port.sh"

                pause

                ;;


            3|03)

                header

                echo -e \
                    "  ${BOLD}${WHITE}ELIMINAR PUERTO${RESET}"

                echo

                run_resource \
                    "delete-port.sh"

                pause

                ;;


            4|04)

                header

                echo -e \
                    "  ${BOLD}${WHITE}INICIAR / DETENER PUERTO${RESET}"

                echo

                run_resource \
                    "start-stop-port.sh"

                pause

                ;;


            0|00)

                return

                ;;


            *)

                echo

                error \
                    "Opción no válida."

                sleep 1

                ;;

        esac

    done
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
        "  ${GRAY}Abriendo comprobador independiente.${RESET}"

    echo


    run_resource \
        "status-port.sh"


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


    run_resource \
        "start-stop-service.sh"


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


    run_resource \
        "restart-service.sh"


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


    run_resource \
        "optimize.sh"


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
        "      ${GRAY}Añade, cambia, elimina o controla puertos${RESET}"

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


    prepare_dirs || {

        error \
            "No se pudo preparar el entorno temporal del panel."

        exit 1
    }


    if ! prepare_resources; then

        error \
            "No se pudo preparar completamente el panel."

        exit 1
    fi


    echo

    success \
        "Panel preparado correctamente."

    echo

    pause


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

                error \
                    "Opción no válida."

                sleep 1

                ;;

        esac

    done
}


# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
