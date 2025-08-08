#!/bin/bash

# FreeBSD科学上网增强版脚本
# 适用于FreeBSD 14.3-RELEASE amd64系统
# 无需root权限，增强安全性和性能

export LANG=en_US.UTF-8

# 版本信息
VERSION="1.0.1"
SCRIPT_NAME="FreeBSD Proxy Enhanced"

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
purple='\033[0;35m'
plain='\033[0m'

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
purple(){ echo -e "\033[35m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 系统检测
check_system() {
    if [[ ! -f /etc/freebsd-update.conf ]]; then
        red "错误：此脚本仅支持FreeBSD系统"
        exit 1
    fi
    
    local version=$(freebsd-version | cut -d'-' f1)
    local major_version=$(echo "$version" | cut -d'.' -f1)
    
    if [[ "$major_version" -lt 13 ]]; then
        red "错误：需要FreeBSD 13.0或更高版本，当前版本：$version"
        exit 1
    elif [[ "$major_version" -eq 13 ]]; then
        yellow "警告：建议使用FreeBSD 14.x版本以获得更好的性能"
    fi
    
    green "系统检测通过：FreeBSD $version"
}

# 检测架构
check_arch() {
    case $(uname -m) in
        amd64) cpu="amd64";;
        arm64|aarch64) cpu="arm64";;
        *) red "不支持的架构：$(uname -m)" && exit 1;;
    esac
    green "架构检测：$cpu"
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "openssl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        red "缺少依赖：${missing_deps[*]}"
        yellow "请先安装缺少的依赖：pkg install ${missing_deps[*]}"
        exit 1
    fi
    
    green "依赖检查通过"
}

# 全局变量
WORKDIR="$HOME/.freebsd-proxy"
CONFIG_FILE="$WORKDIR/config.json"
PID_FILE="$WORKDIR/sing-box.pid"
LOG_FILE="$WORKDIR/sing-box.log"
SING_BOX_BIN="$WORKDIR/sing-box"
BACKUP_DIR="$WORKDIR/backup"
CONFIG_BACKUP="$BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json"

# 端口配置（支持随机端口）
VLESS_PORT=28332
VMESS_PORT=38533
HY2_PORT=38786

# 安全配置
REALITY_DOMAINS=("www.microsoft.com" "www.apple.com" "www.cloudflare.com" "www.github.com")
MASQUERADE_SITES=("https://www.bing.com" "https://www.google.com" "https://www.github.com")

# 生成安全的UUID
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # FreeBSD fallback with better randomness
        local uuid=$(od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:upper:]' '[:lower:]')
        # Ensure proper UUID format
        echo "$uuid" | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/'
    fi
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65000
    echo $((RANDOM % (max_port - min_port + 1) + min_port))
}

# 检查端口是否被占用
check_port_available() {
    local port=$1
    if netstat -an | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# 获取可用端口
get_available_port() {
    local default_port=$1
    local port=$default_port
    
    if check_port_available "$port"; then
        echo "$port"
        return 0
    fi
    
    # 如果默认端口被占用，生成随机端口
    for i in {1..10}; do
        port=$(generate_random_port)
        if check_port_available "$port"; then
            echo "$port"
            return 0
        fi
    done
    
    red "无法找到可用端口"
    exit 1
}

# 获取本机IP（支持IPv6）
get_ip() {
    local ip4=$(curl -s4m8 ifconfig.me 2>/dev/null || curl -s4m8 ip.sb 2>/dev/null)
    local ip6=$(curl -s6m8 ifconfig.me 2>/dev/null || curl -s6m8 ip.sb 2>/dev/null)
    
    if [[ -n "$ip4" ]]; then
        echo "$ip4"
    elif [[ -n "$ip6" ]]; then
        echo "[$ip6]"
    else
        # 获取本地IP作为fallback
        ifconfig | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}'
    fi
}

