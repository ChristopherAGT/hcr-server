#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#                  HCR SERVER — AÑADIR PUERTO
# ============================================================
# Añade una nueva instancia independiente de HCR Server
# utilizando el binario y configuración TLS existentes.
#
# NO modifica las instancias HCR existentes.
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

TARGET_PORT="22"

MAX_DOWNLOAD_FRAME="1500"
DOWNLOAD_POLL_TIMEOUT="5s"

TRANSPORT="auto"

INSTALL_DIR=""
BINARY_PATH=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""

PORT=""

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

OK="✔"
FAIL="✖"
ARROW="➜"
BULLET="•"
WARN="!"
DIAMOND="◆"

# ============================================================
# RUTAS
# ============================================================

command -v readlink >/dev/null 2>&1 || {
	printf '%s\n' \
		"Error: readlink no está instalado." >&2
	exit 1
}

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "${SCRIPT_PATH}")"

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

	fi

	printf '\r\033[K'
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
		"${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                 H C R   S E R V E R                        ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                    A Ñ A D I R   P U E R T O               ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

	printf '\n'

	printf '%b\n' \
		"${DIM}Gestor de instancias HCR Server para Linux + systemd${RESET}"

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
# COMANDOS REQUERIDOS
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

		fail \
			"Este script debe ejecutarse como root."

	fi

	if [[ "$(uname -s)" != "Linux" ]]; then

		fail \
			"Este script solamente funciona en Linux."

	fi

	for command_name in \
		systemctl \
		systemd-analyze \
		flock \
		readlink \
		stat \
		rm \
		mv \
		mktemp \
		sleep \
		ss \
		tail \
		awk \
		grep \
		sed \
		head \
		find \
		sort \
		basename \
		dirname \
		journalctl
	do

		require_command "${command_name}"

	done

	if [[ "${TRANSPORT}" == "tls" ||
		  "${TRANSPORT}" == "auto" ]]; then

		require_command openssl

	fi

	if [[ ! -d "${SYSTEMD_DIR}" ]]; then

		fail \
			"No existe el directorio de systemd: ${SYSTEMD_DIR}"

	fi
}

# ============================================================
# BLOQUEO
# ============================================================

acquire_lock() {

	local lock_file="${SYSTEMD_DIR}/.${SERVICE_NAME}.add-port.lock"

	exec 9>"${lock_file}" ||
		fail \
			"No se pudo crear el bloqueo."

	if ! flock -n 9; then

		fail \
			"Ya existe otra operación de HCR Server en ejecución."

	fi

	LOCK_FD_OPEN="true"
}

