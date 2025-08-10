#!/bin/bash

# ==========================================
# FreeBSD科学上网一键部署脚本
# 支持VLESS+Reality/Vision/GRPC协议
# 自动配置防火墙、生成订阅、管理工具
# ==========================================

# Set shell options for better error handling
set -euo pipefail

# Color functions
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

# Global variables
UUID=""
DOMAIN=""
PRIVATE_KEY=""
PUBLIC_KEY=""
REALITY_PORT=""
VISION_PORT=""
GRPC_PORT=""
SERVER_IP=""
BASE_PATH="$HOME/sbx"

# Check environment
check_environment() {
    # Check if running on FreeBSD
    if [[ "$(uname)" != "FreeBSD" ]]; then
        red "错误：此脚本仅支持FreeBSD系统"
        exit 1
    fi
    
    # Warn for FreeBSD 14.x
    if uname -r | grep -q "14\."; then
        yellow "警告：FreeBSD 14.x版本可能存在兼容性问题"
        yellow "推荐使用FreeBSD 13.x版本"
        echo
    fi
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        red "错误：请勿以root用户运行此脚本"
        red "使用普通用户运行，脚本会在需要时提示输入密码"
        exit 1
    fi
    
    green "✓ 环境检查通过"
}

# Check dependencies  
check_dependencies() {
    local missing_tools=()
    
    # Check required tools
    for tool in jq openssl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    # Check for curl or fetch
    if ! command -v curl &> /dev/null && ! command -v fetch &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        red "错误：缺少必要工具：${missing_tools[*]}"
        echo
        yellow "请先安装缺少的工具："
        yellow "pkg install curl jq openssl"
        exit 1
    fi
    
    green "✓ 依赖检查通过"
}

# Generate UUID and other configs
generate_configs() {
    UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    REALITY_PORT=$((RANDOM % 10000 + 10000))
    VISION_PORT=$((REALITY_PORT + 1))
    GRPC_PORT=$((REALITY_PORT + 2))
    
    green "✓ 配置生成完成"
    blue "  UUID: $UUID"
    blue "  Reality端口: $REALITY_PORT"
    blue "  Vision端口: $VISION_PORT"  
    blue "  GRPC端口: $GRPC_PORT"
}

# Generate Reality keypair
generate_reality_keys() {
    local temp_output=$(./sb-amd64 generate reality-keypair)
    
    if [[ -z "$temp_output" ]]; then
        red "Reality密钥生成失败"
        exit 1
    fi
    
    # Extract keys from output
    PUBLIC_KEY=$(echo "$temp_output" | grep "PublicKey:" | cut -d' ' -f2)
    PRIVATE_KEY=$(echo "$temp_output" | grep "PrivateKey:" | cut -d' ' -f2)
    
    if [[ -z "$PUBLIC_KEY" || -z "$PRIVATE_KEY" ]]; then
        red "Reality密钥解析失败"
        exit 1
    fi
    
    green "✓ Reality密钥生成完成"
}

# Generate TLS certificate
generate_tls_cert() {
    # Generate private key (compatible with all OpenSSL versions)
    openssl genrsa -out private.key 2048
    
    # Generate self-signed certificate
    openssl req -new -x509 -key private.key -out cert.pem -days 365 -subj "/C=US/ST=CA/L=San Francisco/O=Example/OU=IT/CN=example.com"
    
    green "✓ TLS证书已生成"
}

