#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#                  HCR SERVER — ELIMINAR PUERTO
# ============================================================
# Elimina una instancia específica de HCR Server.
#
# CARACTERÍSTICAS:
#
#   - NO elimina el binario HCR.
#   - NO elimina certificados.
#   - NO modifica otras instancias.
#   - NO supone que existan puertos concretos.
#   - Detecta dinámicamente las instancias HCR existentes.
#   - Detiene únicamente la instancia seleccionada.
#   - Deshabilita únicamente la instancia seleccionada.
#   - Elimina únicamente la unidad correspondiente al puerto.
#   - Verifica la unidad antes de eliminarla.
#   - Recarga systemd después de la eliminación.
#   - Verifica que el puerto deje de escuchar.
#   - Utiliza bloqueo para evitar operaciones simultáneas.
#
# Estructura esperada:
#
#   /root/.hcr-panel/
#   ├── hcr-server
#   ├── fullchain.pem
#   └── privkey.pem
#
# Las unidades pueden encontrarse en:
#
#   /root/.hcr-panel/hcr-server-XXXX.service
#   /etc/systemd/system/hcr-server-XXXX.service
#
# Parámetros de referencia:
#
#   MAX_DOWNLOAD_FRAME=1500
#   DOWNLOAD_POLL_TIMEOUT=5s
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

	spinner_stop

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
				"${BRIGHT_CYAN}${frames[$i]}${RESET} ${WHITE}${message}${RESET}"

			i=$(( (i + 1) % ${#frames[@]} ))

			sleep 0.08

		done

	) &

	SPINNER_PID=$!
}

spinner_stop() {

	local pid="${SPINNER_PID}"

	SPINNER_PID=""

	if [[ -n "${pid}" ]]; then

		kill "${pid}" >/dev/null 2>&1 || true

		wait "${pid}" 2>/dev/null || true

	fi

	printf '\r\033[K'
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

	[[ "${port}" =~ ^[0-9]+$ ]] ||
		return 1

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
# RUTA DE UNIDAD ESPERADA
# ============================================================

unit_source_path_for_port() {

	local port="$1"

	printf '%s/%s-%s.service' \
		"${HCR_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

# ============================================================
# RUTA SYSTEMD
# ============================================================

unit_link_path_for_port() {

	local port="$1"

	printf '%s/%s-%s.service' \
		"${SYSTEMD_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

# ============================================================
# OBTENER INSTANCIAS HCR
# ============================================================

get_existing_hcr_units() {

	local unit=""

	systemctl list-unit-files \
		--type=service \
		--no-legend \
		--no-pager \
		2>/dev/null |
	awk '{print $1}' |
	grep -E '^hcr-server-[0-9]+\.service$' |
	while IFS= read -r unit; do

		[[ -n "${unit}" ]] || continue

		printf '%s\n' "${unit}"

	done || true
}

# ============================================================
# DETECTAR DIRECTORIO DESDE UNA UNIDAD
# ============================================================

detect_hcr_dir_from_unit() {

	local unit="$1"
	local fragment=""
	local working_directory=""
	local exec_start=""
	local candidate=""
	local binary_candidate=""

	fragment="$(
		systemctl show \
			--property=FragmentPath \
			--value \
			"${unit}" \
			2>/dev/null ||
			true
	)"

	if [[ -n "${fragment}" &&
		  -f "${fragment}" ]]; then

		candidate="$(dirname -- "${fragment}")"

		if [[ -f "${candidate}/hcr-server" ]]; then

			printf '%s\n' "${candidate}"

			return 0

		fi

	fi

	working_directory="$(
		systemctl show \
			--property=WorkingDirectory \
			--value \
			"${unit}" \
			2>/dev/null ||
			true
	)"

	if [[ -n "${working_directory}" &&
		  -f "${working_directory}/hcr-server" ]]; then

		printf '%s\n' "${working_directory}"

		return 0

	fi

	exec_start="$(
		systemctl show \
			--property=ExecStart \
			--value \
			"${unit}" \
			2>/dev/null ||
			true
	)"

	if [[ "${exec_start}" =~ (/[^[:space:]]*/hcr-server) ]]; then

		binary_candidate="${BASH_REMATCH[1]}"

		if [[ -f "${binary_candidate}" ]]; then

			candidate="$(dirname -- "${binary_candidate}")"

			if [[ -f "${candidate}/hcr-server" ]]; then

				printf '%s\n' "${candidate}"

				return 0

			fi

		fi

	fi

	return 1
}

# ============================================================
# DETECTAR INSTALACIÓN HCR
# ============================================================

detect_hcr_installation() {

	local unit=""
	local detected_dir=""
	local candidate=""

	local candidates=(
		"/root/.hcr-panel"
		"/opt/.hcr-panel"
		"/usr/local/lib/hcr-server"
		"/opt/hcr-server"
	)

	# --------------------------------------------------------
	# Primero: unidades HCR existentes.
	# --------------------------------------------------------

	while IFS= read -r unit; do

		[[ -n "${unit}" ]] || continue

		detected_dir="$(
			detect_hcr_dir_from_unit "${unit}" 2>/dev/null ||
			true
		)"

		if [[ -n "${detected_dir}" ]]; then

			HCR_DIR="${detected_dir}"

			break

		fi

	done < <(get_existing_hcr_units)

	# --------------------------------------------------------
	# Segundo: ubicaciones conocidas.
	# --------------------------------------------------------

	if [[ -z "${HCR_DIR}" ]]; then

		for candidate in "${candidates[@]}"; do

			if [[ -f "${candidate}/hcr-server" ]]; then

				HCR_DIR="${candidate}"

				break

			fi

		done

	fi

	if [[ -z "${HCR_DIR}" ]]; then

		fail \
			"No se encontró una instalación HCR Server existente.

Se buscó mediante las unidades systemd reales y en ubicaciones
de instalación conocidas.

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
		journalctl
	do

		require_command "${command_name}"

	done

	if [[ ! -d "${SYSTEMD_DIR}" ]]; then

		fail \
			"No existe el directorio de systemd: ${SYSTEMD_DIR}"

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

	if [[ ! -f "${BINARY_PATH}" ]]; then

		fail \
			"No se encontró el binario HCR Server:

${BINARY_PATH}"

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

	exec 9>"${lock_file}" ||
		fail \
			"No se pudo crear el bloqueo de HCR Server."

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
# CONFIGURAR PUERTO
# ============================================================

configure_port() {

	local input=""

	section "Selección de la instancia"

	while true; do

		printf \
			"${WHITE}Puerto HCR a eliminar${RESET} ${DIM}[ejemplo: 8880]${RESET}: "

		read -r input

		if [[ -z "${input}" ]]; then

			error_message \
				"Debes introducir un puerto."

			continue

		fi

		if ! validate_port "${input}"; then

			error_message \
				"Puerto no válido. Debe estar entre 1 y 65535."

			continue

		fi

		PORT="${input}"

		break

	done

	SERVICE_NAME_SELECTED="$(service_name_for_port "${PORT}")"
	UNIT_SOURCE="$(unit_source_path_for_port "${PORT}")"
	UNIT_LINK="$(unit_link_path_for_port "${PORT}")"

	printf '\n'

	success \
		"Puerto seleccionado: ${PORT}"

	detail \
		"Servicio: ${SERVICE_NAME_SELECTED}.service"

	detail \
		"Unidad fuente esperada: ${UNIT_SOURCE}"

	detail \
		"Ruta systemd: ${UNIT_LINK}"
}

# ============================================================
# RESOLVER UNIDAD REAL
# ============================================================

resolve_target_unit() {

	local expected_service="${SERVICE_NAME_SELECTED}.service"
	local fragment=""
	local resolved_source=""

	fragment="$(
		systemctl show \
			--property=FragmentPath \
			--value \
			"${expected_service}" \
			2>/dev/null ||
			true
	)"

	# --------------------------------------------------------
	# Si systemd conoce la unidad, utilizar su FragmentPath.
	# --------------------------------------------------------

	if [[ -n "${fragment}" ]]; then

		if [[ -f "${fragment}" ]]; then

			resolved_source="$(readlink -f -- "${fragment}" 2>/dev/null || true)"

			if [[ -n "${resolved_source}" &&
				  -f "${resolved_source}" ]]; then

				UNIT_SOURCE="${resolved_source}"

			else

				UNIT_SOURCE="${fragment}"

			fi

			return 0

		fi

	fi

	# --------------------------------------------------------
	# Si no está cargada, buscar unidad propia.
	# --------------------------------------------------------

	if [[ -f "${UNIT_SOURCE}" &&
		  ! -L "${UNIT_SOURCE}" ]]; then

		return 0

	fi

	# --------------------------------------------------------
	# Si existe directamente en systemd.
	# --------------------------------------------------------

	if [[ -f "${UNIT_LINK}" &&
		  ! -L "${UNIT_LINK}" ]]; then

		UNIT_SOURCE="${UNIT_LINK}"

		return 0

	fi

	# --------------------------------------------------------
	# Si es un enlace, resolverlo.
	# --------------------------------------------------------

	if [[ -L "${UNIT_LINK}" ]]; then

		resolved_source="$(readlink -f -- "${UNIT_LINK}" 2>/dev/null || true)"

		if [[ -n "${resolved_source}" &&
			  -f "${resolved_source}" ]]; then

			UNIT_SOURCE="${resolved_source}"

			return 0

		fi

	fi

	return 1
}

