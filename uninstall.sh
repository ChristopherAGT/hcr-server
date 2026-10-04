#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — DESINSTALADOR
# Compatible con el instalador HCR Server actual
#
# Elimina:
#   - Todas las instancias hcr-server-<puerto>.service
#   - Enlaces de systemd correspondientes
#   - Unidades systemd instaladas
#   - Drop-ins relacionados
#   - Binario hcr-server
#   - fullchain.pem
#   - privkey.pem
#   - Archivos temporales del instalador
#   - El propio desinstalador
#
# NO elimina el directorio del panel.
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

SERVICE_PREFIX="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"

# ============================================================
# RUTAS DEL DESINSTALADOR
# ============================================================

command -v readlink >/dev/null 2>&1 || {
	echo "Error: readlink no está instalado." >&2
	exit 1
}

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "${SCRIPT_PATH}")"

# ============================================================
# VARIABLES DE INSTALACIÓN
# ============================================================

INSTALL_DIR=""
BINARY_PATH=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""

# ============================================================
# ARRAYS DE INSTANCIAS
# ============================================================

SERVICE_NAMES=()
UNIT_SOURCE_PATHS=()
UNIT_LINK_PATHS=()
INSTALL_DIRS=()

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
		"${BRIGHT_CYAN}${BOLD}║              HCR SERVER — DESINSTALADOR                  ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                  DESINSTALACIÓN COMPLETA                 ║${RESET}"

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
# COMANDOS REQUERIDOS
# ============================================================

require_command() {

	command -v "$1" >/dev/null 2>&1 ||
		fail "No se encontró el comando requerido: $1"
}

require_environment() {

	[[ "${EUID}" -eq 0 ]] ||
		fail "Este desinstalador debe ejecutarse como root."

	[[ "$(uname -s)" == "Linux" ]] ||
		fail "Este desinstalador solo funciona en Linux."

	require_command systemctl
	require_command systemd-analyze
	require_command flock
	require_command readlink
	require_command stat
	require_command rm
	require_command sleep
	require_command grep
	require_command sed
	require_command tail
	require_command dirname
	require_command basename
	require_command find
	require_command ps
}

# ============================================================
# BLOQUEO
#
# El instalador utiliza /etc/systemd/system como objeto
# bloqueado mediante flock. Usamos el mismo mecanismo.
# ============================================================

acquire_uninstall_lock() {

	exec 9<"${SYSTEMD_DIR}" ||
		fail \
			"No se pudo abrir ${SYSTEMD_DIR} para bloqueo."

	flock -n 9 ||
		fail \
			"Ya existe otra operación de instalación/desinstalación en curso."
}

# ============================================================
# NORMALIZAR RUTA
# ============================================================

normalize_path() {

	local path="$1"

	if [[ -e "${path}" || -L "${path}" ]]; then

		readlink -f -- "${path}"

	else

		printf '%s' "${path}"

	fi
}

# ============================================================
# OBTENER FRAGMENT PATH DE SYSTEMD
# ============================================================

loaded_fragment_path() {

	local service_name="$1"

	systemctl show \
		--property=FragmentPath \
		--value \
		"${service_name}.service" \
		2>/dev/null || true
}

# ============================================================
# DETECTAR SI UNA UNIDAD ES REALMENTE DE HCR
# ============================================================

is_hcr_unit() {

	local unit_file="$1"

	[[ -f "${unit_file}" ]] || return 1

	# Debe contener el patrón de descripción creado
	# por el instalador actual.
	grep -qE '^Description=HCR relay on port [0-9]+$' \
		"${unit_file}" ||
		return 1

	# Debe ejecutar nuestro binario hcr-server.
	grep -qE '^ExecStart=.*\/hcr-server([[:space:]]|$)' \
		"${unit_file}" ||
		return 1

	return 0
}

# ============================================================
# DETECTAR DIRECTORIO DE INSTALACIÓN DESDE UNIDAD
# ============================================================

