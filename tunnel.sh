#!/bin/bash
# ====================================================
# Multi-Tunnel Manager (GOST & GRE) - Unified Script
# GitHub: https://github.com/Mnidri/tunnel.sh
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="/etc/tunnel-core"
CONFIG_DIR="${BASE_DIR}/configs"
mkdir -p "${CONFIG_DIR}"

# ----------------- Prerequisites -----------------
install_prerequisites() {
    clear
    echo -e "${CYAN}[*] Checking and installing dependencies...${NC}"
    apt update -y >/dev/null 2>&1
    apt install -y curl wget iptables iproute2 net-tools iputils-ping dnsutils tar >/dev/null 2>&1

    # Enable IPv4 Forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # Install GOST binary if not found
    if [ ! -f /usr/local/bin/gost ]; then
        echo -e "${YELLOW}[*] Downloading GOST binary...${NC}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GOST_ARCH="amd64" ;;
            aarch64) GOST_ARCH="arm64" ;;
            armv7l) GOST_ARCH="armv7" ;;
            *) echo -e "${RED}[!] Unsupported architecture: $ARCH${NC}"; exit 1 ;;
        esac
        
        wget -qO /tmp/gost.tar.gz "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${GOST_ARCH}-2.11.5.tar.gz"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        rm -rf /tmp/gost*
    fi
    echo -e "${GREEN}[+] Prerequisites verified successfully.${NC}\n"
    sleep 1
}

# ----------------- Create GOST Tunnel -----------------
create_gost_tunnel() {
    clear
    echo -e "${CYAN}=== Create GOST Tunnel (L3 TUN over TCP Mux) ===${NC}"
    
    echo -e "\n${YELLOW}Select Server Role:${NC}"
    echo "1) Server (Foreign / Listener)"
    echo "2) Client (Iran / Forwarder)"
    read -p "Select option [1-2]: " SERVER_ROLE

    read -p "Enter Tunnel Name (e.g. tun1): " TUN_NAME
    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: A tunnel with this name already exists!${NC}"
        read -p "Press Enter to return..."; return
    fi

    read -p "Enter TCP Port for tunnel traffic (e.g. 8443): " PORT
    read -p "Enter Local Tunnel IP with CIDR (e.g. 10.10.10.1/30): " LOCAL_TUN_IP
    read -p "Enter Remote Tunnel IP without CIDR (e.g. 10.10.10.2): " REMOTE_TUN_IP
    read -p "Enter MTU (Default: 1360): " MTU
    MTU=${MTU:-1360}

    if [ "$SERVER_ROLE" == "1" ]; then
        ROLE_NAME="SERVER"
        EXEC_CMD="/usr/local/bin/gost -L \"tun://${TUN_NAME}::${PORT}?net=${LOCAL_TUN_IP}&mtu=${MTU}\""
    else
        ROLE_NAME="CLIENT"
        read -p "Enter Remote Server Public IP: " REMOTE_PUB_IP
        EXEC_CMD="/usr/local/bin/gost -L \"tun://${TUN_NAME}:0?net=${LOCAL_TUN_IP}&mtu=${MTU}\" -F \"tcp://${REMOTE_PUB_IP}:${PORT}\""
    fi

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GOST Tunnel L3 - ${TUN_NAME}
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '${EXEC_CMD}'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat << EOF > "${CONFIG_DIR}/${TUN_NAME}.conf"
TYPE="GOST"
ROLE="${ROLE_NAME}"
TUN_NAME="${TUN_NAME}"
PORT="${PORT}"
LOCAL_TUN_IP="${LOCAL_TUN_IP}"
REMOTE_TUN_IP="${REMOTE_TUN_IP}"
REMOTE_PUB_IP="${REMOTE_PUB_IP:-N/A}"
MTU="${MTU}"
EOF

    systemctl daemon-reload
    systemctl enable --now tunnel-${TUN_NAME}.service >/dev/null 2>&1

    show_summary "${TUN_NAME}"
}

