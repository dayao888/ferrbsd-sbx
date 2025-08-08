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
# 使用 sing-box 官方 GitHub 发布版本（包含完整功能）
SING_BOX_VERSION="1.11.9"
PKG_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-freebsd-amd64.tar.gz"
INSTALL_BASE="$HOME/.sbx"
BIN_DIR="$INSTALL_BASE/bin"
ETC_DIR="$INSTALL_BASE/etc"
LOG_DIR="$INSTALL_BASE/log"
TMP_DIR="/tmp/sbx_install_$$"

SING_BOX_BIN="$BIN_DIR/sing-box"
CONFIG_FILE="$ETC_DIR/config.json"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$LOG_DIR/sing-box.pid"
MANAGER_SCRIPT_PATH="$HOME/sbx.sh"

# --- 函数定义 ---

info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

error_exit() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
    [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    info "正在检查系统依赖..."
    ! command_exists curl && error_exit "curl 未安装，请先安装它。"
    ! command_exists tar && error_exit "tar 未安装，请先安装它。"
    ! command_exists openssl && error_exit "openssl 未安装，请先安装它。"
    info "所有依赖均已满足。"
}

cleanup_old_install() {
    if [ -d "$INSTALL_BASE" ] || [ -f "$MANAGER_SCRIPT_PATH" ]; then
        warn "检测到旧的安装文件。脚本将先执行卸载操作。"
        info "正在停止可能在运行的服务..."
        if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null 2>&1; then
            kill "$(cat "$PID_FILE")"
            rm -f "$PID_FILE"
        fi
        info "正在删除旧的安装目录..."
        rm -rf "$INSTALL_BASE"
        rm -f "$MANAGER_SCRIPT_PATH"
        info "旧版本已卸载。"
    fi
    
    # 检查并提醒卸载系统安装的 sing-box
    if command_exists sing-box && [ "$(which sing-box)" = "/usr/local/bin/sing-box" ]; then
        warn "检测到系统已安装 sing-box，建议先手动卸载以避免冲突：pkg delete -y sing-box"
    fi
}

