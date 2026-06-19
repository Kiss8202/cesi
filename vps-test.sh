#!/bin/bash
# ===================================================
# VPS 网络质量交互测试脚本 (v20 - 完整版)
# 功能：本地+国内测速，MTR，Ping，路由追踪，自动评价
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

LOCAL_CACHE_FILE="/tmp/local_speed_result.txt"
DEPS_INSTALLED_FLAG="/tmp/vps_test_deps_installed"

# ---------- 预置常用节点 ID ----------
get_predefined_id() {
    case "$1_$2" in
        "beijing_china unicom") echo "5145" ;;
        "shanghai_china unicom") echo "5083" ;;
        "guangzhou_china unicom") echo "4624" ;;
        "shenyang_china unicom") echo "17344" ;;
        "dalian_china unicom") echo "1536" ;;
        "beijing_china mobile") echo "18475" ;;
        "shanghai_china mobile") echo "18474" ;;
        "guangzhou_china mobile") echo "18473" ;;
        "beijing_china telecom") echo "18472" ;;
        "shanghai_china telecom") echo "18471" ;;
        "guangzhou_china telecom") echo "18470" ;;
        *) return 1 ;;
    esac
}

# ---------- 评价函数 ----------
evaluate_latency() {
    local target_name="$1"
    local avg="$2"
    local loss="$3"
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BOLD}📊 延迟/丢包评价 (目标: $target_name)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "平均延迟: ${avg}ms  |  丢包率: ${loss}%"
    if [[ -z "$avg" || -z "$loss" || "$avg" == "?" || "$loss" == "?" ]]; then
        echo -e "${RED}❌ 无法获取有效数据${NC}"
    elif (( $(echo "$avg < 80" | bc -l 2>/dev/null) )) && (( $(echo "$loss < 2" | bc -l 2>/dev/null) )); then
        echo -e "${GREEN}${BOLD}✅ 线路评级：优秀 (★★★★★)${NC}"
    elif (( $(echo "$avg < 120" | bc -l 2>/dev/null) )) && (( $(echo "$loss < 5" | bc -l 2>/dev/null) )); then
        echo -e "${YELLOW}${BOLD}⚠️  线路评级：良好 (★★★☆☆)${NC}"
    else
        echo -e "${RED}${BOLD}❌ 线路评级：较差 (★☆☆☆☆)${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
}

evaluate_speed() {
    local test_type="$1"
    local download="$2"
    local upload="$3"
    local server_info="$4"
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BOLD}📊 ${test_type}带宽测速结果${NC}"
    echo -e "${BLUE}========================================${NC}"
    if [ -n "$server_info" ]; then
        echo -e "📌 测速节点: ${server_info}"
    fi
    echo -e "下载速度: ${download} Mbps  |  上传速度: ${upload} Mbps"
    if [[ -z "$download" || "$download" == "0" ]]; then
        echo -e "${RED}❌ 无法获取有效速度数据${NC}"
    elif (( $(echo "$download > 500" | bc -l 2>/dev/null) )); then
        echo -e "${GREEN}${BOLD}✅ 带宽评级：极速 (★★★★★)${NC}"
    elif (( $(echo "$download > 100" | bc -l 2>/dev/null) )); then
        echo -e "${YELLOW}${BOLD}⚠️  带宽评级：良好 (★★★☆☆)${NC}"
    else
        echo -e "${RED}${BOLD}❌ 带宽评级：较低 (★☆☆☆☆)${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
}

evaluate_combined() {
    local local_dl="$1"
    local cn_dl="$2"
    local cn_server="$3"
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BOLD}📊 综合对比评价${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "📌 本地带宽 (VPS上限): ${local_dl} Mbps"
    echo -e "📌 国内测速 (到 ${cn_server}): ${cn_dl} Mbps"
    if [[ -z "$local_dl" || -z "$cn_dl" ]]; then
        echo -e "${RED}数据不完整，无法评价${NC}"
    elif (( $(echo "$cn_dl > 500" | bc -l 2>/dev/null) )); then
        echo -e "${GREEN}${BOLD}✅ 国内速度极佳，几乎跑满本地带宽，线路非常优秀！${NC}"
    elif (( $(echo "$cn_dl > 100" | bc -l 2>/dev/null) )); then
        echo -e "${YELLOW}${BOLD}⚠️  国内速度良好，但未完全跑满本地带宽，可能存在轻微拥堵。${NC}"
    else
        echo -e "${RED}${BOLD}❌ 国内速度远低于本地带宽，线路严重拥堵或运营商限速。${NC}"
    fi
    echo -e "${BLUE}========================================${NC}"
}