# Get server IP (no external service)
get_server_ip() {
    # Method 1: Try route + ifconfig
    local iface
    if iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); then
        if [[ -n "$iface" ]]; then
            if SERVER_IP=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{if($2!="127.0.0.1") print $2; exit}'); then
                [[ -n "$SERVER_IP" ]] && green "✓ 服务器IP: $SERVER_IP" && return
            fi
        fi
    fi
    
    # Method 2: Try common interface names
    for iface in em0 re0 igb0 bge0 vtnet0; do
        if SERVER_IP=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{if($2!="127.0.0.1") print $2; exit}'); then
            [[ -n "$SERVER_IP" ]] && green "✓ 服务器IP: $SERVER_IP" && return
        fi
    done
    
    # Method 3: Parse all interfaces
    if SERVER_IP=$(ifconfig 2>/dev/null | awk '/inet /{if($2!="127.0.0.1" && $2!~/^169\.254\./ && $2!~/^10\./ && $2!~/^192\.168\./) print $2; exit}'); then
        [[ -n "$SERVER_IP" ]] && green "✓ 服务器IP: $SERVER_IP" && return
    fi
    
    # Method 4: Allow any non-loopback IP
    if SERVER_IP=$(ifconfig 2>/dev/null | awk '/inet /{if($2!="127.0.0.1" && $2!~/^169\.254\./) print $2; exit}'); then
        [[ -n "$SERVER_IP" ]] && green "✓ 服务器IP: $SERVER_IP" && return
    fi
    
    # Method 5: Use external service as fallback if curl available
    if command -v curl &> /dev/null; then
        if SERVER_IP=$(curl -s4 -m 5 https://api64.ipify.org 2>/dev/null); then
            [[ -n "$SERVER_IP" ]] && green "✓ 服务器IP (外部获取): $SERVER_IP" && return
        fi
    fi
    
    # Method 6: Manual input if all failed
    red "无法自动获取服务器IP地址"
    yellow "请查看可用网络接口："
    ifconfig 2>/dev/null | grep -E "^[a-z]|inet " || echo "无法获取接口信息"
    echo
    
    # In non-TTY environment, default to 0.0.0.0 with warning
    if [[ ! -t 0 ]]; then
        SERVER_IP="0.0.0.0"
        yellow "警告：非交互模式下使用占位符IP: $SERVER_IP"
        yellow "部署后请手动更新配置文件中的IP地址"
        return
    fi
    
    read -p "请手动输入服务器IP: " SERVER_IP < /dev/tty
    
    # Validate IP format
    if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        red "IP地址格式无效"
        exit 1
    fi
    
    green "✓ 服务器IP: $SERVER_IP"
}

# Interactive configuration
interactive_config() {
    echo
    blue "=== 配置向导 ==="

    # 如果是通过管道执行（stdin 不是 TTY），使用默认配置并跳过交互
    if [[ ! -t 0 ]]; then
        DOMAIN="www.yahoo.com"
        rules_choice="1"
        green "✓ 非交互模式：已使用默认配置"
        green "  伪装域名: $DOMAIN"
        green "  规则模式: ${rules_choice}"
        green "  端口配置: $REALITY_PORT, $VISION_PORT, $GRPC_PORT"
        return
    fi
    
    # Reality domain config
    echo
    yellow "Reality伪装域名配置："
    blue "1. www.yahoo.com (默认)"
    blue "2. www.microsoft.com"
    blue "3. 自定义域名"
    read -p "请选择 [1-3, 默认1]: " domain_choice < /dev/tty
    
    case "${domain_choice:-1}" in
        1)
            DOMAIN="www.yahoo.com"
            ;;
        2)
            DOMAIN="www.microsoft.com"
            ;;
        3)
            read -p "请输入自定义域名: " DOMAIN < /dev/tty
            ;;
        *)
            DOMAIN="www.yahoo.com"
            ;;
    esac
    
    # Rules config
    echo
    yellow "规则配置："
    blue "1. 在线规则集（推荐）"
    blue "2. 本地规则文件"
    read -p "请选择 [1-2, 默认1]: " rules_choice < /dev/tty
    
    # Port config
    echo
    yellow "端口配置："
    blue "Reality端口: $REALITY_PORT"
    blue "Vision端口: $VISION_PORT"
    blue "GRPC端口: $GRPC_PORT"
    read -p "是否修改端口? [y/N]: " change_port < /dev/tty
    
    if [[ "$change_port" =~ ^[yY] ]]; then
        read -p "Reality端口 [$REALITY_PORT]: " new_reality < /dev/tty
        read -p "Vision端口 [$VISION_PORT]: " new_vision < /dev/tty
        read -p "GRPC端口 [$GRPC_PORT]: " new_grpc < /dev/tty
        
        REALITY_PORT=${new_reality:-$REALITY_PORT}
        VISION_PORT=${new_vision:-$VISION_PORT}
        GRPC_PORT=${new_grpc:-$GRPC_PORT}
    fi
    
    green "✓ 交互配置完成"
    green "  伪装域名: $DOMAIN"
    green "  规则模式: ${rules_choice:-1}"
    green "  端口配置: $REALITY_PORT, $VISION_PORT, $GRPC_PORT"
}

