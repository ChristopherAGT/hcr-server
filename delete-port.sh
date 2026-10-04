#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#                  HCR SERVER — ELIMINAR PUERTO
# ============================================================
# Elimina una instancia específica de HCR Server.
#
# CARACTERÍSTICAS:
#
#   - Detecta automáticamente las instancias HCR existentes.
#   - Muestra únicamente las instancias actualmente activas.
#   - Permite seleccionar la instancia mediante un menú.
#   - NO elimina el binario HCR.
#   - NO elimina certificados.
#   - NO modifica otras instancias.
#   - Detecta dinámicamente la unidad real de systemd.
#   - Detiene únicamente la instancia seleccionada.
#   - Deshabilita únicamente la instancia seleccionada.
#   - Elimina únicamente la unidad correspondiente.
#   - Verifica FragmentPath antes de eliminar.
#   - Recarga systemd después de la eliminación.
#   - Verifica que el puerto haya quedado libre.
#
# Compatible con múltiples instancias HCR Server.
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

# ============================================================
# CONFIGURACIÓN
# ============================================================

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"

MAX_DOWNLOAD_FRAME="1500"
DOWNLOAD_POLL_TIMEOUT="5s"

# ============================================================
# DETECCIÓN DE INSTALACIÓN
# ============================================================

HCR_DIR=""
BINARY_PATH=""

# ============================================================
# VARIABLES
# ============================================================

PORT=""
SERVICE_NAME_SELECTED=""
UNIT_SOURCE=""
UNIT_LINK=""
TEMP_UNIT=""

LOCK_FD_OPEN="false"
SPINNER_PID=""

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
WHITE="\033[37m"

BRIGHT_BLUE="\033[94m"
BRIGHT_CYAN="\033[96m"
BRIGHT_GREEN="\033[92m"
BRIGHT_WHITE="\033[97m"

# ============================================================
# ICONOS
# ============================================================

ICON_OK="✔"
ICON_FAIL="✖"
ICON_INFO="◆"
ICON_ARROW="➜"
ICON_WARN="!"
ICON_DOT="•"

# ============================================================
# SPINNER
# ============================================================