get_unit_working_directory() {

	local unit_file="$1"

	grep -E '^WorkingDirectory=' \
		"${unit_file}" \
		2>/dev/null |
		tail -n1 |
		sed 's/^WorkingDirectory=//' ||
		true
}

# ============================================================
# REGISTRAR INSTANCIA
# ============================================================

register_instance() {

	local service_name="$1"
	local unit_source="$2"
	local unit_link="$3"

	local existing

	for existing in "${SERVICE_NAMES[@]}"; do

		if [[ "${existing}" == "${service_name}" ]]; then
			return 0
		fi

	done

	SERVICE_NAMES+=("${service_name}")
	UNIT_SOURCE_PATHS+=("${unit_source}")
	UNIT_LINK_PATHS+=("${unit_link}")

	detail \
		"Instancia detectada: ${service_name}.service"

	detail \
		"Unidad: ${unit_source}"
}

# ============================================================
# DESCUBRIR TODAS LAS INSTANCIAS
# ============================================================

discover_instances() {

	section "BUSCANDO INSTALACIÓN DE HCR SERVER"

	local file
	local service_name
	local port
	local source
	local link
	local working_directory

	# --------------------------------------------------------
	# 1. Buscar unidades hcr-server-*.service dentro de
	#    /etc/systemd/system
	# --------------------------------------------------------

	shopt -s nullglob

	for file in \
		"${SYSTEMD_DIR}/${SERVICE_PREFIX}-"*.service
	do

		[[ -f "${file}" || -L "${file}" ]] || continue

		source="$(normalize_path "${file}")"

		[[ -f "${source}" ]] || continue

		is_hcr_unit "${source}" || continue

		service_name="$(basename -- "${file}" .service)"

		# Debe seguir el formato hcr-server-PORT.
		if [[ "${service_name}" =~ ^${SERVICE_PREFIX}-([0-9]+)$ ]]; then

			port="${BASH_REMATCH[1]}"

			link="${file}"

			register_instance \
				"${service_name}" \
				"${source}" \
				"${link}"

		fi

	done

	# --------------------------------------------------------
	# 2. Buscar unidades que systemd tenga cargadas.
	# --------------------------------------------------------

	while IFS= read -r service_name; do

		[[ -n "${service_name}" ]] || continue

		if [[ "${service_name}" =~ ^${SERVICE_PREFIX}-([0-9]+)$ ]]; then

			source="$(loaded_fragment_path "${service_name}")"

			[[ -n "${source}" ]] || continue
			[[ -f "${source}" ]] || continue

			is_hcr_unit "${source}" || continue

			link="${SYSTEMD_DIR}/${service_name}.service"

			register_instance \
				"${service_name}" \
				"$(normalize_path "${source}")" \
				"${link}"

		fi

	done < <(
		systemctl list-unit-files \
			--no-legend \
			--no-pager \
			"${SERVICE_PREFIX}-*.service" \
			2>/dev/null |
			awk '{print $1}' |
			sed 's/\.service$//' |
			grep -E "^${SERVICE_PREFIX}-[0-9]+$" ||
			true
	)

	# --------------------------------------------------------
	# 3. También comprobar una posible unidad legacy:
	#
	#    hcr-server.service
	#
	# Esto permite limpiar instalaciones antiguas.
	# --------------------------------------------------------

	source="${SYSTEMD_DIR}/${SERVICE_PREFIX}.service"

	if [[ -f "${source}" ]] &&
		is_hcr_unit "${source}"; then

		link="${source}"

		register_instance \
			"${SERVICE_PREFIX}" \
			"$(normalize_path "${source}")" \
			"${link}"

	fi

	# --------------------------------------------------------
	# 4. Determinar directorio de instalación.
	# --------------------------------------------------------

	for source in "${UNIT_SOURCE_PATHS[@]}"; do

		working_directory="$(get_unit_working_directory "${source}")"

		if [[ -n "${working_directory}" &&
			  -d "${working_directory}" ]]; then

			working_directory="$(normalize_path "${working_directory}")"

			INSTALL_DIRS+=("${working_directory}")

		else

			INSTALL_DIRS+=(
				"$(dirname -- "${source}")"
			)

		fi

	done

	# --------------------------------------------------------
	# 5. Si no se encontró ninguna unidad, comprobar el
	#    directorio desde el que se ejecuta el desinstalador.
	# --------------------------------------------------------

	if [[ "${#SERVICE_NAMES[@]}" -eq 0 ]]; then

		if [[ -f "${SCRIPT_DIR}/hcr-server" ]]; then

			INSTALL_DIR="${SCRIPT_DIR}"

			info \
				"No se encontraron unidades activas, pero se detectó el binario HCR en el directorio actual."

		else

			fail \
				"No se encontró ninguna unidad HCR Server instalada ni un binario hcr-server en el directorio del desinstalador."

		fi

	else

		INSTALL_DIR="${INSTALL_DIRS[0]}"
	fi

	# --------------------------------------------------------
	# 6. Normalizar instalación.
	# --------------------------------------------------------

	INSTALL_DIR="$(normalize_path "${INSTALL_DIR}")"

	BINARY_PATH="${INSTALL_DIR}/hcr-server"
	TLS_CERT_PATH="${INSTALL_DIR}/fullchain.pem"
	TLS_KEY_PATH="${INSTALL_DIR}/privkey.pem"

	printf '\n'

	if [[ "${#SERVICE_NAMES[@]}" -gt 0 ]]; then

		success \
			"Se detectaron ${#SERVICE_NAMES[@]} instancia(s) de HCR Server."

		printf '\n'

		for service_name in "${SERVICE_NAMES[@]}"; do

			detail \
				"${service_name}.service"

		done

	else

		info "No hay unidades systemd activas para eliminar."
	fi

	printf '\n'

	detail "Directorio de instalación: ${INSTALL_DIR}"
	detail "Binario: ${BINARY_PATH}"
	detail "Certificado: ${TLS_CERT_PATH}"
	detail "Clave privada: ${TLS_KEY_PATH}"
}