# Download sing-box
download_singbox() {
    local arch
    
    case "$(uname -m)" in
        amd64|x86_64)
            arch="amd64"
            ;;
        arm64|aarch64)
            arch="arm64"
            ;;
        *)
            red "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
    
    local filename="sb-$arch"
    
    # Check if binary already exists
    if [[ -f "$filename" ]]; then
        green "✓ sing-box 二进制文件已存在"
        return
    fi
    
    blue "正在下载 sing-box..."
    
    # Try download methods
    local url="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-freebsd-$arch.tar.gz"
    local download_success=false
    
    if command -v curl &> /dev/null; then
        if curl -L -o "sing-box.tar.gz" "$url"; then
            download_success=true
        fi
    elif command -v fetch &> /dev/null; then
        if fetch -o "sing-box.tar.gz" "$url"; then
            download_success=true
        fi
    fi
    
    if [[ "$download_success" != true ]]; then
        red "下载失败，请检查网络连接"
        exit 1
    fi
    
    # Extract
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box "$filename"
    rm -rf sing-box-* sing-box.tar.gz
    chmod +x "$filename"
    
    green "✓ sing-box 下载完成"
}

# Setup working directory
setup_directory() {
    if [[ ! -d "$BASE_PATH" ]]; then
        mkdir -p "$BASE_PATH"
    fi
    
    cd "$BASE_PATH"
    green "✓ 工作目录: $BASE_PATH"
}

# Generate sing-box config
generate_config() {
    local rules_config
    
    if [[ "${rules_choice:-1}" == "1" ]]; then
        # Online rules
        rules_config='{
            "rules": [
                {
                    "rule_set": [
                        "geosite-category-ads-all",
                        "geosite-malware",
                        "geosite-phishing",
                        "geosite-cryptominers"
                    ],
                    "outbound": "block"
                },
                {
                    "rule_set": [
                        "geosite-private",
                        "geoip-private"
                    ],
                    "outbound": "direct"
                },
                {
                    "rule_set": [
                        "geosite-geolocation-!cn",
                        "geoip-telegram"
                    ],
                    "outbound": "proxy"
                },
                {
                    "rule_set": [
                        "geosite-cn",
                        "geoip-cn"
                    ],
                    "outbound": "direct"
                }
            ],
            "rule_set": [
                {
                    "tag": "geosite-category-ads-all",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"
                },
                {
                    "tag": "geosite-malware",
                    "type": "remote", 
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-malware.srs"
                },
                {
                    "tag": "geosite-phishing",
                    "type": "remote",
                    "format": "binary", 
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-phishing.srs"
                },
                {
                    "tag": "geosite-cryptominers",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cryptominers.srs"
                },
                {
                    "tag": "geosite-private",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-private.srs"
                },
                {
                    "tag": "geoip-private", 
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-private.srs"
                },
                {
                    "tag": "geosite-geolocation-!cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"
                },
                {
                    "tag": "geoip-telegram",
                    "type": "remote", 
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-telegram.srs"
                },
                {
                    "tag": "geosite-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
                },
                {
                    "tag": "geoip-cn",
                    "type": "remote",
                    "format": "binary", 
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
                }
            ]
        }'
    else
        # Local rules
        rules_config='{
            "rules": [
                {
                    "geosite": [
                        "category-ads-all"
                    ],
                    "outbound": "block"
                },
                {
                    "geosite": [
                        "private"
                    ],
                    "geoip": [
                        "private"
                    ],
                    "outbound": "direct"
                },
                {
                    "geosite": [
                        "geolocation-!cn"
                    ],
                    "outbound": "proxy"
                },
                {
                    "geosite": [
                        "cn"
                    ],
                    "geoip": [
                        "cn"
                    ],
                    "outbound": "direct"
                }
            ]
        }'
    fi

    # Create main config
    cat > config.json << EOF
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-in-vision",
            "listen": "::",
            "listen_port": $VISION_PORT,
            "users": [
                {
                    "uuid": "$UUID",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "certificate_path": "cert.pem",
                "key_path": "private.key"
            }
        },
        {
            "type": "vless",
            "tag": "vless-in-reality",
            "listen": "::",
            "listen_port": $REALITY_PORT,
            "users": [
                {
                    "uuid": "$UUID",
                    "flow": ""
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$DOMAIN",
                        "server_port": 443
                    },
                    "private_key": "$PRIVATE_KEY",
                    "short_id": [""]
                }
            }
        },
        {
            "type": "vless",
            "tag": "vless-in-grpc",
            "listen": "::",
            "listen_port": $GRPC_PORT,
            "users": [
                {
                    "uuid": "$UUID",
                    "flow": ""
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "certificate_path": "cert.pem",
                "key_path": "private.key"
            },
            "transport": {
                "type": "grpc",
                "service_name": "grpc"
            }
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
        },
        {
            "type": "dns",
            "tag": "dns-out"
        }
    ],
    "route": $rules_config
}
EOF

    green "✓ 配置文件已生成"
}

