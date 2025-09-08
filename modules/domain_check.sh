#!/usr/bin/env bash
# ========================================
# 域名解析检测
# ========================================
check_domain() {
    local domain="$1"
    [[ -z "$domain" ]] && { error "域名不能为空"; exit 1; }

    info "正在解析域名 $domain..."
    local resolved_ips
    resolved_ips=$(host "$domain" 2>/dev/null | awk '/has address/{print $4} /has IPv6 address/{print $5}')

    [[ -z "$resolved_ips" ]] && warn "域名 $domain 解析失败或未返回 IP，请检查 DNS 设置" || info "域名解析结果：${GREEN}${resolved_ips}${RESET}"

    if [[ "$resolved_ips" == *"$ipv4"* ]] || [[ "$resolved_ips" == *"$ipv6"* ]]; then
        info "域名 ${GREEN}$domain${RESET} 已正确解析到当前服务器 IP"
    else
        warn "域名 ${YELLOW}$domain${RESET} 未解析到当前服务器 IP (${YELLOW}${ipv4:-无}/${ipv6:-无}${RESET})"
        warn "请检查您的 DNS 解析设置。"
        read -rp "是否继续安装？(y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi
}
