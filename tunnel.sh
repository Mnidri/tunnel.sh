#!/bin/bash
# ====================================================
# Multi-Tunnel Manager (GOST WSS PF & GRE) - V3
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
    apt install -y curl wget iptables iproute2 net-tools iputils-ping dnsutils gzip >/dev/null 2>&1

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
        
        echo -e "${CYAN} -> Fetching GOST (${GOST_ARCH})...${NC}"
        if ! curl -sSL -f -o /tmp/gost.gz "${GOST_URL}"; then
            if ! curl -sSL -f -o /tmp/gost.gz "${MIRROR1}"; then
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
            echo -e "${RED}[!] Critical: Failed to download GOST.${NC}"
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

# ----------------- 1. Create GOST Port Forward (L4 WSS) -----------------
create_gost_pf() {
    clear
    echo -e "${CYAN}=== Create GOST Port Forward (Secure WebSocket - WSS) ===${NC}"
    echo -e "${YELLOW}Fully independent secure tunnel for port forwarding.${NC}\n"
    
    echo -e "${YELLOW}Select Server Role:${NC}"
    echo "1) Foreign Server (Server / Listener)"
    echo "2) Iran Server (Client / Forwarder)"
    read -p "Select option [1-2, default: 1]: " SERVER_ROLE
    SERVER_ROLE=${SERVER_ROLE:-1}

    ROLE_NAME="SERVER"
    [ "$SERVER_ROLE" == "2" ] && ROLE_NAME="CLIENT"

    read -p "Tunnel Name [default: gost_pf1]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-gost_pf1}

    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}[!] Error: Tunnel '${TUN_NAME}' already exists!${NC}"
        read -p "Press Enter to return..."; return
    fi

    echo -e "\n${YELLOW}--- Security Credentials ---${NC}"
    read -p "Username [default: admin]: " AUTH_USER
    AUTH_USER=${AUTH_USER:-admin}
    read -p "Password [default: Pass123!]: " AUTH_PASS
    AUTH_PASS=${AUTH_PASS:-Pass123!}

    echo -e "\n${YELLOW}--- Port Configuration ---${NC}"
    read -p "Secure WSS Tunnel Port (between servers) [default: 443]: " TUN_PORT
    TUN_PORT=${TUN_PORT:-443}

    APP_PORT="N/A"
    TARGET_IP="N/A"
    REMOTE_PUB_IP="N/A"

    if [ "$ROLE_NAME" == "SERVER" ]; then
        EXEC_CMD="/usr/local/bin/gost -L relay+wss://${AUTH_USER}:${AUTH_PASS}@:${TUN_PORT}"
        iptables -I INPUT -p tcp --dport ${TUN_PORT} -j ACCEPT 2>/dev/null
    else
        while true; do
            read -p "Remote Server Public IP (Foreign IP): " REMOTE_PUB_IP
            if [ -n "$REMOTE_PUB_IP" ]; then break; fi
            echo -e "${RED}[!] Server IP is required!${NC}"
        done
        read -p "Port you want to forward (e.g. your panel port) [default: 2333]: " APP_PORT
        APP_PORT=${APP_PORT:-2333}
        read -p "Target IP on Foreign Server [default: 127.0.0.1]: " TARGET_IP
        TARGET_IP=${TARGET_IP:-127.0.0.1}
        
        # Listen locally, forward via WSS to target IP/Port on foreign server
        EXEC_CMD="/usr/local/bin/gost -L tcp://:${APP_PORT}/${TARGET_IP}:${APP_PORT} -L udp://:${APP_PORT}/${TARGET_IP}:${APP_PORT} -F relay+wss://${AUTH_USER}:${AUTH_PASS}@${REMOTE_PUB_IP}:${TUN_PORT}"
        iptables -I INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport ${APP_PORT} -j ACCEPT 2>/dev/null
    fi

    generate_gost_service
    save_gost_config
    start_service

    echo -e "\n${GREEN}=== GOST Port Forward Created ===${NC}"
    read -p "Press Enter to return..."
}

generate_gost_service() {
    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GOST Port Forward - ${TUN_NAME}
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
}

