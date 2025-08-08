# FreeBSD (非 root) sing-box 一键部署脚本

## 声明
本项目旨在提供一个自动化工具，方便在 **FreeBSD** 系统上为 **非 root 用户** 快速部署 `sing-box` 服务。所有生成的节点仅供个人学习和研究网络技术使用，请遵守您所在地区和服务器所在地区的法律法规。

**IP 安全性**: 本脚本配置的 **VLESS + REALITY** 协议，通过伪装流量为访问常规网站（如 `www.microsoft.com`），极大地提高了连接的安全性与隐蔽性，能有效防止 IP 被探测和封锁。

---

## ✨ 项目特⾊

- **专为非 root 用户设计**: 无需 `sudo` 或 `root` 权限，所有文件和进程均在用户主目录 (`$HOME`) 下运行，干净无污染。
- **全交互式安装**: 通过简单的问答形式，引导您完成域名、端口等关键信息的配置。
- **多协议支持**: 一次性部署三种主流高效协议，满足不同网络环境下的需求：
    1.  **VLESS + REALITY**: 安全性与伪装性极佳，推荐首选。
    2.  **VMess + WebSocket**: 兼容性好，连接稳定。
    3.  **Hysteria 2**: 高速暴力发包协议，适合网络环境好的情况。
- **自动化安全配置**: UUID、密钥、密码等敏感信息均在安装时自动随机生成，保障每个部署的独特性和安全性。
- **便捷的命令行管理面板**: 提供一个简单的管理脚本 `sbx.sh`，轻松完成启动、停止、重启、卸载、查看日志和链接等操作。
- **订阅链接生成**: 自动生成聚合了所有节点的订阅链接，方便一键导入各类客户端。

---

## 🚀 快速开始

### 准备工作

1.  一台运行 FreeBSD 14.3+ (amd64) 的服务器。
2.  一个普通的（非 root）用户账户。
3.  在您的服务器防火墙或云服务商安全组中，提前规划并**开放三个端口** (TCP/UDP)。
4.  (可选) 准备一个域名，并将其解析到您的服务器 IP 地址。

### 一键安装

通过 SSH 登录您的 FreeBSD 服务器，然后执行以下命令：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main/install.sh)"
```
*注意：请将上面的 `dayao888/ferrbsd-sbx` 替换为您自己的 GitHub 用户名和仓库名。*

脚本将会引导您完成后续的配置。安装成功后，屏幕上会直接显示节点链接和订阅链接。

---

## 🛠️ 管理脚本用法

脚本安装成功后，会在您当前目录下生成一个管理脚本 `sbx.sh`。

**使用方法:**

```bash
# 显示管理菜单 (推荐)
./sbx.sh menu

# 直接使用命令
./sbx.sh [命令]

# 例如:
./sbx.sh start    # 启动服务
./sbx.sh stop     # 停止服务
./sbx.sh restart  # 重启服务
./sbx.sh status   # 查看运行状态
./sbx.sh log      # 查看实时日志
./sbx.sh links    # 重新显示节点和订阅链接
./sbx.sh uninstall # 卸载
```

---

### **第二步：创建 `install.sh` 一键安装脚本**

这是整个项目的核心。它将负责执行我们讨论过的所有自动化任务：交互式提问、下载核心、解压、生成配置、创建管理脚本并最终启动服务。

我已经为您编写好了这个脚本。

```bash:%2Fc%3A%2FUsers%2Fdayao%2FDesktop%2Fsbx%2Finstall.sh
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
# 从您的 GitHub 仓库下载 .pkg 文件
PKG_URL="https://github.com/dayao888/ferrbsd-sbx/raw/main/sing-box-1.11.9.pkg"
# 安装目录
INSTALL_BASE="$HOME/.sbx"
BIN_DIR="$INSTALL_BASE/bin"
ETC_DIR="$INSTALL_BASE/etc"
LOG_DIR="$INSTALL_BASE/log"
TMP_DIR="$INSTALL_BASE/tmp"

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
    if [ -d "$INSTALL_BASE" ]; then
        warn "检测到旧的安装目录 ($INSTALL_BASE)。"
        printf "您想卸载旧版本并重新安装吗? (y/n): "
        read -r choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            info "正在停止可能在运行的服务..."
            if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
                kill "$(cat "$PID_FILE")"
                rm -f "$PID_FILE"
            fi
            info "正在删除旧的安装目录..."
            rm -rf "$INSTALL_BASE"
            rm -f "$MANAGER_SCRIPT_PATH"
            info "旧版本已卸载。"
        else
            error_exit "安装已取消。"
        fi
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
    mkdir -p "$BIN_DIR" "$ETC_DIR" "$LOG_DIR" "$TMP_DIR"

    info "正在从 GitHub 下载 sing-box 核心包..."
    curl -L -o "$TMP_DIR/sing-box.pkg" "$PKG_URL" || error_exit "下载 sing-box 核心失败。"

    info "正在解压核心包..."
    tar -xf "$TMP_DIR/sing-box.pkg" -C "$TMP_DIR" || error_exit "解压核心包失败。"

    info "正在安装 sing-box 二进制文件..."
    # 从解压后的目录中找到并移动二进制文件
    if [ -f "$TMP_DIR/usr/local/bin/sing-box" ]; then
        mv "$TMP_DIR/usr/local/bin/sing-box" "$SING_BOX_BIN"
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
    
    # 生成 REALITY 密钥对
    KEY_PAIR=$( "$SING_BOX_BIN" generate reality-keypair )
    PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/PrivateKey/ {print $2}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/PublicKey/ {print $2}')

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
    cat > "$MANAGER_SCRIPT_PATH" << EOF
