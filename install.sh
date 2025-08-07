#!/bin/bash

# ==============================================================================
# 透明代理劫持与 DNS 修改一键部署/卸载脚本 v5 (软件源修复版)
# 功能:
# 1. 自动修复失效的 bullseye-backports 软件源
# 2. 使用 iptables 和 Nginx 透明代理劫持 HTTP 流量
# 3. 修改系统 DNS 为 1.1.1.1 和 8.8.8.8
# 支持系统: Ubuntu / Debian
# ==============================================================================

# --- 配置 ---
NGINX_CONF_FILE="/etc/nginx/conf.d/transparent_proxy.conf"
PROXY_PORT="8888" # Nginx 监听的代理端口
NGINX_USER="www-data" # Ubuntu/Debian 上 Nginx 默认的运行用户
RESOLVED_CONF_FILE="/etc/systemd/resolved.conf"
RESOLVED_CONF_BACKUP="$RESOLVED_CONF_FILE.bak_$(date +%Y%m%d_%H%M%S)"
PRIMARY_DNS="1.1.1.1"
SECONDARY_DNS="8.8.8.8"
SOURCES_LIST_DIR="/etc/apt/sources.list.d"
MAIN_SOURCES_LIST="/etc/apt/sources.list"

# --- 函数定义 ---

log_info() {
    echo "✅ [INFO] $1"
}

log_error() {
    echo "❌ [ERROR] $1" >&2
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "此脚本需要root权限。请使用 'sudo bash $0'"
        exit 1
    fi
}

# 自动修复失效的软件源
fix_apt_sources() {
    log_info "正在检查并修复失效的 'bullseye-backports' 软件源..."
    
    # 定义要查找和注释的模式
    local pattern="bullseye-backports"
    
    # 查找并处理主 sources.list 文件
    if grep -q "$pattern" "$MAIN_SOURCES_LIST"; then
        log_info "在 $MAIN_SOURCES_LIST 中发现失效源，正在创建备份并注释..."
        cp "$MAIN_SOURCES_LIST" "$MAIN_SOURCES_LIST.bak_$(date +%Y%m%d_%H%M%S)"
        sed -i -E "s|^(.*$pattern.*)|# \1 (Commented out by script)|" "$MAIN_SOURCES_LIST"
    fi
    
    # 查找并处理 sources.list.d 目录下的文件
    if [ -d "$SOURCES_LIST_DIR" ]; then
        for file in $(grep -lr "$pattern" "$SOURCES_LIST_DIR"); do
            log_info "在 $file 中发现失效源，正在创建备份并注释..."
            cp "$file" "$file.bak_$(date +%Y%m%d_%H%M%S)"
            sed -i -E "s|^(.*$pattern.*)|# \1 (Commented out by script)|" "$file"
        done
    fi
    log_info "软件源检查修复完成。"
}


