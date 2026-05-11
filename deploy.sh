#!/bin/bash

#Install dependencies and configure the system for mesh networking
apt update && apt upgrade -y
apt install batctl vim net-tools apache2 python3-pip python3-venv libgl1 jq iptables iw build-essential apt-transport-https ca-certificates gnupg git dkms linux-headers-$(uname -r) -y
systemctl stop apache2
systemctl disable apache2
sudo apt remove wpasupplicant -y

# Configure BATMAN
echo 'batman-adv' | sudo tee -a /etc/modules
sudo modprobe batman-adv
echo 'denyinterfaces wlan0' | sudo tee -a /etc/dhcpcd.conf

# Configure Services
mkdir -p /opt/iot-mesh/
mkdir -p /var/lib/iot-mesh/
uuid=$(cat /proc/sys/kernel/random/uuid)
echo $uuid > /var/lib/iot-mesh/node_uuid
git clone https://github.com/gnnbarbosa/iot-mesh.git /opt/iot-mesh

if [ "$1" == "client" ]; then
    nmcli r wifi on
    apt update
    chmod +x /opt/iot-mesh/app/startup.sh
    chmod +x /opt/iot-mesh/app/set_ip.sh
    cp /opt/iot-mesh/app/services/* /lib/systemd/system/
    systemctl daemon-reload
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    clear 
    sleep 1
    echo "Your network is being initialized."

elif [ "$1" == "router" ]; then
echo "This option is not available anymore. Use client mode." 
else
    echo "Usage: $0 [client|router]"
    exit 1
fi