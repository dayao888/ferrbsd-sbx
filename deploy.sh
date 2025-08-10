#!/usr/bin/env bash

# =============================================================================
# FreeBSD Scientific Internet Access Deployment Script
# 
# Author: Self-developed, Clean & Secure Implementation
# Platform: FreeBSD 14.3-RELEASE amd64 (No root required)
# Protocols: VLESS+Reality, VMess+WebSocket, Hysteria2
# Source: https://github.com/dayao888/ferrbsd-sbx
# =============================================================================

# Color output functions
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
purple() { echo -e "\033[35m\033[01m$1\033[0m"; }
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }

# Global variables
SCRIPT_VERSION="1.0.0"
GITHUB_REPO="https://github.com/dayao888/ferrbsd-sbx"
BASE_PATH="$HOME/sbx"
SB_BINARY="sb-amd64"
CONFIG_FILE="config.json"
UUID=""
VLESS_PORT=""
VMESS_PORT=""
HY2_PORT=""
SERVER_IP=""
REALITY_DOMAIN=""
PRIVATE_KEY=""
PUBLIC_KEY=""

# Check FreeBSD environment
check_environment() {
    if [[ ! "$(uname)" == "FreeBSD" ]]; then
        red "错误：此脚本仅支持FreeBSD系统"
        exit 1
    fi
    
    if [[ ! "$(uname -r)" =~ ^14\. ]]; then
        yellow "警告：建议使用FreeBSD 14.x版本"
    fi
    
    if [[ $EUID -eq 0 ]]; then
        red "错误：不要使用root用户运行此脚本"
        exit 1
    fi
    
    green "✓ FreeBSD环境检查通过"
}

# Check required tools
check_dependencies() {
    local missing_tools=()
    
    for tool in jq openssl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # 可选工具：nc用于握手端口检测
    if ! command -v nc >/dev/null 2>&1; then
        yellow "提示：未检测到 nc（netcat），将默认使用 443 作为握手端口"
    fi
    
    # 下载工具至少有一个
    if ! command -v fetch >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing_tools+=("fetch或curl")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        red "错误：缺少必要工具: ${missing_tools[*]}"
        yellow "请使用以下命令安装："
        yellow "pkg install curl jq openssl"
        exit 1
    fi
    
    green "✓ 依赖工具检查通过"
}

# Generate UUID
generate_uuid() {
    UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    green "✓ UUID已生成: $UUID"
}

