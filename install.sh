#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#                  HCR SERVER INSTALLER
# ============================================================
# Instalador independiente de HCR Server para Linux + systemd
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

# ------------------------------------------------------------
# CONFIGURACIÓN
# ------------------------------------------------------------

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"

PORT="8080"
PORTS=()
TARGET_PORT="22"

# Ajustes de rendimiento
MAX_DOWNLOAD_FRAME="1500"
DOWNLOAD_POLL_TIMEOUT="5s"

TRANSPORT="auto"

TEMP_UNIT=""
TEMP_UNITS=()

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
MAGENTA="\033[35m"
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
# RUTAS
# ------------------------------------------------------------

command -v readlink >/dev/null 2>&1 || {
	echo "Error: readlink no está instalado." >&2
	exit 1
}

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "${SCRIPT_PATH}")"

BINARY_PATH="${SCRIPT_DIR}/hcr-server"
TLS_CERT_PATH="${SCRIPT_DIR}/fullchain.pem"
TLS_KEY_PATH="${SCRIPT_DIR}/privkey.pem"

UNIT_SOURCE_PATH="${SCRIPT_DIR}/${SERVICE_NAME}.service"
UNIT_LINK_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

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
	printf "║                    I N S T A L A D O R                    ║\n"
	printf "║                                                            ║\n"
	printf "╚════════════════════════════════════════════════════════════╝\n"

	printf "${RESET}\n"

	printf "${DIM} Instalador profesional para Linux + systemd${RESET}\n"
	printf "\n"
}

section() {
	printf "\n${BOLD}${BRIGHT_BLUE}◆ %s${RESET}\n" "$1"
	line
}

success() {
	printf "${BRIGHT_GREEN}${ICON_OK}${RESET} ${GREEN}%s${RESET}\n" "$1"
}

info() {
	printf "${BRIGHT_CYAN}${ICON_INFO}${RESET} ${WHITE}%s${RESET}\n" "$1"
}

warning() {
	printf "${YELLOW}${ICON_WARN}${RESET} ${YELLOW}%s${RESET}\n" "$1"
}

error_message() {
	printf "${RED}${ICON_FAIL}${RESET} ${RED}%s${RESET}\n" "$1" >&2
}

