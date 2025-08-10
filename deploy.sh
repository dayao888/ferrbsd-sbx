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
    local iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    if [[ -n "$iface" ]]; then
        SERVER_IP=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{if($2!="127.0.0.1") print $2; exit}')
    fi
    
    # Method 2: Try common interface names
    if [[ -z "$SERVER_IP" ]]; then
        for iface in em0 re0 igb0 bge0 vtnet0; do
            if SERVER_IP=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{if($2!="127.0.0.1") print $2; exit}'); then
                [[ -n "$SERVER_IP" ]] && break
            fi
        done
    fi
    
    # Method 3: Parse all interfaces
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ifconfig 2>/dev/null | awk '/inet /{if($2!="127.0.0.1" && $2!~/^169\.254\./ && $2!~/^10\./ && $2!~/^192\.168\./) print $2; exit}')
    fi
    
    # Method 4: Allow any non-loopback IP
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ifconfig 2>/dev/null | awk '/inet /{if($2!="127.0.0.1" && $2!~/^169\.254\./) print $2; exit}')
    fi
    
    # Method 5: Manual input if all failed
    if [[ -z "$SERVER_IP" ]]; then
        red "无法自动获取服务器IP地址"
        yellow "请查看可用网络接口："
        ifconfig 2>/dev/null | grep -E "^[a-z]|inet " || echo "无法获取接口信息"
        echo
        
        # 如果是通过管道执行，设置默认IP
        if [[ ! -t 0 ]]; then
            SERVER_IP="YOUR_SERVER_IP"
            yellow "⚠ 非交互模式：请手动修改配置中的服务器IP"
        else
            read -p "请手动输入服务器IP: " SERVER_IP < /dev/tty
        
            # Validate IP format
            if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                red "IP地址格式无效"
                exit 1
            fi
        fi
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
pass out quick on any proto tcp from any to any port 443
pass out quick on any proto tcp from any to any port 80
pass out quick on any proto udp from any to any port 53"
    
    # Backup pf.conf
    sudo cp /etc/pf.conf /etc/pf.conf.backup."$(date +%s)" 2>/dev/null || true
    
    # Check if rules already exist
    if ! grep -q "# Sing-box rules" /etc/pf.conf 2>/dev/null; then
        echo "$pf_rules" | sudo tee -a /etc/pf.conf > /dev/null
        sudo pfctl -f /etc/pf.conf 2>/dev/null || {
            yellow "警告：防火墙规则加载失败，可能需要手动配置"
        }
        green "✓ 防火墙配置完成"
    else
        green "✓ 防火墙规则已存在"
    fi
}

# Start services
start_services() {
    blue "正在启动 sing-box 服务..."
    
    # Stop existing service if running
    if pgrep -f "sb-" > /dev/null; then
        pkill -f "sb-"
        sleep 2
    fi
    
    # Start sing-box with nohup
    nohup ./sb-amd64 run -c config.json > sing-box.log 2>&1 &
    
    # Wait and check if started successfully
    sleep 3
    if pgrep -f "sb-" > /dev/null; then
        green "✓ sing-box 服务已启动"
        blue "  日志文件: $BASE_PATH/sing-box.log"
    else
        red "sing-box 启动失败，请检查日志文件"
        tail -n 20 sing-box.log 2>/dev/null || echo "无法读取日志文件"
        exit 1
    fi
}

# Generate subscription links
generate_subscription() {
    blue "正在生成订阅链接..."
    
    cat > subscription.txt << EOF
科学上网节点信息
==================

VLESS Reality协议:
vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=&type=tcp&headerType=none#FreeBSD-Reality

VLESS Vision协议:
vless://$UUID@$SERVER_IP:$VISION_PORT?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=tcp&headerType=none#FreeBSD-Vision

VLESS GRPC协议:
vless://$UUID@$SERVER_IP:$GRPC_PORT?encryption=none&flow=&security=tls&sni=$DOMAIN&type=grpc&serviceName=grpc&mode=gun#FreeBSD-GRPC

==================
配置说明：
服务器地址: $SERVER_IP
UUID: $UUID
Reality端口: $REALITY_PORT
Vision端口: $VISION_PORT
GRPC端口: $GRPC_PORT
伪装域名: $DOMAIN
Reality公钥: $PUBLIC_KEY
==================
EOF
    
    green "✓ 订阅文件已生成: $BASE_PATH/subscription.txt"
}