spinner_start() {

	local message="$1"

	# Evitar múltiples spinners simultáneos.
	spinner_stop >/dev/null 2>&1 || true

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

			printf '\r\033[K%b' \
				"${BRIGHT_CYAN}${frames[$i]}${RESET} ${WHITE}${message}${RESET}"

			i=$(( (i + 1) % ${#frames[@]} ))

			sleep 0.08

		done

	) &

	SPINNER_PID=$!
}

spinner_stop() {

	if [[ -n "${SPINNER_PID:-}" ]]; then

		kill "${SPINNER_PID}" >/dev/null 2>&1 || true

		wait "${SPINNER_PID}" 2>/dev/null || true

		SPINNER_PID=""

		printf '\r\033[K'
	fi
}

# ============================================================
# SALIDA
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
		"${BRIGHT_CYAN}${BOLD}║                  E L I M I N A R   P U E R T O             ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

	printf '\n'

	printf '%b\n' \
		"${DIM}Administrador de instancias HCR Server para Linux + systemd${RESET}"

	printf '\n'
}

section() {

	printf '\n%b\n' \
		"${BOLD}${BRIGHT_BLUE}◆ $1${RESET}"

	line
}

success() {

	printf '%b\n' \
		"${BRIGHT_GREEN}${ICON_OK}${RESET} ${GREEN}$1${RESET}"
}

info() {

	printf '%b\n' \
		"${BRIGHT_CYAN}${ICON_INFO}${RESET} ${WHITE}$1${RESET}"
}

warning() {

	printf '%b\n' \
		"${YELLOW}${ICON_WARN}${RESET} ${YELLOW}$1${RESET}"
}

error_message() {

	printf '%b\n' \
		"${RED}${ICON_FAIL}${RESET} ${RED}$1${RESET}" >&2
}

detail() {

	printf '%b\n' \
		"  ${DIM}${ICON_DOT} $1${RESET}"
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
# COMANDOS REQUERIDOS
# ============================================================

require_command() {

	local command_name="$1"

	if ! command -v "${command_name}" >/dev/null 2>&1; then

		fail \
			"No se encontró el comando requerido: ${command_name}"

	fi
}

# ============================================================
# VALIDACIÓN DE PUERTO
# ============================================================

validate_port() {

	local port="$1"

	[[ "${port}" =~ ^[0-9]+$ ]] || return 1

	(( port >= 1 && port <= 65535 ))
}

# ============================================================
# NOMBRE DEL SERVICIO
# ============================================================

service_name_for_port() {

	local port="$1"

	printf '%s-%s' \
		"${SERVICE_NAME}" \
		"${port}"
}

# ============================================================
# EXTRAER PUERTO DESDE NOMBRE DE UNIDAD
# ============================================================

port_from_unit() {

	local unit="$1"

	if [[ "${unit}" =~ ^${SERVICE_NAME}-([0-9]+)\.service$ ]]; then

		printf '%s\n' "${BASH_REMATCH[1]}"

		return 0

	fi

	return 1
}

# ============================================================
# OBTENER TODAS LAS UNIDADES HCR
# ============================================================

get_existing_hcr_units() {

	systemctl list-unit-files \
		--type=service \
		--no-legend \
		--no-pager \
		2>/dev/null |
	awk '{print $1}' |
	grep -E "^${SERVICE_NAME}-[0-9]+\.service$" |
	sort -V ||
	true
}

# ============================================================
# OBTENER INSTANCIAS ACTIVAS
# ============================================================

get_active_hcr_units() {

	local unit=""
	local active_state=""

	while IFS= read -r unit; do

		[[ -n "${unit}" ]] || continue

		active_state="$(
			systemctl is-active \
				"${unit}" \
				2>/dev/null ||
				true
		)"

		if [[ "${active_state}" == "active" ]]; then

			printf '%s\n' "${unit}"

		fi

	done < <(get_existing_hcr_units)
}

# ============================================================
# OBTENER FRAGMENTPATH REAL
# ============================================================

get_fragment_path() {

	local unit="$1"

	systemctl show \
		--property=FragmentPath \
		--value \
		"${unit}" \
		2>/dev/null ||
	true
}

# ============================================================
# DETECTAR INSTALACIÓN HCR
# ============================================================

detect_hcr_installation() {

	local unit=""
	local fragment=""
	local candidate=""
	local candidates=()

	# --------------------------------------------------------
	# Primero buscar mediante las unidades reales.
	# --------------------------------------------------------

	while IFS= read -r unit; do

		[[ -n "${unit}" ]] || continue

		fragment="$(get_fragment_path "${unit}")"

		if [[ -n "${fragment}" &&
			  -f "${fragment}" ]]; then

			candidate="$(dirname -- "${fragment}")"

			if [[ -f "${candidate}/hcr-server" ]]; then

				HCR_DIR="${candidate}"

				break

			fi

		fi

		# Revisar WorkingDirectory.

		candidate="$(
			systemctl show \
				--property=WorkingDirectory \
				--value \
				"${unit}" \
				2>/dev/null ||
				true
		)"

		if [[ -n "${candidate}" &&
			  -f "${candidate}/hcr-server" ]]; then

			HCR_DIR="${candidate}"

			break

		fi

	done < <(get_existing_hcr_units)

	# --------------------------------------------------------
	# Ubicaciones conocidas.
	# --------------------------------------------------------

	if [[ -z "${HCR_DIR}" ]]; then

		candidates=(
			"/root/.hcr-panel"
			"/opt/.hcr-panel"
			"/usr/local/lib/hcr-server"
			"/opt/hcr-server"
		)

		for candidate in "${candidates[@]}"; do

			if [[ -f "${candidate}/hcr-server" ]]; then

				HCR_DIR="${candidate}"

				break

			fi

		done

	fi

	# --------------------------------------------------------
	# No se encontró instalación.
	# --------------------------------------------------------

	if [[ -z "${HCR_DIR}" ]]; then

		fail \
			"No se encontró una instalación HCR Server existente.

Se revisaron las unidades systemd existentes y las ubicaciones
conocidas de instalación.

No se eliminará ningún archivo."

	fi

	BINARY_PATH="${HCR_DIR}/hcr-server"
}