# Get available ports
get_available_ports() {
    local start_port=10000
    local end_port=65000
    local ports=()
    
    while [[ ${#ports[@]} -lt 3 ]]; do
        local port=$((RANDOM % (end_port - start_port + 1) + start_port))
        local used=0
        
        if command -v sockstat >/dev/null 2>&1; then
            if sockstat -4 -6 -l | awk '{print $6}' | grep -E ":$port$" >/dev/null 2>&1; then
                used=1
            fi
        else
            if netstat -an | grep -E "\.$port .*LISTEN" >/dev/null 2>&1; then
                used=1
            fi
        fi
        
        if [[ $used -eq 0 ]]; then
            ports+=($port)
        fi
    done
    
    VLESS_PORT=${ports[0]}
    VMESS_PORT=${ports[1]}
    HY2_PORT=${ports[2]}
    
    green "✓ 端口分配完成:"
    green "  VLESS Reality: $VLESS_PORT"
    green "  VMess WebSocket: $VMESS_PORT"
    green "  Hysteria2: $HY2_PORT"
}

# Generate Reality keys
generate_reality_keys() {
    local key_pair=$(./sb-amd64 generate reality-keypair)
    PRIVATE_KEY=$(echo "$key_pair" | grep "PrivateKey:" | cut -d' ' -f2)
    PUBLIC_KEY=$(echo "$key_pair" | grep "PublicKey:" | cut -d' ' -f2)
    
    # 保存公钥供订阅脚本使用
    echo -n "$PUBLIC_KEY" > reality.pub
    
    green "✓ Reality密钥对已生成"
}

# Generate TLS certificate
generate_tls_cert() {
    # Generate private key
    openssl genpkey -algorithm RSA -out private.key -pkcs8 -pkeyopt rsa_keygen_bits:2048
    
    # Generate self-signed certificate
    openssl req -new -x509 -key private.key -out cert.pem -days 365 -subj "/C=US/ST=CA/L=San Francisco/O=Example/OU=IT/CN=example.com"
    
    green "✓ TLS证书已生成"
}

# Get server IP (no external service)
get_server_ip() {
    # 通过默认路由接口获取IPv4
    local iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    if [[ -n "$iface" ]]; then
        SERVER_IP=$(ifconfig "$iface" | awk '/inet /{print $2; exit}')
    fi
    
    if [[ -z "$SERVER_IP" ]]; then
        yellow "未能自动获取公网IP。"
        read -p "请输入用于客户端的服务器地址（IP或域名）: " SERVER_IP
    fi
    
    if [[ -z "$SERVER_IP" ]]; then
        red "错误：必须提供服务器地址"
        exit 1
    fi
    
    echo -n "$SERVER_IP" > server.addr
    green "✓ 服务器地址: $SERVER_IP"
}

# Interactive configuration
interactive_config() {
    blue "=== FreeBSD科学上网配置向导 ==="
    echo
    
    # Reality domain
    while true; do
        read -p "请输入Reality伪装域名 (默认: www.yahoo.com): " reality_input
        REALITY_DOMAIN=${reality_input:-"www.yahoo.com"}
        
        # Test domain connectivity and detect handshake port
        REALITY_HANDSHAKE_PORT=443
        if curl -s --connect-timeout 5 "https://$REALITY_DOMAIN" > /dev/null; then
            green "✓ 域名连通性测试通过: $REALITY_DOMAIN"
            # 尝试检测是否支持443端口
            if nc -z -w3 "$REALITY_DOMAIN" 443 2>/dev/null; then
                REALITY_HANDSHAKE_PORT=443
            elif nc -z -w3 "$REALITY_DOMAIN" 80 2>/dev/null; then
                REALITY_HANDSHAKE_PORT=80
                yellow "注意：域名 $REALITY_DOMAIN 将使用端口 80 进行握手"
            fi
            break
        else
            yellow "警告：域名连通性测试失败，但仍可继续使用"
            break
        fi
    done
    
    # Rules mode selection
    echo
    yellow "请选择规则集模式："
    yellow "1. 在线模式 (实时更新，需要网络连接)"
    yellow "2. 本地模式 (使用本地rules目录文件)"
    yellow "3. 混合模式 (优先本地，回退在线)"
    read -p "请选择 [1-3] (默认: 3): " rules_mode
    RULES_MODE=${rules_mode:-3}
    
    case $RULES_MODE in
        1) green "✓ 已选择：在线规则模式" ;;
        2) green "✓ 已选择：本地规则模式" ;;
        3) green "✓ 已选择：混合规则模式" ;;
        *) RULES_MODE=3; green "✓ 默认选择：混合规则模式" ;;
    esac
    
    echo "$RULES_MODE" > RULES_MODE
    
    # Port configuration (optional)
    echo
    yellow "端口配置（直接回车使用自动分配的端口）:"
    
    read -p "VLESS Reality端口 (当前: $VLESS_PORT): " vless_input
    if [[ -n "$vless_input" && "$vless_input" =~ ^[0-9]+$ ]]; then
        VLESS_PORT=$vless_input
    fi
    
    read -p "VMess WebSocket端口 (当前: $VMESS_PORT): " vmess_input
    if [[ -n "$vmess_input" && "$vmess_input" =~ ^[0-9]+$ ]]; then
        VMESS_PORT=$vmess_input
    fi
    
    read -p "Hysteria2端口 (当前: $HY2_PORT): " hy2_input
    if [[ -n "$hy2_input" && "$hy2_input" =~ ^[0-9]+$ ]]; then
        HY2_PORT=$hy2_input
    fi
    
    green "✓ 配置完成"
}

