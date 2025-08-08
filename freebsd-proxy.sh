#!/bin/bash

# FreeBSD科学上网一键脚本
# 适用于FreeBSD 14.3-RELEASE amd64系统
# 无需root权限

export LANG=en_US.UTF-8

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
plain='\033[0m'

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 系统检测
check_system() {
    if [[ ! -f /etc/freebsd-update.conf ]]; then
        red "错误：此脚本仅支持FreeBSD系统"
        exit 1
    fi
    
    local version=$(freebsd-version | cut -d'-' -f1)
    if [[ ! "$version" =~ ^14\. ]]; then
        yellow "警告：建议使用FreeBSD 14.x版本，当前版本：$version"
    fi
    
    green "系统检测通过：FreeBSD $version"
}

# 检测架构
check_arch() {
    case $(uname -m) in
        amd64) cpu="amd64";;
        arm64) cpu="arm64";;
        *) red "不支持的架构：$(uname -m)" && exit 1;;
    esac
    green "架构检测：$cpu"
}

# 全局变量
WORKDIR="$HOME/.freebsd-proxy"
CONFIG_FILE="$WORKDIR/config.json"
PID_FILE="$WORKDIR/sing-box.pid"
LOG_FILE="$WORKDIR/sing-box.log"
SING_BOX_BIN="$WORKDIR/sing-box"

# 端口配置
VLESS_PORT=28332
VMESS_PORT=38533
HY2_PORT=38786

# 生成UUID
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # FreeBSD fallback
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:upper:]' '[:lower:]'
    fi
}

# 获取本机IP
get_ip() {
    local ip4=$(curl -s4m8 ifconfig.me 2>/dev/null || curl -s4m8 ip.sb 2>/dev/null)
    local ip6=$(curl -s6m8 ifconfig.me 2>/dev/null || curl -s6m8 ip.sb 2>/dev/null)
    
    if [[ -n "$ip4" ]]; then
        echo "$ip4"
    elif [[ -n "$ip6" ]]; then
        echo "$ip6"
    else
        echo "127.0.0.1"
    fi
}

# 安装sing-box
install_singbox() {
    green "开始安装sing-box..."
    
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    # 检查是否已安装
    if [[ -f "$SING_BOX_BIN" ]]; then
        yellow "sing-box已存在，跳过下载"
        return 0
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
    local download_url="http://pkg.freebsd.org/FreeBSD:14:amd64/latest/All/sing-box-1.11.9.pkg"
    
    green "正在下载sing-box..."
    if curl -L -o sing-box.pkg "$download_url"; then
        # 解压pkg文件
        tar -xf sing-box.pkg
        if [[ -f usr/local/bin/sing-box ]]; then
            cp usr/local/bin/sing-box "$SING_BOX_BIN"
            chmod +x "$SING_BOX_BIN"
            rm -rf usr sing-box.pkg
            green "sing-box下载安装成功"
        else
            red "sing-box解压失败"
            return 1
        fi
    else
        red "sing-box下载失败"
        return 1
    fi
}

# 生成配置文件
generate_config() {
    local uuid="$1"
    local server_ip="$2"
    
    # 生成reality密钥对
    local reality_keys=$("$SING_BOX_BIN" generate reality-keypair 2>/dev/null)
    local private_key=$(echo "$reality_keys" | grep "PrivateKey:" | awk '{print $2}')
    local public_key=$(echo "$reality_keys" | grep "PublicKey:" | awk '{print $2}')
    
    # 保存公钥供客户端使用
    echo "$public_key" > "$WORKDIR/reality_public_key.txt"
    
    # 生成自签名证书
    openssl ecparam -genkey -name prime256v1 -out "$WORKDIR/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" -subj "/CN=example.com" 2>/dev/null
    
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
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [""]
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
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/$uuid-vm",
        "early_data_header_name": "Sec-WebSocket-Protocol"
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
      "masquerade": "https://www.bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$WORKDIR/cert.pem",
        "key_path": "$WORKDIR/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    
    green "配置文件生成完成"
}