# Configure firewall
configure_firewall() {
    blue "正在配置防火墙..."
    
    # Check if pf is enabled
    if ! sudo pfctl -s info &>/dev/null; then
        yellow "警告：PF防火墙未启用，跳过防火墙配置"
        return
    fi
    
    # Add rules to pf.conf if not already present
    local pf_rules="
# Sing-box rules
pass in quick on any proto tcp from any to any port $REALITY_PORT
pass in quick on any proto tcp from any to any port $VISION_PORT  
pass in quick on any proto tcp from any to any port $GRPC_PORT
pass out quick on any proto tcp from any to any
pass out quick on any proto udp from any to any
"
    
    # Check if rules already exist
    if ! sudo grep -q "Sing-box rules" /etc/pf.conf 2>/dev/null; then
        echo "$pf_rules" | sudo tee -a /etc/pf.conf > /dev/null
        sudo pfctl -f /etc/pf.conf
        green "✓ 防火墙规则已添加"
    else
        yellow "防火墙规则已存在，跳过"
    fi
}

# Start sing-box
start_singbox() {
    blue "正在启动 sing-box..."
    
    # Kill existing process
    pkill -f "sb-amd64" 2>/dev/null || true
    
    # Start in background
    nohup ./sb-amd64 run -c config.json > singbox.log 2>&1 &
    
    sleep 3
    
    # Check if started successfully
    if pgrep -f "sb-amd64" > /dev/null; then
        green "✓ sing-box 启动成功"
    else
        red "sing-box 启动失败，请检查日志:"
        tail -20 singbox.log
        exit 1
    fi
}

# Generate subscription info
generate_subscription() {
    local reality_config vision_config grpc_config
    
    # Reality config
    reality_config="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=&type=tcp&headerType=none#Reality-$SERVER_IP"
    
    # Vision config  
    vision_config="vless://$UUID@$SERVER_IP:$VISION_PORT?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=tcp&headerType=none#Vision-$SERVER_IP"
    
    # GRPC config
    grpc_config="vless://$UUID@$SERVER_IP:$GRPC_PORT?encryption=none&flow=&security=tls&sni=$DOMAIN&type=grpc&serviceName=grpc&mode=gun#GRPC-$SERVER_IP"
    
    # Save to file
    cat > links.txt << EOF
$reality_config
$vision_config  
$grpc_config
EOF
    
    # Generate base64 subscription
    base64 links.txt > subscription.txt
    
    green "✓ 订阅信息已生成"
    green "  链接文件: $BASE_PATH/links.txt"
    green "  订阅文件: $BASE_PATH/subscription.txt"
    
    echo
    blue "=== 分享链接 ==="
    echo "Reality: $reality_config"
    echo "Vision: $vision_config"
    echo "GRPC: $grpc_config"
}