release_lock() {

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
# VALIDACIÓN DE PUERTO
# ============================================================

validate_port() {

	local port="$1"

	[[ "${port}" =~ ^[0-9]+$ ]] ||
		return 1

	(( port >= 1 && port <= 65535 ))
}

# ============================================================
# PUERTO PRIVILEGIADO
# ============================================================

requires_privileged_port_capability() {

	local port="$1"

	(( port >= 1 && port <= 1023 ))
}

# ============================================================
# NOMBRE DE SERVICIO
# ============================================================

service_name_for_port() {

	local port="$1"

	printf '%s-%s' \
		"${SERVICE_NAME}" \
		"${port}"
}

# ============================================================
# RUTA DE UNIDAD
# ============================================================

unit_source_path_for_port() {

	local port="$1"

	printf '%s/%s-%s.service' \
		"${INSTALL_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

unit_link_path_for_port() {

	local port="$1"

	printf '%s/%s-%s.service' \
		"${SYSTEMD_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

# ============================================================
# DETECTAR HCR INSTALADO
# ============================================================

discover_installation() {

	local fragment
	local working_directory
	local candidate
	local detected_binary=""

	section "LOCALIZANDO INSTALACIÓN HCR"

	# --------------------------------------------------------
	# Buscar una unidad HCR existente.
	# --------------------------------------------------------

	while IFS= read -r service_name; do

		[[ -n "${service_name}" ]] || continue

		[[ "${service_name}" =~ ^${SERVICE_NAME}-[0-9]+\.service$ ]] ||
			continue

		fragment="$(
			systemctl show \
				--property=FragmentPath \
				--value \
				"${service_name}" \
				2>/dev/null ||
				true
		)"

		[[ -n "${fragment}" ]] || continue

		[[ -f "${fragment}" ]] || continue

		working_directory="$(
			grep -E '^WorkingDirectory=' \
				"${fragment}" \
				2>/dev/null |
				tail -n1 |
				sed 's/^WorkingDirectory=//' ||
				true
		)"

		if [[ -n "${working_directory}" &&
			  -d "${working_directory}" ]]; then

			candidate="$(normalize_path "${working_directory}")"

			if [[ -z "${INSTALL_DIR}" ]]; then

				INSTALL_DIR="${candidate}"

			elif [[ "${INSTALL_DIR}" != "${candidate}" ]]; then

				fail \
					"Se detectaron instalaciones HCR en directorios diferentes."

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
	# Si no se encontró WorkingDirectory, buscar binario.
	# --------------------------------------------------------

	if [[ -z "${INSTALL_DIR}" ]]; then

		while IFS= read -r fragment; do

			[[ -f "${fragment}" ]] || continue

			if grep -qF \
				'ExecStart=' \
				"${fragment}" 2>/dev/null; then

				detected_binary="$(
					grep '^ExecStart=' "${fragment}" |
						head -n1 |
						sed -E 's/^ExecStart=([^ ]+).*/\1/'
				)"

				if [[ -x "${detected_binary}" ]]; then

					INSTALL_DIR="$(
						dirname -- \
							"$(normalize_path "${detected_binary}")"
					)"

					break

				fi

			fi

		done < <(
			find "${SYSTEMD_DIR}" \
				-maxdepth 1 \
				-type f \
				-name "${SERVICE_NAME}-*.service" \
				-print \
				2>/dev/null
		)

	fi

	[[ -n "${INSTALL_DIR}" ]] ||
		fail \
			"No se pudo localizar una instalación existente de HCR Server."

	BINARY_PATH="${INSTALL_DIR}/hcr-server"
	TLS_CERT_PATH="${INSTALL_DIR}/fullchain.pem"
	TLS_KEY_PATH="${INSTALL_DIR}/privkey.pem"

	printf '\n'

	success \
		"Instalación HCR encontrada."

	detail \
		"Directorio: ${INSTALL_DIR}"

	detail \
		"Binario: ${BINARY_PATH}"

	detail \
		"Certificado: ${TLS_CERT_PATH}"

	detail \
		"Clave privada: ${TLS_KEY_PATH}"
}

# ============================================================
# VALIDAR BINARIO
# ============================================================

validate_binary() {

	[[ -f "${BINARY_PATH}" ]] ||
		fail \
			"No existe el binario HCR Server:

${BINARY_PATH}"

	[[ ! -L "${BINARY_PATH}" ]] ||
		fail \
			"El binario HCR no puede ser un enlace simbólico."

	[[ -x "${BINARY_PATH}" ]] ||
		fail \
			"El binario HCR no tiene permisos de ejecución."

	[[ "$(stat -c '%u' -- "${BINARY_PATH}")" == "0" ]] ||
		fail \
			"El binario HCR no pertenece a root."

	local version

	version="$(
		"${BINARY_PATH}" -version 2>/dev/null
	)" ||
		fail \
			"El binario HCR no admite el parámetro -version."

	[[ "${version}" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+(\ -\ Patch\ [1-9][0-9]*)?$ ]] ||
		fail \
			"El binario HCR devolvió una versión no reconocida."

	success \
		"Binario HCR válido: ${version}"
}

# ============================================================
# VALIDAR TLS
# ============================================================

validate_tls() {

	[[ -f "${TLS_CERT_PATH}" ]] ||
		fail \
			"No existe el certificado TLS:

${TLS_CERT_PATH}"

	[[ -f "${TLS_KEY_PATH}" ]] ||
		fail \
			"No existe la clave privada TLS:

${TLS_KEY_PATH}"

	[[ ! -L "${TLS_CERT_PATH}" ]] ||
		fail \
			"El certificado TLS no puede ser un enlace simbólico."

	[[ ! -L "${TLS_KEY_PATH}" ]] ||
		fail \
			"La clave privada TLS no puede ser un enlace simbólico."

	openssl x509 \
		-in "${TLS_CERT_PATH}" \
		-noout >/dev/null 2>&1 ||
		fail \
			"No se pudo analizar el certificado TLS."

	local certificate_public_key
	local private_public_key

	certificate_public_key="$(
		openssl x509 \
			-in "${TLS_CERT_PATH}" \
			-pubkey \
			-noout 2>/dev/null
	)" ||
		fail \
			"No se pudo obtener la clave pública del certificado."

	private_public_key="$(
		openssl pkey \
			-in "${TLS_KEY_PATH}" \
			-passin pass: \
			-pubout 2>/dev/null
	)" ||
		fail \
			"No se pudo analizar la clave privada TLS."

	[[ "${certificate_public_key}" == "${private_public_key}" ]] ||
		fail \
			"El certificado TLS y la clave privada no coinciden."

	success \
		"Certificado y clave TLS válidos."
}