# Create management tools
create_management_tools() {
    blue "正在创建管理工具..."

    # Create main management script
    cat > SB << 'EOF'
#!/bin/bash

BASE_PATH="$HOME/sbx"
cd "$BASE_PATH" || exit 1

# Color functions
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

show_menu() {
    clear
    blue "=================================="
    blue "    FreeBSD Sing-box 管理面板"
    blue "=================================="
    echo
    green "1. 启动 sing-box"
    green "2. 停止 sing-box"
    green "3. 重启 sing-box"
    green "4. 查看状态"
    green "5. 实时日志"
    green "6. 更新地理规则"
    green "7. 生成订阅"
    green "8. 卸载"
    red "0. 退出"
    echo
}

start_singbox() {
    if pgrep -f "sb-" > /dev/null; then
        yellow "sing-box 已在运行"
        return
    fi
    
    blue "正在启动 sing-box..."
    nohup ./sb-amd64 run -c config.json > sing-box.log 2>&1 &
    sleep 2
    
    if pgrep -f "sb-" > /dev/null; then
        green "✓ sing-box 启动成功"
    else
        red "✗ sing-box 启动失败"
        echo "最近日志："
        tail -n 10 sing-box.log 2>/dev/null
    fi
}

stop_singbox() {
    if ! pgrep -f "sb-" > /dev/null; then
        yellow "sing-box 未运行"
        return
    fi
    
    blue "正在停止 sing-box..."
    pkill -f "sb-"
    sleep 2
    
    if ! pgrep -f "sb-" > /dev/null; then
        green "✓ sing-box 已停止"
    else
        red "✗ 停止失败，强制终止"
        pkill -9 -f "sb-"
    fi
}

restart_singbox() {
    stop_singbox
    sleep 1
    start_singbox
}

show_status() {
    if pgrep -f "sb-" > /dev/null; then
        green "状态：运行中"
        echo "进程信息："
        ps aux | grep "[s]b-" || echo "无法获取进程信息"
    else
        red "状态：未运行"
    fi
    
    echo
    echo "端口监听状态："
    netstat -an | grep -E ":$(grep listen_port config.json | head -3 | grep -o '[0-9]\+' | tr '\n' '|' | sed 's/|$//')" || echo "无监听端口"
}

show_logs() {
    blue "实时日志 (按 Ctrl+C 退出)："
    echo
    tail -f sing-box.log 2>/dev/null || {
        red "无法读取日志文件"
        return
    }
}

update_rules() {
    if [[ -f "update_rules.sh" ]]; then
        ./update_rules.sh
    else
        blue "正在更新地理规则..."
        stop_singbox
        rm -rf *.srs 2>/dev/null
        start_singbox
        green "✓ 规则文件已清理，将在下次连接时重新下载"
    fi
}

generate_subscription() {
    if [[ -f "subscription.sh" ]]; then
        ./subscription.sh
    else
        if [[ -f "subscription.txt" ]]; then
            green "订阅信息："
            cat subscription.txt
        else
            red "订阅文件不存在"
        fi
    fi
}

uninstall() {
    read -p "确定要卸载吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[yY] ]]; then
        stop_singbox
        cd "$HOME" || exit 1
        rm -rf "$BASE_PATH"
        green "✓ 卸载完成"
        exit 0
    fi
}

# Handle command line arguments
case "${1:-}" in
    --start)
        start_singbox
        exit 0
        ;;
    --stop)
        stop_singbox  
        exit 0
        ;;
    --restart)
        restart_singbox
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    --logs)
        show_logs
        exit 0
        ;;
esac

# Interactive menu
while true; do
    show_menu
    read -p "请选择操作 [0-8]: " choice
    
    case $choice in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        4) show_status ;;
        5) show_logs ;;
        6) update_rules ;;
        7) generate_subscription ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) red "无效选择" ;;
    esac
    
    read -p "按 Enter 继续..."
done
EOF

    # Create individual management scripts
    cat > check_status.sh << 'EOF'
#!/bin/bash
cd "$HOME/sbx" || exit 1