# ============================================================
# VALIDAR DIRECTORIO DE INSTALACIÓN
# ============================================================

validate_install_directory() {

	[[ -d "${INSTALL_DIR}" ]] ||
		fail \
			"El directorio de instalación no existe: ${INSTALL_DIR}"

	[[ "$(stat -c '%u' -- "${INSTALL_DIR}")" == "0" ]] ||
		fail \
			"El directorio de instalación no pertenece a root: ${INSTALL_DIR}"

	# No permitimos eliminar accidentalmente directorios críticos.
	case "${INSTALL_DIR}" in

		"/" |
		"/etc" |
		"/usr" |
		"/usr/bin" |
		"/usr/sbin" |
		"/bin" |
		"/sbin" |
		"/lib" |
		"/lib64" |
		"/var" |
		"/home" |
		"/root")
			fail \
				"Ruta de instalación insegura. Se rechazará la desinstalación: ${INSTALL_DIR}"
			;;

	esac
}

# ============================================================
# VALIDAR ARCHIVO PROPIO
# ============================================================

validate_file_if_exists() {

	local description="$1"
	local file="$2"

	[[ -e "${file}" || -L "${file}" ]] || return 0

	[[ -f "${file}" && ! -L "${file}" ]] ||
		fail \
			"${description} no es un archivo regular: ${file}"

	[[ "$(stat -c '%u' -- "${file}")" == "0" ]] ||
		fail \
			"${description} no pertenece a root: ${file}"
}

# ============================================================
# VALIDAR INSTALACIÓN
# ============================================================

