#!/usr/bin/env bash
set -e

# -------------------
# 彩色输出函数
# -------------------
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; RESET="\033[0m"
info() { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

# -------------------
# 系统识别
# -------------------
detect_os() {
    [[ -f /etc/os-release ]] && . /etc/os-release || { error "无法识别操作系统"; exit 1; }
    OS="$ID"; VERSION="$VERSION_ID"
}

# -------------------
# 安装依赖
# -------------------
install_dependencies() {
    local deps=(curl sudo lsof host gnupg)
    local to_install=()
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null || to_install+=("$dep"); done
    [[ ${#to_install[@]} -eq 0 ]] && { info "所有依赖已安装"; return; }
    info "检测到缺失依赖: ${to_install[*]}"
    case "$OS" in
        debian|ubuntu) sudo apt update && sudo apt install -y "${to_install[@]}";;
        centos|rhel|fedora) command -v dnf >/dev/null && sudo dnf install -y "${to_install[@]}" || sudo yum install -y "${to_install[@]}";;
        alpine) sudo apk add --no-cache "${to_install[@]}";;
        *) error "不支持的系统: $OS"; exit 1;;
    esac
}

# -------------------
# 检查端口占用
# -------------------
check_ports() {
    local conflict=0
    for port in 80 443; do
        if info=$(sudo lsof -i :"$port" -Pn -sTCP:LISTEN 2>/dev/null); then
            [ -n "$info" ] && { warn "端口 $port 被占用:"; echo "$info" | awk 'NR>1 {print "  PID="$2", 用户="$3", 命令="$1}'; conflict=1; }
        fi
    done
    return $conflict
}

# -------------------
# 检查域名解析
# -------------------
check_domain() {
    local domain="$1"
    [[ ! $(command -v host) ]] && { warn "未检测到 host 命令，跳过域名解析检查"; return; }
    local ip=$(curl -s ifconfig.me)
    if host "$domain" | grep -q "$ip"; then info "域名 $domain 已解析到当前服务器 IP ($ip)"; 
    else warn "域名 $domain 未解析到当前服务器 IP ($ip)"; read -rp "是否继续安装？(y/n): " choice; [[ "$choice" =~ ^[Yy]$ ]] || exit 1; fi
}

# -------------------
# 安装并配置 Caddy
# -------------------
install_caddy() {
    info "安装并配置 Caddy"

    read -rp "域名: " DOMAIN
    read -rp "邮箱: " EMAIL
    read -rp "后端 (例如127.0.0.1:8888): " UPSTREAM
    read -rp "Cloudflare API Token (可留空手动 DNS-01): " CF_TOKEN
    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

    echo -e "\n您输入的信息:\n域名: $DOMAIN\n邮箱: $EMAIL\n后端: $UPSTREAM"
    check_domain "$DOMAIN"

    HTTP_FREE=1; HTTPS_FREE=1
    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            warn "端口 $port 已被占用"
            [ $port -eq 80 ] && HTTP_FREE=0; [ $port -eq 443 ] && HTTPS_FREE=0
        fi
    done
    [[ $HTTP_FREE -eq 0 && $HTTPS_FREE -eq 0 && -z "$CF_TOKEN" ]] && { error "80/443端口被占用且未提供CF Token，无法申请证书"; exit 1; }

    # 安装最新版 Caddy 官方脚本
    info "安装最新版 Caddy"
    curl -1sLf 'https://getcaddy.com' | bash -s personal
    export PATH=$PATH:/usr/local/bin

    # 创建 Caddyfile
    sudo mkdir -p /etc/caddy /etc/ssl/caddy
    sudo chown -R root:www-data /etc/caddy
    sudo chown -R www-data:root /etc/ssl/caddy
    sudo chmod 0770 /etc/ssl/caddy

    CADDYFILE="${DOMAIN} {\n encode gzip\n reverse_proxy ${UPSTREAM} {\n header_up X-Real-IP {remote_host}\n header_up X-Forwarded-For {remote_host}\n header_up X-Forwarded-Port {server_port}\n header_up X-Forwarded-Proto {scheme}\n }"

    if [ $HTTP_FREE -eq 1 ]; then info "使用 HTTP-01 验证"; CADDYFILE+="\n tls ${EMAIL}"
    elif [ $HTTPS_FREE -eq 1 ]; then info "使用 TLS-ALPN-01 验证"; CADDYFILE+="\n tls ${EMAIL} { alpn tls }"
    else info "使用 DNS-01 验证"; CADDYFILE+="\n tls { dns cloudflare ${CF_TOKEN} email ${EMAIL} }"; fi
    CADDYFILE+="\n}"

    echo -e "$CADDYFILE" | sudo tee /etc/caddy/Caddyfile >/dev/null

    # 验证并启动
    sudo caddy validate --config /etc/caddy/Caddyfile || { warn "Caddyfile语法错误"; exit 1; }
    sudo systemctl enable caddy
    sudo systemctl restart caddy
    info "Caddy 已启动并开机自启"

    sleep 5
    CERT=$(sudo /usr/local/bin/caddy list certs 2>/dev/null | grep "$DOMAIN" | awk '{print $1}')
    [[ -n "$CERT" ]] && info "证书生成成功: $CERT" || warn "证书未找到，请检查网络/端口"

    info "查看服务: sudo systemctl status caddy.service"
    info "查看日志: sudo journalctl -xeu caddy.service"
}

