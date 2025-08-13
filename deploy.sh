#!/bin/bash

# ==========================================
# FreeBSD 科学上网一键部署脚本
# 支持三协议：VLESS Reality、VMess WebSocket、Hysteria2
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
HY2_PORT=""
VLESS_PORT=""
VMESS_PORT=""
SERVER_IP=""
BASE_PATH="$HOME/sbx"
# 避免 set -u 下未绑定变量错误，为握手端口提供安全默认值
REALITY_HANDSHAKE_PORT=443

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
        yellow "请先安装缺少的工具（仅依赖）："
        yellow "pkg install curl jq openssl  # 不通过 pkg 安装 sing-box，本脚本将从自编译仓库下载"
        exit 1
    fi
    
    green "✓ 依赖检查通过"
}

# Smart port allocation with scanning and user interaction
smart_port_allocation() {
    blue "=== 端口分配模式 ==="
    echo "1) 自动扫描可用端口 (推荐，范围: 20000-40000)"
    echo "2) 手动指定端口"
    echo "3) 随机端口 (原始模式，范围: 10000-20000)"
    
    # 非交互模式使用默认自动扫描
    if [[ ! -t 0 ]]; then
        port_mode=1
        blue "非交互模式：使用自动扫描端口"
    else
        read -p "请选择端口分配模式 [1-3, 默认1]: " port_mode < /dev/tty
        port_mode=${port_mode:-1}
    fi
    
    case $port_mode in
        1)
            blue "正在扫描 20000-40000 范围内的可用端口..."
            HY2_PORT=$(scan_available_port 20000 40000)
            VLESS_PORT=$(scan_available_port $((HY2_PORT + 1)) 40000)
            VMESS_PORT=$(scan_available_port $((VLESS_PORT + 1)) 40000)
            
            if [[ -z "$HY2_PORT" || -z "$VLESS_PORT" || -z "$VMESS_PORT" ]]; then
                yellow "端口扫描失败，回退到随机模式"
                generate_random_ports
            else
                green "✓ 自动分配端口: HY2=$HY2_PORT, VLESS=$VLESS_PORT, VMESS=$VMESS_PORT"
            fi
            ;;
        2)
            blue "=== 手动指定端口模式 ==="
            echo "端口范围: 20000-40000 (TCP/UDP)"
            echo "当前占用端口:"
            sockstat -l | grep -E ":2[0-9]{4}|:3[0-9]{4}|:4[0-9]{4}" || echo "无相关端口占用"
            echo ""
            
            while true; do
                read -p "Hysteria2 端口 (UDP, 20000-40000): " HY2_PORT < /dev/tty
                read -p "VLESS 端口 (TCP, 20000-40000): " VLESS_PORT < /dev/tty
                read -p "VMess 端口 (TCP, 20000-40000): " VMESS_PORT < /dev/tty
                
                if validate_ports "$HY2_PORT" "$VLESS_PORT" "$VMESS_PORT"; then
                    break
                else
                    red "端口验证失败，请重新输入"
                fi
            done
            ;;
        3)
            blue "使用随机端口模式"
            generate_random_ports
            ;;
        *)
            yellow "无效选择，使用默认自动扫描模式"
            smart_port_allocation
            ;;
    esac
}

# Port scanning function for FreeBSD
scan_available_port() {
    local start_port=${1:-20000}
    local end_port=${2:-40000}
    
    for port in $(seq $start_port $end_port); do
        # Check if port is available using sockstat
        if ! sockstat -l | grep -q ":$port "; then
            echo $port
            return 0
        fi
    done
    return 1
}

# Validate user input ports  
validate_ports() {
    local hy2=$1 vless=$2 vmess=$3
    
    # Check if all ports are provided
    if [[ -z "$hy2" || -z "$vless" || -z "$vmess" ]]; then
        red "所有端口都必须填写"
        return 1
    fi
    
    # Check port range and format
    for port in $hy2 $vless $vmess; do
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 20000 ]] || [[ $port -gt 40000 ]]; then
            red "端口 $port 不在有效范围 20000-40000"
            return 1
        fi
    done
    
    # Check for duplicates
    if [[ "$hy2" == "$vless" ]] || [[ "$hy2" == "$vmess" ]] || [[ "$vless" == "$vmess" ]]; then
        red "端口不能重复"
        return 1
    fi
    
    # Check if ports are available
    for port in $hy2 $vless $vmess; do
        if sockstat -l | grep -q ":$port "; then
            red "端口 $port 已被占用："
            sockstat -l | grep ":$port "
            return 1
        fi
    done
    
    green "✓ 端口验证通过: HY2=$hy2, VLESS=$vless, VMESS=$vmess"
    return 0
}

