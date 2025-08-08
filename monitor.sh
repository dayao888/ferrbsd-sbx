#!/bin/bash

# FreeBSD科学上网服务监控脚本
# 用于监控服务状态、性能和自动恢复

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

# 配置
WORKDIR="$HOME/.freebsd-proxy"
MONITOR_DIR="$WORKDIR/monitor"
LOG_FILE="$MONITOR_DIR/monitor.log"
STATS_FILE="$MONITOR_DIR/stats.json"
ALERT_FILE="$MONITOR_DIR/alerts.log"
PID_FILE="$WORKDIR/sing-box.pid"
CONFIG_FILE="$WORKDIR/config.json"
SING_BOX_BIN="$WORKDIR/sing-box"

# 监控配置
CHECK_INTERVAL=60        # 检查间隔（秒）
RESTART_THRESHOLD=3      # 连续失败次数阈值
CPU_THRESHOLD=80         # CPU使用率阈值（%）
MEMORY_THRESHOLD=80      # 内存使用率阈值（%）
DISK_THRESHOLD=90        # 磁盘使用率阈值（%）
CONN_THRESHOLD=1000      # 连接数阈值

# 初始化
init_monitor() {
    mkdir -p "$MONITOR_DIR"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
    fi
    
    if [[ ! -f "$STATS_FILE" ]]; then
        echo '{}' > "$STATS_FILE"
    fi
}

# 记录日志
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        ERROR) red "[$timestamp] [ERROR] $message" ;;
        WARN) yellow "[$timestamp] [WARN] $message" ;;
        INFO) green "[$timestamp] [INFO] $message" ;;
        DEBUG) blue "[$timestamp] [DEBUG] $message" ;;
    esac
}

# 发送告警
send_alert() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$ALERT_FILE"
    log_message "$level" "ALERT: $message"
    
    # 这里可以添加邮件、webhook等通知方式
    # send_email_alert "$level" "$message"
    # send_webhook_alert "$level" "$message"
}

# 检查服务状态
check_service_status() {
    if [[ ! -f "$PID_FILE" ]]; then
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    
    return 0
}

# 检查端口监听
check_ports() {
    local ports=()
    
    if [[ -f "$WORKDIR/vless_port.txt" ]]; then
        ports+=($(cat "$WORKDIR/vless_port.txt"))
    fi
    if [[ -f "$WORKDIR/vmess_port.txt" ]]; then
        ports+=($(cat "$WORKDIR/vmess_port.txt"))
    fi
    if [[ -f "$WORKDIR/hy2_port.txt" ]]; then
        ports+=($(cat "$WORKDIR/hy2_port.txt"))
    fi
    
    for port in "${ports[@]}"; do
        if ! netstat -an | grep -q ":$port.*LISTEN"; then
            log_message "ERROR" "端口 $port 未监听"
            return 1
        fi
    done
    
    return 0
}