# Download sing-box binary
download_singbox() {
    green "正在下载sing-box二进制文件..."
    
    local download_url="$GITHUB_REPO/releases/download/v1/sb-amd64"
    local fallback_raw_url="https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main/sb-amd64"
    
    if command -v fetch >/dev/null 2>&1; then
        fetch -o sb-amd64 "$download_url" || true
    fi
    
    if [[ ! -f sb-amd64 || ! -s sb-amd64 ]]; then
        if command -v curl >/dev/null 2>&1; then
            curl -L -o sb-amd64 "$download_url" || true
        fi
    fi

    # Fallback to raw file in main branch if release asset is unavailable
    if [[ ! -f sb-amd64 || ! -s sb-amd64 ]]; then
        yellow "主发布资源获取失败，尝试备用地址下载..."
        if command -v fetch >/dev/null 2>&1; then
            fetch -o sb-amd64 "$fallback_raw_url" || true
        fi
        if [[ ! -f sb-amd64 || ! -s sb-amd64 ]]; then
            if command -v curl >/dev/null 2>&1; then
                curl -L -o sb-amd64 "$fallback_raw_url" || true
            fi
        fi
    fi
    
    if [[ -f sb-amd64 && -s sb-amd64 ]]; then
        chmod +x sb-amd64
        green "✓ sing-box下载完成"
    else
        red "错误：sing-box下载失败"
        exit 1
    fi
}

# Generate sing-box configuration
generate_config() {
    # 构造规则集配置块
    local rule_set_json=""
    if [[ "$RULES_MODE" == "1" ]]; then
        # 在线模式
        rule_set_json='[
            {
                "tag": "geoip-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
                "download_detour": "direct"
            },
            {
                "tag": "geosite-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
                "download_detour": "direct"
            }
        ]'
    elif [[ "$RULES_MODE" == "2" ]]; then
        # 本地模式
        mkdir -p rules
        rule_set_json='[
            {
                "tag": "geoip-cn",
                "type": "local",
                "format": "binary",
                "path": "rules/geoip-cn.srs"
            },
            {
                "tag": "geosite-cn",
                "type": "local",
                "format": "binary",
                "path": "rules/geosite-cn.srs"
            }
        ]'
    else
        # 混合模式：优先本地，如果本地文件不存在则自动切换到在线模式
        mkdir -p rules
        if [[ -f "rules/geoip-cn.srs" && -f "rules/geosite-cn.srs" ]]; then
            rule_set_json='[
                {
                    "tag": "geoip-cn",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geoip-cn.srs"
                },
                {
                    "tag": "geosite-cn",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geosite-cn.srs"
                }
            ]'
            green "✓ 使用本地规则文件"
        else
            rule_set_json='[
                {
                    "tag": "geoip-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
                    "download_detour": "direct"
                },
                {
                    "tag": "geosite-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
                    "download_detour": "direct"
                }
            ]'
            yellow "本地规则文件不存在，回退到在线模式。可运行 ./update_rules.sh 下载本地规则"
        fi
    fi

    cat > "$CONFIG_FILE" <<EOF
{
    "log": {
        "level": "info"
    },
    "inbounds": [
        {
            "tag": "hysteria2-in",
            "type": "hysteria2",
            "listen": "0.0.0.0",
            "listen_port": $HY2_PORT,
            "users": [
                {
                    "password": "$UUID"
                }
            ],
            "masquerade": "https://www.bing.com",
            "ignore_client_bandwidth": false,
            "tls": {
                "enabled": true,
                "alpn": ["h3"],
                "certificate_path": "cert.pem",
                "key_path": "private.key"
            }
        },
        {
            "tag": "vless-reality-vision",
            "type": "vless",
            "listen": "0.0.0.0",
            "listen_port": $VLESS_PORT,
            "users": [
                {
                    "uuid": "$UUID",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$REALITY_DOMAIN",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$REALITY_DOMAIN",
                        "server_port": ${REALITY_HANDSHAKE_PORT:-443}
                    },
                    "private_key": "$PRIVATE_KEY",
                    "short_id": [""]
                }
            }
        },
        {
            "tag": "vmess-ws-in",
            "type": "vmess",
            "listen": "0.0.0.0",
            "listen_port": $VMESS_PORT,
            "users": [
                {
                    "uuid": "$UUID"
                }
            ],
            "transport": {
                "type": "ws",
                "path": "/$UUID-vm",
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "rule_set": $rule_set_json,
        "rules": [
            {
                "rule_set": ["geoip-cn", "geosite-cn"],
                "outbound": "direct"
            }
        ],
        "final": "direct"
    }
}
EOF
    
    green "✓ sing-box配置文件已生成"
}

