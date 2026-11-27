#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "    VPS 公网属性与真实数据下载检测脚本"
echo "=========================================="

# 1. 检测 IPv4 公网属性
echo -e "\n${YELLOW}[1/3] 正在检测 IPv4 地址属性...${NC}"
LOCAL_IPV4=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
PUBLIC_IPV4=$(curl -4 -sL --max-time 5 https://www.ipify.org | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

if [ -z "$PUBLIC_IPV4" ]; then
    echo -e "IPv4 状态: ${RED}无法获取公网 IPv4（纯 IPv6 机器或 IPv4 出站阻断）${NC}"
else
    echo "本机网卡 IPv4: ${LOCAL_IPV4:-未检测到}"
    echo "外部出口 IPv4: $PUBLIC_IPV4"
    
    if ip -4 addr show | grep -q "$PUBLIC_IPV4"; then
        echo -e "IPv4 属性: ${GREEN}独立公网 IP（直接绑定在网卡上）${NC}"
    else
        echo -e "IPv4 属性: ${YELLOW}NAT 共享 IP / 内网映射（网卡为内网 IP，通过网关出公网）${NC}"
    fi
fi

# 2. 检测 IPv6 公网属性（先查网卡绑定，再测外网连通）
echo -e "\n${YELLOW}[2/3] 正在检测 IPv6 地址属性...${NC}"
LOCAL_IPV6=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-fA-F:]+' | head -n 1)
PUBLIC_IPV6=$(curl -6 -sL --max-time 5 https://www.ipify.org | grep -oE '^[0-9a-fA-F:]+$')

if [ -z "$LOCAL_IPV6" ] && [ -z "$PUBLIC_IPV6" ]; then
    echo -e "IPv6 状态: ${RED}网卡未配置全局 IPv6 地址${NC}"
elif [ -n "$LOCAL_IPV6" ] && [ -z "$PUBLIC_IPV6" ]; then
    echo "本机网卡 IPv6: $LOCAL_IPV6"
    echo -e "IPv6 状态: ${RED}网卡已分配公网 IPv6，但无法连接 IPv6 外网（请检查防火墙/安全组或路由表）${NC}"
else
    echo "本机网卡 IPv6: ${LOCAL_IPV6:-未检测到}"
    echo "外部出口 IPv6: $PUBLIC_IPV6"
    
    if ip -6 addr show | grep -qi "$PUBLIC_IPV6"; then
        echo -e "IPv6 属性: ${GREEN}独立公网 IP（直接绑定在网卡上且外网畅通）${NC}"
    else
        echo -e "IPv6 属性: ${YELLOW}NAT6 或动态隐私扩展地址（网卡 IP 与出口 IP 不一致）${NC}"
    fi
fi

# 3. 真实下载网页数据并校验内容函数
check_download() {
    local url=$1
    local ip_ver=$2
    local label=$3
    local keyword=$4
    local tmp_file=$(mktemp)

    metrics=$(curl -$ip_ver -s -L --max-time 10 \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        -o "$tmp_file" \
        -w "%{http_code}|%{size_download}|%{speed_download}" "$url")

    http_code=$(echo "$metrics" | cut -d'|' -f1)
    size_bytes=$(echo "$metrics" | cut -d'|' -f2)
    speed_bps=$(echo "$metrics" | cut -d'|' -f3 | cut -d'.' -f1)
    speed_kbps=$((speed_bps / 1024))

    if [[ "$http_code" == "200" && "$size_bytes" -gt 10240 ]]; then
        if grep -qi "<title>.*unusual traffic.*</title>" "$tmp_file"; then
            echo -e "  - $label: ${YELLOW}已下载数据 (${size_bytes} 字节)，但触发 Google 人机验证风控${NC}"
        elif grep -qi "$keyword" "$tmp_file"; then
            echo -e "  - $label: ${GREEN}下载成功 | 状态: 200 | 大小: ${size_bytes} 字节 | 速度: ${speed_kbps} KB/s${NC}"
        else
            echo -e "  - $label: ${YELLOW}状态 200 且下载了 ${size_bytes} 字节，但未匹配到预期页面特征${NC}"
        fi
    elif [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
        echo -e "  - $label: ${RED}拒绝访问/触发风控 (HTTP $http_code | 下载: ${size_bytes} 字节)${NC}"
    elif [[ "$http_code" == "000" ]]; then
        echo -e "  - $label: ${RED}连接超时或无法建立 TLS 握手${NC}"
    else
        echo -e "  - $label: ${RED}下载异常 (HTTP $http_code | 仅下载: ${size_bytes} 字节)${NC}"
    fi

    rm -f "$tmp_file"
}

echo -e "\n${YELLOW}[3/3] 正在测试真实网页数据下载...${NC}"

if [ -n "$PUBLIC_IPV4" ]; then
    echo ">> 通过 IPv4 下载测试:"
    check_download "https://www.google.com" 4 "Google" "google"
    check_download "https://www.youtube.com" 4 "YouTube" "ytInitialData"
fi

if [ -n "$PUBLIC_IPV6" ]; then
    echo ">> 通过 IPv6 下载测试:"
    check_download "https://www.google.com" 6 "Google" "google"
    check_download "https://www.youtube.com" 6 "YouTube" "ytInitialData"
fi

echo -e "\n=========================================="
echo "检测完成。"
