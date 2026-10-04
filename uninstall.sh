#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HCR SERVER — DESINSTALADOR
# Compatible con el instalador HCR Server actual
#
# Elimina:
#   - Todas las instancias hcr-server-*.service
#   - Enlaces/unidades systemd correspondientes
#   - Drop-ins de systemd
#   - Binario hcr-server
#   - fullchain.pem
#   - privkey.pem
#   - Archivos temporales de systemd
#   - Este propio desinstalador
#
# NO elimina el directorio completo del panel.
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

# ============================================================
# CONFIGURACIÓN
# ============================================================

SERVICE_PREFIX="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"

# ============================================================
# RUTAS DEL DESINSTALADOR
# ============================================================

command -v readlink >/dev/null 2>&1 || {
	printf '%s\n' "Error: readlink no está instalado." >&2
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

# Lista de servicios encontrados.
SERVICES=()

# Lista de unidades fuente.
UNIT_SOURCES=()

# Lista de enlaces systemd.
UNIT_LINKS=()

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
# ERROR
# ============================================================

fail() {

	spinner_stop

	printf '\n'

	error_message "$1"

	exit 1
}

# ============================================================
# COMPROBACIÓN DE COMANDOS
# ============================================================

require_command() {

	local command_name="$1"

	command -v "${command_name}" >/dev/null 2>&1 ||
		fail \
			"No se encontró el comando requerido: ${command_name}"
}

# ============================================================
# ENTORNO
# ============================================================

require_environment() {

	if [[ "${EUID}" -ne 0 ]]; then
		fail "Este desinstalador debe ejecutarse como root."
	fi

	if [[ "$(uname -s)" != "Linux" ]]; then
		fail "Este desinstalador solamente funciona en Linux."
	fi

	for command_name in \
		systemctl \
		systemd-analyze \
		flock \
		readlink \
		stat \
		rm \
		sleep \
		grep \
		sed \
		awk \
		tail \
		head \
		find \
		sort \
		basename \
		dirname
	do
		require_command "${command_name}"
	done

	if [[ ! -d "${SYSTEMD_DIR}" ]]; then
		fail "No existe el directorio de systemd: ${SYSTEMD_DIR}"
	fi
}

# ============================================================
# BLOQUEO
# ============================================================

LOCK_FD_OPEN="false"

acquire_uninstall_lock() {

	local lock_file="${SYSTEMD_DIR}/.${SERVICE_PREFIX}.uninstall.lock"

	exec 9>"${lock_file}"

	if ! flock -n 9; then
		fail \
			"Ya existe otra operación de instalación/desinstalación de HCR Server en curso."
	fi

	LOCK_FD_OPEN="true"
}

release_uninstall_lock() {

	if [[ "${LOCK_FD_OPEN}" == "true" ]]; then

		flock -u 9 >/dev/null 2>&1 || true

		exec 9>&-

		LOCK_FD_OPEN="false"
	fi
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
# DETECTAR INSTALACIÓN DESDE UNA UNIDAD
# ============================================================

extract_working_directory() {

	local unit="$1"
	local working_directory

	working_directory="$(
		grep -E '^WorkingDirectory=' \
			"${unit}" \
			2>/dev/null |
			tail -n1 |
			sed 's/^WorkingDirectory=//' ||
			true
	)"

	printf '%s' "${working_directory}"
}

# ============================================================
# DETECTAR TODOS LOS SERVICIOS
# ============================================================

discover_services() {

	local file
	local service_name
	local found=0

	SERVICES=()
	UNIT_SOURCES=()
	UNIT_LINKS=()

	# --------------------------------------------------------
	# Buscar unidades directamente en /etc/systemd/system
	# --------------------------------------------------------

	while IFS= read -r -d '' file; do

		service_name="$(basename -- "${file}")"

		if [[ "${service_name}" =~ ^${SERVICE_PREFIX}-[0-9]+\.service$ ]]; then

			SERVICES+=("${service_name}")
			UNIT_LINKS+=("${file}")

			found=1

			# Resolver enlace si corresponde.
			if [[ -L "${file}" ]]; then
				UNIT_SOURCES+=("$(normalize_path "${file}")")
			else
				UNIT_SOURCES+=("${file}")
			fi
		fi

	done < <(
		find "${SYSTEMD_DIR}" \
			-maxdepth 1 \
			-type f \
			-name "${SERVICE_PREFIX}-*.service" \
			-print0 \
			2>/dev/null
	)

	while IFS= read -r -d '' file; do

		service_name="$(basename -- "${file}")"

		if [[ "${service_name}" =~ ^${SERVICE_PREFIX}-[0-9]+\.service$ ]]; then

			# Evitar duplicados.
			if [[ ! " ${SERVICES[*]} " =~ " ${service_name} " ]]; then

				SERVICES+=("${service_name}")
				UNIT_LINKS+=("${file}")
				UNIT_SOURCES+=("$(normalize_path "${file}")")

				found=1
			fi
		fi

	done < <(
		find "${SYSTEMD_DIR}" \
			-maxdepth 1 \
			-type l \
			-name "${SERVICE_PREFIX}-*.service" \
			-print0 \
			2>/dev/null
	)

	# --------------------------------------------------------
	# Buscar servicios conocidos por systemd.
	# --------------------------------------------------------

	while IFS= read -r service_name; do

		[[ -n "${service_name}" ]] || continue

		if [[ "${service_name}" =~ ^${SERVICE_PREFIX}-[0-9]+\.service$ ]]; then

			local duplicate="false"

			for existing in "${SERVICES[@]}"; do

				if [[ "${existing}" == "${service_name}" ]]; then
					duplicate="true"
					break
				fi

			done

			if [[ "${duplicate}" == "false" ]]; then

				local fragment

				fragment="$(
					systemctl show \
						--property=FragmentPath \
						--value \
						"${service_name}" \
						2>/dev/null ||
						true
				)"

				if [[ -n "${fragment}" ]]; then

					SERVICES+=("${service_name}")
					UNIT_LINKS+=("${SYSTEMD_DIR}/${service_name}")
					UNIT_SOURCES+=("${fragment}")

					found=1
				fi
			fi
		fi

	done < <(
		systemctl list-unit-files \
			--type=service \
			--no-legend \
			--no-pager \
			2>/dev/null |
			awk '{print $1}'
	)

	# --------------------------------------------------------
	# Ordenar resultados.
	# --------------------------------------------------------

	if [[ "${#SERVICES[@]}" -gt 1 ]]; then

		local sorted_services=()

		while IFS= read -r service_name; do
			sorted_services+=("${service_name}")
		done < <(
			printf '%s\n' "${SERVICES[@]}" |
				sort -V
		)

		SERVICES=("${sorted_services[@]}")
	fi

	return "${found}"
}

