#!/usr/bin/env bash
# ========================================
# 获取服务器公网 IPv4 / IPv6
# ========================================
get_public_ip() {
    info "正在获取当前服务器公网 IPv4 和 IPv6 地址..."

    local local_ipv4
    local_ipv4=$(ip -4 a | grep -oP 'inet \K[\d.]+' | grep -Ev '^(127\.|169\.254\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1)

    if [[ -n "$local_ipv4" ]]; then
        ipv4=$(curl -s4 --max-time 5 https://ifconfig.co 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        [[ -z "$ipv4" ]] && ipv4="NAT IPv4（非公网）"
    else
        ipv4="无 IPv4"
    fi

    local local_ipv6
    local_ipv6=$(ip -6 a | grep -oP 'inet6 \K[^/]*' | grep -v '^fe80' | grep -v '^::1$' | head -n1)

    if [[ -n "$local_ipv6" ]]; then
        [[ "$local_ipv6" =~ ^2[0-9a-fA-F]{0,3}: ]] && ipv6="$local_ipv6" || ipv6="无公网 IPv6"
    else
        ipv6="无 IPv6"
    fi

    info "服务器 IPv4: ${GREEN}${ipv4}${RESET}"
    info "服务器 IPv6: ${GREEN}${ipv6}${RESET}"
}
