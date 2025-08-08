#!/bin/sh

#================================================================
# FreeBSD (non-root) sing-box Installation Script
#
# Author: AI Assistant
# GitHub: https://github.com/dayao888/ferrbsd-sbx
#================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 全局变量 ---
# 使用系统已安装的 sing-box
SYSTEM_SING_BOX="/usr/local/bin/sing-box"
INSTALL_BASE="$HOME/.sbx"
BIN_DIR="$INSTALL_BASE/bin"
ETC_DIR="$INSTALL_BASE/etc"
LOG_DIR="$INSTALL_BASE/log"
CERT_DIR="$INSTALL_BASE/certs"

SING_BOX_BIN="$BIN_DIR/sing-box"
CONFIG_FILE="$ETC_DIR/config.json"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$LOG_DIR/sing-box.pid"
MANAGER_SCRIPT_PATH="$HOME/sbx.sh"

# 证书文件路径
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"

# --- 函数定义 ---

info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

error_exit() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    info "正在检查系统依赖..."
    
    # 检查必需的命令
    for cmd in curl openssl; do
        if ! command_exists "$cmd"; then
            error_exit "缺少必需的命令: $cmd，请先安装。"
        fi
    done
    
    # 检查 sing-box 是否已安装
    if [ ! -f "$SYSTEM_SING_BOX" ]; then
        error_exit "系统中未找到 sing-box，请先运行: pkg install sing-box"
    fi
    
    info "系统依赖检查完成。"
}

get_public_ip() {
    info "正在获取公网 IP..."
    PUBLIC_IP=$(curl -s --connect-timeout 10 ipinfo.io/ip || curl -s --connect-timeout 10 ifconfig.me || curl -s --connect-timeout 10 icanhazip.com)
    if [ -z "$PUBLIC_IP" ]; then
        warn "无法获取公网 IP，将使用 127.0.0.1"
        PUBLIC_IP="127.0.0.1"
    else
        info "获取到公网 IP: $PUBLIC_IP"
    fi
}

get_user_config() {
    info "开始交互式配置..."
    
    # 获取域名（可选）
    printf "${BLUE}请输入您的域名 (可选，直接回车跳过): ${NC}"
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then
        DOMAIN="www.microsoft.com"
        info "使用默认域名: $DOMAIN"
    fi
    
    # 获取端口配置
    while true; do
        printf "${BLUE}请输入您为 VLESS-Reality 准备的端口号: ${NC}"
        read -r VLESS_PORT
        if [ -n "$VLESS_PORT" ] && [ "$VLESS_PORT" -ge 1 ] && [ "$VLESS_PORT" -le 65535 ]; then
            break
        else
            error_exit "端口号不能为空，且必须在 1-65535 范围内。"
        fi
    done
    
    while true; do
        printf "${BLUE}请输入您为 VMess-WS 准备的端口号: ${NC}"
        read -r VMESS_PORT
        if [ -n "$VMESS_PORT" ] && [ "$VMESS_PORT" -ge 1 ] && [ "$VMESS_PORT" -le 65535 ]; then
            break
        else
            error_exit "端口号不能为空，且必须在 1-65535 范围内。"
        fi
    done
    
    while true; do
        printf "${BLUE}请输入您为 Hysteria2 准备的端口号: ${NC}"
        read -r HYSTERIA2_PORT
        if [ -n "$HYSTERIA2_PORT" ] && [ "$HYSTERIA2_PORT" -ge 1 ] && [ "$HYSTERIA2_PORT" -le 65535 ]; then
            break
        else
            error_exit "端口号不能为空，且必须在 1-65535 范围内。"
        fi
    done
}

cleanup_old_installation() {
    info "正在清理旧版本安装..."
    
    # 停止服务（如果正在运行）
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            info "正在停止旧的 sing-box 服务..."
            kill "$OLD_PID"
            sleep 2
        fi
        rm -f "$PID_FILE"
    fi
    
    # 清理旧文件
    [ -d "$INSTALL_BASE" ] && rm -rf "$INSTALL_BASE"
    [ -f "$MANAGER_SCRIPT_PATH" ] && rm -f "$MANAGER_SCRIPT_PATH"
    
    info "旧版本清理完成。"
}

setup_sing_box() {
    info "正在设置 sing-box 环境..."
    mkdir -p "$BIN_DIR" "$ETC_DIR" "$LOG_DIR" "$CERT_DIR"
    
    # 创建 sing-box 的符号链接到用户目录
    if [ -f "$SYSTEM_SING_BOX" ]; then
        ln -sf "$SYSTEM_SING_BOX" "$SING_BOX_BIN"
        info "sing-box 环境设置成功！"
    else
        error_exit "系统中的 sing-box 不存在，请检查安装。"
    fi
}

