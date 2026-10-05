#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#                  HCR SERVER
#             INICIAR / DETENER PUERTOS
# ============================================================
#
# Este script SOLO permite:
#
#   - Detectar las instancias HCR existentes
#   - Mostrar sus puertos
#   - Mostrar el estado de cada puerto
#   - Iniciar una instancia detenida
#   - Detener una instancia activa
#   - Salir
#
# Al seleccionar un puerto:
#
#   [Encendido] -> se detiene
#   [Apagado]   -> se inicia
#
# Este script NO:
#
#   - Instala HCR Server
#   - Crea unidades systemd
#   - Modifica unidades systemd
#   - Elimina unidades
#   - Configura puertos
#   - Configura TLS
#   - Modifica parámetros de HCR
#
# ============================================================

set -o pipefail

# ------------------------------------------------------------
# CONFIGURACIÓN
# ------------------------------------------------------------

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

export PATH LC_ALL LANG

SERVICE_PREFIX="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"

# ------------------------------------------------------------
# COLORES
# ------------------------------------------------------------

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
WHITE="\033[37m"

BRIGHT_BLUE="\033[94m"
BRIGHT_CYAN="\033[96m"
BRIGHT_GREEN="\033[92m"
BRIGHT_WHITE="\033[97m"

# ------------------------------------------------------------
# ICONOS
# ------------------------------------------------------------

ICON_OK="✔"
ICON_FAIL="✖"
ICON_INFO="◆"
ICON_ARROW="➜"
ICON_WARN="!"
ICON_DOT="•"

# ------------------------------------------------------------
# ARRAYS
# ------------------------------------------------------------

PORTS=()
SERVICES=()

# ------------------------------------------------------------
# FUNCIONES VISUALES
# ------------------------------------------------------------

clear_screen() {
	printf '\033[2J\033[H'
}

line() {
	printf "${DIM}${CYAN}────────────────────────────────────────────────────────────${RESET}\n"
}

header() {

	clear_screen

	printf "\n"

	printf "${BRIGHT_CYAN}${BOLD}"

	printf "╔════════════════════════════════════════════════════════════╗\n"
	printf "║                                                            ║\n"
	printf "║                 H C R   S E R V E R                       ║\n"
	printf "║                                                            ║\n"
	printf "║             I N I C I A R  /  D E T E N E R              ║\n"
	printf "║                     P U E R T O S                          ║\n"
	printf "║                                                            ║\n"
	printf "╚════════════════════════════════════════════════════════════╝\n"

	printf "${RESET}\n"

	printf "${DIM}Control independiente de puertos HCR + systemd${RESET}\n"

	printf "\n"
}

section() {

	printf "\n${BOLD}${BRIGHT_BLUE}◆ %s${RESET}\n" "$1"

	line
}

success() {

	printf \
		"${BRIGHT_GREEN}${ICON_OK}${RESET} ${GREEN}%s${RESET}\n" \
		"$1"
}

info() {

	printf \
		"${BRIGHT_CYAN}${ICON_INFO}${RESET} ${WHITE}%s${RESET}\n" \
		"$1"
}

warning() {

	printf \
		"${YELLOW}${ICON_WARN}${RESET} ${YELLOW}%s${RESET}\n" \
		"$1"
}

error_message() {

	printf \
		"${RED}${ICON_FAIL}${RESET} ${RED}%s${RESET}\n" \
		"$1" >&2
}

detail() {

	printf \
		"  ${DIM}${ICON_DOT} %s${RESET}\n" \
		"$1"
}

# ------------------------------------------------------------
# SPINNER
# ------------------------------------------------------------

