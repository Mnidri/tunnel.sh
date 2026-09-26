#!/bin/bash
# ==========================================
# All-In-One Multi-Tunnel Manager (GOST & GRE)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="/etc/tunnel-core"
CONFIG_DIR="${BASE_DIR}/configs"
mkdir -p "${CONFIG_DIR}"

# ----------------- بررسی و نصب پیش‌نیازها -----------------
install_prerequisites() {
    clear
    echo -e "${CYAN}در حال بررسی و نصب بسته‌های مورد نیاز سیستم...${NC}"
    apt update -y >/dev/null 2>&1
    apt install -y curl wget iptables iproute2 net-tools iputils-ping dnsutils tar >/dev/null 2>&1

    # فعال‌سازی فورواردینگ پکت‌ها در هسته سیستم
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # نصب یا بررسی باینری Gost
    if [ ! -f /usr/local/bin/gost ]; then
        echo -e "${YELLOW}در حال دانلود و نصب باینری Gost...${NC}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GOST_ARCH="amd64" ;;
            aarch64) GOST_ARCH="arm64" ;;
            armv7l) GOST_ARCH="armv7" ;;
            *) echo -e "${RED}معماری سخت‌افزار ناشناخته است: $ARCH${NC}"; exit 1 ;;
        esac
        
        wget -qO /tmp/gost.tar.gz "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${GOST_ARCH}-2.11.5.tar.gz"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        rm -rf /tmp/gost*
    fi
    echo -e "${GREEN}تمام پیش‌نیازها با موفقیت مستقر شدند.${NC}\n"
    sleep 1
}

# ----------------- ساخت تانل GOST (بر بستر TCP) -----------------
create_gost_tunnel() {
    clear
    echo -e "${CYAN}=== ساخت تانل جدید GOST (TCP Layer 3 TUN) ===${NC}"
    
    echo -e "\n${YELLOW}موقعیت این سرور را انتخاب کنید:${NC}"
    echo "1) خارج (Server / Listener)"
    echo "2) ایران (Client / Forwarder)"
    read -p "انتخاب شما [1-2]: " SERVER_ROLE

    read -p "یک نام اختصاصی برای این تانل وارد کنید (مثال: tun1): " TUN_NAME
    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}خطا: تانلی با این نام از قبل وجود دارد!${NC}"
        read -p "اینتر را برای بازگشت بزنید..."; return
    fi

    read -p "پورت تبادل ترافیک TCP بین دو سرور (مثال: 8443): " PORT
    read -p "آی‌پی داخلی این سرور روی تانل همراه با ساب‌نت (مثال: 10.10.10.1/30): " LOCAL_TUN_IP
    read -p "آی‌پی داخلی سرور مقابل روی تانل بدون ساب‌نت (جهت تست پینگ، مثال: 10.10.10.2): " REMOTE_TUN_IP
    read -p "مقدار MTU (پیش‌فرض پیشنهادی: 1360): " MTU
    MTU=${MTU:-1360}

    if [ "$SERVER_ROLE" == "1" ]; then
        ROLE_NAME="KHAREJ"
        # سرور خارج منتظر اتصال سرور ایران روی پورت TCP می‌ماند
        EXEC_CMD="/usr/local/bin/gost -L \"tun://${TUN_NAME}::${PORT}?net=${LOCAL_TUN_IP}&mtu=${MTU}\""
    else
        ROLE_NAME="IRAN"
        read -p "آی‌پی پابلیک سرور خارج (Remote Public IP): " REMOTE_PUB_IP
        # سرور ایران کانکشن TCP را به خارج می‌زند
        EXEC_CMD="/usr/local/bin/gost -L \"tun://${TUN_NAME}:0?net=${LOCAL_TUN_IP}&mtu=${MTU}\" -F \"tcp://${REMOTE_PUB_IP}:${PORT}\""
    fi

    # ساخت سرویس systemd
    cat << EOF > /etc/systemd/system/tunnel-${TUN_NAME}.service
