#!/usr/bin/env bash
set -e

# -------------------
# 彩色输出函数
# -------------------
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[0;34m"
PURPLE="\033[1;35m"
RESET="\033[0m"

info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

# -------------------
# 系统识别 & 依赖安装
# -------------------
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="$ID"
        VERSION="$VERSION_ID"
    else
        error "无法识别操作系统"
        exit 1
    fi
}

install_dependencies() {
    local deps=(curl sudo lsof host gnupg apt-transport-https)
    local to_install=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            to_install+=("$dep")
        fi
    done
    if [ ${#to_install[@]} -gt 0 ]; then
        info "安装缺失依赖: ${to_install[*]}"
        case "$OS" in
            debian|ubuntu)
                sudo apt update
                sudo apt install -y "${to_install[@]}"
                ;;
            *)
                error "不支持的系统: $OS"
                exit 1
                ;;
        esac
    else
        info "所有依赖已安装"
    fi
}

# -------------------
# 端口检测
# -------------------
check_ports() {
    HTTP_FREE=1
    HTTPS_FREE=1
    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            warn "端口 $port 已被占用"
            if [ "$port" -eq 80 ]; then
                HTTP_FREE=0
            elif [ "$port" -eq 443 ]; then
                HTTPS_FREE=0
            fi
        fi
    done
    info "端口检测结果：HTTP_FREE=$HTTP_FREE, HTTPS_FREE=$HTTPS_FREE"
}

# -------------------
# 域名解析检测
# -------------------
check_domain() {
    local domain="$1"
    local ip
    ip=$(curl -s ifconfig.me)
    if host "$domain" | grep -q "$ip"; then
        info "域名 $domain 已解析到当前服务器 IP ($ip)"
    else
        warn "域名 $domain 未解析到当前服务器 IP ($ip)"
        read -rp "是否继续安装？(y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi
}

# -------------------
# 安装 Caddy 并生成 Caddyfile
# -------------------
install_caddy() {
    info "开始安装并配置 Caddy"

    read -rp "请输入绑定的域名: " DOMAIN
    read -rp "请输入用于申请证书的邮箱: " EMAIL
    read -rp "请输入反向代理目标地址 (例如 127.0.0.1:8888): " UPSTREAM
    read -rp "请输入 Cloudflare API Token (可留空使用 HTTP/DNS 验证): " CF_TOKEN
    read -rp "是否使用 Let’s Encrypt 测试环境 (避免限额, y/n): " TEST_MODE

    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

    echo -e "\n您输入的信息如下："
    echo "域名: $DOMAIN"
    echo "邮箱: $EMAIL"
    echo "后端: $UPSTREAM"

    check_domain "$DOMAIN"
    check_ports

    # 安装官方 apt 源 Caddy
    info "安装最新版 Caddy"
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy || { error "Caddy 安装失败"; exit 1; }

    # 创建目录权限
    sudo mkdir -p /etc/caddy /etc/ssl/caddy
    sudo chown -R root:www-data /etc/caddy
    sudo chown -R www-data:root /etc/ssl/caddy
    sudo chmod 0770 /etc/ssl/caddy

    # -------------------
    # 生成 Caddyfile
    # -------------------
    CADDYFILE="${DOMAIN} {
    encode gzip
    reverse_proxy ${UPSTREAM} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Port {server_port}
    }"

    # -------------------
    # 证书逻辑：优先 DNS-01 -> HTTP-01 -> TLS-ALPN-01
    # -------------------
    if [[ -n "$CF_TOKEN" ]]; then
        info "使用 DNS-01 验证 (Cloudflare Token)"
        export CF_API_TOKEN="$CF_TOKEN"
        CADDYFILE+="
    tls {
        dns cloudflare {env.CF_API_TOKEN}"
        if [[ "$TEST_MODE" =~ ^[Yy]$ ]]; then
            CADDYFILE+="
        ca https://acme-staging-v02.api.letsencrypt.org/directory"
        fi
        CADDYFILE+="
    }"
    else
        if [ "$HTTP_FREE" -eq 1 ] && [ "$HTTPS_FREE" -eq 1 ]; then
            info "80/443 端口均可用，使用 HTTP-01 (推荐)"
            if [[ "$TEST_MODE" =~ ^[Yy]$ ]]; then
                CADDYFILE+="
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }"
            else
                CADDYFILE+="
    tls ${EMAIL}"
            fi
        elif [ "$HTTP_FREE" -eq 1 ]; then
            info "仅 80 端口可用，使用 HTTP-01"
            if [[ "$TEST_MODE" =~ ^[Yy]$ ]]; then
                CADDYFILE+="
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }"
            else
                CADDYFILE+="
    tls ${EMAIL}"
            fi
        elif [ "$HTTPS_FREE" -eq 1 ]; then
            info "仅 443 端口可用，使用 TLS-ALPN-01"
            if [[ "$TEST_MODE" =~ ^[Yy]$ ]]; then
                CADDYFILE+="
    tls {
        alpn tls-alpn-01
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }"
            else
                CADDYFILE+="
    tls ${EMAIL} {
        alpn tls-alpn-01
    }"
            fi
        else
            error "80/443 端口均被占用，无法申请证书"
            error "请提供 Cloudflare Token 以使用 DNS-01 方式"
            exit 1
        fi
    fi

    CADDYFILE+="
}"

    # 写入 Caddyfile 并验证
    echo "$CADDYFILE" | sudo tee /etc/caddy/Caddyfile >/dev/null
    sudo caddy validate --config /etc/caddy/Caddyfile || { warn "Caddyfile 语法错误"; exit 1; }
    sudo systemctl enable
    sudo systemctl restart caddy
    info "Caddy 已启动并开机自启"

    # 等待证书生成
    if [[ "$TEST_MODE" =~ ^[Yy]$ ]]; then
        CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory/${DOMAIN}/"
    else
        CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN}/"
    fi
    info "等待证书生成..."
    for i in {1..20}; do
        if [ -d "$CERT_DIR" ] && [ "$(ls -A $CERT_DIR 2>/dev/null)" ]; then
            info "证书已生成！"
            break
        fi
        sleep 5
    done
}