# Create management tools
create_management_tools() {
    # Status check script
    cat > check_status.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "=== Sing-box 状态 ==="
if pgrep -f "sb-amd64" > /dev/null; then
    echo "状态: 运行中"
    echo "进程ID: $(pgrep -f 'sb-amd64')"
    echo "端口监听:"
    sockstat -l | grep -E "($(jq -r '.inbounds[].listen_port' config.json | tr '\n' '|' | sed 's/|$//'))" 2>/dev/null || echo "无法获取端口信息"
else
    echo "状态: 未运行"
fi

echo
echo "=== 系统资源 ==="
echo "内存使用: $(free -h 2>/dev/null | awk 'NR==2{print $3"/"$2}' || echo '无法获取')"
echo "磁盘使用: $(df -h . | awk 'NR==2{print $3"/"$2" ("$5")"}')"

echo  
echo "=== 最新日志 ==="
tail -10 singbox.log 2>/dev/null || echo "无日志文件"
EOF

    # Restart script
    cat > restart.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "正在重启 sing-box..."
pkill -f "sb-amd64" 2>/dev/null || true
sleep 2

nohup ./sb-amd64 run -c config.json > singbox.log 2>&1 &
sleep 3

if pgrep -f "sb-amd64" > /dev/null; then
    echo "✓ sing-box 重启成功"
else
    echo "✗ sing-box 重启失败"
    tail -10 singbox.log
fi
EOF

    # Stop script
    cat > stop.sh << 'EOF'
#!/bin/bash
echo "正在停止 sing-box..."
if pgrep -f "sb-amd64" > /dev/null; then
    pkill -f "sb-amd64"
    sleep 2
    if ! pgrep -f "sb-amd64" > /dev/null; then
        echo "✓ sing-box 已停止"
    else
        echo "强制停止..."
        pkill -9 -f "sb-amd64"
        echo "✓ sing-box 已强制停止"
    fi
else
    echo "sing-box 未运行"
fi
EOF

    # Update rules script
    cat > update_rules.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "正在更新地理位置规则..."

# Create rules directory
mkdir -p rules

# Download latest geoip and geosite
download_file() {
    local url="$1"
    local output="$2"
    
    if command -v curl &> /dev/null; then
        curl -L -o "$output" "$url"
    elif command -v fetch &> /dev/null; then
        fetch -o "$output" "$url"
    else
        echo "错误：需要 curl 或 fetch"
        return 1
    fi
}

# Download geoip and geosite files
if download_file "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db" "rules/geoip.db" && \
   download_file "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db" "rules/geosite.db"; then
    echo "✓ 规则文件更新完成"
    
    # Restart if running
    if pgrep -f "sb-amd64" > /dev/null; then
        echo "正在重启 sing-box 以应用新规则..."
        ./restart.sh
    fi
else
    echo "✗ 规则文件更新失败"
fi
EOF

    # Subscription generator script
    cat > subscription.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

if [[ ! -f config.json ]]; then
    echo "错误：配置文件不存在"
    exit 1
fi

# Extract config from JSON
UUID=$(jq -r '.inbounds[0].users[0].uuid' config.json)
REALITY_PORT=$(jq -r '.inbounds[1].listen_port' config.json)
VISION_PORT=$(jq -r '.inbounds[0].listen_port' config.json)
GRPC_PORT=$(jq -r '.inbounds[2].listen_port' config.json)
DOMAIN=$(jq -r '.inbounds[1].tls.server_name' config.json)
PRIVATE_KEY=$(jq -r '.inbounds[1].tls.reality.private_key' config.json)

# Generate public key from private key
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | ./sb-amd64 generate reality-keypair --private-key-input | grep "PublicKey:" | cut -d' ' -f2)

# Get server IP
SERVER_IP=$(ifconfig | awk '/inet /{if($2!="127.0.0.1" && $2!~/^169\.254/ && $2!~/^10\./ && $2!~/^192\.168\./ && $2!~/^172\.(1[6-9]|2[0-9]|3[01])\./) print $2; exit}')
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(ifconfig | awk '/inet /{if($2!="127.0.0.1") print $2; exit}')
fi