# ============================================================
# DESCUBRIR DIRECTORIO DE INSTALACIÓN
# ============================================================

discover_installation_directory() {

	local service
	local source
	local working_directory
	local candidate
	local found_directory=""

	for service in "${SERVICES[@]}"; do

		source=""

		for index in "${!SERVICES[@]}"; do

			if [[ "${SERVICES[$index]}" == "${service}" ]]; then
				source="${UNIT_SOURCES[$index]}"
				break
			fi

		done

		[[ -f "${source}" ]] || continue

		working_directory="$(
			extract_working_directory "${source}"
		)"

		if [[ -n "${working_directory}" &&
			  -d "${working_directory}" ]]; then

			candidate="$(normalize_path "${working_directory}")"

			if [[ -z "${found_directory}" ]]; then

				found_directory="${candidate}"

			elif [[ "${candidate}" != "${found_directory}" ]]; then

				fail \
					"Las instancias de HCR Server utilizan directorios de instalación diferentes:

${found_directory}

${candidate}"

			fi
		fi

	done

	# --------------------------------------------------------
	# Si no se obtuvo WorkingDirectory, utilizar las unidades.
	# --------------------------------------------------------

	if [[ -z "${found_directory}" ]]; then

		for source in "${UNIT_SOURCES[@]}"; do

			if [[ -f "${source}" ]]; then

				candidate="$(dirname -- "${source}")"

				if [[ -z "${found_directory}" ]]; then

					found_directory="$(normalize_path "${candidate}")"

				elif [[ "${candidate}" != "${found_directory}" ]]; then

					fail \
						"No se pudo determinar un único directorio de instalación."

				fi
			fi

		done
	fi

	[[ -n "${found_directory}" ]] ||
		fail \
			"No se pudo determinar el directorio de instalación de HCR Server."

	INSTALL_DIR="${found_directory}"

	BINARY_PATH="${INSTALL_DIR}/hcr-server"
	TLS_CERT_PATH="${INSTALL_DIR}/fullchain.pem"
	TLS_KEY_PATH="${INSTALL_DIR}/privkey.pem"
}