# ---------- 运行 Speedtest（含限流检测） ----------
run_speedtest() {
    local id="$1"
    local output_file="/tmp/speedtest_output.txt"
    local cmd="speedtest"
    [ -n "$id" ] && cmd="$cmd -s $id"
    $cmd > "$output_file" 2>&1
    local ret=$?
    if [ $ret -ne 0 ] || [ ! -s "$output_file" ]; then
        if grep -qi "Too many requests" "$output_file"; then
            echo -e "${RED}⛔ Speedtest 官方限流，请等待 5 分钟后再试。${NC}" >&2
            echo -e "${YELLOW}你也可以选择其他节点或稍后重试。${NC}" >&2
            rm -f "$output_file"
            return 2
        fi
        echo -e "${RED}测速失败${NC}" >&2
        cat "$output_file" >&2
        rm -f "$output_file"
        return 1
    fi
    local download=$(grep -i "Download:" "$output_file" | tail -1 | sed -E 's/.*Download:[[:space:]]*([0-9.]+).*/\1/')
    local upload=$(grep -i "Upload:" "$output_file" | tail -1 | sed -E 's/.*Upload:[[:space:]]*([0-9.]+).*/\1/')
    local server=$(grep -i "Server:" "$output_file" | head -1 | sed -E 's/^[[:space:]]*Server:[[:space:]]*//')
    [ -z "$server" ] && server="未知节点"
    rm -f "$output_file"
    echo "$download $upload $server"
    return 0
}

# ---------- 获取节点 ID ----------
get_node_id() {
    local city="$1" isp="$2"
    local id=""
    # 先尝试从 speedtest -L 实时获取中国节点
    for cmd in "--servers" "-L"; do
        id=$(speedtest $cmd 2>/dev/null | grep -i "china" | grep -i "$city" | grep -i "$isp" | head -1 | awk '{print $1}' | sed 's/[^0-9]//g')
        [ -n "$id" ] && { echo "$id"; return 0; }
    done
    for cmd in "--servers" "-L"; do
        id=$(speedtest $cmd 2>/dev/null | grep -i "china" | grep -i "$city" | head -1 | awk '{print $1}' | sed 's/[^0-9]//g')
        [ -n "$id" ] && { echo "$id"; return 0; }
    done
    for cmd in "--servers" "-L"; do
        id=$(speedtest $cmd 2>/dev/null | grep -i "china" | grep -i "$isp" | head -1 | awk '{print $1}' | sed 's/[^0-9]//g')
        [ -n "$id" ] && { echo "$id"; return 0; }
    done
    # fallback 到预置ID
    id=$(get_predefined_id "$city" "$isp")
    [ -n "$id" ] && { echo "$id"; return 0; }
    return 1
}

# ---------- 显示可用中国节点 ----------
show_china_nodes() {
    echo -e "${YELLOW}正在获取可用中国节点列表...${NC}"
    local nodes=""
    for cmd in "--servers" "-L"; do
        nodes=$(speedtest $cmd 2>/dev/null | grep -i "china" | head -15)
        [ -n "$nodes" ] && break
    done
    if [ -z "$nodes" ]; then
        echo -e "${RED}无法获取列表，使用预置常用节点：${NC}"
        echo "  5145 - 北京联通"
        echo "  5083 - 上海联通"
        echo "  4624 - 广州联通"
        echo "  17344 - 沈阳联通"
        echo "  1536 - 大连联通"
        return 1
    fi
    echo -e "${GREEN}可用中国节点（部分）：${NC}"
    echo "$nodes"
    return 0
}

