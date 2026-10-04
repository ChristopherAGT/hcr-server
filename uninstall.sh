#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — DESINSTALADOR
# Elimina completamente la instalación realizada por install.sh
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"

# ============================================================
# RUTAS
# ============================================================

command -v readlink >/dev/null 2>&1 || {
	echo "Error: readlink no está instalado." >&2
	exit 1
}

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "${SCRIPT_PATH}")"

# ------------------------------------------------------------
# Unidad principal de systemd
# ------------------------------------------------------------

UNIT_LINK_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

# ------------------------------------------------------------
# Se determinarán después de localizar la instalación real.
# ------------------------------------------------------------

INSTALL_DIR=""
UNIT_SOURCE_PATH=""
BINARY_PATH=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""

# Posible directorio de drop-ins de systemd.
SYSTEMD_DROPIN_DIR="${SYSTEMD_DIR}/${SERVICE_NAME}.service.d"

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
	printf '%b\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"
}

header() {
	clear_screen

	printf '\n'
	printf '%b\n' "${BRIGHT_CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
	printf '%b\n' "${BRIGHT_CYAN}${BOLD}║              HCR SERVER — DESINSTALADOR                  ║${RESET}"
	printf '%b\n' "${BRIGHT_CYAN}${BOLD}║                  DESINSTALACIÓN COMPLETA                 ║${RESET}"
	printf '%b\n' "${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"
	printf '\n'
}

section() {
	printf '\n%b\n' "${BRIGHT_BLUE}${BOLD}${DIAMOND} $1${RESET}"
	line
}

success() {
	printf '%b\n' "${GREEN}${OK}${RESET} $1"
}

info() {
	printf '%b\n' "${CYAN}${ARROW}${RESET} $1"
}

warning() {
	printf '%b\n' "${YELLOW}${WARN}${RESET} $1"
}

error_message() {
	printf '%b\n' "${RED}${FAIL}${RESET} $1" >&2
}

detail() {
	printf '%b\n' "  ${DIM}${BULLET}${RESET} $1"
}

# ============================================================
# SPINNER
# ============================================================

SPINNER_PID=""

