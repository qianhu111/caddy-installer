#!/usr/bin/env bash
set -e

# ========================================
# 彩色输出函数
# ========================================
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[0;34m"
PURPLE="\033[1;35m"
RESET="\033[0m"

info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

# ========================================
# 分割线统一定义
# ========================================
LINE="========================================"
LINE_SHORT="--------------------"

# ========================================
# 系统识别
# ========================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="$ID"
        VERSION="$VERSION_ID"
        info "检测到操作系统: $OS $VERSION"
    else
        error "无法识别操作系统"
        exit 1
    fi
}

# ========================================
# 安装依赖
# ========================================
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

# ========================================
# 获取服务器公网 IPv4 / IPv6
# ========================================
get_public_ip() {
    info "正在获取当前服务器公网 IPv4 和 IPv6 地址..."

    # ---------- IPv4 ----------
    local local_ipv4
    local_ipv4=$(ip -4 a | grep -oP 'inet \K[\d.]+' | grep -Ev '^(127\.|169\.254\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1)

    if [[ -n "$local_ipv4" ]]; then
        ipv4="$local_ipv4"
        info "检测到本机 IPv4: ${GREEN}${ipv4}${RESET}"
    else
        info "未检测到本机 IPv4，使用外部服务获取公网 IPv4..."
        for url in "https://ip.sb" "https://ifconfig.co" "https://api.ipify.org"; do
            ipv4=$(curl -4 -s --max-time 5 "$url")
            if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                info "外部服务返回 IPv4: ${GREEN}${ipv4}${RESET}"
                break
            fi
        done
        [[ -z "$ipv4" ]] && { ipv4="无 IPv4"; warn "未能获取公网 IPv4"; }
    fi

    # ---------- IPv6 ----------
    local local_ipv6
    local_ipv6=$(ip -6 a | grep -oP 'inet6 \K[^/]*' | grep -v '^fe80' | grep -v '^::1$' | head -n1)

    if [[ -n "$local_ipv6" ]]; then
        ipv6="$local_ipv6"
        info "检测到本机 IPv6: ${GREEN}${ipv6}${RESET}"
    else
        info "未检测到本机 IPv6，使用外部服务获取公网 IPv6..."
        for url in "https://ip.sb" "https://ifconfig.co"; do
            ipv6=$(curl -6 -s --max-time 5 "$url")
            if [[ "$ipv6" =~ ^[0-9a-fA-F:]+$ ]]; then
                info "外部服务返回 IPv6: ${GREEN}${ipv6}${RESET}"
                break
            fi
        done
        [[ -z "$ipv6" ]] && { ipv6="无 IPv6"; warn "未能获取公网 IPv6"; }
    fi

    info "服务器公网 IPv4: ${GREEN}${ipv4}${RESET}"
    info "服务器公网 IPv6: ${GREEN}${ipv6}${RESET}"
}

# ========================================
# 域名解析检测
# ========================================
check_domain() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        error "域名不能为空"
        exit 1
    fi

    info "正在解析域名 $domain..."

    # 使用 host 命令获取 IPv4 和 IPv6
    local resolved_ips
    resolved_ips=$(host "$domain" 2>/dev/null | awk '/has address/{print $4} /has IPv6 address/{print $5}')

    if [[ -z "$resolved_ips" ]]; then
        warn "域名 $domain 解析失败或未返回 IP，请检查 DNS 设置"
    else
        info "域名解析结果：${GREEN}${resolved_ips}${RESET}"
    fi

    # 判断是否匹配任意一个公网 IP
    if [[ "$resolved_ips" == *"$ipv4"* ]] || [[ "$resolved_ips" == *"$ipv6"* ]]; then
        info "域名 ${GREEN}$domain${RESET} 已正确解析到当前服务器 IP"
    else
        warn "域名 ${YELLOW}$domain${RESET} 未解析到当前服务器 IP (${YELLOW}${ipv4:-无}/${ipv6:-无}${RESET})"
        warn "请检查您的 DNS 解析设置。"
        read -rp "是否继续安装？(y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi
}

# ========================================
# 端口检测
# ========================================
check_ports() {
    info "正在检测 80/443 端口状态..."

    HTTP_FREE=1
    HTTPS_FREE=1

    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            warn "端口 $port 已被占用"
            [[ "$port" -eq 80 ]] && HTTP_FREE=0
            [[ "$port" -eq 443 ]] && HTTPS_FREE=0
        fi
    done

    local http_status https_status
    http_status=$([ $HTTP_FREE -eq 1 ] && echo "${GREEN}可用${RESET}" || echo "${RED}已占用${RESET}")
    https_status=$([ $HTTPS_FREE -eq 1 ] && echo "${GREEN}可用${RESET}" || echo "${RED}已占用${RESET}")

    info "端口检测结果：80端口:${http_status}，443端口:${https_status}"
}

