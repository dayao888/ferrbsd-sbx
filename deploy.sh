#!/bin/bash

# FreeBSD科学上网脚本部署工具
# 用于快速部署到远程FreeBSD服务器

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
readp(){ read -p "$(yellow "$1")" $2;}

# GitHub仓库配置
GITHUB_REPO="https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main"
SCRIPT_FILES=(
    "freebsd-proxy.sh"
    "freebsd-proxy-enhanced.sh"
    "install.sh"
)

# 显示帮助信息
show_help() {
    echo
    blue "FreeBSD科学上网脚本部署工具"
    echo
    green "使用方法："
    echo "  $0 local                    # 本地部署"
    echo "  $0 remote <user@host>       # 远程部署"
    echo "  $0 download                 # 仅下载脚本"
    echo "  $0 check <user@host>        # 检查远程环境"
    echo
    green "示例："
    echo "  $0 remote user@192.168.1.100"
    echo "  $0 local"
    echo
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "ssh" "scp")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        red "缺少依赖：${missing_deps[*]}"
        exit 1
    fi
}

# 下载脚本文件
download_scripts() {
    local target_dir="$1"
    
    green "正在下载脚本文件到：$target_dir"
    
    mkdir -p "$target_dir"
    
    for script in "${SCRIPT_FILES[@]}"; do
        local url="$GITHUB_REPO/$script"
        green "下载：$script"
        
        if curl -fsSL -o "$target_dir/$script" "$url"; then
            chmod +x "$target_dir/$script"
            green "✓ $script 下载成功"
        else
            red "✗ $script 下载失败"
            return 1
        fi
    done
    
    green "所有脚本下载完成"
}

# 检查远程环境
check_remote_environment() {
    local remote_host="$1"
    
    green "检查远程环境：$remote_host"
    
    # 检查SSH连接
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$remote_host" "echo 'SSH连接正常'" 2>/dev/null; then
        red "SSH连接失败，请检查："
        echo "1. 主机地址是否正确"
        echo "2. SSH密钥是否配置"
        echo "3. 网络连接是否正常"
        return 1
    fi
    
    # 检查系统类型
    local os_info=$(ssh "$remote_host" "uname -s" 2>/dev/null)
    if [[ "$os_info" != "FreeBSD" ]]; then
        red "远程系统不是FreeBSD：$os_info"
        return 1
    fi
    
    # 检查系统版本
    local version=$(ssh "$remote_host" "freebsd-version" 2>/dev/null)
    green "远程系统：FreeBSD $version"
    
    # 检查架构
    local arch=$(ssh "$remote_host" "uname -m" 2>/dev/null)
    green "系统架构：$arch"
    
    # 检查依赖
    green "检查依赖..."
    local deps=("curl" "openssl")
    for dep in "${deps[@]}"; do
        if ssh "$remote_host" "command -v $dep >/dev/null 2>&1"; then
            green "✓ $dep 已安装"
        else
            yellow "✗ $dep 未安装"
        fi
    done
    
    # 检查端口
    green "检查端口占用..."
    local ports=(28332 38533 38786)
    for port in "${ports[@]}"; do
        if ssh "$remote_host" "netstat -an | grep -q :$port"; then
            yellow "⚠ 端口 $port 已被占用"
        else
            green "✓ 端口 $port 可用"
        fi
    done
    
    green "远程环境检查完成"
}

# 本地部署
deploy_local() {
    green "开始本地部署..."
    
    # 检查系统
    if [[ ! -f /etc/freebsd-update.conf ]]; then
        red "错误：此脚本仅支持FreeBSD系统"
        exit 1
    fi
    
    local work_dir="$HOME/.freebsd-proxy-deploy"
    
    # 下载脚本
    if ! download_scripts "$work_dir"; then
        red "脚本下载失败"
        exit 1
    fi
    
    # 创建快捷方式
    if [[ -d "$HOME/bin" ]] || mkdir -p "$HOME/bin" 2>/dev/null; then
        ln -sf "$work_dir/freebsd-proxy.sh" "$HOME/bin/freebsd-proxy"
        ln -sf "$work_dir/freebsd-proxy-enhanced.sh" "$HOME/bin/freebsd-proxy-enhanced"
        green "快捷命令已创建"
    fi
    
    echo
    green "=== 本地部署完成 ==="
    echo "脚本位置：$work_dir"
    echo "基础版本：$work_dir/freebsd-proxy.sh"
    echo "增强版本：$work_dir/freebsd-proxy-enhanced.sh"
    echo "快捷命令：freebsd-proxy 或 freebsd-proxy-enhanced"
    echo
    
    readp "是否立即安装服务？(Y/n): " install_now
    if [[ "$install_now" != "n" && "$install_now" != "N" ]]; then
        "$work_dir/freebsd-proxy-enhanced.sh" install
    fi
}