spinner_start() {
	local message="$1"

	(
		local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
		local i=0

		while true; do
			printf '\r%b' "${BRIGHT_CYAN}${frames[$i]}${RESET} ${message}"
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
# CONTROL DE ERRORES
# ============================================================

fail() {
	spinner_stop
	printf '\n'
	error_message "$1"
	exit 1
}

# ============================================================
# VALIDACIONES
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
}

# ============================================================
# BLOQUEO
# ============================================================

acquire_uninstall_lock() {

	exec 9>"${SYSTEMD_DIR}/.${SERVICE_NAME}.uninstall.lock"

	flock -n 9 ||
		fail "Ya existe otra operación de instalación/desinstalación en curso."
}

# ============================================================
# NORMALIZACIÓN DE RUTAS
# ============================================================

normalize_existing_path() {

	local path="$1"

	if [[ -e "$path" || -L "$path" ]]; then
		readlink -f -- "$path"
	else
		printf '%s' "$path"
	fi
}

# ============================================================
# LOCALIZACIÓN DE SYSTEMD
# ============================================================

loaded_fragment_path() {

	systemctl show \
		-p FragmentPath \
		--value \
		"${SERVICE_NAME}.service" \
		2>/dev/null || true
}

loaded_dropin_paths() {

	systemctl show \
		-p DropInPaths \
		--value \
		"${SERVICE_NAME}.service" \
		2>/dev/null || true
}

# ============================================================
# LOCALIZACIÓN DE LA INSTALACIÓN
# ============================================================

discover_installation() {

	local fragment
	local resolved_fragment
	local working_directory
	local exec_start

	# --------------------------------------------------------
	# 1. Intentar obtener la unidad actualmente conocida
	# --------------------------------------------------------

	fragment="$(loaded_fragment_path)"

	if [[ -n "$fragment" && -f "$fragment" ]]; then

		resolved_fragment="$(normalize_existing_path "$fragment")"

		[[ -n "$resolved_fragment" ]] ||
			fail "No se pudo determinar la unidad de HCR Server."

		UNIT_SOURCE_PATH="$resolved_fragment"

	elif [[ -L "$UNIT_LINK_PATH" ]]; then

		UNIT_SOURCE_PATH="$(normalize_existing_path "$UNIT_LINK_PATH")"

	elif [[ -f "$UNIT_LINK_PATH" ]]; then

		UNIT_SOURCE_PATH="$(normalize_existing_path "$UNIT_LINK_PATH")"

	else

		# ----------------------------------------------------
		# Último intento:
		# buscar una unidad hcr-server.service dentro del
		# directorio desde el cual se ejecuta el desinstalador.
		# ----------------------------------------------------

		if [[ -f "${SCRIPT_DIR}/${SERVICE_NAME}.service" ]]; then

			UNIT_SOURCE_PATH="$(
				normalize_existing_path \
					"${SCRIPT_DIR}/${SERVICE_NAME}.service"
			)"

		else

			fail \
				"No se encontró la unidad systemd de HCR Server."
		fi
	fi

	# --------------------------------------------------------
	# 2. Determinar WorkingDirectory
	# --------------------------------------------------------

	working_directory="$(
		grep -E '^WorkingDirectory=' \
			"${UNIT_SOURCE_PATH}" \
			2>/dev/null |
			tail -n1 |
			sed 's/^WorkingDirectory=//' ||
			true
	)"

	if [[ -n "${working_directory}" &&
		  -d "${working_directory}" ]]; then

		INSTALL_DIR="$(
			normalize_existing_path \
				"${working_directory}"
		)"

	else

		# ----------------------------------------------------
		# El instalador actual coloca la unidad dentro del
		# directorio de instalación.
		# ----------------------------------------------------

		INSTALL_DIR="$(
			normalize_existing_path \
				"$(dirname -- "${UNIT_SOURCE_PATH}")"
		)"

	fi

	# --------------------------------------------------------
	# 3. Construir rutas del paquete HCR
	# --------------------------------------------------------

	BINARY_PATH="${INSTALL_DIR}/hcr-server"
	TLS_CERT_PATH="${INSTALL_DIR}/fullchain.pem"
	TLS_KEY_PATH="${INSTALL_DIR}/privkey.pem"

	# --------------------------------------------------------
	# 4. Normalizar unidad real
	# --------------------------------------------------------

	UNIT_SOURCE_PATH="$(
		normalize_existing_path \
			"${UNIT_SOURCE_PATH}"
	)"

	# --------------------------------------------------------
	# 5. Mostrar información adicional si existe ExecStart
	# --------------------------------------------------------

	exec_start="$(
		grep -E '^ExecStart=' \
			"${UNIT_SOURCE_PATH}" \
			2>/dev/null |
			tail -n1 |
			sed 's/^ExecStart=//' ||
			true
	)"

	if [[ -n "${exec_start}" ]]; then
		detail "ExecStart detectado: ${exec_start}"
	fi
}

# ============================================================
# SEGURIDAD DEL DIRECTORIO
# ============================================================

mode_is_writable_by_others() {

	local mode="$1"

	case "$mode" in
		*2|*3|*6|*7)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

validate_secure_directory() {

	local directory="$1"

	[[ -d "$directory" ]] ||
		fail \
			"El directorio de instalación no existe: ${directory}"

	local owner
	owner="$(stat -c '%U' "$directory")"

	[[ "$owner" == "root" ]] ||
		fail \
			"El directorio de instalación no pertenece a root: ${directory}"

	local mode
	mode="$(stat -c '%a' "$directory")"

	if mode_is_writable_by_others "${mode: -1}" ||
		mode_is_writable_by_others "${mode: -2:1}"; then

		fail \
			"El directorio de instalación tiene permisos inseguros: ${directory}"
	fi
}

validate_root_file() {

	local description="$1"
	local file="$2"

	[[ -e "$file" ]] || return 0

	local owner
	owner="$(stat -c '%U' "$file")"

	[[ "$owner" == "root" ]] ||
		fail \
			"${description} no pertenece a root: ${file}"
}