# ============================================================
# ENTORNO
# ============================================================

require_environment() {

	if [[ "${EUID}" -ne 0 ]]; then

		fail \
			"Este script debe ejecutarse como root."

	fi

	if [[ "$(uname -s)" != "Linux" ]]; then

		fail \
			"Este script solamente funciona en Linux."

	fi

	for command_name in \
		stat \
		systemctl \
		flock \
		rm \
		sleep \
		ss \
		awk \
		grep \
		dirname \
		readlink \
		journalctl \
		sort
	do

		require_command "${command_name}"

	done

	if [[ ! -d "${SYSTEMD_DIR}" ]]; then

		fail \
			"No existe el directorio de systemd:

${SYSTEMD_DIR}"

	fi

	if ! systemctl show \
		--property=Version \
		--value >/dev/null 2>&1; then

		fail \
			"El administrador systemd no está disponible."

	fi

	detect_hcr_installation

	if [[ ! -d "${HCR_DIR}" ]]; then

		fail \
			"No existe el directorio de instalación HCR detectado:

${HCR_DIR}"

	fi

	if [[ ! "${HCR_DIR}" =~ ^/[-A-Za-z0-9._/@+:]+$ ]]; then

		fail \
			"El directorio de instalación contiene caracteres no compatibles."

	fi
}

# ============================================================
# BLOQUEO
# ============================================================

acquire_remove_port_lock() {

	local lock_file="${SYSTEMD_DIR}/.${SERVICE_NAME}.remove-port.lock"

	if ! exec 9>"${lock_file}"; then

		fail \
			"No se pudo crear el bloqueo de HCR Server."

	fi

	if ! flock -n 9; then

		fail \
			"Ya existe otra operación de HCR Server en curso."

	fi

	LOCK_FD_OPEN="true"
}

release_remove_port_lock() {

	if [[ "${LOCK_FD_OPEN}" == "true" ]]; then

		flock -u 9 >/dev/null 2>&1 || true

		exec 9>&-

		LOCK_FD_OPEN="false"

	fi
}

# ============================================================
# MOSTRAR PUERTOS ACTIVOS
# ============================================================