# ---------- DNS 解析 ----------
resolve_ip() {
    local target="$1"
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$target"; return 0
    fi
    local ip=""
    if command -v dig &>/dev/null; then
        ip=$(dig +short "$target" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    if command -v nslookup &>/dev/null; then
        ip=$(nslookup "$target" 2>/dev/null | grep -E 'Address: [0-9.]+$' | tail -1 | awk '{print $2}')
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    if command -v host &>/dev/null; then
        ip=$(host -t A "$target" 2>/dev/null | grep 'has address' | head -1 | awk '{print $4}')
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    if command -v getent &>/dev/null; then
        ip=$(getent ahosts "$target" 2>/dev/null | grep -E '^[0-9.]+' | head -1 | awk '{print $1}')
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    return 1
}

get_target() {
    local prompt="$1"
    local default="$2"
    while true; do
        read -p "$prompt" input
        [ -z "$input" ] && [ -n "$default" ] && input="$default"
        [ -z "$input" ] && { echo -e "${RED}输入不能为空${NC}"; continue; }
        local ip=$(resolve_ip "$input")
        if [ $? -eq 0 ] && [ -n "$ip" ]; then
            echo "$ip"; return 0
        else
            echo -e "${RED}解析失败，请重新输入${NC}"
        fi
    done
}

# ---------- 依赖检查 ----------
check_deps() {
    # 如果已有标记且 speedtest 可用，直接跳过
    if [ -f "$DEPS_INSTALLED_FLAG" ] && command -v speedtest &>/dev/null; then
        if speedtest -L 2>&1 | head -1 | grep -q "speedtest"; then
            return 0
        else
            echo -e "${YELLOW}当前 speedtest 版本不支持列表查询，重新安装...${NC}"
            rm -f "$DEPS_INSTALLED_FLAG"
        fi
    fi

    # 检查核心依赖是否已存在
    local all_deps_ok=true
    for dep in curl mtr traceroute bc speedtest; do
        if ! command -v $dep &>/dev/null; then
            all_deps_ok=false
            break
        fi
    done
    if ! command -v nslookup &>/dev/null && ! command -v dig &>/dev/null; then
        all_deps_ok=false
    fi

    if [ "$all_deps_ok" = true ]; then
        echo -e "${GREEN}检测到所有依赖已安装，直接进入菜单...${NC}"
        sleep 1
        touch "$DEPS_INSTALLED_FLAG"
        return 0
    fi

    echo -e "${YELLOW}首次运行或需要更新，安装/重装必要工具...${NC}"
    for dep in curl mtr traceroute bc; do
        if ! command -v $dep &>/dev/null; then
            echo -e "安装 $dep ..."
            apt update -y && apt install -y $dep >/dev/null 2>&1 || yum install -y $dep >/dev/null 2>&1
        fi
    done
    if ! command -v nslookup &>/dev/null && ! command -v dig &>/dev/null; then
        echo -e "安装 DNS 工具 ..."
        if [[ -f /etc/debian_version ]]; then
            apt update -y && apt install -y dnsutils >/dev/null 2>&1
        else
            yum install -y bind-utils >/dev/null 2>&1
        fi
    fi

    if command -v speedtest &>/dev/null; then
        if ! speedtest -L &>/dev/null; then
            echo -e "卸载旧版 speedtest ..."
            if [[ -f /etc/debian_version ]]; then
                apt remove -y speedtest-cli >/dev/null 2>&1
            else
                yum remove -y speedtest-cli >/dev/null 2>&1
            fi
        fi
    fi
    if [[ -f /etc/debian_version ]]; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1
        apt install -y speedtest >/dev/null 2>&1
    else
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash >/dev/null 2>&1
        yum install -y speedtest >/dev/null 2>&1
    fi

    if ! command -v speedtest &>/dev/null; then
        echo -e "${RED}Speedtest 安装失败，请手动安装。${NC}"
        exit 1
    fi
    touch "$DEPS_INSTALLED_FLAG"
    echo -e "${GREEN}依赖处理完成。${NC}"
}

# ---------- 解析 MTR ----------
parse_mtr() {
    local result_file="$1"
    local last_line=$(grep -E '^[ ]*[0-9]+\.\|--' "$result_file" | grep -v '???' | grep -v '100.0%' | tail -1)
    if [ -z "$last_line" ]; then
        echo ""; echo ""; return 1
    fi
    local loss=$(echo "$last_line" | awk '{print $3}' | sed 's/%//')
    local avg=$(echo "$last_line" | awk '{print $6}')
    echo "$avg"; echo "$loss"; return 0
}

# ---------- 国内区域节点数据 ----------
# 格式: 城市英文名 运营商关键字 显示名称 speedtest节点ID(可选)
# 节点ID通过 speedtest -L 获取，如果预置ID失效会自动尝试从列表获取
declare -A REGION_NODES=(
    ["东北_1"]="shenyang china unicom 沈阳联通"
    ["东北_2"]="dalian china unicom 大连联通"
    ["东北_3"]="changchun china unicom 长春联通"
    ["东北_4"]="harbin china unicom 哈尔滨联通"
    ["东北_5"]="shenyang china telecom 沈阳电信"
    ["东北_6"]="shenyang china mobile 沈阳移动"
    ["华北_1"]="beijing china unicom 北京联通"
    ["华北_2"]="beijing china telecom 北京电信"
    ["华北_3"]="beijing china mobile 北京移动"
    ["华北_4"]="tianjin china unicom 天津联通"
    ["华北_5"]="tianjin china telecom 天津电信"
    ["华北_6"]="shijiazhuang china unicom 石家庄联通"
    ["华北_7"]="taiyuan china unicom 太原联通"
    ["华东_1"]="shanghai china unicom 上海联通"
    ["华东_2"]="shanghai china telecom 上海电信"
    ["华东_3"]="shanghai china mobile 上海移动"
    ["华东_4"]="hangzhou china unicom 杭州联通"
    ["华东_5"]="hangzhou china telecom 杭州电信"
    ["华东_6"]="nanjing china unicom 南京联通"
    ["华东_7"]="nanjing china telecom 南京电信"
    ["华东_8"]="suzhou china unicom 苏州联通"
    ["华南_1"]="guangzhou china unicom 广州联通"
    ["华南_2"]="guangzhou china telecom 广州电信"
    ["华南_3"]="guangzhou china mobile 广州移动"
    ["华南_4"]="shenzhen china unicom 深圳联通"
    ["华南_5"]="shenzhen china telecom 深圳电信"
    ["华南_6"]="fuzhou china unicom 福州联通"
    ["华中_1"]="wuhan china unicom 武汉联通"
    ["华中_2"]="wuhan china telecom 武汉电信"
    ["华中_3"]="changsha china unicom 长沙联通"
    ["华中_4"]="zhengzhou china unicom 郑州联通"
    ["西南_1"]="chengdu china unicom 成都联通"
    ["西南_2"]="chengdu china telecom 成都电信"
    ["西南_3"]="chengdu china mobile 成都移动"
    ["西南_4"]="chongqing china unicom 重庆联通"
    ["西南_5"]="chongqing china telecom 重庆电信"
    ["西南_6"]="kunming china unicom 昆明联通"
    ["西北_1"]="xian china unicom 西安联通"
    ["西北_2"]="xian china telecom 西安电信"
    ["西北_3"]="lanzhou china unicom 兰州联通"
    ["西北_4"]="urumqi china unicom 乌鲁木齐联通"
)

# ---------- 选择国内区域节点 ----------
select_cn_node() {
    echo "" >&2
    echo -e "${BLUE}========================================${NC}" >&2
    echo -e "${GREEN}🗺️  选择国内测速区域${NC}" >&2
    echo -e "${BLUE}========================================${NC}" >&2
    echo "  1) 东北" >&2
    echo "  2) 华北" >&2
    echo "  3) 华东" >&2
    echo "  4) 华南" >&2
    echo "  5) 华中" >&2
    echo "  6) 西南" >&2
    echo "  7) 西北" >&2
    echo "  8) 手动输入城市和运营商" >&2
    echo "  0) 返回" >&2
    read -p "请选择区域 [0-8] (默认1): " region_opt
    region_opt=${region_opt:-1}

    local region_key=""
    case $region_opt in
        1) region_key="东北" ;;
        2) region_key="华北" ;;
        3) region_key="华东" ;;
        4) region_key="华南" ;;
        5) region_key="华中" ;;
        6) region_key="西南" ;;
        7) region_key="西北" ;;
        8)
            read -p "请输入城市和运营商 (如: shenyang unicom): " custom_input
            local city=$(echo "$custom_input" | awk '{print $1}')
            local isp=$(echo "$custom_input" | awk '{print $2}')
            local id=$(get_node_id "$city" "$isp")
            if [ -n "$id" ]; then
                echo "$id 自定义 ($custom_input)"
            else
                echo ""
            fi
            return
            ;;
        0) echo "" >&2; return ;;
        *) echo "" >&2; return ;;
    esac

    # 收集该区域节点
    local nodes=()
    for key in "${!REGION_NODES[@]}"; do
        if [[ "$key" == ${region_key}_* ]]; then
            nodes+=("${REGION_NODES[$key]}")
        fi
    done

    if [ ${#nodes[@]} -eq 0 ]; then
        echo -e "${RED}该区域暂无预置节点${NC}" >&2
        echo "" >&2
        return
    fi

    echo "" >&2
    echo -e "${BLUE}========================================${NC}" >&2
    echo -e "${GREEN}📍 ${region_key}区域节点${NC}" >&2
    echo -e "${BLUE}========================================${NC}" >&2
    local i=1
    local node_info
    for node_info in "${nodes[@]}"; do
        local name=$(echo "$node_info" | awk '{print $4}')
        echo "  $i) $name" >&2
        i=$((i+1))
    done
    echo "  0) 返回" >&2
    read -p "请选择节点 [0-$((i-1))] (默认1): " node_opt
    node_opt=${node_opt:-1}
    [ "$node_opt" == "0" ] && { echo "" >&2; return; }

    if ! [[ "$node_opt" =~ ^[0-9]+$ ]] || [ "$node_opt" -lt 1 ] || [ "$node_opt" -gt $((i-1)) ]; then
        echo -e "${RED}无效选择${NC}" >&2
        echo "" >&2
        return
    fi

    local selected="${nodes[$((node_opt-1))]}"
    local city=$(echo "$selected" | awk '{print $1}')
    local isp=$(echo "$selected" | awk '{print $2" "$3}')
    local name=$(echo "$selected" | awk '{print $4}')

    # 优先通过 speedtest -L 实时获取节点ID
    local id=$(get_node_id "$city" "$isp")
    if [ -z "$id" ]; then
        echo -e "${RED}无法获取 ${name} 的有效节点ID，请检查网络或更换节点。${NC}" >&2
        echo "" >&2
        return
    fi

    echo "$id $name"
}

# ---------- 菜单1：测速 ----------
menu_speedtest() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}🚀 带宽测速（先测本地，再测国内，自动对比）${NC}"
    echo -e "${BLUE}========================================${NC}"

    local local_dl local_ul local_server
    if [ -f "$LOCAL_CACHE_FILE" ] && [ -s "$LOCAL_CACHE_FILE" ]; then
        read local_dl local_ul local_server < "$LOCAL_CACHE_FILE"
        echo -e "${YELLOW}检测到上次本地测速结果：${NC}"
        echo -e "下载: ${local_dl} Mbps, 上传: ${local_ul} Mbps (节点: ${local_server})"
        read -p "是否跳过本次本地测速，直接使用上次结果？(y/n, 默认y): " skip_local
        skip_local=${skip_local:-y}
        if [[ "$skip_local" == "y" || "$skip_local" == "Y" ]]; then
            echo -e "${GREEN}使用上次本地测速结果。${NC}"
            evaluate_speed "本地" "$local_dl" "$local_ul" "$local_server"
        else
            echo -e "${YELLOW}重新测速本地带宽...${NC}"
            local_result=$(run_speedtest "")
            local ret=$?
            if [ $ret -eq 2 ]; then
                read -p "按回车返回..."
                return
            elif [ $ret -ne 0 ]; then
                echo -e "${RED}本地测速失败，请检查网络${NC}"
                read -p "按回车返回..."
                return
            fi
            local_dl=$(echo "$local_result" | awk '{print $1}')
            local_ul=$(echo "$local_result" | awk '{print $2}')
            local_server=$(echo "$local_result" | cut -d' ' -f3-)
            echo "$local_dl $local_ul $local_server" > "$LOCAL_CACHE_FILE"
            evaluate_speed "本地" "$local_dl" "$local_ul" "$local_server"
        fi
    else
        echo -e "${YELLOW}第一步：测本地带宽（最近节点）...${NC}"
        local_result=$(run_speedtest "")
        local ret=$?
        if [ $ret -eq 2 ]; then
            read -p "按回车返回..."
            return
        elif [ $ret -ne 0 ]; then
            echo -e "${RED}本地测速失败，请检查网络${NC}"
            read -p "按回车返回..."
            return
        fi
        local_dl=$(echo "$local_result" | awk '{print $1}')
        local_ul=$(echo "$local_result" | awk '{print $2}')
        local_server=$(echo "$local_result" | cut -d' ' -f3-)
        echo "$local_dl $local_ul $local_server" > "$LOCAL_CACHE_FILE"
        evaluate_speed "本地" "$local_dl" "$local_ul" "$local_server"
    fi

    echo -e "${YELLOW}\n第二步：选择国内测速区域${NC}"
    local cn_node=$(select_cn_node)
    if [ -z "$cn_node" ]; then
        echo -e "${YELLOW}未选择国内节点，跳过国内测速。${NC}"
        read -p "按回车返回..."
        return
    fi

    local id=$(echo "$cn_node" | awk '{print $1}')
    local desc=$(echo "$cn_node" | cut -d' ' -f2-)

    echo -e "${YELLOW}使用节点 ID: $id (${desc})${NC}"

    local cn_result=$(run_speedtest "$id")
    local ret=$?
    if [ $ret -eq 2 ]; then
        read -p "按回车返回..."
        return
    elif [ $ret -ne 0 ]; then
        echo -e "${RED}国内测速失败，可能节点不可用或网络问题。${NC}"
        echo -e "${YELLOW}建议稍后重试或选择其他节点。${NC}"
        read -p "按回车返回..."
        return
    fi
    local cn_dl=$(echo "$cn_result" | awk '{print $1}')
    local cn_ul=$(echo "$cn_result" | awk '{print $2}')
    local cn_server=$(echo "$cn_result" | cut -d' ' -f3-)
    evaluate_speed "国内" "$cn_dl" "$cn_ul" "$cn_server"
    evaluate_combined "$local_dl" "$cn_dl" "$cn_server"
    read -p "按回车返回..."
}