# 下载sing-box
download_singbox() {
    green "正在下载sing-box..."
    
    # 尝试多个下载源
    local download_urls=(
        "http://pkg.freebsd.org/FreeBSD:14:amd64/latest/All/sing-box-1.11.9.pkg"
        "https://github.com/SagerNet/sing-box/releases/download/v1.11.9/sing-box-1.11.9-freebsd-amd64.tar.gz"
    )
    
    for url in "${download_urls[@]}"; do
        green "尝试从 $url 下载..."
        
        if [[ "$url" == *.pkg ]]; then
            # FreeBSD pkg格式
            if curl -L --connect-timeout 30 --max-time 300 -o "$WORKDIR/sing-box.pkg" "$url"; then
                cd "$WORKDIR"
                tar -xf sing-box.pkg
                if [[ -f usr/local/bin/sing-box ]]; then
                    cp usr/local/bin/sing-box "$SING_BOX_BIN"
                    chmod +x "$SING_BOX_BIN"
                    rm -rf usr sing-box.pkg
                    green "sing-box下载安装成功（pkg格式）"
                    return 0
                fi
            fi
        elif [[ "$url" == *.tar.gz ]]; then
            # tar.gz格式
            if curl -L --connect-timeout 30 --max-time 300 -o "$WORKDIR/sing-box.tar.gz" "$url"; then
                cd "$WORKDIR"
                tar -xzf sing-box.tar.gz
                if find . -name "sing-box" -type f -executable | head -1 | xargs -I {} cp {} "$SING_BOX_BIN"; then
                    chmod +x "$SING_BOX_BIN"
                    rm -rf sing-box-* sing-box.tar.gz
                    green "sing-box下载安装成功（tar.gz格式）"
                    return 0
                fi
            fi
        fi
    done
    
    red "所有下载源都失败"
    return 1
}

# 安装sing-box
install_singbox() {
    green "开始安装sing-box..."
    
    mkdir -p "$WORKDIR" "$BACKUP_DIR"
    cd "$WORKDIR"
    
    # 检查是否已安装
    if [[ -f "$SING_BOX_BIN" ]]; then
        local current_version=$("$SING_BOX_BIN" version 2>/dev/null | head -1 || echo "unknown")
        yellow "sing-box已存在，版本：$current_version"
        readp "是否重新下载？(y/N): " reinstall
        if [[ "$reinstall" != "y" && "$reinstall" != "Y" ]]; then
            return 0
        fi
    fi
    
    # 尝试使用pkg安装（如果有权限）
    if command -v pkg >/dev/null 2>&1; then
        green "尝试使用pkg安装sing-box..."
        if pkg install -y sing-box 2>/dev/null; then
            SING_BOX_BIN="/usr/local/bin/sing-box"
            green "sing-box安装成功（系统包）"
            return 0
        else
            yellow "pkg安装失败，尝试手动下载..."
        fi
    fi
    
    # 手动下载
    if ! download_singbox; then
        red "sing-box安装失败"
        return 1
    fi
    
    # 验证安装
    if "$SING_BOX_BIN" version >/dev/null 2>&1; then
        green "sing-box安装验证成功"
        return 0
    else
        red "sing-box安装验证失败"
        return 1
    fi
}

