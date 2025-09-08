# ========================================
# 卸载 Caddy
# ========================================
uninstall_caddy() {
    echo -e "\n${BLUE}========================================${RESET}"
    echo "            卸载 Caddy 并清理           "
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