# ---------- 菜单2：MTR ----------
menu_mtr() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}📡 延迟+丢包测试 (MTR) 含自动评价${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1) 沈阳联通 (202.96.69.38)"
    echo "2) 北京联通 (123.125.0.1)"
    echo "3) 上海联通 (210.22.70.3)"
    echo "4) 大连联通 (202.96.64.68)"
    echo "5) 锦州联通 (自动解析)"
    echo "6) 手动输入 IP/域名"
    read -p "请选择 [1-6]: " opt
    case $opt in
        1) target="202.96.69.38"; name="沈阳联通" ;;
        2) target="123.125.0.1"; name="北京联通" ;;
        3) target="210.22.70.3"; name="上海联通" ;;
        4) target="202.96.64.68"; name="大连联通" ;;
        5) target="ln-jinzhou-cu-v4.ip.zstaticcdn.com"; name="锦州联通" ;;
        6) target=$(get_target "请输入 IP 或域名: "); name="手动目标" ;;
        *) echo "无效" ; sleep 1 ; menu_mtr ; return ;;
    esac
    local ip=$(resolve_ip "$target")
    if [ $? -ne 0 ] || [ -z "$ip" ]; then
        echo -e "${RED}解析失败${NC}"
        read -p "按回车返回..."
        return
    fi
    echo -e "${GREEN}解析成功: $target -> $ip${NC}"
    echo -e "${YELLOW}正在 MTR ...${NC}"
    mtr -4 -r -c 20 -n "$ip" > /tmp/mtr_result
    cat /tmp/mtr_result
    local avg=$(parse_mtr "/tmp/mtr_result" | head -1)
    local loss=$(parse_mtr "/tmp/mtr_result" | tail -1)
    if [ -n "$avg" ] && [ -n "$loss" ]; then
        evaluate_latency "$name" "$avg" "$loss"
    else
        echo -e "${RED}无法获取有效数据${NC}"
    fi
    rm -f /tmp/mtr_result
    read -p "按回车返回..."
}