# 生成增强配置文件
generate_enhanced_config() {
    local uuid="$1"
    local server_ip="$2"
    
    # 随机选择Reality域名和伪装站点
    local reality_domain=${REALITY_DOMAINS[$RANDOM % ${#REALITY_DOMAINS[@]}]}
    local masquerade_site=${MASQUERADE_SITES[$RANDOM % ${#MASQUERADE_SITES[@]}]}
    
    # 获取可用端口
    VLESS_PORT=$(get_available_port $VLESS_PORT)
    VMESS_PORT=$(get_available_port $VMESS_PORT)
    HY2_PORT=$(get_available_port $HY2_PORT)
    
    green "使用端口：VLESS=$VLESS_PORT, VMess=$VMESS_PORT, Hysteria2=$HY2_PORT"
    green "Reality域名：$reality_domain"
    green "伪装站点：$masquerade_site"
    
    # 生成reality密钥对
    local reality_keys=$("$SING_BOX_BIN" generate reality-keypair 2>/dev/null)
    local private_key=$(echo "$reality_keys" | grep "PrivateKey:" | awk '{print $2}')
    local public_key=$(echo "$reality_keys" | grep "PublicKey:" | awk '{print $2}')
    
    # 保存密钥信息
    echo "$public_key" > "$WORKDIR/reality_public_key.txt"
    echo "$private_key" > "$WORKDIR/reality_private_key.txt"
    
    # 生成更安全的自签名证书
    openssl ecparam -genkey -name prime256v1 -out "$WORKDIR/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" \
        -subj "/C=US/ST=CA/L=San Francisco/O=Example Corp/CN=example.com" 2>/dev/null
    
    # 生成短ID
    local short_id=$(openssl rand -hex 8)
    
    # 备份旧配置
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$CONFIG_BACKUP"
        green "配置已备份到：$CONFIG_BACKUP"
    fi
    
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "info",
    "output": "$LOG_FILE",
    "timestamp": true
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "type": "vless",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$reality_domain",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$reality_domain",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    },
    {
      "tag": "vmess-ws",
      "type": "vmess",
      "listen": "::",
      "listen_port": $VMESS_PORT,
      "users": [
        {
          "uuid": "$uuid",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/$uuid-vm",
        "early_data_header_name": "Sec-WebSocket-Protocol",
        "max_early_data": 2048
      }
    },
    {
      "tag": "hysteria2",
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "masquerade": "$masquerade_site",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$WORKDIR/cert.pem",
        "key_path": "$WORKDIR/private.key"
      },
      "ignore_client_bandwidth": false
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ]
  }
}
EOF
    
    # 保存配置信息
    echo "$VLESS_PORT" > "$WORKDIR/vless_port.txt"
    echo "$VMESS_PORT" > "$WORKDIR/vmess_port.txt"
    echo "$HY2_PORT" > "$WORKDIR/hy2_port.txt"
    echo "$reality_domain" > "$WORKDIR/reality_domain.txt"
    echo "$short_id" > "$WORKDIR/short_id.txt"
    
    green "增强配置文件生成完成"
}

# 启动服务（增强版）
start_service() {
    if [[ -f "$PID_FILE" ]] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        yellow "服务已在运行中"
        return 0
    fi
    
    green "启动sing-box服务..."
    
    # 检查配置文件
    if ! "$SING_BOX_BIN" check -c "$CONFIG_FILE" 2>/dev/null; then
        red "配置文件验证失败"
        return 1
    fi
    
    # 启动服务
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    
    # 等待服务启动
    sleep 3
    
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        green "服务启动成功"
        
        # 显示监听端口
        sleep 2
        show_listening_ports
        return 0
    else
        red "服务启动失败"
        if [[ -f "$LOG_FILE" ]]; then
            red "错误日志："
            tail -10 "$LOG_FILE"
        fi
        return 1
    fi
}

# 显示监听端口
show_listening_ports() {
    green "当前监听端口："
    netstat -an | grep LISTEN | grep -E ":($(cat "$WORKDIR/"*_port.txt 2>/dev/null | tr '\n' '|' | sed 's/|$//'))"
}

# 停止服务
stop_service() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            rm -f "$PID_FILE"
            green "服务已停止"
        else
            yellow "服务未运行"
            rm -f "$PID_FILE"
        fi
    else
        yellow "服务未运行"
    fi
}

# 重启服务
restart_service() {
    stop_service
    sleep 2
    start_service
}

# 查看详细状态
show_detailed_status() {
    echo
    blue "=== 服务状态 ==="
    
    if [[ -f "$PID_FILE" ]] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        green "服务状态：运行中"
        green "PID：$(cat "$PID_FILE")"
        
        # 显示运行时间
        local start_time=$(stat -f %B "$PID_FILE" 2>/dev/null)
        if [[ -n "$start_time" ]]; then
            local current_time=$(date +%s)
            local uptime=$((current_time - start_time))
            green "运行时间：$(date -u -r $uptime +%H:%M:%S)"
        fi
        
        # 显示内存使用
        local pid=$(cat "$PID_FILE")
        local memory=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1/1024 " MB"}')
        if [[ -n "$memory" ]]; then
            green "内存使用：$memory"
        fi
        
        show_listening_ports
    else
        red "服务状态：未运行"
    fi
    
    # 显示配置信息
    if [[ -f "$WORKDIR/uuid.txt" ]]; then
        echo
        blue "=== 配置信息 ==="
        green "UUID：$(cat "$WORKDIR/uuid.txt")"
        green "服务器IP：$(cat "$WORKDIR/server_ip.txt")"
        
        if [[ -f "$WORKDIR/vless_port.txt" ]]; then
            green "VLESS端口：$(cat "$WORKDIR/vless_port.txt")"
        fi
        if [[ -f "$WORKDIR/vmess_port.txt" ]]; then
            green "VMess端口：$(cat "$WORKDIR/vmess_port.txt")"
        fi
        if [[ -f "$WORKDIR/hy2_port.txt" ]]; then
            green "Hysteria2端口：$(cat "$WORKDIR/hy2_port.txt")"
        fi
        if [[ -f "$WORKDIR/reality_domain.txt" ]]; then
            green "Reality域名：$(cat "$WORKDIR/reality_domain.txt")"
        fi
    fi
}

# 生成增强节点信息
generate_enhanced_links() {
    if [[ ! -f "$WORKDIR/uuid.txt" ]]; then
        red "配置文件不存在，请先安装"
        return 1
    fi
    
    local uuid=$(cat "$WORKDIR/uuid.txt")
    local server_ip=$(cat "$WORKDIR/server_ip.txt")
    local public_key=$(cat "$WORKDIR/reality_public_key.txt")
    local reality_domain=$(cat "$WORKDIR/reality_domain.txt")
    local short_id=$(cat "$WORKDIR/short_id.txt")
    local vless_port=$(cat "$WORKDIR/vless_port.txt")
    local vmess_port=$(cat "$WORKDIR/vmess_port.txt")
    local hy2_port=$(cat "$WORKDIR/hy2_port.txt")
    
    echo
    blue "=== 节点信息 ==="
    echo
    
    # VLESS Reality（增强版）
    local vless_link="vless://$uuid@$server_ip:$vless_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$reality_domain&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#FreeBSD-VLESS-Reality-Enhanced"
    green "VLESS Reality（增强版）:"
    echo "$vless_link"
    echo
    
    # VMess WS（增强版）
    local vmess_config='{"v":"2","ps":"FreeBSD-VMess-WS-Enhanced","add":"'$server_ip'","port":"'$vmess_port'","id":"'$uuid'","aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/'$uuid'-vm","tls":"","sni":"","alpn":""}'
    local vmess_link="vmess://$(echo -n "$vmess_config" | base64 -w 0)"
    green "VMess WS（增强版）:"
    echo "$vmess_link"
    echo
    
    # Hysteria2（增强版）
    local hy2_link="hysteria2://$uuid@$server_ip:$hy2_port?insecure=1&sni=www.bing.com#FreeBSD-Hysteria2-Enhanced"
    green "Hysteria2（增强版）:"
    echo "$hy2_link"
    echo
    
    # 生成订阅链接
    local subscription_content=$(cat << EOF
vless://$uuid@$server_ip:$vless_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$reality_domain&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#FreeBSD-VLESS-Reality
vmess://$(echo -n "$vmess_config" | base64 -w 0)
hysteria2://$uuid@$server_ip:$hy2_port?insecure=1&sni=www.bing.com#FreeBSD-Hysteria2
EOF
)
    
    local subscription_base64=$(echo -n "$subscription_content" | base64 -w 0)
    
    # 保存到文件
    cat > "$WORKDIR/links.txt" << EOF
VLESS Reality（增强版）:
$vless_link

VMess WS（增强版）:
$vmess_link

Hysteria2（增强版）:
$hy2_link

订阅链接（Base64）:
$subscription_base64
EOF
    
    green "节点信息已保存到：$WORKDIR/links.txt"
    
    # 显示二维码（如果有qrencode）
    if command -v qrencode >/dev/null 2>&1; then
        echo
        blue "=== 二维码 ==="
        echo "VLESS Reality:"
        echo "$vless_link" | qrencode -t ANSIUTF8
    fi
}

# 查看详细日志
show_detailed_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        yellow "日志文件不存在"
        return
    fi
    
    echo
    blue "=== 实时日志 ==="
    echo "按 Ctrl+C 退出日志查看"
    echo
    
    tail -f "$LOG_FILE"
}