save_gost_config() {
    cat << EOF > "${CONFIG_DIR}/${TUN_NAME}.conf"
TYPE="GOST_PF"
ROLE="${ROLE_NAME}"
TUN_NAME="${TUN_NAME}"
AUTH_USER="${AUTH_USER}"
AUTH_PASS="${AUTH_PASS}"
TUN_PORT="${TUN_PORT}"
APP_PORT="${APP_PORT}"
TARGET_IP="${TARGET_IP}"
REMOTE_PUB_IP="${REMOTE_PUB_IP}"
EOF
}

start_service() {
    systemctl daemon-reload
    systemctl enable --now tunnel-${TUN_NAME}.service >/dev/null 2>&1
    sleep 2
}

# ----------------- 2. Create GRE Tunnel (UNTOUCHED) -----------------
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

    generate_gre_service
    save_gre_config
    start_service

    iptables -I INPUT -p gre -j ACCEPT 2>/dev/null
    iptables -I INPUT -i ${TUN_NAME} -j ACCEPT 2>/dev/null
    iptables -I FORWARD -i ${TUN_NAME} -j ACCEPT 2>/dev/null
    iptables -I FORWARD -o ${TUN_NAME} -j ACCEPT 2>/dev/null

    echo -e "\n${GREEN}=== GRE Tunnel Created ===${NC}"
    read -p "Press Enter to return..."
}

generate_gre_service() {
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
}

save_gre_config() {
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
}