# ============================================================
# COMPROBAR PUERTO
# ============================================================

check_port_available() {

	local port="$1"
	local listeners

	listeners="$(
		ss -lntp "sport = :${port}" 2>/dev/null |
			tail -n +2
	)"

	[[ -z "${listeners}" ]]
}

# ============================================================
# COMPROBAR SERVICIO EXISTENTE
# ============================================================

check_service_conflict() {

	local port="$1"
	local service_name
	local unit_source
	local unit_link

	service_name="$(service_name_for_port "${port}")"
	unit_source="$(unit_source_path_for_port "${port}")"
	unit_link="$(unit_link_path_for_port "${port}")"

	if [[ -e "${unit_source}" ||
		  -L "${unit_source}" ]]; then

		fail \
			"Ya existe una unidad HCR para el puerto ${port}:

${unit_source}"

	fi

	if [[ -e "${unit_link}" ||
		  -L "${unit_link}" ]]; then

		fail \
			"Ya existe una unidad systemd para el puerto ${port}:

${unit_link}"

	fi

	if systemctl list-unit-files \
		--type=service \
		--no-legend \
		--no-pager 2>/dev/null |
		awk '{print $1}' |
		grep -qx "${service_name}.service"; then

		fail \
			"systemd ya conoce el servicio:

${service_name}.service"

	fi
}

# ============================================================
# CONFIGURAR PUERTO
# ============================================================

configure_port() {

	local input

	section "CONFIGURACIÓN DEL NUEVO PUERTO"

	while true; do

		printf '%b' \
			"${WHITE}Nuevo puerto HCR ${DIM}[1-65535]${RESET}: "

		read -r input

		if [[ -z "${input}" ]]; then

			error_message \
				"Debes indicar un puerto."

			continue

		fi

		if ! validate_port "${input}"; then

			error_message \
				"Puerto no válido: ${input}. Debe estar entre 1 y 65535."

			continue

		fi

		if ! check_port_available "${input}"; then

			error_message \
				"El puerto ${input} ya está siendo utilizado por otro proceso."

			continue

		fi

		PORT="${input}"

		break

	done

	printf '\n'

	success \
		"Puerto HCR seleccionado: ${PORT}"

	if requires_privileged_port_capability "${PORT}"; then

		info \
			"Puerto privilegiado detectado: ${PORT}"

		detail \
			"Se utilizará CAP_NET_BIND_SERVICE."

	else

		detail \
			"Puerto no privilegiado."

		detail \
			"No se requiere CAP_NET_BIND_SERVICE."

	fi

	printf '\n'

	while true; do

		printf '%b' \
			"${WHITE}Puerto destino ${DIM}[${TARGET_PORT}]${RESET}: "

		read -r input

		if [[ -z "${input}" ]]; then

			break

		fi

		if validate_port "${input}"; then

			TARGET_PORT="${input}"

			break

		fi

		error_message \
			"Puerto destino no válido."

	done

	success \
		"Puerto destino: ${TARGET_PORT}"
}

# ============================================================
# CREAR UNIDAD SYSTEMD
# ============================================================

render_unit() {

	local tls_arguments=""
	local capability_arguments=""
	local service_name
	local unit_source

	service_name="$(service_name_for_port "${PORT}")"
	unit_source="$(unit_source_path_for_port "${PORT}")"

	# --------------------------------------------------------
	# TLS
	# --------------------------------------------------------

	if [[ "${TRANSPORT}" == "tls" ||
		  "${TRANSPORT}" == "auto" ]]; then

		tls_arguments=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"

	fi

	# --------------------------------------------------------
	# CAPACIDADES
	# --------------------------------------------------------

	if requires_privileged_port_capability "${PORT}"; then

		capability_arguments=$(
			cat <<'EOF'
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF
		)

	else

		capability_arguments=$(
			cat <<'EOF'
CapabilityBoundingSet=
AmbientCapabilities=
EOF
		)

	fi

	# --------------------------------------------------------
	# TEMPORAL
	# --------------------------------------------------------

	TEMP_UNIT="$(
		mktemp \
			"${INSTALL_DIR}/.${service_name}.XXXXXX.service"
	)"

	chmod 0600 "${TEMP_UNIT}"

	# --------------------------------------------------------
	# UNIDAD
	# --------------------------------------------------------

	cat >"${TEMP_UNIT}" <<EOF