# Fallback random port generation
generate_random_ports() {
    HY2_PORT=$((RANDOM % 10000 + 20000))
    VLESS_PORT=$((RANDOM % 10000 + 20000))
    VMESS_PORT=$((RANDOM % 10000 + 20000))
    yellow "随机端口: HY2=$HY2_PORT, VLESS=$VLESS_PORT, VMESS=$VMESS_PORT"
}

# Generate UUID and other configs
generate_configs() {
    UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    
    # Smart port allocation
    smart_port_allocation
    
    green "✓ 配置生成完成"
    blue "  UUID: $UUID"
    blue "  Hysteria2端口: $HY2_PORT"
    blue "  VLESS端口: $VLESS_PORT"  
    blue "  VMess端口: $VMESS_PORT"
 }

# Generate Reality keypair
generate_reality_keys() {
    # Determine binary name based on architecture
    local arch=$(uname -m)
    case "$arch" in
        amd64|x86_64) BINARY_NAME="sb-amd64" ;;
        arm64|aarch64) BINARY_NAME="sb-arm64" ;;
        *) BINARY_NAME="sb-amd64" ;;  # Default fallback
    esac
    
    local temp_output=$(./$BINARY_NAME generate reality-keypair)
    
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
    
    # Save public key for subscription use
    echo "$PUBLIC_KEY" > reality.pub
    
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
        # 为非交互模式生成必要的 Reality 配置
        SHORT_ID=$(openssl rand -hex 4 2>/dev/null || echo $(printf "%08x" $((RANDOM * RANDOM))))
        green "✓ 非交互模式：已使用默认配置"
        green "  伪装域名: $DOMAIN"
        green "  规则模式: ${rules_choice}"
        green "  端口配置: $HY2_PORT, $VLESS_PORT, $VMESS_PORT"
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
    
    # Test Reality handshake port
    blue "正在检测Reality握手端口..."
    REALITY_HANDSHAKE_PORT=443
    
    if command -v nc >/dev/null 2>&1; then
        # Use nc for port testing
        if nc -z "$DOMAIN" 443 >/dev/null 2>&1; then
            REALITY_HANDSHAKE_PORT=443
            green "✓ 443端口连通正常"
        elif nc -z "$DOMAIN" 80 >/dev/null 2>&1; then
            REALITY_HANDSHAKE_PORT=80
            yellow "⚠ 443端口不通，回退到80端口"
        else
            REALITY_HANDSHAKE_PORT=443
            yellow "⚠ 端口检测失败，默认使用443端口"
        fi
    else
        # Fallback: use curl for basic connectivity test
        if curl -s --max-time 5 "https://$DOMAIN" >/dev/null 2>&1; then
            REALITY_HANDSHAKE_PORT=443
            green "✓ HTTPS连通正常，使用443端口"
        elif curl -s --max-time 5 "http://$DOMAIN" >/dev/null 2>&1; then
            REALITY_HANDSHAKE_PORT=80
            yellow "⚠ HTTPS不通但HTTP可用，使用80端口"
        else
            REALITY_HANDSHAKE_PORT=443
            yellow "⚠ 连通性测试失败，默认使用443端口"
        fi
    fi
    
    # Generate random short_id (8-character hex string)
    SHORT_ID=$(openssl rand -hex 4 2>/dev/null || echo $(printf "%08x" $((RANDOM * RANDOM))))
    
    green "✓ Reality配置完成"
    green "  伪装域名: $DOMAIN"
    green "  握手端口: $REALITY_HANDSHAKE_PORT"
    green "  Short ID: $SHORT_ID"
    
    # Rules config
    echo
    yellow "规则配置："
    blue "1. 在线规则集（推荐）"
    blue "2. 本地规则文件"
    blue "3. 混合（本地优先，在线回退）"
    read -p "请选择 [1-3, 默认1]: " rules_choice < /dev/tty
    
    # Port config
    echo
    yellow "端口配置："
    blue "Hysteria2端口: $HY2_PORT (UDP)"
    blue "VLESS端口: $VLESS_PORT (TCP)"
    blue "VMess端口: $VMESS_PORT (TCP)"
    read -p "是否修改端口? [y/N]: " change_port < /dev/tty
    
    if [[ "$change_port" =~ ^[yY] ]]; then
        read -p "Hysteria2端口 [$HY2_PORT] (UDP): " new_hy2 < /dev/tty
        read -p "VLESS端口 [$VLESS_PORT] (TCP): " new_vless < /dev/tty
        read -p "VMess端口 [$VMESS_PORT] (TCP): " new_vmess < /dev/tty
        
        HY2_PORT=${new_hy2:-$HY2_PORT}
        VLESS_PORT=${new_vless:-$VLESS_PORT}
        VMESS_PORT=${new_vmess:-$VMESS_PORT}
    fi
    
    green "✓ 交互配置完成"
    green "  伪装域名: $DOMAIN"
    green "  规则模式: ${rules_choice:-1}"
    green "  端口配置: $HY2_PORT, $VLESS_PORT, $VMESS_PORT"
}