# 获取系统资源使用情况
get_system_stats() {
    local cpu_usage=$(top -n 1 | grep "CPU:" | awk '{print $2}' | sed 's/%//')
    local memory_info=$(top -n 1 | grep "Mem:")
    local memory_used=$(echo "$memory_info" | awk '{print $2}' | sed 's/[^0-9]//g')
    local memory_total=$(echo "$memory_info" | awk '{print $4}' | sed 's/[^0-9]//g')
    local memory_usage=$((memory_used * 100 / memory_total))
    
    local disk_usage=$(df -h "$WORKDIR" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    echo "$cpu_usage,$memory_usage,$disk_usage"
}

# 获取进程资源使用情况
get_process_stats() {
    if ! check_service_status; then
        echo "0,0,0"
        return
    fi
    
    local pid=$(cat "$PID_FILE")
    local process_info=$(ps -o pid,pcpu,pmem,vsz,rss -p "$pid" | tail -1)
    
    local cpu_usage=$(echo "$process_info" | awk '{print $2}')
    local memory_usage=$(echo "$process_info" | awk '{print $3}')
    local memory_kb=$(echo "$process_info" | awk '{print $5}')
    
    echo "$cpu_usage,$memory_usage,$memory_kb"
}

# 获取网络连接数
get_connection_count() {
    local ports=()
    
    if [[ -f "$WORKDIR/vless_port.txt" ]]; then
        ports+=($(cat "$WORKDIR/vless_port.txt"))
    fi
    if [[ -f "$WORKDIR/vmess_port.txt" ]]; then
        ports+=($(cat "$WORKDIR/vmess_port.txt"))
    fi
    if [[ -f "$WORKDIR/hy2_port.txt" ]]; then
        ports+=($(cat "$WORKDIR/hy2_port.txt"))
    fi
    
    local total_connections=0
    for port in "${ports[@]}"; do
        local connections=$(netstat -an | grep ":$port" | wc -l)
        total_connections=$((total_connections + connections))
    done
    
    echo "$total_connections"
}

# 更新统计信息
update_stats() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local system_stats=$(get_system_stats)
    local process_stats=$(get_process_stats)
    local connections=$(get_connection_count)
    
    local cpu_sys=$(echo "$system_stats" | cut -d',' -f1)
    local mem_sys=$(echo "$system_stats" | cut -d',' -f2)
    local disk_usage=$(echo "$system_stats" | cut -d',' -f3)
    
    local cpu_proc=$(echo "$process_stats" | cut -d',' -f1)
    local mem_proc=$(echo "$process_stats" | cut -d',' -f2)
    local mem_kb=$(echo "$process_stats" | cut -d',' -f3)
    
    # 创建JSON统计信息
    cat > "$STATS_FILE" << EOF
{
  "timestamp": "$timestamp",
  "service_status": $(check_service_status && echo "true" || echo "false"),
  "system": {
    "cpu_usage": $cpu_sys,
    "memory_usage": $mem_sys,
    "disk_usage": $disk_usage
  },
  "process": {
    "cpu_usage": $cpu_proc,
    "memory_usage": $mem_proc,
    "memory_kb": $mem_kb
  },
  "network": {
    "connections": $connections
  }
}
EOF
    
    # 检查阈值并发送告警
    if [[ "$cpu_sys" -gt "$CPU_THRESHOLD" ]]; then
        send_alert "WARN" "系统CPU使用率过高: ${cpu_sys}%"
    fi
    
    if [[ "$mem_sys" -gt "$MEMORY_THRESHOLD" ]]; then
        send_alert "WARN" "系统内存使用率过高: ${mem_sys}%"
    fi
    
    if [[ "$disk_usage" -gt "$DISK_THRESHOLD" ]]; then
        send_alert "WARN" "磁盘使用率过高: ${disk_usage}%"
    fi
    
    if [[ "$connections" -gt "$CONN_THRESHOLD" ]]; then
        send_alert "WARN" "连接数过多: $connections"
    fi
}

# 重启服务
restart_service() {
    log_message "INFO" "正在重启服务..."
    
    if [[ -f "$WORKDIR/freebsd-proxy.sh" ]]; then
        "$WORKDIR/freebsd-proxy.sh" restart
    elif [[ -f "$WORKDIR/freebsd-proxy-enhanced.sh" ]]; then
        "$WORKDIR/freebsd-proxy-enhanced.sh" restart
    else
        log_message "ERROR" "找不到管理脚本"
        return 1
    fi
    
    sleep 5
    
    if check_service_status; then
        log_message "INFO" "服务重启成功"
        send_alert "INFO" "服务已自动重启"
        return 0
    else
        log_message "ERROR" "服务重启失败"
        send_alert "ERROR" "服务重启失败"
        return 1
    fi
}

# 主监控循环
monitor_loop() {
    local failure_count=0
    
    log_message "INFO" "监控服务启动"
    
    while true; do
        # 检查服务状态
        if check_service_status && check_ports; then
            if [[ "$failure_count" -gt 0 ]]; then
                log_message "INFO" "服务恢复正常"
                failure_count=0
            fi
        else
            failure_count=$((failure_count + 1))
            log_message "ERROR" "服务检查失败 ($failure_count/$RESTART_THRESHOLD)"
            
            if [[ "$failure_count" -ge "$RESTART_THRESHOLD" ]]; then
                send_alert "ERROR" "服务连续失败 $failure_count 次，尝试重启"
                
                if restart_service; then
                    failure_count=0
                else
                    send_alert "CRITICAL" "服务重启失败，需要人工干预"
                fi
            fi
        fi
        
        # 更新统计信息
        update_stats
        
        # 等待下次检查
        sleep "$CHECK_INTERVAL"
    done
}