[Unit]
Description=HCR relay on port ${PORT}
Documentation=file:${INSTALL_DIR}/README.md

Wants=network-online.target
After=network-online.target ssh.service sshd.service

StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec

User=root
Group=root

WorkingDirectory=${INSTALL_DIR}

ExecStart=${BINARY_PATH} --listen :${PORT} --target 127.0.0.1:${TARGET_PORT} --transport ${TRANSPORT}${tls_arguments} --max-download-frame ${MAX_DOWNLOAD_FRAME} --download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}

Restart=on-failure
RestartSec=5s

TimeoutStopSec=15s
KillSignal=SIGTERM

UMask=0077

# ------------------------------------------------------------
# SEGURIDAD
# ------------------------------------------------------------

NoNewPrivileges=true

${capability_arguments}

PrivateTmp=true
PrivateDevices=true

ProtectSystem=strict
ProtectHome=read-only
ProtectControlGroups=true

RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true

MemoryDenyWriteExecute=false

ReadOnlyPaths=${INSTALL_DIR}

# ------------------------------------------------------------
# RENDIMIENTO
# ------------------------------------------------------------

Nice=-5

LimitNOFILE=16384

TasksMax=1024

MemoryMax=512M
MemorySwapMax=0

LimitCORE=0

# ------------------------------------------------------------
# REGISTRO
# ------------------------------------------------------------

StandardOutput=journal
StandardError=journal

SyslogIdentifier=${service_name}

[Install]
WantedBy=multi-user.target
EOF

	chmod 0644 "${TEMP_UNIT}"

	systemd-analyze verify \
		"${TEMP_UNIT}"
}

# ============================================================
# INSTALAR UNIDAD
# ============================================================

install_unit() {

	local unit_source
	local unit_link
	local service_name

	unit_source="$(unit_source_path_for_port "${PORT}")"
	unit_link="$(unit_link_path_for_port "${PORT}")"
	service_name="$(service_name_for_port "${PORT}")"

	# --------------------------------------------------------
	# Crear unidad fuente
	# --------------------------------------------------------

	spinner_start \
		"Generando configuración para puerto ${PORT}..."

	if render_unit >/dev/null 2>&1; then

		spinner_stop

	else

		spinner_stop

		fail \
			"No se pudo generar la unidad systemd."

	fi

	# --------------------------------------------------------
	# Instalar unidad fuente
	# --------------------------------------------------------

	spinner_start \
		"Instalando unidad ${service_name}.service..."

	if mv -f \
		-- "${TEMP_UNIT}" \
		"${unit_source}"; then

		TEMP_UNIT=""

		spinner_stop

	else

		spinner_stop

		fail \
			"No se pudo instalar la unidad systemd."

	fi

	chmod 0644 "${unit_source}"

	# --------------------------------------------------------
	# Crear enlace systemd
	# --------------------------------------------------------

	spinner_start \
		"Creando enlace de systemd..."

	if ln -s \
		-- "${unit_source}" \
		"${unit_link}"; then

		spinner_stop

	else

		spinner_stop

		rm -f -- "${unit_source}" >/dev/null 2>&1 || true

		fail \
			"No se pudo crear el enlace systemd."

	fi

	# --------------------------------------------------------
	# Recargar systemd
	# --------------------------------------------------------

	spinner_start \
		"Recargando configuración de systemd..."

	if systemctl daemon-reload >/dev/null 2>&1; then

		spinner_stop

	else

		spinner_stop

		fail \
			"No se pudo recargar systemd."

	fi

	# --------------------------------------------------------
	# Habilitar
	# --------------------------------------------------------

	spinner_start \
		"Habilitando inicio automático..."

	if systemctl enable \
		"${service_name}.service" >/dev/null 2>&1; then

		spinner_stop

	else

		spinner_stop

		fail \
			"No se pudo habilitar ${service_name}.service."

	fi

	systemctl reset-failed \
		"${service_name}.service" \
		>/dev/null 2>&1 ||
		true
}