# -------------------
# 服务管理
# -------------------
manage_caddy() {
    echo -e "\n${BLUE}========================================${RESET}"
    echo -e "${BLUE}              Caddy 服务管理            ${RESET}"
    echo -e "${BLUE}========================================${RESET}"
    echo "1) 启动 Caddy"
    echo "2) 停止 Caddy"
    echo "3) 重启 Caddy"
    echo "4) 查看实时日志"
    echo "5) 查看证书文件"
    read -rp "请选择操作: " choice
    case $choice in
        1) sudo systemctl start caddy && info "Caddy 已启动";;
        2) sudo systemctl stop caddy && info "Caddy 已停止";;
        3) sudo systemctl restart caddy && info "Caddy 已重启";;
        4) sudo journalctl -u caddy -f;;
        5)
            read -rp "请输入域名: " dom
            CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"
            if [ -d "$CERT_DIR" ]; then
                find "$CERT_DIR" -type f \( -name "${dom}*.crt" -o -name "${dom}*.key" \)
            else
                warn "证书目录不存在: $CERT_DIR"
            fi
            ;;
        *) warn "无效选择";;
    esac
}

# -------------------
# 卸载 Caddy
# -------------------
uninstall_caddy() {
    echo -e "\n${BLUE}========================================${RESET}"
    echo -e "${BLUE}            卸载 Caddy 并清理           ${RESET}"
    echo -e "${BLUE}========================================${RESET}"
    read -rp "确认卸载 Caddy 吗？(y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    sudo systemctl stop caddy || true
    sudo systemctl disable caddy || true
    sudo rm -f /etc/systemd/system/caddy.service
    sudo rm -rf /etc/caddy /etc/ssl/caddy /usr/local/bin/caddy /etc/apt/sources.list.d/caddy-stable.list
    sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    sudo apt remove --purge -y caddy || true
    sudo systemctl daemon-reload
    info "Caddy 已彻底卸载"
}

# -------------------
# 主菜单
# -------------------
while true; do
    echo -e "\n${BLUE}========================================${RESET}"
    echo -e "      Caddy 一键管理脚本 ${PURPLE}by${RESET}:千狐       "
    echo -e "${BLUE}========================================${RESET}"
    echo "1) 安装并配置 Caddy"
    echo "2) 检查 Caddy 状态"
    echo "3) 管理 Caddy 服务"
    echo "4) 卸载 Caddy"
    echo "5) 退出"
    read -rp "请选择操作: " choice
    case $choice in
        1) detect_os; install_dependencies; install_caddy ;;
        2) systemctl status caddy --no-pager || warn "Caddy 未运行" ;;
        3) manage_caddy ;;
        4) detect_os; uninstall_caddy ;;
        5) exit 0 ;;
        *) warn "无效选择" ;;
    esac
done