# ----------------- Status, Ping, Edit, Delete -----------------
list_tunnels() {
    clear
    echo -e "${CYAN}=== Configured Tunnels Overview ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels configured yet.${NC}"
    else
        printf "%-12s %-10s %-10s %-20s %-14s\n" "NAME" "TYPE" "ROLE" "KEY INFO" "STATUS"
        echo "----------------------------------------------------------------------"
        for conf in "${CONFIG_FILES[@]}"; do
            source "$conf"
            STATUS=$(systemctl is-active tunnel-${TUN_NAME}.service 2>/dev/null)
            
            if [ "$STATUS" == "active" ]; then
                STATUS_COLOR="${GREEN}active (up)${NC}"
            else
                STATUS_COLOR="${RED}inactive${NC}"
            fi
            
            if [ "$TYPE" == "GOST_PF" ]; then
                [ "$ROLE" == "SERVER" ] && INFO="Listen: ${TUN_PORT}" || INFO="Port: ${APP_PORT} -> ${TUN_PORT}"
            else
                INFO="${LOCAL_TUN_IP}"
            fi
            
            printf "%-12s %-10s %-10s %-20s %b\n" "$TUN_NAME" "$TYPE" "$ROLE" "$INFO" "$STATUS_COLOR"
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

    echo -e "${YELLOW}Select a tunnel to ping (GRE L3 only):${NC}"
    VALID_INDEXES=()
    for i in "${!CONFIG_FILES[@]}"; do
        source "${CONFIG_FILES[$i]}"
        if [ "$TYPE" == "GOST_PF" ]; then
            echo -e " ${RED}X)${NC} ${TUN_NAME} [GOST] -> (Port Forwarding has no L3 IP to ping)"
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

# ----------------- EDIT TUNNEL -----------------
edit_tunnel() {
    clear
    echo -e "${CYAN}=== Edit Existing Tunnel ===${NC}\n"
    get_config_files
    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No tunnels found to edit.${NC}"
        read -p "Press Enter to return..."; return
    fi

    for i in "${!CONFIG_FILES[@]}"; do
        source "${CONFIG_FILES[$i]}"
        echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] Role: ${ROLE}"
    done
    echo -e " ${YELLOW}0)${NC} Cancel & Back\n"

    read -p "Select tunnel to edit [1-${#CONFIG_FILES[@]}, 0 to cancel]: " SEL
    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CONFIG_FILES[@]}" ]; then
        CONF_FILE="${CONFIG_FILES[$((SEL-1))]}"
        source "$CONF_FILE"
        
        echo -e "\n${CYAN}Editing: ${TUN_NAME} (${TYPE})${NC}"
        echo -e "${YELLOW}Press ENTER to keep the current value.${NC}\n"

        if [ "$TYPE" == "GOST_PF" ]; then
            read -p "Username [${AUTH_USER}]: " NEW_AUTH_USER
            AUTH_USER=${NEW_AUTH_USER:-$AUTH_USER}
            read -p "Password [${AUTH_PASS}]: " NEW_AUTH_PASS
            AUTH_PASS=${NEW_AUTH_PASS:-$AUTH_PASS}
            read -p "Secure WSS Tunnel Port [${TUN_PORT}]: " NEW_TUN_PORT
            TUN_PORT=${NEW_TUN_PORT:-$TUN_PORT}

            if [ "$ROLE" == "CLIENT" ]; then
                read -p "Remote Server Public IP [${REMOTE_PUB_IP}]: " NEW_REMOTE_PUB_IP
                REMOTE_PUB_IP=${NEW_REMOTE_PUB_IP:-$REMOTE_PUB_IP}
                read -p "Forwarded App Port [${APP_PORT}]: " NEW_APP_PORT
                APP_PORT=${NEW_APP_PORT:-$APP_PORT}
                read -p "Target IP on Foreign Server [${TARGET_IP}]: " NEW_TARGET_IP
                TARGET_IP=${NEW_TARGET_IP:-$TARGET_IP}
                
                EXEC_CMD="/usr/local/bin/gost -L tcp://:${APP_PORT}/${TARGET_IP}:${APP_PORT} -L udp://:${APP_PORT}/${TARGET_IP}:${APP_PORT} -F relay+wss://${AUTH_USER}:${AUTH_PASS}@${REMOTE_PUB_IP}:${TUN_PORT}"
            else
                EXEC_CMD="/usr/local/bin/gost -L relay+wss://${AUTH_USER}:${AUTH_PASS}@:${TUN_PORT}"
            fi
            
            generate_gost_service
            save_gost_config

        elif [ "$TYPE" == "GRE" ]; then
            read -p "Local Public IP [${LOCAL_PUB_IP}]: " NEW_LOCAL_PUB_IP
            LOCAL_PUB_IP=${NEW_LOCAL_PUB_IP:-$LOCAL_PUB_IP}
            read -p "Remote Server Public IP [${REMOTE_PUB_IP}]: " NEW_REMOTE_PUB_IP
            REMOTE_PUB_IP=${NEW_REMOTE_PUB_IP:-$REMOTE_PUB_IP}
            read -p "Local Tunnel IP [${LOCAL_TUN_IP}]: " NEW_LOCAL_TUN_IP
            LOCAL_TUN_IP=${NEW_LOCAL_TUN_IP:-$LOCAL_TUN_IP}
            read -p "Remote Tunnel IP [${REMOTE_TUN_IP}]: " NEW_REMOTE_TUN_IP
            REMOTE_TUN_IP=${NEW_REMOTE_TUN_IP:-$REMOTE_TUN_IP}
            read -p "MTU [${MTU}]: " NEW_MTU
            MTU=${NEW_MTU:-$MTU}

            systemctl stop tunnel-${TUN_NAME}.service >/dev/null 2>&1
            ip link set dev "${TUN_NAME}" down 2>/dev/null
            ip tunnel del "${TUN_NAME}" 2>/dev/null
            
            generate_gre_service
            save_gre_config
        fi

        systemctl daemon-reload
        systemctl restart tunnel-${TUN_NAME}.service
        echo -e "\n${GREEN}[+] Tunnel '${TUN_NAME}' successfully updated and restarted.${NC}"
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
    echo -e "${CYAN}         Tunnel Manager (GOST WSS & GRE)            ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}1)${NC} Create GOST Tunnel (Secure Port Forward WSS)"
    echo -e "${YELLOW}2)${NC} Create GRE Tunnel (Raw L3)"
    echo -e "${YELLOW}3)${NC} List All Tunnels & Status"
    echo -e "${YELLOW}4)${NC} Ping Connectivity Test (GRE Only)"
    echo -e "${YELLOW}5)${NC} Edit an Existing Tunnel"
    echo -e "${YELLOW}6)${NC} Delete a Tunnel"
    echo -e "${YELLOW}7)${NC} Optimize Network (Enable BBR)"
    echo -e "${YELLOW}0)${NC} Exit"
    echo -e "${CYAN}====================================================${NC}"
    read -p "Choose an option [0-7]: " OPTION

    case $OPTION in
        1) create_gost_pf ;;
        2) create_gre_tunnel ;;
        3) list_tunnels ;;
        4) test_ping ;;
        5) edit_tunnel ;;
        6) delete_tunnel ;;
        7) optimize_system ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option!${NC}"; sleep 1 ;;
    esac
done
