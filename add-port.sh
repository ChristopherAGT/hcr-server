#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#                  HCR SERVER — NUEVO PUERTO
# ============================================================
# Agrega una nueva instancia de HCR Server sobre una instalación
# existente.
#
# NO reinstala el binario.
# NO modifica las instancias existentes.
# NO elimina certificados.
# NO elimina archivos existentes.
#
# Detecta automáticamente la instalación HCR existente.
#
# Estructura esperada:
#
#   /root/.hcr-panel/
#   ├── hcr-server
#   ├── fullchain.pem
#   ├── privkey.pem
#   ├── hcr-server-80.service
#   └── hcr-server-443.service
#
# Y crea:
#
#   /root/.hcr-panel/hcr-server-<PUERTO>.service
#
# con enlace:
#
#   /etc/systemd/system/hcr-server-<PUERTO>.service
#
# Parámetros HCR:
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
TRANSPORT="auto"

TARGET_PORT="22"

# ============================================================
# DETECCIÓN DE INSTALACIÓN HCR
# ============================================================

HCR_DIR=""
BINARY_PATH=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""

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

run_spinner() {

	local message="$1"

	shift

	spinner_start "${message}"

	if "$@" >/dev/null 2>&1; then

		spinner_stop

		success "Completado"

		return 0

	else

		spinner_stop

		error_message "Falló"

		return 1

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
		"${BRIGHT_CYAN}${BOLD}║                 H C R   S E R V E R 2020                       ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                    N U E V O   P U E R T O                ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

	printf '\n'

	printf '%b\n' \
		"${DIM} Administrador de instancias HCR Server para Linux + systemd${RESET}"

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
# PUERTOS PRIVILEGIADOS
# ============================================================

requires_privileged_port_capability() {

	local port="$1"

	(( port >= 1 && port <= 1023 ))
}

# ============================================================
# DISPONIBILIDAD DEL PUERTO
# ============================================================

check_port_available() {

	local port="$1"
	local listeners=""

	listeners="$(
		ss -H -lntp "sport = :${port}" 2>/dev/null || true
	)"

	[[ -z "${listeners}" ]]
}

# ============================================================
# COMPROBAR SI HCR YA ESCUCHA
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
# DETECTAR INSTALACIÓN HCR
# ============================================================

