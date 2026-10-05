#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#          HCR SERVER — SERVICE CONTROL ENGINE
# ============================================================
#
# SCRIPT AUXILIAR
#
# Este script NO tiene menú.
#
# Está diseñado para ser llamado por el panel principal.
#
# USO:
#
#   hcr-service-control.sh start
#   hcr-service-control.sh stop
#
# FUNCIONES:
#
#   start
#       Inicia TODAS las instancias HCR creadas por el instalador.
#
#   stop
#       Detiene TODAS las instancias HCR creadas por el instalador.
#
# NO:
#
#   - Modifica archivos .service
#   - Habilita servicios
#   - Deshabilita servicios
#   - Desinstala HCR
#   - Modifica puertos
#   - Modifica configuración
#   - Modifica el binario
#
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"

export PATH LC_ALL LANG

# ============================================================
# CONFIGURACIÓN
# ============================================================

SERVICE_PREFIX="hcr-server-"
SYSTEMD_DIR="/etc/systemd/system"

# ============================================================
# FUNCIONES
# ============================================================

error_message() {

	printf \
		"✖ %s\n" \
		"$*" >&2
}

success() {

	printf \
		"✔ %s\n" \
		"$*"
}

# ============================================================
# VALIDACIÓN
# ============================================================

require_environment() {

	[ "$(id -u)" -eq 0 ] ||
		{
			error_message \
				"Este script debe ejecutarse como root."

			exit 1
		}

	command -v systemctl >/dev/null 2>&1 ||
		{
			error_message \
				"No se encontró systemctl."

			exit 1
		}

	[ -d "${SYSTEMD_DIR}" ] ||
		{
			error_message \
				"No existe el directorio de systemd."

			exit 1
		}
}

# ============================================================
# DESCUBRIR INSTANCIAS HCR
# ============================================================

discover_services() {

	find "${SYSTEMD_DIR}" \
		-maxdepth 1 \
		-type f \
		-name "${SERVICE_PREFIX}*.service" \
		-printf '%f\n' \
		2>/dev/null |
		grep -E '^hcr-server-[0-9]+\.service$' |
		sort -V
}

# ============================================================
# INICIAR TODAS
# ============================================================

start_all() {

	local services
	local service
	local failed=0

	services="$(discover_services)"

	if [ -z "${services}" ]; then

		error_message \
			"No se encontraron instancias HCR Server."

		return 1
	fi

	while IFS= read -r service; do

		[ -n "${service}" ] || continue

		if systemctl start "${service}" >/dev/null 2>&1; then

			if systemctl is-active --quiet "${service}"; then

				success \
					"${service} iniciado correctamente."

			else

				error_message \
					"${service} no quedó activo."

				failed=$((failed + 1))

			fi

		else

			error_message \
				"No se pudo iniciar ${service}."

			failed=$((failed + 1))

		fi

	done <<< "${services}"

	if [ "${failed}" -gt 0 ]; then

		return 1
	fi

	return 0
}

# ============================================================
# DETENER TODAS
# ============================================================

stop_all() {

	local services
	local service
	local failed=0

	services="$(discover_services)"

	if [ -z "${services}" ]; then

		error_message \
			"No se encontraron instancias HCR Server."

		return 1
	fi

	while IFS= read -r service; do

		[ -n "${service}" ] || continue

		if systemctl stop "${service}" >/dev/null 2>&1; then

			if ! systemctl is-active --quiet "${service}"; then

				success \
					"${service} detenido correctamente."

			else

				error_message \
					"${service} continúa activo."

				failed=$((failed + 1))

			fi

		else

			error_message \
				"No se pudo detener ${service}."

			failed=$((failed + 1))

		fi

	done <<< "${services}"

	if [ "${failed}" -gt 0 ]; then

		return 1
	fi

	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {

	require_environment

	[ "$#" -eq 1 ] ||
		{
			error_message \
				"Uso: $0 {start|stop}"

			exit 1
		}

	case "$1" in

		start)

			start_all

			;;

		stop)

			stop_all

			;;

		*)

			error_message \
				"Acción no válida: $1"

			error_message \
				"Uso: $0 {start|stop}"

			exit 1

			;;

	esac
}

# ============================================================
# EJECUCIÓN
# ============================================================

main "$@"