validate_installation() {

	section "VALIDANDO INSTALACIÓN"

	validate_install_directory

	validate_file_if_exists \
		"Binario HCR" \
		"${BINARY_PATH}"

	validate_file_if_exists \
		"Certificado TLS" \
		"${TLS_CERT_PATH}"

	validate_file_if_exists \
		"Clave privada TLS" \
		"${TLS_KEY_PATH}"

	validate_file_if_exists \
		"Desinstalador" \
		"${SCRIPT_PATH}"

	local source

	for source in "${UNIT_SOURCE_PATHS[@]}"; do

		[[ -f "${source}" ]] ||
			fail \
				"La unidad HCR no existe: ${source}"

		is_hcr_unit "${source}" ||
			fail \
				"La unidad no coincide con el formato esperado de HCR Server: ${source}"

	done

	success "La instalación corresponde al formato del instalador HCR Server actual."
}

# ============================================================
# CONFIRMACIÓN
# ============================================================

confirm_uninstall() {

	printf '\n'

	warning \
		"Esta operación eliminará completamente HCR Server."

	printf '\n'

	detail \
		"Instancias systemd: ${#SERVICE_NAMES[@]}"

	local service_name

	for service_name in "${SERVICE_NAMES[@]}"; do

		detail \
			"Servicio: ${service_name}.service"

	done

	printf '\n'

	detail "Directorio de instalación: ${INSTALL_DIR}"
	detail "Binario: ${BINARY_PATH}"
	detail "Certificado: ${TLS_CERT_PATH}"
	detail "Clave privada: ${TLS_KEY_PATH}"
	detail "Desinstalador: ${SCRIPT_PATH}"

	printf '\n'

	warning \
		"El directorio del panel NO será eliminado."

	warning \
		"Solo se eliminarán archivos y unidades pertenecientes a HCR Server."

	printf '\n'

	read -r -p \
		"¿Deseas continuar? [s/N]: " \
		answer

	case "${answer,,}" in

		s|si|sí|y|yes)
			;;

		*)
			printf '\n'

			info "Desinstalación cancelada."

			exit 0
			;;

	esac
}

# ============================================================
# DETENER TODAS LAS INSTANCIAS
# ============================================================

stop_services() {

	section "DETENIENDO SERVICIOS"

	local service_name

	if [[ "${#SERVICE_NAMES[@]}" -eq 0 ]]; then

		info "No existen instancias systemd que detener."

		return 0
	fi

	for service_name in "${SERVICE_NAMES[@]}"; do

		if systemctl is-active --quiet \
			"${service_name}.service" \
			2>/dev/null; then

			spinner_start \
				"Deteniendo ${service_name}.service..."

			if systemctl stop \
				"${service_name}.service"; then

				spinner_stop

				success \
					"${service_name}.service detenido."

			else

				spinner_stop

				fail \
					"No se pudo detener ${service_name}.service."

			fi

		else

			info \
				"${service_name}.service ya estaba detenido."

		fi

	done
}

# ============================================================
# DESHABILITAR TODAS LAS INSTANCIAS
# ============================================================

disable_services() {

	section "DESHABILITANDO SERVICIOS"

	local service_name

	for service_name in "${SERVICE_NAMES[@]}"; do

		if systemctl is-enabled --quiet \
			"${service_name}.service" \
			2>/dev/null; then

			spinner_start \
				"Deshabilitando ${service_name}.service..."

			if systemctl disable \
				"${service_name}.service" \
				>/dev/null 2>&1; then

				spinner_stop

				success \
					"${service_name}.service deshabilitado."

			else

				spinner_stop

				fail \
					"No se pudo deshabilitar ${service_name}.service."

			fi

		else

			info \
				"${service_name}.service ya estaba deshabilitado."

		fi

	done
}

# ============================================================
# ELIMINAR DROP-INS
# ============================================================

remove_dropins() {

	section "ELIMINANDO DROP-INS"

	local directory
	local found=0

	shopt -s nullglob

	for directory in \
		"${SYSTEMD_DIR}/${SERVICE_PREFIX}.service.d" \
		"${SYSTEMD_DIR}/${SERVICE_PREFIX}-"*.service.d
	do

		[[ -d "${directory}" ]] || continue

		found=1

		spinner_start \
			"Eliminando $(basename -- "${directory}")..."

		rm -rf -- "${directory}"

		spinner_stop

		success \
			"Drop-in eliminado: $(basename -- "${directory}")"

	done

	if [[ "${found}" -eq 0 ]]; then

		info "No existen drop-ins de HCR Server."

	fi
}