detail() {
	printf "  ${DIM}${ICON_DOT} %s${RESET}\n" "$1"
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

			printf "\r${BRIGHT_CYAN}%s${RESET} ${WHITE}%s${RESET}" \
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

run_spinner() {
	local message="$1"

	shift

	spinner_start "${message}"

	if "$@" >/dev/null 2>&1; then

		spinner_stop ok

		return 0

	else

		spinner_stop fail

		return 1

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
# VALIDACIÓN DE PUERTO
# ------------------------------------------------------------

validate_port() {
	local port="$1"

	[[ "${port}" =~ ^[0-9]+$ ]] ||
		return 1

	(( port >= 1 && port <= 65535 ))
}

# ------------------------------------------------------------
# COMPROBAR DISPONIBILIDAD DEL PUERTO
# ------------------------------------------------------------

check_port_available() {
	local port="$1"
	local listeners

	listeners="$(
		ss -lntp "sport = :${port}" 2>/dev/null |
			tail -n +2
	)"

	if [ -z "${listeners}" ]; then
		return 0
	fi

	# Si una instancia HCR ya ocupa el puerto, permitimos
	# continuar para poder reinstalar/reconfigurar esa instancia.
	if echo "${listeners}" | grep -q '"hcr-server"'; then
		return 0
	fi

	return 1
}

# ------------------------------------------------------------
# PUERTOS PRIVILEGIADOS
# ------------------------------------------------------------

requires_privileged_port_capability() {
	local port="$1"

	(( port >= 1 && port <= 1023 ))
}

configure_port_capability() {
	local port="$1"

	if requires_privileged_port_capability "${port}"; then

		info "Puerto HCR privilegiado detectado: ${port}"

		detail \
			"Se habilitará CAP_NET_BIND_SERVICE exclusivamente para HCR Server."

	else

		detail "Puerto HCR no privilegiado: ${port}"

		detail "No se requiere CAP_NET_BIND_SERVICE."

	fi
}

# ------------------------------------------------------------
# COMPROBAR LISTENER HCR
# ------------------------------------------------------------

check_hcr_listener() {
	local port="$1"

	# Acepta:
	#
	# 0.0.0.0:80
	# [::]:80
	# *:80
	#
	# Se comprueba solamente el puerto final de la
	# dirección local.

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

# ------------------------------------------------------------
# NOMBRE DE SERVICIO POR PUERTO
# ------------------------------------------------------------

service_name_for_port() {
	local port="$1"

	printf "%s-%s" \
		"${SERVICE_NAME}" \
		"${port}"
}

unit_source_path_for_port() {
	local port="$1"

	printf "%s/%s-%s.service" \
		"${SCRIPT_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

unit_link_path_for_port() {
	local port="$1"

	printf "%s/%s-%s.service" \
		"${SYSTEMD_DIR}" \
		"${SERVICE_NAME}" \
		"${port}"
}

# ------------------------------------------------------------
# CONFIGURACIÓN DE PUERTOS
# ------------------------------------------------------------

configure_ports() {
	local input
	local port
	local duplicate
	local selected_ports=()

	section "Configuración de puertos"

	while true; do

		printf \
			"${WHITE}Puertos para HCR Server${RESET} ${DIM}[${PORT}]${RESET}: "

		read -r input

		if [ -z "${input}" ]; then
			input="${PORT}"
		fi

		# ----------------------------------------------------
		# VALIDAR CADA PUERTO
		# ----------------------------------------------------

		selected_ports=()

		for port in ${input}; do

			if ! validate_port "${port}"; then

				error_message \
					"Puerto no válido: ${port}. Debe estar entre 1 y 65535."

				selected_ports=()

				break
			fi

			duplicate="false"

			for existing_port in "${selected_ports[@]}"; do

				if [ "${existing_port}" = "${port}" ]; then
					duplicate="true"
					break
				fi

			done

			if [ "${duplicate}" = "true" ]; then

				error_message \
					"El puerto ${port} está duplicado."

				selected_ports=()

				break
			fi

			if ! check_port_available "${port}"; then

				error_message \
					"El puerto ${port} ya está siendo utilizado por otro servicio."

				selected_ports=()

				break
			fi

			selected_ports+=("${port}")

		done

		[ "${#selected_ports[@]}" -gt 0 ] ||
			continue

		break

	done

	PORTS=("${selected_ports[@]}")
	PORT="${PORTS[0]}"

	printf "\n"

	for port in "${PORTS[@]}"; do

		success "Puerto HCR configurado: ${port}"

		configure_port_capability "${port}"

	done

	while true; do

		printf \
			"${WHITE}Puerto destino para redirección${RESET} ${DIM}[${TARGET_PORT}]${RESET}: "

		read -r input

		if [ -z "${input}" ]; then
			break
		fi

		if validate_port "${input}"; then

			TARGET_PORT="${input}"

			break
		fi

		error_message \
			"Puerto no válido. Debe estar entre 1 y 65535."

	done

	success "Puerto destino configurado: ${TARGET_PORT}"
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
		fail "Este instalador debe ejecutarse como root."

	[ "$(uname -s)" = "Linux" ] ||
		fail "Este instalador solamente es compatible con Linux."

	for command_name in \
		stat \
		systemctl \
		systemd-analyze \
		flock \
		ln \
		mv \
		mktemp \
		sleep \
		ss \
		tail \
		awk \
		grep \
		dirname \
		readlink \
		journalctl
	do

		require_command "${command_name}"

	done

	if [ "${TRANSPORT}" = "tls" ] ||
		[ "${TRANSPORT}" = "auto" ]; then

		require_command openssl

	fi

	systemctl show \
		--property=Version \
		--value >/dev/null 2>&1 ||
		fail "El administrador systemd no está disponible."

	if [[ ! "${SCRIPT_DIR}" =~ ^/[-A-Za-z0-9._/@+:]+$ ]]; then

		fail \
			"El directorio del instalador contiene caracteres no compatibles."

	fi
}

# ------------------------------------------------------------
# BLOQUEO
# ------------------------------------------------------------

acquire_install_lock() {

	exec 9<"${SYSTEMD_DIR}" ||
		fail \
			"No se pudo abrir el directorio de systemd para bloqueo."

	flock -n 9 ||
		fail \
			"Ya existe otra instalación de HCR Server en ejecución."
}

# ------------------------------------------------------------
# SEGURIDAD
# ------------------------------------------------------------

mode_is_writable_by_others() {
	(( (8#$1 & 8#022) != 0 ))
}

validate_secure_directory() {

	local current="${SCRIPT_DIR}"
	local mode

	while :; do

		[ -d "${current}" ] &&
			[ ! -L "${current}" ] ||
			fail \
				"El componente de ruta no es un directorio válido: ${current}"

		[ "$(stat -c '%u' -- "${current}")" = "0" ] ||
			fail \
				"El directorio no pertenece a root: ${current}"

		mode="$(stat -c '%a' -- "${current}")"

		mode_is_writable_by_others "${mode}" &&
			fail \
				"El directorio es escribible por grupo u otros usuarios: ${current}"

		[ "${current}" = "/" ] &&
			break

		current="$(dirname -- "${current}")"

	done
}

validate_root_file() {

	local executable="$1"
	local label="$2"
	local path="$3"
	local mode

	[ -f "${path}" ] &&
		[ ! -L "${path}" ] ||
		fail \
			"${label} debe ser un archivo regular: ${path}"

	[ "$(stat -c '%u' -- "${path}")" = "0" ] ||
		fail \
			"${label} debe pertenecer a root: ${path}"

	mode="$(stat -c '%a' -- "${path}")"

	mode_is_writable_by_others "${mode}" &&
		fail \
			"${label} es escribible por grupo u otros usuarios: ${path}"

	if [ "${executable}" = "true" ] &&
		[ ! -x "${path}" ]; then

		fail \
			"${label} debe tener permisos de ejecución: ${path}"

	fi
}

# ------------------------------------------------------------
# VALIDACIÓN SYSTEMD
# ------------------------------------------------------------

validate_unit_link() {

	local port
	local unit_link
	local unit_source
	local service_name

	for port in "${PORTS[@]}"; do

		unit_link="$(unit_link_path_for_port "${port}")"
		unit_source="$(unit_source_path_for_port "${port}")"
		service_name="$(service_name_for_port "${port}")"

		if [ -L "${unit_link}" ]; then

			[ "$(readlink -- "${unit_link}")" = "${unit_source}" ] ||
				fail \
					"Ya existe un enlace ${service_name}.service diferente."

		elif [ -e "${unit_link}" ]; then

			fail \
				"Ya existe una unidad no simbólica en ${unit_link}"

		fi

	done
}

loaded_fragment_path() {
	local service_name="$1"

	systemctl show \
		--property=FragmentPath \
		--value \
		"${service_name}.service" \
		2>/dev/null || true
}

validate_loaded_fragment() {

	local service_name="$1"
	local unit_source="$2"
	local unit_link="$3"

	case "$(loaded_fragment_path "${service_name}")" in

		"")
			;;

		"${unit_source}")
			;;

		"${unit_link}")
			;;

		*)
			fail \
				"systemd está utilizando una unidad ${service_name}.service inesperada."
			;;

	esac
}

# ------------------------------------------------------------
# VALIDACIÓN DEL BINARIO
# ------------------------------------------------------------

validate_binary_identity() {

	local path="$1"
	local output

	output="$(
		"${path}" -version 2>/dev/null
	)" ||
		fail \
			"El binario no admite el parámetro -version."

	[[ "${output}" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+(\ -\ Patch\ [1-9][0-9]*)?$ ]] ||
		fail \
			"El binario devolvió una versión no reconocida."
}

validate_binary() {

	validate_root_file \
		true \
		"Binario HCR" \
		"${BINARY_PATH}"

	validate_binary_identity "${BINARY_PATH}"
}

# ------------------------------------------------------------
# VALIDACIÓN TLS
# ------------------------------------------------------------

validate_tls_pair() {

	local certificate_public_key
	local private_public_key

	openssl x509 \
		-in "${TLS_CERT_PATH}" \
		-noout >/dev/null 2>&1 ||
		fail \
			"No se pudo analizar el certificado TLS."

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

	[ "${certificate_public_key}" = "${private_public_key}" ] ||
		fail \
			"El certificado TLS y la clave privada no coinciden."
}

# ------------------------------------------------------------
# VALIDACIÓN DEL PAQUETE
# ------------------------------------------------------------

validate_bundle() {

	local key_mode

	section "Comprobando archivos"

	validate_secure_directory

	success "Directorio seguro"

	validate_root_file \
		true \
		"Instalador" \
		"${SCRIPT_PATH}"

	success "Instalador válido"

	validate_binary

	success "Binario HCR válido"

	if [ "${TRANSPORT}" = "tls" ] ||
		[ "${TRANSPORT}" = "auto" ]; then

		validate_root_file \
			false \
			"Certificado TLS" \
			"${TLS_CERT_PATH}"

		success "Certificado TLS válido"

		validate_root_file \
			false \
			"Clave privada TLS" \
			"${TLS_KEY_PATH}"

		key_mode="$(stat -c '%a' -- "${TLS_KEY_PATH}")"

		(( (8#${key_mode} & 8#077) == 0 )) ||
			fail \
				"La clave privada TLS debe estar protegida contra otros usuarios."

		validate_tls_pair

		success "Certificado y clave TLS coinciden"

	fi
}

# ------------------------------------------------------------
# GENERACIÓN DE SYSTEMD
# ------------------------------------------------------------

render_unit() {

	local port="$1"
	local tls_arguments=""
	local capability_arguments=""
	local service_name
	local unit_source

	service_name="$(service_name_for_port "${port}")"
	unit_source="$(unit_source_path_for_port "${port}")"

	# --------------------------------------------------------
	# TLS
	# --------------------------------------------------------

	if [ "${TRANSPORT}" = "tls" ] ||
		[ "${TRANSPORT}" = "auto" ]; then

		tls_arguments=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"

	fi

	# --------------------------------------------------------
	# CAPABILITIES
	# --------------------------------------------------------

	if requires_privileged_port_capability "${port}"; then

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
	# ARCHIVO TEMPORAL
	# --------------------------------------------------------

	TEMP_UNIT="$(
		mktemp \
			"${SCRIPT_DIR}/.${service_name}.XXXXXX.service"
	)"

	TEMP_UNITS+=("${TEMP_UNIT}")

	chmod 0600 "${TEMP_UNIT}"

	# --------------------------------------------------------
	# SYSTEMD UNIT
	# --------------------------------------------------------

	cat >"${TEMP_UNIT}" <<EOF
[Unit]
Description=HCR relay on port ${port}
Documentation=file:${SCRIPT_DIR}/README.md

Wants=network-online.target
After=network-online.target ssh.service sshd.service

StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec

User=root
Group=root

WorkingDirectory=${SCRIPT_DIR}

ExecStart=${BINARY_PATH} --listen :${port} --target 127.0.0.1:${TARGET_PORT} --transport ${TRANSPORT}${tls_arguments} --max-download-frame ${MAX_DOWNLOAD_FRAME} --download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}

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

ReadOnlyPaths=${SCRIPT_DIR}

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

	systemd-analyze verify "${TEMP_UNIT}"
}

# ------------------------------------------------------------
# LIMPIEZA
# ------------------------------------------------------------

cleanup() {

	local exit_code=$?
	local temp_unit

	trap - EXIT

	set +e

	if [ -n "${TEMP_UNIT}" ]; then
		rm -f -- "${TEMP_UNIT}"
	fi

	for temp_unit in "${TEMP_UNITS[@]}"; do
		rm -f -- "${temp_unit}"
	done

	exit "${exit_code}"
}

# ------------------------------------------------------------
# DIAGNÓSTICO
# ------------------------------------------------------------

show_service_diagnostics() {

	local port="$1"
	local service_name

	service_name="$(service_name_for_port "${port}")"

	printf "\n"

	detail "Estado del servicio ${service_name}:"

	systemctl status \
		--no-pager \
		--full \
		"${service_name}.service" ||
		true

	printf "\n"

	detail "Últimos registros de HCR Server:"

	journalctl \
		-u "${service_name}.service" \
		-n 30 \
		--no-pager \
		--output=short-iso ||
		true
}

# ------------------------------------------------------------
# VERIFICACIÓN DE ESTABILIDAD
# ------------------------------------------------------------

verify_service_health() {

	local port="$1"
	local service_name
	local initial_pid
	local final_pid

	service_name="$(service_name_for_port "${port}")"

	# --------------------------------------------------------
	# PID INICIAL
	# --------------------------------------------------------

	initial_pid="$(
		systemctl show \
			--property=MainPID \
			--value \
			"${service_name}.service"
	)"

	[[ "${initial_pid}" =~ ^[1-9][0-9]*$ ]] ||
		return 1

	# --------------------------------------------------------
	# ESPERAR
	# --------------------------------------------------------

	sleep 3

	# --------------------------------------------------------
	# ESTADO
	# --------------------------------------------------------

	systemctl is-active --quiet \
		"${service_name}.service" ||
		return 1

	# --------------------------------------------------------
	# PID FINAL
	# --------------------------------------------------------

	final_pid="$(
		systemctl show \
			--property=MainPID \
			--value \
			"${service_name}.service"
	)"

	[[ "${final_pid}" =~ ^[1-9][0-9]*$ ]] ||
		return 1

	# El PID no debe haber cambiado.
	[ "${final_pid}" = "${initial_pid}" ] ||
		return 1

	# --------------------------------------------------------
	# LISTENER
	# --------------------------------------------------------

	check_hcr_listener "${port}" ||
		return 1

	return 0
}

