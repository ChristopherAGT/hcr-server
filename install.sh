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

# Ajustes de rendimiento
MAX_DOWNLOAD_FRAME="16384"
DOWNLOAD_POLL_TIMEOUT="8s"

TRANSPORT="auto"

TEMP_UNIT=""

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
		local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
		local i=0

		while true; do
			printf "\r${BRIGHT_CYAN}%s${RESET} ${WHITE}%s${RESET}" \
				"${frames[$i]}" "${message}"

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
# VALIDACIÓN DE ENTORNO
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
		sleep
	do
		require_command "${command_name}"
	done

	if [ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ]; then
		require_command openssl
	fi

	systemctl show --property=Version --value >/dev/null 2>&1 ||
		fail "El administrador systemd no está disponible."

	if [[ ! "${SCRIPT_DIR}" =~ ^/[-A-Za-z0-9._/@+:]+$ ]]; then
		fail "El directorio del instalador contiene caracteres no compatibles."
	fi
}

# ------------------------------------------------------------
# BLOQUEO DEL INSTALADOR
# ------------------------------------------------------------

acquire_install_lock() {
	exec 9<"${SYSTEMD_DIR}" ||
		fail "No se pudo abrir el directorio de systemd para bloqueo."

	flock -n 9 ||
		fail "Ya existe otra instalación de HCR Server en ejecución."
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

		[ -d "${current}" ] && [ ! -L "${current}" ] ||
			fail "El componente de ruta no es un directorio válido: ${current}"

		[ "$(stat -c '%u' -- "${current}")" = "0" ] ||
			fail "El directorio no pertenece a root: ${current}"

		mode="$(stat -c '%a' -- "${current}")"

		mode_is_writable_by_others "${mode}" &&
			fail "El directorio es escribible por grupo u otros usuarios: ${current}"

		[ "${current}" = "/" ] && break

		current="$(dirname -- "${current}")"
	done
}

validate_root_file() {
	local executable="$1"
	local label="$2"
	local path="$3"
	local mode

	[ -f "${path}" ] && [ ! -L "${path}" ] ||
		fail "${label} debe ser un archivo regular: ${path}"

	[ "$(stat -c '%u' -- "${path}")" = "0" ] ||
		fail "${label} debe pertenecer a root: ${path}"

	mode="$(stat -c '%a' -- "${path}")"

	mode_is_writable_by_others "${mode}" &&
		fail "${label} es escribible por grupo u otros usuarios: ${path}"

	if [ "${executable}" = "true" ] && [ ! -x "${path}" ]; then
		fail "${label} debe tener permisos de ejecución: ${path}"
	fi
}

# ------------------------------------------------------------
# VALIDACIÓN DEL SERVICIO EXISTENTE
# ------------------------------------------------------------

validate_unit_link() {
	if [ -L "${UNIT_LINK_PATH}" ]; then

		[ "$(readlink -- "${UNIT_LINK_PATH}")" = "${UNIT_SOURCE_PATH}" ] ||
			fail "Ya existe un enlace ${SERVICE_NAME}.service diferente."

	elif [ -e "${UNIT_LINK_PATH}" ]; then

		fail "Ya existe una unidad no simbólica en ${UNIT_LINK_PATH}"

	fi
}

loaded_fragment_path() {
	systemctl show \
		--property=FragmentPath \
		--value \
		"${SERVICE_NAME}.service" 2>/dev/null || true
}

validate_loaded_fragment() {
	case "$1" in
		"")
			;;
		"${UNIT_SOURCE_PATH}")
			;;
		"${UNIT_LINK_PATH}")
			;;
		*)
			fail "systemd está utilizando una unidad ${SERVICE_NAME}.service inesperada."
			;;
	esac
}

# ------------------------------------------------------------
# VALIDACIÓN DEL BINARIO
# ------------------------------------------------------------

validate_binary_identity() {
	local path="$1"
	local output

	output="$("${path}" -version 2>/dev/null)" ||
		fail "El binario no admite el parámetro -version."

	[[ "${output}" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+(\ -\ Patch\ [1-9][0-9]*)?$ ]] ||
		fail "El binario devolvió una versión no reconocida."
}

