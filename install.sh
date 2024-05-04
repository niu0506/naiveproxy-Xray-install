#!/bin/bash

# 获取服务器的 IP 地址
SERVER_IP=$(hostname -I | awk '{print $1}')

# 设置域名
read -p "请输入域名（如 example.com）: " DOMAIN
DOMAIN=${DOMAIN:-"example.com"}

# go最新版本
VERSION=$(curl -sSL "https://golang.org/VERSION?m=text")

#caddy证书路径
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"

#变量

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
# 如果用户没有输入密码，则生成一个随机字符串
if [ -z "$AUTH_PASS" ]; then
    AUTH_PASS=$(openssl rand -hex 8)
fi

read -s -p "请输入您的Hysteria密码（默认随机）: " HYSTERIA_PASS
# 如果用户没有输入密码，则生成一个随机字符串
if [ -z "$HYSTERIA_PASS" ]; then
    HYSTERIA_PASS=$(openssl rand -hex 16)
fi

read -p "请输入xray端口（默认从10000-20000随机）: " PORT
# 如果用户没有输入端口，则生成一个随机端口
if [ -z "$PORT" ]; then
    PORT=$(shuf -i 10000-20000 -n 1)
fi

# 更新软件包列表并升级系统软件
apt update
apt install -y curl wget git debian-keyring debian-archive-keyring apt-transport-https crontabs
apt upgrade -y 

# 运行apt自动清理
apt autoremove -y

# 设置系统缓冲区大小
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# 检查当前系统是否支持BBR
grep -qF "tcp_bbr" /etc/modules || echo "tcp_bbr" >> /etc/modules
grep -qF "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -qF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# 应用修改
sysctl -p

# 下载 Go 二进制压缩包
wget https://golang.org/dl/go$VERSION.linux-amd64.tar.gz

# 解压压缩包到 /usr/local 目录
tar -C /usr/local -xzf go$VERSION.linux-amd64.tar.gz

# 删除下载的压缩包
rm go$VERSION.linux-amd64.tar.gz

# 配置环境变量
echo 'export GOPATH=$HOME/go' >> ~/.profile
echo 'export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin' >> ~/.profile

# 重新加载配置文件
source ~/.profile

# 检查是否需要添加 Caddy 存储库
if [ ! -f "/usr/share/keyrings/caddy-stable-archive-keyring.gpg" ] || [ ! -f "/etc/apt/sources.list.d/caddy-stable.list" ]; then
    echo "需要添加 Caddy 存储库"
    
    # 添加 Caddy 存储库的 GPG 密钥
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    
    # 添加 Caddy 存储库的信息
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    
    # 更新 apt 软件包列表
    sudo apt update

    # 安装 Caddy 软件包
    sudo apt install -y caddy
fi

if [ ! -f "/root/caddy" ]; then
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
~/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
fi
systemctl stop caddy.service
cp /root/caddy /usr/bin

# 修改Caddyfile

cat <<EOF > /etc/caddy/Caddyfile
:80 {
    root * /usr/share/caddy
    file_server
}

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

:8443 {
         reverse_proxy https://www.coze.com { 
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Host {host}
        }
}
EOF

#重启Caddy服务
systemctl restart caddy.service

# 安装Hysteria
bash <(curl -fsSL https://get.hy2.sh/) 

# 修改Hysteria配置文件

cat <<EOF > /etc/hysteria/config.yaml
listen: 0.0.0.0:8443

tls:
  cert: /etc/hysteria/$DOMAIN.crt
  key: /etc/hysteria/$DOMAIN.key

auth:
  type: password
  password: $HYSTERIA_PASS

quic:
  initStreamReceiveWindow: 26843545 
  maxStreamReceiveWindow: 26843545 
  initConnReceiveWindow: 67108864 
  maxConnReceiveWindow: 67108864

acl:
  inline: 
    - reject(all, udp/443)
    - reject(geoip:private)
    - reject(geoip:cn)
    - reject(geosite:cn)
    - reject(geosite:category-ads-all)
    - direct(all)

masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN/
    rewriteHost: true
EOF

# 检查证书目录是否存在
while [ ! -d "$CERT_DIR" ]; do
    sleep 1
done

# 复制证书文件到/etc/hysteria
cp -f "$CERT_DIR/$DOMAIN.crt" /etc/hysteria/
cp -f "$CERT_DIR/$DOMAIN.key" /etc/hysteria/
chmod 444 /etc/hysteria/*.crt
chmod 444 /etc/hysteria/*.key

# 安装xay
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 生成 x25519 密钥对并提取私钥和公钥
X25519_KEY=$(xray x25519)

# 提取私钥和公钥
PRIVATE_KEY=$(echo "$X25519_KEY" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$X25519_KEY" | grep "Public key:" | awk '{print $3}')

# 生成随机 UUID
RANDOM_UUID=$(xray uuid)

# 生成随机的 shortId
RANDOM_SHORTID=$(openssl rand -hex 8)

# 修改xray配置文件
cat << EOF > /usr/local/etc/xray/config.json
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

# 指定要添加的计划任务
CRON_JOB="0 0 * * * systemctl restart hysteria-server"

# 创建一个空的临时文件，如果不存在的话
touch /tmp/crontab.tmp

# 检查是否已经存在相同的任务
if ! grep -qF "$CRON_JOB" /tmp/crontab.tmp; then
    # 添加任务到临时文件
    echo "$CRON_JOB" >> /tmp/crontab.tmp

    # 导入更新后的 crontab
    crontab /tmp/crontab.tmp
fi

# 删除临时文件
rm /tmp/crontab.tmp

# Hysteria服务开机自启
systemctl enable hysteria-server.service

# 重启服务
systemctl restart xray.service
systemctl restart hysteria-server.service

echo 

# 输出VLESS和Hysteria的连接信息
echo "vless://$RANDOM_UUID@$SERVER_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$RANDOM_SHORTID&type=tcp&headerType=none#xray-reality" > /root/vless_config.json

echo "hysteria2://$HYSTERIA_PASS@$SERVER_IP:8443/?sni=$DOMAIN&alpn=h3&insecure=0#Hysteria2" > /root/hysteria_config.json

echo "{\"listen\": \"socks://127.0.0.1:1080\",\"proxy\": \"https://$AUTH_USER:$AUTH_PASS@$DOMAIN\"}" > /root/naive.json

echo "安装完成"