# ========================================
# 安装并配置 Caddy
# ========================================
install_caddy() {
    read -rp "请输入绑定的域名: " DOMAIN
    read -rp "请输入用于申请证书的邮箱: " EMAIL
    read -rp "请输入反向代理目标地址 (127.0.0.1:8888): " UPSTREAM
    read -rp "请输入 Cloudflare API Token (可留空使用 HTTP 验证): " CF_TOKEN
    read -rp "是否使用 Let's Encrypt 测试环境 (y/n, 默认n): " TEST_MODE

    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

    # --------- Cloudflare Token 优先 ---------
    if [[ -n "$CF_TOKEN" ]]; then
        info "检测到 Cloudflare Token，安装带 Cloudflare 插件的 Caddy"
    
        # 使用官方下载 API，自动生成带 Cloudflare 插件的 Caddy
        DOWNLOAD_URL="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare&idempotency=95604088870894"
        info "下载 Caddy 二进制: $DOWNLOAD_URL"
        
        wget -O /tmp/caddy "$DOWNLOAD_URL"
        sudo mv /tmp/caddy /usr/bin/caddy
        sudo chmod +x /usr/bin/caddy
    
        # 检查是否安装成功
        if /usr/bin/caddy list-modules | grep -q 'cloudflare'; then
            info "✅ Caddy 安装完成，Cloudflare 插件已集成"
        else
            error "❌ Caddy 安装失败，未集成 Cloudflare 插件"
            exit 1
        fi
    else
        info "未检测到 Cloudflare Token，使用系统包安装 Caddy"
        case "$OS" in
            debian|ubuntu)
                sudo apt update
                sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg
                echo "deb [signed-by=/usr/share/keyrings/caddy-archive-keyring.gpg] \
                https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
                | sudo tee /etc/apt/sources.list.d/caddy.list
                sudo apt update
                sudo apt install -y caddy
                ;;
            centos|rhel)
                sudo yum install -y yum-plugin-copr
                sudo yum copr enable @caddy/caddy
                sudo yum install -y caddy
                ;;
            fedora)
                sudo dnf install -y 'dnf-command(copr)'
                sudo dnf copr enable @caddy/caddy
                sudo dnf install -y caddy
                ;;
            alpine)
                CADDY_VER=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep tag_name | cut -d '"' -f4)
                wget -O /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/${CADDY_VER}/caddy_${CADDY_VER#v}_linux_amd64.tar.gz"
                tar -xzf /tmp/caddy.tar.gz -C /tmp
                sudo mv /tmp/caddy /usr/bin/caddy
                sudo chmod +x /usr/bin/caddy
                ;;
            *)
                error "暂不支持的系统"
                exit 1
                ;;
        esac
    fi

    info "Caddy 安装完成"

    # --------- 准备目录 ---------
    sudo mkdir -p /etc/caddy /etc/ssl/caddy
    sudo chown -R www-data:root /etc/ssl/caddy
    sudo chmod 0770 /etc/ssl/caddy

    # --------- 生成 Caddyfile ---------
    CADDYFILE="${DOMAIN} {
    encode gzip
    reverse_proxy ${UPSTREAM} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Port {server_port}
    }"

    if [[ -n "$CF_TOKEN" ]]; then
        export CF_API_TOKEN="$CF_TOKEN"
        CADDYFILE+="
    tls {
        dns cloudflare {env.CF_API_TOKEN}
        storage file_system /etc/ssl/caddy"
        [[ "$TEST_MODE" =~ ^[Yy]$ ]] && CADDYFILE+="
        ca https://acme-staging-v02.api.letsencrypt.org/directory"
        CADDYFILE+="
    }"
    else
        if [[ $HTTP_FREE -eq 1 && $HTTPS_FREE -eq 1 ]]; then
            CADDYFILE+="
    tls ${EMAIL} { storage file_system /etc/ssl/caddy }"
        elif [[ $HTTP_FREE -eq 1 ]]; then
            CADDYFILE+="
    tls ${EMAIL} { storage file_system /etc/ssl/caddy }"
        elif [[ $HTTPS_FREE -eq 1 ]]; then
            CADDYFILE+="
    tls ${EMAIL} {
        storage file_system /etc/ssl/caddy
        alpn tls-alpn-01
    }"
        else
            error "80/443 均不可用，无法申请证书"
            exit 1
        fi
    fi

    CADDYFILE+="
}"

    echo "$CADDYFILE" | sudo tee /etc/caddy/Caddyfile > /dev/null

    # --------- systemd 服务 ---------
    sudo tee /etc/systemd/system/caddy.service > /dev/null <<-'EOF'
[Unit]
Description=Caddy Web Server
After=network.target