# ----------------- Create GRE Tunnel -----------------
create_gre_tunnel() {
    clear
    echo -e "${CYAN}=== Create GRE Tunnel ===${NC}"
    
    echo -e "\n${YELLOW}Select Server Role:${NC}"
    echo "1) Foreign Server"
    echo "2) Iran Server"
    read -p "Select option [1-2]: " SERVER_ROLE

    read -p "Enter Tunnel Name (e.g. gre1): " TUN_NAME
    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: A tunnel with this name already exists!${NC}"
        read -p "Press Enter to return..."; return
    fi

    read -p "Enter Local Public IP of this server: " LOCAL_PUB_IP
    read -p "Enter Remote Public IP of the other server: " REMOTE_PUB_IP
    read -p "Enter Local Tunnel IP with CIDR (e.g. 10.20.20.1/30): " LOCAL_TUN_IP
    read -p "Enter Remote Tunnel IP without CIDR (e.g. 10.20.20.2): " REMOTE_TUN_IP
    read -p "Enter MTU (Default: 1400): " MTU
    MTU=${MTU:-1400}

    ROLE_NAME="IRAN"
    [ "$SERVER_ROLE" == "1" ] && ROLE_NAME="FOREIGN"

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GRE Tunnel - ${TUN_NAME}
After=network.target

[Service]
Type=oneshot
ExecStartPre=/sbin/modprobe ip_gre
ExecStart=/sbin/ip tunnel add ${TUN_NAME} mode gre remote ${REMOTE_PUB_IP} local ${LOCAL_PUB_IP} ttl 255
ExecStart=/sbin/ip addr add ${LOCAL_TUN_IP} dev ${TUN_NAME}
ExecStart=/sbin/ip link set dev ${TUN_NAME} mtu ${MTU}
ExecStart=/sbin/ip link set ${TUN_NAME} up
ExecStop=/sbin/ip link set ${TUN_NAME} down
ExecStop=/sbin/ip tunnel del ${TUN_NAME}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat << EOF > "${CONFIG_DIR}/${TUN_NAME}.conf"
TYPE="GRE"
ROLE="${ROLE_NAME}"
TUN_NAME="${TUN_NAME}"
LOCAL_PUB_IP="${LOCAL_PUB_IP}"
REMOTE_PUB_IP="${REMOTE_PUB_IP}"
LOCAL_TUN_IP="${LOCAL_TUN_IP}"
REMOTE_TUN_IP="${REMOTE_TUN_IP}"
MTU="${MTU}"
EOF

    systemctl daemon-reload
    systemctl enable --now tunnel-${TUN_NAME}.service >/dev/null 2>&1
    iptables -I INPUT -p gre -j ACCEPT 2>/dev/null
    iptables -I FORWARD -j ACCEPT 2>/dev/null

    show_summary "${TUN_NAME}"
}

# ----------------- Summary Screen -----------------
show_summary() {
    local NAME=$1
    source "${CONFIG_DIR}/${NAME}.conf"
    
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e "${GREEN}           TUNNEL CONFIGURED SUCCESSFULLY         ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "Tunnel Identifier : ${CYAN}${TUN_NAME}${NC}"
    echo -e "Tunnel Protocol   : ${CYAN}${TYPE}${NC}"
    echo -e "Assigned Role     : ${CYAN}${ROLE}${NC}"
    echo -e "Local Tunnel IP   : ${YELLOW}${LOCAL_TUN_IP}${NC}"
    echo -e "Remote Tunnel IP  : ${YELLOW}${REMOTE_TUN_IP}${NC}"
    [ "$TYPE" == "GOST" ] && echo -e "TCP Listen Port   : ${YELLOW}${PORT}${NC}"
    [ "$TYPE" == "GOST" ] && echo -e "Remote Target IP  : ${YELLOW}${REMOTE_PUB_IP}${NC}"
    echo -e "Configured MTU    : ${YELLOW}${MTU}${NC}"
    echo -e "Systemd Service   : ${CYAN}tunnel-${TUN_NAME}.service${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${YELLOW}Usage in Rathole / Inner Core:${NC}"
    echo -e "Set your remote peer connection address to: ${CYAN}${REMOTE_TUN_IP}${NC}"
    echo -e "${GREEN}==================================================${NC}\n"
    read -p "Press Enter to return to main menu..."
}

