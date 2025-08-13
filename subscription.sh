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

# Read short_id from config
SHORT_ID=$(jq -r '.inbounds[1].tls.reality.short_id[0]' config.json 2>/dev/null || echo "")

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
    cat > "subscriptions/${UUID}_v2sub.txt" <<EOF
$vless_link
$vmess_link
$hy2_link
EOF
    
    green "✓ V2rayN订阅文件已生成: subscriptions/${UUID}_v2sub.txt"
}

# Generate Clash Meta subscription
generate_clashmeta_subscription() {
    cat > "subscriptions/${UUID}_clashmeta.yaml" <<EOF
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
EOF
    
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

    cat > "subscriptions/${UUID}_singbox.json" <<EOF
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
EOF
    
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

# Main function
main() {
    blue "正在生成订阅文件..."
    
    generate_v2rayn_subscription
    generate_clashmeta_subscription  
    generate_singbox_subscription
    
    display_info
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
