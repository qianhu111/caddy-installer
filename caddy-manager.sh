#!/usr/bin/env bash
set -e

# -------------------
# 彩色输出函数
# -------------------
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
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
    local conflict=0
    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            warn "端口 $port 已被占用"
            conflict=1
        fi
    done
    return $conflict
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
# 安装最新版 Caddy
# -------------------
install_caddy() {
    info "开始安装并配置 Caddy"

    # 用户输入
    read -rp "请输入要绑定的域名: " DOMAIN
    read -rp "请输入用于申请证书的邮箱: " EMAIL
    read -rp "请输入反向代理目标地址 (例如 127.0.0.1:8888): " UPSTREAM
    read -rp "请输入 Cloudflare API Token (可留空手动 DNS-01): " CF_TOKEN

    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

    echo -e "\n您输入的信息如下："
    echo "域名: $DOMAIN"
    echo "邮箱: $EMAIL"
    echo "后端: $UPSTREAM"

    # 域名解析
    check_domain "$DOMAIN"

    # 检查端口占用
    HTTP_FREE=1; HTTPS_FREE=1
    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            [ $port -eq 80 ] && HTTP_FREE=0
            [ $port -eq 443 ] && HTTPS_FREE=0
        fi
    done

    if [ $HTTP_FREE -eq 0 ] && [ $HTTPS_FREE -eq 0 ] && [ -z "$CF_TOKEN" ]; then
        error "80/443端口都被占用且未提供 Cloudflare Token，无法申请证书"
        exit 1
    fi

    # 安装 Caddy via 官方 apt 源
    info "使用官方 apt 源安装 Caddy"
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy || { error "Caddy 安装失败"; exit 1; }

    # 生成 Caddyfile
    sudo mkdir -p /etc/caddy /etc/ssl/caddy
    sudo chown -R root:www-data /etc/caddy
    sudo chown -R www-data:root /etc/ssl/caddy
    sudo chmod 0770 /etc/ssl/caddy

    CADDYFILE="${DOMAIN} {
    encode gzip
    reverse_proxy ${UPSTREAM} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Port {server_port}
        header_up X-Forwarded-Proto {scheme}
    }"

    if [ $HTTP_FREE -eq 1 ]; then
        info "使用 HTTP-01 验证"
        CADDYFILE+="
    tls ${EMAIL}"
    elif [ $HTTPS_FREE -eq 1 ]; then
        info "使用 TLS-ALPN-01 验证"
        CADDYFILE+="
    tls ${EMAIL} {
        alpn tls
    }"
    else
        info "使用 DNS-01 验证"
        CADDYFILE+="
    tls {
        dns cloudflare ${CF_TOKEN}
        email ${EMAIL}
    }"
    fi

    CADDYFILE+="
}"

    echo "$CADDYFILE" | sudo tee /etc/caddy/Caddyfile >/dev/null

    # 验证并启动
    sudo caddy validate --config /etc/caddy/Caddyfile || { warn "Caddyfile 语法错误"; exit 1; }
    sudo systemctl enable --now caddy
    info "Caddy 已启动并设置开机自启"
}

# -------------------
# 主菜单
# -------------------
while true; do
    echo -e "\n==============================="
    echo "      Caddy 一键管理脚本        "
    echo "==============================="
    echo "1) 安装并配置 Caddy"
    echo "2) 检查 Caddy 状态"
    echo "3) 卸载 Caddy"
    echo "4) 退出"
    read -rp "请选择操作: " choice
    case $choice in
        1) detect_os; install_dependencies; install_caddy ;;
        2) systemctl status caddy --no-pager || warn "Caddy 未运行" ;;
        3)
            read -rp "确认卸载 Caddy 吗？(y/n): " c
            [[ "$c" =~ ^[Yy]$ ]] || continue
            sudo systemctl stop caddy || true
            sudo systemctl disable caddy || true
            sudo rm -rf /etc/caddy /etc/ssl/caddy /usr/local/bin/caddy /etc/apt/sources.list.d/caddy-stable.list
            sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            sudo systemctl daemon-reload
            info "Caddy 已卸载"
            ;;
        4) exit 0 ;;
        *) warn "无效选择" ;;
    esac
done
