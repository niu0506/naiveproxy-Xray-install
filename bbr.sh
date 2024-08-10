#!/bin/bash

# Enable TCP window scaling
sysctl -w net.ipv4.tcp_window_scaling=1

# Set TCP receive and send buffer sizes
sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456"
sysctl -w net.ipv4.tcp_wmem="4096 87380 6291456"

# Set maximum buffer sizes for all sockets
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# Configure TCP settings
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_tw_reuse=1

# Load BBR module
modprobe tcp_bbr

# Update sysctl configuration file
grep -qxF 'net.core.default_qdisc=fq' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf

# Apply the changes
sysctl -p