# 启动服务
start_service() {
    if [[ -f "$PID_FILE" ]] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        yellow "服务已在运行中"
        return 0
    fi
    
    green "启动sing-box服务..."
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    echo $! > "$PID_FILE"
    
    sleep 2
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        green "服务启动成功"
        return 0
    else
        red "服务启动失败"
        return 1
    fi
}

# 停止服务
stop_service() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
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
    sleep 1
    start_service
}

# 查看状态
show_status() {
    if [[ -f "$PID_FILE" ]] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        green "服务状态：运行中"
        green "PID：$(cat "$PID_FILE")"
    else
        red "服务状态：未运行"
    fi
}

# 生成节点信息
generate_links() {
    if [[ ! -f "$WORKDIR/uuid.txt" ]]; then
        red "配置文件不存在，请先安装"
        return 1
    fi
    
    local uuid=$(cat "$WORKDIR/uuid.txt")
    local server_ip=$(cat "$WORKDIR/server_ip.txt")
    local public_key=$(cat "$WORKDIR/reality_public_key.txt")
    
    echo
    blue "=== 节点信息 ==="
    echo
    
    # VLESS Reality
    local vless_link="vless://$uuid@$server_ip:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$public_key&type=tcp&headerType=none#FreeBSD-VLESS-Reality"
    green "VLESS Reality:"
    echo "$vless_link"
    echo
    
    # VMess WS
    local vmess_config='{"v":"2","ps":"FreeBSD-VMess-WS","add":"'$server_ip'","port":"'$VMESS_PORT'","id":"'$uuid'","aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/'$uuid'-vm","tls":"","sni":"","alpn":""}'
    local vmess_link="vmess://$(echo -n "$vmess_config" | base64 -w 0)"
    green "VMess WS:"
    echo "$vmess_link"
    echo
    
    # Hysteria2
    local hy2_link="hysteria2://$uuid@$server_ip:$HY2_PORT?insecure=1&sni=www.bing.com#FreeBSD-Hysteria2"
    green "Hysteria2:"
    echo "$hy2_link"
    echo
    
    # 保存到文件
    cat > "$WORKDIR/links.txt" << EOF
VLESS Reality:
$vless_link

VMess WS:
$vmess_link

Hysteria2:
$hy2_link
EOF
    
    green "节点信息已保存到：$WORKDIR/links.txt"
}

# 查看日志
show_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 50 "$LOG_FILE"
    else
        yellow "日志文件不存在"
    fi
}

# 卸载
uninstall() {
    readp "确定要卸载吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        yellow "取消卸载"
        return
    fi
    
    stop_service
    rm -rf "$WORKDIR"
    green "卸载完成"
}

# 安装主函数
install_main() {
    green "开始安装FreeBSD科学上网脚本..."
    
    check_system
    check_arch
    
    if ! install_singbox; then
        red "sing-box安装失败"
        exit 1
    fi
    
    local uuid=$(generate_uuid)
    local server_ip=$(get_ip)
    
    echo "$uuid" > "$WORKDIR/uuid.txt"
    echo "$server_ip" > "$WORKDIR/server_ip.txt"
    
    generate_config "$uuid" "$server_ip"
    
    if start_service; then
        green "安装完成！"
        echo
        generate_links
    else
        red "安装失败"
        exit 1
    fi
}

# 主菜单
show_menu() {
    echo
    blue "=== FreeBSD科学上网管理脚本 ==="
    echo
    green "1. 安装"
    green "2. 启动服务"
    green "3. 停止服务"
    green "4. 重启服务"
    green "5. 查看状态"
    green "6. 查看节点信息"
    green "7. 查看日志"
    green "8. 卸载"
    green "0. 退出"
    echo
    readp "请选择操作 [0-8]: " choice
    
    case "$choice" in
        1) install_main ;;
        2) start_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) show_status ;;
        6) generate_links ;;
        7) show_logs ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) red "无效选择" ;;
    esac
}

# 主程序
if [[ $# -eq 0 ]]; then
    while true; do
        show_menu
    done
else
    case "$1" in
        install) install_main ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) show_status ;;
        links) generate_links ;;
        logs) show_logs ;;
        uninstall) uninstall ;;
        *) echo "用法: $0 {install|start|stop|restart|status|links|logs|uninstall}" ;;
    esac
fi