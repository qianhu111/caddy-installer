#!/usr/bin/env bash
set -e

# 导入模块
source ./modules/main_menu.sh
source ./modules/colors.sh
source ./modules/detect_os.sh
source ./modules/dependencies.sh
source ./modules/ip_check.sh
source ./modules/domain_check.sh
source ./modules/port_check.sh
source ./modules/caddy_install.sh
source ./modules/caddy_manage.sh
source ./modules/caddy_uninstall.sh

# 主菜单
main_menu
