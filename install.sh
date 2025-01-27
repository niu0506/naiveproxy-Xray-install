#!/bin/bash
set -euo pipefail
trap 'echo -e "\n\033[31mError at line $LINENO\033[0m" >&2' ERR

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

#######################################
# 输出错误信息并退出
# Arguments:
#   $1: 错误信息
#######################################
die() {
  echo -e "${RED}Error: $1${NC}" >&2
  exit 1
}

#######################################
# 通用输入函数
# Globals:
#   None
# Arguments:
#   $1: 变量名
#   $2: 提示信息
#   $3: 默认生成命令（可选）
#######################################
prompt_input() {
  local var_name="$1"
  local prompt="$2"
  local default_gen="${3:-}"

  read -p "$prompt" "$var_name"
  
  if [[ -z "${!var_name}" && -n "$default_gen" ]]; then
    eval "$var_name=\"\$($default_gen)\""
    echo -e "${YELLOW}使用自动生成值: ${!var_name}${NC}"
  fi
}

#######################################
# 生成随机字符串
# Arguments:
#   $1: 长度 (默认8)
#   $2: 字符集 (默认a-zA-Z0-9)
#######################################
gen_random_str() {
  local len="${1:-8}"
  local charset="${2:-'a-zA-Z0-9'}"
  LC_ALL=C tr -dc "$charset" </dev/urandom | head -c"$len"
}

#######################################
# 安装系统依赖
#######################################
install_dependencies() {
  echo -e "\n${GREEN}正在更新系统并安装依赖...${NC}"
  
  sudo apt update && sudo apt upgrade -y || die "系统更新失败"
  sudo apt install -y \
    curl \
    wget \
    git \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https || die "依赖安装失败"

  sudo apt autoremove -y
}

# 检查root权限
[[ $(id -u) -eq 0 ]] || die "必须使用root权限运行脚本"

# 获取服务器IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "\n服务器IP: ${GREEN}${SERVER_IP}${NC}"

# 用户输入处理
prompt_input DOMAIN "请输入域名（默认 example.com）: " "echo example.com"
prompt_input EMAIL "请输入邮箱（默认随机生成）: " \
  "echo \"\$(gen_random_str 6 'a-z')@\$(shuf -e gmail.com sina.com yahoo.com -n1)\""

prompt_input AUTH_USER "请输入naiveproxy用户名（默认随机）: " "openssl rand -hex 8"
prompt_input AUTH_PASS "请输入naiveproxy密码（默认随机）: " "openssl rand -hex 8"
prompt_input PORT "请输入xray端口（默认10000-20000随机）: " "shuf -i 10000-20000 -n1"

# 安装系统依赖
install_dependencies

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

#替换xcaddy
sudo systemctl stop caddy.service
echo "正在下载并替换xcaddy..."
wget https://github.com/klzgrad/forwardproxy/releases/download/v2.7.6-naive2/caddy-forwardproxy-naive.tar.xz
tar -xvf caddy-forwardproxy-naive.tar.xz
sudo cp /root/caddy-forwardproxy-naive/caddy /usr/bin
# 为 /usr/bin 目录下的 caddy 文件添加执行权限
sudo chmod +x /usr/bin/caddy
# 删除下载的文件和解压后的目录
rm -rf /root/caddy-forwardproxy-naive
rm -f /root/caddy-forwardproxy-naive.tar.xz

# 生成Caddy配置
echo -e "\n${GREEN}生成Caddy配置文件...${NC}"
sudo cat <<EOF > /etc/caddy/Caddyfile
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
sudo systemctl restart caddy.service || die "Caddy服务启动失败"

# 安装Xray
echo -e "\n${GREEN}正在安装Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || die "Xray安装失败"

# 生成Xray密钥
echo -e "\n${GREEN}生成Xray密钥...${NC}"
X25519_KEY=$(xray x25519)
PRIVATE_KEY=$(awk '/Private key:/ {print $3}' <<< "$X25519_KEY")
PUBLIC_KEY=$(awk '/Public key:/ {print $3}' <<< "$X25519_KEY")
RANDOM_UUID=$(xray uuid)
RANDOM_SHORTID=$(openssl rand -hex 4)

# 生成Xray配置
echo -e "\n${GREEN}生成Xray配置文件...${NC}"
sudo tee /usr/local/etc/xray/config.json >/dev/null <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
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
        "fallbacks": [{"dest": 6666}]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": true,
          "dest": "${DOMAIN@Q}:443",
          "serverNames": ["${DOMAIN@Q}"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$RANDOM_SHORTID"],
          "publicKey": "$PUBLIC_KEY"
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

# 重启Xray服务
sudo systemctl restart xray.service || die "Xray服务启动失败"

# 输出配置信息
echo -e "\n${GREEN}======== 安装完成 ========${NC}"
echo -e "VLESS链接：\n${GREEN}vless://$RANDOM_UUID@$SERVER_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$RANDOM_SHORTID&type=tcp&headerType=none#xray-reality${NC}"

echo -e "\nNaiveProxy配置已保存到 ${GREEN}/root/naive.json${NC}"
sudo tee /root/naive.json >/dev/null <<EOF
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://${AUTH_USER@Q}:${AUTH_PASS@Q}@${DOMAIN@Q}"
}
EOF

echo -e "\n${YELLOW}提示：\n1. 请确保域名 ${DOMAIN} 已解析到本机IP\n2. 防火墙需要开放 $PORT 和 443 端口${NC}"