# 远程部署
deploy_remote() {
    local remote_host="$1"
    
    if [[ -z "$remote_host" ]]; then
        red "请指定远程主机地址"
        show_help
        exit 1
    fi
    
    green "开始远程部署到：$remote_host"
    
    # 检查远程环境
    if ! check_remote_environment "$remote_host"; then
        red "远程环境检查失败"
        exit 1
    fi
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    local remote_dir=".freebsd-proxy-deploy"
    
    # 下载脚本到临时目录
    if ! download_scripts "$temp_dir"; then
        red "脚本下载失败"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # 上传脚本到远程主机
    green "上传脚本到远程主机..."
    if ssh "$remote_host" "mkdir -p $remote_dir"; then
        if scp "$temp_dir"/* "$remote_host:$remote_dir/"; then
            green "脚本上传成功"
        else
            red "脚本上传失败"
            rm -rf "$temp_dir"
            exit 1
        fi
    else
        red "无法在远程主机创建目录"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # 设置执行权限
    ssh "$remote_host" "chmod +x $remote_dir/*.sh"
    
    # 创建快捷命令
    ssh "$remote_host" "mkdir -p bin && ln -sf $remote_dir/freebsd-proxy.sh bin/freebsd-proxy && ln -sf $remote_dir/freebsd-proxy-enhanced.sh bin/freebsd-proxy-enhanced"
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    echo
    green "=== 远程部署完成 ==="
    echo "远程主机：$remote_host"
    echo "脚本位置：~/$remote_dir"
    echo "快捷命令：freebsd-proxy 或 freebsd-proxy-enhanced"
    echo
    
    readp "是否立即在远程主机安装服务？(Y/n): " install_now
    if [[ "$install_now" != "n" && "$install_now" != "N" ]]; then
        green "正在远程安装..."
        ssh -t "$remote_host" "$remote_dir/freebsd-proxy-enhanced.sh install"
    fi
    
    echo
    green "连接到远程主机进行管理："
    echo "ssh $remote_host"
    echo "freebsd-proxy-enhanced"
}

# 仅下载脚本
download_only() {
    local target_dir="./freebsd-proxy-scripts"
    
    readp "下载目录 [$target_dir]: " custom_dir
    if [[ -n "$custom_dir" ]]; then
        target_dir="$custom_dir"
    fi
    
    if ! download_scripts "$target_dir"; then
        red "下载失败"
        exit 1
    fi
    
    echo
    green "=== 下载完成 ==="
    echo "脚本位置：$target_dir"
    echo "使用方法："
    echo "  cd $target_dir"
    echo "  ./freebsd-proxy.sh install"
    echo "  或"
    echo "  ./freebsd-proxy-enhanced.sh install"
}

# 批量部署
batch_deploy() {
    local hosts_file="$1"
    
    if [[ ! -f "$hosts_file" ]]; then
        red "主机列表文件不存在：$hosts_file"
        exit 1
    fi
    
    green "开始批量部署..."
    
    local success_count=0
    local total_count=0
    
    while IFS= read -r host; do
        # 跳过空行和注释
        [[ -z "$host" || "$host" =~ ^#.*$ ]] && continue
        
        total_count=$((total_count + 1))
        
        echo
        blue "=== 部署到：$host ==="
        
        if deploy_remote "$host"; then
            success_count=$((success_count + 1))
            green "✓ $host 部署成功"
        else
            red "✗ $host 部署失败"
        fi
    done < "$hosts_file"
    
    echo
    blue "=== 批量部署完成 ==="
    green "成功：$success_count/$total_count"
}

# 主程序
case "$1" in
    local)
        check_dependencies
        deploy_local
        ;;
    remote)
        check_dependencies
        deploy_remote "$2"
        ;;
    download)
        check_dependencies
        download_only
        ;;
    check)
        check_dependencies
        check_remote_environment "$2"
        ;;
    batch)
        check_dependencies
        batch_deploy "$2"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        red "无效参数：$1"
        show_help
        exit 1
        ;;
esac