# ============================================================
# VALIDACIÓN DE LA UNIDAD SYSTEMD
# ============================================================

validate_unit_identity() {

	[[ -f "$UNIT_SOURCE_PATH" ]] ||
		fail \
			"La unidad systemd no existe:

${UNIT_SOURCE_PATH}"

	# --------------------------------------------------------
	# Debe corresponder al servicio HCR.
	# --------------------------------------------------------

	grep -qE '^Description=HCR relay$' \
		"${UNIT_SOURCE_PATH}" ||
		fail \
			"La unidad localizada no corresponde a HCR Server:

${UNIT_SOURCE_PATH}"

	# --------------------------------------------------------
	# Debe ejecutar el binario HCR.
	# --------------------------------------------------------

	if ! grep -qF \
		"ExecStart=${BINARY_PATH}" \
		"${UNIT_SOURCE_PATH}"; then

		fail \
			"La unidad localizada no apunta al binario HCR esperado:

${UNIT_SOURCE_PATH}"
	fi
}

validate_unit_link() {

	if [[ -L "$UNIT_LINK_PATH" ]]; then

		local target
		target="$(normalize_existing_path "$UNIT_LINK_PATH")"

		if [[ "$target" != "$UNIT_SOURCE_PATH" ]]; then

			fail \
				"El enlace de systemd apunta a una unidad inesperada:

${target}

Unidad localizada:

${UNIT_SOURCE_PATH}

Por seguridad, no se eliminará."

		fi

	elif [[ -f "$UNIT_LINK_PATH" ]]; then

		local normalized_link
		normalized_link="$(
			normalize_existing_path \
				"$UNIT_LINK_PATH"
		)"

		if [[ "$normalized_link" != "$UNIT_SOURCE_PATH" ]]; then

			fail \
				"La unidad ${UNIT_LINK_PATH} no coincide con la unidad utilizada por systemd.

Por seguridad, no se eliminará."

		fi

	else

		# Si systemd está utilizando otra unidad real, no
		# necesariamente tiene que existir el enlace.
		local fragment
		fragment="$(loaded_fragment_path)"

		if [[ -n "${fragment}" ]]; then
			return 0
		fi

		info \
			"No existe el enlace ${UNIT_LINK_PATH}."

	fi
}

validate_loaded_fragment() {

	local fragment
	fragment="$(loaded_fragment_path)"

	[[ -z "$fragment" ]] && return 0

	local normalized_fragment
	normalized_fragment="$(
		normalize_existing_path \
			"$fragment"
	)"

	local normalized_link
	normalized_link="$(
		normalize_existing_path \
			"$UNIT_LINK_PATH"
	)"

	if [[ "$normalized_fragment" != "$UNIT_SOURCE_PATH" &&
		  "$normalized_fragment" != "$normalized_link" ]]; then

		fail \
			"systemd apunta a una unidad inesperada:

${fragment}

Unidad localizada:

${UNIT_SOURCE_PATH}

Por seguridad, no se realizará la desinstalación."

	fi
}

# ============================================================
# VALIDACIÓN DE ARCHIVOS
# ============================================================

validate_installation_files() {

	discover_installation

	section "VALIDANDO INSTALACIÓN"

	detail "Unidad detectada: ${UNIT_SOURCE_PATH}"
	detail "Directorio detectado: ${INSTALL_DIR}"
	detail "Binario esperado: ${BINARY_PATH}"
	detail "Certificado esperado: ${TLS_CERT_PATH}"
	detail "Clave esperada: ${TLS_KEY_PATH}"

	validate_secure_directory \
		"${INSTALL_DIR}"

	validate_root_file \
		"Binario HCR" \
		"${BINARY_PATH}"

	validate_root_file \
		"Certificado TLS" \
		"${TLS_CERT_PATH}"

	validate_root_file \
		"Clave privada TLS" \
		"${TLS_KEY_PATH}"

	validate_root_file \
		"Unidad systemd" \
		"${UNIT_SOURCE_PATH}"

	validate_root_file \
		"Desinstalador" \
		"${SCRIPT_PATH}"

	validate_unit_identity
	validate_unit_link
	validate_loaded_fragment

	success "Instalación válida localizada."
}

