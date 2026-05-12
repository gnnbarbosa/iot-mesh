#!/bin/bash

REPO_URL="https://github.com/gnnbarbosa/iot-mesh.git"
REPO_DIR="/opt/iot-mesh"

#Install dependencies and configure the system for mesh networking
apt update && apt upgrade -y
apt install batctl vim net-tools apache2 python3-pip python3-venv libgl1 jq iptables iw build-essential apt-transport-https ca-certificates gnupg git dkms linux-headers-$(uname -r) -y
systemctl stop apache2
systemctl disable apache2
sudo apt remove wpasupplicant -y
sudo apt autoremove -y

#Install docker
curl -sSL https://get.docker.com | sh

# Configure BATMAN
echo 'batman-adv' | sudo tee -a /etc/modules
sudo modprobe batman-adv
echo 'denyinterfaces wlan0' | sudo tee -a /etc/dhcpcd.conf

# Configure Services
mkdir -p /opt/iot-mesh/
mkdir -p /var/lib/iot-mesh/
uuid=$(cat /proc/sys/kernel/random/uuid)
echo $uuid > /var/lib/iot-mesh/node_uuid

# Clone or update the repository
if [ -d "$REPO_DIR/.git" ]; then
    echo "Repository already exists in $REPO_DIR. Updating to last version..."
    cd "$REPO_DIR" || exit 1
    git fetch --all
    git reset --hard origin/main
    git pull origin main
else
    echo "Cloning repository in $REPO_DIR..."
    rm -rf "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
fi

if [ "$1" == "client" ]; then
    nmcli r wifi on
    apt update
    chmod +x /opt/iot-mesh/app/*.sh
    cp /opt/iot-mesh/app/services/* /lib/systemd/system/
    systemctl daemon-reload
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    systemctl enable iot-mesh.service
    systemctl enable iot-mesh-set-ip.service
    systemctl enable iot-mesh-set-gw.service
    systemctl start iot-mesh
    systemctl start iot-mesh-set-ip
    systemctl start iot-mesh-set-gw
    sysctl -p
    clear 
    sleep 2
    echo " "
    echo " 
░██████           ░██████████        ░███     ░███                       ░██        
  ░██                 ░██            ░████   ░████                       ░██        
  ░██   ░███████      ░██            ░██░██ ░██░██  ░███████   ░███████  ░████████  
  ░██  ░██    ░██     ░██    ░██████ ░██ ░████ ░██ ░██    ░██ ░██        ░██    ░██ 
  ░██  ░██    ░██     ░██            ░██  ░██  ░██ ░█████████  ░███████  ░██    ░██ 
  ░██  ░██    ░██     ░██            ░██       ░██ ░██               ░██ ░██    ░██ 
░██████ ░███████      ░██            ░██       ░██  ░███████   ░███████  ░██    ░██ 

" 
    echo " "
    echo " "    
    echo "Your network is being initialized."

elif [ "$1" == "router" ]; then
echo "This option is not available anymore. Use client mode." 
else
    echo "Usage: $0 [client|router]"
    exit 1
fi