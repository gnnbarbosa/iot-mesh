#!/bin/bash

HOSTNAME=$(hostname)
LAST_OCTET=$(echo "$HOSTNAME" | grep -o -E '[0-9]+$')

if [ -z "$LAST_OCTET" ]; then
	echo "Erro: The hostname '$HOSTNAME' does not end with a number (between 01 and 99)."
    exit 1
fi

IP_PREFIX="10.99.100"
FINAL_IP="$IP_PREFIX.$LAST_OCTET/24"
sudo ip addr add "$FINAL_IP" dev bat0