# ============================================================
# ELIMINAR UNIDADES SYSTEMD
# ============================================================

remove_systemd_units() {

	section "ELIMINANDO UNIDADES SYSTEMD"

	local service_name
	local source
	local link

	for service_name in "${SERVICE_NAMES[@]}"; do

		source=""
		link="${SYSTEMD_DIR}/${service_name}.service"

		for source_candidate in "${UNIT_SOURCE_PATHS[@]}"; do

			if [[ "$(basename -- "${source_candidate}" .service)" == "${service_name}" ]]; then

				source="${source_candidate}"
				break

			fi

		done

		# ----------------------------------------------------
		# Eliminar enlace en /etc/systemd/system
		# ----------------------------------------------------

		if [[ -L "${link}" || -f "${link}" ]]; then

			spinner_start \
				"Eliminando ${service_name}.service de systemd..."

			rm -f -- "${link}"

			spinner_stop

			success \
				"${service_name}.service eliminado de systemd."

		else

			info \
				"${service_name}.service no existe en ${SYSTEMD_DIR}."

		fi

		# ----------------------------------------------------
		# Eliminar unidad fuente.
		# ----------------------------------------------------

		if [[ -n "${source}" &&
			  -f "${source}" ]]; then

			# Si la unidad está fuera del directorio de
			# instalación esperado, no se elimina.
			case "${source}" in

				"${INSTALL_DIR}/"*)
					;;

				*)
					fail \
						"La unidad ${source} está fuera del directorio de instalación esperado."
					;;

			esac

			spinner_start \
				"Eliminando archivo de unidad ${service_name}..."

			rm -f -- "${source}"

			spinner_stop

			success \
				"Archivo de unidad eliminado."

		fi

	done

	# --------------------------------------------------------
	# Eliminar cualquier unidad HCR que haya quedado dentro
	# de /etc/systemd/system y coincida exactamente con el
	# formato del instalador.
	# --------------------------------------------------------

	local file

	shopt -s nullglob

	for file in \
		"${SYSTEMD_DIR}/${SERVICE_PREFIX}-"*.service
	do

		[[ -f "${file}" || -L "${file}" ]] || continue

		local normalized

		normalized="$(normalize_path "${file}")"

		if [[ -f "${normalized}" ]] &&
			is_hcr_unit "${normalized}"; then

			spinner_start \
				"Eliminando unidad HCR restante..."

			rm -f -- "${file}"

			spinner_stop

			success \
				"Unidad restante eliminada: $(basename -- "${file}")"

		fi

	done

	# --------------------------------------------------------
	# Recargar systemd.
	# --------------------------------------------------------

	spinner_start \
		"Recargando configuración de systemd..."

	if systemctl daemon-reload; then

		spinner_stop

		success "systemd recargado."

	else

		spinner_stop

		fail \
			"No se pudo recargar systemd."

	fi

	# --------------------------------------------------------
	# Limpiar estados failed.
	# --------------------------------------------------------

	systemctl reset-failed \
		2>/dev/null ||
		true
}

# ============================================================
# ELIMINAR ARCHIVOS TEMPORALES
# ============================================================

remove_temp_units() {

	section "ELIMINANDO ARCHIVOS TEMPORALES"

	local file
	local found=0

	while IFS= read -r -d '' file; do

		found=1

		spinner_start \
			"Eliminando temporal $(basename -- "${file}")..."

		rm -f -- "${file}"

		spinner_stop

		success \
			"Temporal eliminado."

	done < <(
		find "${INSTALL_DIR}" \
			-maxdepth 1 \
			-type f \
			-name ".${SERVICE_PREFIX}-*.service" \
			-print0 \
			2>/dev/null ||
			true
	)

	if [[ "${found}" -eq 0 ]]; then

		info "No se encontraron archivos temporales."

	fi
}