# Download sing-box from custom build (GitHub repository)
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
    
    blue "正在下载 sing-box (包含Reality支持的自编译版本)..."
    
    # Download from provided custom build URL (with Reality support)
    blue "从 GitHub 仓库下载自编译的 sing-box..."
    
    # Use architecture-specific URLs for better support
    local custom_url
    case "$arch" in
        amd64)
            custom_url="https://github.com/dayao888/ferrbsd-sbx/releases/download/v1.10/sb-amd64"
            ;;
        arm64)
            custom_url="https://github.com/dayao888/ferrbsd-sbx/releases/download/v1.10/sb-arm64"
            ;;
        *)
            custom_url="https://github.com/dayao888/ferrbsd-sbx/releases/download/v1.10/sb-amd64"
            ;;
    esac
    
    local download_success=false
    
    # Try downloading the custom compiled binary with Reality support
    if command -v curl &> /dev/null; then
        if curl -fsSL -o "$filename" "$custom_url" 2>/dev/null; then
            chmod +x "$filename"
            download_success=true
            green "✓ 自定义编译的 sing-box 二进制文件下载完成 (包含Reality支持)"
        fi
    elif command -v fetch &> /dev/null; then
        if fetch -o "$filename" "$custom_url" 2>/dev/null; then
            chmod +x "$filename"
            download_success=true
            green "✓ 自定义编译的 sing-box 二进制文件下载完成 (包含Reality支持)"
        fi
    fi
    
    # Verify Reality support: try running 'generate reality-keypair'
    if [[ -x "$filename" ]]; then
        if ! ./$filename generate reality-keypair >/dev/null 2>&1; then
            red "自编译二进制缺少 Reality 支持或文件损坏，请重新下载或联系我们维护发布包。"
            yellow "可选方案："
            yellow "1. 手动下载你仓库发布的 sb-amd64/sb-arm64 并确认已包含 Reality"
            yellow "2. 自行编译: 'go build -tags with_reality_server'"
            exit 1
        fi
    fi

    if [[ "$download_success" != true ]]; then
        red "所有下载方法都失败了"
        yellow "请尝试手动安装："
        yellow "1. 访问: https://github.com/SagerNet/sing-box/releases"
        yellow "2. 或手动下载: $custom_url"
        exit 1
    fi
    
    green "✓ sing-box 二进制文件安装完成"
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
    blue "正在生成配置文件..."
    
    # 写入规则模式设置
    echo "${rules_choice:-1}" > RULES_MODE
    
    local rules_config
    
    if [[ "${rules_choice:-1}" == "1" ]]; then
        # Online rules - 使用远程 .srs 规则
        rules_config='{
            "rules": [
                {
                    "rule_set": [
                        "geosite-category-ads-all"
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
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs",
          "download_detour": "direct"
        },
        {
          "tag": "geosite-private",
          "type": "remote",
          "format": "binary",
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/private.srs",
          "download_detour": "direct"
        },
        {
          "tag": "geoip-private",
          "type": "remote",
          "format": "binary",
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/private.srs",
          "download_detour": "direct"
        },
        {
          "tag": "geosite-geolocation-!cn",
          "type": "remote",
          "format": "binary",
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs",
          "download_detour": "direct"
        },
        {
          "tag": "geoip-telegram",
          "type": "remote",
          "format": "binary",
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs",
          "download_detour": "direct"
        },
        {
          "tag": "geosite-cn",
          "type": "remote",
          "format": "binary",
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
          "download_detour": "direct"
        },
        {
          "tag": "geoip-cn",
          "type": "remote",
          "format": "binary",
          "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
          "download_detour": "direct"
        }
      ]
        }'
    elif [[ "${rules_choice:-1}" == "2" ]]; then
        # Local rules - 使用本地 .srs 文件
        rules_config='{
            "rules": [
                {
                    "rule_set": [
                        "geosite-category-ads-all"
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
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geosite-category-ads-all.srs"
                },
                {
                    "tag": "geosite-private",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geosite-private.srs"
                },
                {
                    "tag": "geoip-private",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geoip-private.srs"
                },
                {
                    "tag": "geosite-geolocation-!cn",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geosite-geolocation-!cn.srs"
                },
                {
                    "tag": "geoip-telegram",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geoip-telegram.srs"
                },
                {
                    "tag": "geosite-cn",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geosite-cn.srs"
                },
                {
                    "tag": "geoip-cn",
                    "type": "local",
                    "format": "binary",
                    "path": "rules/geoip-cn.srs"
                }
            ]
        }'
    else
        # Mixed mode - 如果本地文件存在则使用本地，否则使用远程
        if [[ -f "rules/geosite-cn.srs" && -f "rules/geoip-cn.srs" ]]; then
            # 使用本地 .srs 文件
            rules_config='{
                "rules": [
                    {
                        "rule_set": [
                            "geosite-category-ads-all"
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
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geosite-category-ads-all.srs"
                    },
                    {
                        "tag": "geosite-private",
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geosite-private.srs"
                    },
                    {
                        "tag": "geoip-private",
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geoip-private.srs"
                    },
                    {
                        "tag": "geosite-geolocation-!cn",
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geosite-geolocation-!cn.srs"
                    },
                    {
                        "tag": "geoip-telegram",
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geoip-telegram.srs"
                    },
                    {
                        "tag": "geosite-cn",
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geosite-cn.srs"
                    },
                    {
                        "tag": "geoip-cn",
                        "type": "local",
                        "format": "binary",
                        "path": "rules/geoip-cn.srs"
                    }
                ]
            }'
        else
            # 回退到远程规则
            rules_config='{
                "rules": [
                    {
                        "rule_set": [
                            "geosite-category-ads-all"
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
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs",
                        "download_detour": "direct"
                    },
                    {
                        "tag": "geosite-private",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/private.srs",
                        "download_detour": "direct"
                    },
                    {
                        "tag": "geoip-private",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/private.srs",
                        "download_detour": "direct"
                    },
                    {
                        "tag": "geosite-geolocation-!cn",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs",
                        "download_detour": "direct"
                    },
                    {
                        "tag": "geoip-telegram",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs",
                        "download_detour": "direct"
                    },
                    {
                        "tag": "geosite-cn",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
                        "download_detour": "direct"
                    },
                    {
                        "tag": "geoip-cn",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
                        "download_detour": "direct"
                    }
                ]
            }'
        fi
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
            "type": "hysteria2",
            "tag": "hy2-in",
            "listen": "0.0.0.0",
            "listen_port": $HY2_PORT,
            "users": [
                {
                    "password": "$UUID"
                }
            ],
            "up_mbps": 1000,
            "down_mbps": 1000,
            "ignore_client_bandwidth": true,
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "certificate_path": "cert.pem",
                "key_path": "private.key",
                "alpn": ["h3"]
            }
        },
        {
            "type": "vless",
            "tag": "vless-in",
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
                "server_name": "$DOMAIN",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$DOMAIN",
                        "server_port": $REALITY_HANDSHAKE_PORT
                    },
                    "private_key": "$PRIVATE_KEY",
                    "short_id": ["$SHORT_ID"],
                    "server_names": ["$DOMAIN"]
                }
            }
        },
        {
            "type": "vmess",
            "tag": "vmess-in",
            "listen": "0.0.0.0",
            "listen_port": $VMESS_PORT,
            "users": [
                {
                    "uuid": "$UUID",
                    "alterId": 0
                }
            ],
            "transport": {
                "type": "ws",
                "path": "/$UUID-vm"
            }
        }
    ],
    "outbounds": [
        {
            "type": "selector",
            "tag": "proxy",
            "outbounds": [
                "direct"
            ],
            "default": "direct"
        },
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
    
    # Check if running as non-root user
    if [[ $(id -u) -ne 0 ]]; then
        # Try to check if sudo is available
        if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
            # Sudo available without password
            local can_sudo=true
        else
            yellow "当前为非root用户，跳过防火墙配置"
            yellow "如需配置防火墙，请以管理员身份手动执行以下命令："
            echo "# 添加防火墙规则到 /etc/pf.conf"
            echo "pass in quick on any proto tcp from any to any port $VLESS_PORT"
            echo "pass in quick on any proto tcp from any to any port $VMESS_PORT"
            echo "pass in quick on any proto udp from any to any port $HY2_PORT"
            echo "pass out quick on any proto tcp from any to any"
            echo "pass out quick on any proto udp from any to any"
            echo "# 然后重新载入规则: pfctl -f /etc/pf.conf"
            return
        fi
    else
        local can_sudo=true
    fi
    
    # Proceed with firewall configuration if possible
    if [[ "$can_sudo" == true ]]; then
        # Check if pf is enabled
        if ! sudo pfctl -s info &>/dev/null; then
            yellow "警告：PF防火墙未启用，跳过防火墙配置"
            return
        fi
        
        # Add rules to pf.conf if not already present
        local pf_rules="
# Sing-box rules
pass in quick on any proto tcp from any to any port $VLESS_PORT
pass in quick on any proto tcp from any to any port $VMESS_PORT
pass in quick on any proto udp from any to any port $HY2_PORT
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
    fi
}

