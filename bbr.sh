#!/bin/bash

# 启用TCP窗口缩放
sysctl -w net.ipv4.tcp_window_scaling=1

# 设置TCP接收和发送缓冲区大小
sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456"
sysctl -w net.ipv4.tcp_wmem="4096 87380 6291456"

# 设置最大缓冲区大小
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# 设置TCP连接超时和启用TIME_WAIT套接字的快速回收
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_tw_recycle=1

# 加载BBR模块（可选：如果在sysctl.conf中配置，通常会自动加载）
modprobe tcp_bbr

# 更新sysctl配置文件以使设置永久生效
grep -qxF 'net.core.default_qdisc=fq' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf

# 重新应用新的设置
sysctl -p