# ============================================================
# VALIDAR UNIDAD
# ============================================================

validate_unit() {

	local service="$1"
	local source="$2"
	local expected_binary

	expected_binary="${BINARY_PATH}"

	[[ -f "${source}" ]] ||
		fail \
			"La unidad ${service} no existe:

${source}"

	# --------------------------------------------------------
	# Debe pertenecer a HCR.
	# --------------------------------------------------------

	if ! grep -qE '^Description=HCR relay on port [0-9]+$' "${source}"; then

		fail \
			"La unidad ${service} no coincide con el formato del instalador HCR actual:

${source}"
	fi

	# --------------------------------------------------------
	# Debe utilizar nuestro binario.
	# --------------------------------------------------------

	if ! grep -qF \
		"ExecStart=${expected_binary}" \
		"${source}"; then

		fail \
			"La unidad ${service} no apunta al binario esperado:

${source}

Binario esperado:

${expected_binary}"
	fi
}

# ============================================================
# VALIDAR INSTALACIÓN
# ============================================================

validate_installation() {

	local index
	local service
	local source
	local link

	section "LOCALIZANDO INSTALACIÓN"

	if [[ "${#SERVICES[@]}" -eq 0 ]]; then

		error_message \
			"No se encontró ninguna instancia instalada de HCR Server."

		printf '\n'

		detail "Se buscaron unidades con el formato:"
		detail "${SERVICE_PREFIX}-<PUERTO>.service"

		printf '\n'

		info \
			"Ejemplo esperado: hcr-server-8080.service"

		exit 0
	fi

	discover_installation_directory

	printf '\n'

	success \
		"Se encontraron ${#SERVICES[@]} instancia(s) de HCR Server."

	printf '\n'

	for index in "${!SERVICES[@]}"; do

		service="${SERVICES[$index]}"
		source="${UNIT_SOURCES[$index]}"
		link="${UNIT_LINKS[$index]}"

		detail "Servicio: ${service}"
		detail "Unidad: ${source}"
		detail "Enlace: ${link}"

		validate_unit \
			"${service}" \
			"${source}"

	done

	printf '\n'

	detail "Directorio de instalación: ${INSTALL_DIR}"
	detail "Binario: ${BINARY_PATH}"
	detail "Certificado: ${TLS_CERT_PATH}"
	detail "Clave privada: ${TLS_KEY_PATH}"

	printf '\n'

	success "Instalación localizada correctamente."
}

# ============================================================
# MOSTRAR RESUMEN ANTES DE ELIMINAR
# ============================================================

confirm_uninstall() {

	local service

	printf '\n'

	warning \
		"Esta acción eliminará el servicio y sus archivos de instalación."

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Instancias detectadas:${RESET}"

	for service in "${SERVICES[@]}"; do
		detail "${service}"
	done

	printf '\n'

	detail "Directorio:     ${INSTALL_DIR}"
	detail "Binario:        ${BINARY_PATH}"
	detail "Certificado:    ${TLS_CERT_PATH}"
	detail "Clave privada:  ${TLS_KEY_PATH}"

	printf '\n'

	warning \
		"El directorio completo del panel NO será eliminado."

	warning \
		"Solo se eliminarán los archivos pertenecientes a HCR Server."

	printf '\n'

	read -r -p \
		"¿Deseas continuar? [s/N]: " answer

	case "${answer,,}" in

		s|si|sí|y|yes)
			printf '\n'
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

	local service

	section "DETENIENDO SERVICIOS"

	for service in "${SERVICES[@]}"; do

		if systemctl is-active --quiet \
			"${service}" 2>/dev/null; then

			spinner_start \
				"Deteniendo ${service}..."

			if systemctl stop "${service}"; then

				spinner_stop

				success \
					"${service} detenido."

			else

				spinner_stop

				fail \
					"No se pudo detener ${service}."
			fi

		else

			info \
				"${service} ya estaba detenido."
		fi
	done
}