SPINNER_PID=""

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

			printf \
				"\r${BRIGHT_CYAN}%s${RESET} ${WHITE}%s${RESET}" \
				"${frames[$i]}" \
				"${message}"

			i=$(( (i + 1) % ${#frames[@]} ))

			sleep 0.08

		done
	) &

	SPINNER_PID=$!
}

spinner_stop() {

	local status="$1"

	if [ -n "${SPINNER_PID}" ]; then

		kill "${SPINNER_PID}" >/dev/null 2>&1 || true

		wait "${SPINNER_PID}" 2>/dev/null || true

		SPINNER_PID=""

	fi

	printf "\r\033[K"

	if [ "${status}" = "ok" ]; then

		success "Completado"

	else

		error_message "Falló"

	fi
}

# ------------------------------------------------------------
# ERROR
# ------------------------------------------------------------

fail() {

	error_message "$*"

	exit 1
}

# ------------------------------------------------------------
# VALIDACIÓN DEL ENTORNO
# ------------------------------------------------------------

require_command() {

	command -v "$1" >/dev/null 2>&1 ||
		fail "No se encontró el comando requerido: $1"
}

require_environment() {

	[ "$(id -u)" -eq 0 ] ||
		fail "Este script debe ejecutarse como root."

	[ "$(uname -s)" = "Linux" ] ||
		fail "Este script solamente es compatible con Linux."

	for command_name in \
		systemctl \
		find \
		basename \
		sort \
		sleep
	do

		require_command "${command_name}"

	done

	systemctl show \
		--property=Version \
		--value >/dev/null 2>&1 ||
		fail "El administrador systemd no está disponible."

	[ -d "${SYSTEMD_DIR}" ] ||
		fail \
			"No existe el directorio de unidades systemd: ${SYSTEMD_DIR}"
}

# ------------------------------------------------------------
# NOMBRE DEL SERVICIO
# ------------------------------------------------------------

service_name_for_port() {

	local port="$1"

	printf "%s-%s" \
		"${SERVICE_PREFIX}" \
		"${port}"
}

# ------------------------------------------------------------
# VALIDACIÓN DE PUERTO
# ------------------------------------------------------------

validate_port() {

	local port="$1"

	[[ "${port}" =~ ^[0-9]+$ ]] ||
		return 1

	(( port >= 1 && port <= 65535 ))
}

# ------------------------------------------------------------
# DETECTAR INSTANCIAS HCR
# ------------------------------------------------------------

discover_instances() {

	local unit
	local filename
	local port
	local service_name

	PORTS=()
	SERVICES=()

	while IFS= read -r unit; do

		[ -n "${unit}" ] || continue

		filename="$(basename -- "${unit}")"

		if [[ "${filename}" =~ ^${SERVICE_PREFIX}-([0-9]+)\.service$ ]]; then

			port="${BASH_REMATCH[1]}"

			if ! validate_port "${port}"; then
				continue
			fi

			service_name="${SERVICE_PREFIX}-${port}"

			PORTS+=("${port}")
			SERVICES+=("${service_name}")

		fi

	done < <(
		find \
			"${SYSTEMD_DIR}" \
			-maxdepth 1 \
			\( -type f -o -type l \) \
			-name "${SERVICE_PREFIX}-*.service" \
			-print
	)

	# --------------------------------------------------------
	# ORDENAR PUERTOS NUMÉRICAMENTE
	# --------------------------------------------------------

	if [ "${#PORTS[@]}" -gt 1 ]; then

		local combined=()
		local i

		for i in "${!PORTS[@]}"; do

			combined+=(
				"${PORTS[$i]}:${SERVICES[$i]}"
			)

		done

		mapfile -t combined < <(
			printf '%s\n' "${combined[@]}" |
				sort -t ':' -k1,1n
		)

		PORTS=()
		SERVICES=()

		for unit in "${combined[@]}"; do

			port="${unit%%:*}"
			service_name="${unit#*:}"

			PORTS+=("${port}")
			SERVICES+=("${service_name}")

		done

	fi
}

# ------------------------------------------------------------
# ESTADO DE LA INSTANCIA
# ------------------------------------------------------------

get_service_state() {

	local service_name="$1"

	if systemctl is-active --quiet \
		"${service_name}.service"; then

		printf "active"

	else

		printf "inactive"

	fi
}

# ------------------------------------------------------------
# MOSTRAR ESTADO
# ------------------------------------------------------------

print_service_state() {

	local service_name="$1"
	local state

	state="$(get_service_state "${service_name}")"

	if [ "${state}" = "active" ]; then

		printf "${BRIGHT_GREEN}[Encendido]${RESET}"

	else

		printf "${RED}[Apagado]${RESET}"

	fi
}

# ------------------------------------------------------------
# MOSTRAR LISTA
# ------------------------------------------------------------

show_instances() {

	local i
	local number
	local port
	local service_name

	header

	section "Puertos HCR Server"

	if [ "${#PORTS[@]}" -eq 0 ]; then

		printf "\n"

		warning "No se encontraron instancias HCR Server."

		printf "\n"

		printf \
			"  ${BRIGHT_WHITE}00${RESET} ${CYAN}${ICON_ARROW}${RESET} Salir\n"

		printf "\n"

		line

		printf "\n"

		return 0
	fi

	printf "\n"

	for i in "${!PORTS[@]}"; do

		number=$((i + 1))
		port="${PORTS[$i]}"
		service_name="${SERVICES[$i]}"

		printf \
			"  ${BRIGHT_WHITE}%02d${RESET} ${CYAN}${ICON_ARROW}${RESET} Puerto ${BRIGHT_WHITE}%-6s${RESET} " \
			"${number}" \
			"${port}"

		print_service_state "${service_name}"

		printf "\n"

	done

	printf "\n"

	printf \
		"  ${BRIGHT_WHITE}00${RESET} ${CYAN}${ICON_ARROW}${RESET} Salir\n"

	printf "\n"

	line

	printf "\n"

	printf \
		"${WHITE}Selecciona un puerto: ${RESET}"
}

# ------------------------------------------------------------
# INICIAR PUERTO
# ------------------------------------------------------------

start_instance() {

	local port="$1"
	local service_name

	service_name="$(service_name_for_port "${port}")"

	spinner_start \
		"Iniciando HCR Server en puerto ${port}..."

	if systemctl start \
		"${service_name}.service" >/dev/null 2>&1; then

		spinner_stop ok

	else

		spinner_stop fail

		error_message \
			"No se pudo iniciar HCR Server en el puerto ${port}."

		return 1
	fi

	return 0
}

# ------------------------------------------------------------
# DETENER PUERTO
# ------------------------------------------------------------

stop_instance() {

	local port="$1"
	local service_name

	service_name="$(service_name_for_port "${port}")"

	spinner_start \
		"Deteniendo HCR Server en puerto ${port}..."

	if systemctl stop \
		"${service_name}.service" >/dev/null 2>&1; then

		spinner_stop ok

	else

		spinner_stop fail

		error_message \
			"No se pudo detener HCR Server en el puerto ${port}."

		return 1
	fi

	return 0
}

# ------------------------------------------------------------
# CAMBIAR ESTADO DEL PUERTO
# ------------------------------------------------------------

toggle_instance() {

	local index="$1"
	local port
	local service_name
	local current_state

	port="${PORTS[$index]}"
	service_name="${SERVICES[$index]}"

	current_state="$(get_service_state "${service_name}")"

	printf "\n"

	# --------------------------------------------------------
	# ENCENDIDO -> APAGAR
	# --------------------------------------------------------

	if [ "${current_state}" = "active" ]; then

		if stop_instance "${port}"; then

			sleep 0.3

			if [ "$(get_service_state "${service_name}")" = "active" ]; then

				error_message \
					"El puerto ${port} continúa encendido."

			else

				success \
					"Puerto ${port}: ${RED}Apagado${RESET}"

			fi

		fi

	# --------------------------------------------------------
	# APAGADO -> ENCENDER
	# --------------------------------------------------------

	else

		if start_instance "${port}"; then

			sleep 0.3

			if [ "$(get_service_state "${service_name}")" = "active" ]; then

				success \
					"Puerto ${port}: ${BRIGHT_GREEN}Encendido${RESET}"

			else

				error_message \
					"El puerto ${port} no quedó encendido."

			fi

		fi

	fi

	printf "\n"

	sleep 0.8
}

# ------------------------------------------------------------
# BUCLE PRINCIPAL
# ------------------------------------------------------------

main_loop() {

	local input
	local selected_index
	local max_index

	while true; do

		# ----------------------------------------------------
		# DETECTAR NUEVAMENTE LAS INSTANCIAS EN CADA CICLO
		# ----------------------------------------------------

		discover_instances

		show_instances

		# ----------------------------------------------------
		# SI NO EXISTEN INSTANCIAS
		# ----------------------------------------------------

		if [ "${#PORTS[@]}" -eq 0 ]; then

			read -r input

			# 0 y 00 permiten salir.
			# Visualmente solo se muestra 00.

			if [[ "${input}" == "0" || "${input}" == "00" ]]; then
				break
			fi

			continue
		fi

		read -r input

		# ----------------------------------------------------
		# SALIR
		#
		# Acepta:
		#   0
		#   00
		#
		# Pero visualmente solamente se muestra:
		#
		#   00 ➜ Salir
		# ----------------------------------------------------

		if [[ "${input}" == "0" || "${input}" == "00" ]]; then

			break

		fi

		# ----------------------------------------------------
		# VALIDAR ENTRADA
		# ----------------------------------------------------

		if ! [[ "${input}" =~ ^[0-9]+$ ]]; then

			printf "\n"

			error_message \
				"Selección no válida."

			sleep 1

			continue
		fi

		# ----------------------------------------------------
		# CONVERTIR SELECCIÓN A ÍNDICE DEL ARRAY
		# ----------------------------------------------------

		selected_index=$((10#${input} - 1))

		max_index=$(( ${#PORTS[@]} - 1 ))

		if (( selected_index < 0 )) ||
			(( selected_index > max_index )); then

			printf "\n"

			error_message \
				"El puerto seleccionado no existe."

			sleep 1

			continue
		fi

		# ----------------------------------------------------
		# TOGGLE
		#
		# Encendido -> Apagado
		# Apagado   -> Encendido
		# ----------------------------------------------------

		toggle_instance "${selected_index}"

	done
}

# ------------------------------------------------------------
# SALIDA
# ------------------------------------------------------------

show_exit_message() {

	clear_screen

	printf "\n"

	printf "${BRIGHT_CYAN}${BOLD}"

	printf "╔════════════════════════════════════════════════════════════╗\n"
	printf "║                                                            ║\n"
	printf "║                 H C R   S E R V E R                       ║\n"
	printf "║                                                            ║\n"
	printf "║                  H A S T A   L U E G O                    ║\n"
	printf "║                                                            ║\n"
	printf "╚════════════════════════════════════════════════════════════╝\n"

	printf "${RESET}\n"

	printf "${DIM}Control de puertos cerrado.${RESET}\n"

	printf "\n"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {

	require_environment

	main_loop

	show_exit_message
}

# ------------------------------------------------------------
# EJECUCIÓN
# ------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

	main "$@"

fi