# -------------------
# 检查状态
# -------------------
check_status() {
    echo "======= Caddy 服务状态 ======="
    systemctl list-units --type=service | grep -q caddy.service && sudo systemctl status caddy.service --no-pager || warn "未检测到 Caddy 服务"
}

# -------------------
# 管理 Caddy
# -------------------
manage_caddy() {
    echo "======= 管理 Caddy 服务 ======="
    echo "1) 启动 2) 停止 3) 重启 4) 实时日志 5) 证书状态"
    read -rp "选择: " choice
    case $choice in
        1) sudo systemctl start caddy && info "Caddy 已启动";;
        2) sudo systemctl stop caddy && info "Caddy 已停止";;
        3) sudo systemctl restart caddy && info "Caddy 已重启";;
        4) sudo journalctl -u caddy -f;;
        5) read -rp "域名: " dom; CERT_PATH="/etc/ssl/caddy/acme/acme-v02.api.letsencrypt.org/sites/${dom}"
           [[ -d "$CERT_PATH" ]] && { info "证书路径: $CERT_PATH"; ls -l "$CERT_PATH"; } || warn "证书未找到";;
        *) warn "无效选择";;
    esac
}

# -------------------
# 卸载 Caddy
# -------------------
uninstall_caddy() {
    echo "======= 卸载 Caddy ======="
    read -rp "确认卸载? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
    sudo systemctl stop caddy || true
    sudo systemctl disable caddy || true
    sudo rm -f /etc/systemd/system/caddy.service
    sudo rm -rf /etc/caddy /etc/ssl/caddy /usr/local/bin/caddy
    sudo systemctl daemon-reload
    case "$OS" in
        debian|ubuntu) sudo apt remove --purge -y caddy || true;;
        centos|rhel|fedora) sudo dnf remove -y caddy || sudo yum remove -y caddy || true;;
        alpine) sudo apk del caddy || true;;
    esac
    info "Caddy 已彻底卸载"
}

# -------------------
# 主菜单
# -------------------
while true; do
    echo -e "\n======= Caddy 一键管理脚本 ======="
    echo "1) 安装并配置 Caddy"
    echo "2) 检查状态"
    echo "3) 管理服务"
    echo "4) 卸载"
    echo "5) 退出"
    read -rp "选择: " main_choice
    case $main_choice in
        1) detect_os; install_dependencies; install_caddy ;;
        2) check_status ;;
        3) manage_caddy ;;
        4) detect_os; uninstall_caddy ;;
        5) exit 0 ;;
        *) warn "无效选择";;
    esac
done
