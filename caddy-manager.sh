#!/usr/bin/env bash
set -e

# -------------------
# 彩色输出函数
# -------------------
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

# -------------------
# 系统识别 & 安装依赖
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
    local deps=(curl sudo lsof host)
    local to_install=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            to_install+=("$dep")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        info "所有依赖已安装"
        return
    fi

    info "安装缺失依赖: ${to_install[*]}"
    case "$OS" in
        debian|ubuntu)
            sudo apt update
            sudo apt install -y "${to_install[@]}"
            ;;
        centos|rhel|fedora)
            sudo yum install -y "${to_install[@]}" || sudo dnf install -y "${to_install[@]}"
            ;;
        alpine)
            sudo apk add --no-cache "${to_install[@]}"
            ;;
        *)
            error "不支持的系统: $OS"
            exit 1
            ;;
    esac
}

# -------------------
# 检测端口占用
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
# 检查域名解析
# -------------------
check_domain() {
    local domain="$1"
    if ! command -v host >/dev/null 2>&1; then
        warn "host 命令未安装，跳过域名解析检查"
        return
    fi
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
# 安装 Caddy（最新版）
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

    # 检查域名解析
    check_domain "$DOMAIN"

    # 检查端口占用
    HTTP_FREE=1
    HTTPS_FREE=1
    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            [ $port -eq 80 ] && HTTP_FREE=0
            [ $port -eq 443 ] && HTTPS_FREE=0
        fi
    done
    if [ $HTTP_FREE -eq 0 ] && [ $HTTPS_FREE -eq 0 ] && [ -z "$CF_TOKEN" ]; then
        error "80/443端口被占用且未提供 Cloudflare API Token，无法申请证书"
        exit 1
    fi

    # 安装最新版 Caddy
    info "安装最新版 Caddy"
    curl -fsSL https://getcaddy.com | bash -s personal

    if ! command -v caddy >/dev/null 2>&1; then
        error "Caddy 安装失败，未找到可执行文件"
        exit 1
    fi

    # 生成 Caddyfile
    CADDYFILE="/etc/caddy/Caddyfile"
    sudo mkdir -p /etc/caddy /etc/ssl/caddy
    sudo chown -R root:www-data /etc/caddy
    sudo chown -R www-data:root /etc/ssl/caddy
    sudo chmod 0770 /etc/ssl/caddy

    CADDY_CONFIG="${DOMAIN} {
    encode gzip
    reverse_proxy ${UPSTREAM} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Port {server_port}
        header_up X-Forwarded-Proto {scheme}
    }"

    if [ $HTTP_FREE -eq 1 ]; then
        info "使用 HTTP-01 验证"
        CADDY_CONFIG+="
    tls ${EMAIL}"
    elif [ $HTTPS_FREE -eq 1 ]; then
        info "使用 TLS-ALPN-01 验证"
        CADDY_CONFIG+="
    tls ${EMAIL} {
        alpn tls
    }"
    else
        info "使用 DNS-01 验证"
        CADDY_CONFIG+="
    tls {
        dns cloudflare ${CF_TOKEN}
        email ${EMAIL}
    }"
    fi

    CADDY_CONFIG+="
}"

    echo "$CADDY_CONFIG" | sudo tee "$CADDYFILE" >/dev/null

    # 验证 Caddyfile
    if ! sudo caddy validate --config "$CADDYFILE"; then
        error "Caddyfile 语法错误"
        exit 1
    fi

    # 启动 Caddy
    sudo systemctl enable caddy
    sudo systemctl restart caddy
    info "Caddy 已启动并设置开机自启"

    # 简单检查证书
    sleep 5
    CERTS=$(sudo caddy list-certificates 2>/dev/null || true)
    if echo "$CERTS" | grep -q "$DOMAIN"; then
        info "证书已生成"
    else
        warn "证书未找到，请检查端口、DNS 或网络"
    fi
}

# -------------------
# 服务管理
# -------------------
manage_caddy() {
    echo "1) 启动 Caddy"
    echo "2) 停止 Caddy"
    echo "3) 重启 Caddy"
    echo "4) 查看日志"
    echo "5) 查看证书状态"
    read -rp "请选择: " choice
    case $choice in
        1) sudo systemctl start caddy && info "已启动";;
        2) sudo systemctl stop caddy && info "已停止";;
        3) sudo systemctl restart caddy && info "已重启";;
        4) sudo journalctl -u caddy -f;;
        5)
            read -rp "输入域名: " dom
            CERT_PATH="/etc/ssl/caddy/acme/acme-v02.api.letsencrypt.org/sites/${dom}"
            if [ -d "$CERT_PATH" ]; then
                info "证书路径: $CERT_PATH"
                ls -l "$CERT_PATH"
            else
                warn "未找到证书"
            fi
            ;;
        *) warn "无效选择";;
    esac
}

# -------------------
# 检查状态
# -------------------
check_status() {
    if systemctl list-units --type=service | grep -q caddy.service; then
        sudo systemctl status caddy.service --no-pager || warn "状态获取失败"
    else
        warn "未检测到 Caddy 服务"
    fi
}

# -------------------
# 卸载 Caddy
# -------------------
uninstall_caddy() {
    read -rp "确认卸载 Caddy 吗？(y/n): " choice
    [[ "$choice" =~ ^[Yy]$ ]] || return
    sudo systemctl stop caddy || true
    sudo systemctl disable caddy || true
    sudo rm -rf /etc/caddy /etc/ssl/caddy /usr/local/bin/caddy
    sudo systemctl daemon-reload
    info "Caddy 已卸载"
}

# -------------------
# 主菜单
# -------------------
while true; do
    echo -e "\n==============================="
    echo "      Caddy 一键管理脚本        "
    echo "==============================="
    echo "1) 安装并配置 Caddy"
    echo "2) 检查状态"
    echo "3) 管理服务"
    echo "4) 卸载"
    echo "5) 退出"
    read -rp "请选择: " main_choice
    case $main_choice in
        1) detect_os; install_dependencies; install_caddy ;;
        2) check_status ;;
        3) manage_caddy ;;
        4) detect_os; uninstall_caddy ;;
        5) exit 0 ;;
        *) warn "无效选择";;
    esac
done