# Start sing-box
start_singbox() {
    blue "正在启动 sing-box..."
    
    # Determine binary name based on architecture
    local arch=$(uname -m)
    case "$arch" in
        amd64|x86_64) BINARY_NAME="sb-amd64" ;;
        arm64|aarch64) BINARY_NAME="sb-arm64" ;;
        *) BINARY_NAME="sb-amd64" ;;  # Default fallback
    esac
    
    # Pre-check: validate configuration syntax
    blue "检查配置文件语法..."
    if ! ./$BINARY_NAME check -c config.json >/dev/null 2>&1; then
        red "配置文件语法错误:"
        ./$BINARY_NAME check -c config.json
        exit 1
    fi
    green "✓ 配置文件语法正确"
    
    # Pre-check: test port availability
    blue "检查端口可用性..."
    local ports=($(jq -r '.inbounds[].listen_port' config.json))
    for port in "${ports[@]}"; do
        if sockstat -l | grep -q ":$port "; then
            yellow "警告: 端口 $port 已被占用"
            sockstat -l | grep ":$port "
        fi
    done
    
    # Kill existing process
    pkill -f "$BINARY_NAME" 2>/dev/null || true
    sleep 1
    
    # Start in background
    blue "启动 sing-box 服务..."
    nohup ./$BINARY_NAME run -c config.json > singbox.log 2>&1 &
    local start_pid=$!
    
    sleep 3
    
    # Check if started successfully
    if pgrep -f "$BINARY_NAME" > /dev/null; then
        green "✓ sing-box 启动成功"
        blue "监听端口:"
        sockstat -l | grep -E "($(jq -r '.inbounds[].listen_port' config.json | tr '\n' '|' | sed 's/|$//'))" 2>/dev/null || echo "无法获取端口信息"
    else
        red "sing-box 启动失败，请检查日志:"
        echo "=== 错误日志 ==="
        tail -20 singbox.log
        echo ""
        echo "=== 诊断信息 ==="
        echo "用户ID: $(id)"
        echo "端口权限检查:"
        for port in "${ports[@]}"; do
            if [[ $port -lt 1024 ]]; then
                red "  端口 $port < 1024，需要 root 权限"
            else
                green "  端口 $port >= 1024，普通用户可用"
            fi
        done
        exit 1
    fi
}

