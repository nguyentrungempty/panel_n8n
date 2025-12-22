#!/usr/bin/env bash

# Network Functions - Các hàm liên quan đến mạng (IPv4/IPv6)
#
# HƯỚNG DẪN SỬ DỤNG:
# - get_server_ipv4(): Lấy địa chỉ IPv4 của server
# - get_server_ipv6(): Lấy địa chỉ IPv6 của server
# - get_server_ip(): Lấy IP ưu tiên (IPv4 trước, nếu không có thì IPv6)
# - auto_detect_ips(): Phát hiện cả IPv4 và IPv6, trả về format: "type|ipv4|ipv6"
# - check_domain_ip(): Kiểm tra domain có trỏ đúng đến server không
#
# KHUYẾN NGHỊ: 
# - Dùng get_server_ipv4() và get_server_ipv6() cho hầu hết trường hợp
# - Dùng auto_detect_ips() khi cần phát hiện đầy đủ thông tin network

get_server_ipv4() {
    local ipv4=""
    ipv4=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null) || \
    ipv4=$(curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null) || \
    ipv4=$(curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null) || \
    ipv4=$(hostname -I 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
    
    echo "$ipv4"
}

get_server_ipv6() {
    local ipv6=""
    ipv6=$(curl -6 -s --connect-timeout 5 ifconfig.me 2>/dev/null) || \
    ipv6=$(curl -6 -s --connect-timeout 5 icanhazip.com 2>/dev/null) || \
    ipv6=$(curl -6 -s --connect-timeout 5 api64.ipify.org 2>/dev/null) || \
    ipv6=$(hostname -I 2>/dev/null | grep -oE "([0-9a-fA-F]{0,4}:){7}[0-9a-fA-F]{0,4}" | head -1)
    
    echo "$ipv6"
}

get_server_ip() {
    local ipv4=$(get_server_ipv4)
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
    else
        local ipv6=$(get_server_ipv6)
        echo "$ipv6"
    fi
}

auto_detect_ips() {
    echo -e "${CYAN}🔍 Đang tự động phát hiện địa chỉ IP...${NC}"
    
    local ipv4=$(get_server_ipv4)
    local ipv6=$(get_server_ipv6)
    
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    if [ -n "$ipv4" ]; then
        echo -e "${GREEN}✅ IPv4: $ipv4${NC}"
    else
        echo -e "${YELLOW}⚠️  IPv4: Không phát hiện${NC}"
    fi
    
    if [ -n "$ipv6" ]; then
        echo -e "${GREEN}✅ IPv6: $ipv6${NC}"
    else
        echo -e "${YELLOW}⚠️  IPv6: Không phát hiện${NC}"
    fi
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    
    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        echo -e "${GREEN}🌐 Hệ thống hỗ trợ: Dual-stack (IPv4 + IPv6)${NC}"
        echo "ipv4|ipv6|$ipv4|$ipv6"
    elif [ -n "$ipv4" ]; then
        echo -e "${GREEN}🌐 Hệ thống hỗ trợ: IPv4 only${NC}"
        echo "ipv4||$ipv4|"
    elif [ -n "$ipv6" ]; then
        echo -e "${GREEN}🌐 Hệ thống hỗ trợ: IPv6 only${NC}"
        echo "ipv6||$ipv6|"
    else
        echo -e "${RED}❌ Không phát hiện được IP nào!${NC}"
        echo "none|||"
    fi
}

check_domain_ip() {
    local domain=$1
    local server_ipv4=$2
    local server_ipv6=$3
    
    echo -e "${YELLOW}Kiểm tra domain $domain...${NC}"
    
    local ipv4_match=false
    local ipv6_match=false
    local has_ipv4=false
    local has_ipv6=false
    
    if [ -n "$server_ipv4" ]; then
        has_ipv4=true
        echo -e "${CYAN}Kiểm tra A record (IPv4)...${NC}"
        local resolved_ipv4=""
        
        if command -v host &> /dev/null; then
            resolved_ipv4=$(host "$domain" 2>/dev/null | grep "has address" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
        elif command -v nslookup &> /dev/null; then
            resolved_ipv4=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
        elif command -v dig &> /dev/null; then
            resolved_ipv4=$(dig +short "$domain" A 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
        fi
        
        if [ -n "$resolved_ipv4" ]; then
            echo -e "${CYAN}   IPv4 từ DNS: $resolved_ipv4${NC}"
            if [ "$resolved_ipv4" = "$server_ipv4" ]; then
                echo -e "${GREEN}   ✅ IPv4 khớp!${NC}"
                ipv4_match=true
            else
                echo -e "${YELLOW}   ⚠️  IPv4 không khớp (Server: $server_ipv4, DNS: $resolved_ipv4)${NC}"
            fi
        else
            echo -e "${YELLOW}   ⚠️  Không tìm thấy A record${NC}"
        fi
    fi
    
    if [ -n "$server_ipv6" ]; then
        has_ipv6=true
        echo -e "${CYAN}Kiểm tra AAAA record (IPv6)...${NC}"
        local resolved_ipv6=""
        
        if command -v host &> /dev/null; then
            resolved_ipv6=$(host "$domain" 2>/dev/null | grep "has IPv6 address" | awk '{print $NF}' | head -1)
        elif command -v nslookup &> /dev/null; then
            resolved_ipv6=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | grep ":" | awk '{print $2}' | head -1)
        elif command -v dig &> /dev/null; then
            resolved_ipv6=$(dig +short "$domain" AAAA 2>/dev/null | head -1)
        fi
        
        if [ -n "$resolved_ipv6" ]; then
            echo -e "${CYAN}   IPv6 từ DNS: $resolved_ipv6${NC}"
            if [ "$resolved_ipv6" = "$server_ipv6" ]; then
                echo -e "${GREEN}   ✅ IPv6 khớp!${NC}"
                ipv6_match=true
            else
                echo -e "${YELLOW}   ⚠️  IPv6 không khớp (Server: $server_ipv6, DNS: $resolved_ipv6)${NC}"
            fi
        else
            echo -e "${YELLOW}   ⚠️  Không tìm thấy AAAA record${NC}"
        fi
    fi
    
    if ($has_ipv4 && $ipv4_match) || ($has_ipv6 && $ipv6_match); then
        echo -e "${GREEN}✅ Domain đã trỏ đúng đến máy chủ${NC}"
        return 0
    fi
    
    echo -e "${RED}⚠️  Cảnh báo: Domain chưa trỏ đúng đến máy chủ${NC}"
    echo -e "${YELLOW}Bạn có muốn:${NC}"
    echo -e "${CYAN}1. Kiểm tra lại${NC}"
    echo -e "${CYAN}2. Bỏ qua kiểm tra${NC}"
    echo -e "${CYAN}3. Hủy cài đặt${NC}"
    read -p "$(echo -e ${CYAN}Lựa chọn [1/2/3]: ${NC})" dns_choice
    
    case $dns_choice in
        1) check_domain_ip "$domain" "$server_ipv4" "$server_ipv6"
           return $? ;;
        2) echo -e "${YELLOW}Bỏ qua kiểm tra DNS. Tiếp tục cài đặt...${NC}"
           return 0 ;;
        *) echo -e "${RED}Quá trình cài đặt bị hủy.${NC}"
           return 1 ;;
    esac
}