[Service]
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
User=www-data
Group=www-data
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment=CADDY_STORAGE_DIR=/etc/ssl/caddy
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable caddy
    sudo systemctl restart caddy

    info "等待证书生成..."
    sleep 5
    CERT_FILES=$(find /etc/ssl/caddy -type f \( -name "*.crt" -o -name "*.key" \) 2>/dev/null)
    if [[ -n "$CERT_FILES" ]]; then
        info "✅ 证书申请成功!"
        echo "$CERT_FILES"
    else
        warn "未检测到证书，请检查 DNS/端口/CF Token"
    fi
}

# ========================================
# Caddy 服务管理
# ========================================
manage_caddy() {
    local LINE="========================================"

    while true; do
        echo -e "\n${BLUE}${LINE}${RESET}"
        echo -e "${PURPLE}            Caddy 服务管理            ${RESET}"
        echo -e "${BLUE}${LINE}${RESET}"
        echo -e "${YELLOW}1)${RESET} 启动 Caddy"
        echo -e "${YELLOW}2)${RESET} 停止 Caddy"
        echo -e "${YELLOW}3)${RESET} 重启 Caddy"
        echo -e "${YELLOW}4)${RESET} 查看实时日志"
        echo -e "${YELLOW}5)${RESET} 查看证书文件"
        echo -e "${YELLOW}6)${RESET} 返回主菜单"
        read -rp "请选择操作: " choice

        case $choice in
            1)
                sudo systemctl start caddy
                info "✅ Caddy 已启动"
                ;;
            2)
                sudo systemctl stop caddy
                info "✅ Caddy 已停止"
                ;;
            3)
                sudo systemctl restart caddy
                info "✅ Caddy 已重启"
                ;;
            4)
                info "按 Ctrl+C 退出日志"
                sudo journalctl -u caddy -f
                ;;
            5)
                read -rp "请输入域名: " dom
                CERT_DIR="/etc/ssl/caddy"
                if [ -d "$CERT_DIR" ]; then
                    echo "证书文件列表:"
                    find "$CERT_DIR" -type f \( -name "${dom}*.crt" -o -name "${dom}*.key" \)
                else
                    warn "证书目录不存在: $CERT_DIR"
                fi
                ;;
            6)
                info "返回主菜单"
                break
                ;;
            *)
                warn "⚠️ 选择无效，请输入 1-6"
                ;;
        esac
    done
}


# ========================================
# 卸载 Caddy
# ========================================
uninstall_caddy() {
    local LINE="========================================"
    echo -e "\n${BLUE}${LINE}${RESET}"
    echo "            卸载 Caddy 并清理           "
    echo -e "${BLUE}${LINE}${RESET}"
    read -rp "确认卸载 Caddy 吗？(y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    sudo systemctl stop caddy || true
    sudo systemctl disable caddy || true
    sudo rm -f /etc/systemd/system/caddy.service
    sudo systemctl daemon-reload

    if [[ -f /etc/debian_version ]]; then
        sudo apt purge -y caddy || true
        sudo rm -f /etc/apt/sources.list.d/caddy.list
        sudo rm -f /usr/share/keyrings/caddy*.gpg
    elif [[ -f /etc/redhat-release ]]; then
        sudo yum remove -y caddy || true
    elif grep -qi "fedora" /etc/os-release 2>/dev/null; then
        sudo dnf remove -y caddy || true
    else
        sudo rm -f /usr/local/bin/caddy /usr/bin/caddy
    fi

    sudo rm -rf /etc/caddy /etc/ssl/caddy
    info "Caddy 已彻底卸载"
}

# ========================================
# 主菜单
# ========================================
main_menu() {
    local LINE="========================================"

    while true; do
        echo -e "\n${BLUE}${LINE}${RESET}"
        echo -e "      Caddy 一键管理脚本 ${PURPLE}by 千狐${RESET}       "
        echo -e "${BLUE}${LINE}${RESET}"
        echo "1) 安装并配置 Caddy"
        echo "2) 检查 Caddy 状态"
        echo "3) 管理 Caddy 服务"
        echo "4) 卸载 Caddy"
        echo "5) 退出"
        read -rp "请选择操作: " choice
        case $choice in
            1)
                detect_os
                install_dependencies
                install_caddy
                ;;
            2)
                if systemctl status caddy --no-pager >/dev/null 2>&1; then
                    systemctl status caddy --no-pager
                else
                    warn "Caddy 未运行"
                fi
                ;;
            3)
                manage_caddy
                ;;
            4)
                detect_os
                uninstall_caddy
                ;;
            5)
                info "退出脚本"
                exit 0
                ;;
            *)
                warn "无效选择"
                ;;
        esac
    done
}

# ========================================
# 脚本入口
# ========================================
main_menu