# ============================================================
# VALIDAR UNIDAD OBJETIVO
# ============================================================

validate_target_unit() {

	local fragment=""
	local exec_start=""
	local expected_listen=""
	local expected_service=""

	section "Comprobando instancia seleccionada"

	expected_service="${SERVICE_NAME_SELECTED}.service"
	expected_listen="--listen :${PORT}"

	if ! resolve_target_unit; then

		fail \
			"No existe una unidad válida para el puerto ${PORT}.

Servicio:
${expected_service}

Unidad esperada:
${UNIT_SOURCE}

Ruta systemd:
${UNIT_LINK}"

	fi

	success \
		"Unidad HCR encontrada."

	detail \
		"Unidad real: ${UNIT_SOURCE}"

	# --------------------------------------------------------
	# Seguridad: solamente rutas absolutas.
	# --------------------------------------------------------

	if [[ "${UNIT_SOURCE}" != /* ]]; then

		fail \
			"La unidad detectada no utiliza una ruta absoluta."

	fi

	# --------------------------------------------------------
	# Comprobar propietario.
	# --------------------------------------------------------

	if [[ "$(stat -c '%u' -- "${UNIT_SOURCE}")" != "0" ]]; then

		fail \
			"La unidad seleccionada no pertenece a root:

${UNIT_SOURCE}"

	fi

	success \
		"La unidad pertenece a root."

	# --------------------------------------------------------
	# Comprobar FragmentPath.
	# --------------------------------------------------------

	fragment="$(
		systemctl show \
			--property=FragmentPath \
			--value \
			"${expected_service}" \
			2>/dev/null ||
			true
	)"

	if [[ -n "${fragment}" ]]; then

		local fragment_real=""
		local source_real=""

		fragment_real="$(readlink -f -- "${fragment}" 2>/dev/null || true)"
		source_real="$(readlink -f -- "${UNIT_SOURCE}" 2>/dev/null || true)"

		if [[ -n "${fragment_real}" &&
			  -n "${source_real}" &&
			  "${fragment_real}" != "${source_real}" ]]; then

			fail \
				"systemd tiene una unidad ${expected_service}, pero
su FragmentPath no coincide con la unidad objetivo.

FragmentPath:
${fragment}

Unidad objetivo:
${UNIT_SOURCE}"

		fi

	fi

	# --------------------------------------------------------
	# Comprobar ExecStart.
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

		if [[ "${exec_start}" != *"${expected_listen}"* ]]; then

			fail \
				"La instancia ${expected_service} no parece corresponder
al puerto ${PORT}.

ExecStart detectado:

${exec_start}"

		fi

		success \
			"ExecStart corresponde al puerto ${PORT}."

	else

		info \
			"systemd no tiene ExecStart cargado actualmente."

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
			"${SERVICE_NAME_SELECTED}.service" \
			2>/dev/null ||
			true
	)"

	enabled_state="$(
		systemctl is-enabled \
			"${SERVICE_NAME_SELECTED}.service" \
			2>/dev/null ||
			true
	)"

	fragment="$(
		systemctl show \
			--property=FragmentPath \
			--value \
			"${SERVICE_NAME_SELECTED}.service" \
			2>/dev/null ||
			true
	)"

	detail \
		"Servicio: ${SERVICE_NAME_SELECTED}.service"

	detail \
		"Estado: ${active_state:-no-activo}"

	detail \
		"Inicio automático: ${enabled_state:-no-habilitado}"

	if [[ -n "${fragment}" ]]; then

		detail \
			"FragmentPath: ${fragment}"

	fi

	if [[ "${active_state}" == "active" ]]; then

		success \
			"La instancia está actualmente activa."

	else

		info \
			"La instancia no está activa."

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
			"${SERVICE_NAME_SELECTED}.service" \
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
		"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1; then

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
			"${SERVICE_NAME_SELECTED}.service" ||
			true

		fail \
			"La instancia no pudo detenerse."

	fi

	# --------------------------------------------------------
	# Confirmar que realmente dejó de estar activa.
	# --------------------------------------------------------

	active_state="$(
		systemctl is-active \
			"${SERVICE_NAME_SELECTED}.service" \
			2>/dev/null ||
			true
	)"

	if [[ "${active_state}" == "active" ]]; then

		fail \
			"La instancia sigue activa después de ejecutar stop."

	fi
}

# ============================================================
# DESHABILITAR SERVICIO
# ============================================================

disable_service() {

	section "Deshabilitando inicio automático"

	if systemctl is-enabled --quiet \
		"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1; then

		spinner_start \
			"Deshabilitando inicio automático..."

		if systemctl disable \
			"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1; then

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
	# Primero eliminar el enlace systemd si existe.
	# --------------------------------------------------------

	if [[ -L "${UNIT_LINK}" ]]; then

		local link_real=""
		local source_real=""

		link_real="$(readlink -f -- "${UNIT_LINK}" 2>/dev/null || true)"
		source_real="$(readlink -f -- "${UNIT_SOURCE}" 2>/dev/null || true)"

		if [[ -n "${link_real}" &&
			  -n "${source_real}" &&
			  "${link_real}" != "${source_real}" ]]; then

			fail \
				"El enlace systemd no apunta a la unidad seleccionada:

Enlace:
${UNIT_LINK}

Destino:
${link_real}

Esperado:
${source_real}"

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

	elif [[ -e "${UNIT_LINK}" ]]; then

		# ----------------------------------------------------
		# Si UNIT_LINK es la propia unidad fuente, no borrarla
		# aquí. Se procesará abajo como UNIT_SOURCE.
		# ----------------------------------------------------

		if [[ "${UNIT_SOURCE}" == "${UNIT_LINK}" ]]; then

			info \
				"La unidad está instalada directamente en systemd."

		else

			fail \
				"Existe un archivo en la ruta systemd, pero no es
un enlace simbólico:

${UNIT_LINK}"

		fi

	else

		info \
			"No existe un enlace systemd que eliminar."

	fi

	# --------------------------------------------------------
	# Eliminar unidad fuente.
	# --------------------------------------------------------

	if [[ -f "${UNIT_SOURCE}" &&
		  ! -L "${UNIT_SOURCE}" ]]; then

		# ----------------------------------------------------
		# Nunca eliminar el binario HCR.
		# ----------------------------------------------------

		if [[ "$(readlink -f -- "${UNIT_SOURCE}")" ==
			  "$(readlink -f -- "${BINARY_PATH}")" ]]; then

			fail \
				"La ruta de la unidad coincide con el binario HCR.
Operación abortada por seguridad."

		fi

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
			"La unidad fuente ya no existe."

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
		"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1 ||
		true
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_removal() {

	local fragment=""
	local active_state=""
	local enabled_state=""
	local unit_exists=""

	section "Verificación final"

	# --------------------------------------------------------
	# Unidad fuente
	# --------------------------------------------------------

	if [[ ! -e "${UNIT_SOURCE}" ]]; then

		success \
			"Unidad fuente eliminada."

	else

		error_message \
			"La unidad fuente todavía existe:

${UNIT_SOURCE}"

		return 1

	fi

	# --------------------------------------------------------
	# Enlace systemd
	# --------------------------------------------------------

	if [[ ! -e "${UNIT_LINK}" &&
		  ! -L "${UNIT_LINK}" ]]; then

		success \
			"Ruta systemd eliminada."

	else

		error_message \
			"La ruta systemd todavía existe:

${UNIT_LINK}"

		return 1

	fi

	# --------------------------------------------------------
	# Recargar una comprobación directa de la unidad.
	# --------------------------------------------------------

	unit_exists="$(
		systemctl list-unit-files \
			"${SERVICE_NAME_SELECTED}.service" \
			--no-legend \
			--no-pager \
			2>/dev/null |
		awk '{print $1}' ||
		true
	)"

	if [[ -n "${unit_exists}" ]]; then

		error_message \
			"systemd todavía tiene registrada la unidad:

${SERVICE_NAME_SELECTED}.service"

		return 1

	fi

	success \
		"systemd ya no registra la unidad."

	# --------------------------------------------------------
	# FragmentPath
	# --------------------------------------------------------

	fragment="$(
		systemctl show \
			--property=FragmentPath \
			--value \
			"${SERVICE_NAME_SELECTED}.service" \
			2>/dev/null ||
			true
	)"

	if [[ -z "${fragment}" ]]; then

		success \
			"FragmentPath eliminado."

	else

		error_message \
			"systemd todavía detecta FragmentPath:

${fragment}"

		return 1

	fi

	# --------------------------------------------------------
	# Estado activo
	# --------------------------------------------------------

	active_state="$(
		systemctl is-active \
			"${SERVICE_NAME_SELECTED}.service" \
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
	# Estado enabled
	# --------------------------------------------------------

	enabled_state="$(
		systemctl is-enabled \
			"${SERVICE_NAME_SELECTED}.service" \
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
	# Listener
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
		-u "${SERVICE_NAME_SELECTED}.service" \
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
		"  ${CYAN}${ICON_ARROW}${RESET} Servicio          : ${BRIGHT_WHITE}${SERVICE_NAME_SELECTED}.service${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Estado            : ${BRIGHT_GREEN}Eliminado${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Inicio automático : ${BRIGHT_GREEN}Eliminado${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Archivos eliminados:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CY