# ----------------- List All Tunnels -----------------
list_tunnels() {
    clear
    echo -e "${CYAN}=== Active & Registered Tunnels ===${NC}\n"
    FILES=("${CONFIG_DIR}"/*.conf)
    if [ ! -e "${FILES[0]}" ]; then
        echo -e "${YELLOW}No tunnels configured yet.${NC}"
    else
        printf "%-12s %-8s %-10s %-18s %-12s\n" "NAME" "TYPE" "ROLE" "LOCAL IP" "STATUS"
        echo "---------------------------------------------------------------"
        for conf in "${CONFIG_DIR}"/*.conf; do
            source "$conf"
            STATUS=$(systemctl is-active tunnel-${TUN_NAME}.service 2>/dev/null)
            if [ "$STATUS" == "active" ]; then
                STATUS_COLOR="${GREEN}active (up)${NC}"
            else
                STATUS_COLOR="${RED}inactive${NC}"
            fi
            printf "%-12s %-8s %-10s %-18s %b\n" "$TUN_NAME" "$TYPE" "$ROLE" "$LOCAL_TUN_IP" "$STATUS_COLOR"
        done
    fi
    echo ""
    read -p "Press Enter to return..."
}

# ----------------- Ping Test -----------------
test_ping() {
    clear
    echo -e "${CYAN}=== Tunnel Connectivity Test (Ping) ===${NC}\n"
    read -p "Enter Tunnel Name to test: " TUN_NAME
    
    if [ ! -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Tunnel '${TUN_NAME}' not found.${NC}"
        read -p "Press Enter to return..."; return
    fi

    source "${CONFIG_DIR}/${TUN_NAME}.conf"
    echo -e "\n${YELLOW}[*] Sending 4 ICMP packets to Remote Tunnel IP (${REMOTE_TUN_IP})...${NC}\n"
    ping -c 4 -W 2 "${REMOTE_TUN_IP}"
    
    echo -e "\n${GREEN}[+] Ping test complete.${NC}"
    read -p "Press Enter to return..."
}

# ----------------- Delete Tunnel -----------------
delete_tunnel() {
    clear
    echo -e "${RED}=== Delete Tunnel ===${NC}\n"
    read -p "Enter Tunnel Name to delete: " TUN_NAME

    if [ ! -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Tunnel not found.${NC}"
        read -p "Press Enter to return..."; return
    fi

    source "${CONFIG_DIR}/${TUN_NAME}.conf"

    systemctl stop tunnel-${TUN_NAME}.service >/dev/null 2>&1
    systemctl disable tunnel-${TUN_NAME}.service >/dev/null 2>&1
    rm -f /etc/systemd/system/tunnel-${TUN_NAME}.service
    systemctl daemon-reload

    if [ "$TYPE" == "GRE" ]; then
        ip link set dev "${TUN_NAME}" down 2>/dev/null
        ip tunnel del "${TUN_NAME}" 2>/dev/null
    fi

    rm -f "${CONFIG_DIR}/${TUN_NAME}.conf"
    echo -e "\n${GREEN}[+] Tunnel '${TUN_NAME}' deleted and network state cleaned.${NC}"
    read -p "Press Enter to return..."
}

# ----------------- TCP BBR Optimization -----------------
optimize_system() {
    clear
    echo -e "${CYAN}=== Enable TCP BBR Congestion Control ===${NC}"
    modprobe tcp_bbr 2>/dev/null
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}[+] TCP BBR enabled successfully.${NC}"
    read -p "Press Enter to return..."
}

# ----------------- Main Menu Loop -----------------
install_prerequisites

while true; do
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        Multi-Tunnel Manager (GOST & GRE)         ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}1)${NC} Create GOST Tunnel (TCP Layer 3 - Anti UDP-Drop)"
    echo -e "${YELLOW}2)${NC} Create GRE Tunnel (Raw L3)"
    echo -e "${YELLOW}3)${NC} List Tunnels & Status"
    echo -e "${YELLOW}4)${NC} Ping Connectivity Test"
    echo -e "${YELLOW}5)${NC} Delete a Tunnel"
    echo -e "${YELLOW}6)${NC} Optimize Network (Enable BBR)"
    echo -e "${YELLOW}0)${NC} Exit"
    echo -e "${CYAN}==================================================${NC}"
    read -p "Choose an option [0-6]: " OPTION

    case $OPTION in
        1) create_gost_tunnel ;;
        2) create_gre_tunnel ;;
        3) list_tunnels ;;
        4) test_ping ;;
        5) delete_tunnel ;;
        6) optimize_system ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option!${NC}"; sleep 1 ;;
    esac
done
