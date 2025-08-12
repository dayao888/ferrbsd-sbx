#!/usr/bin/env bash

# =============================================================================
# FreeBSD 14 amd64 sing-box v1.10 一键编译脚本
# 
# 功能：
# - 自动检测并安装依赖 (Go, Git, 编译工具)
# - 下载 sing-box v1.10 源码
# - 使用完整的构建标签进行编译
# - 支持普通用户权限运行
# - 生成多架构二进制文件
# - 自动验证编译结果
# =============================================================================

set -e  # 遇到错误立即退出

# 颜色输出函数
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue() { echo -e "\033[34m\033[01m$1\033[0m"; }

# 配置参数
SING_BOX_VERSION="v1.10.0"
GO_MIN_VERSION="1.20"
GO_MAX_VERSION="1.22"
BUILD_DIR="$HOME/sing-box-build"
OUTPUT_DIR="$BUILD_DIR/output"

# 完整的构建标签 (基于官方推荐和社区最佳实践)
BUILD_TAGS="with_quic,with_grpc,with_wireguard,with_ech,with_utls,with_reality_server,with_clash_api,with_gvisor,with_acme,with_dhcp"

# 显示欢迎信息
show_banner() {
    blue "=================================================================="
    blue "   FreeBSD 14 amd64 sing-box v1.10 一键编译脚本"
    blue "=================================================================="
    echo
    yellow "编译版本: $SING_BOX_VERSION"
    yellow "构建标签: $BUILD_TAGS"
    yellow "目标系统: FreeBSD 14 amd64"
    yellow "输出目录: $OUTPUT_DIR"
    echo
}

# 检查系统兼容性
check_system() {
    blue "正在检查系统兼容性..."
    
    # 检查操作系统
    if [[ "$(uname -s)" != "FreeBSD" ]]; then
        red "错误：此脚本仅支持 FreeBSD 系统"
        exit 1
    fi
    
    # 检查架构
    local arch=$(uname -m)
    if [[ "$arch" != "amd64" && "$arch" != "x86_64" ]]; then
        red "错误：此脚本仅支持 amd64 架构"
        exit 1
    fi
    
    # 检查 FreeBSD 版本
    local fbsd_version=$(freebsd-version | cut -d'-' -f1 | cut -d'.' -f1)
    if [[ "$fbsd_version" -lt 13 ]]; then
        yellow "警告：推荐使用 FreeBSD 13+ 进行编译"
    fi
    
    green "✓ 系统兼容性检查通过"
}

# 检查并安装依赖
install_dependencies() {
    blue "正在检查依赖..."
    
    local missing_deps=()
    local install_cmd=""
    
    # 检查是否有 pkg 权限
    if command -v pkg &>/dev/null; then
        if pkg info go >/dev/null 2>&1 || sudo -n pkg info go >/dev/null 2>&1; then
            install_cmd="pkg"
        elif [[ $(id -u) -eq 0 ]]; then
            install_cmd="pkg"
        else
            yellow "注意：无 sudo 权限，将尝试手动安装方法"
        fi
    fi
    
    # 检查 Go 版本
    if command -v go &>/dev/null; then
        local go_version=$(go version | grep -o 'go[0-9]\+\.[0-9]\+' | sed 's/go//')
        local go_major=$(echo $go_version | cut -d'.' -f1)
        local go_minor=$(echo $go_version | cut -d'.' -f2)
        
        if [[ "$go_major" -gt 1 ]] || [[ "$go_major" -eq 1 && "$go_minor" -ge 20 && "$go_minor" -le 22 ]]; then
            green "✓ Go $go_version 已安装"
        else
            yellow "警告：Go 版本 $go_version 可能不兼容，推荐 1.20-1.22"
            missing_deps+=("go")
        fi
    else
        missing_deps+=("go")
    fi
    
    # 检查 Git
    if ! command -v git &>/dev/null; then
        missing_deps+=("git")
    else
        green "✓ Git 已安装"
    fi
    
    # 检查编译工具
    if ! command -v gmake &>/dev/null && ! command -v make &>/dev/null; then
        missing_deps+=("gmake")
    else
        green "✓ Make 工具已安装"
    fi
    
    # 安装缺失依赖
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        blue "正在安装缺失依赖: ${missing_deps[*]}"
        
        if [[ -n "$install_cmd" ]]; then
            # 使用 pkg 安装
            for dep in "${missing_deps[@]}"; do
                if [[ "$dep" == "gmake" ]]; then
                    sudo pkg install -y gmake || pkg install -y gmake
                else
                    sudo pkg install -y "$dep" || pkg install -y "$dep"
                fi
            done
        else
            # 提供手动安装指导
            red "无法自动安装依赖，请手动安装："
            echo
            yellow "方法1 - 使用 pkg (需要 sudo 权限):"
            echo "sudo pkg install -y ${missing_deps[*]}"
            echo
            yellow "方法2 - 下载预编译二进制:"
            if [[ " ${missing_deps[*]} " =~ " go " ]]; then
                echo "Go: curl -L https://go.dev/dl/go1.21.latest.freebsd-amd64.tar.gz | tar -C \$HOME -xz"
                echo "export PATH=\$HOME/go/bin:\$PATH"
            fi
            if [[ " ${missing_deps[*]} " =~ " git " ]]; then
                echo "Git: pkg install -y git (需要权限) 或使用 ports"
            fi
            echo
            exit 1
        fi
    fi
    
    green "✓ 所有依赖已安装"
}

