#!/bin/sh

#================================================================
# FreeBSD (non-root) sing-box Installation Script
#
# Author: Gemini
#
# GitHub: https://github.com/dayao888/ferrbsd-sbx
#================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 全局变量 ---
# 使用 FreeBSD 官方 pkg 源
PKG_URL="http://pkg.freebsd.org/FreeBSD:14:amd64/latest/All/sing-box-1.11.9.pkg"

# 安装目录
INSTALL_BASE="$HOME/.sbx"
BIN_DIR="$INSTALL_BASE/bin"
ETC_DIR="$INSTALL_BASE/etc"
LOG_DIR="$INSTALL_BASE/log"
TMP_DIR="/tmp/sbx_install_$$" # 使用唯一的临时目录

# 脚本和配置文件路径
SING_BOX_BIN="$BIN_DIR/sing-box"
CONFIG_FILE="$ETC_DIR/config.json"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$LOG_DIR/sing-box.pid"
MANAGER_SCRIPT_PATH="$HOME/sbx.sh"

# --- 函数定义 ---

# 打印信息
info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

# 打印警告
warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

# 打印错误并退出
error_exit() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
    # 清理临时目录
    [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查依赖
check_dependencies() {
    info "正在检查系统依赖..."
    ! command_exists curl && error_exit "curl 未安装，请先安装它。"
    ! command_exists tar && error_exit "tar 未安装，请先安装它。"
    ! command_exists openssl && error_exit "openssl 未安装，请先安装它。"
    info "所有依赖均已满足。"
}

# 清理旧的安装
cleanup_old_install() {
    if [ -d "$INSTALL_BASE" ] || [ -f "$MANAGER_SCRIPT_PATH" ]; then
        warn "检测到旧的安装文件。脚本将先执行卸载操作。"
        info "正在停止可能在运行的服务..."
        if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
            kill "$(cat "$PID_FILE")"
            rm -f "$PID_FILE"
        fi
        info "正在删除旧的安装目录..."
        rm -rf "$INSTALL_BASE"
        rm -f "$MANAGER_SCRIPT_PATH"
        info "旧版本已卸载。"
    fi
}

# 获取用户配置
get_user_config() {
    # 获取域名
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

    # 获取端口
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

# 安装 sing-box
install_sing_box() {
    info "正在创建安装目录..."
    mkdir -p "$BIN_DIR" "$ETC_DIR" "$LOG_DIR"
    
    info "正在创建临时下载目录: $TMP_DIR"
    mkdir -p "$TMP_DIR"

    info "正在从 FreeBSD 官方源下载 sing-box 核心包..."
    curl -L -o "$TMP_DIR/sing-box.pkg" "$PKG_URL" || error_exit "下载 sing-box 核心失败。"

    DOWNLOADED_SIZE=$(stat -f%z "$TMP_DIR/sing-box.pkg")
    info "正在解压核心包 (文件大小: $DOWNLOADED_SIZE bytes)..."
    
    if [ "$DOWNLOADED_SIZE" -lt 102400 ]; then # 小于100KB，肯定有问题
        error_exit "下载的 sing-box.pkg 文件大小异常，请检查网络或链接有效性。"
    fi

    tar -xf "$TMP_DIR/sing-box.pkg" -C "$TMP_DIR" --strip-components 3 '*/local/bin/sing-box' || error_exit "解压核心包失败。"

    info "正在安装 sing-box 二进制文件..."
    if [ -f "$TMP_DIR/sing-box" ]; then
        mv "$TMP_DIR/sing-box" "$SING_BOX_BIN"
        chmod +x "$SING_BOX_BIN"
    else
        error_exit "在 .pkg 文件中未找到 sing-box 二进制文件。"
    fi

    info "正在清理临时文件..."
    rm -rf "$TMP_DIR"

    info "sing-box 核心安装成功！"
}

# 生成配置
generate_config() {
    info "正在生成安全密钥和 UUID..."
    VLESS_UUID=$(openssl rand -hex 16)
    VMESS_UUID=$(openssl rand -hex 16)
    HYS_PASS=$(openssl rand -hex 16)
    
    info "正在生成 REALITY 密钥对..."
    # 确保路径正确，并处理可能的错误
    KEY_PAIR=$("$SING_BOX_BIN" generate reality-keypair) || error_exit "生成 REALITY 密钥对失败。"
    PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/PrivateKey/ {print $2}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/PublicKey/ {print $2}')
    [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] && error_exit "从密钥对中提取公钥或私钥失败。"

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
      "transport": {
        "type": "reality",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ""
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
      "users": {
        "${HYS_PASS}": ""
      },
      "transport": {
        "type": "udp"
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

# 创建管理脚本
create_manager_script() {
    info "正在创建管理脚本 (sbx.sh)..."
    # 使用 cat <<'EOF' 替代 cat <<EOF, 防止本地变量被意外替换
    cat > "$MANAGER_SCRIPT_PATH" << 'EOF'
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
NC='\033[0m' # No Color

# --- 函数 ---
start() {
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null; then
        printf "${YELLOW}sing-box 已经在运行了。${NC}\n"
        return
    fi
    printf "${GREEN}正在启动 sing-box...${NC}\n"
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null; then
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
    kill $(cat "$PID_FILE")
    rm -f "$PID_FILE"
    printf "${GREEN}sing-box 已停止。${NC}\n"
}

restart() {
    stop
    sleep 1
    start
}

status() {
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null; then
        printf "${GREEN}sing-box 正在运行。PID: $(cat $PID_FILE)${NC}\n"
    else
        printf "${RED}sing-box 已停止。${NC}\n"
    fi
}

show_log() {
    printf "${GREEN}正在显示实时日志 (按 Ctrl+C 退出)...${NC}\n"
    tail -f "$LOG_FILE"
}

show_links() {
    # 这些变量将在下面的替换步骤中被实际值填充
    SERVER_ADDR="__SERVER_ADDR__"
    VLESS_PORT="__VLESS_PORT__"
    VMESS_PORT="__VMESS_PORT__"
    HYSTERIA2_PORT="__HYSTERIA2_PORT__"
    VLESS_UUID="__VLESS_UUID__"
    VMESS_UUID="__VMESS_UUID__"
    HYS_PASS="__HYS_PASS__"
    PUBLIC_KEY="__PUBLIC_KEY__"
    DOMAIN_OR_IP="$SERVER_ADDR"

    # 生成链接
    VLESS_LINK="vless://${VLESS_UUID}@${DOMAIN_OR_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#VLESS-REALITY"
    VMESS_RAW="{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${DOMAIN_OR_IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":0,\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/vmess\",\"tls\":\"\"}"
    VMESS_LINK="vmess://$(echo "$VMESS_RAW" | base64 -w 0)"
    HYSTERIA2_LINK="hysteria2://${HYS_PASS}@${DOMAIN_OR_IP}:${HYSTERIA2_PORT}?sni=www.microsoft.com#Hysteria2"
    
    # 订阅链接
    ALL_LINKS="${VLESS_LINK}\n${VMESS_LINK}\n${HYSTERIA2_LINK}"
    SUB_LINK="data:text/plain;base64,$(echo "$ALL_LINKS" | base64 -w 0)"

    printf "\n"
    printf "================================================================\n"
    printf "${GREEN}安装完成！您的节点信息如下：${NC}\n"
    printf "================================================================\n"
    printf "${BLUE}VLESS + REALITY:${NC}\n"
    printf "%s\n" "$VLESS_LINK"
    printf "----------------------------------------------------------------\n"
    printf "${BLUE}VMess + WebSocket:${NC}\n"
    printf "%s\n" "$VMESS_LINK"
    printf "----------------------------------------------------------------\n"
    printf "${BLUE}Hysteria 2:${NC}\n"
    printf "%s\n" "$HYSTERIA2_LINK"
    printf "----------------------------------------------------------------\n"
    printf "${YELLOW}订阅链接:${NC}\n"
    printf "%s\n" "$SUB_LINK"
    printf "================================================================\n"
}

uninstall() {
    printf "${RED}警告：这将停止服务并删除所有相关文件 (${INSTALL_BASE})。${NC}\n"
    printf "您确定要卸载吗? (y/n): "
    read -r choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        stop
        printf "${GREEN}正在删除安装目录...${NC}\n"
        rm -rf "$INSTALL_BASE"
        printf "${GREEN}正在删除管理脚本...${NC}\n"
        rm -f "$MANAGER_SCRIPT_PATH"
        printf "${GREEN}卸载完成！${NC}\n"
    else
        printf "${YELLOW}卸载已取消。${NC}\n"
    fi
}

show_menu() {
    clear
    printf "================================================\n"
    printf "     FreeBSD (non-root) sing-box 管理面板\n"
    printf "================================================\n"
    printf " ${GREEN}1. 启动 sing-box${NC}\n"
    printf " ${RED}2. 停止 sing-box${NC}\n"
    printf " ${YELLOW}3. 重启 sing-box${NC}\n"
    printf " ${BLUE}4. 查看状态${NC}\n"
    printf " ${BLUE}5. 查看日志${NC}\n"
    printf " ${BLUE}6. 查看节点链接${NC}\n"
    printf " ${RED}7. 卸载脚本${NC}\n"
    printf " ${YELLOW}0. 退出${NC}\n"
    printf "================================================\n"
    printf "请输入选项 [0-7]: "
    read -r option
    case $option in
        1) start ;;
        2) stop ;;
        3) restart ;;
        4) status ;;
        5) show_log ;;
        6) show_links ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) printf "${RED}无效的选项!${NC}\n" ;;
    esac
}