# ============================================================
# DESHABILITAR TODAS LAS INSTANCIAS
# ============================================================

disable_services() {

	local service

	section "DESHABILITANDO SERVICIOS"

	for service in "${SERVICES[@]}"; do

		if systemctl is-enabled --quiet \
			"${service}" 2>/dev/null; then

			spinner_start \
				"Deshabilitando ${service}..."

			if systemctl disable "${service}" >/dev/null 2>&1; then

				spinner_stop

				success \
					"${service} deshabilitado."

			else

				spinner_stop

				fail \
					"No se pudo deshabilitar ${service}."
			fi

		else

			info \
				"${service} ya estaba deshabilitado."
		fi
	done
}

# ============================================================
# ELIMINAR DROP-INS
# ============================================================

remove_dropins() {

	local service
	local dropin_dir

	section "ELIMINANDO DROP-INS"

	for service in "${SERVICES[@]}"; do

		dropin_dir="${SYSTEMD_DIR}/${service}.d"

		if [[ -d "${dropin_dir}" ]]; then

			spinner_start \
				"Eliminando configuración adicional de ${service}..."

			if rm -rf -- "${dropin_dir}"; then

				spinner_stop

				success \
					"Drop-ins eliminados: ${service}"

			else

				spinner_stop

				fail \
					"No se pudieron eliminar los drop-ins de ${service}."
			fi

		else

			info \
				"No existen drop-ins para ${service}."
		fi
	done
}

# ============================================================
# ELIMINAR UNIDADES SYSTEMD
# ============================================================

remove_units() {

	local index
	local service
	local link
	local source

	section "ELIMINANDO UNIDADES SYSTEMD"

	for index in "${!SERVICES[@]}"; do

		service="${SERVICES[$index]}"
		link="${UNIT_LINKS[$index]}"
		source="${UNIT_SOURCES[$index]}"

		# ----------------------------------------------------
		# Eliminar enlace/unidad en /etc/systemd/system.
		# ----------------------------------------------------

		if [[ -e "${link}" || -L "${link}" ]]; then

			spinner_start \
				"Eliminando ${service}..."

			if rm -f -- "${link}"; then

				spinner_stop

				success \
					"Unidad/enlace eliminado: ${service}"

			else

				spinner_stop

				fail \
					"No se pudo eliminar ${link}."
			fi

		else

			info \
				"La unidad ${link} ya no existe."
		fi

		# ----------------------------------------------------
		# Si la fuente está fuera del directorio de instalación,
		# se eliminará posteriormente junto con las unidades.
		# ----------------------------------------------------

		if [[ -f "${source}" &&
			  "${source}" != "${UNIT_LINKS[$index]}" ]]; then

			# La fuente normalmente está en INSTALL_DIR.
			# Se elimina en remove_installation_files.
			true
		fi
	done

	# --------------------------------------------------------
	# Recargar systemd después de eliminar unidades.
	# --------------------------------------------------------

	spinner_start \
		"Recargando configuración de systemd..."

	if systemctl daemon-reload; then

		spinner_stop

		success \
			"systemd recargado correctamente."

	else

		spinner_stop

		fail \
			"No se pudo recargar systemd."
	fi

	# --------------------------------------------------------
	# Limpiar estados failed.
	# --------------------------------------------------------

	for service in "${SERVICES[@]}"; do

		systemctl reset-failed \
			"${service}" \
			>/dev/null 2>&1 ||
			true

	done
}

# ============================================================
# ELIMINAR ARCHIVOS DE INSTALACIÓN
# ============================================================

remove_file_if_exists() {

	local description="$1"
	local file="$2"

	if [[ -e "${file}" || -L "${file}" ]]; then

		spinner_start \
			"Eliminando ${description}..."

		if rm -f -- "${file}"; then

			spinner_stop

			success \
				"${description} eliminado."

		else

			spinner_stop

			fail \
				"No se pudo eliminar: ${file}"
		fi

	else

		info \
			"${description} ya no existe."
	fi
}