if pgrep -f "sb-" > /dev/null; then
    echo "✓ sing-box 运行中"
    ps aux | grep "[s]b-"
else
    echo "✗ sing-box 未运行"
fi

echo
echo "端口监听："
netstat -an | grep -E ":$(grep listen_port config.json | head -3 | grep -o '[0-9]\+' | tr '\n' '|' | sed 's/|$//')" 2>/dev/null || echo "无监听端口"
EOF

    cat > restart.sh << 'EOF'
#!/bin/bash
cd "$HOME/sbx" || exit 1

echo "重启 sing-box..."
pkill -f "sb-" 2>/dev/null
sleep 2
nohup ./sb-amd64 run -c config.json > sing-box.log 2>&1 &
sleep 2

if pgrep -f "sb-" > /dev/null; then
    echo "✓ 重启成功"
else
    echo "✗ 重启失败"
    tail -n 10 sing-box.log
fi
EOF

    cat > stop.sh << 'EOF'
#!/bin/bash
cd "$HOME/sbx" || exit 1

echo "停止 sing-box..."
pkill -f "sb-"
sleep 2

if ! pgrep -f "sb-" > /dev/null; then
    echo "✓ 已停止"
else
    echo "强制终止..."
    pkill -9 -f "sb-"
fi
EOF

    cat > update_rules.sh << 'EOF'
#!/bin/bash
cd "$HOME/sbx" || exit 1

echo "更新地理规则文件..."
pkill -f "sb-" 2>/dev/null
sleep 2

# Clear old rule files
rm -f *.srs 2>/dev/null

echo "重启 sing-box..."
nohup ./sb-amd64 run -c config.json > sing-box.log 2>&1 &
sleep 3

if pgrep -f "sb-" > /dev/null; then
    echo "✓ 规则更新完成"
else
    echo "✗ 启动失败"
    tail -n 10 sing-box.log
fi
EOF

    cat > subscription.sh << 'EOF'
#!/bin/bash
cd "$HOME/sbx" || exit 1

if [[ -f "subscription.txt" ]]; then
    echo "节点订阅信息："
    echo "=================="
    cat subscription.txt
    echo "=================="
    echo
    echo "文件位置: $HOME/sbx/subscription.txt"
else
    echo "订阅文件不存在"
fi
EOF

    # Make all scripts executable
    chmod +x SB check_status.sh restart.sh stop.sh update_rules.sh subscription.sh
    
    green "✓ 管理工具已创建"
    blue "  主管理工具: ./SB"
    blue "  快捷命令: ./SB --start|--stop|--restart|--status|--logs"
}

# Update geo rules
update_geo_rules() {
    blue "正在更新地理规则..."
    
    # Rules will be downloaded automatically when sing-box starts
    # Just clear any existing cached rules
    rm -f *.srs 2>/dev/null
    
    green "✓ 地理规则缓存已清理，将在服务启动时自动下载"
}

# Main deployment function
main() {
    echo "==================================="
    echo "   FreeBSD科学上网一键部署脚本"
    echo "==================================="
    echo
    
    check_environment
    check_dependencies
    generate_configs
    
    setup_directory
    get_server_ip
    interactive_config
    
    download_singbox
    generate_reality_keys
    generate_tls_cert
    generate_config
    
    configure_firewall
    start_services
    generate_subscription
    create_management_tools
    update_geo_rules
    
    echo
    green "🎉 部署完成！"
    echo
    blue "管理命令："
    blue "  查看状态: $BASE_PATH/check_status.sh"
    blue "  重启服务: $BASE_PATH/restart.sh"  
    blue "  停止服务: $BASE_PATH/stop.sh"
    blue "  更新规则: $BASE_PATH/update_rules.sh"
    blue "  查看订阅: $BASE_PATH/subscription.sh"
    blue "  管理面板: $BASE_PATH/SB"
    echo
    blue "快捷管理："
    blue "  cd $BASE_PATH && ./SB"
    echo
    yellow "注意：订阅文件在 $BASE_PATH/subscription.txt"
    yellow "如服务器IP获取错误，请手动修改配置文件中的IP地址"
}

# Script entry point - handle both file execution and piped execution
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]] || [[ "${BASH_SOURCE[0]:-}" =~ /dev/fd/ ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi