#!/bin/bash
# ====================================================
# Multi-Tunnel Manager (GOST PF, GRE, WireGuard)
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
    local IP=$(curl -s4 --max-time 3 api.ipify.org | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -z "$IP" ]; then
        IP=$(curl -s4 --max-time 3 icanhazip.com | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    echo "${IP}"
}

# ----------------- Prerequisites -----------------
install_prerequisites() {
    clear
    echo -e "${CYAN}[*] Verifying system dependencies...${NC}"
    apt update -y >/dev/null 2>&1
    apt install -y curl wget iptables iproute2 net-tools iputils-ping dnsutils gzip wireguard wireguard-tools >/dev/null 2>&1

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    if [ ! -f /usr/local/bin/gost ]; then
        echo -e "${YELLOW}[*] Downloading GOST binary...${NC}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GOST_ARCH="amd64" ;;
            aarch64|arm64) GOST_ARCH="armv8" ;; 
            armv7l|armv7) GOST_ARCH="armv7" ;;
            *) GOST_ARCH="amd64" ;; 
        esac
        
        GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${GOST_ARCH}-2.11.5.gz"
        MIRROR1="https://mirror.ghproxy.com/${GOST_URL}"
        MIRROR2="https://ghproxy.net/${GOST_URL}"
        
        rm -f /tmp/gost*
        
        echo -e "${CYAN} -> Fetching GOST (${GOST_ARCH}) from GitHub...${NC}"
        if ! curl -sSL -f -o /tmp/gost.gz "${GOST_URL}"; then
            echo -e "${YELLOW} -> GitHub blocked/failed. Trying Mirror 1...${NC}"
            if ! curl -sSL -f -o /tmp/gost.gz "${MIRROR1}"; then
                echo -e "${YELLOW} -> Mirror 1 failed. Trying Mirror 2...${NC}"
                curl -sSL -f -o /tmp/gost.gz "${MIRROR2}"
            fi
        fi
        
        if [ -s /tmp/gost.gz ]; then
            gzip -df /tmp/gost.gz
            if [ -f /tmp/gost ]; then
                mv /tmp/gost /usr/local/bin/gost
                chmod +x /usr/local/bin/gost
                echo -e "${GREEN}[+] GOST installed successfully.${NC}"
            else
                echo -e "${RED}[!] Extraction failed. File might be corrupted.${NC}"
                rm -f /tmp/gost*
            fi
        else
            echo -e "${RED}[!] Critical: Failed to download GOST from all sources.${NC}"
        fi
    fi
    echo -e "${GREEN}[+] Dependencies are ready.${NC}\n"
    sleep 1
}

get_config_files() {
    CONFIG_FILES=()
    for f in "${CONFIG_DIR}"/*.conf; do
        [ -e "$f" ] && CONFIG_FILES+=("$f")
    done
}

# ----------------- 1. Create GOST Port Forward (L4 TCP/TLS) -----------------
create_gost_pf() {
    clear
    echo -e "${CYAN}=== Create GOST Port Forward (Secure Relay+TLS) ===${NC}"
    echo -e "${YELLOW}This tunnels Rathole/TCP traffic securely over TLS without L3 IP routing.${NC}\n"
    
    echo -e "${YELLOW}Select Server Role:${NC}"
    echo "1) Foreign Server (Server / Listener)"
    echo "2) Iran Server (Client / Forwarder)"
    read -p "Select option [1-2, default: 1]: " SERVER_ROLE
    SERVER_ROLE=${SERVER_ROLE:-1}

    ROLE_NAME="SERVER"
    [ "$SERVER_ROLE" == "2" ] && ROLE_NAME="CLIENT"

    read -p "Tunnel/Service Name [default: gost_pf1]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-gost_pf1}

    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: Tunnel '${TUN_NAME}' already exists!${NC}"
        read -p "Press Enter to return..."; return
    fi

    echo -e "\n${YELLOW}--- Security Credentials ---${NC}"
    read -p "Username for TLS auth [default: admin]: " AUTH_USER
    AUTH_USER=${AUTH_USER:-admin}
    read -p "Password for TLS auth [default: Pass123!]: " AUTH_PASS
    AUTH_PASS=${AUTH_PASS:-Pass123!}

    echo -e "\n${YELLOW}--- Port Configuration ---${NC}"
    read -p "Secure GOST Tunnel Port (between servers) [default: 8443]: " TUN_PORT
    TUN_PORT=${TUN_PORT:-8443}

    if [ "$ROLE_NAME" == "SERVER" ]; then
        # Server listens securely
        EXEC_CMD="/usr/local/bin/gost -L relay+tls://${AUTH_USER}:${AUTH_PASS}@:${TUN_PORT}"
        iptables -I INPUT -p tcp --dport ${TUN_PORT} -j ACCEPT 2>/dev/null
    else
        # Client asks for target port to forward
        while true; do
            read -p "Remote Server Public IP (Foreign IP): " REMOTE_PUB_IP
            if [ -n "$REMOTE_PUB_IP" ]; then break; fi
            echo -e "${RED}[!] Server IP is required!${NC}"
        done
        read -p "Local/Remote Application Port (e.g. Rathole port) [default: 2333]: " APP_PORT
        APP_PORT=${APP_PORT:-2333}
        
        # Client listens locally on APP_PORT and securely sends to Server, which outputs to localhost:APP_PORT
        EXEC_CMD="/usr/local/bin/gost -L tcp://:${APP_PORT}/127.0.0.1:${APP_PORT} -F relay+tls://${AUTH_USER}:${AUTH_PASS}@${REMOTE_PUB_IP}:${TUN_PORT}"
        iptables -I INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null
    fi

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GOST Secure Port Forward - ${TUN_NAME}
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
TYPE="GOST_PF"
ROLE="${ROLE_NAME}"
TUN_NAME="${TUN_NAME}"
TUN_PORT="${TUN_PORT}"
APP_PORT="${APP_PORT:-N/A}"
REMOTE_PUB_IP="${REMOTE_PUB_IP:-N/A}"
EOF

    systemctl daemon-reload
    systemctl enable --now tunnel-${TUN_NAME}.service >/dev/null 2>&1
    sleep 2

    echo -e "\n${GREEN}=== GOST Port Forward Created ===${NC}"
    echo -e "Name: ${CYAN}${TUN_NAME}${NC} | Role: ${CYAN}${ROLE_NAME}${NC}"
    if [ "$ROLE_NAME" == "CLIENT" ]; then
        echo -e "${YELLOW}[*] Usage for Rathole:${NC}"
        echo -e "Point your Iran Rathole Client to: ${GREEN}127.0.0.1:${APP_PORT}${NC}"
        echo -e "It will securely exit on Foreign Server at: ${GREEN}127.0.0.1:${APP_PORT}${NC}"
    fi
    read -p "Press Enter to return..."
}

# ----------------- 2. Create GRE Tunnel (UNTOUCHED - L3 RAW) -----------------
create_gre_tunnel() {
    clear
    echo -e "${CYAN}=== Create GRE Tunnel (Raw L3) ===${NC}\n"
    
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

    echo -e "\n${GREEN}=== GRE Tunnel Created ===${NC}"
    read -p "Press Enter to return..."
}

# ----------------- 3. Create WireGuard Tunnel (Encrypted L3 UDP) -----------------
create_wg_tunnel() {
    clear
    echo -e "${CYAN}=== Create WireGuard Tunnel (Encrypted L3 UDP) ===${NC}\n"
    
    echo -e "${YELLOW}Important: Run this on Server 1 first, copy its Public Key, then run on Server 2!${NC}\n"

    echo -e "${YELLOW}Select Server Role:${NC}"
    echo "1) Foreign Server (Server)"
    echo "2) Iran Server (Client)"
    read -p "Select option [1-2, default: 1]: " SERVER_ROLE
    SERVER_ROLE=${SERVER_ROLE:-1}

    if [ "$SERVER_ROLE" == "1" ]; then
        ROLE_NAME="FOREIGN"
        DEF_NAME="wg0"
        DEF_PORT="51820"
        DEF_LOCAL_IP="10.30.30.1/24"
        DEF_REMOTE_IP="10.30.30.2"
    else
        ROLE_NAME="IRAN"
        DEF_NAME="wg0"
        DEF_PORT="51820"
        DEF_LOCAL_IP="10.30.30.2/24"
        DEF_REMOTE_IP="10.30.30.1"
    fi

    read -p "Tunnel Name [default: ${DEF_NAME}]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-$DEF_NAME}

    if [ -f "/etc/wireguard/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: Interface ${TUN_NAME} already exists in /etc/wireguard/!${NC}"
        read -p "Press Enter to return..."; return
    fi

    read -p "WireGuard UDP Port [default: ${DEF_PORT}]: " WG_PORT
    WG_PORT=${WG_PORT:-$DEF_PORT}

    read -p "Local Tunnel IP with CIDR [default: ${DEF_LOCAL_IP}]: " LOCAL_TUN_IP
    LOCAL_TUN_IP=${LOCAL_TUN_IP:-$DEF_LOCAL_IP}

    read -p "Remote Tunnel IP [default: ${DEF_REMOTE_IP}]: " REMOTE_TUN_IP
    REMOTE_TUN_IP=${REMOTE_TUN_IP:-$DEF_REMOTE_IP}

    read -p "MTU [default: 1360]: " MTU
    MTU=${MTU:-1360}

    # Generate Keys
    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)
    
    echo -e "\n${CYAN}================ YOUR WG PUBLIC KEY =================${NC}"
    echo -e "${GREEN}${PUB_KEY}${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${YELLOW}(Copy this key to paste in the OTHER server's setup)${NC}\n"

    read -p "Enter PEER'S Public Key (Paste it here): " PEER_PUB_KEY

    ENDPOINT_CONF=""
    if [ "$ROLE_NAME" == "IRAN" ]; then
        while true; do
            read -p "Enter Remote Server Public IP (Foreign IP): " REMOTE_PUB_IP
            if [ -n "$REMOTE_PUB_IP" ]; then break; fi
            echo -e "${RED}[!] Server IP is required for the client!${NC}"
        done
        ENDPOINT_CONF="Endpoint = ${REMOTE_PUB_IP}:${WG_PORT}"
        PERSISTENT_KEEPALIVE="PersistentKeepalive = 25"
    fi

    cat << EOF > /etc/wireguard/${TUN_NAME}.conf
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${LOCAL_TUN_IP}
ListenPort = ${WG_PORT}
MTU = ${MTU}

[Peer]
PublicKey = ${PEER_PUB_KEY}
AllowedIPs = 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
${ENDPOINT_CONF}
${PERSISTENT_KEEPALIVE}
EOF

    cat << EOF > "${CONFIG_DIR}/${TUN_NAME}.conf"
TYPE="WIREGUARD"
ROLE="${ROLE_NAME}"
TUN_NAME="${TUN_NAME}"
LOCAL_TUN_IP="${LOCAL_TUN_IP}"
REMOTE_TUN_IP="${REMOTE_TUN_IP}"
MTU="${MTU}"
EOF

    iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null
    iptables -I INPUT -i ${TUN_NAME} -j ACCEPT 2>/dev/null
    iptables -I FORWARD -i ${TUN_NAME} -j ACCEPT 2>/dev/null

    systemctl enable --now wg-quick@${TUN_NAME} >/dev/null 2>&1
    sleep 2

    echo -e "\n${GREEN}=== WireGuard Tunnel Created ===${NC}"
    read -p "Press Enter to return..."
}

# ----------------- Status, Delete, Ping, BBR -----------------
list_tunnels() {
    clear
    echo -e "${CYAN}=== Configured Tunnels Overview ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels configured yet.${NC}"
    else
        printf "%-12s %-12s %-10s %-18s %-14s\n" "NAME" "TYPE" "ROLE" "LOCAL IP" "STATUS"
        echo "----------------------------------------------------------------------"
        for conf in "${CONFIG_FILES[@]}"; do
            source "$conf"
            if [ "$TYPE" == "WIREGUARD" ]; then
                STATUS=$(systemctl is-active wg-quick@${TUN_NAME} 2>/dev/null)
            else
                STATUS=$(systemctl is-active tunnel-${TUN_NAME}.service 2>/dev/null)
            fi
            
            if [ "$STATUS" == "active" ]; then
                STATUS_COLOR="${GREEN}active (up)${NC}"
            else
                STATUS_COLOR="${RED}inactive${NC}"
            fi
            
            PRINT_IP="${LOCAL_TUN_IP}"
            [ "$TYPE" == "GOST_PF" ] && PRINT_IP="L4 Proxy Only"
            
            printf "%-12s %-12s %-10s %-18s %b\n" "$TUN_NAME" "$TYPE" "$ROLE" "$PRINT_IP" "$STATUS_COLOR"
        done
    fi
    echo ""
    read -p "Press Enter to return..."
}

test_ping() {
    clear
    echo -e "${CYAN}=== Tunnel Connectivity Test (Ping) ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels available to test.${NC}"
        read -p "Press Enter to return..."; return
    fi

    echo -e "${YELLOW}Select a tunnel to ping (L3 IP-based only):${NC}"
    VALID_INDEXES=()
    for i in "${!CONFIG_FILES[@]}"; do
        source "${CONFIG_FILES[$i]}"
        if [ "$TYPE" == "GOST_PF" ]; then
            echo -e " ${RED}X)${NC} ${TUN_NAME} [GOST_PF] -> (Skipped: Port Forwarding has no IP to ping)"
        else
            echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] -> Ping Target: ${YELLOW}${REMOTE_TUN_IP}${NC}"
            VALID_INDEXES+=($((i+1)))
        fi
    done
    echo -e " ${YELLOW}0)${NC} Back to Main Menu\n"

    read -p "Select number [0 to exit]: " SEL
    if [[ " ${VALID_INDEXES[*]} " =~ " ${SEL} " ]]; then
        source "${CONFIG_FILES[$((SEL-1))]}"
        echo -e "\n${YELLOW}[*] Sending 4 packets to ${REMOTE_TUN_IP} via ${TUN_NAME}...${NC}\n"
        ping -c 4 -W 2 "${REMOTE_TUN_IP}"
        echo -e "\n${GREEN}[+] Ping test finished.${NC}"
    fi
    read -p "Press Enter to return..."
}

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
        echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] Role: ${ROLE}"
    done
    echo -e " ${YELLOW}0)${NC} Cancel & Back\n"

    read -p "Select number [1-${#CONFIG_FILES[@]}, 0 to cancel]: " SEL
    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CONFIG_FILES[@]}" ]; then
        CONF_FILE="${CONFIG_FILES[$((SEL-1))]}"
        source "$CONF_FILE"
        read -p "Are you sure you want to delete '${TUN_NAME}'? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
            
            if [ "$TYPE" == "WIREGUARD" ]; then
                systemctl stop wg-quick@${TUN_NAME} >/dev/null 2>&1
                systemctl disable wg-quick@${TUN_NAME} >/dev/null 2>&1
                rm -f /etc/wireguard/${TUN_NAME}.conf
            else
                systemctl stop tunnel-${TUN_NAME}.service >/dev/null 2>&1
                systemctl disable tunnel-${TUN_NAME}.service >/dev/null 2>&1
                rm -f /etc/systemd/system/tunnel-${TUN_NAME}.service
                systemctl daemon-reload
                
                if [ "$TYPE" == "GRE" ]; then
                    ip link set dev "${TUN_NAME}" down 2>/dev/null
                    ip tunnel del "${TUN_NAME}" 2>/dev/null
                elif [ "$TYPE" == "GOST_PF" ]; then
                    killall -9 gost 2>/dev/null
                fi
            fi

            rm -f "$CONF_FILE"
            echo -e "${GREEN}[+] Tunnel '${TUN_NAME}' completely removed.${NC}"
        else
            echo -e "${YELLOW}[*] Deletion aborted.${NC}"
        fi
    fi
    read -p "Press Enter to return..."
}

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

# ----------------- Main Menu -----------------
install_prerequisites

while true; do
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}       Tunnel Manager (GOST PF, GRE, WireGuard)     ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}1)${NC} Create GOST Tunnel (Secure TLS Port Forward L4)"
    echo -e "${YELLOW}2)${NC} Create GRE Tunnel (Raw L3)"
    echo -e "${YELLOW}3)${NC} Create WireGuard Tunnel (Encrypted UDP L3)"
    echo -e "${YELLOW}4)${NC} List All Tunnels & Status"
    echo -e "${YELLOW}5)${NC} Ping Connectivity Test"
    echo -e "${YELLOW}6)${NC} Delete a Tunnel"
    echo -e "${YELLOW}7)${NC} Optimize Network (Enable BBR)"
    echo -e "${YELLOW}0)${NC} Exit"
    echo -e "${CYAN}====================================================${NC}"
    read -p "Choose an option [0-7]: " OPTION

    case $OPTION in
        1) create_gost_pf ;;
        2) create_gre_tunnel ;;
        3) create_wg_tunnel ;;
        4) list_tunnels ;;
        5) test_ping ;;
        6) delete_tunnel ;;
        7) optimize_system ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option!${NC}"; sleep 1 ;;
    esac
done