# 显示实时状态
show_realtime_status() {
    while true; do
        clear
        echo
        blue "=== FreeBSD科学上网服务监控 ==="
        echo "更新时间: $(date)"
        echo
        
        # 服务状态
        if check_service_status; then
            green "服务状态: 运行中"
        else
            red "服务状态: 未运行"
        fi
        
        # 端口状态
        echo
        blue "端口状态:"
        if [[ -f "$WORKDIR/vless_port.txt" ]]; then
            local vless_port=$(cat "$WORKDIR/vless_port.txt")
            if netstat -an | grep -q ":$vless_port.*LISTEN"; then
                green "  VLESS ($vless_port): 监听中"
            else
                red "  VLESS ($vless_port): 未监听"
            fi
        fi
        
        if [[ -f "$WORKDIR/vmess_port.txt" ]]; then
            local vmess_port=$(cat "$WORKDIR/vmess_port.txt")
            if netstat -an | grep -q ":$vmess_port.*LISTEN"; then
                green "  VMess ($vmess_port): 监听中"
            else
                red "  VMess ($vmess_port): 未监听"
            fi
        fi
        
        if [[ -f "$WORKDIR/hy2_port.txt" ]]; then
            local hy2_port=$(cat "$WORKDIR/hy2_port.txt")
            if netstat -an | grep -q ":$hy2_port.*LISTEN"; then
                green "  Hysteria2 ($hy2_port): 监听中"
            else
                red "  Hysteria2 ($hy2_port): 未监听"
            fi
        fi
        
        # 系统资源
        echo
        blue "系统资源:"
        local system_stats=$(get_system_stats)
        local cpu_usage=$(echo "$system_stats" | cut -d',' -f1)
        local mem_usage=$(echo "$system_stats" | cut -d',' -f2)
        local disk_usage=$(echo "$system_stats" | cut -d',' -f3)
        
        echo "  CPU使用率: ${cpu_usage}%"
        echo "  内存使用率: ${mem_usage}%"
        echo "  磁盘使用率: ${disk_usage}%"
        
        # 进程资源
        if check_service_status; then
            echo
            blue "进程资源:"
            local process_stats=$(get_process_stats)
            local proc_cpu=$(echo "$process_stats" | cut -d',' -f1)
            local proc_mem=$(echo "$process_stats" | cut -d',' -f2)
            local proc_mem_kb=$(echo "$process_stats" | cut -d',' -f3)
            
            echo "  进程CPU: ${proc_cpu}%"
            echo "  进程内存: ${proc_mem}%"
            echo "  内存使用: ${proc_mem_kb}KB"
        fi
        
        # 网络连接
        echo
        blue "网络连接:"
        local connections=$(get_connection_count)
        echo "  总连接数: $connections"
        
        echo
        yellow "按 Ctrl+C 退出监控"
        
        sleep 5
    done
}

# 显示统计报告
show_stats_report() {
    if [[ ! -f "$STATS_FILE" ]]; then
        red "统计文件不存在"
        return 1
    fi
    
    echo
    blue "=== 统计报告 ==="
    
    # 显示当前统计信息
    if command -v jq >/dev/null 2>&1; then
        echo
        green "当前状态:"
        jq . "$STATS_FILE"
    else
        echo
        green "当前状态:"
        cat "$STATS_FILE"
    fi
    
    # 显示日志摘要
    if [[ -f "$LOG_FILE" ]]; then
        echo
        green "最近日志 (最后10条):"
        tail -10 "$LOG_FILE"
    fi
    
    # 显示告警信息
    if [[ -f "$ALERT_FILE" ]]; then
        echo
        yellow "最近告警 (最后5条):"
        tail -5 "$ALERT_FILE"
    fi
}

# 清理日志
cleanup_logs() {
    local days=${1:-7}
    
    green "清理 $days 天前的日志..."
    
    # 清理监控日志
    if [[ -f "$LOG_FILE" ]]; then
        local temp_file=$(mktemp)
        tail -1000 "$LOG_FILE" > "$temp_file"
        mv "$temp_file" "$LOG_FILE"
    fi
    
    # 清理告警日志
    if [[ -f "$ALERT_FILE" ]]; then
        local temp_file=$(mktemp)
        tail -500 "$ALERT_FILE" > "$temp_file"
        mv "$temp_file" "$ALERT_FILE"
    fi
    
    green "日志清理完成"
}

# 显示帮助
show_help() {
    echo
    blue "FreeBSD科学上网服务监控脚本"
    echo
    green "使用方法:"
    echo "  $0 start                # 启动监控服务"
    echo "  $0 status               # 显示实时状态"
    echo "  $0 stats                # 显示统计报告"
    echo "  $0 check                # 单次检查"
    echo "  $0 restart-service      # 重启被监控的服务"
    echo "  $0 cleanup [days]       # 清理日志（默认7天）"
    echo "  $0 help                 # 显示帮助"
    echo
}

# 主程序
init_monitor

case "${1:-help}" in
    start)
        monitor_loop
        ;;
    status)
        show_realtime_status
        ;;
    stats)
        show_stats_report
        ;;
    check)
        if check_service_status && check_ports; then
            green "服务状态正常"
            update_stats
        else
            red "服务状态异常"
            exit 1
        fi
        ;;
    restart-service)
        restart_service
        ;;
    cleanup)
        cleanup_logs "$2"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        red "无效参数: $1"
        show_help
        exit 1
        ;;
esac