# ---------- 菜单3：路由追踪 ----------
menu_traceroute() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}🗺️  路由追踪 (traceroute)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1) 沈阳联通 (202.96.69.38)"
    echo "2) 北京联通 (123.125.0.1)"
    echo "3) 上海联通 (210.22.70.3)"
    echo "4) 大连联通 (202.96.64.68)"
    echo "5) 锦州联通 (自动解析)"
    echo "6) 手动输入 IP/域名"
    read -p "请选择 [1-6]: " opt
    case $opt in
        1) target="202.96.69.38"; name="沈阳联通" ;;
        2) target="123.125.0.1"; name="北京联通" ;;
        3) target="210.22.70.3"; name="上海联通" ;;
        4) target="202.96.64.68"; name="大连联通" ;;
        5) target="ln-jinzhou-cu-v4.ip.zstaticcdn.com"; name="锦州联通" ;;
        6) target=$(get_target "请输入 IP 或域名: "); name="手动目标" ;;
        *) echo "无效" ; sleep 1 ; menu_traceroute ; return ;;
    esac
    local ip=$(resolve_ip "$target")
    if [ $? -ne 0 ] || [ -z "$ip" ]; then
        echo -e "${RED}解析失败${NC}"
        read -p "按回车返回..."
        return
    fi
    echo -e "${GREEN}解析成功: $target -> $ip${NC}"
    traceroute -4 -n "$ip"
    read -p "按回车返回..."
}

