#!/bin/bash
# ====================================================
# Multi-Tunnel Manager (Classic Stable Core)
# GitHub: https://github.com/Mnidri/tunnel.sh
#
# GRE:
# - Persistent after reboot
# - network-online aware
# - Automatic interface recovery
# - Automatic route recovery
# - GRE protocol 47 firewall rules
# - rp_filter handling
# - ip_gre module check
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
    local IP

    IP=$(curl -s4 --max-time 3 api.ipify.org 2>/dev/null | \
        grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

    if [ -z "$IP" ]; then
        IP=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null | \
            grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi

    echo "${IP}"
}

# ----------------- Prerequisites -----------------
install_prerequisites() {
    clear

    echo -e "${CYAN}[*] Verifying system dependencies...${NC}"

    apt update -y >/dev/null 2>&1

    apt install -y \
        curl \
        wget \
        iptables \
        iproute2 \
        net-tools \
        iputils-ping \
        dnsutils \
        gzip \
        tcpdump \
        kmod \
        >/dev/null 2>&1

    # IPv4 Forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    sed -i '/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # Loose reverse path filtering.
    # Important for routed/GRE traffic on some VPS networks.
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1

    sed -i '/^[[:space:]]*net\.ipv4\.conf\.all\.rp_filter[[:space:]]*=/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.ipv4\.conf\.default\.rp_filter[[:space:]]*=/d' /etc/sysctl.conf

    echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf
    echo "net.ipv4.conf.default.rp_filter=2" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1

    # ----------------- GOST -----------------
    if [ ! -f /usr/local/bin/gost ]; then

        echo -e "${YELLOW}[*] Downloading GOST binary...${NC}"

        ARCH=$(uname -m)

        case "$ARCH" in
            x86_64)
                GOST_ARCH="amd64"
                ;;
            aarch64|arm64)
                GOST_ARCH="armv8"
                ;;
            armv7l|armv7)
                GOST_ARCH="armv7"
                ;;
            *)
                GOST_ARCH="amd64"
                ;;
        esac

        GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${GOST_ARCH}-2.11.5.gz"

        MIRROR1="https://mirror.ghproxy.com/${GOST_URL}"
        MIRROR2="https://ghproxy.net/${GOST_URL}"

        rm -f /tmp/gost*

        if ! curl -sSL -f -o /tmp/gost.gz "${GOST_URL}"; then

            if ! curl -sSL -f -o /tmp/gost.gz "${MIRROR1}"; then
                curl -sSL -f -o /tmp/gost.gz "${MIRROR2}"
            fi

        fi

        if [ -s /tmp/gost.gz ]; then

            gzip -df /tmp/gost.gz

            mv /tmp/gost /usr/local/bin/gost

            chmod +x /usr/local/bin/gost

        fi
    fi

    echo -e "${GREEN}[+] Dependencies are ready.${NC}\n"

    sleep 1
}

