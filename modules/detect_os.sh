#!/usr/bin/env bash
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