validate_binary() {
	validate_root_file true "Binario HCR" "${BINARY_PATH}"
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
		fail "No se pudo analizar el certificado TLS."

	certificate_public_key="$(
		openssl x509 \
			-in "${TLS_CERT_PATH}" \
			-pubkey \
			-noout 2>/dev/null
	)" ||
		fail "No se pudo obtener la clave pública del certificado."

	private_public_key="$(
		openssl pkey \
			-in "${TLS_KEY_PATH}" \
			-passin pass: \
			-pubout 2>/dev/null
	)" ||
		fail "No se pudo analizar la clave privada TLS."

	[ "${certificate_public_key}" = "${private_public_key}" ] ||
		fail "El certificado TLS y la clave privada no coinciden."
}

# ------------------------------------------------------------
# VALIDACIÓN DEL PAQUETE
# ------------------------------------------------------------

validate_bundle() {
	local key_mode

	section "Comprobando archivos"

	validate_secure_directory
	success "Directorio seguro"

	validate_root_file true "Instalador" "${SCRIPT_PATH}"
	success "Instalador válido"

	validate_binary
	success "Binario HCR válido"

	if [ -e "${UNIT_SOURCE_PATH}" ] || [ -L "${UNIT_SOURCE_PATH}" ]; then
		validate_root_file false \
			"Unidad systemd existente" \
			"${UNIT_SOURCE_PATH}"

		success "Unidad systemd válida"
	fi

	if [ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ]; then

		validate_root_file false \
			"Certificado TLS" \
			"${TLS_CERT_PATH}"

		success "Certificado TLS válido"

		validate_root_file false \
			"Clave privada TLS" \
			"${TLS_KEY_PATH}"

		key_mode="$(stat -c '%a' -- "${TLS_KEY_PATH}")"

		(( (8#${key_mode} & 8#077) == 0 )) ||
			fail "La clave privada TLS debe estar protegida contra otros usuarios."

		validate_tls_pair

		success "Certificado y clave TLS coinciden"
	fi
}

# ------------------------------------------------------------
# GENERACIÓN DE SYSTEMD
# ------------------------------------------------------------

render_unit() {
	local tls_arguments=""

	if [ "${TRANSPORT}" = "tls" ] ||
		[ "${TRANSPORT}" = "auto" ]; then

		tls_arguments=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"
	fi

	TEMP_UNIT="$(
		mktemp "${SCRIPT_DIR}/.${SERVICE_NAME}.XXXXXX.service"
	)"

	chmod 0600 "${TEMP_UNIT}"

	cat >"${TEMP_UNIT}" <<EOF
[Unit]
Description=HCR relay
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

ExecStart=${BINARY_PATH} --listen :${PORT} --target 127.0.0.1:22 --transport ${TRANSPORT}${tls_arguments} --max-download-frame ${MAX_DOWNLOAD_FRAME} --download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}

Restart=on-failure
RestartSec=5s

TimeoutStopSec=15s
KillSignal=SIGTERM

UMask=0077

# ------------------------------------------------------------
# SEGURIDAD
# ------------------------------------------------------------

NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=

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

SyslogIdentifier=hcr-server

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

	trap - EXIT
	set +e

	[ -n "${TEMP_UNIT}" ] &&
		rm -f -- "${TEMP_UNIT}"

	exit "${exit_code}"
}

# ------------------------------------------------------------
# VERIFICACIÓN DEL SERVICIO
# ------------------------------------------------------------

verify_service_health() {
	local initial_pid

	initial_pid="$(
		systemctl show \
			--property=MainPID \
			--value \
			"${SERVICE_NAME}.service"
	)"

	[[ "${initial_pid}" =~ ^[1-9][0-9]*$ ]] ||
		fail "El servicio no reportó un proceso activo."

	sleep 3

	systemctl is-active --quiet "${SERVICE_NAME}.service" ||
		fail "El servicio no permaneció activo."

	[ "$(
		systemctl show \
			--property=MainPID \
			--value \
			"${SERVICE_NAME}.service"
	)" = "${initial_pid}" ] ||
		fail "El servicio se reinició durante la comprobación."
}

# ------------------------------------------------------------
# INSTALACIÓN
# ------------------------------------------------------------

