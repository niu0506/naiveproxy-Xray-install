#!/bin/bash

# 错误处理：若命令执行失败则退出脚本
set -e

# 函数：获取服务器的 IP 地址
get_server_ip() {
    hostname -I | awk '{print $1}'
}

# 函数：生成随机字符串
generate_random_string() {
    local length=$1
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "$length" | head -n 1
}

# 函数：生成随机端口
generate_random_port() {
    shuf -i 10000-20000 -n 1
}

# 获取服务器的 IP 地址
SERVER_IP=$(get_server_ip)

# 设置域名
read -p "请输入域名（如 example.com）: " DOMAIN
DOMAIN=${DOMAIN:-"example.com"}

# caddy证书路径
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"

# 变量：邮箱
read -p "请输入邮箱（默认随机）: " EMAIL
if [ -z "$EMAIL" ]; then
    RANDOM_STRING=$(generate_random_string 8)
    DOMAIN_SUFFIXES=("gmail.com" "sina.com" "yahoo.com")
    RANDOM_SUFFIX=${DOMAIN_SUFFIXES[$RANDOM % ${#DOMAIN_SUFFIXES[@]}]}
    EMAIL="$RANDOM_STRING@$RANDOM_SUFFIX"
fi

# 变量：naiveproxy用户名
read -p "请输入您的naiveproxy用户名（默认随机）: " AUTH_USER
if [ -z "$AUTH_USER" ]; then
    AUTH_USER=$(generate_random_string 8)
fi

# 变量：naiveproxy密码
read -s -p "请输入您的naiveproxy密码（默认随机）: " AUTH_PASS
echo
if [ -z "$AUTH_PASS" ]; then
    AUTH_PASS=$(openssl rand -hex 8)
fi

# 变量：xray端口
read -p "请输入xray端口（默认从10000-20000随机）: " PORT
if [ -z "$PORT" ]; then
    PORT=$(generate_random_port)
fi

# 更新软件包列表并升级系统软件
echo "正在更新软件包列表并升级系统软件..."
sudo apt update
sudo apt install -y curl wget git debian-keyring debian-archive-keyring apt-transport-https crontabs nftables
sudo apt upgrade -y 

# 运行apt自动清理
echo "正在运行apt自动清理..."
sudo apt autoremove -y

# 检查是否需要添加 Caddy 存储库
if [ ! -f "/usr/share/keyrings/caddy-stable-archive-keyring.gpg" ] || [ ! -f "/etc/apt/sources.list.d/caddy-stable.list" ]; then
    echo "需要添加 Caddy 存储库"
    
    # 添加 Caddy 存储库的 GPG 密钥
    echo "正在添加 Caddy 存储库的 GPG 密钥..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    
    # 添加 Caddy 存储库的信息
    echo "正在添加 Caddy 存储库的信息..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    
    # 更新 apt 软件包列表
    echo "正在更新 apt 软件包列表..."
    sudo apt update

    # 安装 Caddy 软件包
    echo "正在安装 Caddy 软件包..."
    sudo apt install -y caddy
fi

# 替换xcaddy
echo "正在下载并替换xcaddy..."
wget https://github.com/klzgrad/forwardproxy/releases/download/v2.7.6-naive2/caddy-forwardproxy-naive.tar.xz
tar -xvf caddy-forwardproxy-naive.tar.xz
sudo cp /root/caddy-forwardproxy-naive/caddy /usr/bin
# 为 /usr/bin 目录下的 caddy 文件添加执行权限
sudo chmod +x /usr/bin/caddy

# 修改Caddyfile
echo "正在修改Caddyfile..."
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
:443, $DOMAIN {
    tls $EMAIL
    route {
        forward_proxy {
            basic_auth $AUTH_USER $AUTH_PASS
            hide_ip
            hide_via
            probe_resistance
        }
        reverse_proxy https://www.coze.com { 
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Host {host}
        }
    }
}
EOF

# 重启Caddy服务
echo "正在重启Caddy服务..."
sudo systemctl restart caddy.service

# 安装xray
echo "正在安装xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 生成 x25519 密钥对并提取私钥和公钥
echo "正在生成 x25519 密钥对..."
X25519_KEY=$(xray x25519)
PRIVATE_KEY=$(echo "$X25519_KEY" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$X25519_KEY" | grep "Public key:" | awk '{print $3}')

# 生成随机 UUID
RANDOM_UUID=$(xray uuid)

# 生成随机的 shortId
RANDOM_SHORTID=$(openssl rand -hex 8)

# 修改xray配置文件
echo "正在修改xray配置文件..."
sudo tee /usr/local/etc/xray/config.json > /dev/null << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "https://cloudflare-dns.com/dns-query",
        "skipFallback": true,
        "queryStrategy": "UseIP"
      },
      {
        "address": "https://dns.google/dns-query",
        "skipFallback": true,
        "queryStrategy": "UseIP"
      }
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$RANDOM_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 6666
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": true,
          "dest": "$DOMAIN:443",
          "serverNames": [
            "$DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$RANDOM_SHORTID"
          ],
          "publicKey": "$PUBLIC_KEY"
        }
      }
    },
    {
      "port": 6666,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "email": "$EMAIL",
            "password": "$RANDOM_UUID",
            "level": 0
          }
        ],
        "fallbacks": [
          {
            "dest": 80
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {
          "acceptProxyProtocol": true
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

# 删除下载的文件和解压后的目录
rm -rf /root/caddy-forwardproxy-naive
rm -f /root/caddy-forwardproxy-naive.tar.xz

# 重启服务
echo "正在重启xray服务..."
sudo systemctl restart xray.service

echo 

# 输出VLESS和Hysteria的连接信息
echo "正在生成配置文件..."
echo "vless://$RANDOM_UUID@$SERVER_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$RANDOM_SHORTID&type=tcp&headerType=none#xray-reality" > /root/vless_config.json
echo "{\"listen\": \"socks://127.0.0.1:1080\",\"proxy\": \"https://$AUTH_USER:$AUTH_PASS@$DOMAIN\"}" > /root/naive.json

echo "安装完成"
