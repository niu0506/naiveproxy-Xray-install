#!/bin/bash

# 函数：检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查脚本是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "该脚本必须以 root 用户运行。" >&2
    exit 1
fi

# 检查是否安装了必需的命令
for cmd in sysctl modprobe grep tr; do
    if ! command_exists "$cmd"; then
        echo "错误：$cmd 是必需的但未安装。" >&2
        exit 1
    fi
done

# 检查当前 TCP 窗口缩放设置
current_value=$(sysctl -n net.ipv4.tcp_window_scaling)

if [ "$current_value" -eq 1 ]; then
    echo "TCP 窗口缩放已启用。"
else
    echo "TCP 窗口缩放未启用。当前值为：$current_value"
fi

# 设置 TCP 接收和发送缓冲区大小
sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456"
sysctl -w net.ipv4.tcp_wmem="4096 87380 6291456"

# 检查并验证 TCP 接收缓冲区大小
current_rmem=$(sysctl -n net.ipv4.tcp_rmem | tr -d ' ')
expected_rmem="4096 87380 6291456"

if [ "$current_rmem" != "$expected_rmem" ]; then
    echo "错误：TCP 接收缓冲区大小设置不正确。当前值为：$current_rmem"
    exit 1
fi

# 检查并验证 TCP 发送缓冲区大小
current_wmem=$(sysctl -n net.ipv4.tcp_wmem | tr -d ' ')
expected_wmem="4096 87380 6291456"

if [ "$current_wmem" != "$expected_wmem" ]; then
    echo "错误：TCP 发送缓冲区大小设置不正确。当前值为：$current_wmem"
    exit 1
fi

echo "TCP 接收和发送缓冲区大小设置成功。"

# 设置所有套接字的最大接收和发送缓冲区大小
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# 检查并验证最大接收缓冲区大小
current_rmem_max=$(sysctl -n net.core.rmem_max)
expected_rmem_max=16777216

if [ "$current_rmem_max" -ne "$expected_rmem_max" ]; then
    echo "错误：最大接收缓冲区大小设置不正确。当前值为：$current_rmem_max"
    exit 1
fi

# 检查并验证最大发送缓冲区大小
current_wmem_max=$(sysctl -n net.core.wmem_max)
expected_wmem_max=16777216

if [ "$current_wmem_max" -ne "$expected_wmem_max" ]; then
    echo "错误：最大发送缓冲区大小设置不正确。当前值为：$current_wmem_max"
    exit 1
fi

echo "所有套接字的最大缓冲区大小设置成功。"

# 配置 TCP 设置
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_tw_reuse=1

# 检查并验证 FIN 超时时间
current_fin_timeout=$(sysctl -n net.ipv4.tcp_fin_timeout)
expected_fin_timeout=30

if [ "$current_fin_timeout" -ne "$expected_fin_timeout" ]; then
    echo "错误：TCP FIN 超时时间设置不正确。当前值为：$current_fin_timeout"
    exit 1
fi

# 检查并验证 TIME-WAIT 状态重用设置
current_tw_reuse=$(sysctl -n net.ipv4.tcp_tw_reuse)
expected_tw_reuse=1

if [ "$current_tw_reuse" -ne "$expected_tw_reuse" ]; then
    echo "错误：TCP TIME-WAIT 状态重用设置不正确。当前值为：$current_tw_reuse"
    exit 1
fi

echo "TCP 设置成功应用。"

# 检查 BBR 模块是否已加载
if ! lsmod | grep -q '^tcp_bbr '; then
    echo "加载 BBR 模块..."
    if ! modprobe tcp_bbr; then
        echo "错误：加载 BBR 模块失败。" >&2
        exit 1
    fi
else
    echo "BBR 模块已加载。"
fi

# 更新 sysctl 配置文件
grep -qxF 'net.core.default_qdisc=fq' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf

# 应用更改
sysctl -p

# 打印当前的 sysctl 设置以进行调试
echo "当前的 sysctl 设置："
sysctl -a | grep -E 'net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|net.core.rmem_max|net.core.wmem_max|net.ipv4.tcp_fin_timeout|net.ipv4.tcp_tw_reuse'

echo "脚本执行成功。"