get_user_config() {
    printf "您是否要为配置绑定一个域名? (建议使用) (y/n): "
    read -r use_domain
    if [ "$use_domain" = "y" ] || [ "$use_domain" = "Y" ]; then
        printf "请输入您的域名: "
        read -r DOMAIN
        [ -z "$DOMAIN" ] && error_exit "域名不能为空。"
        SERVER_ADDR="$DOMAIN"
    else
        info "您选择了不使用域名，将自动获取服务器的公网 IP 地址。"
        SERVER_ADDR=$(curl -s https://api.ipify.org)
        [ -z "$SERVER_ADDR" ] && error_exit "无法自动获取公网 IP，请检查网络或手动指定域名。"
        info "获取到公网 IP: $SERVER_ADDR"
    fi

    printf "请输入您为 ${BLUE}VLESS-Reality${NC} 准备的端口号: "
    read -r VLESS_PORT
    [ -z "$VLESS_PORT" ] && error_exit "端口号不能为空。"

    printf "请输入您为 ${BLUE}VMess-WS${NC} 准备的端口号: "
    read -r VMESS_PORT
    [ -z "$VMESS_PORT" ] && error_exit "端口号不能为空。"

    printf "请输入您为 ${BLUE}Hysteria2${NC} 准备的端口号: "
    read -r HYSTERIA2_PORT
    [ -z "$HYSTERIA2_PORT" ] && error_exit "端口号不能为空。"
}

install_sing_box() {
    info "正在创建安装目录..."
    mkdir -p "$BIN_DIR" "$ETC_DIR" "$LOG_DIR"
    info "正在创建临时下载目录: $TMP_DIR"
    mkdir -p "$TMP_DIR"

    info "正在从 sing-box 官方 GitHub 下载完整功能版本 v${SING_BOX_VERSION}..."
    info "下载可能需要一些时间，请耐心等待..."
    
    # 使用更稳定的下载方式
    if ! curl -L --connect-timeout 30 --max-time 300 -o "$TMP_DIR/sing-box.tar.gz" "$PKG_URL"; then
        error_exit "下载 sing-box 失败，请检查网络连接。"
    fi

    DOWNLOADED_SIZE=$(stat -f%z "$TMP_DIR/sing-box.tar.gz")
    info "下载完成，文件大小: $DOWNLOADED_SIZE bytes"
    
    # 检查文件大小（sing-box 压缩包通常大于 5MB）
    if [ "$DOWNLOADED_SIZE" -lt 5242880 ]; then
        error_exit "下载的文件大小异常（小于 5MB），可能下载不完整或链接无效。"
    fi

    info "正在解压 sing-box..."
    cd "$TMP_DIR" || error_exit "无法进入临时目录。"
    tar -xzf sing-box.tar.gz || error_exit "解压 sing-box 失败。"

    # 查找 sing-box 二进制文件
    SING_BOX_EXTRACTED=$(find . -name "sing-box" -type f | head -1)
    [ -z "$SING_BOX_EXTRACTED" ] && error_exit "在解压的文件中找不到 sing-box 二进制文件。"

    info "正在安装 sing-box 到 $SING_BOX_BIN..."
    cp "$SING_BOX_EXTRACTED" "$SING_BOX_BIN" || error_exit "复制 sing-box 二进制文件失败。"
    chmod +x "$SING_BOX_BIN" || error_exit "设置 sing-box 执行权限失败。"

    # 验证安装
    if ! "$SING_BOX_BIN" version >/dev/null 2>&1; then
        error_exit "sing-box 安装验证失败。"
    fi

    INSTALLED_VERSION=$("$SING_BOX_BIN" version 2>/dev/null | head -1)
    info "sing-box 安装成功！版本: $INSTALLED_VERSION"

    # 清理临时文件
    cd / && rm -rf "$TMP_DIR"
}

generate_config() {
    info "正在生成安全密钥和 UUID..."
    VLESS_UUID=$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    VMESS_UUID=$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    HYS_PASS=$(openssl rand -hex 16)
    
    info "正在生成 REALITY 密钥对..."
    KEY_PAIR=$("$SING_BOX_BIN" generate reality-keypair) || error_exit "生成 REALITY 密钥对失败。"
    PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/PrivateKey/ {print $2}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/PublicKey/ {print $2}')
    [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] && error_exit "从密钥对中提取公钥或私钥失败。"

    info "正在生成自签名证书..."
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$ETC_DIR/private.key" -out "$ETC_DIR/cert.crt" -days 365 -subj "/CN=www.microsoft.com" || error_exit "生成自签名证书失败。"

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
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
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
        "server_name": "www.microsoft.com",
        "key_path": "${ETC_DIR}/private.key",
        "certificate_path": "${ETC_DIR}/cert.crt"
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
start() {
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null 2>&1; then
        printf "${YELLOW}sing-box 已经在运行了。${NC}\n"
        return
    fi
    printf "${GREEN}正在启动 sing-box...${NC}\n"
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null 2>&1; then
        printf "${GREEN}sing-box 启动成功！PID: $(cat $PID_FILE)${NC}\n"
    else
        printf "${RED}sing-box 启动失败，请查看日志: $LOG_FILE${NC}\n"
    fi
}

stop() {
    if [ ! -f "$PID_FILE" ]; then
        printf "${YELLOW}sing-box 没有在运行。${NC}\n"
        return
    fi
    printf "${GREEN}正在停止 sing-box...${NC}\n"
    kill $(cat "$PID_FILE") 2>/dev/null
    rm -f "$PID_FILE"
    printf "${GREEN}sing-box 已停止。${NC}\n"
}

restart() {
    stop
    sleep 1
    start
}

status() {
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null 2>&1; then
        printf "${GREEN}sing-box 正在运行，PID: $(cat $PID_FILE)${NC}\n"
    else
        printf "${RED}sing-box 未运行。${NC}\n"
    fi
}

show_log() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        printf "${RED}日志文件不存在: $LOG_FILE${NC}\n"
    fi
}

show_links() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED}配置文件不存在，请重新安装。${NC}\n"
        return
    fi
    
    printf "${BLUE}=== 节点链接信息 ===${NC}\n\n"
    printf "${GREEN}PLACEHOLDER_LINKS${NC}\n"
}