select_active_port() {

	local units=()
	local unit=""
	local port=""
	local active_state=""
	local index=1
	local selection=""

	section "Instancias HCR activas"

	while IFS= read -r unit; do

		[[ -n "${unit}" ]] || continue

		units+=("${unit}")

	done < <(get_active_hcr_units)

	if (( ${#units[@]} == 0 )); then

		fail \
			"No se encontraron instancias HCR Server activas.

No hay ningún puerto HCR activo para eliminar."

	fi

	printf '%b\n\n' \
		"${WHITE}Selecciona el puerto que deseas eliminar:${RESET}"

	for unit in "${units[@]}"; do

		port="$(port_from_unit "${unit}")"

		active_state="$(
			systemctl is-active \
				"${unit}" \
				2>/dev/null ||
				true
		)"

		printf '%b\n' \
			"  ${BRIGHT_CYAN}${index})${RESET} ${BRIGHT_WHITE}Puerto ${port}${RESET} ${DIM}— ${unit} — ${active_state}${RESET}"

		index=$((index + 1))

	done

	printf '\n'

	while true; do

		printf \
			"${WHITE}Opción [1-${#units[@]}]${RESET}: "

		read -r selection

		if [[ ! "${selection}" =~ ^[0-9]+$ ]]; then

			error_message \
				"Debes seleccionar una opción numérica."

			continue

		fi

		if (( selection < 1 || selection > ${#units[@]} )); then

			error_message \
				"Opción fuera de rango."

			continue

		fi

		break

	done

	SERVICE_NAME_SELECTED="${units[$((selection - 1))]}"

	PORT="$(port_from_unit "${SERVICE_NAME_SELECTED}")"

	UNIT_SOURCE="$(get_fragment_path "${SERVICE_NAME_SELECTED}")"

	UNIT_LINK="${SYSTEMD_DIR}/${SERVICE_NAME_SELECTED}"

	printf '\n'

	success \
		"Instancia seleccionada."

	detail \
		"Puerto: ${PORT}"

	detail \
		"Servicio: ${SERVICE_NAME_SELECTED}"

	detail \
		"FragmentPath: ${UNIT_SOURCE}"

	# --------------------------------------------------------
	# Validar que el puerto sea correcto.
	# --------------------------------------------------------

	if ! validate_port "${PORT}"; then

		fail \
			"No se pudo determinar correctamente el puerto de la instancia."

	fi

	# --------------------------------------------------------
	# Validar FragmentPath.
	# --------------------------------------------------------

	if [[ -z "${UNIT_SOURCE}" ]]; then

		fail \
			"systemd no devolvió el FragmentPath de:

${SERVICE_NAME_SELECTED}"

	fi

	if [[ ! -e "${UNIT_SOURCE}" ]]; then

		fail \
			"El FragmentPath de la instancia no existe:

${UNIT_SOURCE}"

	fi
}

# ============================================================
# VALIDAR UNIDAD OBJETIVO
# ============================================================

validate_target_unit() {

	local fragment=""
	local exec_start=""
	local expected_service=""

	section "Comprobando instancia seleccionada"

	expected_service="${SERVICE_NAME_SELECTED}"

	# --------------------------------------------------------
	# La unidad debe existir.
	# --------------------------------------------------------

	if [[ ! -e "${UNIT_SOURCE}" ]]; then

		fail \
			"No existe la unidad seleccionada:

${UNIT_SOURCE}"

	fi

	success \
		"Unidad encontrada."

	# --------------------------------------------------------
	# FragmentPath debe ser exactamente la unidad seleccionada.
	# --------------------------------------------------------

	fragment="$(get_fragment_path "${expected_service}")"

	if [[ -z "${fragment}" ]]; then

		fail \
			"systemd no devolvió FragmentPath para:

${expected_service}"

	fi

	if [[ "${fragment}" != "${UNIT_SOURCE}" ]]; then

		fail \
			"El FragmentPath cambió inesperadamente.

Esperado:
${UNIT_SOURCE}

Detectado:
${fragment}"

	fi

	success \
		"FragmentPath verificado."

	# --------------------------------------------------------
	# Verificar propietario cuando sea un archivo normal.
	# --------------------------------------------------------

	if [[ -f "${UNIT_SOURCE}" &&
		  ! -L "${UNIT_SOURCE}" ]]; then

		if [[ "$(stat -c '%u' -- "${UNIT_SOURCE}")" != "0" ]]; then

			fail \
				"La unidad seleccionada no pertenece a root:

${UNIT_SOURCE}"

		fi

		success \
			"La unidad pertenece a root."

	fi

	# --------------------------------------------------------
	# Verificar ExecStart.
	#
	# No se exige una cadena exacta porque systemd puede mostrar
	# ExecStart con una representación diferente dependiendo de
	# la versión de systemd.
	# --------------------------------------------------------

	exec_start="$(
		systemctl show \
			--property=ExecStart \
			--value \
			"${expected_service}" \
			2>/dev/null ||
			true
	)"

	if [[ -n "${exec_start}" ]]; then

		info \
			"ExecStart detectado correctamente."

	else

		warning \
			"No se pudo obtener ExecStart; se continuará usando
la identidad de la unidad y su FragmentPath."

	fi
}

# ============================================================
# MOSTRAR ESTADO
# ============================================================

show_target_status() {

	local active_state=""
	local enabled_state=""
	local fragment=""

	section "Estado de la instancia"

	active_state="$(
		systemctl is-active \
			"${SERVICE_NAME_SELECTED}" \
			2>/dev/null ||
			true
	)"

	enabled_state="$(
		systemctl is-enabled \
			"${SERVICE_NAME_SELECTED}" \
			2>/dev/null ||
			true
	)"

	fragment="$(get_fragment_path "${SERVICE_NAME_SELECTED}")"

	detail \
		"Servicio: ${SERVICE_NAME_SELECTED}"

	detail \
		"Puerto: ${PORT}"

	detail \
		"Estado: ${active_state:-desconocido}"

	detail \
		"Inicio automático: ${enabled_state:-desconocido}"

	detail \
		"FragmentPath: ${fragment:-no disponible}"

	if [[ "${active_state}" == "active" ]]; then

		success \
			"La instancia está actualmente activa."

	else

		warning \
			"La instancia ya no aparece activa."

	fi
}

# ============================================================
# VERIFICAR LISTENER
# ============================================================

check_hcr_listener() {

	local port="$1"

	ss -H -lnt 2>/dev/null |
		awk -v port="${port}" '
			{
				address = $4

				sub(/^.*:/, "", address)

				if (address == port) {
					found = 1
					exit
				}
			}

			END {
				if (found) {
					exit 0
				}

				exit 1
			}
		'
}

# ============================================================
# DETENER SERVICIO
# ============================================================

stop_service() {

	local active_state=""

	section "Deteniendo instancia"

	active_state="$(
		systemctl is-active \
			"${SERVICE_NAME_SELECTED}" \
			2>/dev/null ||
			true
	)"

	if [[ "${active_state}" != "active" ]]; then

		info \
			"La instancia ya estaba detenida."

		return 0

	fi

	spinner_start \
		"Deteniendo HCR Server en puerto ${PORT}..."

	if systemctl stop \
		"${SERVICE_NAME_SELECTED}" >/dev/null 2>&1; then

		spinner_stop

		success \
			"HCR Server detenido correctamente."

	else

		spinner_stop

		printf '\n'

		error_message \
			"No se pudo detener HCR Server."

		systemctl status \
			--no-pager \
			--full \
			"${SERVICE_NAME_SELECTED}" ||
			true

		fail \
			"La instancia no pudo detenerse."

	fi
}

# ============================================================
# DESHABILITAR SERVICIO
# ============================================================

disable_service() {

	section "Deshabilitando inicio automático"

	if systemctl is-enabled --quiet \
		"${SERVICE_NAME_SELECTED}" >/dev/null 2>&1; then

		spinner_start \
			"Deshabilitando inicio automático..."

		if systemctl disable \
			"${SERVICE_NAME_SELECTED}" >/dev/null 2>&1; then

			spinner_stop

			success \
				"Inicio automático deshabilitado."

		else

			spinner_stop

			fail \
				"No se pudo deshabilitar el servicio."

		fi

	else

		info \
			"La instancia ya estaba deshabilitada."

	fi
}

# ============================================================
# ELIMINAR UNIDAD
# ============================================================

remove_unit() {

	section "Eliminando instancia HCR Server"

	# --------------------------------------------------------
	# Verificar nuevamente que la unidad siga siendo la misma.
	# --------------------------------------------------------

	local current_fragment=""

	current_fragment="$(get_fragment_path "${SERVICE_NAME_SELECTED}")"

	if [[ -n "${current_fragment}" &&
		  "${current_fragment}" != "${UNIT_SOURCE}" ]]; then

		fail \
			"La unidad cambió durante la operación.

Original:
${UNIT_SOURCE}

Actual:
${current_fragment}"

	fi

	# --------------------------------------------------------
	# Eliminar enlace / unidad en /etc/systemd/system.
	# --------------------------------------------------------

	if [[ -L "${UNIT_LINK}" ]]; then

		local link_target=""

		link_target="$(readlink -- "${UNIT_LINK}")"

		# Resolver enlace relativo si fuera necesario.
		if [[ "${link_target}" != /* ]]; then

			link_target="$(
				cd "$(dirname -- "${UNIT_LINK}")" &&
				readlink -f -- "${link_target}"
			)"

		fi

		local resolved_source=""

		resolved_source="$(readlink -f -- "${UNIT_SOURCE}" 2>/dev/null || true)"

		if [[ -n "${resolved_source}" &&
			  -n "${link_target}" &&
			  "${link_target}" != "${resolved_source}" ]]; then

			fail \
				"El enlace systemd no apunta a la unidad seleccionada:

${UNIT_LINK}

Destino:
${link_target}

Esperado:
${resolved_source}"

		fi

		spinner_start \
			"Eliminando enlace systemd..."

		if rm -f -- "${UNIT_LINK}"; then

			spinner_stop

			success \
				"Enlace systemd eliminado."

		else

			spinner_stop

			fail \
				"No se pudo eliminar el enlace systemd."

		fi

	elif [[ -f "${UNIT_LINK}" ]]; then

		# Si el FragmentPath está directamente en /etc/systemd,
		# UNIT_LINK y UNIT_SOURCE pueden ser el mismo archivo.
		if [[ "${UNIT_LINK}" == "${UNIT_SOURCE}" ]]; then

			info \
				"La unidad está instalada directamente en systemd."

		else

			fail \
				"Existe un archivo en ${UNIT_LINK}, pero no es un enlace
simbólico y no coincide con la unidad seleccionada."

		fi

	elif [[ -e "${UNIT_LINK}" ]]; then

		fail \
			"Existe un objeto no compatible en:

${UNIT_LINK}"

	fi

	# --------------------------------------------------------
	# Si la unidad fuente es diferente del enlace, eliminarla.
	# --------------------------------------------------------

	if [[ "${UNIT_SOURCE}" != "${UNIT_LINK}" ]]; then

		if [[ -L "${UNIT_SOURCE}" ]]; then

			spinner_start \
				"Eliminando enlace de la unidad fuente..."

			if rm -f -- "${UNIT_SOURCE}"; then

				spinner_stop

				success \
					"Enlace de la unidad fuente eliminado."

			else

				spinner_stop

				fail \
					"No se pudo eliminar el enlace de la unidad fuente."

			fi

		elif [[ -f "${UNIT_SOURCE}" ]]; then

			spinner_start \
				"Eliminando unidad HCR Server..."

			if rm -f -- "${UNIT_SOURCE}"; then

				spinner_stop

				success \
					"Unidad HCR Server eliminada."

			else

				spinner_stop

				fail \
					"No se pudo eliminar la unidad HCR Server."

			fi

		elif [[ -e "${UNIT_SOURCE}" ]]; then

			fail \
				"La unidad fuente existe pero no es un archivo regular
ni un enlace simbólico:

${UNIT_SOURCE}"

		else

			info \
				"La unidad fuente ya no existe."

		fi

	else

		# La unidad estaba directamente en /etc/systemd/system.
		if [[ -f "${UNIT_SOURCE}" ]]; then

			spinner_start \
				"Eliminando unidad HCR Server..."

			if rm -f -- "${UNIT_SOURCE}"; then

				spinner_stop

				success \
					"Unidad HCR Server eliminada."

			else

				spinner_stop

				fail \
					"No se pudo eliminar la unidad HCR Server."

			fi

		elif [[ -L "${UNIT_SOURCE}" ]]; then

			spinner_start \
				"Eliminando unidad HCR Server..."

			if rm -f -- "${UNIT_SOURCE}"; then

				spinner_stop

				success \
					"Unidad HCR Server eliminada."

			else

				spinner_stop

				fail \
					"No se pudo eliminar la unidad HCR Server."

			fi

		else

			info \
				"La unidad ya no existe."

		fi

	fi
}

# ============================================================
# RECARGAR SYSTEMD
# ============================================================

reload_systemd() {

	section "Actualizando systemd"

	spinner_start \
		"Recargando configuración de systemd..."

	if systemctl daemon-reload >/dev/null 2>&1; then

		spinner_stop

		success \
			"systemd recargado correctamente."

	else

		spinner_stop

		fail \
			"No se pudo recargar systemd."

	fi

	systemctl reset-failed \
		"${SERVICE_NAME_SELECTED}" >/dev/null 2>&1 ||
		true
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_removal() {

	local fragment=""
	local active_state=""
	local enabled_state=""

	section "Verificación final"

	# --------------------------------------------------------
	# Verificar archivo de unidad.
	# --------------------------------------------------------

	if [[ ! -e "${UNIT_SOURCE}" &&
		  ! -L "${UNIT_SOURCE}" ]]; then

		success \
			"Unidad eliminada del sistema de archivos."

	else

		error_message \
			"La unidad todavía existe:

${UNIT_SOURCE}"

		return 1

	fi

	# --------------------------------------------------------
	# Verificar enlace /etc/systemd/system.
	# --------------------------------------------------------

	if [[ ! -e "${UNIT_LINK}" &&
		  ! -L "${UNIT_LINK}" ]]; then

		success \
			"La ruta de systemd quedó limpia."

	else

		error_message \
			"La unidad todavía existe en:

${UNIT_LINK}"

		return 1

	fi

	# --------------------------------------------------------
	# Verificar FragmentPath.
	# --------------------------------------------------------

	fragment="$(get_fragment_path "${SERVICE_NAME_SELECTED}")"

	if [[ -z "${fragment}" ]]; then

		success \
			"systemd ya no tiene registrada la unidad."

	else

		error_message \
			"systemd todavía detecta la unidad:

${fragment}"

		return 1

	fi

	# --------------------------------------------------------
	# Estado activo.
	# --------------------------------------------------------

	active_state="$(
		systemctl is-active \
			"${SERVICE_NAME_SELECTED}" \
			2>/dev/null ||
			true
	)"

	if [[ "${active_state}" == "active" ]]; then

		error_message \
			"La instancia todavía aparece activa."

		return 1

	fi

	success \
		"La instancia ya no está activa."

	# --------------------------------------------------------
	# Estado enabled.
	# --------------------------------------------------------

	enabled_state="$(
		systemctl is-enabled \
			"${SERVICE_NAME_SELECTED}" \
			2>/dev/null ||
			true
	)"

	if [[ "${enabled_state}" == "enabled" ]]; then

		error_message \
			"La instancia todavía aparece habilitada."

		return 1

	fi

	success \
		"El inicio automático fue eliminado."

	# --------------------------------------------------------
	# Listener.
	# --------------------------------------------------------

	if check_hcr_listener "${PORT}"; then

		error_message \
			"El puerto ${PORT} todavía aparece escuchando."

		ss -lntp "sport = :${PORT}" 2>/dev/null ||
			true

		return 1

	fi

	success \
		"El puerto ${PORT} ya no está siendo escuchado."

	return 0
}

# ============================================================
# DIAGNÓSTICO
# ============================================================

show_service_diagnostics() {

	printf '\n'

	detail \
		"Últimos registros de la instancia eliminada:"

	journalctl \
		-u "${SERVICE_NAME_SELECTED}" \
		-n 30 \
		--no-pager \
		--output=short-iso ||
		true
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {

	clear_screen

	printf '\n'

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║             ✔ PUERTO ELIMINADO CORRECTAMENTE              ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Instancia eliminada:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Puerto HCR       : ${BRIGHT_WHITE}${PORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Servicio          : ${BRIGHT_WHITE}${SERVICE_NAME_SELECTED}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Estado            : ${BRIGHT_GREEN}Eliminado${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Inicio automático : ${BRIGHT_GREEN}Eliminado${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Unidad eliminada:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} FragmentPath : ${BRIGHT_WHITE}${UNIT_SOURCE}${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Archivos conservados:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Binario        : ${BRIGHT_GREEN}Conservado${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Certificados   : ${BRIGHT_GREEN}Conservados${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Otras instancias: ${BRIGHT_GREEN}Sin modificar${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}La instancia HCR del puerto ${PORT} fue eliminada correctamente.${RESET}"

	printf '%b\n' \
		"${DIM}El binario y la instalación principal de HCR Server permanecen intactos.${RESET}"

	printf '%b\n' \
		"${DIM}Las demás instancias HCR Server no fueron modificadas.${RESET}"

	printf '\n'

	line

	printf '\n'
}

# ============================================================
# LIMPIEZA
# ============================================================

cleanup() {

	local exit_code=$?

	trap - EXIT

	set +e

	spinner_stop

	if [[ -n "${TEMP_UNIT:-}" ]]; then

		rm -f \
			-- "${TEMP_UNIT}" >/dev/null 2>&1 ||
			true

	fi

	if [[ "${LOCK_FD_OPEN:-false}" == "true" ]]; then

		release_remove_port_lock

	fi

	exit "${exit_code}"
}

# ============================================================
# MAIN
# ============================================================

main() {

	header

	# --------------------------------------------------------
	# ENTORNO
	# --------------------------------------------------------

	section "Verificando entorno"

	spinner_start \
		"Comprobando permisos, Linux y systemd..."

	if require_environment >/dev/null 2>&1; then

		spinner_stop

		success \
			"Entorno Linux + systemd válido."

		info \
			"Instalación HCR detectada: ${HCR_DIR}"

		info \
			"Binario HCR: ${BINARY_PATH}"

	else

		spinner_stop

		fail \
			"El entorno no cumple los requisitos."

	fi

	# --------------------------------------------------------
	# BLOQUEO
	# --------------------------------------------------------

	spinner_start \
		"Adquiriendo bloqueo de HCR Server..."

	if acquire_remove_port_lock >/dev/null 2>&1; then

		spinner_stop

		success \
			"Bloqueo adquirido."

	else

		spinner_stop

		fail \
			"No se pudo adquirir el bloqueo."

	fi

	# --------------------------------------------------------
	# SELECCIÓN
	# --------------------------------------------------------

	select_active_port

	# --------------------------------------------------------
	# VALIDAR UNIDAD
	# --------------------------------------------------------

	validate_target_unit

	# --------------------------------------------------------
	# ESTADO
	# --------------------------------------------------------

	show_target_status

	# --------------------------------------------------------
	# RESUMEN PREVIO
	# --------------------------------------------------------

	section "Resumen de eliminación"

	detail \
		"Instancia: ${SERVICE_NAME_SELECTED}"

	detail \
		"Puerto HCR: ${PORT}"

	detail \
		"Unidad real: ${UNIT_SOURCE}"

	detail \
		"Ruta systemd: ${UNIT_LINK}"

	detail \
		"Binario HCR: ${BINARY_PATH}"

	detail \
		"Frame de descarga de referencia: ${MAX_DOWNLOAD_FRAME}"

	detail \
		"Poll timeout de referencia: ${DOWNLOAD_POLL_TIMEOUT}"

	printf '\n'

	warning \
		"Se eliminará únicamente la instancia ${SERVICE_NAME_SELECTED}."

	warning \
		"El binario HCR Server NO será eliminado."

	warning \
		"Los certificados TLS NO serán eliminados."

	warning \
		"Las demás instancias HCR Server NO serán modificadas."

	printf '\n'

	read -r -p \
		"¿Deseas eliminar esta instancia? [s/N]: " answer

	case "${answer,,}" in

		s|si|sí|y|yes)

			printf '\n'

			;;

		*)

			info \
				"Operación cancelada."

			exit 0

			;;

	esac

	# --------------------------------------------------------
	# DETENER
	# --------------------------------------------------------

	stop_service

	# --------------------------------------------------------
	# DESHABILITAR
	# --------------------------------------------------------

	disable_service

	# --------------------------------------------------------
	# ELIMINAR UNIDAD
	# --------------------------------------------------------

	remove_unit

	# --------------------------------------------------------
	# SYSTEMD
	# --------------------------------------------------------

	reload_systemd

	# --------------------------------------------------------
	# VERIFICACIÓN
	# --------------------------------------------------------

	if ! verify_removal; then

		printf '\n'

		error_message \
			"La verificación final encontró problemas."

		show_service_diagnostics

		fail \
			"La instancia no fue eliminada completamente."

	fi

	# --------------------------------------------------------
	# RESUMEN
	# --------------------------------------------------------

	show_summary
}

# ============================================================
# TRAPS
# ============================================================

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================
# EJECUCIÓN
# ============================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

	main "$@"

fi
