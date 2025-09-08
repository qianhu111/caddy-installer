#!/usr/bin/env bash
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
