#!/usr/bin/env bash
set -e

# -------------------
# 彩色输出函数
# -------------------
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }

# -------------------
# 环境检查
# -------------------
if [[ -z "$BASH_VERSION" ]]; then
  error "请使用 Bash 执行该脚本！"
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  error "请确保系统已安装 sudo 并可执行"
  exit 1
fi

CADDY_BIN=$(command -v caddy || echo "/usr/local/bin/caddy")
CADDY_SERVICE="/etc/systemd/system/caddy.service"

# -------------------
# 检测域名解析
# -------------------
check_domain() {
  local domain="$1"
  local ip
  ip=$(curl -s ifconfig.me)
  if ! host "$domain" | grep -q "$ip"; then
    warn "域名 $domain 没有解析到当前服务器 IP ($ip)，HTTPS 可能无法申请"
  else
    info "域名 $domain 已正确解析到当前服务器 IP ($ip)"
  fi
}

# -------------------
# 安装 Caddy
# -------------------
install_caddy() {
  info "安装并配置 Caddy"

  read -rp "请输入要绑定的域名: " DOMAIN
  read -rp "请输入用于申请证书的邮箱: " EMAIL
  read -rp "请输入反向代理目标地址 (例如 localhost:8888): " UPSTREAM

  [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "输入不能为空"; exit 1; }

  echo -e "\n您输入的信息如下："
  echo "域名: $DOMAIN"
  echo "邮箱: $EMAIL"
  echo "后端: $UPSTREAM"
  read -rp "确认继续安装吗？(y/n): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

  # -------------------
  # 安装 Caddy
  # -------------------
  if command -v apt >/dev/null 2>&1; then
    info "检测到 apt，使用官方仓库安装 Caddy"
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy
  else
    info "未检测到 apt，使用官方二进制安装 Caddy"
    curl -fsSL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_$(uname -s)_$(uname -m).tar.gz" -o caddy.tar.gz
    tar -xzf caddy.tar.gz
    sudo mv caddy /usr/local/bin/
    sudo chmod +x /usr/local/bin/caddy
    rm -f caddy.tar.gz

    # 创建 systemd 服务
    sudo tee "$CADDY_SERVICE" > /dev/null <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=on-failure
TimeoutStopSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable caddy
  fi

  # -------------------
  # 配置目录
  # -------------------
  sudo mkdir -p /etc/caddy /etc/ssl/caddy
  sudo touch /etc/caddy/Caddyfile
  sudo chown -R root:www-data /etc/caddy
  sudo chown -R www-data:root /etc/ssl/caddy
  sudo chmod 0770 /etc/ssl/caddy

  # 写入 Caddyfile
  sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
${DOMAIN} {
    gzip
    tls ${EMAIL}
    proxy / ${UPSTREAM} {
        transparent
    }
}
EOF

  sudo systemctl restart caddy
  info "Caddy 已启动并设置为开机自启"

  # 检查域名解析
  check_domain "$DOMAIN"
}

# -------------------
# 检查状态
# -------------------
check_status() {
  echo "==============================="
  echo "         Caddy 服务状态         "
  echo "==============================="
  if systemctl list-units --type=service | grep -q caddy.service; then
    sudo systemctl status caddy.service --no-pager || warn "状态获取失败"
  else
    warn "未检测到 Caddy 服务，请先安装"
  fi
}

# -------------------
# 管理 Caddy
# -------------------
manage_caddy() {
  echo "==============================="
  echo "          管理 Caddy 服务       "
  echo "==============================="
  echo "1) 启动 Caddy"
  echo "2) 停止 Caddy"
  echo "3) 重启 Caddy"
  read -rp "请选择操作: " choice
  case $choice in
    1) sudo systemctl start caddy && info "Caddy 已启动";;
    2) sudo systemctl stop caddy && info "Caddy 已停止";;
    3) sudo systemctl restart caddy && info "Caddy 已重启";;
    *) warn "无效选择";;
  esac
}

# -------------------
# 卸载 Caddy
# -------------------
uninstall_caddy() {
  echo "==============================="
  echo "        卸载并清理 Caddy        "
  echo "==============================="
  read -rp "确认卸载 Caddy 吗？(y/n): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

  sudo systemctl stop caddy || true
  sudo systemctl disable caddy || true
  sudo rm -f "$CADDY_SERVICE"
  sudo rm -rf /etc/caddy /etc/ssl/caddy
  sudo rm -f "$CADDY_BIN"
  sudo systemctl daemon-reload

  info "Caddy 已彻底卸载"
}

# -------------------
# 主菜单
# -------------------
while true; do
  echo -e "\n==============================="
  echo "      Caddy 一键管理脚本        "
  echo "==============================="
  echo "1) 安装并配置 Caddy"
  echo "2) 检查 Caddy 状态"
  echo "3) 管理 Caddy (启动/停止/重启)"
  echo "4) 卸载 Caddy"
  echo "5) 退出"
  read -rp "请选择操作: " main_choice
  case $main_choice in
    1) install_caddy ;;
    2) check_status ;;
    3) manage_caddy ;;
    4) uninstall_caddy ;;
    5) exit 0 ;;
    *) warn "无效选择，请重新输入";;
  esac
done