#!/bin/sh

# --- 全局变量 ---
INSTALL_BASE="$INSTALL_BASE"
SING_BOX_BIN="\$INSTALL_BASE/bin/sing-box"
CONFIG_FILE="\$INSTALL_BASE/etc/config.json"
LOG_FILE="\$INSTALL_BASE/log/sing-box.log"
PID_FILE="\$INSTALL_BASE/log/sing-box.pid"
MANAGER_SCRIPT_PATH="$MANAGER_SCRIPT_PATH"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 函数 ---
start() {
    if [ -f "\$PID_FILE" ] && ps -p \$(cat "\$PID_FILE") > /dev/null; then
        printf "\${YELLOW}sing-box 已经在运行了。\${NC}\n"
        return
    fi
    printf "\${GREEN}正在启动 sing-box...${NC}\n"
    nohup "\$SING_BOX_BIN" run -c "\$CONFIG_FILE" > "\$LOG_FILE" 2>&1 &
    echo \$! > "\$PID_FILE"
    sleep 1
    if [ -f "\$PID_FILE" ] && ps -p \$(cat "\$PID_FILE") > /dev/null; then
        printf "\${GREEN}sing-box 启动成功！PID: \$(cat \$PID_FILE)${NC}\n"
    else
        printf "\${RED}sing-box 启动失败，请查看日志: \$LOG_FILE${NC}\n"
    fi
}

stop() {
    if [ ! -f "\$PID_FILE" ]; then
        printf "\${YELLOW}sing-box 没有在运行。\${NC}\n"
        return
    fi
    printf "\${GREEN}正在停止 sing-box...${NC}\n"
    kill \$(cat "\$PID_FILE")
    rm -f "\$PID_FILE"
    printf "\${GREEN}sing-box 已停止。\${NC}\n"
}

restart() {
    stop
    sleep 1
    start
}

status() {
    if [ -f "\$PID_FILE" ] && ps -p \$(cat "\$PID_FILE") > /dev/null; then
        printf "\${GREEN}sing-box 正在运行。PID: \$(cat \$PID_FILE)${NC}\n"
    else
        printf "\${RED}sing-box 已停止。\${NC}\n"
    fi
}

show_log() {
    printf "\${GREEN}正在显示实时日志 (按 Ctrl+C 退出)...${NC}\n"
    tail -f "\$LOG_FILE"
}

