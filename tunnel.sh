#!/bin/bash
# ====================================================
# Multi-Tunnel Manager (GOST & GRE) - Fully Fixed
# GitHub: https://github.com/Mnidri/tunnel.sh
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="/etc/tunnel-core"
CONFIG_DIR="${BASE_DIR}/configs"
mkdir -p "${CONFIG_DIR}"

# ----------------- Helper: Detect Public IP -----------------
get_public_ip() {
    # دریافت آی‌پی و فیلتر کردن هرگونه کد HTML
    local IP=$(curl -s4 --max-time 3 api.ipify.org | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -z "$IP" ]; then
        IP=$(curl -s4 --max-time 3 icanhazip.com | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    echo "${IP}"
}

# ----------------- Prerequisites (Anti-Filter Download) -----------------
install_prerequisites() {
    clear
    echo -e "${CYAN}[*] Verifying system dependencies...${NC}"
    apt update -y >/dev/null 2>&1
    apt install -y curl wget iptables iproute2 net-tools iputils-ping dnsutils tar >/dev/null 2>&1

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # دانلود هوشمندانه GOST با استفاده از لینک‌های Mirror برای سرور ایران
    if [ ! -f /usr/local/bin/gost ]; then
        echo -e "${YELLOW}[*] Installing GOST binary... (Checking connections)${NC}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GOST_ARCH="amd64" ;;
            aarch64) GOST_ARCH="arm64" ;;
            *) echo -e "${RED}[!] Unsupported architecture: $ARCH${NC}"; exit 1 ;;
        esac
        
        GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${GOST_ARCH}-2.11.5.tar.gz"
        MIRROR_URL="https://mirror.ghproxy.com/${GOST_URL}"
        
        # تلاش برای دانلود مستقیم، در صورت شکست (ایران) استفاده از میرور
        wget -q --timeout=5 -O /tmp/gost.tar.gz "${GOST_URL}" || wget -q --timeout=10 -O /tmp/gost.tar.gz "${MIRROR_URL}"
        
        if [ -s /tmp/gost.tar.gz ]; then
            tar -xzf /tmp/gost.tar.gz -C /tmp/
            find /tmp -type f -name "gost-linux-*" -exec mv {} /usr/local/bin/gost \;
            chmod +x /usr/local/bin/gost
            rm -rf /tmp/gost*
            echo -e "${GREEN}[+] GOST installed successfully.${NC}"
        else
            echo -e "${RED}[!] Failed to download GOST. Internet/DNS issue on this server.${NC}"
            read -p "Press Enter to continue anyway..."
        fi
    fi
    echo -e "${GREEN}[+] Dependencies are ready.${NC}\n"
    sleep 1
}