# ---------- 菜单4：持续Ping ----------
menu_ping() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}🔄 持续 Ping 测试 (按 Ctrl+C 停止)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1) 沈阳联通 (202.96.69.38)"
    echo "2) 北京联通 (123.125.0.1)"
    echo "3) 上海联通 (210.22.70.3)"
    echo "4) 大连联通 (202.96.64.68)"
    echo "5) 锦州联通 (自动解析)"
    echo "6) 手动输入 IP/域名"
    read -p "请选择 [1-6]: " opt
    case $opt in
        1) target="202.96.69.38"; name="沈阳联通" ;;
        2) target="123.125.0.1"; name="北京联通" ;;
        3) target="210.22.70.3"; name="上海联通" ;;
        4) target="202.96.64.68"; name="大连联通" ;;
        5) target="ln-jinzhou-cu-v4.ip.zstaticcdn.com"; name="锦州联通" ;;
        6) target=$(get_target "请输入 IP 或域名: "); name="手动目标" ;;
        *) echo "无效" ; sleep 1 ; menu_ping ; return ;;
    esac
    local ip=$(resolve_ip "$target")
    if [ $? -ne 0 ] || [ -z "$ip" ]; then
        echo -e "${RED}解析失败${NC}"
        read -p "按回车返回..."
        return
    fi
    echo -e "${GREEN}解析成功: $target -> $ip${NC}"
    echo -e "${YELLOW}开始 ping，按 Ctrl+C 停止后自动评价${NC}"
    ping -4 "$ip" > /tmp/ping_result
    local avg=$(tail -1 /tmp/ping_result | awk -F'/' '{print $5}')
    local loss=$(grep -oP '\d+(?=% packet loss)' /tmp/ping_result)
    if [ -n "$avg" ] && [ -n "$loss" ]; then
        evaluate_latency "$name" "$avg" "$loss"
    else
        echo -e "${RED}无法获取数据${NC}"
    fi
    rm -f /tmp/ping_result
    read -p "按回车返回..."
}