# ============================================================
# DIAGNÓSTICO
# ============================================================

show_service_diagnostics() {

	local service_name

	service_name="$(service_name_for_port "${PORT}")"

	printf '\n'

	detail \
		"Estado del servicio:"

	systemctl status \
		--no-pager \
		--full \
		"${service_name}.service" ||
		true

	printf '\n'

	detail \
		"Últimos registros:"

	journalctl \
		-u "${service_name}.service" \
		-n 30 \
		--no-pager \
		--output=short-iso ||
		true
}

# ============================================================
# COMPROBAR LISTENER
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
# VERIFICAR ESTABILIDAD
# ============================================================

verify_service_health() {

	local service_name
	local initial_pid
	local final_pid

	service_name="$(service_name_for_port "${PORT}")"

	initial_pid="$(
		systemctl show \
			--property=MainPID \
			--value \
			"${service_name}.service"
	)"

	[[ "${initial_pid}" =~ ^[1-9][0-9]*$ ]] ||
		return 1

	sleep 3

	systemctl is-active \
		--quiet \
		"${service_name}.service" ||
		return 1

	final_pid="$(
		systemctl show \
			--property=MainPID \
			--value \
			"${service_name}.service"
	)"

	[[ "${final_pid}" =~ ^[1-9][0-9]*$ ]] ||
		return 1

	[[ "${final_pid}" == "${initial_pid}" ]] ||
		return 1

	check_hcr_listener "${PORT}" ||
		return 1

	return 0
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_installation() {

	local service_name
	local unit_source
	local unit_link
	local working_directory
	local main_pid

	service_name="$(service_name_for_port "${PORT}")"
	unit_source="$(unit_source_path_for_port "${PORT}")"
	unit_link="$(unit_link_path_for_port "${PORT}")"

	section "VERIFICACIÓN FINAL"

	# --------------------------------------------------------
	# Servicio activo
	# --------------------------------------------------------

	if systemctl is-active \
		--quiet \
		"${service_name}.service"; then

		success \
			"HCR Server está activo en el puerto ${PORT}."

	else

		error_message \
			"HCR Server no está activo."

		show_service_diagnostics

		return 1
	fi

	# --------------------------------------------------------
	# Servicio habilitado
	# --------------------------------------------------------

	if systemctl is-enabled \
		--quiet \
		"${service_name}.service"; then

		success \
			"Inicio automático habilitado."

	else

		error_message \
			"El servicio no quedó habilitado."

		return 1
	fi

	# --------------------------------------------------------
	# PID
	# --------------------------------------------------------

	main_pid="$(
		systemctl show \
			--property=MainPID \
			--value \
			"${service_name}.service"
	)"

	if [[ "${main_pid}" =~ ^[1-9][0-9]*$ ]]; then

		success \
			"Proceso principal activo: PID ${main_pid}"

	else

		error_message \
			"No se pudo obtener el PID principal."

		return 1
	fi

	# --------------------------------------------------------
	# WorkingDirectory
	# --------------------------------------------------------

	working_directory="$(
		systemctl show \
			--property=WorkingDirectory \
			--value \
			"${service_name}.service"
	)"

	if [[ "${working_directory}" == "${INSTALL_DIR}" ]]; then

		success \
			"Directorio de trabajo verificado."

	else

		error_message \
			"WorkingDirectory inesperado:

Esperado:
${INSTALL_DIR}

Actual:
${working_directory}"

		return 1
	fi

	# --------------------------------------------------------
	# Unidad
	# --------------------------------------------------------

	if [[ -f "${unit_source}" ]]; then

		success \
			"Unidad fuente instalada correctamente."

	else

		error_message \
			"No existe la unidad fuente."

		return 1
	fi

	if [[ -L "${unit_link}" ]]; then

		success \
			"Enlace systemd creado correctamente."

	else

		error_message \
			"No existe el enlace systemd."

		return 1
	fi

	# --------------------------------------------------------
	# Listener
	# --------------------------------------------------------

	if check_hcr_listener "${PORT}"; then

		success \
			"HCR Server está escuchando correctamente en ${PORT}."

	else

		error_message \
			"No se detectó escucha en el puerto ${PORT}."

		return 1
	fi

	# --------------------------------------------------------
	# Estabilidad
	# --------------------------------------------------------

	spinner_start \
		"Comprobando estabilidad del nuevo servicio..."

	if verify_service_health >/dev/null 2>&1; then

		spinner_stop

		success \
			"La comprobación de estabilidad fue exitosa."

	else

		spinner_stop

		error_message \
			"La comprobación de estabilidad falló."

		show_service_diagnostics

		return 1
	fi

	return 0
}