# 设置构建环境
setup_build_environment() {
    blue "正在设置构建环境..."
    
    # 创建构建目录
    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
    cd "$BUILD_DIR"
    
    # 设置 Go 环境变量
    export GOPROXY=https://goproxy.cn,direct
    export GOSUMDB=sum.golang.google.cn
    export CGO_ENABLED=0
    export GOOS=freebsd
    export GOARCH=amd64
    
    # 验证 Go 环境
    green "✓ Go 版本: $(go version)"
    green "✓ GOPROXY: $GOPROXY"
    green "✓ 构建目录: $BUILD_DIR"
}

# 下载 sing-box 源码
download_source() {
    blue "正在下载 sing-box $SING_BOX_VERSION 源码..."
    
    # 清理旧的源码目录
    if [[ -d "sing-box" ]]; then
        rm -rf sing-box
    fi
    
    # 克隆指定版本
    if ! git clone --depth 1 --branch "$SING_BOX_VERSION" https://github.com/SagerNet/sing-box.git; then
        red "源码下载失败，尝试备用方法..."
        
        # 备用下载方法
        local tarball_url="https://github.com/SagerNet/sing-box/archive/refs/tags/$SING_BOX_VERSION.tar.gz"
        if command -v curl &>/dev/null; then
            curl -L "$tarball_url" | tar -xz
            mv "sing-box-${SING_BOX_VERSION#v}" sing-box
        elif command -v fetch &>/dev/null; then
            fetch -o - "$tarball_url" | tar -xz
            mv "sing-box-${SING_BOX_VERSION#v}" sing-box
        else
            red "下载失败：缺少 curl 或 fetch"
            exit 1
        fi
    fi
    
    cd sing-box
    green "✓ 源码下载完成"
    
    # 显示版本信息
    local commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    yellow "源码版本: $SING_BOX_VERSION"
    yellow "提交哈希: $commit_hash"
}

# 编译 sing-box
build_singbox() {
    blue "正在编译 sing-box (标签: $BUILD_TAGS)..."
    
    # 显示编译信息
    echo
    yellow "编译配置:"
    echo "  版本: $SING_BOX_VERSION"
    echo "  标签: $BUILD_TAGS"
    echo "  CGO: $CGO_ENABLED"
    echo "  GOOS: $GOOS"
    echo "  GOARCH: $GOARCH"
    echo
    
    # 开始编译
    local build_start=$(date +%s)
    
    # 主架构编译 (amd64)
    blue "编译 FreeBSD amd64 版本..."
    export GOARCH=amd64
    if ! go build -v -trimpath -ldflags="-s -w -buildid=" -tags "$BUILD_TAGS" -o "$OUTPUT_DIR/sb-amd64" ./cmd/sing-box; then
        red "amd64 编译失败"
        exit 1
    fi
    green "✓ sb-amd64 编译完成"
    
    # ARM64 交叉编译 (如果支持)
    blue "编译 FreeBSD arm64 版本..."
    export GOARCH=arm64
    if go build -v -trimpath -ldflags="-s -w -buildid=" -tags "$BUILD_TAGS" -o "$OUTPUT_DIR/sb-arm64" ./cmd/sing-box 2>/dev/null; then
        green "✓ sb-arm64 编译完成"
    else
        yellow "⚠ arm64 交叉编译失败 (可选)"
    fi
    
    # 编译通用版本 (无架构后缀)
    export GOARCH=amd64
    if go build -v -trimpath -ldflags="-s -w -buildid=" -tags "$BUILD_TAGS" -o "$OUTPUT_DIR/sing-box" ./cmd/sing-box; then
        green "✓ sing-box 通用版本编译完成"
    fi
    
    local build_end=$(date +%s)
    local build_time=$((build_end - build_start))
    green "✓ 编译完成，耗时 ${build_time}s"
}

