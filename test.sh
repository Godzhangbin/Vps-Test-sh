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
PUBLIC_IPV4=$(curl -4 -sL --max-time 5 https://api.ipify.org | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

if [ -z "$PUBLIC_IPV4" ]; then
    echo -e "IPv4 状态: ${RED}无法获取公网 IPv4（可能为纯 IPv6 机器或 IPv4 出站阻断）${NC}"
else
    echo "本机网卡 IPv4: ${LOCAL_IPV4:-未检测到}"
    echo "外部出口 IPv4: $PUBLIC_IPV4"
    
    if ip -4 addr show | grep -q "$PUBLIC_IPV4"; then
        echo -e "IPv4 属性: ${GREEN}独立公网 IP（直接绑定在网卡上）${NC}"
    else
        echo -e "IPv4 属性: ${YELLOW}NAT 共享 IP / 内网映射（网卡为内网 IP，通过网关出公网）${NC}"
    fi
fi

# 2. 通过 ip -6 addr 检测网卡 IPv6 公网地址及静态/动态属性
echo -e "\n${YELLOW}[2/3] 正在检测 IPv6 地址属性...${NC}"
IPV6_BLOCK=$(ip -6 addr show scope global)

if [ -z "$IPV6_BLOCK" ]; then
    echo -e "网卡 IPv6 状态: ${RED}未检测到任何全局公网 IPv6 地址${NC}"
else
    echo -e "网卡 IPv6 状态: ${GREEN}已配置全局公网 IPv6${NC}"
    # 逐条解析网卡上的全局 IPv6 地址及其生命周期属性
    while IFS= read -r line; do
        if [[ "$line" =~ inet6[[:space:]]+([0-9a-fA-F:]+/[0-9]+) ]]; then
            addr="${BASH_REMATCH[1]}"
            flags="$line"
            read -r lft_line
            
            # 排除临时隐私扩展地址 (temporary) 和未完成 DAD 检测的地址
            if [[ "$flags" == *"temporary"* ]]; then
                type_desc="${YELLOW}动态临时隐私地址 (Privacy Extensions)${NC}"
            elif [[ "$lft_line" == *"valid_lft forever"* && "$flags" != *"dynamic"* ]]; then
                type_desc="${GREEN}静态公网 IPv6（永久有效 valid_lft forever）${NC}"
            else
                lft_val=$(echo "$lft_line" | grep -oP 'valid_lft\s+\S+')
                type_desc="${YELLOW}动态分配 IPv6（租约有效期: ${lft_val:-有限期}）${NC}"
            fi
            echo -e "  - 网卡绑定地址: ${addr} -> ${type_desc}"
        fi
    done <<< "$IPV6_BLOCK"
fi

# 探测外部出口 IPv6 是否可用
PUBLIC_IPV6=$(curl -6 -sL --max-time 5 https://api6.ipify.org | grep -oE '^[0-9a-fA-F:]+$')
if [ -n "$PUBLIC_IPV6" ]; then
    echo "外部出口 IPv6: $PUBLIC_IPV6"
    if ip -6 addr show | grep -qi "$PUBLIC_IPV6"; then
        echo -e "IPv6 出口状态: ${GREEN}外网畅通，且出口 IP 与网卡绑定一致${NC}"
    else
        echo -e "IPv6 出口状态: ${YELLOW}外网畅通，但经过了 NAT6 或动态地址转换${NC}"
    fi
elif [ -n "$IPV6_BLOCK" ]; then
    echo -e "IPv6 出口状态: ${RED}无法连接 IPv6 外网（网卡虽有公网 IPv6，但出站路由或防火墙未通）${NC}"
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

if [ -n "$LOCAL_IPV4" ] || [ -n "$PUBLIC_IPV4" ]; then
    echo ">> 通过 IPv4 下载测试:"
    check_download "https://www.google.com" 4 "Google" "google"
    check_download "https://www.youtube.com" 4 "YouTube" "ytInitialData"
fi

if [ -n "$IPV6_BLOCK" ] || [ -n "$PUBLIC_IPV6" ]; then
    echo ">> 通过 IPv6 下载测试:"
    check_download "https://www.google.com" 6 "Google" "google"
    check_download "https://www.youtube.com" 6 "YouTube" "ytInitialData"
fi

echo -e "\n=========================================="
echo "检测完成。"