# Generate subscription info
generate_subscription() {
    local vless_link vmess_link hy2_link

    echo "$SERVER_IP" > server.addr
    
    # VLESS Reality
    vless_link="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#VLESS-Reality-$SERVER_IP"
    
    # VMess WebSocket
    local vmess_config="{\"v\":\"2\",\"ps\":\"VMess-WS-$SERVER_IP\",\"add\":\"$SERVER_IP\",\"port\":\"$VMESS_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/$UUID-vm\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\"}"
    vmess_link="vmess://$(printf %s "$vmess_config" | base64 | tr -d '\n')"
    
    # Hysteria2
    hy2_link="hysteria2://$UUID@$SERVER_IP:$HY2_PORT?insecure=1&sni=www.bing.com&alpn=h3#Hysteria2-$SERVER_IP"
    
    # Save to file
    cat > links.txt << EOF
$vless_link
$vmess_link
$hy2_link
EOF
    
    # Generate base64 subscription
    base64 links.txt > subscription.txt
    
    green "✓ 订阅信息已生成"
    green "  链接文件: $BASE_PATH/links.txt"
    green "  订阅文件: $BASE_PATH/subscription.txt"
    
    echo
    blue "=== 分享链接 ==="
    echo "VLESS Reality: $vless_link"
    echo "VMess WS: $vmess_link"
    echo "Hysteria2: $hy2_link"
}

# Create management tools
create_management_tools() {
    # Status check script
    cat > check_status.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "=== Sing-box 状态 ==="

# Determine binary name
arch=$(uname -m)
case "$arch" in
    amd64|x86_64) BINARY_NAME="sb-amd64" ;;
    arm64|aarch64) BINARY_NAME="sb-arm64" ;;
    *) BINARY_NAME="sb-amd64" ;;
esac

if pgrep -f "$BINARY_NAME" > /dev/null; then
    echo "状态: 运行中"
    echo "进程ID: $(pgrep -f '$BINARY_NAME')"
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

# Determine binary name
arch=$(uname -m)
case "$arch" in
    amd64|x86_64) BINARY_NAME="sb-amd64" ;;
    arm64|aarch64) BINARY_NAME="sb-arm64" ;;
    *) BINARY_NAME="sb-amd64" ;;
esac

pkill -f "$BINARY_NAME" 2>/dev/null || true
sleep 2

nohup ./$BINARY_NAME run -c config.json > singbox.log 2>&1 &
sleep 3

if pgrep -f "$BINARY_NAME" > /dev/null; then
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

