#!/bin/sh

set -e

# Load environment variables
. /mnt/data/udm-le/udm-le.env

# Setup variables for later
DOCKER_VOLUMES="-v ${UDM_LE_PATH}/lego/:/var/lib/lego/"
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} --key-type rsa2048"

deploy_cert() {
	if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${CERT_NAME}".crt -mmin -5)" ]; then
		echo 'New certificate was generated, time to deploy it'
		# Controller certificate
		cp -f ${UDM_LE_PATH}/lego/certificates/${CERT_NAME}.crt ${UBIOS_CERT_PATH}/unifi-core.crt
		cp -f ${UDM_LE_PATH}/lego/certificates/${CERT_NAME}.key ${UBIOS_CERT_PATH}/unifi-core.key
		chmod 644 ${UBIOS_CERT_PATH}/unifi-core.*

		# Import the ertificate for the captive portal
		if [ "$ENABLE_CAPTIVE" == "yes" ]; then
			podman exec -it unifi-os ${CERT_IMPORT_CMD} ${UNIFIOS_CERT_PATH}/unifi-core.key ${UNIFIOS_CERT_PATH}/unifi-core.crt
	
			# This doesn't reboot your router, it just restarts the UnifiOS container
			unifi-os restart
		fi
	else
		echo 'No new certificate was found, exiting without restart'
	fi
}

# Support alternative DNS resolvers
if [ "${DNS_RESOLVERS}" != "" ]; then
	LEGO_ARGS="${LEGO_ARGS} --dns.resolvers ${DNS_RESOLVERS}"
fi

# Support multiple certificate SANs
for DOMAIN in $(echo $CERT_HOSTS | tr "," "\n"); do
	if [ -z "$CERT_NAME" ]; then
		CERT_NAME=$DOMAIN
	fi
	LEGO_ARGS="${LEGO_ARGS} -d ${DOMAIN}"
done

# Check for optional .aws directory, and add it to the mounts if it exists
if [ -d "${UDM_LE_PATH}/.aws" ]; then
        DOCKER_VOLUMES="${DOCKER_VOLUMES} -v ${UDM_LE_PATH}/aws:/home/lego/.aws/"
fi

# Setup persistent on_boot.d trigger
ON_BOOT_DIR='/mnt/data/on_boot.d'
ON_BOOT_FILE='99-udm-le.sh'
if [ -d "${ON_BOOT_DIR}" ] && [ ! -f "${ON_BOOT_DIR}/${ON_BOOT_FILE}" ]; then
	cp "${UDM_LE_PATH}/on_boot.d/${ON_BOOT_FILE}" "${ON_BOOT_DIR}/${ON_BOOT_FILE}"
	chmod 755 ${ON_BOOT_DIR}/${ON_BOOT_FILE}
fi

# Setup nightly cron job
CRON_FILE='/etc/cron.d/udm-le'
if [ ! -f "${CRON_FILE}" ]; then
	echo "0 3 * * * sh ${UDM_LE_PATH}/udm-le.sh renew" >${CRON_FILE}
	chmod 644 ${CRON_FILE}
	/etc/init.d/crond reload ${CRON_FILE}
fi

PODMAN_CMD="podman run --env-file=${UDM_LE_PATH}/udm-le.env -it --name=lego --network=host --rm ${DOCKER_VOLUMES} hectormolinero/lego"

case $1 in
initial)
	# Create lego directory so the container can write to it
	if [ "$(stat -c '%u:%g' "${UDM_LE_PATH}/lego")" != "1000:1000" ]; then
		mkdir "${UDM_LE_PATH}"/lego
		chown 1000:1000 "${UDM_LE_PATH}"/lego
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos run && deploy_cert
	;;
renew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 60 && deploy_cert
	;;
esac
