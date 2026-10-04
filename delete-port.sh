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

			printf '\r%b' \
				"${BRIGHT_CYAN}${frames[$i]}${RESET} ${WHITE}${message}${RESET}"

			i=$(( (i + 1) % ${#frames[@]} ))

			sleep 0.08

		done

	) &

	SPINNER_PID=$!
}

spinner_stop() {

	if [[ -n "${SPINNER_PID}" ]]; then

		kill "${SPINNER_PID}" >/dev/null 2>&1 || true

		wait "${SPINNER_PID}" 2>/dev/null || true

		SPINNER_PID=""

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

	command -v "${command_name}" >/dev/null 2>&1 ||
		fail \
			"No se encontró el comando requerido: ${command_name}"
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
# RUTA UNIDAD FUENTE
# ============================================================

unit_source_path_for_port() {

	local port="$1"

	printf '%s/%s-%s.service' \
		"${HCR_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

# ============================================================
# RUTA ENLACE SYSTEMD
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
	local units=""

	units="$(
		systemctl list-unit-files \
			--type=service \
			--no-legend \
			--no-pager \
			2>/dev/null |
		awk '{print $1}' |
		grep -E '^hcr-server-[0-9]+\.service$' ||
		true
	)"

	while IFS= read -r unit; do

		[[ -n "${unit}" ]] || continue

		printf '%s\n' "${unit}"

	done <<< "${units}"
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
	local candidates=()

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

			info \
				"Instalación detectada mediante: ${unit}"

			break

		fi

	done < <(get_existing_hcr_units)

	# --------------------------------------------------------
	# Segundo: ubicaciones conocidas.
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
		systemd-analyze \
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

	systemctl show \
		--property=Version \
		--value >/dev/null 2>&1 ||
		fail \
			"El administrador systemd no está disponible."

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
		"Unidad fuente: ${UNIT_SOURCE}"

	detail \
		"Enlace systemd: ${UNIT_LINK}"
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

	# --------------------------------------------------------
	# Comprobar unidad fuente.
	# --------------------------------------------------------

	if [[ ! -f "${UNIT_SOURCE}" ||
		  -L "${UNIT_SOURCE}" ]]; then

		fail \
			"No existe una unidad fuente válida para el puerto ${PORT}:

${UNIT_SOURCE}"

	fi

	success \
		"Unidad fuente encontrada."

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

	if [[ -n "${fragment}" &&
		  "${fragment}" != "${UNIT_SOURCE}" ]]; then

		fail \
			"systemd tiene una unidad ${expected_service}, pero su
FragmentPath no coincide con la unidad esperada:

Esperado:
${UNIT_SOURCE}

Detectado:
${fragment}"

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
				if ($4 ~ (":" port "$")) {
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
	# Eliminar enlace systemd.
	# --------------------------------------------------------

	if [[ -L "${UNIT_LINK}" ]]; then

		if [[ "$(readlink -- "${UNIT_LINK}")" != "${UNIT_SOURCE}" ]]; then

			fail \
				"El enlace systemd no apunta a la unidad esperada:

${UNIT_LINK}"

		fi

		spinner_start \
			"Eliminando enlace systemd..."

		if rm -f -- "${UNIT_LINK}"; then

			spinner_stop

			success \
				"Enlace eliminado."

		else

			spinner_stop

			fail \
				"No se pudo eliminar el enlace systemd."

		fi

	elif [[ -e "${UNIT_LINK}" ]]; then

		fail \
			"Existe un archivo en la ruta del enlace systemd, pero no es
un enlace simbólico:

${UNIT_LINK}"

	else

		info \
			"No existe un enlace systemd que eliminar."

	fi

	# --------------------------------------------------------
	# Eliminar unidad fuente.
	# --------------------------------------------------------

	if [[ -f "${UNIT_SOURCE}" &&
		  ! -L "${UNIT_SOURCE}" ]]; then

		spinner_start \
			"Eliminando unidad HCR Server..."

		if rm -f -- "${UNIT_SOURCE}"; then

			spinner_stop

			success \
				"Unidad fuente eliminada."

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
	# Enlace
	# --------------------------------------------------------

	if [[ ! -e "${UNIT_LINK}" &&
		  ! -L "${UNIT_LINK}" ]]; then

		success \
			"Enlace systemd eliminado."

	else

		error_message \
			"El enlace systemd todavía existe:

${UNIT_LINK}"

		return 1

	fi

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
			"systemd ya no tiene registrada la unidad."

	else

		error_message \
			"systemd todavía detecta la unidad:

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
		"  ${CYAN}${ICON_ARROW}${RESET} Unidad : ${BRIGHT_WHITE}${UNIT_SOURCE}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Enlace : ${BRIGHT_WHITE}${UNIT_LINK}${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Archivos conservados:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Binario     : ${BRIGHT_GREEN}Conservado${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Certificados: ${BRIGHT_GREEN}Conservados${RESET}"

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

	if [[ -n "${TEMP_UNIT}" ]]; then

		rm -f \
			-- "${TEMP_UNIT}" >/dev/null 2>&1 ||
			true

	fi

	if [[ "${LOCK_FD_OPEN}" == "true" ]]; then

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
	# PUERTO
	# --------------------------------------------------------

	configure_port

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
		"Instancia: ${SERVICE_NAME_SELECTED}.service"

	detail \
		"Puerto HCR: ${PORT}"

	detail \
		"Unidad fuente: ${UNIT_SOURCE}"

	detail \
		"Enlace systemd: ${UNIT_LINK}"

	detail \
		"Binario HCR: ${BINARY_PATH}"

	detail \
		"Frame de descarga original: ${MAX_DOWNLOAD_FRAME}"

	detail \
		"Poll timeout original: ${DOWNLOAD_POLL_TIMEOUT}"

	printf '\n'

	warning \
		"Se eliminará únicamente la instancia ${SERVICE_NAME_SELECTED}.service."

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