# Determine binary name
arch=$(uname -m)
case "$arch" in
    amd64|x86_64) BINARY_NAME="sb-amd64" ;;
    arm64|aarch64) BINARY_NAME="sb-arm64" ;;
    *) BINARY_NAME="sb-amd64" ;;
esac

if pgrep -f "$BINARY_NAME" > /dev/null; then
    pkill -f "$BINARY_NAME"
    sleep 2
    if ! pgrep -f "$BINARY_NAME" > /dev/null; then
        echo "✓ sing-box 已停止"
    else
        echo "强制停止..."
        pkill -9 -f "$BINARY_NAME"
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

# Download latest geoip and geosite files
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

# Download .srs format rule files from MetaCubeX repository
download_success=0
if download_file "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-cn.srs" "rules/geoip-cn.srs" && \
   download_file "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite-cn.srs" "rules/geosite-cn.srs" && \
   download_file "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite-geolocation-!cn.srs" "rules/geosite-geolocation-!cn.srs" && \
   download_file "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs" "rules/geosite-category-ads-all.srs" && \
    download_file "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/private.srs" "rules/geosite-private.srs" && \
    download_file "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/private.srs" "rules/geoip-private.srs" && \
    download_file "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs" "rules/geoip-telegram.srs"; then
    download_success=1
fi

if [ $download_success -eq 1 ]; then
    echo "✓ 规则文件更新完成"
    
    # Determine binary name for restart check
            arch=$(uname -m)
            case "$arch" in
                amd64|x86_64) BINARY_NAME="sb-amd64" ;;
                arm64|aarch64) BINARY_NAME="sb-arm64" ;;
                *) BINARY_NAME="sb-amd64" ;;
            esac
            
            # Restart if running
            if pgrep -f "$BINARY_NAME" > /dev/null; then
                echo "正在重启 sing-box 以应用新规则..."
                ./restart.sh
            fi
else
    echo "✗ 规则文件更新失败"
fi
EOF

    # Subscription generator script
    cat > subscription.sh << 'EOF'
#!/usr/bin/env bash

# =============================================================================
# FreeBSD科学上网订阅生成工具
# 
# 功能：生成V2rayN、Clash Meta、Sing-box格式订阅文件
# =============================================================================

# Color functions
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }

# Check if config.json exists
if [[ ! -f "config.json" ]]; then
    red "错误：找不到config.json配置文件"
    exit 1
fi

# 读取规则模式
if [[ -f "RULES_MODE" ]]; then
  RULES_MODE=$(cat RULES_MODE | tr -d '\n')
else
  RULES_MODE=3
fi

# 如果是混合模式且本地规则缺失，给出提示
if [[ "$RULES_MODE" == "3" ]]; then
  if [[ ! -f rules/geoip-cn.srs || ! -f rules/geosite-cn.srs || ! -f rules/geosite-geolocation-!cn.srs ]]; then
    yellow "提示：当前为混合模式，但本地规则文件不完整，将在订阅中使用本地路径。"
    yellow "请先执行 ./update_rules.sh 下载本地规则文件，以获得最佳兼容性。"
  fi
fi

# Read configuration from config.json
UUID=$(jq -r '.inbounds[1].users[0].uuid' config.json)
VLESS_PORT=$(jq -r '.inbounds[1].listen_port' config.json)
VMESS_PORT=$(jq -r '.inbounds[2].listen_port' config.json)
HY2_PORT=$(jq -r '.inbounds[0].listen_port' config.json)
DOMAIN=$(jq -r '.inbounds[1].tls.server_name' config.json)
PRIVATE_KEY=$(jq -r '.inbounds[1].tls.reality.private_key' config.json)

# Get public key from saved file if exists
if [[ -f reality.pub ]]; then
  PUBLIC_KEY=$(cat reality.pub)
else
  # Fallback: try deriving from sb (may not support); leave empty if fail
  PUBLIC_KEY=""
fi

# Get server IP
if [[ -f server.addr ]]; then
    SERVER_IP=$(cat server.addr)
fi

if [[ -z "$SERVER_IP" || "$SERVER_IP" == "null" ]]; then
    # try to read from config listen (not ideal for WAN), skip if empty
    SERVER_IP=$(jq -r '.inbounds[0].listen' config.json 2>/dev/null)
    [[ "$SERVER_IP" == "null" ]] && SERVER_IP=""
fi

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -s4 -m 10 https://api64.ipify.org)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s4 -m 10 https://ifconfig.me)
    fi
fi

if [[ -z "$SERVER_IP" ]]; then
    red "错误：无法获取服务器地址"
    read -p "请输入服务器地址（IP或域名）: " SERVER_IP
    if [[ -z "$SERVER_IP" ]]; then
        red "必须输入服务器地址"
        exit 1
    fi
fi

