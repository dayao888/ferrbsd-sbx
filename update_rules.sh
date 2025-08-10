#!/usr/bin/env bash

# =============================================================================
# FreeBSD Geosite/GeoIP规则更新工具
# 
# 功能：下载最新的地理位置规则数据
# =============================================================================

# Color functions
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }

# Rule URLs from MetaCubeX repository
GEOIP_CN_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs"
GEOSITE_CN_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs"
GEOSITE_NOT_CN_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs"

# Create rules directory
mkdir -p rules

# Download function
download_rule() {
    local url="$1"
    local filename="$2"
    local description="$3"
    
    blue "正在下载 $description..."
    
    local success=0
    if command -v fetch >/dev/null 2>&1; then
        if fetch -o "rules/$filename" "$url"; then
            success=1
        fi
    fi
    
    if [[ $success -eq 0 ]] && command -v curl >/dev/null 2>&1; then
        if curl -L -o "rules/$filename" "$url"; then
            success=1
        fi
    fi
    
    if [[ $success -eq 1 && -f "rules/$filename" && -s "rules/$filename" ]]; then
        green "✓ $description 下载完成"
        return 0
    else
        red "✗ $description 下载失败"
        return 1
    fi
}

# Main update function
update_rules() {
    blue "======================== 规则更新开始 ========================"
    echo
    
    local total=0
    local success=0
    
    # Download GeoIP CN rules
    total=$((total + 1))
    if download_rule "$GEOIP_CN_URL" "geoip-cn.srs" "GeoIP中国规则"; then
        success=$((success + 1))
    fi
    
    # Download GeoSite CN rules
    total=$((total + 1))
    if download_rule "$GEOSITE_CN_URL" "geosite-cn.srs" "GeoSite中国规则"; then
        success=$((success + 1))
    fi
    
    # Download GeoSite Non-CN rules
    total=$((total + 1))
    if download_rule "$GEOSITE_NOT_CN_URL" "geosite-geolocation-!cn.srs" "GeoSite海外规则"; then
        success=$((success + 1))
    fi
    
    echo
    if [[ $success -eq $total ]]; then
        green "======================== 规则更新完成 ========================"
        green "所有规则文件已下载到 rules/ 目录"
    else
        yellow "======================== 规则更新完成 ========================"
        yellow "成功: $success/$total 个规则文件"
        yellow "部分规则下载失败，但不影响已有规则使用"
    fi
    
    echo
    green "规则文件列表:"
    if [[ -f "rules/geoip-cn.srs" ]]; then
        echo "  ✓ rules/geoip-cn.srs"
    fi
    if [[ -f "rules/geosite-cn.srs" ]]; then
        echo "  ✓ rules/geosite-cn.srs"
    fi
    if [[ -f "rules/geosite-geolocation-!cn.srs" ]]; then
        echo "  ✓ rules/geosite-geolocation-!cn.srs"
    fi
    
    echo
    yellow "注意：规则文件会在sing-box运行时自动使用，无需重启服务"
}

# Main function
main() {
    clear
    blue "FreeBSD GeoSite/GeoIP 规则更新工具"
    echo
    
    update_rules
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi