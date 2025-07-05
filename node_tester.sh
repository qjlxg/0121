#!/bin/bash

# 主要的 sources.list 文件 URL
SOURCES_LIST_URL="https://raw.githubusercontent.com/qjlxg/ss/refs/heads/master/sources.list"

# 文件路径定义
ALL_NODES_FILE="data/all.txt"
PREVIOUS_NODES_FILE="data/previous_nodes.txt"
TEMP_SOURCES_LIST="data/temp_sources_list.txt"
TEMP_ALL_RAW_NODES="data/temp_all_raw_nodes.txt"
TEMP_NEW_RAW_NODES="data/temp_new_raw_nodes.txt"
TEMP_CLASH_CONFIG="data/clash_config.yaml"
TEMP_PARSED_NODES_JSON="data/parsed_nodes.json"
CLASH_LOG="data/clash.log"

# --- 配置限制 ---
MAX_NODES_FOR_CLASH_TEST=10000  # 降低最大测试节点数量

# 清理旧的临时文件
rm -rf data && mkdir -p data

echo "步骤 1: 获取主 sources 列表..."
curl -s --retry 3 --connect-timeout 10 "$SOURCES_LIST_URL" | grep -v '^#' > "$TEMP_SOURCES_LIST"

if [ ! -s "$TEMP_SOURCES_LIST" ]; then
    echo "错误: 无法获取主 sources 列表或列表为空。退出。"
    exit 1
fi

echo "步骤 2: 从子来源递归获取节点 URL..."
SUB_URL_COUNT=0
while IFS= read -r sub_url; do
    if [ -z "$sub_url" ]; then
        continue
    fi
    curl -s --retry 3 --connect-timeout 10 "$sub_url" | grep -E 'hysteria2://|vmess://|trojan://|ss://|ssr://|vless://' >> "$TEMP_ALL_RAW_NODES"
    ((SUB_URL_COUNT++))
done < "$TEMP_SOURCES_LIST"
echo "  从 $SUB_URL_COUNT 个子来源 URL 获取完成。"

if [ ! -s "$TEMP_ALL_RAW_NODES" ]; then
    echo "错误: 从子来源获取的节点 URL 为空。退出。"
    exit 1
fi

echo "步骤 3: 识别需要测试的新节点..."
if [ ! -f "$PREVIOUS_NODES_FILE" ]; then
    NEW_NODES_COUNT=$(wc -l < "$TEMP_ALL_RAW_NODES")
    cp "$TEMP_ALL_RAW_NODES" "$TEMP_NEW_RAW_NODES"
    echo "  首次运行: 发现 $NEW_NODES_COUNT 个节点，将全部测试。"
else
    sort "$PREVIOUS_NODES_FILE" > "$PREVIOUS_NODES_FILE.sorted"
    sort "$TEMP_ALL_RAW_NODES" > "$TEMP_ALL_RAW_NODES.sorted"
    comm -13 "$PREVIOUS_NODES_FILE.sorted" "$TEMP_ALL_RAW_NODES.sorted" > "$TEMP_NEW_RAW_NODES"
    NEW_NODES_COUNT=$(wc -l < "$TEMP_NEW_RAW_NODES")
    echo "  发现 $NEW_NODES_COUNT 个新节点。"
fi

cp "$TEMP_ALL_RAW_NODES" "$PREVIOUS_NODES_FILE"
rm -f "$PREVIOUS_NODES_FILE.sorted" "$TEMP_ALL_RAW_NODES.sorted"

if [ "$NEW_NODES_COUNT" -eq 0 ]; then
    echo "没有新节点需要测试。退出。"
    exit 0
fi

echo "步骤 4: 执行初始 URL 格式检查并解析为 Clash 格式..."
PARSE_RESULT=$(./convert_nodes.py "$TEMP_NEW_RAW_NODES" "$TEMP_PARSED_NODES_JSON")
echo "$PARSE_RESULT"