generate_certificates() {
    info "正在生成自签名证书用于 Hysteria2..."
    
    # 生成私钥
    openssl genrsa -out "$KEY_FILE" 2048 || error_exit "生成私钥失败。"
    
    # 生成自签名证书
    openssl req -new -x509 -key "$KEY_FILE" -out "$CERT_FILE" -days 365 -subj "/C=US/ST=CA/L=LA/O=SBX/CN=$DOMAIN" || error_exit "生成证书失败。"
    
    info "证书生成成功！"
}

generate_reality_keys() {
    info "正在生成 Reality 密钥对..."
    
    # 使用 sing-box 生成 Reality 密钥对
    REALITY_OUTPUT=$("$SING_BOX_BIN" generate reality-keypair)
    if [ $? -ne 0 ]; then
        error_exit "生成 Reality 密钥对失败。"
    fi
    
    # 解析输出
    PRIVATE_KEY=$(echo "$REALITY_OUTPUT" | grep "PrivateKey:" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$REALITY_OUTPUT" | grep "PublicKey:" | awk '{print $2}')
    
    [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] && error_exit "从密钥对中提取公钥或私钥失败。"
    
    info "Reality 密钥对生成成功！"
}

generate_config() {
    info "正在生成随机 UUID 和密码..."
    VLESS_UUID=$("$SING_BOX_BIN" generate uuid)
    VMESS_UUID=$("$SING_BOX_BIN" generate uuid)
    HYS_PASS=$(openssl rand -base64 16)
    
    # 生成 Reality 密钥对
    generate_reality_keys
    
    # 生成自签名证书
    generate_certificates

    info "正在生成 config.json 配置文件..."
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${VLESS_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${DOMAIN}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [""]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${VMESS_PORT},
      "users": [
        {
          "uuid": "${VMESS_UUID}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${HYSTERIA2_PORT},
      "users": [
        {
          "password": "${HYS_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
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
    info "配置文件生成成功！"
}

create_manager_script() {
    info "正在创建管理脚本 (sbx.sh)..."
    cat > "$MANAGER_SCRIPT_PATH" << 'SCRIPT_EOF'
#!/bin/sh

# --- 全局变量 ---
INSTALL_BASE="$HOME/.sbx"
SING_BOX_BIN="$INSTALL_BASE/bin/sing-box"
CONFIG_FILE="$INSTALL_BASE/etc/config.json"
LOG_FILE="$INSTALL_BASE/log/sing-box.log"
PID_FILE="$INSTALL_BASE/log/sing-box.pid"
MANAGER_SCRIPT_PATH="$HOME/sbx.sh"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 函数 ---
info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

error() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
}

start() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            warn "sing-box 已经在运行中 (PID: $PID)"
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    
    info "正在启动 sing-box 服务..."
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        info "sing-box 服务启动成功！"
    else
        error "sing-box 服务启动失败，请检查日志。"
        rm -f "$PID_FILE"
        return 1
    fi
}

stop() {
    if [ ! -f "$PID_FILE" ]; then
        warn "sing-box 服务未运行。"
        return 0
    fi
    
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        info "正在停止 sing-box 服务..."
        kill "$PID"
        sleep 2
        
        if kill -0 "$PID" 2>/dev/null; then
            warn "正常停止失败，强制终止..."
            kill -9 "$PID"
        fi
        
        rm -f "$PID_FILE"
        info "sing-box 服务已停止。"
    else
        warn "PID 文件存在但进程未运行，清理 PID 文件。"
        rm -f "$PID_FILE"
    fi
}

restart() {
    stop
    sleep 1
    start
}

status() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            info "sing-box 服务正在运行 (PID: $PID)"
        else
            error "PID 文件存在但进程未运行"
            rm -f "$PID_FILE"
        fi
    else
        warn "sing-box 服务未运行"
    fi
}

show_log() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        error "日志文件不存在"
    fi
}

show_links() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "配置文件不存在"
        return 1
    fi
    
    info "节点链接信息："
    echo "VLESS-Reality: PLACEHOLDER_VLESS_LINK"
    echo "VMess-WS: PLACEHOLDER_VMESS_LINK"
    echo "Hysteria2: PLACEHOLDER_HYSTERIA2_LINK"
    echo ""
    echo "订阅链接: PLACEHOLDER_SUBSCRIPTION_LINK"
}

uninstall() {
    printf "${RED}确定要卸载 sing-box 吗？这将删除所有配置和数据 [y/N]: ${NC}"
    read -r confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            stop
            info "正在卸载 sing-box..."
            rm -rf "$INSTALL_BASE"
            rm -f "$MANAGER_SCRIPT_PATH"
            info "sing-box 已完全卸载。"
            ;;
        *)
            info "取消卸载。"
            ;;
    esac
}

show_menu() {
    echo ""
    printf "${BLUE}========== sing-box 管理面板 ==========${NC}\n"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 查看状态"
    echo "5. 查看日志"
    echo "6. 显示链接"
    echo "7. 卸载"
    echo "0. 退出"
    printf "${BLUE}=======================================${NC}\n"
    printf "请选择操作 [0-7]: "
}

menu() {
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1) start ;;
            2) stop ;;
            3) restart ;;
            4) status ;;
            5) show_log ;;
            6) show_links ;;
            7) uninstall; break ;;
            0) break ;;
            *) error "无效选择，请重新输入。" ;;
        esac
        echo ""
        printf "按回车键继续..."
        read -r
    done
}