# ---------- 菜单5：综合测试 ----------
menu_full() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}📊 综合测试 (测速+MTR+路由)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}1. 测速...${NC}"
    menu_speedtest
    echo -e "${YELLOW}2. MTR到锦州联通...${NC}"
    local target="ln-jinzhou-cu-v4.ip.zstaticcdn.com"
    local name="锦州联通"
    local ip=$(resolve_ip "$target")
    if [ $? -eq 0 ] && [ -n "$ip" ]; then
        mtr -4 -r -c 20 -n "$ip" > /tmp/mtr_result
        cat /tmp/mtr_result
        local avg=$(parse_mtr "/tmp/mtr_result" | head -1)
        local loss=$(parse_mtr "/tmp/mtr_result" | tail -1)
        if [ -n "$avg" ] && [ -n "$loss" ]; then
            evaluate_latency "$name" "$avg" "$loss"
        else
            echo -e "${RED}无法获取数据${NC}"
        fi
        rm -f /tmp/mtr_result
    else
        echo -e "${RED}锦州域名解析失败，跳过MTR${NC}"
    fi
    echo -e "${YELLOW}3. 路由到北京联通...${NC}"
    traceroute -4 -n 123.125.0.1
    echo -e "${GREEN}综合测试完成！${NC}"
    read -p "按回车返回..."
}