# ----------------- Config Files -----------------
get_config_files() {

    CONFIG_FILES=()

    for f in "${CONFIG_DIR}"/*.conf; do
        [ -e "$f" ] && CONFIG_FILES+=("$f")
    done
}

# ====================================================
# 1. CREATE GOST PORT FORWARD
# ====================================================

create_gost_pf() {

    clear

    echo -e "${CYAN}=== Create GOST Port Forward (MWS Secure Relay) ===${NC}\n"

    echo -e "${YELLOW}Select Server Role:${NC}"

    echo "1) Foreign Server (Server / Listener)"
    echo "2) Iran Server (Client / Forwarder)"

    read -p "Select option [1-2, default: 1]: " SERVER_ROLE

    SERVER_ROLE=${SERVER_ROLE:-1}

    if [ "$SERVER_ROLE" == "1" ]; then
        ROLE_NAME="SERVER"
    else
        ROLE_NAME="CLIENT"
    fi

    read -p "Tunnel Name [default: gost_pf1]: " TUN_NAME

    TUN_NAME=${TUN_NAME:-gost_pf1}

    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then

        echo -e "${RED}[!] Error: Tunnel '${TUN_NAME}' already exists!${NC}"

        read -p "Press Enter to return..."

        return
    fi

    echo -e "\n${YELLOW}--- Security Credentials ---${NC}"

    read -p "Username [default: admin]: " AUTH_USER
    AUTH_USER=${AUTH_USER:-admin}

    read -p "Password [default: Pass123!]: " AUTH_PASS
    AUTH_PASS=${AUTH_PASS:-Pass123!}

    echo -e "\n${YELLOW}--- Port Configuration ---${NC}"

    read -p "MWS Tunnel Port (between servers) [default: 8080]: " TUN_PORT

    TUN_PORT=${TUN_PORT:-8080}

    APP_PORT="N/A"
    TARGET_IP="N/A"
    REMOTE_PUB_IP="N/A"

    if [ "$ROLE_NAME" == "SERVER" ]; then

        EXEC_CMD="/usr/local/bin/gost -L relay+mws://${AUTH_USER}:${AUTH_PASS}@:${TUN_PORT}"

        iptables -I INPUT -p tcp --dport ${TUN_PORT} -j ACCEPT 2>/dev/null

    else

        while true; do

            read -p "Remote Server Public IP (Foreign IP): " REMOTE_PUB_IP

            if [ -n "$REMOTE_PUB_IP" ]; then
                break
            fi

            echo -e "${RED}[!] Server IP is required!${NC}"

        done

        read -p "Port you want to forward (e.g. Xray panel port) [default: 2333]: " APP_PORT

        APP_PORT=${APP_PORT:-2333}

        read -p "Target IP on Foreign Server (Hit Enter for 127.0.0.1 or enter Foreign IP): " TARGET_IP

        TARGET_IP=${TARGET_IP:-127.0.0.1}

        EXEC_CMD="/usr/local/bin/gost -L tcp://:${APP_PORT}/${TARGET_IP}:${APP_PORT} -L udp://:${APP_PORT}/${TARGET_IP}:${APP_PORT} -F relay+mws://${AUTH_USER}:${AUTH_PASS}@${REMOTE_PUB_IP}:${TUN_PORT}"

        iptables -I INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport ${APP_PORT} -j ACCEPT 2>/dev/null

    fi

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=GOST Port Forward - ${TUN_NAME}
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '${EXEC_CMD}'
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
AUTH_USER="${AUTH_USER}"
AUTH_PASS="${AUTH_PASS}"
TUN_PORT="${TUN_PORT}"
APP_PORT="${APP_PORT}"
TARGET_IP="${TARGET_IP}"
REMOTE_PUB_IP="${REMOTE_PUB_IP}"
EOF

    systemctl daemon-reload

    if ! systemctl enable --now tunnel-${TUN_NAME}.service; then

        echo -e "${RED}[!] GOST service failed.${NC}"

        systemctl status tunnel-${TUN_NAME}.service --no-pager

        journalctl -u tunnel-${TUN_NAME}.service -n 30 --no-pager

        read -p "Press Enter to return..."

        return
    fi

    sleep 2

    show_summary "${TUN_NAME}"
}

# ====================================================
# 2. GRE WATCHDOG
# ====================================================

create_gre_watchdog() {

    local TUN_NAME="$1"

    local SCRIPT_PATH="/usr/local/sbin/tunnel-gre-${TUN_NAME}.sh"

    cat << EOF > "${SCRIPT_PATH}"
#!/bin/bash

CONFIG_FILE="/etc/tunnel-core/configs/${TUN_NAME}.conf"

if [ ! -f "\${CONFIG_FILE}" ]; then
    echo "GRE config not found: \${CONFIG_FILE}"
    exit 1
fi

source "\${CONFIG_FILE}"

LOG_TAG="GRE-\${TUN_NAME}"

cleanup_gre() {

    ip link set "\${TUN_NAME}" down 2>/dev/null || true

    ip tunnel del "\${TUN_NAME}" 2>/dev/null || true
}

create_gre() {

    # Make sure GRE kernel module exists.
    modprobe ip_gre 2>/dev/null || true

    # If local public IP does not exist yet,
    # wait for network-online.
    if ! ip -4 addr show | grep -qw "\${LOCAL_PUB_IP}"; then

        logger -t "\${LOG_TAG}" \
            "Waiting for local public IP \${LOCAL_PUB_IP}"

        return 1
    fi

    # Remove broken/stale interface.
    if ip link show "\${TUN_NAME}" >/dev/null 2>&1; then

        CURRENT_REMOTE=\$(
            ip -d tunnel show "\${TUN_NAME}" 2>/dev/null |
            grep -o "remote [0-9.]*" |
            awk '{print \$2}' |
            head -n1
        )

        CURRENT_LOCAL=\$(
            ip -d tunnel show "\${TUN_NAME}" 2>/dev/null |
            grep -o "local [0-9.]*" |
            awk '{print \$2}' |
            head -n1
        )

        if [ "\${CURRENT_REMOTE}" != "\${REMOTE_PUB_IP}" ] || \
           [ "\${CURRENT_LOCAL}" != "\${LOCAL_PUB_IP}" ]; then

            cleanup_gre
        fi
    fi

    # Create GRE if missing.
    if ! ip link show "\${TUN_NAME}" >/dev/null 2>&1; then

        logger -t "\${LOG_TAG}" \
            "Creating GRE: local=\${LOCAL_PUB_IP} remote=\${REMOTE_PUB_IP}"

        if ! ip tunnel add "\${TUN_NAME}" \
            mode gre \
            local "\${LOCAL_PUB_IP}" \
            remote "\${REMOTE_PUB_IP}" \
            ttl 255; then

            logger -t "\${LOG_TAG}" "Failed to create GRE interface"

            return 1
        fi

        ip addr add "\${LOCAL_TUN_IP}" dev "\${TUN_NAME}" 2>/dev/null || true

        ip link set dev "\${TUN_NAME}" mtu "\${MTU}" 2>/dev/null || true

        ip link set "\${TUN_NAME}" up
    else

        ip link set dev "\${TUN_NAME}" mtu "\${MTU}" 2>/dev/null || true

        ip link set "\${TUN_NAME}" up 2>/dev/null || true

        if ! ip -4 addr show dev "\${TUN_NAME}" | grep -q "\${LOCAL_TUN_IP%/*}"; then

            ip addr add "\${LOCAL_TUN_IP}" dev "\${TUN_NAME}" 2>/dev/null || true

        fi
    fi

    # Make sure route to remote tunnel IP exists.
    if ! ip route get "\${REMOTE_TUN_IP}" 2>/dev/null | grep -q "\${TUN_NAME}"; then

        ip route replace "\${REMOTE_TUN_IP}/32" dev "\${TUN_NAME}" 2>/dev/null || true

    fi

    # Firewall.
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p gre -j ACCEPT

    iptables -C FORWARD -i "\${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "\${TUN_NAME}" -j ACCEPT

    iptables -C FORWARD -o "\${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -o "\${TUN_NAME}" -j ACCEPT

    # Verify interface.
    if ip link show "\${TUN_NAME}" >/dev/null 2>&1 && \
       ip link show "\${TUN_NAME}" | grep -q "UP"; then

        logger -t "\${LOG_TAG}" \
            "GRE interface is UP - \${LOCAL_TUN_IP} -> \${REMOTE_TUN_IP}"

        return 0
    fi

    return 1
}

# Main watchdog loop.
while true; do

    if ! create_gre; then

        sleep 5

        continue
    fi

    # If interface disappears, recreate it.
    if ! ip link show "\${TUN_NAME}" >/dev/null 2>&1; then

        logger -t "\${LOG_TAG}" \
            "GRE interface disappeared. Recreating..."

        cleanup_gre

        sleep 2

        continue
    fi

    sleep 5

done
EOF

    chmod +x "${SCRIPT_PATH}"
}

# ====================================================
# 3. CREATE GRE SYSTEMD SERVICE
# ====================================================

create_gre_service() {

    local TUN_NAME="$1"

    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=Persistent GRE Tunnel - ${TUN_NAME}
Documentation=https://github.com/Mnidri/tunnel.sh

After=network-online.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=/usr/local/sbin/tunnel-gre-${TUN_NAME}.sh

Restart=always
RestartSec=3

# Give network enough time during boot.
TimeoutStartSec=0

# Keep enough file descriptors.
LimitNOFILE=65535

# Kill only this service process tree.
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

# ====================================================
# 4. CREATE GRE TUNNEL
# ====================================================

create_gre_tunnel() {

    clear

    echo -e "${CYAN}=== Create GRE Tunnel (Persistent Raw L3) ===${NC}\n"

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

        read -p "Press Enter to return..."

        return
    fi

    echo ""

    # ----------------- Local Public IP -----------------

    read -p "Local Public IP [default: ${DETECTED_IP}]: " LOCAL_PUB_IP

    LOCAL_PUB_IP=${LOCAL_PUB_IP:-$DETECTED_IP}

    if [ -z "$LOCAL_PUB_IP" ]; then

        echo -e "${RED}[!] Could not detect local public IP.${NC}"

        echo -e "${YELLOW}Please enter it manually.${NC}"

        read -p "Press Enter to return..."

        return
    fi

    # Basic IPv4 validation.
    if ! [[ "$LOCAL_PUB_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

        echo -e "${RED}[!] Invalid Local Public IP: ${LOCAL_PUB_IP}${NC}"

        read -p "Press Enter to return..."

        return
    fi

    # ----------------- Remote Public IP -----------------

    while true; do

        read -p "Remote Server Public IP: " REMOTE_PUB_IP

        if [ -n "$REMOTE_PUB_IP" ]; then
            break
        fi

        echo -e "${RED}[!] Remote Public IP is required!${NC}"

    done

    if ! [[ "$REMOTE_PUB_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

        echo -e "${RED}[!] Invalid Remote Public IP: ${REMOTE_PUB_IP}${NC}"

        read -p "Press Enter to return..."

        return
    fi

    # ----------------- Tunnel IPs -----------------

    read -p "Local Tunnel IP with CIDR [default: ${DEF_LOCAL_IP}]: " LOCAL_TUN_IP

    LOCAL_TUN_IP=${LOCAL_TUN_IP:-$DEF_LOCAL_IP}

    read -p "Remote Tunnel IP [default: ${DEF_REMOTE_IP}]: " REMOTE_TUN_IP

    REMOTE_TUN_IP=${REMOTE_TUN_IP:-$DEF_REMOTE_IP}

    # ----------------- MTU -----------------

    read -p "MTU [default: 1400]: " MTU

    MTU=${MTU:-1400}

    # Validate MTU.
    if ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 576 ] || [ "$MTU" -gt 9000 ]; then

        echo -e "${RED}[!] Invalid MTU. Use a value between 576 and 9000.${NC}"

        read -p "Press Enter to return..."

        return
    fi

    # ----------------- GRE Module -----------------

    echo -e "\n${YELLOW}[*] Checking GRE kernel module...${NC}"

    if ! modprobe ip_gre 2>/dev/null; then

        echo -e "${RED}[!] Could not load ip_gre kernel module.${NC}"

        echo -e "${YELLOW}[*] Trying to continue anyway...${NC}"

    fi

    # ----------------- Public IP Check -----------------

    echo -e "${YELLOW}[*] Checking local public IP on this server...${NC}"

    if ! ip -4 addr show | grep -qw "$LOCAL_PUB_IP"; then

        echo -e "${RED}[!] Local IP ${LOCAL_PUB_IP} is not currently assigned to this server.${NC}"

        echo ""

        echo -e "${YELLOW}Available IPv4 addresses:${NC}"

        ip -4 addr show | grep -E "inet " || true

        echo ""

        echo -e "${YELLOW}If this VPS uses NAT, GRE may require provider support.${NC}"

        read -p "Continue anyway? [y/N]: " CONTINUE

        if [[ ! "$CONTINUE" =~ ^[yY]$ ]]; then

            return
        fi
    fi

    # ----------------- Save Config -----------------

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

    # ----------------- Watchdog -----------------

    create_gre_watchdog "${TUN_NAME}"

    # ----------------- Systemd -----------------

    create_gre_service "${TUN_NAME}"

    systemctl daemon-reload

    # ----------------- Firewall -----------------

    echo -e "${YELLOW}[*] Configuring GRE firewall...${NC}"

    # GRE = IP protocol 47
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p gre -j ACCEPT

    iptables -C FORWARD -i "${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "${TUN_NAME}" -j ACCEPT

    iptables -C FORWARD -o "${TUN_NAME}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -o "${TUN_NAME}" -j ACCEPT

    # ----------------- Start Service -----------------

    echo -e "${YELLOW}[*] Starting persistent GRE service...${NC}"

    if ! systemctl enable --now "tunnel-${TUN_NAME}.service"; then

        echo -e "${RED}"
        echo "===================================================="
        echo "          GRE SERVICE FAILED TO START"
        echo "===================================================="
        echo -e "${NC}"

        systemctl status "tunnel-${TUN_NAME}.service" \
            --no-pager \
            -l

        echo ""

        echo -e "${YELLOW}Recent logs:${NC}"

        journalctl \
            -u "tunnel-${TUN_NAME}.service" \
            -n 50 \
            --no-pager

        read -p "Press Enter to return..."

        return
    fi

    # ----------------- Wait for Interface -----------------

    echo -e "${YELLOW}[*] Waiting for GRE interface...${NC}"

    GRE_READY=0

    for i in $(seq 1 10); do

        if ip link show "${TUN_NAME}" >/dev/null 2>&1; then

            GRE_READY=1
            break

        fi

        sleep 1

    done

    if [ "$GRE_READY" != "1" ]; then

        echo -e "${RED}[!] GRE interface was not created.${NC}"

        echo ""

        systemctl status "tunnel-${TUN_NAME}.service" \
            --no-pager \
            -l

        echo ""

        journalctl \
            -u "tunnel-${TUN_NAME}.service" \
            -n 30 \
            --no-pager

        read -p "Press Enter to return..."

        return
    fi

    echo -e "${GREEN}[+] GRE interface is UP.${NC}"

    sleep 1

    show_summary "${TUN_NAME}"
}

# ====================================================
# Summary Screen
# ====================================================

show_summary() {

    local NAME=$1

    source "${CONFIG_DIR}/${NAME}.conf"

    IS_ACTIVE=$(systemctl is-active "tunnel-${TUN_NAME}.service" 2>/dev/null)

    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}             TUNNEL CREATED SUCCESSFULLY            ${NC}"
    echo -e "${GREEN}====================================================${NC}"

    echo -e "Tunnel Name       : ${CYAN}${TUN_NAME}${NC}"
    echo -e "Protocol Type     : ${CYAN}${TYPE}${NC}"
    echo -e "Assigned Role     : ${CYAN}${ROLE}${NC}"

    if [ "$TYPE" == "GRE" ]; then

        echo -e "Local Public IP   : ${YELLOW}${LOCAL_PUB_IP}${NC}"
        echo -e "Remote Public IP  : ${YELLOW}${REMOTE_PUB_IP}${NC}"
        echo -e "Local Tunnel IP   : ${YELLOW}${LOCAL_TUN_IP}${NC}"
        echo -e "Remote Tunnel IP  : ${YELLOW}${REMOTE_TUN_IP}${NC}"
        echo -e "MTU Size          : ${YELLOW}${MTU}${NC}"
        echo -e "GRE Protocol      : ${YELLOW}IP 47${NC}"

    else

        [ "$ROLE" == "SERVER" ] && \
            echo -e "MWS Listen Port   : ${YELLOW}${TUN_PORT}${NC}"

        [ "$ROLE" == "CLIENT" ] && \
            echo -e "Forwarded Port    : ${YELLOW}${APP_PORT} -> ${TUN_PORT}${NC}"

        [ "$ROLE" == "CLIENT" ] && \
            echo -e "Target IP on exit : ${YELLOW}${TARGET_IP}${NC}"

    fi

    echo -e "Systemd Service   : ${CYAN}tunnel-${TUN_NAME}.service${NC}"

    if [ "$IS_ACTIVE" == "active" ]; then

        echo -e "Current Status    : ${GREEN}Active & Running (UP)${NC}"

    else

        echo -e "Current Status    : ${RED}Service Failed - Check Logs${NC}"

    fi

    echo -e "${GREEN}====================================================${NC}\n"

    read -p "Press Enter to return to main menu..."
}

# ====================================================
# List Tunnels
# ====================================================

list_tunnels() {

    clear

    echo -e "${CYAN}=== Configured Tunnels Overview ===${NC}\n"

    get_config_files

    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then

        echo -e "${YELLOW}No tunnels configured yet.${NC}"

    else

        printf "%-12s %-10s %-10s %-25s %-14s\n" \
            "NAME" "TYPE" "ROLE" "KEY INFO" "STATUS"

        echo "----------------------------------------------------------------------"

        for conf in "${CONFIG_FILES[@]}"; do

            source "$conf"

            STATUS=$(systemctl is-active "tunnel-${TUN_NAME}.service" 2>/dev/null)

            if [ "$STATUS" == "active" ]; then

                STATUS_COLOR="${GREEN}active (up)${NC}"

            else

                STATUS_COLOR="${RED}inactive${NC}"

            fi

            if [ "$TYPE" == "GOST_PF" ]; then

                if [ "$ROLE" == "SERVER" ]; then
                    INFO="Listen: ${TUN_PORT}"
                else
                    INFO="Port: ${APP_PORT} -> ${TUN_PORT}"
                fi

            else

                INFO="${LOCAL_TUN_IP} -> ${REMOTE_TUN_IP}"

            fi

            printf "%-12s %-10s %-10s %-25s %b\n" \
                "$TUN_NAME" \
                "$TYPE" \
                "$ROLE" \
                "$INFO" \
                "$STATUS_COLOR"

        done
    fi

    echo ""

    read -p "Press Enter to return..."
}

# ====================================================
# GRE Ping Test
# ====================================================

test_ping() {

    clear

    echo -e "${CYAN}=== Tunnel Connectivity Test (Ping) ===${NC}\n"

    get_config_files

    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then

        echo -e "${YELLOW}No tunnels available to test.${NC}"

        read -p "Press Enter to return..."

        return
    fi

    echo -e "${YELLOW}Select a tunnel to ping (GRE L3 only):${NC}"

    VALID_INDEXES=()

    for i in "${!CONFIG_FILES[@]}"; do

        source "${CONFIG_FILES[$i]}"

        if [ "$TYPE" == "GOST_PF" ]; then

            echo -e " ${RED}X)${NC} ${TUN_NAME} [GOST] -> Port Forwarding has no L3 IP to ping"

        else

            echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] -> Ping Target: ${YELLOW}${REMOTE_TUN_IP}${NC}"

            VALID_INDEXES+=($((i+1)))

        fi

    done

    echo -e " ${YELLOW}0)${NC} Back to Main Menu\n"

    read -p "Select number [0 to exit]: " SEL

    if [[ " ${VALID_INDEXES[*]} " =~ " ${SEL} " ]]; then

        source "${CONFIG_FILES[$((SEL-1))]}"

        echo ""

        echo -e "${YELLOW}[*] GRE interface status:${NC}"

        ip -d link show "${TUN_NAME}" 2>/dev/null || true

        echo ""

        echo -e "${YELLOW}[*] Route:${NC}"

        ip route get "${REMOTE_TUN_IP}" 2>/dev/null || true

        echo ""

        echo -e "${YELLOW}[*] Sending 4 packets to ${REMOTE_TUN_IP} via ${TUN_NAME}...${NC}\n"

        ping -I "${TUN_NAME}" -c 4 -W 2 "${REMOTE_TUN_IP}"

        echo ""

        echo -e "${GREEN}[+] Ping test finished.${NC}"

    fi

    read -p "Press Enter to return..."
}

# ====================================================
# Delete Tunnel
# ====================================================

delete_tunnel() {

    clear

    echo -e "${RED}=== Delete Tunnel ===${NC}\n"

    get_config_files

    if [ ${#CONFIG_FILES[@]} -eq 0 ]; then

        echo -e "${YELLOW}No tunnels found to delete.${NC}"

        read -p "Press Enter to return..."

        return
    fi

    echo -e "${YELLOW}Select a tunnel to DELETE:${NC}"

    for i in "${!CONFIG_FILES[@]}"; do

        source "${CONFIG_FILES[$i]}"

        echo -e " ${GREEN}$((i+1)))${NC} ${CYAN}${TUN_NAME}${NC} [${TYPE}] Role: ${ROLE}"

    done

    echo -e " ${YELLOW}0)${NC} Cancel & Back\n"

    read -p "Select number [1-${#CONFIG_FILES[@]}, 0 to cancel]: " SEL

    if [[ "$SEL" =~ ^[0-9]+$ ]] && \
       [ "$SEL" -ge 1 ] && \
       [ "$SEL" -le "${#CONFIG_FILES[@]}" ]; then

        CONF_FILE="${CONFIG_FILES[$((SEL-1))]}"

        source "$CONF_FILE"

        read -p "Are you sure you want to delete '${TUN_NAME}'? [y/N]: " CONFIRM

        if [[ "$CONFIRM" =~ ^[yY]$ ]]; then

            systemctl stop "tunnel-${TUN_NAME}.service" >/dev/null 2>&1

            systemctl disable "tunnel-${TUN_NAME}.service" >/dev/null 2>&1

            rm -f "/etc/systemd/system/tunnel-${TUN_NAME}.service"

            rm -f "/usr/local/sbin/tunnel-gre-${TUN_NAME}.sh"

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

# ====================================================
# Optimize System
# ====================================================

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

# ====================================================
# Main Menu
# ====================================================

install_prerequisites

while true; do

    clear

    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}       Tunnel Manager (GRE Classic & GOST MWS)      ${NC}"
    echo -e "${CYAN}====================================================${NC}"

    echo -e "${YELLOW}1)${NC} Create GOST Tunnel (Secure Port Forward MWS)"
    echo -e "${YELLOW}2)${NC} Create GRE Tunnel (Persistent Raw L3)"
    echo -e "${YELLOW}3)${NC} List All Tunnels & Status"
    echo -e "${YELLOW}4)${NC} Ping Connectivity Test (GRE Only)"
    echo -e "${YELLOW}5)${NC} Delete a Tunnel"
    echo -e "${YELLOW}6)${NC} Optimize Network (Enable BBR)"

    echo -e "${YELLOW}0)${NC} Exit"

    echo -e "${CYAN}====================================================${NC}"

    read -p "Choose an option [0-6]: " OPTION

    case $OPTION in

        1)
            create_gost_pf
            ;;

        2)
            create_gre_tunnel
            ;;

        3)
            list_tunnels
            ;;

        4)
            test_ping
            ;;

        5)
            delete_tunnel
            ;;

        6)
            optimize_system
            ;;

        0)
            clear
            exit 0
            ;;

        *)
            echo -e "${RED}[!] Invalid option!${NC}"
            sleep 1
            ;;

    esac

done