# ============================================================
# ELIMINAR ARCHIVOS DEL SERVICIO
# ============================================================

remove_installation_files() {

	section "ELIMINANDO ARCHIVOS DE HCR SERVER"

	local file
	local files=(
		"${BINARY_PATH}"
		"${TLS_CERT_PATH}"
		"${TLS_KEY_PATH}"
	)

	for file in "${files[@]}"; do

		if [[ -e "${file}" || -L "${file}" ]]; then

			spinner_start \
				"Eliminando $(basename -- "${file}")..."

			rm -f -- "${file}"

			spinner_stop

			success \
				"Eliminado: $(basename -- "${file}")"

		else

			detail \
				"No existe: $(basename -- "${file}")"

		fi

	done
}

# ============================================================
# ELIMINAR DESINSTALADOR
# ============================================================

remove_uninstaller() {

	section "ELIMINANDO DESINSTALADOR"

	if [[ -f "${SCRIPT_PATH}" ]]; then

		spinner_start \
			"Eliminando desinstalador..."

		rm -f -- "${SCRIPT_PATH}"

		spinner_stop

		success "Desinstalador eliminado."

	else

		info "El desinstalador ya no existe."

	fi
}

# ============================================================
# VERIFICAR PROCESOS HCR
# ============================================================

verify_processes() {

	section "VERIFICANDO PROCESOS"

	local pid
	local exe
	local found=0

	for pid in /proc/[0-9]*; do

		[[ -d "${pid}" ]] || continue

		exe="${pid}/exe"

		[[ -e "${exe}" ]] || continue

		local resolved

		resolved="$(readlink -f -- "${exe}" 2>/dev/null || true)"

		[[ -n "${resolved}" ]] || continue

		if [[ "${resolved}" == "${BINARY_PATH}" ||
			  "${resolved}" == "${BINARY_PATH} (deleted)" ]]; then

			found=1

			error_message \
				"El proceso HCR todavía está ejecutándose: PID $(basename -- "${pid}")"

		fi

	done

	if [[ "${found}" -eq 0 ]]; then

		success \
			"No quedan procesos HCR Server ejecutándose."

		return 0
	fi

	return 1
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_uninstall() {

	section "VERIFICACIÓN FINAL"

	local failed=0
	local service_name
	local source
	local link

	# --------------------------------------------------------
	# Servicios
	# --------------------------------------------------------

	for service_name in "${SERVICE_NAMES[@]}"; do

		if systemctl is-active --quiet \
			"${service_name}.service" \
			2>/dev/null; then

			error_message \
				"${service_name}.service todavía está activo."

			failed=1

		else

			success \
				"${service_name}.service detenido."

		fi

		if systemctl is-enabled --quiet \
			"${service_name}.service" \
			2>/dev/null; then

			error_message \
				"${service_name}.service todavía está habilitado."

			failed=1

		else

			success \
				"${service_name}.service deshabilitado."

		fi

	done

	# --------------------------------------------------------
	# Enlaces / unidades.
	# --------------------------------------------------------

	for link in "${UNIT_LINK_PATHS[@]}"; do

		if [[ -e "${link}" || -L "${link}" ]]; then

			error_message \
				"La unidad systemd todavía existe: ${link}"

			failed=1

		else

			success \
				"Unidad systemd eliminada: $(basename -- "${link}")"

		fi

	done

	# --------------------------------------------------------
	# Archivos fuente.
	# --------------------------------------------------------

	for source in "${UNIT_SOURCE_PATHS[@]}"; do

		if [[ -e "${source}" || -L "${source}" ]]; then

			error_message \
				"La unidad fuente todavía existe: ${source}"

			failed=1

		else

			success \
				"Unidad fuente eliminada."

		fi

	done

	# --------------------------------------------------------
	# Drop-ins.
	# --------------------------------------------------------

	local dropin

	for dropin in \
		"${SYSTEMD_DIR}/${SERVICE_PREFIX}.service.d" \
		"${SYSTEMD_DIR}/${SERVICE_PREFIX}-"*.service.d
	do

		if [[ -e "${dropin}" ]]; then

			error_message \
				"Drop-in restante: ${dropin}"

			failed=1

		fi

	done

	# --------------------------------------------------------
	# Archivos principales.
	# --------------------------------------------------------

	if [[ -e "${BINARY_PATH}" ]]; then

		error_message \
			"El binario todavía existe."

		failed=1

	else

		success \
			"Binario HCR eliminado."

	fi

	if [[ -e "${TLS_CERT_PATH}" ]]; then

		error_message \
			"El certificado TLS todavía existe."

		failed=1

	else

		success \
			"Certificado TLS eliminado."

	fi

	if [[ -e "${TLS_KEY_PATH}" ]]; then

		error_message \
			"La clave privada TLS todavía existe."

		failed=1

	else

		success \
			"Clave privada TLS eliminada."

	fi

	# --------------------------------------------------------
	# Procesos.
	# --------------------------------------------------------

	if ! verify_processes; then

		failed=1

	fi

	# --------------------------------------------------------
	# Resultado.
	# --------------------------------------------------------

	if [[ "${failed}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {

	printf '\n'

	line

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}✔ DESINSTALACIÓN COMPLETADA${RESET}"

	printf '\n'

	detail \
		"Todas las instancias de HCR Server fueron detenidas."

	detail \
		"Todos los servicios HCR fueron deshabilitados."

	detail \
		"Las unidades systemd fueron eliminadas."

	detail \
		"Los drop-ins de HCR fueron eliminados."

	detail \
		"El binario hcr-server fue eliminado."

	detail \
		"El certificado TLS fue eliminado."

	detail \
		"La clave privada TLS fue eliminada."

	detail \
		"Los archivos temporales fueron eliminados."

	detail \
		"El desinstalador fue eliminado."

	printf '\n'

	printf '%b\n' \
		"${DIM}HCR Server ha sido retirado completamente del sistema.${RESET}"

	printf '%b\n' \
		"${DIM}El directorio del panel NO fue eliminado.${RESET}"

	line

	printf '\n'
}

# ============================================================
# MAIN
# ============================================================

main() {

	header

	# --------------------------------------------------------
	# ENTORNO
	# --------------------------------------------------------

	section "VERIFICANDO ENTORNO"

	require_environment

	success "Entorno compatible."

	# --------------------------------------------------------
	# BLOQUEO
	# --------------------------------------------------------

	section "ADQUIRIENDO BLOQUEO"

	acquire_uninstall_lock

	success "Bloqueo adquirido."

	# --------------------------------------------------------
	# DESCUBRIR
	# --------------------------------------------------------

	discover_instances

	# --------------------------------------------------------
	# VALIDAR
	# --------------------------------------------------------

	validate_installation

	# --------------------------------------------------------
	# CONFIRMAR
	# --------------------------------------------------------

	confirm_uninstall

	# --------------------------------------------------------
	# DETENER
	# --------------------------------------------------------

	stop_services

	# --------------------------------------------------------
	# DESHABILITAR
	# --------------------------------------------------------

	disable_services

	# --------------------------------------------------------
	# DROP-INS
	# --------------------------------------------------------

	remove_dropins

	# --------------------------------------------------------
	# UNIDADES
	# --------------------------------------------------------

	remove_systemd_units

	# --------------------------------------------------------
	# TEMPORALES
	# --------------------------------------------------------

	remove_temp_units

	# --------------------------------------------------------
	# ARCHIVOS
	# --------------------------------------------------------

	remove_installation_files

	# --------------------------------------------------------
	# DESINSTALADOR
	# --------------------------------------------------------

	remove_uninstaller

	# --------------------------------------------------------
	# VERIFICACIÓN
	# --------------------------------------------------------

	if verify_uninstall; then

		show_summary

	else

		printf '\n'

		error_message \
			"La desinstalación terminó con elementos pendientes."

		printf '\n'

		warning \
			"Revisa los elementos indicados anteriormente."

		exit 1

	fi
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
