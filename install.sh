#!/bin/bash

# 遇到错误立即退出
set -e

# 定义清理函数，在脚本退出时执行
cleanup() {
    local exit_code=$?
    # 删除临时文件和目录
    rm -rf /root/caddy-forwardproxy-naive
    rm -f /root/caddy-forwardproxy-naive.tar.xz
    if [ $exit_code -ne 0 ]; then
        echo "脚本执行过程中出现错误，已停止。退出状态码: $exit_code"
    fi
}

# 注册清理函数，在脚本退出时调用
trap cleanup EXIT

# 检查是否以 root 用户身份运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户身份运行此脚本。"
    exit 1
fi

# 获取服务器的 IP 地址
SERVER_IP=$(hostname -I | awk '{print $1}')

# 设置域名
read -p "请输入域名（如 example.com）: " DOMAIN
DOMAIN=${DOMAIN:-"example.com"}

# caddy证书路径
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"

# 变量
read -p "请输入邮箱（默认随机）: " EMAIL

# 如果用户没有输入邮箱，则随机生成一个
if [ -z "$EMAIL" ]; then
    RANDOM_STRING=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 8 | head -n 1)
    DOMAIN_SUFFIXES=("gmail.com" "sina.com" "yahoo.com")
    RANDOM_SUFFIX=${DOMAIN_SUFFIXES[$RANDOM % ${#DOMAIN_SUFFIXES[@]}]}
    EMAIL="$RANDOM_STRING@$RANDOM_SUFFIX"
fi

read -p "请输入您的naiveproxy用户名（默认随机）: " AUTH_USER
# 如果用户没有输入用户名，则生成一个随机字符串
if [ -z "$AUTH_USER" ]; then
    AUTH_USER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
fi

read -s -p "请输入您的naiveproxy密码（默认随机）: " AUTH_PASS
echo
# 如果用户没有输入密码，则生成一个随机字符串
if [ -z "$AUTH_PASS" ]; then
    AUTH_PASS=$(openssl rand -hex 8)
fi

read -p "请输入xray端口（默认从10000-20000随机）: " PORT
# 如果用户没有输入端口，则生成一个随机端口
if [ -z "$PORT" ]; then
    PORT=$(shuf -i 10000-20000 -n 1)
fi

# 更新并安装基础软件
apt update && apt install -y curl wget git gpg debian-keyring debian-archive-keyring apt-transport-https
apt upgrade -y && apt autoremove -y

# 添加 Caddy 存储库并安装
echo "添加 Caddy 存储库"
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

# 安装caddy
apt update
apt install -y caddy

# 替换xcaddy
systemctl stop caddy.service
echo "正在下载并替换xcaddy..."
wget https://github.com/klzgrad/forwardproxy/releases/download/v2.7.6-naive2/caddy-forwardproxy-naive.tar.xz
tar -xvf caddy-forwardproxy-naive.tar.xz
cp /root/caddy-forwardproxy-naive/caddy /usr/bin
# 为 /usr/bin 目录下的 caddy 文件添加执行权限
chmod +x /usr/bin/caddy

# 修改Caddyfile
cat <<EOF > /etc/caddy/Caddyfile
:443, $DOMAIN {
    tls $EMAIL
    route {
        forward_proxy {
            basic_auth $AUTH_USER $AUTH_PASS
            hide_ip
            hide_via
            probe_resistance
        }
        reverse_proxy https://www.bing.com { 
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Host {host}
        }
    }
}
EOF

# 删除下载的文件和解压后的目录
rm -rf /root/caddy-forwardproxy-naive
rm -f /root/caddy-forwardproxy-naive.tar.xz

# 重启Caddy服务
systemctl restart caddy.service

# 安装xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 生成 X25519 密钥对并提取私钥和公钥
X25519_KEY=$(xray x25519)
PRIVATE_KEY=$(echo "$X25519_KEY" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$X25519_KEY" | grep "Public key:" | awk '{print $3}')

# 生成随机 UUID 和 shortId
RANDOM_UUID=$(xray uuid)
RANDOM_SHORTID=$(openssl rand -hex 8)

# 修改xray配置文件
cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "https://cloudflare-dns.com/dns-query",
        "queryStrategy": "UseIP"
      },
      {
        "address": "https://dns.google/dns-query",
        "queryStrategy": "UseIP"
      }
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": [
          "dokodemo-in"
        ],
        "domain": [
          "$DOMAIN"
        ],
        "outboundTag": "direct"
      },
      {
        "inboundTag": [
          "dokodemo-in"
        ],
        "outboundTag": "block"
      },
      {
        "ip": [
          "geoip:private",
          "geoip:cn"
        ],
        "domain": [
          "geosite:category-ads-all",
          "geosite:cn"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
      {
      "tag": "dokodemo-in",
      "port": 8080,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": $PORT,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "tls"
        ],
        "routeOnly": true
      }
    },
    {
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      },
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$RANDOM_UUID"
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
        "network": "xhttp",
        "xhttpSettings": {
          "host": "$DOMAIN",
          "path": "/xhttp",
          "mode": "auto",
          "extra": {
            "headers": {
              "key": "value"
            },
            "xPaddingBytes": "100-1000"
          }
        },
        "security": "reality",
        "realitySettings": {
          "dest": "$DOMAIN:443",
          "serverNames": [
            "$DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$RANDOM_SHORTID"
          ]
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

# 重启服务
systemctl restart xray.service

echo 

# 输出VLESS连接信息
echo "vless://$RANDOM_UUID@$SERVER_IP:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$RANDOM_SHORTID&type=xhttp&host=$DOMAIN&path=%2Fxhttp&mode=auto#xray-reality" > /root/vless_config.json
echo "{\"listen\": \"socks://127.0.0.1:1080\",\"proxy\": \"https://$AUTH_USER:$AUTH_PASS@$DOMAIN\"}" > /root/naive.json

echo "安装完成"