remove_installation_files() {

	local service
	local source
	local temp_file
	local index

	section "ELIMINANDO ARCHIVOS DE HCR SERVER"

	# --------------------------------------------------------
	# Eliminar unidades fuente.
	# --------------------------------------------------------

	for index in "${!SERVICES[@]}"; do

		source="${UNIT_SOURCES[$index]}"

		# Evitar eliminar algo fuera del directorio detectado.
		if [[ "${source}" == "${INSTALL_DIR}/"* ]]; then

			remove_file_if_exists \
				"Unidad ${SERVICES[$index]}" \
				"${source}"

		fi
	done

	# --------------------------------------------------------
	# Binario
	# --------------------------------------------------------

	remove_file_if_exists \
		"Binario HCR Server" \
		"${BINARY_PATH}"

	# --------------------------------------------------------
	# TLS
	# --------------------------------------------------------

	remove_file_if_exists \
		"Certificado TLS" \
		"${TLS_CERT_PATH}"

	remove_file_if_exists \
		"Clave privada TLS" \
		"${TLS_KEY_PATH}"

	# --------------------------------------------------------
	# Temporales creados por el instalador.
	#
	# Ejemplo:
	# .hcr-server-8080.XXXXXX.service
	# --------------------------------------------------------

	while IFS= read -r -d '' temp_file; do

		remove_file_if_exists \
			"Archivo temporal de systemd" \
			"${temp_file}"

	done < <(
		find "${INSTALL_DIR}" \
			-maxdepth 1 \
			-type f \
			-name ".${SERVICE_PREFIX}-*.service" \
			-print0 \
			2>/dev/null
	)

	# --------------------------------------------------------
	# Otros temporales ocultos relacionados con systemd.
	# --------------------------------------------------------

	while IFS= read -r -d '' temp_file; do

		remove_file_if_exists \
			"Archivo temporal HCR" \
			"${temp_file}"

	done < <(
		find "${INSTALL_DIR}" \
			-maxdepth 1 \
			-type f \
			-name ".${SERVICE_PREFIX}-*.XXXXXX*" \
			-print0 \
			2>/dev/null
	)
}

# ============================================================
# VERIFICAR PROCESOS
# ============================================================

verify_no_processes() {

	local service
	local pid
	local failed=0

	section "VERIFICANDO PROCESOS"

	for service in "${SERVICES[@]}"; do

		pid="$(
			systemctl show \
				--property=MainPID \
				--value \
				"${service}" \
				2>/dev/null ||
				true
		)"

		if [[ "${pid}" =~ ^[1-9][0-9]*$ ]]; then

			error_message \
				"${service} todavía reporta un proceso principal: PID ${pid}"

			failed=1

		else

			success \
				"No queda proceso principal para ${service}."
		fi
	done

	return "${failed}"
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_uninstall() {

	local service
	local index
	local link
	local source
	local dropin_dir
	local failed=0

	section "VERIFICACIÓN FINAL"

	# --------------------------------------------------------
	# Servicios
	# --------------------------------------------------------

	for service in "${SERVICES[@]}"; do

		if systemctl is-active --quiet \
			"${service}" 2>/dev/null; then

			error_message \
				"${service} todavía está activo."

			failed=1

		else

			success \
				"${service} está detenido."

		fi

		if systemctl is-enabled --quiet \
			"${service}" 2>/dev/null; then

			error_message \
				"${service} todavía está habilitado."

			failed=1

		else

			success \
				"${service} está deshabilitado."

		fi

	done

	# --------------------------------------------------------
	# Unidades
	# --------------------------------------------------------

	for index in "${!SERVICES[@]}"; do

		link="${UNIT_LINKS[$index]}"
		source="${UNIT_SOURCES[$index]}"

		if [[ -e "${link}" || -L "${link}" ]]; then

			error_message \
				"La unidad todavía existe: ${link}"

			failed=1

		else

			success \
				"Unidad eliminada: $(basename -- "${link}")"
		fi

		if [[ -e "${source}" || -L "${source}" ]]; then

			error_message \
				"La unidad fuente todavía existe: ${source}"

			failed=1

		else

			success \
				"Unidad fuente eliminada."
		fi

		dropin_dir="${SYSTEMD_DIR}/${SERVICES[$index]}.d"

		if [[ -e "${dropin_dir}" ]]; then

			error_message \
				"El drop-in todavía existe: ${dropin_dir}"

			failed=1

		else

			success \
				"Drop-ins eliminados."
		fi
	done

	# --------------------------------------------------------
	# Archivos
	# --------------------------------------------------------

	if [[ -e "${BINARY_PATH}" ]]; then

		error_message \
			"El binario todavía existe: ${BINARY_PATH}"

		failed=1

	else

		success \
			"Binario HCR eliminado."
	fi

	if [[ -e "${TLS_CERT_PATH}" ]]; then

		error_message \
			"El certificado todavía existe: ${TLS_CERT_PATH}"

		failed=1

	else

		success \
			"Certificado TLS eliminado."
	fi

	if [[ -e "${TLS_KEY_PATH}" ]]; then

		error_message \
			"La clave privada todavía existe: ${TLS_KEY_PATH}"

		failed=1

	else

		success \
			"Clave privada TLS eliminada."
	fi

	# --------------------------------------------------------
	# Procesos
	# --------------------------------------------------------

	if ! verify_no_processes; then
		failed=1
	fi

	return "${failed}"
}