uninstall() {
    printf "${YELLOW}确定要卸载 sing-box 吗？这将删除所有配置和数据。(y/n): ${NC}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        stop
        rm -rf "$INSTALL_BASE"
        rm -f "$MANAGER_SCRIPT_PATH"
        printf "${GREEN}sing-box 已完全卸载。${NC}\n"
    else
        printf "${YELLOW}取消卸载。${NC}\n"
    fi
}

show_menu() {
    printf "${BLUE}=== sing-box 管理脚本 ===${NC}\n"
    printf "1. 启动服务\n"
    printf "2. 停止服务\n"
    printf "3. 重启服务\n"
    printf "4. 查看状态\n"
    printf "5. 查看日志\n"
    printf "6. 显示链接\n"
    printf "7. 卸载\n"
    printf "8. 退出\n"
    printf "请选择操作 (1-8): "
}

# --- 主逻辑 ---
if [ $# -eq 0 ]; then
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) start ;;
            2) stop ;;
            3) restart ;;
            4) status ;;
            5) show_log ;;
            6) show_links ;;
            7) uninstall; break ;;
            8) break ;;
            *) printf "${RED}无效选择，请重新输入。${NC}\n" ;;
        esac
        printf "\n"
    done
else
    case $1 in
        start) start ;;
        stop) stop ;;
        restart) restart ;;
        status) status ;;
        log) show_log ;;
        links) show_links ;;
        uninstall) uninstall ;;
        *) printf "${RED}用法: $0 {start|stop|restart|status|log|links|uninstall}${NC}\n" ;;
    esac
fi
SCRIPT_EOF

    chmod +x "$MANAGER_SCRIPT_PATH"
    info "管理脚本创建成功！"
}

replace_placeholders() {
    info "正在替换管理脚本中的占位符..."
    
    # 生成节点链接
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_ADDR}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-REALITY"
    VMESS_LINK="vmess://$(echo '{"v":"2","ps":"VMess-WS","add":"'${SERVER_ADDR}'","port":"'${VMESS_PORT}'","id":"'${VMESS_UUID}'","aid":"0","net":"ws","type":"none","host":"","path":"/vmess","tls":""}' | base64 -w 0)"
    HYSTERIA2_LINK="hysteria2://${HYS_PASS}@${SERVER_ADDR}:${HYSTERIA2_PORT}?insecure=1&sni=www.microsoft.com#Hysteria2"
    
    LINKS_TEXT="${BLUE}VLESS + REALITY:${NC}\n${VLESS_LINK}\n\n${BLUE}VMess + WebSocket:${NC}\n${VMESS_LINK}\n\n${BLUE}Hysteria2:${NC}\n${HYSTERIA2_LINK}\n\n${BLUE}订阅链接:${NC}\ndata:text/plain;base64,$(echo "${VLESS_LINK}\n${VMESS_LINK}\n${HYSTERIA2_LINK}" | base64 -w 0)"
    
    # 替换占位符（FreeBSD 兼容的 sed 语法）
    sed -i '' "s|PLACEHOLDER_LINKS|${LINKS_TEXT}|g" "$MANAGER_SCRIPT_PATH"
}

start_service() {
    info "正在启动 sing-box 服务..."
    "$MANAGER_SCRIPT_PATH" start
}

show_final_info() {
    printf "\n${GREEN}=== 安装完成！ ===${NC}\n\n"
    printf "${BLUE}管理脚本位置:${NC} $MANAGER_SCRIPT_PATH\n"
    printf "${BLUE}配置文件位置:${NC} $CONFIG_FILE\n"
    printf "${BLUE}日志文件位置:${NC} $LOG_FILE\n\n"
    
    printf "${BLUE}常用命令:${NC}\n"
    printf "  启动服务: ./sbx.sh start\n"
    printf "  停止服务: ./sbx.sh stop\n"
    printf "  查看状态: ./sbx.sh status\n"
    printf "  查看日志: ./sbx.sh log\n"
    printf "  显示链接: ./sbx.sh links\n"
    printf "  交互菜单: ./sbx.sh\n\n"
    
    printf "${BLUE}节点链接信息:${NC}\n"
    "$MANAGER_SCRIPT_PATH" links
}

# --- 主程序 ---
main() {
    info "开始安装 sing-box..."
    check_dependencies
    cleanup_old_install
    get_user_config
    install_sing_box
    generate_config
    create_manager_script
    replace_placeholders
    start_service
    show_final_info
}

main "$@"