# Generate links
REALITY_LINK="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=&type=tcp&headerType=none#Reality-$SERVER_IP"
VISION_LINK="vless://$UUID@$SERVER_IP:$VISION_PORT?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=tcp&headerType=none#Vision-$SERVER_IP"
GRPC_LINK="vless://$UUID@$SERVER_IP:$GRPC_PORT?encryption=none&flow=&security=tls&sni=$DOMAIN&type=grpc&serviceName=grpc&mode=gun#GRPC-$SERVER_IP"

# Save links
cat > links.txt << EOL
$REALITY_LINK
$VISION_LINK
$GRPC_LINK
EOL

# Generate subscription
base64 links.txt > subscription.txt

echo "✓ 订阅信息已更新"
echo "分享链接:"
echo "Reality: $REALITY_LINK"
echo "Vision: $VISION_LINK" 
echo "GRPC: $GRPC_LINK"
EOF

    # Management panel
    cat > SB << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

while true; do
    clear
    echo "================================"
    echo "       SB 管理面板"
    echo "================================"
    echo "1. 启动 Sing-box"
    echo "2. 停止 Sing-box"
    echo "3. 重启 Sing-box"
    echo "4. 查看状态"
    echo "5. 实时日志"
    echo "6. 更新地理规则"
    echo "7. 生成订阅"
    echo "8. 卸载"
    echo "0. 退出"
    echo "================================"
    
    read -p "请选择操作 [0-8]: " choice
    
    case $choice in
        1)
            if pgrep -f "sb-amd64" > /dev/null; then
                echo "sing-box 已在运行"
            else
                nohup ./sb-amd64 run -c config.json > singbox.log 2>&1 &
                sleep 2
                if pgrep -f "sb-amd64" > /dev/null; then
                    echo "✓ sing-box 启动成功"
                else
                    echo "✗ sing-box 启动失败"
                fi
            fi
            ;;
        2)
            ./stop.sh
            ;;
        3)
            ./restart.sh
            ;;
        4)
            ./check_status.sh
            ;;
        5)
            echo "按 Ctrl+C 退出日志查看"
            tail -f singbox.log
            ;;
        6)
            ./update_rules.sh
            ;;
        7)
            ./subscription.sh
            ;;
        8)
            read -p "确认卸载? [y/N]: " confirm
            if [[ "$confirm" =~ ^[yY] ]]; then
                ./stop.sh
                cd ..
                rm -rf "$(basename "$PWD")"
                echo "✓ 卸载完成"
                exit 0
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选择"
            ;;
    esac
    
    if [[ $choice != 5 ]]; then
        read -p "按回车继续..."
    fi
done
EOF

    # Make scripts executable
    chmod +x check_status.sh restart.sh stop.sh update_rules.sh subscription.sh SB
    
    green "✓ 管理工具已创建"
}

# Main function
main() {
    clear
    blue "==================================="
    blue "   FreeBSD科学上网一键部署脚本"
    blue "==================================="
    echo
    
    # Pre-deployment checks
    check_environment
    check_dependencies
    
    # Generate basic configs
    generate_configs
    get_server_ip
    
    # Interactive configuration
    interactive_config
    
    # Setup and download
    setup_directory
    download_singbox
    
    # Generate keys and certificates
    generate_reality_keys
    generate_tls_cert
    
    # Configure and start
    generate_config
    configure_firewall
    start_singbox
    
    # Post-deployment
    generate_subscription
    create_management_tools
    
    # Update geo rules
    blue "正在更新地理位置规则..."
    ./update_rules.sh
    
    echo
    green "部署完成！享受自由的网络环境！"
    yellow "管理命令："
    yellow "  查看状态: ./check_status.sh"
    yellow "  重启服务: ./restart.sh" 
    yellow "  停止服务: ./stop.sh"
    yellow "  更新规则: ./update_rules.sh"
    yellow "  重新生成订阅: ./subscription.sh"
    yellow "  管理面板: ./SB"
}

# Script entry point
# Support both file execution and pipe execution
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]] || [[ "${BASH_SOURCE[0]:-}" == "/dev/fd/"* ]] || [[ "${BASH_SOURCE[0]:-}" == "-" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
