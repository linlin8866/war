#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  WARP 一键脚本 —— Google 自动分流 (TCP+UDP)     ║"
    echo "║          适配 Ubuntu 22.04 / Debian 11+          ║"
    echo "║           含开机自启 · 管理命令 warp             ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

[[ $EUID -ne 0 ]] && echo -e "${RED}请用 root 运行${NC}" && exit 1

. /etc/os-release
OS=$ID
CODENAME=${VERSION_CODENAME:-jammy}
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)

# 修复包管理环境
fix_apt() {
    echo -e "${CYAN}[前置] 修复包管理环境${NC}"
    dpkg --configure -a >/dev/null 2>&1
    apt -f install -y >/dev/null 2>&1
    apt update -y >/dev/null 2>&1
}

# 1. 安装 Cloudflare WARP 官方客户端
install_warp() {
    echo -e "${CYAN}[1/5] 安装 Cloudflare WARP 官方客户端${NC}"
    if [[ "$OS" =~ ubuntu|debian ]]; then
        apt install -y gnupg curl lsb-release >/dev/null 2>&1
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" > /etc/apt/sources.list.d/cloudflare-client.list
        apt update -y >/dev/null 2>&1
        apt install -y cloudflare-warp >/dev/null 2>&1
    fi

    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
    sleep 2
}

# 2. 安装 redsocks (支持 UDP)
install_deps() {
    echo -e "${CYAN}[2/5] 安装 redsocks (支持UDP)${NC}"
    if [[ "$OS" =~ ubuntu|debian ]]; then
        apt install -y redsocks iptables iptables-persistent >/dev/null 2>&1
    elif [[ "$OS" =~ centos|rhel|rocky|almalinux|fedora ]]; then
        if command -v dnf &>/dev/null; then
            dnf install -y redsocks iptables >/dev/null 2>&1
        else
            yum install -y redsocks iptables >/dev/null 2>&1
        fi
    fi
}

# 3. 配置 redsocks (TCP+UDP)
setup_redsocks() {
    cat > /etc/redsocks.conf << 'EOF'
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}

redudp {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}
EOF
}

# 4. 配置 Google 分流规则 (TCP+UDP)
setup_iptables() {
    echo -e "${CYAN}[3/5] 配置 Google 分流规则${NC}"

    GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    iptables -t nat -N WARP_GOOGLE

    for ip in $GOOGLE_IPS; do
        iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
        iptables -t nat -A WARP_GOOGLE -d $ip -p udp --dport 53 -j REDIRECT --to-ports 12345
    done

    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_GOOGLE

    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
    grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf || echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
}

# 5. 生成管理命令 + 开机自启
make_service() {
    echo -e "${CYAN}[4/5] 生成管理工具${NC}"

    cat > /usr/local/bin/warp-google << 'EOF'
#!/bin/bash
case "$1" in
    start)
        pkill redsocks 2>/dev/null
        redsocks -c /etc/redsocks.conf
        ;;
    stop)
        pkill redsocks 2>/dev/null
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
esac
EOF
    chmod +x /usr/local/bin/warp-google

    cat > /usr/local/bin/warp << 'EOF'
#!/bin/bash
case "$1" in
    start)
        warp-cli connect
        /usr/local/bin/warp-google start
        ;;
    stop)
        /usr/local/bin/warp-google stop
        warp-cli disconnect
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        echo -e "WARP 状态: $(warp-cli status)"
        echo -e "redsocks 状态: $(pgrep redsocks >/dev/null && echo "运行中" || echo "停止")"
        ;;
    ip)
        echo "直连IP: $(curl -4s ip.sb)"
        echo "WARP IP: $(curl -x socks5://127.0.0.1:40000 -4s ip.sb)"
        ;;
    test)
        curl -o /dev/null -s -w "Google 状态码: %{http_code}\n" https://www.google.com
        ;;
    uninstall)
        $0 stop
        iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
        iptables -t nat -F WARP_GOOGLE 2>/dev/null
        iptables -t nat -X WARP_GOOGLE 2>/dev/null
        apt remove -y cloudflare-warp redsocks
        rm -f /usr/local/bin/warp /usr/local/bin/warp-google /etc/redsocks.conf
        echo "卸载完成"
        ;;
    *)
        echo "用法: warp {start|stop|restart|status|ip|test|uninstall}"
        ;;
esac
EOF
    chmod +x /usr/local/bin/warp

    echo -e "${CYAN}[5/5] 配置开机自启${NC}"
    cat > /etc/systemd/system/warp-google.service << 'EOF'
[Unit]
Description=WARP Google Transparent Proxy
After=network.target warp-svc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-google.service
    systemctl enable warp-svc.service
}

# 主执行流程
do_install() {
    show_banner
    fix_apt
    install_warp
    install_deps
    setup_redsocks
    setup_iptables
    make_service
    /usr/local/bin/warp-google start
    echo -e "${GREEN}✅ 安装完成！管理命令: warp | 开机自启已启用${NC}"
}

do_install
