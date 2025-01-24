#!/bin/bash

# ========================
# 常量定义
# ========================
declare -A SYSCTL_SETTINGS=(
    ["net.ipv4.tcp_rmem"]="4096 87380 6291456"
    ["net.ipv4.tcp_wmem"]="4096 87380 6291456"
    ["net.core.rmem_max"]=16777216
    ["net.core.wmem_max"]=16777216
    ["net.ipv4.tcp_fin_timeout"]=30
    ["net.ipv4.tcp_tw_reuse"]=1
)

PERSISTENT_CONF=(
    "net.core.default_qdisc=fq"
    "net.ipv4.tcp_congestion_control=bbr"
)

# ========================
# 工具函数
# ========================
die() {
    echo -e "\033[31m错误：$*\033[0m" >&2
    exit 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || die "未找到必需命令：$1"
}

check_root() {
    [ "$(id -u)" -eq 0 ] || die "该脚本必须以 root 用户运行"
}

validate_setting() {
    local actual=$(sysctl -n "$1" 2>/dev/null | tr -d '\t ')
    local expected="${2//[[:space:]]/}"
    
    [[ "$actual" == "$expected" ]] || die "$1 设置失败 (当前值: ${actual// /, }，期望值: ${expected// /, })"
}

# ========================
# 主逻辑
# ========================
main() {
    # 预检条件验证
    check_root
    for cmd in sysctl modprobe grep; do
        check_command "$cmd"
    done

    # TCP窗口缩放检查
    local tcp_window_scaling=$(sysctl -n net.ipv4.tcp_window_scaling)
    echo "TCP窗口缩放状态：$([ "$tcp_window_scaling" -eq 1 ] && echo "已启用" || echo "未启用 (当前值: $tcp_window_scaling)")"

    # 批量设置并验证sysctl参数
    for key in "${!SYSCTL_SETTINGS[@]}"; do
        sysctl -w "$key=${SYSCTL_SETTINGS[$key]}" >/dev/null
        validate_setting "$key" "${SYSCTL_SETTINGS[$key]}"
    done

    # BBR模块处理
    if ! grep -qw '^tcp_bbr' /proc/modules; then
        echo "加载BBR模块..."
        modprobe tcp_bbr || die "BBR模块加载失败"
    else
        echo "BBR模块已加载"
    fi

    # 持久化配置
    for line in "${PERSISTENT_CONF[@]}"; do
        grep -qF "$line" /etc/sysctl.conf || echo "$line" >> /etc/sysctl.conf
    done
    sysctl -p >/dev/null

    echo -e "\n\033[32m所有设置已成功应用！当前关键参数：\033[0m"
    sysctl -a 2>/dev/null | grep -E 'net.ipv4.tcp_(rmem|wmem|fin_timeout|tw_reuse)|net.core.(rmem_max|wmem_max|default_qdisc)|tcp_congestion_control'
}

main "$@"