# ============================================================
# CONFIRMACIÓN
# ============================================================

confirm_uninstall() {

	printf '\n'

	warning \
		"Esta operación eliminará completamente la instalación de HCR Server."

	printf '\n'

	detail "Servicio:        ${SERVICE_NAME}"
	detail "Directorio:      ${INSTALL_DIR}"
	detail "Binario:         ${BINARY_PATH}"
	detail "Certificado:     ${TLS_CERT_PATH}"
	detail "Clave privada:   ${TLS_KEY_PATH}"
	detail "Unidad:          ${UNIT_SOURCE_PATH}"
	detail "Enlace systemd:  ${UNIT_LINK_PATH}"

	if [[ -d "${SYSTEMD_DROPIN_DIR}" ]]; then
		detail "Drop-ins:        ${SYSTEMD_DROPIN_DIR}"
	fi

	detail "Desinstalador:   ${SCRIPT_PATH}"

	printf '\n'

	warning \
		"Se eliminarán los archivos relacionados con HCR Server."

	warning \
		"El directorio completo del panel NO será eliminado automáticamente."

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
# DETENER SERVICIO
# ============================================================

stop_service() {

	section "DETENIENDO SERVICIO"

	if systemctl is-active --quiet \
		"${SERVICE_NAME}" 2>/dev/null; then

		spinner_start \
			"Deteniendo ${SERVICE_NAME}..."

		if systemctl stop "${SERVICE_NAME}"; then

			spinner_stop
			success "Servicio detenido."

		else

			spinner_stop
			fail \
				"No se pudo detener ${SERVICE_NAME}."

		fi

	else

		info "El servicio ya estaba detenido."

	fi
}

# ============================================================
# DESHABILITAR SERVICIO
# ============================================================

disable_service() {

	section "DESHABILITANDO SERVICIO"

	if systemctl is-enabled --quiet \
		"${SERVICE_NAME}" 2>/dev/null; then

		spinner_start \
			"Deshabilitando ${SERVICE_NAME}..."

		if systemctl disable \
			"${SERVICE_NAME}"; then

			spinner_stop
			success "Servicio deshabilitado."

		else

			spinner_stop
			fail \
				"No se pudo deshabilitar ${SERVICE_NAME}."

		fi

	else

		info "El servicio ya estaba deshabilitado."

	fi
}

# ============================================================
# ELIMINAR DROP-INS DE SYSTEMD
# ============================================================

remove_systemd_dropins() {

	section "ELIMINANDO CONFIGURACIÓN ADICIONAL DE SYSTEMD"

	if [[ ! -d "${SYSTEMD_DROPIN_DIR}" ]]; then

		info "No existen drop-ins para ${SERVICE_NAME}."

		return 0
	fi

	spinner_start \
		"Eliminando drop-ins de ${SERVICE_NAME}..."

	if rm -rf -- "${SYSTEMD_DROPIN_DIR}"; then

		spinner_stop
		success "Drop-ins de systemd eliminados."

	else

		spinner_stop
		fail \
			"No se pudieron eliminar los drop-ins de systemd."

	fi
}

# ============================================================
# ELIMINAR UNIDAD SYSTEMD
# ============================================================

remove_systemd_unit() {

	section "ELIMINANDO UNIDAD SYSTEMD"

	# --------------------------------------------------------
	# Eliminar enlace o unidad principal en /etc/systemd/system
	# --------------------------------------------------------

	if [[ -L "$UNIT_LINK_PATH" ]]; then

		spinner_start \
			"Eliminando enlace systemd..."

		rm -f -- "$UNIT_LINK_PATH"

		spinner_stop
		success "Enlace systemd eliminado."

	elif [[ -f "$UNIT_LINK_PATH" ]]; then

		# Solo se elimina si fue validado anteriormente.
		spinner_start \
			"Eliminando unidad systemd..."

		rm -f -- "$UNIT_LINK_PATH"

		spinner_stop
		success "Unidad systemd eliminada."

	else

		info \
			"La unidad systemd principal ya no existe."

	fi

	# --------------------------------------------------------
	# Recargar systemd
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
	# Limpiar estado failed
	# --------------------------------------------------------

	systemctl reset-failed \
		"${SERVICE_NAME}" \
		2>/dev/null ||
		true
}

# ============================================================
# ELIMINAR ARCHIVOS DE LA INSTALACIÓN
# ============================================================

remove_installation_files() {

	section "ELIMINANDO ARCHIVOS DE HCR SERVER"

	local files=(
		"${BINARY_PATH}"
		"${TLS_CERT_PATH}"
		"${TLS_KEY_PATH}"
		"${UNIT_SOURCE_PATH}"
	)

	local file

	for file in "${files[@]}"; do

		if [[ -e "$file" || -L "$file" ]]; then

			spinner_start \
				"Eliminando $(basename "$file")..."

			rm -f -- "$file"

			spinner_stop

			success \
				"Eliminado: $(basename "$file")"

		else

			detail \
				"No existe: $(basename "$file")"

		fi

	done

	# --------------------------------------------------------
	# Eliminar archivos temporales del instalador
	# --------------------------------------------------------

	local temp_units=()

	while IFS= read -r -d '' file; do
		temp_units+=("$file")
	done < <(
		find "${INSTALL_DIR}" \
			-maxdepth 1 \
			-type f \
			-name ".${SERVICE_NAME}.*.service" \
			-print0 \
			2>/dev/null
	)

	for file in "${temp_units[@]}"; do

		spinner_start \
			"Eliminando archivo temporal de systemd..."

		rm -f -- "$file"

		spinner_stop

		success \
			"Temporal eliminado: $(basename "$file")"

	done

	# --------------------------------------------------------
	# El propio desinstalador se elimina al final.
	# --------------------------------------------------------

	if [[ -f "$SCRIPT_PATH" ]]; then

		spinner_start \
			"Eliminando desinstalador..."

		rm -f -- "$SCRIPT_PATH"

		spinner_stop

		success "Desinstalador eliminado."

	fi
}

# ============================================================
# LIMPIEZA DEL LOCK
# ============================================================

remove_lock_file() {

	local lock_file="${SYSTEMD_DIR}/.${SERVICE_NAME}.uninstall.lock"

	if [[ -e "$lock_file" ]]; then
		rm -f -- "$lock_file" 2>/dev/null || true
	fi
}

# ============================================================
# VERIFICACIÓN DE PROCESOS
# ============================================================

verify_processes() {

	section "VERIFICANDO PROCESOS"

	local main_pid

	main_pid="$(
		systemctl show \
			-p MainPID \
			--value \
			"${SERVICE_NAME}.service" \
			2>/dev/null ||
			true
	)"

	if [[ "${main_pid}" =~ ^[1-9][0-9]*$ ]]; then

		error_message \
			"El servicio todavía tiene un proceso principal: PID ${main_pid}"

		return 1

	fi

	success "No queda un proceso principal de HCR Server."

	return 0
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_uninstall() {

	section "VERIFICACIÓN FINAL"

	local failed=0

	# --------------------------------------------------------
	# Servicio activo
	# --------------------------------------------------------

	if systemctl is-active --quiet \
		"${SERVICE_NAME}" 2>/dev/null; then

		error_message \
			"El servicio todavía aparece activo."

		failed=1

	else

		success \
			"Servicio detenido."

	fi

	# --------------------------------------------------------
	# Servicio habilitado
	# --------------------------------------------------------

	if systemctl is-enabled --quiet \
		"${SERVICE_NAME}" 2>/dev/null; then

		error_message \
			"El servicio todavía aparece habilitado."

		failed=1

	else

		success \
			"Servicio deshabilitado."

	fi

	# --------------------------------------------------------
	# Unidad principal
	# --------------------------------------------------------

	if [[ -e "$UNIT_LINK_PATH" ||
		  -L "$UNIT_LINK_PATH" ]]; then

		error_message \
			"La unidad systemd todavía existe."

		failed=1

	else

		success \
			"Unidad systemd eliminada."

	fi

	# --------------------------------------------------------
	# Unidad fuente
	# --------------------------------------------------------

	if [[ -e "$UNIT_SOURCE_PATH" ||
		  -L "$UNIT_SOURCE_PATH" ]]; then

		error_message \
			"La unidad fuente todavía existe."

		failed=1

	else

		success \
			"Unidad fuente eliminada."

	fi

	# --------------------------------------------------------
	# Drop-ins
	# --------------------------------------------------------

	if [[ -e "${SYSTEMD_DROPIN_DIR}" ]]; then

		error_message \
			"El directorio de drop-ins todavía existe."

		failed=1

	else

		success \
			"Drop-ins eliminados."

	fi

	# --------------------------------------------------------
	# Binario
	# --------------------------------------------------------

	if [[ -e "$BINARY_PATH" ]]; then

		error_message \
			"El binario todavía existe."

		failed=1

	else

		success \
			"Binario eliminado."

	fi

	# --------------------------------------------------------
	# Certificado
	# --------------------------------------------------------

	if [[ -e "$TLS_CERT_PATH" ]]; then

		error_message \
			"El certificado TLS todavía existe."

		failed=1

	else

		success \
			"Certificado TLS eliminado."

	fi

	# --------------------------------------------------------
	# Clave privada
	# --------------------------------------------------------

	if [[ -e "$TLS_KEY_PATH" ]]; then

		error_message \
			"La clave TLS todavía existe."

		failed=1

	else

		success \
			"Clave TLS eliminada."

	fi

	# --------------------------------------------------------
	# Desinstalador
	# --------------------------------------------------------

	if [[ -e "$SCRIPT_PATH" ]]; then

		error_message \
			"El desinstalador todavía existe."

		failed=1

	else

		success \
			"Desinstalador eliminado."

	fi

	# --------------------------------------------------------
	# Procesos
	# --------------------------------------------------------

	if ! verify_processes; then
		failed=1
	fi

	# --------------------------------------------------------
	# Resultado
	# --------------------------------------------------------

	if [[ "$failed" -ne 0 ]]; then
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
		"Servicio detenido y deshabilitado."

	detail \
		"Unidad systemd eliminada."

	detail \
		"Configuraciones adicionales de systemd eliminadas."

	detail \
		"Binario HCR eliminado."

	detail \
		"Certificado TLS eliminado."

	detail \
		"Clave TLS eliminada."

	detail \
		"Archivos temporales eliminados."

	detail \
		"Desinstalador eliminado."

	printf '\n'

	printf '%b\n' \
		"${DIM}La instalación de HCR Server ha sido retirada del sistema.${RESET}"

	printf '%b\n' \
		"${DIM}El directorio del panel no fue eliminado.${RESET}"

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

	require_environment

	# --------------------------------------------------------
	# BLOQUEO
	# --------------------------------------------------------

	acquire_uninstall_lock

	# --------------------------------------------------------
	# LOCALIZAR INSTALACIÓN
	# --------------------------------------------------------

	validate_installation_files

	# --------------------------------------------------------
	# CONFIRMACIÓN
	# --------------------------------------------------------

	confirm_uninstall

	# --------------------------------------------------------
	# DETENER
	# --------------------------------------------------------

	stop_service

	# --------------------------------------------------------
	# DESHABILITAR
	# --------------------------------------------------------

	disable_service

	# --------------------------------------------------------
	# DROP-INS
	# --------------------------------------------------------

	remove_systemd_dropins

	# --------------------------------------------------------
	# SYSTEMD
	# --------------------------------------------------------

	remove_systemd_unit

	# --------------------------------------------------------
	# ARCHIVOS
	# --------------------------------------------------------

	remove_installation_files

	# --------------------------------------------------------
	# VERIFICACIÓN
	# --------------------------------------------------------

	if verify_uninstall; then

		remove_lock_file

		show_summary

	else

		printf '\n'

		error_message \
			"La desinstalación terminó con elementos pendientes."

		printf '\n'

		warning \
			"Revisa manualmente los elementos indicados anteriormente."

		exit 1

	fi
}

main "$@"