detect_hcr_installation() {

	local candidate=""
	local fragment=""
	local exec_start=""

	for candidate in \
		"${SERVICE_NAME}-80.service" \
		"${SERVICE_NAME}-443.service"
	do

		fragment="$(
			systemctl show \
				--property=FragmentPath \
				--value \
				"${candidate}" \
				2>/dev/null ||
				true
		)"

		if [[ -n "${fragment}" &&
			  -f "${fragment}" ]]; then

			HCR_DIR="$(dirname -- "${fragment}")"

			break

		fi

		exec_start="$(
			systemctl show \
				--property=ExecStart \
				--value \
				"${candidate}" \
				2>/dev/null ||
				true
		)"

		if [[ "${exec_start}" == *"${SERVICE_NAME}"* ]]; then

			if [[ "${exec_start}" =~ (${SERVICE_NAME//./\\.}) ]]; then
				:
			fi
		fi

	done

	if [[ -z "${HCR_DIR}" ]]; then

		if [[ -d "/root/.hcr-panel" ]]; then

			HCR_DIR="/root/.hcr-panel"

		elif [[ -d "/opt/.hcr-panel" ]]; then

			HCR_DIR="/opt/.hcr-panel"

		else

			fail \
				"No se pudo detectar el directorio de instalación de HCR Server."
		fi

	fi

	BINARY_PATH="${HCR_DIR}/hcr-server"
	TLS_CERT_PATH="${HCR_DIR}/fullchain.pem"
	TLS_KEY_PATH="${HCR_DIR}/privkey.pem"
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
		ln \
		mv \
		rm \
		mktemp \
		sleep \
		ss \
		awk \
		grep \
		tail \
		head \
		dirname \
		basename \
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
			"No existe el directorio HCR detectado:

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

acquire_add_port_lock() {

	local lock_file="${SYSTEMD_DIR}/.${SERVICE_NAME}.add-port.lock"

	exec 9>"${lock_file}" ||
		fail \
			"No se pudo crear el bloqueo de HCR Server."

	if ! flock -n 9; then

		fail \
			"Ya existe otra operación de HCR Server en curso."

	fi

	LOCK_FD_OPEN="true"
}

release_add_port_lock() {

	if [[ "${LOCK_FD_OPEN}" == "true" ]]; then

		flock -u 9 >/dev/null 2>&1 || true

		exec 9>&-

		LOCK_FD_OPEN="false"

	fi
}

# ============================================================
# VALIDACIÓN DE SEGURIDAD DEL DIRECTORIO
# ============================================================

mode_is_writable_by_others() {

	local mode="$1"

	(( (8#${mode} & 8#022) != 0 ))
}

validate_secure_directory() {

	local current="${HCR_DIR}"
	local mode

	while true; do

		if [[ ! -d "${current}" || -L "${current}" ]]; then

			fail \
				"El componente de ruta no es un directorio válido: ${current}"

		fi

		if [[ "$(stat -c '%u' -- "${current}")" != "0" ]]; then

			fail \
				"El directorio no pertenece a root: ${current}"

		fi

		mode="$(stat -c '%a' -- "${current}")"

		if mode_is_writable_by_others "${mode}"; then

			fail \
				"El directorio es escribible por grupo u otros usuarios: ${current}"

		fi

		if [[ "${current}" == "/" ]]; then
			break
		fi

		current="$(dirname -- "${current}")"

	done
}

# ============================================================
# VALIDAR ARCHIVO ROOT
# ============================================================

validate_root_file() {

	local executable="$1"
	local label="$2"
	local path="$3"
	local mode

	if [[ ! -f "${path}" || -L "${path}" ]]; then

		fail \
			"${label} no es un archivo regular: ${path}"

	fi

	if [[ "$(stat -c '%u' -- "${path}")" != "0" ]]; then

		fail \
			"${label} no pertenece a root: ${path}"

	fi

	mode="$(stat -c '%a' -- "${path}")"

	if mode_is_writable_by_others "${mode}"; then

		fail \
			"${label} es escribible por grupo u otros usuarios: ${path}"

	fi

	if [[ "${executable}" == "true" && ! -x "${path}" ]]; then

		fail \
			"${label} debe tener permisos de ejecución: ${path}"

	fi
}

# ============================================================
# VALIDAR BINARIO
# ============================================================

validate_binary_identity() {

	local output=""

	output="$(
		"${BINARY_PATH}" -version 2>/dev/null
	)" ||

		fail \
			"El binario HCR no admite el parámetro -version."

	if [[ ! "${output}" =~ ^hcr-server[[:space:]]version[[:space:]][0-9]+\.[0-9]+\.[0-9]+([[:space:]]-[[:space:]]Patch[[:space:]][1-9][0-9]*)?$ ]]; then

		fail \
			"El binario HCR devolvió una versión no reconocida:

${output}"

	fi
}

validate_binary() {

	validate_root_file \
		true \
		"Binario HCR" \
		"${BINARY_PATH}"

	validate_binary_identity
}

# ============================================================
# VALIDAR TLS
# ============================================================

validate_tls_pair() {

	local certificate_public_key=""
	local private_public_key=""

	if ! command -v openssl >/dev/null 2>&1; then

		fail \
			"openssl es necesario para utilizar transporte TLS/auto."

	fi

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
			"No se pudo obtener la clave pública del certificado TLS."

	private_public_key="$(
		openssl pkey \
			-in "${TLS_KEY_PATH}" \
			-passin pass: \
			-pubout 2>/dev/null
	)" ||

		fail \
			"No se pudo analizar la clave privada TLS."

	if [[ "${certificate_public_key}" != "${private_public_key}" ]]; then

		fail \
			"El certificado TLS y la clave privada no coinciden."

	fi
}

validate_tls() {

	local key_mode

	if [[ "${TRANSPORT}" != "tls" &&
		  "${TRANSPORT}" != "auto" ]]; then

		return 0

	fi

	validate_root_file \
		false \
		"Certificado TLS" \
		"${TLS_CERT_PATH}"

	validate_root_file \
		false \
		"Clave privada TLS" \
		"${TLS_KEY_PATH}"

	key_mode="$(stat -c '%a' -- "${TLS_KEY_PATH}")"

	if (( (8#${key_mode} & 8#077) != 0 )); then

		fail \
			"La clave privada TLS debe estar protegida contra otros usuarios."

	fi

	validate_tls_pair
}

# ============================================================
# VALIDAR INSTALACIÓN EXISTENTE
# ============================================================

validate_existing_installation() {

	section "Comprobando instalación existente"

	validate_secure_directory

	success \
		"Directorio de instalación seguro."

	detail \
		"Instalación detectada: ${HCR_DIR}"

	validate_binary

	success \
		"Binario HCR Server válido."

	validate_tls

	success \
		"Certificados TLS válidos."

	detail \
		"Binario: ${BINARY_PATH}"

	detail \
		"Certificado: ${TLS_CERT_PATH}"

	detail \
		"Clave privada: ${TLS_KEY_PATH}"

	detail \
		"Transporte: ${TRANSPORT}"

	detail \
		"Frame de descarga: ${MAX_DOWNLOAD_FRAME}"

	detail \
		"Poll timeout: ${DOWNLOAD_POLL_TIMEOUT}"

	printf '\n'
}

# ============================================================
# CONFIGURAR PUERTO
# ============================================================

configure_port() {

	local input=""

	section "Configuración del nuevo puerto"

	while true; do

		printf \
			"${WHITE}Nuevo puerto HCR${RESET} ${DIM}[ejemplo: 8880]${RESET}: "

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
		"Nuevo puerto seleccionado: ${PORT}"

	if requires_privileged_port_capability "${PORT}"; then

		info \
			"Puerto privilegiado detectado: ${PORT}"

		detail \
			"Se utilizará CAP_NET_BIND_SERVICE exclusivamente para esta instancia."

	else

		detail \
			"Puerto no privilegiado: ${PORT}"

		detail \
			"No se requiere CAP_NET_BIND_SERVICE."

	fi
}

# ============================================================
# CONFIGURAR PUERTO DESTINO
# ============================================================

configure_target_port() {

	local input=""

	while true; do

		printf \
			"${WHITE}Puerto destino${RESET} ${DIM}[${TARGET_PORT}]${RESET}: "

		read -r input

		if [[ -z "${input}" ]]; then

			break

		fi

		if validate_port "${input}"; then

			TARGET_PORT="${input}"

			break

		fi

		error_message \
			"Puerto destino no válido. Debe estar entre 1 y 65535."

	done

	success \
		"Puerto destino configurado: ${TARGET_PORT}"
}

# ============================================================
# VALIDAR CONFLICTOS
# ============================================================

validate_conflicts() {

	local service_name="${SERVICE_NAME_SELECTED}"
	local loaded_fragment=""

	section "Comprobando conflictos"

	if ! check_port_available "${PORT}"; then

		error_message \
			"El puerto ${PORT} ya está siendo utilizado."

		printf '\n'

		ss -lntp "sport = :${PORT}" 2>/dev/null ||
			true

		printf '\n'

		fail \
			"No se puede crear HCR Server en un puerto ocupado."

	fi

	success \
		"El puerto ${PORT} está disponible."

	if [[ -e "${UNIT_SOURCE}" || -L "${UNIT_SOURCE}" ]]; then

		fail \
			"Ya existe una unidad HCR en:

${UNIT_SOURCE}"

	fi

	success \
		"No existe una unidad fuente para el puerto ${PORT}."

	if [[ -e "${UNIT_LINK}" || -L "${UNIT_LINK}" ]]; then

		fail \
			"Ya existe una unidad/enlace systemd para:

${UNIT_LINK}"

	fi

	success \
		"No existe un enlace systemd para el puerto ${PORT}."

	loaded_fragment="$(
		systemctl show \
			--property=FragmentPath \
			--value \
			"${service_name}.service" \
			2>/dev/null ||
			true
	)"

	if [[ -n "${loaded_fragment}" ]]; then

		fail \
			"systemd ya conoce una unidad llamada:

${service_name}.service

Fragmento:

${loaded_fragment}"

	fi

	success \
		"systemd no tiene una instancia previa del puerto ${PORT}."
}

# ============================================================
# RENDERIZAR UNIDAD SYSTEMD
# ============================================================

render_unit() {

	local tls_arguments=""
	local capability_arguments=""

	if [[ "${TRANSPORT}" == "tls" ||
		  "${TRANSPORT}" == "auto" ]]; then

		tls_arguments=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"

	fi

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

	TEMP_UNIT="$(
		mktemp \
			"${HCR_DIR}/.${SERVICE_NAME_SELECTED}.XXXXXX.service"
	)"

	chmod 0600 "${TEMP_UNIT}"

	cat >"${TEMP_UNIT}" <<EOF
[Unit]
Description=HCR relay on port ${PORT}

Wants=network-online.target
After=network-online.target ssh.service sshd.service

StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec

User=root
Group=root

WorkingDirectory=${HCR_DIR}

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

ReadOnlyPaths=${HCR_DIR}

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

SyslogIdentifier=${SERVICE_NAME_SELECTED}

[Install]
WantedBy=multi-user.target
EOF

	chmod 0644 "${TEMP_UNIT}"

	systemd-analyze verify "${TEMP_UNIT}"
}

# ============================================================
# INSTALAR UNIDAD
# ============================================================

install_unit() {

	section "Creando instancia HCR Server"

	spinner_start \
		"Generando configuración para puerto ${PORT}..."

	if render_unit >/dev/null 2>&1; then

		spinner_stop

		success \
			"Configuración systemd generada."

	else

		spinner_stop

		fail \
			"La configuración systemd no es válida."

	fi

	spinner_start \
		"Instalando unidad HCR Server..."

	if mv -f \
		-- "${TEMP_UNIT}" \
		"${UNIT_SOURCE}"; then

		TEMP_UNIT=""

		spinner_stop

		success \
			"Unidad instalada: ${UNIT_SOURCE}"

	else

		spinner_stop

		fail \
			"No se pudo instalar la unidad HCR Server."

	fi

	spinner_start \
		"Creando enlace de systemd..."

	if ln -s \
		-- "${UNIT_SOURCE}" \
		"${UNIT_LINK}"; then

		spinner_stop

		success \
			"Enlace creado: ${UNIT_LINK}"

	else

		spinner_stop

		rm -f \
			-- "${UNIT_SOURCE}" >/dev/null 2>&1 ||
			true

		fail \
			"No se pudo crear el enlace systemd."

	fi
}

# ============================================================
# CONFIGURAR SYSTEMD
# ============================================================

configure_systemd() {

	section "Configurando servicio"

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

	spinner_start \
		"Habilitando inicio automático..."

	if systemctl enable \
		"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1; then

		spinner_stop

		success \
			"Inicio automático habilitado."

	else

		spinner_stop

		fail \
			"No se pudo habilitar el servicio."

	fi

	systemctl reset-failed \
		"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1 ||
		true
}

# ============================================================
# INICIAR SERVICIO
# ============================================================

start_service() {

	section "Iniciando nueva instancia"

	spinner_start \
		"Iniciando HCR Server en puerto ${PORT}..."

	if systemctl start \
		"${SERVICE_NAME_SELECTED}.service" >/dev/null 2>&1; then

		spinner_stop

		success \
			"HCR Server iniciado en puerto ${PORT}."

	else

		spinner_stop

		printf '\n'

		error_message \
			"No se pudo iniciar HCR Server."

		show_service_diagnostics

		printf '\n'

		fail \
			"La nueva instancia no pudo iniciarse."

	fi
}

# ============================================================
# DIAGNÓSTICO
# ============================================================

show_service_diagnostics() {

	printf '\n'

	detail \
		"Estado del servicio ${SERVICE_NAME_SELECTED}:"

	systemctl status \
		--no-pager \
		--full \
		"${SERVICE_NAME_SELECTED}.service" ||
		true

	printf '\n'

	detail \
		"Últimos registros de HCR Server:"

	journalctl \
		-u "${SERVICE_NAME_SELECTED}.service" \
		-n 30 \
		--no-pager \
		--output=short-iso ||
		true
}

# ============================================================
# OBTENER PID PRINCIPAL
# ============================================================

get_main_pid() {

	systemctl show \
		--property=MainPID \
		--value \
		"${SERVICE_NAME_SELECTED}.service" \
		2>/dev/null ||
		true
}

# ============================================================
# VERIFICAR SALUD DEL SERVICIO
# ============================================================
#
# IMPORTANTE:
#
# Esta función NO inicia ni detiene el spinner.
#
# El spinner es controlado exclusivamente por main().
# Esto evita que un segundo spinner sobrescriba SPINNER_PID
# y deje el spinner principal ejecutándose indefinidamente.
#
# ============================================================

verify_service_health() {

	local initial_pid=""
	local final_pid=""

	section "Verificando estabilidad"

	# --------------------------------------------------------
	# PID inicial
	# --------------------------------------------------------

	initial_pid="$(get_main_pid)"

	if [[ ! "${initial_pid}" =~ ^[1-9][0-9]*$ ]]; then

		error_message \
			"No se obtuvo un PID principal válido."

		return 1

	fi

	detail \
		"PID inicial: ${initial_pid}"

	# --------------------------------------------------------
	# Estado activo
	# --------------------------------------------------------

	if ! systemctl is-active --quiet \
		"${SERVICE_NAME_SELECTED}.service"; then

		error_message \
			"El servicio no está activo."

		return 1

	fi

	# --------------------------------------------------------
	# Espera de estabilidad
	#
	# El spinner ya está activo desde main().
	# NO iniciar otro spinner aquí.
	# --------------------------------------------------------

	sleep 3

	# --------------------------------------------------------
	# Estado después de espera
	# --------------------------------------------------------

	if ! systemctl is-active --quiet \
		"${SERVICE_NAME_SELECTED}.service"; then

		error_message \
			"El servicio dejó de estar activo."

		return 1

	fi

	# --------------------------------------------------------
	# PID final
	# --------------------------------------------------------

	final_pid="$(get_main_pid)"

	if [[ ! "${final_pid}" =~ ^[1-9][0-9]*$ ]]; then

		error_message \
			"No se obtuvo un PID final válido."

		return 1

	fi

	detail \
		"PID final: ${final_pid}"

	# --------------------------------------------------------
	# PID debe mantenerse
	# --------------------------------------------------------

	if [[ "${final_pid}" != "${initial_pid}" ]]; then

		error_message \
			"El PID cambió. La instancia pudo reiniciarse."

		return 1

	fi

	success \
		"El proceso se mantuvo estable."

	# --------------------------------------------------------
	# Listener
	# --------------------------------------------------------

	if ! check_hcr_listener "${PORT}"; then

		error_message \
			"No se detectó HCR Server escuchando en el puerto ${PORT}."

		return 1

	fi

	success \
		"HCR Server está escuchando en el puerto ${PORT}."

	return 0
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================

verify_installation() {

	local exec_start=""

	section "Verificación final"

	if systemctl is-active --quiet \
		"${SERVICE_NAME_SELECTED}.service"; then

		success \
			"Servicio activo."

	else

		error_message \
			"El servicio no está activo."

		return 1

	fi

	if systemctl is-enabled --quiet \
		"${SERVICE_NAME_SELECTED}.service"; then

		success \
			"Inicio automático habilitado."

	else

		error_message \
			"El servicio no está habilitado para iniciar con el sistema."

		return 1

	fi

	if [[ -f "${UNIT_SOURCE}" &&
		  ! -L "${UNIT_SOURCE}" ]]; then

		success \
			"Unidad fuente verificada."

	else

		error_message \
			"No existe correctamente la unidad fuente."

		return 1

	fi

	if [[ -L "${UNIT_LINK}" ]]; then

		if [[ "$(readlink -- "${UNIT_LINK}")" == "${UNIT_SOURCE}" ]]; then

			success \
				"Enlace systemd verificado."

		else

			error_message \
				"El enlace systemd apunta a una ruta incorrecta."

			return 1

		fi

	else

		error_message \
			"No existe el enlace systemd."

		return 1

	fi

	if [[ "$(
		systemctl show \
			--property=WorkingDirectory \
			--value \
			"${SERVICE_NAME_SELECTED}.service"
	)" == "${HCR_DIR}" ]]; then

		success \
			"Directorio de trabajo verificado."

	else

		error_message \
			"systemd reportó un directorio de trabajo inesperado."

		return 1

	fi

	exec_start="$(
		systemctl show \
			--property=ExecStart \
			--value \
			"${SERVICE_NAME_SELECTED}.service" \
			2>/dev/null ||
			true
	)"

	if [[ "${exec_start}" == *"${BINARY_PATH}"* &&
		  "${exec_start}" == *"--listen :${PORT}"* &&
		  "${exec_start}" == *"--target 127.0.0.1:${TARGET_PORT}"* &&
		  "${exec_start}" == *"--transport ${TRANSPORT}"* &&
		  "${exec_start}" == *"--max-download-frame ${MAX_DOWNLOAD_FRAME}"* &&
		  "${exec_start}" == *"--download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}"* ]]; then

		success \
			"ExecStart verificado."

	else

		error_message \
			"ExecStart no coincide con la configuración esperada."

		detail \
			"${exec_start}"

		return 1

	fi

	if check_hcr_listener "${PORT}"; then

		success \
			"Puerto ${PORT} está escuchando correctamente."

	else

		error_message \
			"No se detectó escucha en el puerto ${PORT}."

		return 1

	fi

	return 0
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
		"${BRIGHT_GREEN}${BOLD}║              ✔ PUERTO AGREGADO CORRECTAMENTE              ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}║                                                            ║${RESET}"

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Configuración de la nueva instancia:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Directorio HCR   : ${BRIGHT_WHITE}${HCR_DIR}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Puerto HCR       : ${BRIGHT_WHITE}${PORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Puerto destino   : ${BRIGHT_WHITE}${TARGET_PORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Transporte       : ${BRIGHT_WHITE}${TRANSPORT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Frame descarga   : ${BRIGHT_WHITE}${MAX_DOWNLOAD_FRAME}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Poll timeout     : ${BRIGHT_WHITE}${DOWNLOAD_POLL_TIMEOUT}${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} File descriptors : ${BRIGHT_WHITE}16384${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Tasks máximas    : ${BRIGHT_WHITE}1024${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Memoria máxima   : ${BRIGHT_WHITE}512 MB${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Swap máxima      : ${BRIGHT_WHITE}0 MB${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Prioridad        : ${BRIGHT_WHITE}Nice -5${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Instancia:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Servicio : ${BRIGHT_WHITE}${SERVICE_NAME_SELECTED}.service${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Estado   : ${BRIGHT_GREEN}Activo${RESET}"

	printf '%b\n' \
		"  ${CYAN}${ICON_ARROW}${RESET} Inicio   : ${BRIGHT_GREEN}Automático${RESET}"

	printf '\n'

	printf '%b\n' \
		"${BOLD}${WHITE}Rutas:${RESET}"

	printf '\n'

	printf '%b\n' \
		"  ${DIM}Binario:${RESET} ${BINARY_PATH}"

	printf '%b\n' \
		"  ${DIM}Unidad :${RESET} ${UNIT_SOURCE}"

	printf '%b\n' \
		"  ${DIM}Enlace :${RESET} ${UNIT_LINK}"

	printf '\n'

	if requires_privileged_port_capability "${PORT}"; then

		printf '%b\n' \
			"  ${CYAN}${ICON_ARROW}${RESET} Capacidad: ${BRIGHT_WHITE}CAP_NET_BIND_SERVICE${RESET}"

	else

		printf '%b\n' \
			"  ${CYAN}${ICON_ARROW}${RESET} Capacidad: ${BRIGHT_WHITE}No requerida${RESET}"

	fi

	printf '\n'

	printf '%b\n' \
		"${BRIGHT_GREEN}${BOLD}HCR Server está ejecutándose correctamente en el nuevo puerto.${RESET}"

	printf '%b\n' \
		"${DIM}Las demás instancias HCR Server no fueron modificadas.${RESET}"

	printf '%b\n' \
		"${DIM}La nueva instancia se iniciará automáticamente con el sistema.${RESET}"

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

		release_add_port_lock

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

	if acquire_add_port_lock >/dev/null 2>&1; then

		spinner_stop

		success \
			"Bloqueo adquirido."

	else

		spinner_stop

		fail \
			"No se pudo adquirir el bloqueo."

	fi

	# --------------------------------------------------------
	# INSTALACIÓN EXISTENTE
	# --------------------------------------------------------

	validate_existing_installation

	# --------------------------------------------------------
	# PUERTO
	# --------------------------------------------------------

	configure_port

	# --------------------------------------------------------
	# DESTINO
	# --------------------------------------------------------

	configure_target_port

	# --------------------------------------------------------
	# CONFLICTOS
	# --------------------------------------------------------

	validate_conflicts

	# --------------------------------------------------------
	# RESUMEN PREVIO
	# --------------------------------------------------------

	section "Resumen de instalación"

	detail \
		"Nuevo servicio: ${SERVICE_NAME_SELECTED}.service"

	detail \
		"Puerto HCR: ${PORT}"

	detail \
		"Puerto destino: 127.0.0.1:${TARGET_PORT}"

	detail \
		"Transporte: ${TRANSPORT}"

	detail \
		"Frame descarga: ${MAX_DOWNLOAD_FRAME}"

	detail \
		"Poll timeout: ${DOWNLOAD_POLL_TIMEOUT}"

	detail \
		"Directorio HCR: ${HCR_DIR}"

	detail \
		"Unidad fuente: ${UNIT_SOURCE}"

	detail \
		"Enlace systemd: ${UNIT_LINK}"

	printf '\n'

	warning \
		"Solo se agregará la nueva instancia ${SERVICE_NAME_SELECTED}.service."

	warning \
		"Las instancias HCR existentes no serán modificadas."

	printf '\n'

	read -r -p \
		"¿Deseas continuar? [s/N]: " answer

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
	# INSTALAR
	# --------------------------------------------------------

	install_unit

	# --------------------------------------------------------
	# SYSTEMD
	# --------------------------------------------------------

	configure_systemd

	# --------------------------------------------------------
	# INICIAR
	# --------------------------------------------------------

	start_service

	# --------------------------------------------------------
	# SALUD
	# --------------------------------------------------------
	#
	# IMPORTANTE:
	# Solo existe UN spinner para toda esta comprobación.
	# verify_service_health() no crea otro spinner.
	# --------------------------------------------------------

	spinner_start \
		"Realizando comprobación de estabilidad..."

	if verify_service_health >/dev/null 2>&1; then

		spinner_stop

		success \
			"Comprobación de estabilidad superada."

	else

		spinner_stop

		printf '\n'

		error_message \
			"La comprobación de estabilidad falló."

		show_service_diagnostics

		printf '\n'

		fail \
			"La nueva instancia no superó la comprobación de estabilidad."

	fi

	# --------------------------------------------------------
	# VERIFICACIÓN FINAL
	# --------------------------------------------------------

	if ! verify_installation; then

		printf '\n'

		error_message \
			"La verificación final encontró problemas."

		show_service_diagnostics

		fail \
			"La nueva instancia no quedó instalada correctamente."

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