# ---------- 菜单6：卸载 ----------
menu_uninstall() {
    clear
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}⚠️  卸载脚本${NC}"
    echo -e "${RED}========================================${NC}"
    echo "即将删除："
    echo "  - /root/vps-test.sh (本脚本)"
    echo "  - /tmp/local_speed_result.txt (本地测速缓存)"
    echo "  - /root/speedtest.log (测速日志)"
    echo "  - /tmp/test.bin (临时测试文件)"
    echo "  - /root/jp2ln.sh (旧版测速脚本)"
    read -p "确认卸载？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        # 清理 cs 别名
        if [ -f ~/.bashrc ]; then
            sed -i '/# VPS test alias/d' ~/.bashrc
            sed -i "/alias cs='\/root\/vps-test.sh'/d" ~/.bashrc
        fi
        rm -f /root/vps-test.sh /root/speedtest.log /tmp/test.bin /root/jp2ln.sh /tmp/local_speed_result.txt /tmp/vps_test_deps_installed
        echo -e "${GREEN}✅ 已清理。${NC}"
        exit 0
    else
        echo -e "${GREEN}取消。${NC}"
        read -p "按回车返回..."
    fi
}

# ---------- 主菜单 ----------
main_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}  VPS 网络测试 (v20 - 完整版)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1) 带宽测速（本地+国内，自动对比）"
    echo "2) MTR 延迟/丢包 (含评价)"
    echo "3) 路由追踪"
    echo "4) 持续 Ping (含评价)"
    echo "5) 综合测试 (测速+MTR+路由)"
    echo "6) 卸载脚本"
    echo "7) 退出"
    echo -e "${YELLOW}提示: 输入 cs 可直接进入带宽测速${NC}"
    echo -e "${BLUE}========================================${NC}"
    read -p "请选择 [1-7]: " choice
    case $choice in
        1|cs|CS) menu_speedtest ;;
        2) menu_mtr ;;
        3) menu_traceroute ;;
        4) menu_ping ;;
        5) menu_full ;;
        6) menu_uninstall ;;
        7) echo "bye!" ; exit 0 ;;
        *) echo "无效" ; sleep 1 ; main_menu ;;
    esac
    main_menu
}

# ---------- 安装 cs 别名 ----------
install_alias() {
    local script_path="/root/vps-test.sh"
    if [ -f ~/.bashrc ]; then
        if ! grep -q "alias cs='${script_path}'" ~/.bashrc; then
            echo "" >> ~/.bashrc
            echo "# VPS test alias" >> ~/.bashrc
            echo "alias cs='${script_path}'" >> ~/.bashrc
            echo -e "${GREEN}已添加 cs 快捷命令，重新登录或执行 source ~/.bashrc 后生效。${NC}"
        fi
    fi
}

# ---------- 启动 ----------
check_deps
install_alias
main_menu