install_service() {

	section "Preparando instalación"

	validate_unit_link
	validate_loaded_fragment "$(loaded_fragment_path)"

	success "No existen conflictos con systemd"

	spinner_start "Generando configuración de systemd..."

	if render_unit >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail
		fail "No se pudo generar la unidad systemd."
	fi

	spinner_start "Instalando unidad HCR Server..."

	if mv -f -- "${TEMP_UNIT}" "${UNIT_SOURCE_PATH}"; then
		TEMP_UNIT=""
		spinner_stop ok
	else
		spinner_stop fail
		fail "No se pudo instalar la unidad systemd."
	fi

	if [ -L "${UNIT_LINK_PATH}" ]; then
		success "Enlace systemd existente y verificado"
	else
		spinner_start "Creando enlace de systemd..."

		if ln -s -- "${UNIT_SOURCE_PATH}" "${UNIT_LINK_PATH}"; then
			spinner_stop ok
		else
			spinner_stop fail
			fail "No se pudo crear el enlace systemd."
		fi
	fi

	section "Configurando servicio"

	spinner_start "Recargando configuración de systemd..."

	if systemctl daemon-reload >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail
		fail "No se pudo recargar systemd."
	fi

	spinner_start "Habilitando inicio automático..."

	if systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail
		fail "No se pudo habilitar el servicio."
	fi

	systemctl reset-failed \
		"${SERVICE_NAME}.service" >/dev/null 2>&1 || true

	spinner_start "Iniciando HCR Server..."

	if systemctl restart "${SERVICE_NAME}.service" >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail

		printf "\n"
		systemctl status \
			--no-pager \
			--full \
			"${SERVICE_NAME}.service" || true

		fail "HCR Server no pudo iniciarse."
	fi

	if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
		success "HCR Server está activo"
	else
		fail "HCR Server no quedó activo."
	fi

	if [ "$(
		systemctl show \
			--property=WorkingDirectory \
			--value \
			"${SERVICE_NAME}.service"
	)" = "${SCRIPT_DIR}" ]; then

		success "Directorio de trabajo verificado"

	else
		fail "systemd reportó un directorio de trabajo inesperado."
	fi

	spinner_start "Realizando comprobación de estabilidad..."

	if verify_service_health >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail
		fail "La comprobación de estabilidad falló."
	fi
}

# ------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------

show_summary() {
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

	printf "  ${CYAN}${ICON_ARROW}${RESET} Servicio       : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${SERVICE_NAME}"

	printf "  ${CYAN}${ICON_ARROW}${RESET} Puerto         : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${PORT}"

	printf "  ${CYAN}${ICON_ARROW}${RESET} Transporte     : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${TRANSPORT}"

	printf "  ${CYAN}${ICON_ARROW}${RESET} Frame descarga : ${BRIGHT_WHITE}%s${RESET}\n" \
		"${MAX_DOWNLOAD_FRAME}"

	printf "  ${CYAN}${ICON_ARROW}${RESET} File descriptors: ${BRIGHT_WHITE}16384${RESET}\n"

	printf "  ${CYAN}${ICON_ARROW}${RESET} Tasks máximas  : ${BRIGHT_WHITE}1024${RESET}\n"

	printf "  ${CYAN}${ICON_ARROW}${RESET} Memoria máxima : ${BRIGHT_WHITE}512 MB${RESET}\n"

	printf "\n"

	printf "${BOLD}${WHITE}Rutas:${RESET}\n\n"

	printf "  ${DIM}Binario :${RESET} %s\n" "${BINARY_PATH}"
	printf "  ${DIM}Unidad  :${RESET} %s\n" "${UNIT_SOURCE_PATH}"

	printf "\n"

	printf "${BRIGHT_GREEN}${BOLD}"
	printf "HCR Server está ejecutándose correctamente.${RESET}\n"

	printf "${DIM}El servicio se iniciará automáticamente con el sistema.${RESET}\n"

	printf "\n"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {

	header

	section "Verificando entorno"

	spinner_start "Comprobando permisos y sistema..."

	if require_environment >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail
		fail "El entorno no cumple los requisitos."
	fi

	spinner_start "Adquiriendo bloqueo de instalación..."

	if acquire_install_lock >/dev/null 2>&1; then
		spinner_stop ok
	else
		spinner_stop fail
		fail "No se pudo adquirir el bloqueo de instalación."
	fi

	validate_bundle

	install_service

	show_summary
}

trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