# Create subscriptions directory
mkdir -p subscriptions

# Generate V2rayN subscription
generate_v2rayn_subscription() {
    # VLESS Reality link
    local vless_link="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#VLESS-Reality-$SERVER_IP"
    
    # VMess WebSocket link
    local vmess_config="{\"v\":\"2\",\"ps\":\"VMess-WS-$SERVER_IP\",\"add\":\"$SERVER_IP\",\"port\":\"$VMESS_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/$UUID-vm\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\"}"
    local vmess_link="vmess://$(printf %s "$vmess_config" | base64 | tr -d '\n')"
    
    # Hysteria2 link  
    local hy2_link="hysteria2://$UUID@$SERVER_IP:$HY2_PORT?insecure=1&sni=www.bing.com&alpn=h3#Hysteria2-$SERVER_IP"
    
    # Create subscription file
    cat > "subscriptions/${UUID}_v2sub.txt" <<EOL2
$vless_link
$vmess_link
$hy2_link
EOL2
    
    green "✓ V2rayN订阅文件已生成: subscriptions/${UUID}_v2sub.txt"
}

# Generate Clash Meta subscription
generate_clashmeta_subscription() {
    cat > "subscriptions/${UUID}_clashmeta.yaml" <<EOL3
port: 7890
socks-port: 7891
redir-port: 7892
allow-lan: false
mode: Rule
log-level: info
external-controller: 127.0.0.1:9090

proxies:
  - name: "vless-reality-$SERVER_IP"
    type: vless
    server: $SERVER_IP
    port: $VLESS_PORT
    uuid: $UUID
    network: tcp
    flow: xtls-rprx-vision
    tls: true
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: ""
    servername: $DOMAIN

  - name: "vmess-ws-$SERVER_IP"  
    type: vmess
    server: $SERVER_IP
    port: $VMESS_PORT
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: ws
    ws-opts:
      path: /$UUID-vm

  - name: "hysteria2-$SERVER_IP"
    type: hysteria2
    server: $SERVER_IP
    port: $HY2_PORT
    password: $UUID
    sni: www.bing.com
    skip-cert-verify: true

proxy-groups:
  - name: "Select"
    type: select
    proxies:
      - "vless-reality-$SERVER_IP"
      - "vmess-ws-$SERVER_IP"
      - "hysteria2-$SERVER_IP"

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,Select
EOL3
    
    green "✓ Clash Meta订阅文件已生成: subscriptions/${UUID}_clashmeta.yaml"
}

# Generate Sing-box subscription
generate_singbox_subscription() {
    # 根据RULES_MODE生成rule_set配置
    local rule_set_json=""
    if [[ "$RULES_MODE" == "1" ]]; then
        # 在线模式
        rule_set_json='[
            {
                "tag": "geosite-category-ads-all",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs",
                "download_detour": "direct"
            },
            {
                "tag": "geosite-geolocation-!cn",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs",
                "download_detour": "direct"
            },
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
    else
        # 本地模式和混合模式都使用本地路径
        rule_set_json='[
            {
                "tag": "geosite-category-ads-all",
                "type": "local",
                "format": "binary",
                "path": "rules/geosite-category-ads-all.srs"
            },
            {
                "tag": "geosite-geolocation-!cn",
                "type": "local",
                "format": "binary",
                "path": "rules/geosite-geolocation-!cn.srs"
            },
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
    fi

    cat > "subscriptions/${UUID}_singbox.json" <<EOL4
{
    "log": {
        "level": "info"
    },
    "dns": {
        "servers": [
            {
                "tag": "remote",
                "type": "https",
                "server": "cloudflare-dns.com",
                "server_port": 443,
                "detour": "select"
            },
            {
                "tag": "local",
                "type": "https",
                "server": "dns.alidns.com",
                "server_port": 443,
                "detour": "direct"
            },
            {
                "tag": "fakeip",
                "type": "fakeip"
            },
            {
                "tag": "block",
                "type": "rcode",
                "rcode": 3
            }
        ],
        "rules": [
            {
                "rule_set": ["geosite-category-ads-all"],
                "server": "block"
            },
            {
                "rule_set": ["geosite-cn"],
                "server": "local"
            },
            {
                "rule_set": ["geosite-geolocation-!cn"],
                "server": "remote"
            },
            {
                "rule_set": ["geosite-geolocation-!cn"],
                "disable_cache": true,
                "server": "remote"
            }
        ],
        "fakeip": {
            "enabled": true,
            "inet4_range": "198.18.0.0/15",
            "inet6_range": "fc00::/18"
        },
        "independent_cache": true,
        "final": "remote"
    },
    "inbounds": [
        {
            "type": "mixed",
            "listen": "127.0.0.1",
            "listen_port": 2080,
            "sniff": true
        }
    ],
    "outbounds": [
        {
            "tag": "vless-reality",
            "type": "vless",
            "server": "$SERVER_IP",
            "server_port": $VLESS_PORT,
            "uuid": "$UUID",
            "flow": "xtls-rprx-vision",
            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "reality": {
                    "enabled": true,
                    "public_key": "$PUBLIC_KEY",
                    "short_id": "$SHORT_ID"
                }
            }
        },
        {
            "tag": "vmess-ws",
            "type": "vmess",
            "server": "$SERVER_IP",
            "server_port": $VMESS_PORT,
            "uuid": "$UUID",
            "transport": {
                "type": "ws",
                "path": "/$UUID-vm"
            }
        },
        {
            "tag": "hysteria2",
            "type": "hysteria2",
            "server": "$SERVER_IP",
            "server_port": $HY2_PORT,
            "password": "$UUID",
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "insecure": true
            }
        },
        {
            "tag": "select",
            "type": "selector",
            "outbounds": [
                "vless-reality",
                "vmess-ws", 
                "hysteria2"
            ]
        },
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
        "final": "select"
    }
}
EOL4
    
    green "✓ Sing-box订阅文件已生成: subscriptions/${UUID}_singbox.json"
}