# ----------------- Get Config List -----------------
get_config_files() {
    CONFIG_FILES=()
    for f in "${CONFIG_DIR}"/*.conf; do
        [ -e "$f" ] && CONFIG_FILES+=("$f")
    done
}

# ----------------- Create GOST Tunnel -----------------
create_gost_tunnel() {
    clear
    echo -e "${CYAN}=== Create GOST Tunnel (TCP Layer 3 TUN) ===${NC}\n"
    
    echo -e "${YELLOW}Select Server Role:${NC}"
    echo "1) Foreign Server (Server / Listener)"
    echo "2) Iran Server (Client / Forwarder)"
    read -p "Select option [1-2, default: 1]: " SERVER_ROLE
    SERVER_ROLE=${SERVER_ROLE:-1}

    if [ "$SERVER_ROLE" == "1" ]; then
        ROLE_NAME="SERVER"
        DEF_NAME="tun1"
        DEF_PORT="8443"
        DEF_LOCAL_IP="10.10.10.1/30"
        DEF_REMOTE_IP="10.10.10.2"
    else
        ROLE_NAME="CLIENT"
        DEF_NAME="tun1"
        DEF_PORT="8443"
        DEF_LOCAL_IP="10.10.10.2/30"
        DEF_REMOTE_IP="10.10.10.1"
    fi

    read -p "Tunnel Name [default: ${DEF_NAME}]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-$DEF_NAME}

    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: Tunnel '${TUN_NAME}' already exists!${NC}"
        read -p "Press Enter to return..."; return
    fi

    if [ "$ROLE_NAME" == "CLIENT" ]; then
        while true; do
            read -p "Enter Remote Server Public IP (Foreign IP): " REMOTE_PUB_IP
            if [ -n "$REMOTE_PUB_IP" ]; then break; fi
            echo -e "${RED}[!] Server IP is required!${NC}"
        done
    fi

    read -p "TCP Listen Port [default: ${DEF_PORT}]: " PORT
    PORT=${PORT:-$DEF_PORT}

    read -p "Local Tunnel IP with CIDR [default: ${DEF_LOCAL_IP}]: " LOCAL_TUN_IP
    LOCAL_TUN_IP=${LOCAL_TUN_IP:-$DEF_LOCAL_IP}

    read -p "Remote Tunnel IP [default: ${DEF_REMOTE_IP}]: " REMOTE_TUN_IP
    REMOTE_TUN_IP=${REMOTE_TUN_IP:-$DEF_REMOTE_IP}

    if [ "$ROLE_NAME" == "SERVER" ]; then
        EXEC_CMD="/usr/local/bin/gost -L tun://:${PORT}?net=${LOCAL_TUN_IP}"
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null
    else
        EXEC_CMD="/usr/local/bin/gost -L tun://:10443?net=${LOCAL_TUN_IP} -F tcp://${REMOTE_PUB_IP}:${PORT}"
    fi

    iptables -I INPUT -i tun+ -j ACCEPT 2>/dev/null
    iptables -I FORWARD -i tun+ -j ACCEPT 2>/dev/null
    iptables -I FORWARD -o tun+ -j ACCEPT 2>/dev/null

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GOST Tunnel L3 - ${TUN_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=3
LimitNOFILE=65535

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
EOF

    systemctl daemon-reload
    systemctl enable --now tunnel-${TUN_NAME}.service >/dev/null 2>&1
    sleep 3

    show_summary "${TUN_NAME}"
}

# ----------------- Create GRE Tunnel (DO NOT TOUCH - WORKING PERFECTLY) -----------------
create_gre_tunnel() {
    clear
    echo -e "${CYAN}=== Create GRE Tunnel ===${NC}\n"
    
    DETECTED_IP=$(get_public_ip)

    echo -e "${YELLOW}Select Server Role:${NC}"
    echo "1) Foreign Server"
    echo "2) Iran Server"
    read -p "Select option [1-2, default: 1]: " SERVER_ROLE
    SERVER_ROLE=${SERVER_ROLE:-1}

    if [ "$SERVER_ROLE" == "1" ]; then
        ROLE_NAME="FOREIGN"
        DEF_NAME="gre1"
        DEF_LOCAL_IP="10.20.20.1/30"
        DEF_REMOTE_IP="10.20.20.2"
    else
        ROLE_NAME="IRAN"
        DEF_NAME="gre1"
        DEF_LOCAL_IP="10.20.20.2/30"
        DEF_REMOTE_IP="10.20.20.1"
    fi

    read -p "Tunnel Name [default: ${DEF_NAME}]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-$DEF_NAME}

    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: Tunnel '${TUN_NAME}' already exists!${NC}"
        read -p "Press Enter to return..."; return
    fi

    read -p "Local Public IP [default: ${DETECTED_IP}]: " LOCAL_PUB_IP
    LOCAL_PUB_IP=${LOCAL_PUB_IP:-$DETECTED_IP}

    while true; do
        read -p "Remote Server Public IP: " REMOTE_PUB_IP
        if [ -n "$REMOTE_PUB_IP" ]; then break; fi
        echo -e "${RED}[!] Remote Public IP is required!${NC}"
    done

    read -p "Local Tunnel IP with CIDR [default: ${DEF_LOCAL_IP}]: " LOCAL_TUN_IP
    LOCAL_TUN_IP=${LOCAL_TUN_IP:-$DEF_LOCAL_IP}

    read -p "Remote Tunnel IP [default: ${DEF_REMOTE_IP}]: " REMOTE_TUN_IP
    REMOTE_TUN_IP=${REMOTE_TUN_IP:-$DEF_REMOTE_IP}

    read -p "MTU [default: 1400]: " MTU
    MTU=${MTU:-1400}

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GRE Tunnel - ${TUN_NAME}
After=network.target

[Service]
Type=oneshot
ExecStartPre=-/sbin/ip link set ${TUN_NAME} down
ExecStartPre=-/sbin/ip tunnel del ${TUN_NAME}
ExecStartPre=/sbin/modprobe ip_gre
ExecStart=/sbin/ip tunnel add ${TUN_NAME} mode gre remote ${REMOTE_PUB_IP} local ${LOCAL_PUB_IP} ttl 255
ExecStart=/sbin/ip addr add ${LOCAL_TUN_IP} dev ${TUN_NAME}
ExecStart=/sbin/ip link set dev ${TUN_NAME} mtu ${MTU}
ExecStart=/sbin/ip link set ${TUN_NAME} up
ExecStop=-/sbin/ip link set ${TUN_NAME} down
ExecStop=-/sbin/ip tunnel del ${TUN_NAME}
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
    iptables -I INPUT -i ${TUN_NAME} -j ACCEPT 2>/dev/null
    iptables -I FORWARD -i ${TUN_NAME} -j ACCEPT 2>/dev/null
    iptables -I FORWARD -o ${TUN_NAME} -j ACCEPT 2>/dev/null
    sleep 2

    show_summary "${TUN_NAME}"
}

# ----------------- Summary Screen -----------------
show_summary() {
    local NAME=$1
    source "${CONFIG_DIR}/${NAME}.conf"
    
    IS_ACTIVE=$(systemctl is-active tunnel-${TUN_NAME}.service 2>/dev/null)
    
    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}             TUNNEL CREATED SUCCESSFULLY            ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo -e "Tunnel Identifier : ${CYAN}${TUN_NAME}${NC}"
    echo -e "Protocol Type     : ${CYAN}${TYPE}${NC}"
    echo -e "Assigned Role     : ${CYAN}${ROLE}${NC}"
    echo -e "Local Tunnel IP   : ${YELLOW}${LOCAL_TUN_IP}${NC}"
    echo -e "Remote Tunnel IP  : ${YELLOW}${REMOTE_TUN_IP}${NC}"
    [ "$TYPE" == "GOST" ] && echo -e "TCP Listen Port   : ${YELLOW}${PORT}${NC}"
    [ "$TYPE" == "GOST" ] && [ "$ROLE" == "CLIENT" ] && echo -e "Target Public IP  : ${YELLOW}${REMOTE_PUB_IP}${NC}"
    [ "$TYPE" == "GRE" ] && echo -e "MTU Size          : ${YELLOW}${MTU}${NC}"
    echo -e "Systemd Service   : ${CYAN}tunnel-${TUN_NAME}.service${NC}"
    
    if [ "$IS_ACTIVE" == "active" ]; then
        echo -e "Current Status    : ${GREEN}Active & Running (UP)${NC}"
    else
        echo -e "Current Status    : ${RED}Service Failed - Check Logs (journalctl -u tunnel-${TUN_NAME}.service)${NC}"
    fi
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${YELLOW}[*] How to use inside Rathole or core config:${NC}"
    echo -e "Set peer target connection IP to: ${CYAN}${REMOTE_TUN_IP}${NC}"
    echo -e "${GREEN}====================================================${NC}\n"
    read -p "Press Enter to return to main menu..."
}

# ----------------- List All Tunnels -----------------
list_tunnels() {
    clear
    echo -e "${CYAN}=== Configured Tunnels Overview ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels configured yet.${NC}"
    else
        printf "%-12s %-8s %-10s %-18s %-14s\n" "NAME" "TYPE" "ROLE" "LOCAL IP" "STATUS"
        echo "------------------------------------------------------------------"
        for conf in "${CONFIG_FILES[@]}"; do
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

# ----------------- Ping Connectivity Test -----------------
test_ping() {
    clear
    echo -e "${CYAN}=== Tunnel Connectivity Test (Ping) ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels available to test.${NC}"
        read -p "Press Enter to return..."; return
    fi

    echo -e "${YELLOW}Select a tunnel to ping:${NC}"
    for i in "${!CONFIG_FILES[@]}"; do
        source "${CONFIG_FILES[$i]}"
        echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] -> Ping Target: ${YELLOW}${REMOTE_TUN_IP}${NC}"
    done
    echo -e " ${YELLOW}0)${NC} Back to Main Menu\n"

    read -p "Select number [1-${#CONFIG_FILES[@]}, 0 to exit]: " SEL
    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CONFIG_FILES[@]}" ]; then
        source "${CONFIG_FILES[$((SEL-1))]}"
        echo -e "\n${YELLOW}[*] Sending 4 packets to ${REMOTE_TUN_IP} via ${TUN_NAME}...${NC}\n"
        ping -c 4 -W 2 "${REMOTE_TUN_IP}"
        echo -e "\n${GREEN}[+] Ping test finished.${NC}"
    fi
    read -p "Press Enter to return..."
}

# ----------------- Delete Tunnel -----------------
delete_tunnel() {
    clear
    echo -e "${RED}=== Delete Tunnel ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels found to delete.${NC}"
        read -p "Press Enter to return..."; return
    fi

    echo -e "${YELLOW}Select a tunnel to DELETE:${NC}"
    for i in "${!CONFIG_FILES[@]}"; do
        source "${CONFIG_FILES[$i]}"
        echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] Role: ${ROLE} | IP: ${LOCAL_TUN_IP}"
    done
    echo -e " ${YELLOW}0)${NC} Cancel & Back\n"

    read -p "Select number [1-${#CONFIG_FILES[@]}, 0 to cancel]: " SEL
    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CONFIG_FILES[@]}" ]; then
        CONF_FILE="${CONFIG_FILES[$((SEL-1))]}"
        source "$CONF_FILE"
        read -p "Are you sure you want to delete '${TUN_NAME}'? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
            systemctl stop tunnel-${TUN_NAME}.service >/dev/null 2>&1
            systemctl disable tunnel-${TUN_NAME}.service >/dev/null 2>&1
            rm -f /etc/systemd/system/tunnel-${TUN_NAME}.service
            systemctl daemon-reload

            if [ "$TYPE" == "GRE" ]; then
                ip link set dev "${TUN_NAME}" down 2>/dev/null
                ip tunnel del "${TUN_NAME}" 2>/dev/null
            elif [ "$TYPE" == "GOST" ]; then
                killall -9 gost 2>/dev/null
            fi

            rm -f "$CONF_FILE"
            echo -e "${GREEN}[+] Tunnel '${TUN_NAME}' completely removed.${NC}"
        else
            echo -e "${YELLOW}[*] Deletion aborted.${NC}"
        fi
    fi
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
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}         Multi-Tunnel Manager (GOST & GRE)          ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}1)${NC} Create GOST Tunnel (TCP Layer 3 - Recommended)"
    echo -e "${YELLOW}2)${NC} Create GRE Tunnel (Raw L3)"
    echo -e "${YELLOW}3)${NC} List All Tunnels & Status"
    echo -e "${YELLOW}4)${NC} Ping Connectivity Test"
    echo -e "${YELLOW}5)${NC} Delete a Tunnel"
    echo -e "${YELLOW}6)${NC} Optimize Network (Enable BBR)"
    echo -e "${YELLOW}0)${NC} Exit"
    echo -e "${CYAN}====================================================${NC}"
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