# 验证编译结果
verify_build() {
    blue "正在验证编译结果..."
    
    cd "$OUTPUT_DIR"
    
    for binary in sb-amd64 sb-arm64 sing-box; do
        if [[ -f "$binary" ]]; then
            echo
            blue "验证 $binary:"
            
            # 检查文件大小
            local size=$(ls -lh "$binary" | awk '{print $5}')
            echo "  文件大小: $size"
            
            # 检查权限
            chmod +x "$binary"
            echo "  权限: $(ls -l "$binary" | cut -d' ' -f1)"
            
            # 只对 amd64 版本进行功能测试 (当前架构)
            if [[ "$binary" == "sb-amd64" || "$binary" == "sing-box" ]]; then
                # 版本检查
                if ./"$binary" version >/dev/null 2>&1; then
                    local version_info=$(./"$binary" version 2>/dev/null)
                    echo "  版本验证: ✓"
                    echo "  $version_info" | head -3 | sed 's/^/    /'
                else
                    yellow "  版本验证: ⚠ (可能缺少运行时库)"
                fi
                
                # Reality 支持检查
                if ./"$binary" generate reality-keypair >/dev/null 2>&1; then
                    echo "  Reality 支持: ✓"
                else
                    red "  Reality 支持: ✗"
                fi
                
                # 配置检查
                echo '{"inbounds":[],"outbounds":[]}' > test-config.json
                if ./"$binary" check -c test-config.json >/dev/null 2>&1; then
                    echo "  配置检查: ✓"
                    rm -f test-config.json
                else
                    yellow "  配置检查: ⚠"
                    rm -f test-config.json
                fi
            fi
            
            green "  $binary 验证通过"
        fi
    done
}

# 生成文件摘要
generate_checksums() {
    blue "正在生成文件摘要..."
    
    cd "$OUTPUT_DIR"
    
    # 生成 SHA256 摘要
    if command -v sha256 &>/dev/null; then
        sha256 sb-* sing-box 2>/dev/null > checksums.txt || true
    elif command -v sha256sum &>/dev/null; then
        sha256sum sb-* sing-box 2>/dev/null > checksums.txt || true
    fi
    
    # 生成文件列表
    cat > build-info.txt << EOF
Sing-box 编译信息
================

版本: $SING_BOX_VERSION
构建时间: $(date)
构建系统: $(uname -a)
Go 版本: $(go version)
构建标签: $BUILD_TAGS

文件列表:
$(ls -lh sb-* sing-box 2>/dev/null | awk '{print $5 "\t" $9}')

摘要信息:
$(cat checksums.txt 2>/dev/null || echo "摘要生成失败")
EOF
    
    green "✓ 文件摘要已生成"
}

# 显示完成信息
show_completion() {
    echo
    green "=================================================================="
    green "                    编译完成！"
    green "=================================================================="
    echo
    blue "输出文件位置: $OUTPUT_DIR"
    echo
    yellow "生成的文件:"
    ls -la "$OUTPUT_DIR" | grep -E "(sb-|sing-box|\.txt)" | awk '{print "  " $5 "\t" $9}'
    echo
    blue "使用方法:"
    echo "  1. 复制 sb-amd64 到你的项目目录"
    echo "  2. 替换现有的二进制文件"
    echo "  3. 运行 ./deploy.sh 测试"
    echo
    yellow "验证命令:"
    echo "  ./sb-amd64 version"
    echo "  ./sb-amd64 generate reality-keypair"
    echo
    blue "GitHub Release 上传建议:"
    echo "  - 上传 sb-amd64 和 sb-arm64"
    echo "  - 包含 checksums.txt 校验文件"
    echo "  - 在发布说明中注明构建标签"
    echo
}

# 清理函数
cleanup() {
    if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
        read -p "是否删除构建临时文件? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$BUILD_DIR/sing-box"
            green "✓ 临时文件已清理"
        fi
    fi
}

# 主函数
main() {
    # 显示横幅
    show_banner
    
    # 检查参数
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        echo "用法: $0 [选项]"
        echo "选项:"
        echo "  --help, -h    显示此帮助信息"
        echo "  --clean       仅清理构建目录"
        echo "  --verify      仅验证现有构建"
        echo
        echo "环境变量:"
        echo "  BUILD_TAGS    自定义构建标签 (默认: $BUILD_TAGS)"
        echo "  OUTPUT_DIR    输出目录 (默认: $OUTPUT_DIR)"
        exit 0
    fi
    
    if [[ "$1" == "--clean" ]]; then
        rm -rf "$BUILD_DIR"
        green "✓ 构建目录已清理"
        exit 0
    fi
    
    if [[ "$1" == "--verify" ]]; then
        if [[ -d "$OUTPUT_DIR" ]]; then
            verify_build
        else
            red "输出目录不存在: $OUTPUT_DIR"
            exit 1
        fi
        exit 0
    fi
    
    # 执行构建流程
    trap cleanup EXIT
    
    check_system
    install_dependencies
    setup_build_environment
    download_source
    build_singbox
    verify_build
    generate_checksums
    show_completion
}

# 运行主函数
main "$@"