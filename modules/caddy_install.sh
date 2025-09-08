# ========================================
# 安装并配置 Caddy
# ========================================
install_caddy() {
    read -rp "请输入绑定的域名: " DOMAIN
    read -rp "请输入用于申请证书的邮箱: " EMAIL
    read -rp "请输入反向代理目标地址 (例如 127.0.0.1:8888): " UPSTREAM
    read -rp "请输入 Cloudflare API Token (可留空使用 HTTP/DNS 验证): " CF_TOKEN
    read -rp "是否使用 Let’s Encrypt 测试环境 (y/n，默认n): " TEST_MODE

    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

    echo -e "\n您输入的信息如下："
    echo "域名: $DOMAIN"
    echo "邮箱: $EMAIL"
    echo "后端: $UPSTREAM"

    # 获取公网 IP 并检测域名
    get_public_ip
    check_domain "$DOMAIN"
    check_ports

    # -------------------
    # 安装 Caddy 官方 apt 源
    # -------------------
    info "安装最新版 Caddy..."
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy || { error "Caddy 安装失败"; exit 1; }

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
    # 证书申请逻辑
    # -------------------
    if [[ -n "$CF_TOKEN" ]]; then
        info "使用 DNS-01 验证 (Cloudflare Token)"
        export CF_API_TOKEN="$CF_TOKEN"
        CADDYFILE+="
    tls {
        dns cloudflare {env.CF_API_TOKEN}"
        [[ "$TEST_MODE" =~ ^[Yy]$ ]] && CADDYFILE+="
        ca https://acme-staging-v02.api.letsencrypt.org/directory"
        CADDYFILE+="
    }"
    else
        # 未提供 Cloudflare Token，优先 HTTP-01 / TLS-ALPN-01
        if [[ $HTTP_FREE -eq 1 && $HTTPS_FREE -eq 1 ]]; then
            info "80/443 均可用，使用 HTTP-01 验证 (推荐)"
            [[ "$TEST_MODE" =~ ^[Yy]$ ]] && CADDYFILE+="
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }" || CADDYFILE+="
    tls ${EMAIL}"
        elif [[ $HTTP_FREE -eq 1 ]]; then
            info "仅 80 端口可用，使用 HTTP-01"
            [[ "$TEST_MODE" =~ ^[Yy]$ ]] && CADDYFILE+="
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }" || CADDYFILE+="
    tls ${EMAIL}"
        elif [[ $HTTPS_FREE -eq 1 ]]; then
            info "仅 443 端口可用，使用 TLS-ALPN-01"
            [[ "$TEST_MODE" =~ ^[Yy]$ ]] && CADDYFILE+="
    tls {
        alpn tls-alpn-01
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }" || CADDYFILE+="
    tls ${EMAIL} {
        alpn tls-alpn-01
    }"
        else
            error "80/443 端口均被占用，无法申请证书"
            error "请提供 Cloudflare Token 使用 DNS-01 方式"
            exit 1
        fi
    fi

    CADDYFILE+="
}"

    # 写入 Caddyfile 并验证
    echo "$CADDYFILE" | sudo tee /etc/caddy/Caddyfile >/dev/null
    sudo caddy validate --config /etc/caddy/Caddyfile || { warn "Caddyfile 语法错误"; exit 1; }
    sudo systemctl enable caddy
    sudo systemctl restart caddy
    info "Caddy 已启动并设置开机自启"

    # -------------------
    # 等待证书生成
    # -------------------
    CERT_BASE="/var/lib/caddy/.local/share/caddy/certificates"
    if [[ "$TEST_MODE" =~ ^[Yy]$ ]]; then
        CERT_DIR="${CERT_BASE}/acme-staging-v02.api.letsencrypt.org-directory/${DOMAIN}/"
    else
        CERT_DIR="${CERT_BASE}/acme-v02.api.letsencrypt.org-directory/${DOMAIN}/"
    fi

    info "等待证书生成..."
    for i in {1..20}; do
        if [ -d "$CERT_DIR" ] && [ "$(ls -A "$CERT_DIR" 2>/dev/null)" ]; then
            info "证书已生成！路径如下："
            find "$CERT_DIR" -type f \( -name "*.crt" -o -name "*.key" \)
            break
        fi
        sleep 5
    done
}