# Display subscription information
display_info() {
    blue "======================== 订阅信息 ========================"
    echo
    green "服务器信息:"
    echo "  IP地址: $SERVER_IP"
    echo "  UUID: $UUID"
    echo "  VLESS端口: $VLESS_PORT"
    echo "  VMess端口: $VMESS_PORT"
    echo "  Hysteria2端口: $HY2_PORT"
    echo "  Reality域名: $DOMAIN"
    echo
    green "订阅文件:"
    echo "  V2rayN: subscriptions/${UUID}_v2sub.txt"
    echo "  Clash Meta: subscriptions/${UUID}_clashmeta.yaml"
    echo "  Sing-box: subscriptions/${UUID}_singbox.json"
    echo
    yellow "分享链接（单独使用）:"
    
    # VLESS link
    local vless_link="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#VLESS-Reality-$SERVER_IP"
    echo
    echo "VLESS Reality:"
    echo "$vless_link"
    
    # VMess link
    local vmess_config="{\"v\":\"2\",\"ps\":\"VMess-WS-$SERVER_IP\",\"add\":\"$SERVER_IP\",\"port\":\"$VMESS_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/$UUID-vm\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\"}"
    local vmess_link="vmess://$(printf %s "$vmess_config" | base64 | tr -d '\n')"
    echo
    echo "VMess WebSocket:"
    echo "$vmess_link"
    
    # Hysteria2 link
    local hy2_link="hysteria2://$UUID@$SERVER_IP:$HY2_PORT?insecure=1&sni=www.bing.com&alpn=h3#Hysteria2-$SERVER_IP"
    echo
    echo "Hysteria2:"
    echo "$hy2_link"
    
    blue "======================================================"
}

# Generate links for backward compatibility
generate_legacy_links() {
    # VLESS link
    local vless_link="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#VLESS-Reality-$SERVER_IP"
    
    # VMess link
    local vmess_config="{\"v\":\"2\",\"ps\":\"VMess-WS-$SERVER_IP\",\"add\":\"$SERVER_IP\",\"port\":\"$VMESS_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/$UUID-vm\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\"}"
    local vmess_link="vmess://$(printf %s "$vmess_config" | base64 | tr -d '\n')"
    
    # Hysteria2 link
    local hy2_link="hysteria2://$UUID@$SERVER_IP:$HY2_PORT?insecure=1&sni=www.bing.com&alpn=h3#Hysteria2-$SERVER_IP"
    
    # Save links
    cat > links.txt <<EOL5
$vless_link
$vmess_link
$hy2_link
EOL5
    
    # Generate subscription
    base64 links.txt > subscription.txt
}

# Main function
main() {
    blue "正在生成订阅文件..."
    
    generate_v2rayn_subscription
    generate_clashmeta_subscription  
    generate_singbox_subscription
    generate_legacy_links
    
    display_info
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
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
            # Determine binary name
            arch=$(uname -m)
            case "$arch" in
                amd64|x86_64) BINARY_NAME="sb-amd64" ;;
                arm64|aarch64) BINARY_NAME="sb-arm64" ;;
                *) BINARY_NAME="sb-amd64" ;;
            esac
            
            if pgrep -f "$BINARY_NAME" > /dev/null; then
                echo "sing-box 已在运行"
            else
                nohup ./$BINARY_NAME run -c config.json > singbox.log 2>&1 &
                sleep 2
                if pgrep -f "$BINARY_NAME" > /dev/null; then
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
    yellow "管理命令：（请先进入工作目录：cd $BASE_PATH）"
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