# Start sing-box service
start_singbox() {
    # Kill existing processes
    pkill -f "sb-amd64" > /dev/null 2>&1
    sleep 2
    
    # Start sing-box
    nohup ./sb-amd64 run -c "$CONFIG_FILE" > sb.log 2>&1 &
    sleep 3
    
    # Check if started successfully
    if pgrep -f "sb-amd64" > /dev/null; then
        green "✓ sing-box服务已启动"
    else
        red "错误：sing-box启动失败"
        cat sb.log
        exit 1
    fi
}

# Generate share links
generate_share_links() {
    # VLESS Reality link
    local vless_link="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&type=tcp#VLESS-Reality-$SERVER_IP"
    
    # VMess WebSocket link  
    local vmess_config="{\"v\":\"2\",\"ps\":\"VMess-WS-$SERVER_IP\",\"add\":\"$SERVER_IP\",\"port\":\"$VMESS_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/$UUID-vm\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\"}"
    local vmess_link="vmess://$(printf %s "$vmess_config" | base64 | tr -d '\n')"
    
    # Hysteria2 link
    local hy2_link="hysteria2://$UUID@$SERVER_IP:$HY2_PORT?insecure=1&sni=www.bing.com#Hysteria2-$SERVER_IP"
    
    # Create subscription file
    mkdir -p subscriptions
    cat > "subscriptions/${UUID}_v2sub.txt" <<EOF
$vless_link
$vmess_link  
$hy2_link
EOF
    
    # Display results
    blue "======================== 部署完成 ========================"
    echo
    green "服务器信息:"
    echo "  IP地址: $SERVER_IP"
    echo "  UUID: $UUID"
    echo "  VLESS端口: $VLESS_PORT"
    echo "  VMess端口: $VMESS_PORT"  
    echo "  Hysteria2端口: $HY2_PORT"
    echo
    green "分享链接:"
    echo
    yellow "1. VLESS Reality:"
    echo "$vless_link"
    echo
    yellow "2. VMess WebSocket:"
    echo "$vmess_link"
    echo
    yellow "3. Hysteria2:"
    echo "$hy2_link"
    echo
    green "订阅文件已保存到: subscriptions/${UUID}_v2sub.txt"
    blue "=========================================================="
}

# Create management tools
create_management_tools() {
    # Status check script
    cat > check_status.sh <<'EOF'
#!/bin/bash
if pgrep -f "sb-amd64" > /dev/null; then
    echo "✓ sing-box正在运行"
    echo "进程ID: $(pgrep -f "sb-amd64")"
else
    echo "✗ sing-box未运行"
fi
EOF
    chmod +x check_status.sh
    
    # Restart script
    cat > restart.sh <<'EOF'
#!/bin/bash
echo "正在重启sing-box..."
pkill -f "sb-amd64"
sleep 2
nohup ./sb-amd64 run -c config.json > sb.log 2>&1 &
sleep 3
if pgrep -f "sb-amd64" > /dev/null; then
    echo "✓ sing-box重启成功"
else
    echo "✗ sing-box重启失败"
fi
EOF
    chmod +x restart.sh
    
    # Stop script
    cat > stop.sh <<'EOF'
#!/bin/bash
echo "正在停止sing-box..."
pkill -f "sb-amd64"
echo "✓ sing-box已停止"
EOF
    chmod +x stop.sh
    
    # Make rules update script executable
    chmod +x update_rules.sh
    
    # Interactive management panel: SB
    cat > SB <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$base_dir"

SB_BIN="./sb-amd64"
CONFIG="config.json"
LOGF="sb.log"

print_menu() {
  clear
  echo "================== SB 管理面板 =================="
  echo "1) 启动 sing-box"
  echo "2) 停止 sing-box"
  echo "3) 重启 sing-box"
  echo "4) 查看状态"
  echo "5) 实时日志"
  echo "6) 更新地理规则 (GeoIP/GeoSite)"
  echo "7) 生成/查看订阅 (V2rayN/Clash/Sing-box)"
  echo "8) 卸载 (停止并删除当前目录下的相关文件)"
  echo "9) 退出"
  echo "================================================"
}

start_sb() {
  if pgrep -f "sb-amd64" >/dev/null; then
    echo "sing-box 已在运行"
    return
  fi
  if [[ ! -x "$SB_BIN" ]]; then
    echo "找不到 $SB_BIN，请先运行部署脚本或下载内核"; return 1
  fi
  if [[ ! -f "$CONFIG" ]]; then
    echo "找不到 $CONFIG"; return 1
  fi
  echo "正在启动 sing-box..."
  nohup "$SB_BIN" run -c "$CONFIG" > "$LOGF" 2>&1 &
  sleep 1
  if pgrep -f "sb-amd64" >/dev/null; then
    echo "✓ 启动成功"
  else
    echo "✗ 启动失败，查看日志：$LOGF"
  fi
}

stop_sb() {
  echo "正在停止 sing-box..."
  pkill -f "sb-amd64" >/dev/null 2>&1 || true
  echo "✓ 已停止"
}

restart_sb() {
  stop_sb
  sleep 1
  start_sb
}

status_sb() {
  if pgrep -f "sb-amd64" >/dev/null; then
    echo "✓ sing-box 正在运行 (PID: $(pgrep -f "sb-amd64" | xargs))"
  else
    echo "✗ sing-box 未运行"
  fi
}

logs_sb() {
  if [[ -f "$LOGF" ]]; then
    echo "按 Ctrl+C 退出日志查看"
    tail -f "$LOGF"
  else
    echo "未找到日志文件：$LOGF"
  fi
}

update_rules() {
  if [[ -x ./update_rules.sh ]]; then
    ./update_rules.sh
  else
    echo "未找到 update_rules.sh"
  fi
}

subscription_menu() {
  if [[ -x ./subscription.sh ]]; then
    ./subscription.sh
  else
    echo "未找到 subscription.sh"
  fi
}

uninstall_all() {
  read -rp "确认卸载并删除当前目录内的相关文件? (y/N): " ans
  case "${ans:-N}" in
    y|Y)
      stop_sb || true
      rm -rf sb-amd64 config.json sb.log RULES_MODE rules reality.pub reality.priv server.addr subscriptions || true
      echo "✓ 卸载完成（仅清理当前目录内文件）"
      ;;
    *) echo "已取消";;
  esac
}

