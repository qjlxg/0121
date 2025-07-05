#!/bin/bash

# --- 文件路径定义 ---
INPUT_NODES="data/temp_all_raw_nodes.txt"
OUTPUT_NODES="data/filtered_nodes.txt"
LOG_FILE="data/prefilter_nodes.log"
TEMP_CHECK_FILE="data/temp_check_nodes.txt"

# --- 配置限制 ---
MAX_WORKERS=50 # 并行检查的最大进程数
PING_TIMEOUT=2 # ping 超时时间（秒）
CURL_TIMEOUT=3 # curl 超时时间（秒）

# 初始化
mkdir -p data
rm -f "$OUTPUT_NODES" "$TEMP_CHECK_FILE" "$LOG_FILE"
touch "$OUTPUT_NODES" "$LOG_FILE"

echo "开始预过滤节点: $(date)" >> "$LOG_FILE"
if [ ! -f "$INPUT_NODES" ] || [ ! -s "$INPUT_NODES" ]; then
    echo "错误: 输入文件 $INPUT_NODES 不存在或为空。" | tee -a "$LOG_FILE"
    exit 1
fi

TOTAL_NODES=$(wc -l < "$INPUT_NODES")
echo "发现 $TOTAL_NODES 个节点需要过滤..." | tee -a "$LOG_FILE"

# 检查主机可达性函数
check_node() {
    local node_url="$1"
    local output_file="$2"
    if [[ "$node_url" =~ ^(hysteria2|vmess|trojan|ss|ssr|vless):// ]]; then
        host=$(echo "$node_url" | grep -oP '(?<=://)[^:/]+')
        if [ -n "$host" ]; then
            if ping -c 1 -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1 || curl -s --connect-timeout "$CURL_TIMEOUT" "http://$host" > /dev/null 2>&1; then
                echo "$node_url" >> "$output_file"
                echo "$node_url: passed" >> "$LOG_FILE"
            else
                echo "$node_url: failed (unreachable)" >> "$LOG_FILE"
            fi
        else
            echo "$node_url: failed (invalid host)" >> "$LOG_FILE"
        fi
    else
        echo "$node_url: failed (invalid format)" >> "$LOG_FILE"
    fi
}

# 导出函数以供并行使用
export -f check_node
export PING_TIMEOUT CURL_TIMEOUT

# 并行检查节点
echo "开始并行检查节点（最大 $MAX_WORKERS 进程）..." | tee -a "$LOG_FILE"
cat "$INPUT_NODES" | xargs -n 1 -P "$MAX_WORKERS" -I {} bash -c 'check_node "{}" "$TEMP_CHECK_FILE"'
if [ -f "$TEMP_CHECK_FILE" ]; then
    mv "$TEMP_CHECK_FILE" "$OUTPUT_NODES"
fi

FILTERED_NODES_COUNT=$(wc -l < "$OUTPUT_NODES" 2>/dev/null || echo 0)
echo "过滤完成: $FILTERED_NODES_COUNT 个节点通过预过滤，保存到 $OUTPUT_NODES。" | tee -a "$LOG_FILE"
echo "详细日志: $LOG_FILE"
if [ "$FILTERED_NODES_COUNT" -eq 0 ]; then
    echo "错误: 没有节点通过预过滤，退出。" | tee -a "$LOG_FILE"
    exit 1
fi

echo "预过滤结束: $(date)" >> "$LOG_FILE"
