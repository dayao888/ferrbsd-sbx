#!/bin/bash

# FreeBSD科学上网一键安装脚本
# 使用方法：bash <(curl -fsSL https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main/install.sh)

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

# 检查系统
if [[ ! -f /etc/freebsd-update.conf ]]; then
    red "错误：此脚本仅支持FreeBSD系统"
    exit 1
fi

green "检测到FreeBSD系统，开始安装..."

# 下载主脚本
SCRIPT_DIR="$HOME/.freebsd-proxy"
mkdir -p "$SCRIPT_DIR"

green "正在下载主脚本..."
if curl -fsSL -o "$SCRIPT_DIR/freebsd-proxy.sh" "https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main/freebsd-proxy.sh"; then
    chmod +x "$SCRIPT_DIR/freebsd-proxy.sh"
    green "主脚本下载完成"
else
    red "主脚本下载失败"
    exit 1
fi

# 创建快捷命令
if [[ -d "$HOME/bin" ]] || mkdir -p "$HOME/bin" 2>/dev/null; then
    cat > "$HOME/bin/freebsd-proxy" << 'EOF'
#!/bin/bash
exec "$HOME/.freebsd-proxy/freebsd-proxy.sh" "$@"
EOF
    chmod +x "$HOME/bin/freebsd-proxy"
    
    # 添加到PATH
    if ! echo "$PATH" | grep -q "$HOME/bin"; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
        export PATH="$HOME/bin:$PATH"
    fi
    
    green "快捷命令已创建：freebsd-proxy"
fi

echo
blue "=== 安装完成 ==="
green "使用方法："
echo "  1. 运行管理面板：$SCRIPT_DIR/freebsd-proxy.sh"
echo "  2. 或使用快捷命令：freebsd-proxy"
echo "  3. 一键安装：$SCRIPT_DIR/freebsd-proxy.sh install"
echo
green "现在开始自动安装服务..."
echo

# 自动执行安装
"$SCRIPT_DIR/freebsd-proxy.sh" install