# --- 主逻辑 ---
# 如果没有参数，则显示菜单。否则，执行对应命令。
main() {
    ACTION=${1:-menu}

    case "$ACTION" in
        start) start ;;
        stop) stop ;;
        restart) restart ;;
        status) status ;;
        log) show_log ;;
        links) show_links ;;
        uninstall) uninstall ;;
        menu)
            while true; do
                show_menu
                printf "\n按 Enter 键返回菜单..."
                read -r _
            done
            ;;
        *)
            printf "${RED}用法: $0 {start|stop|restart|status|log|links|uninstall|menu}${NC}\n"
            exit 1
            ;;
    esac
}

main "$@"

EOF
    # --- 变量替换 ---
    # 使用 sed 将占位符替换为实际值
    sed -i '' "s|__SERVER_ADDR__|${SERVER_ADDR}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__VLESS_PORT__|${VLESS_PORT}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__VMESS_PORT__|${VMESS_PORT}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__HYSTERIA2_PORT__|${HYSTERIA2_PORT}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__VLESS_UUID__|${VLESS_UUID}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__VMESS_UUID__|${VMESS_UUID}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__HYS_PASS__|${HYS_PASS}|g" "$MANAGER_SCRIPT_PATH"
    sed -i '' "s|__PUBLIC_KEY__|${PUBLIC_KEY}|g" "$MANAGER_SCRIPT_PATH"

    chmod +x "$MANAGER_SCRIPT_PATH"
    info "管理脚本创建成功: $MANAGER_SCRIPT_PATH"
}


# --- 主执行流程 ---
main() {
    # 确保在脚本退出或中断时清理临时文件
    trap 'rm -rf "$TMP_DIR"' EXIT

    clear
    echo "================================================================="
    echo "     欢迎使用 FreeBSD (non-root) sing-box 一键安装脚本"
    echo "================================================================="
    echo
    
    check_dependencies
    cleanup_old_install
    get_user_config
    install_sing_box
    generate_config
    create_manager_script

    # 启动服务并显示链接
    info "正在首次启动服务..."
    sh "$MANAGER_SCRIPT_PATH" start
    
    info "服务启动成功！您的节点信息如下："
    sh "$MANAGER_SCRIPT_PATH" links
    
    echo
    info "安装全部完成！"
    info "您随时可以使用 'sh $MANAGER_SCRIPT_PATH' 或 './sbx.sh' 命令来管理服务和查看链接。"
}

# 运行主函数
main
