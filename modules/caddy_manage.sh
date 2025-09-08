# ========================================
# Caddy 服务管理
# ========================================
manage_caddy() {
    echo -e "\n${BLUE}========================================${RESET}"
    echo "              Caddy 服务管理             "
    echo -e "${BLUE}========================================${RESET}"
    echo "1) 启动 Caddy"
    echo "2) 停止 Caddy"
    echo "3) 重启 Caddy"
    echo "4) 查看实时日志"
    echo "5) 查看证书文件"
    read -rp "请选择操作: " choice
    case $choice in
        1)
            sudo systemctl start caddy
            info "Caddy 已启动"
            ;;
        2)
            sudo systemctl stop caddy
            info "Caddy 已停止"
            ;;
        3)
            sudo systemctl restart caddy
            info "Caddy 已重启"
            ;;
        4)
            sudo journalctl -u caddy -f
            ;;
        5)
            read -rp "请输入域名: " dom
            CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"
            if [ -d "$CERT_DIR" ]; then
                find "$CERT_DIR" -type f \( -name "${dom}*.crt" -o -name "${dom}*.key" \)
            else
                warn "证书目录不存在: $CERT_DIR"
            fi
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}