# ============================================================
# ELIMINAR DESINSTALADOR
# ============================================================

remove_self() {

	if [[ -f "${SCRIPT_PATH}" ]]; then

		spinner_start \
			"Eliminando desinstalador..."

		if rm -f -- "${SCRIPT_PATH}"; then

			spinner_stop

			success \
				"Desinstalador eliminado."

		else

			spinner_stop

			error_message \
				"No se pudo eliminar automáticamente el desinstalador."

			return 1
		fi
	else

		info \
			"El desinstalador ya no existe."
	fi

	return 0
}

# ============================================================
# LIMPIAR LOCK
# ============================================================

remove_lock_file() {

	local lock_file="${SYSTEMD_DIR}/.${SERVICE_PREFIX}.uninstall.lock"

	release_uninstall_lock

	rm -f -- "${lock_file}" >/dev/null 2>&1 || true
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
		"Todos los servicios fueron deshabilitados."

	detail \
		"Todas las unidades systemd fueron eliminadas."

	detail \
		"Los drop-ins de HCR Server fueron eliminados."

	detail \
		"El binario hcr-server fue eliminado."

	detail \
		"El certificado TLS fue eliminado."

	detail \
		"La clave privada TLS fue eliminada."

	detail \
		"Los archivos temporales fueron eliminados."

	printf '\n'

	printf '%b\n' \
		"${DIM}El directorio del panel NO fue eliminado.${RESET}"

	printf '%b\n' \
		"${DIM}La instalación de HCR Server fue retirada del sistema.${RESET}"

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

	success \
		"Entorno Linux + systemd válido."

	# --------------------------------------------------------
	# BLOQUEO
	# --------------------------------------------------------

	acquire_uninstall_lock

	success \
		"Bloqueo de desinstalación adquirido."

	# --------------------------------------------------------
	# DETECCIÓN
	# --------------------------------------------------------

	discover_services

	# --------------------------------------------------------
	# VALIDACIÓN
	# --------------------------------------------------------

	validate_installation

	# --------------------------------------------------------
	# CONFIRMACIÓN
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

	remove_units

	# --------------------------------------------------------
	# ARCHIVOS
	# --------------------------------------------------------

	remove_installation_files

	# --------------------------------------------------------
	# VERIFICACIÓN
	# --------------------------------------------------------

	if ! verify_uninstall; then

		printf '\n'

		error_message \
			"La desinstalación terminó con elementos pendientes."

		printf '\n'

		warning \
			"No se eliminará automáticamente el desinstalador para permitir revisar el problema."

		release_uninstall_lock

		exit 1
	fi

	# --------------------------------------------------------
	# ELIMINAR DESINSTALADOR
	# --------------------------------------------------------

	if ! remove_self; then

		printf '\n'

		warning \
			"El servicio fue desinstalado correctamente, pero el desinstalador no pudo eliminarse."

		release_uninstall_lock

		exit 1
	fi

	# --------------------------------------------------------
	# LOCK
	# --------------------------------------------------------

	remove_lock_file

	# --------------------------------------------------------
	# FINAL
	# --------------------------------------------------------

	show_summary
}

# ============================================================
# LIMPIEZA ANTE INTERRUPCIÓN
# ============================================================

cleanup_on_exit() {

	local exit_code=$?

	spinner_stop

	if [[ "${LOCK_FD_OPEN}" == "true" ]]; then
		release_uninstall_lock
	fi

	exit "${exit_code}"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================
# EJECUCIÓN
# ============================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
