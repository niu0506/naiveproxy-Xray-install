#!/bin/bash
set -euo pipefail

# 定义颜色代码和重置符号
readonly CRED='\033[0;31m'
readonly CGRN='\033[0;32m'
readonly CYEL='\033[0;33m'
readonly CRST='\033[0m'

# 错误处理函数
die() {
    echo -e "${CRED}错误: $*${CRST}" >&2
    exit 1
}

# 生成随机字符串函数
generate_random() {
    local length=${1:-8}
    local charset=${2:-'a-zA-Z0-9'}
    tr -dc "$charset" < /dev/urandom | head -c "$length"
}

# 检查服务状态
check_service() {
    if ! systemctl is-active --quiet "$1"; then
        die "服务 $1 启动失败，请检查日志：journalctl -u $1"
    fi
}

# 检查依赖命令
check_deps() {
    local deps=("curl" "wget" "git" "openssl" "shuf" "gpg" "xray")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            die "依赖命令 $cmd 未安装"
        fi
    done
}

# 获取本机IP
get_server_ip() {
    hostname -I | awk '{print $1}' | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "无法获取有效IP"
}

# 配置防火墙
configure_firewall() {
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow "$1"/tcp
        ufw reload
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=80/tcpl
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port="$1"/tcp
        firewall-cmd --reload
    else
        echo -e "${CYEL}警告: 未找到UFW或firewalld，请手动开放端口$1,80,443${CRST}"
    fi
}

# 主函数
main() {
    check_deps

    # 基本信息配置
    readonly SERVER_IP=$(get_server_ip)
    read -p "请输入域名（如 example.com）: " DOMAIN
    readonly DOMAIN=${DOMAIN:-"example.com"}

    # 验证域名解析
    if ! dig +short "$DOMAIN" | grep -q "$SERVER_IP"; then
        echo -e "${CRED}警告: 域名 $DOMAIN 未解析到本机IP $SERVER_IP，证书申请可能失败！${CRST}"
        read -p "是否继续？(y/N) " -n 1 -r
        [[ $REPLY =~ ^[Yy]$ ]] || die "用户取消"
    fi

    # 获取Go最新版本
    readonly GOLANG_VERSION=$(curl -fsSL "https://golang.org/VERSION?m=text" | head -n1)

    # 用户输入处理
    read -p "请输入邮箱（默认随机）: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        EMAIL="$(generate_random 8 'a-z')@$(generate_random 5-8 'a-z').com"
    fi

    read -p "请输入naiveproxy用户名（默认随机）: " AUTH_USER
    readonly AUTH_USER=${AUTH_USER:-$(generate_random 12)}

    read -s -p "请输入naiveproxy密码（默认随机）: " AUTH_PASS
    echo
    readonly AUTH_PASS=${AUTH_PASS:-$(openssl rand -hex 12)}

    read -p "请输入xray端口（默认10000-20000随机）: " PORT
    readonly PORT=${PORT:-$(shuf -i 10000-20000 -n 1)}

    # 系统更新
    echo -e "${CYEL}[1/7] 更新系统组件...${CRST}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update && apt-get -qq upgrade -y
    apt-get -qq install -y curl wget git crontabs debian-archive-keyring ufw
    apt-get -qq autoremove -y

    # 配置防火墙
    echo -e "${CYEL}[2/7] 配置防火墙...${CRST}"
    configure_firewall "$PORT"

    # 安装Golang（如果尚未安装）
    if [[ ! -d /usr/local/go ]]; then
        echo -e "${CYEL}[3/7] 安装Golang ${GOLANG_VERSION}...${CRST}"
        readonly GO_TAR="go${GOLANG_VERSION}.linux-amd64.tar.gz"
        wget -q --show-progress "https://dl.google.com/go/${GO_TAR}"
        tar -C /usr/local -xzf "$GO_TAR"
        rm -f "$GO_TAR"
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/profile.d/go.sh
        source /etc/profile.d/go.sh
    else
        echo -e "${CYEL}[3/7] 跳过Golang安装，已存在...${CRST}"
    fi

    # 安装Caddy（使用自定义编译版本）
    echo -e "${CYEL}[4/7] 配置Caddy服务...${CRST}"
    if ! [[ -f /usr/bin/caddy ]]; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
        apt-get -qq update
        apt-get -qq install -y caddy

        # 编译自定义Caddy
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
        ~/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
        systemctl stop caddy
        mv caddy /usr/bin/
    fi

    # 配置Caddyfile
    echo -e "${CYEL}[5/7] 生成Caddy配置...${CRST}"
cat > /etc/caddy/Caddyfile <<-EOF
:80 {
    redir https://{host}{uri} permanent
}

${DOMAIN}:443 {
    tls ${EMAIL}
    route {
        forward_proxy {
            basic_auth ${AUTH_USER} ${AUTH_PASS}
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

    systemctl restart caddy.service
    check_service caddy

    # 安装Xray
    echo -e "${CYEL}[6/7] 安装Xray服务...${CRST}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    # 生成密钥材料
    echo -e "${CYEL}[7/7] 生成安全凭证...${CRST}"
    readonly X25519_KEY=$(xray x25519)
    readonly PRIVATE_KEY=$(awk '/Private key:/{print $3}' <<< "$X25519_KEY")
    readonly PUBLIC_KEY=$(awk '/Public key:/{print $3}' <<< "$X25519_KEY")
    readonly RANDOM_UUID=$(xray uuid)
    readonly RANDOM_SHORTID=$(openssl rand -hex 4)

    # 生成Xray配置
# 生成Xray配置（使用<<EOF顶格写法）
cat > /usr/local/etc/xray/config.json <<EOF
{
    "log": { "loglevel": "warning" },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
            { "type": "field", "ip": ["geoip:cn"], "outboundTag": "block" },
            { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" }
        ]
    },
    "inbounds": [
        {
            "port": ${PORT},
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "${RANDOM_UUID}", "flow": "xtls-rprx-vision" }],
                "fallbacks": [{"dest": 6666}]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "${DOMAIN}:443",
                    "serverNames": ["${DOMAIN}"],
                    "privateKey": "${PRIVATE_KEY}",
                    "shortIds": ["${RANDOM_SHORTID}"],
                    "publicKey": "${PUBLIC_KEY}"
                }
            }
        }
    ],
    "outbounds": [
        { "tag": "direct", "protocol": "freedom" },
        { "tag": "block", "protocol": "blackhole" }
    ]
}
EOF

# 输出配置信息（使用<<-EOF + tab缩进）
cat <<-EOF

    ${CGRN}=== 安装完成 ===${CRST}
    ${CYEL}服务器IP: ${CGRN}${SERVER_IP}
    ${CYEL}连接端口: ${CGRN}${PORT}
    ${CYEL}用户UUID: ${CGRN}${RANDOM_UUID}
    ${CYEL}公钥(PBK): ${CGRN}${PUBLIC_KEY}
    ${CYEL}短ID(SID): ${CGRN}${RANDOM_SHORTID}
    ${CYEL}域名(SNI): ${CGRN}${DOMAIN}

    ${CGRN}VLESS 链接:${CRST}
    vless://${RANDOM_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${RANDOM_SHORTID}&type=tcp#xray-reality

    ${CGRN}NaiveProxy 配置已保存到: ${CYEL}/root/naive.json${CRST}
EOF

main "$@"