# 安装部署函数
do_install() {
    log_info "开始部署透明代理与 DNS 修改 (v5)..."

    # 0. 修复软件源
    fix_apt_sources

    # 1. 更新 apt 并安装依赖
    log_info "正在更新 apt 软件源..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update; then
        log_error "apt-get update 失败！请检查您的网络连接和软件源配置。"
        exit 1
    fi
    
    log_info "正在安装依赖 (nginx, iptables-persistent)..."
    if ! apt-get install -y nginx iptables-persistent; then
        log_error "依赖安装 (nginx, iptables-persistent) 失败！"
        exit 1
    fi
    log_info "依赖安装完成。"

    # 2. 修改系统 DNS
    log_info "正在配置系统 DNS..."
    if [ ! -f "$RESOLVED_CONF_BACKUP" ]; then
        cp "$RESOLVED_CONF_FILE" "$RESOLVED_CONF_BACKUP"
        log_info "已备份当前 DNS 配置到: $RESOLVED_CONF_BACKUP"
    fi
    sed -i -e "s/^#*DNS=.*/DNS=$PRIMARY_DNS $SECONDARY_DNS/" \
           -e "s/^#*FallbackDNS=.*/FallbackDNS=/" \
           "$RESOLVED_CONF_FILE"
    if ! grep -q "^DNS=" "$RESOLVED_CONF_FILE"; then
        echo "DNS=$PRIMARY_DNS $SECONDARY_DNS" >> "$RESOLVED_CONF_FILE"
    fi
    log_info "已将 DNS 修改为 $PRIMARY_DNS (备用: $SECONDARY_DNS)。"
    systemctl restart systemd-resolved
    log_info "DNS 服务已重启。"

    # 3. 创建 Nginx 透明代理配置文件
    log_info "正在创建 Nginx 透明代理配置文件: $NGINX_CONF_FILE"
    cat > "$NGINX_CONF_FILE" <<EOF
# 由 setup_gstatic_hijack.sh 脚本自动生成 (v5)
server {
    listen ${PROXY_PORT};
    server_name www.gstatic.com;
    location = /generate_204 { return 204; }
    location / {
        proxy_pass http://www.gstatic.com;
        proxy_set_header Host "www.gstatic.com";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
server {
    listen ${PROXY_PORT} default_server;
    resolver $PRIMARY_DNS $SECONDARY_DNS valid=300s;
    resolver_timeout 5s;
    location / {
        proxy_pass http://\$host\$request_uri;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

    # 4. 设置 iptables 流量重定向规则
    log_info "正在设置 iptables 流量重定向规则 (端口 80 -> ${PROXY_PORT})..."
    iptables -t nat -D OUTPUT -p tcp --dport 80 -m owner ! --uid-owner ${NGINX_USER} -j REDIRECT --to-port ${PROXY_PORT} 2>/dev/null
    iptables -t nat -A OUTPUT -p tcp --dport 80 -m owner ! --uid-owner ${NGINX_USER} -j REDIRECT --to-port ${PROXY_PORT}
    
    # 5. 保存 iptables 规则并重载 Nginx
    log_info "正在永久保存 iptables 规则..."
    iptables-save > /etc/iptables/rules.v4

    log_info "正在测试并重载 Nginx..."
    if nginx -t; then
        systemctl reload nginx
    else
        log_error "Nginx 配置测试失败。请检查 $NGINX_CONF_FILE 文件。"
        exit 1
    fi

    echo ""
    log_info "🎉 部署成功！"
    log_info "如需卸载，请运行: sudo bash $0 --uninstall"
}

# 卸载函数
do_uninstall() {
    log_info "开始卸载透明代理与 DNS 修改..."

    # 卸载时不需要恢复软件源，因为注释掉是无害的
    log_info "注意：脚本不会自动恢复被注释的软件源。如有需要，请手动编辑相关文件。"

    # 1. 恢复 DNS 配置
    BACKUP_FILE=$(ls -t "$RESOLVED_CONF_FILE.bak_"* 2>/dev/null | head -n 1)
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        log_info "正在从备份恢复 DNS 配置: $BACKUP_FILE"
        mv "$BACKUP_FILE" "$RESOLVED_CONF_FILE"
        systemctl restart systemd-resolved
        log_info "DNS 服务已重启并恢复。"
    fi

    # 2. 移除 iptables 规则
    log_info "正在移除 iptables 流量重定向规则..."
    iptables -t nat -D OUTPUT -p tcp --dport 80 -m owner ! --uid-owner ${NGINX_USER} -j REDIRECT --to-port ${PROXY_PORT} 2>/dev/null
    iptables-save > /etc/iptables/rules.v4
    log_info "iptables 规则已移除并保存。"
    
    # 3. 删除 Nginx 配置文件
    if [ -f "$NGINX_CONF_FILE" ]; then
        rm -f "$NGINX_CONF_FILE"
        log_info "已删除 Nginx 配置文件。"
    fi
    
    # 4. 重载 Nginx
    log_info "正在重载 Nginx 以应用更改..."
    if nginx -t; then
        systemctl reload nginx
    else
        log_error "Nginx 配置测试失败，可能需要您手动修复。"
    fi

    echo ""
    log_info "🎉 卸载完成！"
}


# --- 主逻辑 ---
check_root

if [[ "$1" == "--uninstall" ]]; then
    do_uninstall
else
    do_install
fi