# ------------------------------------------------------------
# INSTALACIÓN
# ------------------------------------------------------------

install_service() {

	local port
	local service_name
	local unit_source
	local unit_link

	section "Preparando instalación"

	validate_unit_link

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"
		unit_source="$(unit_source_path_for_port "${port}")"
		unit_link="$(unit_link_path_for_port "${port}")"

		validate_loaded_fragment \
			"${service_name}" \
			"${unit_source}" \
			"${unit_link}"

	done

	success "No existen conflictos con systemd"

	# --------------------------------------------------------
	# GENERAR SYSTEMD
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		spinner_start \
			"Generando configuración de systemd para puerto ${port}..."

		if render_unit "${port}" >/dev/null 2>&1; then

			spinner_stop ok

		else

			spinner_stop fail

			fail \
				"No se pudo generar la unidad systemd para el puerto ${port}."

		fi

	done

	# --------------------------------------------------------
	# INSTALAR SYSTEMD
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"
		unit_source="$(unit_source_path_for_port "${port}")"

		# Buscar el temporal correspondiente.
		TEMP_UNIT=""

		for candidate in "${TEMP_UNITS[@]}"; do

			if grep -q \
				"Description=HCR relay on port ${port}" \
				"${candidate}" 2>/dev/null; then

				TEMP_UNIT="${candidate}"
				break

			fi

		done

		[ -n "${TEMP_UNIT}" ] ||
			fail \
				"No se encontró la unidad temporal del puerto ${port}."

		spinner_start \
			"Instalando unidad HCR Server para puerto ${port}..."

		if mv -f \
			-- "${TEMP_UNIT}" \
			"${unit_source}"; then

			TEMP_UNIT=""

			spinner_stop ok

		else

			spinner_stop fail

			fail \
				"No se pudo instalar la unidad systemd para el puerto ${port}."

		fi

	done

	# --------------------------------------------------------
	# ENLACES
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		unit_source="$(unit_source_path_for_port "${port}")"
		unit_link="$(unit_link_path_for_port "${port}")"

		if [ -L "${unit_link}" ]; then

			success \
				"Enlace systemd existente y verificado para puerto ${port}"

		else

			spinner_start \
				"Creando enlace de systemd para puerto ${port}..."

			if ln -s \
				-- "${unit_source}" \
				"${unit_link}"; then

				spinner_stop ok

			else

				spinner_stop fail

				fail \
					"No se pudo crear el enlace systemd para puerto ${port}."

			fi
		fi

	done

	# --------------------------------------------------------
	# CONFIGURAR SYSTEMD
	# --------------------------------------------------------

	section "Configurando servicios"

	spinner_start \
		"Recargando configuración de systemd..."

	if systemctl daemon-reload >/dev/null 2>&1; then

		spinner_stop ok

	else

		spinner_stop fail

		fail \
			"No se pudo recargar systemd."

	fi

	# --------------------------------------------------------
	# ENABLE
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"

		spinner_start \
			"Habilitando inicio automático para puerto ${port}..."

		if systemctl enable \
			"${service_name}.service" >/dev/null 2>&1; then

			spinner_stop ok

		else

			spinner_stop fail

			fail \
				"No se pudo habilitar el servicio del puerto ${port}."

		fi

		systemctl reset-failed \
			"${service_name}.service" >/dev/null 2>&1 ||
			true

	done

	# --------------------------------------------------------
	# COMPROBAR PUERTOS
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		spinner_start \
			"Comprobando disponibilidad del puerto HCR ${port}..."

		if check_port_available "${port}"; then

			spinner_stop ok

		else

			spinner_stop fail

			fail \
				"El puerto HCR ${port} está siendo utilizado por otro servicio."

		fi

	done

	# --------------------------------------------------------
	# REINICIAR HCR
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"

		spinner_start \
			"Iniciando HCR Server en puerto ${port}..."

		if systemctl restart \
			"${service_name}.service" >/dev/null 2>&1; then

			spinner_stop ok

		else

			spinner_stop fail

			printf "\n"

			show_service_diagnostics "${port}"

			printf "\n"

			fail \
				"HCR Server no pudo iniciarse en el puerto ${port}."

		fi

	done

	# --------------------------------------------------------
	# ESTADO
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"

		if systemctl is-active --quiet \
			"${service_name}.service"; then

			success \
				"HCR Server está activo en el puerto ${port}"

		else

			fail \
				"HCR Server no quedó activo en el puerto ${port}."

		fi

	done

	# --------------------------------------------------------
	# WORKING DIRECTORY
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"

		if [ "$(
			systemctl show \
				--property=WorkingDirectory \
				--value \
				"${service_name}.service"
		)" = "${SCRIPT_DIR}" ]; then

			success \
				"Directorio de trabajo verificado para puerto ${port}"

		else

			fail \
				"systemd reportó un directorio de trabajo inesperado para puerto ${port}."

		fi

	done

	# --------------------------------------------------------
	# ESTABILIDAD
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		spinner_start \
			"Realizando comprobación de estabilidad en puerto ${port}..."

		if verify_service_health "${port}" >/dev/null 2>&1; then

			spinner_stop ok

		else

			spinner_stop fail

			printf "\n"

			error_message \
				"La comprobación de estabilidad del puerto ${port} falló."

			show_service_diagnostics "${port}"

			printf "\n"

			fail \
				"La instalación terminó con errores."

		fi

	done

	# --------------------------------------------------------
	# COMPROBACIÓN FINAL
	# --------------------------------------------------------

	for port in "${PORTS[@]}"; do

		if check_hcr_listener "${port}"; then

			success \
				"HCR Server está escuchando correctamente en el puerto ${port}"

		else

			fail \
				"HCR Server está activo, pero no se detectó escucha en el puerto ${port}."

		fi

	done
}

