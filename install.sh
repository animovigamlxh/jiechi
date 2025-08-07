#!/bin/bash

# ==============================================================================
# Nginx 劫持与 DNS 修改一键部署/卸载脚本
# 功能:
# 1. 劫持 http://www.gstatic.com/generate_204 请求
# 2. 修改系统 DNS 为 1.1.1.1 和 8.8.8.8
# 支持系统: Ubuntu / Debian
# ==============================================================================

# --- 配置 ---
HIJACK_DOMAIN="www.gstatic.com"
NGINX_CONF_FILE="/etc/nginx/conf.d/gstatic_hijack.conf"
HOSTS_ENTRY="127.0.0.1 $HIJACK_DOMAIN"
RESOLVED_CONF_FILE="/etc/systemd/resolved.conf"
RESOLVED_CONF_BACKUP="$RESOLVED_CONF_FILE.bak_$(date +%Y%m%d_%H%M%S)"
PRIMARY_DNS="1.1.1.1"
SECONDARY_DNS="8.8.8.8"

# --- 函数定义 ---

# 打印消息
log_info() {
    echo "✅ [INFO] $1"
}

log_error() {
    echo "❌ [ERROR] $1" >&2
}

# 检查是否以root权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "此脚本需要root权限。请使用 'sudo bash $0'"
        exit 1
    fi
}

# 安装部署函数
do_install() {
    log_info "开始部署 Nginx 劫持与 DNS 修改..."

    # 1. 检查并安装 Nginx
    if ! command -v nginx &> /dev/null; then
        log_info "未检测到 Nginx，正在自动安装..."
        apt-get update
        apt-get install -y nginx
        log_info "Nginx 安装完成。"
    else
        log_info "Nginx 已安装。"
    fi

    # 2. 修改系统 DNS
    log_info "正在配置系统 DNS..."
    if [ ! -f "$RESOLVED_CONF_BACKUP" ]; then
        cp "$RESOLVED_CONF_FILE" "$RESOLVED_CONF_BACKUP"
        log_info "已备份当前 DNS 配置到: $RESOLVED_CONF_BACKUP"
    fi
    
    # 使用 sed 更新或添加 DNS 设置
    sed -i -e "s/^#*DNS=.*/DNS=$PRIMARY_DNS $SECONDARY_DNS/" \
           -e "s/^#*FallbackDNS=.*/FallbackDNS=/" \
           "$RESOLVED_CONF_FILE"
    
    # 确保 DNS 配置存在
    if ! grep -q "^DNS=" "$RESOLVED_CONF_FILE"; then
        echo "DNS=$PRIMARY_DNS $SECONDARY_DNS" >> "$RESOLVED_CONF_FILE"
    fi

    log_info "已将 DNS 修改为 $PRIMARY_DNS (备用: $SECONDARY_DNS)。"
    log_info "正在重启 systemd-resolved 服务..."
    systemctl restart systemd-resolved

    # 3. 修改 /etc/hosts 文件
    if ! grep -qF "$HOSTS_ENTRY" /etc/hosts; then
        log_info "正在将 '$HOSTS_ENTRY' 添加到 /etc/hosts..."
        echo -e "\n# Added by gstatic_hijack script\n$HOSTS_ENTRY" >> /etc/hosts
    else
        log_info "'$HOSTS_ENTRY' 已存在于 /etc/hosts 中。"
    fi

    # 4. 创建 Nginx 配置文件
    log_info "正在创建 Nginx 配置文件: $NGINX_CONF_FILE"
    cat > "$NGINX_CONF_FILE" <<EOF
# 由 setup_gstatic_hijack.sh 脚本自动生成
server {
    listen 80;
    server_name $HIJACK_DOMAIN;
    access_log /var/log/nginx/gstatic_hijack.access.log;
    error_log /var/log/nginx/gstatic_hijack.error.log;
    location = /generate_204 {
        return 204;
    }
    location / {
        return 404;
    }
}
EOF

    # 5. 测试并重载 Nginx
    log_info "正在测试 Nginx 配置..."
    if nginx -t; then
        log_info "Nginx 配置有效，正在重载服务..."
        systemctl reload nginx
    else
        log_error "Nginx 配置测试失败。"
        exit 1
    fi

    echo ""
    log_info "🎉 部署成功！"
    log_info "DNS 和 Nginx 劫持均已配置。"
    log_info "如需卸载，请运行: sudo bash $0 --uninstall"
}

# 卸载函数
do_uninstall() {
    log_info "开始卸载 Nginx 劫持与 DNS 修改..."

    # 1. 恢复 DNS 配置
    BACKUP_FILE=$(ls -t "$RESOLVED_CONF_FILE.bak_"* 2>/dev/null | head -n 1)
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        log_info "正在从备份恢复 DNS 配置: $BACKUP_FILE"
        mv "$BACKUP_FILE" "$RESOLVED_CONF_FILE"
        log_info "正在重启 systemd-resolved 服务..."
        systemctl restart systemd-resolved
    else
        log_info "未找到 DNS 备份文件，跳过恢复。"
    fi

    # 2. 删除 Nginx 配置文件
    if [ -f "$NGINX_CONF_FILE" ]; then
        rm -f "$NGINX_CONF_FILE"
        log_info "已删除 Nginx 配置文件。"
    fi

    # 3. 从 /etc/hosts 文件中移除相关条目
    if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
        log_info "正在从 /etc/hosts 中移除劫持条目..."
        sed -i "/$HOSTS_ENTRY/d" /etc/hosts
        sed -i "/# Added by gstatic_hijack script/d" /etc/hosts
    fi

    # 4. 测试并重载 Nginx
    log_info "正在测试并重载 Nginx 以应用更改..."
    if nginx -t; then
        systemctl reload nginx
        log_info "Nginx 已重载。"
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