# 主逻辑
case "$1" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    log) show_log ;;
    links) show_links ;;
    uninstall) uninstall ;;
    menu|*) menu ;;
esac
SCRIPT_EOF

    chmod +x "$MANAGER_SCRIPT_PATH"
    
    # 替换占位符
    replace_placeholders_in_manager
    
    info "管理脚本创建成功！"
}

replace_placeholders_in_manager() {
    info "正在替换管理脚本中的占位符..."
    
    # 从配置文件中提取信息
    VLESS_UUID=$(grep -A 10 '"type": "vless"' "$CONFIG_FILE" | grep '"uuid":' | sed 's/.*"uuid": "\([^"]*\)".*/\1/')
    VMESS_UUID=$(grep -A 10 '"type": "vmess"' "$CONFIG_FILE" | grep '"uuid":' | sed 's/.*"uuid": "\([^"]*\)".*/\1/')
    HYS_PASS=$(grep -A 10 '"type": "hysteria2"' "$CONFIG_FILE" | grep '"password":' | sed 's/.*"password": "\([^"]*\)".*/\1/')
    
    # 生成链接
    VLESS_LINK="vless://${VLESS_UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-Reality"
    VMESS_LINK="vmess://$(echo "{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/vmess\",\"tls\":\"\"}" | base64 -w 0)"
    HYSTERIA2_LINK="hysteria2://${HYS_PASS}@${PUBLIC_IP}:${HYSTERIA2_PORT}?insecure=1&sni=${DOMAIN}#Hysteria2"
    
    # 生成订阅链接（base64编码的节点列表）
    SUBSCRIPTION_CONTENT="${VLESS_LINK}\n${VMESS_LINK}\n${HYSTERIA2_LINK}"
    SUBSCRIPTION_LINK="data:text/plain;base64,$(echo -e "$SUBSCRIPTION_CONTENT" | base64 -w 0)"
    
    # 替换占位符
    sed -i "" "s|PLACEHOLDER_VLESS_LINK|$VLESS_LINK|g" "$MANAGER_SCRIPT_PATH"
    sed -i "" "s|PLACEHOLDER_VMESS_LINK|$VMESS_LINK|g" "$MANAGER_SCRIPT_PATH"
    sed -i "" "s|PLACEHOLDER_HYSTERIA2_LINK|$HYSTERIA2_LINK|g" "$MANAGER_SCRIPT_PATH"
    sed -i "" "s|PLACEHOLDER_SUBSCRIPTION_LINK|$SUBSCRIPTION_LINK|g" "$MANAGER_SCRIPT_PATH"
}

start_service() {
    info "正在启动 sing-box 服务..."
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        info "sing-box 服务启动成功！"
    else
        error_exit "sing-box 服务启动失败，请检查配置文件和日志。"
    fi
}

show_final_info() {
    info "安装完成！正在显示节点信息..."
    echo ""
    printf "${BLUE}========== 节点信息 ==========${NC}\n"
    echo "VLESS-Reality: vless://${VLESS_UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-Reality"
    echo ""
    echo "VMess-WS: vmess://$(echo "{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/vmess\",\"tls\":\"\"}" | base64 -w 0)"
    echo ""
    echo "Hysteria2: hysteria2://${HYS_PASS}@${PUBLIC_IP}:${HYSTERIA2_PORT}?insecure=1&sni=${DOMAIN}#Hysteria2"
    echo ""
    printf "${BLUE}========== 管理命令 ==========${NC}\n"
    echo "启动服务: $MANAGER_SCRIPT_PATH start"
    echo "停止服务: $MANAGER_SCRIPT_PATH stop"
    echo "查看状态: $MANAGER_SCRIPT_PATH status"
    echo "管理面板: $MANAGER_SCRIPT_PATH menu"
    echo ""
    printf "${GREEN}安装完成！请保存好上述节点信息。${NC}\n"
}

# --- 主程序 ---
info "开始 FreeBSD sing-box 一键安装脚本..."

# 检查系统依赖
check_dependencies

# 获取公网 IP
get_public_ip

# 获取用户配置
get_user_config

# 清理旧版本
cleanup_old_installation

# 设置 sing-box 环境
setup_sing_box

# 生成配置文件
generate_config

# 创建管理脚本
create_manager_script

# 启动服务
start_service

# 显示最终信息
show_final_info

info "脚本执行完成！"