# ------------------------------------------------------------
# RESUMEN
# ------------------------------------------------------------

show_summary() {

	local port
	local service_name

	clear_screen

	printf "\n"

	printf "${BRIGHT_GREEN}${BOLD}"

	printf "╔════════════════════════════════════════════════════════════╗\n"
	printf "║                                                            ║\n"
	printf "║              ✔ INSTALACIÓN COMPLETADA                     ║\n"
	printf "║                                                            ║\n"
	printf "╚════════════════════════════════════════════════════════════╝\n"

	printf "${RESET}\n"

	printf "${BOLD}${WHITE}Configuración:${RESET}\n\n"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Servicios      : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${#PORTS[@]}"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Puertos HCR    : ${BRIGHT_WHITE}"

	for port in "${PORTS[@]}"; do
		printf "%s " "${port}"
	done

	printf "${RESET}\n"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Puerto destino : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${TARGET_PORT}"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Transporte     : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${TRANSPORT}"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Frame descarga : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${MAX_DOWNLOAD_FRAME}"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Poll timeout   : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${DOWNLOAD_POLL_TIMEOUT}"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} File descriptors: ${BRIGHT_WHITE}16384${RESET}\n"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Tasks máximas  : ${BRIGHT_WHITE}1024${RESET}\n"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Memoria máxima : ${BRIGHT_WHITE}512 MB${RESET}\n"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Swap máxima    : ${BRIGHT_WHITE}0 MB${RESET}\n"

	printf \
		"  ${CYAN}${ICON_ARROW}${RESET} Prioridad      : ${BRIGHT_WHITE}Nice -5${RESET}\n"

	printf "\n"

	printf "${BOLD}${WHITE}Instancias:${RESET}\n\n"

	for port in "${PORTS[@]}"; do

		service_name="$(service_name_for_port "${port}")"

		printf \
			"  ${CYAN}${ICON_ARROW}${RESET} Puerto ${BRIGHT_WHITE}%s${RESET} → ${BRIGHT_WHITE}%s${RESET}\n" \
			"${port}" \
			"${service_name}.service"

	done

	printf "\n"

	printf "${BOLD}${WHITE}Capacidades:${RESET}\n\n"

	for port in "${PORTS[@]}"; do

		if requires_privileged_port_capability "${port}"; then

			printf \
				"  ${CYAN}${ICON_ARROW}${RESET} Puerto ${BRIGHT_WHITE}%s${RESET}: ${BRIGHT_WHITE}CAP_NET_BIND_SERVICE${RESET}\n" \
				"${port}"

		else

			printf \
				"  ${CYAN}${ICON_ARROW}${RESET} Puerto ${BRIGHT_WHITE}%s${RESET}: ${BRIGHT_WHITE}No requerida${RESET}\n" \
				"${port}"

		fi

	done

	printf "\n"

	printf "${BOLD}${WHITE}Rutas:${RESET}\n\n"

	printf \
		"  ${DIM}Binario :${RESET} %s\n" \
		"${BINARY_PATH}"

	for port in "${PORTS[@]}"; do

		printf \
			"  ${DIM}Unidad  :${RESET} %s\n" \
			"$(unit_source_path_for_port "${port}")"

	done

	printf "\n"

	printf "${BRIGHT_GREEN}${BOLD}"

	printf \
		"HCR Server está ejecutándose correctamente.${RESET}\n"

	printf \
		"${DIM}Todas las instancias se iniciarán automáticamente con el sistema.${RESET}\n"

	printf "\n"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {

	header

	# --------------------------------------------------------
	# ENTORNO
	# --------------------------------------------------------

	section "Verificando entorno"

	spinner_start \
		"Comprobando permisos y sistema..."

	if require_environment >/dev/null 2>&1; then

		spinner_stop ok

	else

		spinner_stop fail

		fail \
			"El entorno no cumple los requisitos."

	fi

	# --------------------------------------------------------
	# BLOQUEO
	# --------------------------------------------------------

	spinner_start \
		"Adquiriendo bloqueo de instalación..."

	if acquire_install_lock >/dev/null 2>&1; then

		spinner_stop ok

	else

		spinner_stop fail

		fail \
			"No se pudo adquirir el bloqueo de instalación."

	fi

	# --------------------------------------------------------
	# PUERTOS
	# --------------------------------------------------------

	configure_ports

	# --------------------------------------------------------
	# ARCHIVOS
	# --------------------------------------------------------

	validate_bundle

	# --------------------------------------------------------
	# INSTALACIÓN
	# --------------------------------------------------------

	install_service

	# --------------------------------------------------------
	# RESUMEN
	# --------------------------------------------------------

	show_summary
}

# ------------------------------------------------------------
# LIMPIEZA AL SALIR
# ------------------------------------------------------------

trap cleanup EXIT

# ------------------------------------------------------------
# EJECUCIÓN
# ------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