# 性能优化
optimize_performance() {
    green "正在进行性能优化..."
    
    # 检查系统限制
    local max_files=$(ulimit -n)
    if [[ "$max_files" -lt 65536 ]]; then
        yellow "当前文件描述符限制：$max_files，建议增加到65536"
        echo "请在 ~/.profile 中添加：ulimit -n 65536"
    fi
    
    # 优化网络参数（如果有权限）
    if [[ -w /etc/sysctl.conf ]]; then
        green "优化网络参数..."
        cat >> /etc/sysctl.conf << EOF
# FreeBSD Proxy Optimization
net.inet.tcp.cc.algorithm=cubic
net.inet.tcp.sendspace=65536
net.inet.tcp.recvspace=65536
EOF
        sysctl -f /etc/sysctl.conf
    else
        yellow "无权限修改系统参数，跳过网络优化"
    fi
    
    green "性能优化完成"
}

# 安全检查
security_check() {
    green "正在进行安全检查..."
    
    # 检查文件权限
    chmod 600 "$WORKDIR"/*.txt "$WORKDIR"/*.key 2>/dev/null
    chmod 644 "$WORKDIR"/*.pem 2>/dev/null
    
    # 检查端口安全性
    local open_ports=$(netstat -an | grep LISTEN | wc -l)
    if [[ "$open_ports" -gt 20 ]]; then
        yellow "警告：系统开放了较多端口($open_ports)，请检查安全性"
    fi
    
    # 检查防火墙状态
    if command -v pfctl >/dev/null 2>&1; then
        if pfctl -s info >/dev/null 2>&1; then
            green "防火墙已启用"
        else
            yellow "警告：防火墙未启用，建议启用防火墙"
        fi
    fi
    
    green "安全检查完成"
}

# 备份配置
backup_config() {
    if [[ ! -d "$WORKDIR" ]]; then
        red "配置目录不存在"
        return 1
    fi
    
    local backup_file="$HOME/freebsd-proxy-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    
    green "正在备份配置到：$backup_file"
    
    tar -czf "$backup_file" -C "$HOME" ".freebsd-proxy" 2>/dev/null
    
    if [[ -f "$backup_file" ]]; then
        green "备份完成：$backup_file"
        echo "备份大小：$(du -h "$backup_file" | cut -f1)"
    else
        red "备份失败"
        return 1
    fi
}

# 恢复配置
restore_config() {
    readp "请输入备份文件路径: " backup_file
    
    if [[ ! -f "$backup_file" ]]; then
        red "备份文件不存在：$backup_file"
        return 1
    fi
    
    readp "确定要恢复配置吗？当前配置将被覆盖 (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        yellow "取消恢复"
        return
    fi
    
    green "正在恢复配置..."
    
    # 停止服务
    stop_service
    
    # 备份当前配置
    if [[ -d "$WORKDIR" ]]; then
        mv "$WORKDIR" "$WORKDIR.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 恢复配置
    tar -xzf "$backup_file" -C "$HOME" 2>/dev/null
    
    if [[ -d "$WORKDIR" ]]; then
        green "配置恢复成功"
        start_service
    else
        red "配置恢复失败"
        return 1
    fi
}

# 卸载（增强版）
uninstall_enhanced() {
    echo
    red "=== 卸载确认 ==="
    yellow "这将删除所有配置文件和数据"
    readp "确定要卸载吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        yellow "取消卸载"
        return
    fi
    
    readp "是否备份配置？(Y/n): " backup_confirm
    if [[ "$backup_confirm" != "n" && "$backup_confirm" != "N" ]]; then
        backup_config
    fi
    
    green "正在卸载..."
    
    stop_service
    
    # 删除快捷命令
    rm -f "$HOME/bin/freebsd-proxy"
    
    # 删除配置目录
    rm -rf "$WORKDIR"
    
    green "卸载完成"
}

# 安装主函数（增强版）
install_enhanced() {
    echo
    blue "=== FreeBSD科学上网脚本增强版安装 ==="
    purple "版本：$VERSION"
    echo
    
    check_system
    check_arch
    check_dependencies
    
    if ! install_singbox; then
        red "sing-box安装失败"
        exit 1
    fi
    
    local uuid=$(generate_uuid)
    local server_ip=$(get_ip)
    
    # 保存基本信息
    echo "$uuid" > "$WORKDIR/uuid.txt"
    echo "$server_ip" > "$WORKDIR/server_ip.txt"
    echo "$VERSION" > "$WORKDIR/version.txt"
    
    generate_enhanced_config "$uuid" "$server_ip"
    
    # 性能优化和安全检查
    optimize_performance
    security_check
    
    if start_service; then
        echo
        green "=== 安装完成！==="
        echo
        generate_enhanced_links
        echo
        blue "=== 管理命令 ==="
        echo "查看状态：$0 status"
        echo "查看节点：$0 links"
        echo "查看日志：$0 logs"
        echo "重启服务：$0 restart"
        echo
    else
        red "安装失败"
        exit 1
    fi
}

# 显示版本信息
show_version() {
    echo
    blue "$SCRIPT_NAME"
    green "版本：$VERSION"
    green "适用系统：FreeBSD 14.3-RELEASE amd64"
    green "作者：FreeBSD Proxy Team"
    echo
}

# 增强主菜单
show_enhanced_menu() {
    echo
    blue "=== FreeBSD科学上网管理脚本（增强版）==="
    purple "版本：$VERSION"
    echo
    green "1. 安装服务"
    green "2. 启动服务"
    green "3. 停止服务"
    green "4. 重启服务"
    green "5. 查看状态"
    green "6. 查看节点信息"
    green "7. 查看日志"
    green "8. 性能优化"
    green "9. 安全检查"
    green "10. 备份配置"
    green "11. 恢复配置"
    green "12. 卸载"
    green "13. 版本信息"
    green "0. 退出"
    echo
    readp "请选择操作 [0-13]: " choice
    
    case "$choice" in
        1) install_enhanced ;;
        2) start_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) show_detailed_status ;;
        6) generate_enhanced_links ;;
        7) show_detailed_logs ;;
        8) optimize_performance ;;
        9) security_check ;;
        10) backup_config ;;
        11) restore_config ;;
        12) uninstall_enhanced ;;
        13) show_version ;;
        0) exit 0 ;;
        *) red "无效选择" ;;
    esac
}

# 主程序
if [[ $# -eq 0 ]]; then
    while true; do
        show_enhanced_menu
    done
else
    case "$1" in
        install) install_enhanced ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) show_detailed_status ;;
        links) generate_enhanced_links ;;
        logs) show_detailed_logs ;;
        optimize) optimize_performance ;;
        security) security_check ;;
        backup) backup_config ;;
        restore) restore_config ;;
        uninstall) uninstall_enhanced ;;
        version) show_version ;;
        *) 
            echo "用法: $0 {install|start|stop|restart|status|links|logs|optimize|security|backup|restore|uninstall|version}"
            echo "或直接运行 $0 进入交互式菜单"
            ;;
    esac
fi