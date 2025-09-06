# Caddy Manager 一键管理脚本

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Caddy Manager 是一款支持交互式安装、配置 Caddy 并自动申请 SSL 证书的一键管理脚本。  
支持多种 VPS 环境，自动检测系统和依赖，输出中文提示，适合国内用户使用。

仓库地址: [https://github.com/qianhu111/caddy-manager](https://github.com/qianhu111/caddy-manager)

---

## 功能特性

- **一键安装 Caddy**  
  自动选择官方 apt 源安装或二进制版本，设置 systemd 服务并开机自启。

- **自动申请 SSL 证书**  
  支持 HTTP-01、TLS-ALPN-01、DNS-01（Cloudflare Token）验证方式。  
  支持 Let’s Encrypt / ZeroSSL / Buypass 可选证书厂商。  

- **交互式配置**  
  提示用户输入域名、邮箱、反向代理目标、Cloudflare Token 等信息，支持默认值和格式验证。

- **端口与系统检测**  
  自动检测 80/443 是否可用，检测操作系统类型及包管理器，安装缺失依赖。

- **中文化输出**  
  安装过程和错误提示均为中文，友好易用。

- **日志记录**  
  安装过程输出到终端并写入 `/tmp/caddy_install.log`。

- **服务管理**  
  提供启动、停止、重启、查看日志和证书文件的操作。

- **卸载与回滚**  
  可彻底卸载 Caddy 并清理配置和证书文件，安装失败时自动回滚。

---

## 使用方式

### 在线执行

```bash
bash <(curl -sSL https://raw.githubusercontent.com/qianhu111/caddy-manager/main/caddy-install.sh)
```

---

## 脚本功能菜单

执行脚本后，会显示以下菜单：

1. 安装并配置 Caddy

2. 检查 Caddy 状态

3. 管理 Caddy 服务（启动/停止/重启/日志/证书查看）

4. 卸载 Caddy

5. 退出

根据提示输入数字选择对应操作。

---

## 安装流程说明

1. 系统与依赖检测
  自动识别 Ubuntu/Debian 系统，检查 curl、lsof、host、gnupg 等工具是否安装，缺失则自动安装。

2. 端口检查
  检测 80/443 端口是否可用，提示用户选择验证方式。

3. 生成 Caddyfile
  根据用户输入的域名、邮箱、反向代理目标和 Cloudflare Token 自动生成配置文件。

4. 启动 Caddy 并申请证书

  * 优先使用 DNS-01（Cloudflare Token）

  * 其次使用 HTTP-01（优先 IPv4）

  * 最后使用 TLS-ALPN-01（优先 IPv4，如果失败尝试 IPv6）

5. 证书生成等待
  脚本会循环等待证书生成，并提示成功。

---

## 配置示例

Caddyfile 示例：

```caddyfile
nameserver.example.com {
    encode gzip
    reverse_proxy 127.0.0.1:8888 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Port {server_port}
    }
    tls admin@mail.com
}
```

---

## 系统兼容性

* Ubuntu / Debian 系列（apt 包管理器）

* 需要 root 或 sudo 权限执行

* 仅支持 Cloudflare DNS-01 验证（DNS-01 必选）

---

## 注意事项

* 若 80/443 端口被占用，自动申请证书可能失败，可提供 Cloudflare Token 使用 DNS-01 方式。

* 安装过程中生成的日志保存在 /tmp/caddy_install.log，可用于排查问题。

* 卸载时会彻底清理 Caddy 二进制、配置和证书文件。

---

卸载命令

执行脚本选择“卸载 Caddy”，或手动执行：

```bash
sudo systemctl stop caddy
sudo systemctl disable caddy
sudo rm -rf /etc/caddy /etc/ssl/caddy /usr/local/bin/caddy /etc/apt/sources.list.d/caddy-stable.list
sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo apt remove --purge -y caddy
sudo systemctl daemon-reload
```

---

开源协议

MIT License，详情请见 [LICENSE](https://github.com/qianhu111/caddy-manager/blob/7dbbffa389c11f90feef9fc2c1e97469beb432c7/LICENSE)。

---

## 联系作者

GitHub: https://github.com/qianhu111

欢迎提交 Issue 或 PR 贡献改进。