# ============================================================
# RESUMEN
# ============================================================

show_summary() {

	local service_name

	service_name="$(service_name_for_port "${PORT}")"

	clear_screen

	printf '\n'

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║              ✔ PUERTO AÑADIDO CORRECTAMENTE               ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Configuración:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Puerto HCR    : ${BRIGHT_WHITE}${PORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Puerto destino: ${BRIGHT_WHITE}${TARGET_PORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Transporte    : ${BRIGHT_WHITE}${TRANSPORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Frame descarga: ${BRIGHT_WHITE}${MAX_DOWNLOAD_FRAME}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Poll timeout  : ${BRIGHT_WHITE}${DOWNLOAD_POLL_TIMEOUT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} File descriptors: ${BRIGHT_WHITE}16384${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Tasks máximas : ${BRIGHT_WHITE}1024${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Memoria máxima: ${BRIGHT_WHITE}512 MB${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Swap máxima   : ${BRIGHT_WHITE}0 MB${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} Prioridad     : ${BRIGHT_WHITE}Nice -5${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Instancia creada:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ARROW}${RESET} ${BRIGHT_WHITE}${service_name}.service${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Rutas:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${DIM}Unidad:${RESET} $(unit_source_path_for_port "${PORT}")"

	printf '%b\n' \
		"  ${DIM}Enlace:${RESET} $(unit_link_path_for_port "${PORT}")"

	printf '%b\n' \
		"  ${DIM}Binario:${RESET} ${BINARY_PATH}"

	printf '\n'

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}HCR Server está ejecutándose correctamente.${RESET}"

	printf '%b\n' \
		"${DIM}La nueva instancia se iniciará automáticamente con el sistema.${RESET}"

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
			-- "${TEMP_UNIT}"

	fi

	release_lock

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

	section "VERIFICANDO ENTORNO"

	spinner_start \
		"Comprobando permisos y sistema..."

	if require_environment >/dev/null 2>&1; then

		spinner_stop

		success \
			"Entorno Linux + systemd válido."

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

	if acquire_lock >/dev/null 2>&1; then

		spinner_stop

		success \
			"Bloqueo adquirido."

	else

		spinner_stop

		fail \
			"No se pudo adquirir el bloqueo."

	fi

	# --------------------------------------------------------
	# LOCALIZAR INSTALACIÓN
	# --------------------------------------------------------

	discover_installation

	# --------------------------------------------------------
	# VALIDAR ARCHIVOS
	# --------------------------------------------------------

	section "VALIDANDO INSTALACIÓN EXISTENTE"

	validate_binary

	if [[ "${TRANSPORT}" == "tls" ||
		  "${TRANSPORT}" == "auto" ]]; then

		validate_tls

	fi

	# --------------------------------------------------------
	# CONFIGURAR NUEVO PUERTO
	# --------------------------------------------------------

	configure_port

	# --------------------------------------------------------
	# COMPROBAR CONFLICTOS
	# --------------------------------------------------------

	section "COMPROBANDO CONFLICTOS"

	check_service_conflict "${PORT}"

	success \
		"No existe una instancia HCR para el puerto ${PORT}."

	success \
		"El puerto ${PORT} está disponible."

	# --------------------------------------------------------
	# INSTALAR
	# --------------------------------------------------------

	section "AÑADIENDO NUEVA INSTANCIA"

	install_unit

	# --------------------------------------------------------
	# INICIAR
	# --------------------------------------------------------

	section "INICIANDO HCR SERVER"

	local service_name

	service_name="$(service_name_for_port "${PORT}")"

	spinner_start \
		"Iniciando HCR Server en puerto ${PORT}..."

	if systemctl restart \
		"${service_name}.service" >/dev/null 2>&1; then

		spinner_stop

		success \
			"HCR Server iniciado."

	else

		spinner_stop

		error_message \
			"No se pudo iniciar HCR Server."

		show_service_diagnostics

		fail \
			"La instalación terminó con errores."
	fi

	# --------------------------------------------------------
	# VERIFICACIÓN
	# --------------------------------------------------------

	if ! verify_installation; then

		printf '\n'

		error_message \
			"La nueva instancia no superó la verificación."

		exit 1
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