[Unit]
Description=Gost Tunnel Layer3 - ${TUN_NAME}
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '${EXEC_CMD}'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # ذخیره کانفیگ
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

    # خروجی خلاصه
    show_summary "${TUN_NAME}"
}

# ----------------- ساخت تانل GRE -----------------
create_gre_tunnel() {
    clear
    echo -e "${CYAN}=== ساخت تانل جدید GRE ===${NC}"
    
    echo -e "\n${YELLOW}موقعیت این سرور را انتخاب کنید:${NC}"
    echo "1) خارج"
    echo "2) ایران"
    read -p "انتخاب شما [1-2]: " SERVER_ROLE

    read -p "یک نام اختصاصی برای این تانل وارد کنید (مثال: gre1): " TUN_NAME
    if [ -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}خطا: تانلی با این نام از قبل وجود دارد!${NC}"
        read -p "اینتر را برای بازگشت بزنید..."; return
    fi

    read -p "آی‌پی پابلیک همین سرور (Local Public IP): " LOCAL_PUB_IP
    read -p "آی‌پی پابلیک سرور مقابل (Remote Public IP): " REMOTE_PUB_IP
    read -p "آی‌پی داخلی این سرور روی تانل همراه با ساب‌نت (مثال: 10.20.20.1/30): " LOCAL_TUN_IP
    read -p "آی‌پی داخلی سرور مقابل روی تانل بدون ساب‌نت (مثال: 10.20.20.2): " REMOTE_TUN_IP
    read -p "مقدار MTU (پیش‌فرض پیشنهادی: 1400): " MTU
    MTU=${MTU:-1400}

    ROLE_NAME="IRAN"
    [ "$SERVER_ROLE" == "1" ] && ROLE_NAME="KHAREJ"

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

# ----------------- چاپ خلاصه مشخصات تانل -----------------
show_summary() {
    local NAME=$1
    source "${CONFIG_DIR}/${NAME}.conf"
    
    echo -e "\n${GREEN}==============================================${NC}"
    echo -e "${GREEN}       تانل با موفقیت ساخته و راه‌اندازی شد       ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "شناسه تانل:        ${CYAN}${TUN_NAME}${NC}"
    echo -e "نوع پروتکل:        ${CYAN}${TYPE}${NC}"
    echo -e "نقش این سرور:      ${CYAN}${ROLE}${NC}"
    echo -e "آی‌پی داخلی سرور:   ${YELLOW}${LOCAL_TUN_IP}${NC}"
    echo -e "آی‌پی داخلی مقابل:  ${YELLOW}${REMOTE_TUN_IP}${NC}"
    [ "$TYPE" == "GOST" ] && echo -e "پورت تبادل TCP:    ${YELLOW}${PORT}${NC}"
    [ "$TYPE" == "GOST" ] && echo -e "آی‌پی مقصد خارج:    ${YELLOW}${REMOTE_PUB_IP}${NC}"
    echo -e "میزان MTU ست شده:   ${YELLOW}${MTU}${NC}"
    echo -e "سرویس Systemd:     ${CYAN}tunnel-${TUN_NAME}.service${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${YELLOW}نکته برای استفاده در Rathole یا ابزارهای دیگر:${NC}"
    echo -e "در رتهول یا هسته‌های دیگر، به جای آی‌پی پابلیک از آی‌پی ${CYAN}${REMOTE_TUN_IP}${NC} استفاده کنید."
    echo -e "${GREEN}==============================================${NC}\n"
    read -p "کلید Enter را برای ادامه فشار دهید..."
}

# ----------------- لیست تانل‌ها و وضعیت -----------------
list_tunnels() {
    clear
    echo -e "${CYAN}=== لیست تانل‌های ثبت شده ===${NC}\n"
    FILES=("${CONFIG_DIR}"/*.conf)
    if [ ! -e "${FILES[0]}" ]; then
        echo -e "${YELLOW}هیچ تانلی یافت نشد.${NC}"
    else
        printf "%-12s %-8s %-10s %-18s %-12s\n" "نام تانل" "نوع" "نقش" "آی‌پی داخلی" "وضعیت"
        echo "---------------------------------------------------------------"
        for conf in "${CONFIG_DIR}"/*.conf; do
            source "$conf"
            STATUS=$(systemctl is-active tunnel-${TUN_NAME}.service 2>/dev/null)
            if [ "$STATUS" == "active" ]; then
                STATUS_COLOR="${GREEN}فعال (Up)${NC}"
            else
                STATUS_COLOR="${RED}غیرفعال${NC}"
            fi
            printf "%-12s %-8s %-10s %-18s %b\n" "$TUN_NAME" "$TYPE" "$ROLE" "$LOCAL_TUN_IP" "$STATUS_COLOR"
        done
    fi
    echo ""
    read -p "کلید Enter را برای بازگشت بزنید..."
}

# ----------------- تست پینگ بین دو سرور -----------------
test_ping() {
    clear
    echo -e "${CYAN}=== تست پینگ و سلامت ارتباط تانل ===${NC}\n"
    read -p "نام تانل مورد نظر را وارد کنید: " TUN_NAME
    
    if [ ! -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}خطا: تانلی با نام ${TUN_NAME} یافت نشد.${NC}"
        read -p "کلید Enter را برای بازگشت بزنید..."; return
    fi

    source "${CONFIG_DIR}/${TUN_NAME}.conf"
    echo -e "\n${YELLOW}در حال ارسال ۴ بسته پینگ به آی‌پی مقابل (${REMOTE_TUN_IP})...${NC}\n"
    ping -c 4 -W 2 "${REMOTE_TUN_IP}"
    
    echo -e "\n${GREEN}تست انجام شد.${NC}"
    read -p "کلید Enter را برای بازگشت بزنید..."
}

# ----------------- حذف تانل -----------------
delete_tunnel() {
    clear
    echo -e "${RED}=== حذف تانل ===${NC}\n"
    read -p "نام تانلی که قصد حذف آن را دارید وارد کنید: " TUN_NAME

    if [ ! -f "${CONFIG_DIR}/${TUN_NAME}.conf" ]; then
        echo -e "${RED}خطا: چنین تانلی پیدا نشد.${NC}"
        read -p "کلید Enter را برای بازگشت بزنید..."; return
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
    echo -e "\n${GREEN}تانل ${TUN_NAME} با موفقیت حذف شد و تمام ردپاهای شبکه پاکسازی شدند.${NC}"
    read -p "کلید Enter را برای بازگشت بزنید..."
}

# ----------------- بهینه‌سازی TCP BBR -----------------
optimize_system() {
    clear
    echo -e "${CYAN}=== فعال‌سازی الگوریتم ازدحام BBR ===${NC}"
    modprobe tcp_bbr 2>/dev/null
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}الگوریتم BBR با موفقیت روی سیستم فعال شد.${NC}"
    read -p "کلید Enter را برای بازگشت بزنید..."
}

# ----------------- چرخه منوی اصلی -----------------
install_prerequisites

while true; do
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}       مدیریت چندتانله سرور (GOST & GRE)       ${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${YELLOW}1)${NC} ساخت تانل GOST (بر بستر TCP Mux - ضد لیمیت)"
    echo -e "${YELLOW}2)${NC} ساخت تانل GRE (ساده و خام)"
    echo -e "${YELLOW}3)${NC} لیست تانل‌ها و بررسی وضعیت"
    echo -e "${YELLOW}4)${NC} تست پینگ ارتباط تانل"
    echo -e "${YELLOW}5)${NC} حذف یک تانل"
    echo -e "${YELLOW}6)${NC} بهینه‌سازی شبکه لینوکس (BBR)"
    echo -e "${YELLOW}0)${NC} خروج"
    echo -e "${CYAN}==============================================${NC}"
    read -p "گزینه مورد نظر را وارد کنید: " OPTION

    case $OPTION in
        1) create_gost_tunnel ;;
        2) create_gre_tunnel ;;
        3) list_tunnels ;;
        4) test_ping ;;
        5) delete_tunnel ;;
        6) optimize_system ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر است!${NC}"; sleep 1 ;;
    esac
done