while true; do
  print_menu
  read -rp "请选择 [1-9]: " choice
  case "$choice" in
    1) start_sb; read -rp "回车返回菜单" _;;
    2) stop_sb; read -rp "回车返回菜单" _;;
    3) restart_sb; read -rp "回车返回菜单" _;;
    4) status_sb; read -rp "回车返回菜单" _;;
    5) logs_sb;;
    6) update_rules; read -rp "回车返回菜单" _;;
    7) subscription_menu; read -rp "回车返回菜单" _;;
    8) uninstall_all; read -rp "回车返回菜单" _;;
    9) exit 0;;
    *) echo "无效选择"; sleep 1;;
  esac
done
EOF
    chmod +x SB
    
    green "✓ 管理工具已创建"
}

# Main installation function
main() {
    case "${1:-}" in
        --restart)
            echo "正在重启sing-box..."
            pkill -f "sb-amd64"
            sleep 2
            nohup ./sb-amd64 run -c config.json > sb.log 2>&1 &
            sleep 3
            if pgrep -f "sb-amd64" > /dev/null; then
                green "✓ sing-box重启成功"
            else
                red "✗ sing-box重启失败"
            fi
            exit 0
            ;;
        --status)
            if pgrep -f "sb-amd64" > /dev/null; then
                green "✓ sing-box正在运行"
                echo "进程ID: $(pgrep -f "sb-amd64")"
            else
                red "✗ sing-box未运行"
            fi
            exit 0
            ;;
        --logs)
            if [[ -f sb.log ]]; then
                tail -f sb.log
            else
                red "日志文件不存在"
                exit 1
            fi
            exit 0
            ;;
        --stop)
            echo "正在停止sing-box..."
            pkill -f "sb-amd64"
            green "✓ sing-box已停止"
            exit 0
            ;;
    esac
    
    clear
    blue "================================================================"
    blue "        FreeBSD科学上网一键部署脚本 v$SCRIPT_VERSION"
    blue "================================================================"
    echo
    
    # Create working directory
    mkdir -p "$BASE_PATH"
    cd "$BASE_PATH"
    
    # Environment checks
    check_environment
    check_dependencies
    
    # Generate basic configuration
    generate_uuid
    get_available_ports
    get_server_ip
    
    # Interactive configuration
    interactive_config
    
    # Download and setup
    download_singbox
    generate_reality_keys
    generate_tls_cert
    
    # Generate and start service
    generate_config
    start_singbox
    
    # Create output
    generate_share_links
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
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi