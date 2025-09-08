#!/usr/bin/env bash
# ========================================
# 主菜单函数
# ========================================
main_menu() {
    while true; do
        echo -e "\n${BLUE}========================================${RESET}"
        echo -e "      Caddy 一键管理脚本 ${PURPLE}by 千狐${RESET}       "
        echo -e "${BLUE}========================================${RESET}"
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