if [ ! -s "$TEMP_PARSED_NODES_JSON" ]; then
    echo "没有成功解析的节点。退出。"
    exit 0
fi

PARSED_NODES_COUNT=$(jq '. | length' "$TEMP_PARSED_NODES_JSON")
echo "  成功解析 $PARSED_NODES_COUNT 个节点。"

NODES_TO_TEST_COUNT=$PARSED_NODES_COUNT
if [ "$PARSED_NODES_COUNT" -gt "$MAX_NODES_FOR_CLASH_TEST" ]; then
    NODES_TO_TEST_COUNT="$MAX_NODES_FOR_CLASH_TEST"
    echo "  限制 Clash 测试的前 $MAX_NODES_FOR_CLASH_TEST 个节点。"
    jq ".[0:$MAX_NODES_FOR_CLASH_TEST]" "$TEMP_PARSED_NODES_JSON" > "$TEMP_PARSED_NODES_JSON.limited"
    mv "$TEMP_PARSED_NODES_JSON.limited" "$TEMP_PARSED_NODES_JSON"
fi

echo "步骤 5: 准备 Clash 配置文件以进行并行测试..."
cat << EOF > "$TEMP_CLASH_CONFIG"
port: 7890
socks-port: 7891
mode: rule
log-level: debug
allow-lan: false
external-controller: 127.0.0.1:9090
secret: ""

proxies:
EOF

python3 -c '
import sys, json, yaml
input_json_file = sys.argv[1]
output_yaml_file = sys.argv[2]
with open(input_json_file, "r", encoding="utf-8") as f:
    proxies_list = json.load(f)
with open(output_yaml_file, "a", encoding="utf-8") as f:
    yaml.dump(proxies_list, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
' "$TEMP_PARSED_NODES_JSON" "$TEMP_CLASH_CONFIG"

echo "proxy-groups:" >> "$TEMP_CLASH_CONFIG"
echo "  - name: 'auto-test'" >> "$TEMP_CLASH_CONFIG"
echo "    type: url-test" >> "$TEMP_CLASH_CONFIG"
echo "    url: https://www.google.com/generate_204" >> "$TEMP_CLASH_CONFIG"
echo "    interval: 300" >> "$TEMP_CLASH_CONFIG"
echo "    proxies:" >> "$TEMP_CLASH_CONFIG"

python3 -c '
import yaml, sys
with open(sys.argv[1], "r") as f:
    config = yaml.safe_load(f)
proxy_names = [proxy["name"] for proxy in config.get("proxies", []) if isinstance(proxy, dict) and "name" in proxy]
with open(sys.argv[1], "a") as f:
    for name in proxy_names:
        f.write(f"      - \"{name}\"\n")
' "$TEMP_CLASH_CONFIG"

echo "步骤 6: 运行 Clash 进行连接测试..."
./clash -f "$TEMP_CLASH_CONFIG" -d . > "$CLASH_LOG" 2>&1 &
CLASH_PID=$!
echo "  Clash 已启动，PID: $CLASH_PID。等待加载..."

# 等待 Clash 启动并检查 API 可用性
sleep 15
if ! ps -p $CLASH_PID > /dev/null; then
    echo "错误: Clash 启动失败，查看日志 $CLASH_LOG。"
    cat "$CLASH_LOG"
    exit 1
fi

# 检查 Clash API 是否可用
if ! curl -s --connect-timeout 5 "http://127.0.0.1:9090/proxies" > /dev/null; then
    echo "错误: Clash API (127.0.0.1:9090) 不可用，查看日志 $CLASH_LOG。"
    cat "$CLASH_LOG"
    exit 1
fi

echo "  Clash 加载完成，开始测试..."
./test_clash_api.py "$ALL_NODES_FILE"

kill $CLASH_PID 2>/dev/null
echo "Clash 已停止。"

echo "步骤 7: 保存 Clash 测试结果到 $ALL_NODES_FILE。"
echo "节点测试和更新过程已完成。详细测试结果已保存到 $ALL_NODES_FILE"
