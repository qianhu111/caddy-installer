#!/usr/bin/env bash
set -e

# -------------------
# 彩色输出函数
# -------------------
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }

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
    local deps=(curl sudo lsof host gnupg)
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

    info "检测到缺失依赖: ${to_install[*]}"
    case "$OS" in
        debian|ubuntu)
            sudo apt update
            sudo apt install -y "${to_install[@]}"
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "${to_install[@]}"
            else
                sudo yum install -y "${to_install[@]}"
            fi
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
        local pid
        pid=$(sudo lsof -t -i :"$port" || true)
        if [ -n "$pid" ]; then
            warn "端口 $port 已被占用，进程 ID: $pid"
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
        warn "未检测到 host 命令，跳过域名解析检查"
        return
    fi

    local ip
    ip=$(curl -s ifconfig.me)
    if host "$domain" | grep -q "$ip"; then
        info "域名 $domain 已正确解析到当前服务器 IP ($ip)"
    else
        warn "域名 $domain 没有解析到当前服务器 IP ($ip)，HTTPS 可能无法申请"
        read -rp "是否继续安装？(y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi
}

# -------------------
# 安装 Caddy
# -------------------
install_caddy() {
    info "开始安装并配置 Caddy"

    # 用户输入
    read -rp "请输入要绑定的域名: " DOMAIN
    read -rp "请输入用于申请证书的邮箱: " EMAIL
    read -rp "请输入反向代理目标地址 (例如 localhost:8888): " UPSTREAM

    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

    echo -e "\n您输入的信息如下："
    echo "域名: $DOMAIN"
    echo "邮箱: $EMAIL"
    echo "后端: $UPSTREAM"

    # 检查域名解析
    check_domain "$DOMAIN"

    # 检查端口占用
    if check_ports; then
        read -rp "端口冲突可能导致启动失败，是否继续安装？(y/n): " port_choice
        [[ "$port_choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi

    # 安装 Caddy
    case "$OS" in
        debian|ubuntu)
            info "使用官方 apt 仓库安装 Caddy"
            sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                | sudo tee /etc/apt/sources.list.d/caddy-stable.list
            sudo apt update
            sudo apt install -y caddy
            ;;
        centos|rhel|fedora)
            info "使用官方 yum/dnf 仓库安装 Caddy"
            sudo dnf install -y 'dnf-command(config-manager)' || sudo yum install -y yum-utils
            sudo dnf config-manager --add-repo https://dl.cloudsmith.io/public/caddy/stable/rpm.repo || sudo yum-config-manager --add-repo https://dl.cloudsmith.io/public/caddy/stable/rpm.repo
            sudo dnf install -y caddy || sudo yum install -y caddy
            ;;
        alpine)
            info "使用 apk 安装 Caddy"
            sudo apk add caddy
            ;;
        *)
            error "不支持的系统: $OS"
            exit 1
            ;;
    esac

    # 写入 Caddyfile
    sudo mkdir -p /etc/caddy /etc/ssl/caddy
    sudo touch /etc/caddy/Caddyfile
    sudo chown -R root:www-data /etc/caddy
    sudo chown -R www-data:root /etc/ssl/caddy
    sudo chmod 0770 /etc/ssl/caddy

    sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy ${UPSTREAM} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Port {server_port}
        header_up X-Forwarded-Proto {scheme}
    }
    tls ${EMAIL}
}
EOF

    # 验证 Caddyfile 语法
    if ! sudo caddy validate --config /etc/caddy/Caddyfile; then
        warn "Caddyfile 语法错误，请检查配置"
        exit 1
    fi

    # 启动服务
    sudo systemctl enable caddy
    sudo systemctl restart caddy
    info "Caddy 已启动并设置为开机自启"

    # 检查证书状态
    CERT_PATH="/etc/ssl/caddy/acme/acme-v02.api.letsencrypt.org/sites/${DOMAIN}"
    if [ -d "$CERT_PATH" ]; then
        info "证书申请成功，路径: $CERT_PATH"
    else
        warn "证书未生成，请稍等或手动检查"
    fi

    info "如需查看服务状态：sudo systemctl status caddy.service"
    info "如需查看启动日志：sudo journalctl -xeu caddy.service"
}

# -------------------
# 检查状态
# -------------------
check_status() {
    echo "==============================="
    echo "         Caddy 服务状态         "
    echo "==============================="
    if systemctl list-units --type=service | grep -q caddy.service; then
        sudo systemctl status caddy.service --no-pager || warn "状态获取失败"
    else
        warn "未检测到 Caddy 服务，请先安装"
    fi
}

# -------------------
# 管理 Caddy
# -------------------
manage_caddy() {
    echo "==============================="
    echo "          管理 Caddy 服务       "
    echo "==============================="
    echo "1) 启动 Caddy"
    echo "2) 停止 Caddy"
    echo "3) 重启 Caddy"
    echo "4) 查看实时日志"
    echo "5) 查看证书状态"
    read -rp "请选择操作: " choice
    case $choice in
        1) sudo systemctl start caddy && info "Caddy 已启动";;
        2) sudo systemctl stop caddy && info "Caddy 已停止";;
        3) sudo systemctl restart caddy && info "Caddy 已重启";;
        4) sudo journalctl -u caddy -f;;
        5)
            read -rp "请输入要查看证书的域名: " dom
            CERT_PATH="/etc/ssl/caddy/acme/acme-v02.api.letsencrypt.org/sites/${dom}"
            if [ -d "$CERT_PATH" ]; then
                info "证书路径: $CERT_PATH"
                ls -l "$CERT_PATH"
            else
                warn "证书未找到"
            fi
            ;;
        *) warn "无效选择";;
    esac
}

# -------------------
# 卸载 Caddy
# -------------------
uninstall_caddy() {
    echo "==============================="
    echo "        卸载并清理 Caddy        "
    echo "==============================="
    read -rp "确认卸载 Caddy 吗？(y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

    sudo systemctl stop caddy || true
    sudo systemctl disable caddy || true
    sudo rm -f /etc/systemd/system/caddy.service
    sudo rm -rf /etc/caddy /etc/ssl/caddy
    sudo rm -f /usr/local/bin/caddy
    sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
    sudo systemctl daemon-reload

    case "$OS" in
        debian|ubuntu)
            sudo apt remove --purge -y caddy || true
            ;;
        centos|rhel|fedora)
            sudo dnf remove -y caddy || sudo yum remove -y caddy || true
            ;;
        alpine)
            sudo apk del caddy || true
            ;;
    esac

    info "Caddy 已彻底卸载"
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
    echo "3) 管理 Caddy (启动/停止/重启/日志/证书)"
    echo "4) 卸载 Caddy"
    echo "5) 退出"
    read -rp "请选择操作: " main_choice
    case $main_choice in
        1) detect_os; install_dependencies; install_caddy ;;
        2) check_status ;;
        3) manage_caddy ;;
        4) detect_os; uninstall_caddy ;;
        5) exit 0 ;;
        *) warn "无效选择，请重新输入";;
    esac
done