show_links() {
    # 从配置文件中提取信息
    SERVER_ADDR="$SERVER_ADDR"
    VLESS_PORT=$VLESS_PORT
    VMESS_PORT=$VMESS_PORT
    HYSTERIA2_PORT=$HYSTERIA2_PORT
    VLESS_UUID="$VLESS_UUID"
    VMESS_UUID="$VMESS_UUID"
    HYS_PASS="$HYS_PASS"
    PUBLIC_KEY="$PUBLIC_KEY"
    DOMAIN_OR_IP="$SERVER_ADDR"

    # 生成链接
    VLESS_LINK="vless://\${VLESS_UUID}@\${DOMAIN_OR_IP}:\${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=\${PUBLIC_KEY}&type=tcp#VLESS-REALITY"
    VMESS_RAW="{\\"v\\":\\"2\\",\\"ps\\":\\"VMess-WS\\",\\"add\\":\\"\${DOMAIN_OR_IP}\\",\\"port\\":\\"\${VMESS_PORT}\\",\\"id\\":\\"\${VMESS_UUID}\\",\\"aid\\":0,\\"net\\":\\"ws\\",\\"type\\":\\"none\\",\\"host\\":\\"\\",\\"path\\":\\"/vmess\\",\\"tls\\":\\"\\"}"
    VMESS_LINK="vmess://\$(echo "\$VMESS_RAW" | base64 -w 0)"
    HYSTERIA2_LINK="hysteria2://\${HYS_PASS}@\${DOMAIN_OR_IP}:\${HYSTERIA2_PORT}?sni=www.microsoft.com#Hysteria2"
    
    # 订阅链接
    ALL_LINKS="\${VLESS_LINK}\n\${VMESS_LINK}\n\${HYSTERIA2_LINK}"
    SUB_LINK="data:text/plain;base64,\$(echo "\$ALL_LINKS" | base64 -w 0)"

    printf "\n"
    printf "================================================================\n"
    printf "${GREEN}安装完成！您的节点信息如下：${NC}\n"
    printf "================================================================\n"
    printf "${BLUE}VLESS + REALITY:${NC}\n"
    printf "%s\n" "\$VLESS_LINK"
    printf "----------------------------------------------------------------\n"
    printf "${BLUE}VMess + WebSocket:${NC}\n"
    printf "%s\n" "\$VMESS_LINK"
    printf "----------------------------------------------------------------\n"
    printf "${BLUE}Hysteria 2:${NC}\n"
    printf "%s\n" "\$HYSTERIA2_LINK"
    printf "----------------------------------------------------------------\n"
    printf "${YELLOW}订阅链接:${NC}\n"
    printf "%s\n" "\$SUB_LINK"
    printf "================================================================\n"
}

uninstall() {
    printf "\${RED}警告：这将停止服务并删除所有相关文件 (${INSTALL_BASE})。${NC}\n"
    printf "您确定要卸载吗? (y/n): "
    read -r choice
    if [ "\$choice" = "y" ] || [ "\$choice" = "Y" ]; then
        stop
        printf "\${GREEN}正在删除安装目录...${NC}\n"
        rm -rf "\$INSTALL_BASE"
        printf "\${GREEN}正在删除管理脚本...${NC}\n"
        rm -f "\$MANAGER_SCRIPT_PATH"
        printf "\${GREEN}卸载完成！${NC}\n"
    else
        printf "\${YELLOW}卸载已取消。${NC}\n"
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
    case \$option in
        1) start ;;
        2) stop ;;
        3) restart ;;
        4) status ;;
        5) show_log ;;
        6) show_links ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) printf "\${RED}无效的选项!${NC}\n" ;;
    esac
}

# --- 主逻辑 ---
if [ \$# -eq 0 ]; then
    show_menu
    exit 0
fi

case "\$1" in
    start|stop|restart|status|log|links|uninstall|menu)
        "\$1"
        ;;
    *)
        printf "用法: \$0 {start|stop|restart|status|log|links|uninstall|menu}\n"
        exit 1
        ;;
esac
EOF
    chmod +x "$MANAGER_SCRIPT_PATH"
    info "管理脚本创建成功: $MANAGER_SCRIPT_PATH"
}

# --- 主执行流程 ---
main() {
    clear
    echo "================================================================"
    echo "     欢迎使用 FreeBSD (non-root) sing-box 一键安装脚本"
    echo "================================================================"
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
    sh "$MANAGER_SCRIPT_PATH" links
    
    info "您可以使用 './sbx.sh menu' 命令来管理服务。"
}

# 运行主函数
main
```

---

### **下一步计划**

现在，您需要将这两个文件 (`README.md` 和 `install.sh`) 上传到您的 GitHub 仓库 `dayao888/ferrbsd-sbx` 的主分支 `main` 下。

请在您完成上传后，告诉我一声。然后，我们就可以进行最后一步：在您的 FreeBSD 服务器上执行一键安装命令，进行实际的部署测试了。
