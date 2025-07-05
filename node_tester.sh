#!/bin/bash

# --- 文件路径定义 ---
SOURCES_LIST_URL="https://raw.githubusercontent.com/qjlxg/ss/refs/heads/master/sources.list"
ALL_NODES_FILE="data/all.txt"
PREVIOUS_NODES_FILE="data/previous_nodes.txt"
TEMP_SOURCES_LIST="data/temp_sources_list.txt"
TEMP_ALL_RAW_NODES="data/temp_all_raw_nodes.txt"
TEMP_NEW_RAW_NODES="data/temp_new_raw_nodes.txt"
TEMP_PARSED_NODES_JSON="data/parsed_nodes.json"
TEMP_CLASH_CONFIG="data/clash_config_batch.yaml"
FINAL_CLASH_CONFIG="data/clash_config.yaml"
CLASH_LOG="data/clash.log"
ALL_PASSED_NODES_JSON="data/passed_nodes.json"

# --- 配置限制 ---
MAX_NODES_FOR_CLASH_TEST=5000
BATCH_SIZE=500

# 清理遗留文件并初始化
mkdir -p data clash
rm -rf data/temp_*.txt data/batch_*.json data/batch_all_*.txt
touch "$ALL_NODES_FILE" "$ALL_PASSED_NODES_JSON"

echo "步骤 1: 获取主 sources 列表..."
curl -s --retry 3 --connect-timeout 10 "$SOURCES_LIST_URL" | grep -v '^#' > "$TEMP_SOURCES_LIST"

if [ ! -s "$TEMP_SOURCES_LIST" ]; then
    echo "错误: 无法获取主 sources 列表或列表为空。退出。"
    exit 1
fi

echo "步骤 2: 从子来源获取节点 URL..."
SUB_URL_COUNT=0
while IFS= read -r sub_url; do
    if [ -z "$sub_url" ]; then
        continue
    fi
    curl -s --retry 3 --connect-timeout 10 "$sub_url" | grep -E 'hysteria2://|vmess://|trojan://|ss://|ssr://|vless://' >> "$TEMP_ALL_RAW_NODES"
    ((SUB_URL_COUNT++))
done < "$TEMP_SOURCES_LIST"
echo "  从 $SUB_URL_COUNT 个子来源获取完成。"

if [ ! -s "$TEMP_ALL_RAW_NODES" ]; then
    echo "错误: 从子来源获取的节点 URL 为空。退出。"
    exit 1
fi

echo "步骤 3: 识别新节点..."
if [ ! -f "$PREVIOUS_NODES_FILE" ]; then
    NEW_NODES_COUNT=$(wc -l < "$TEMP_ALL_RAW_NODES")
    cp "$TEMP_ALL_RAW_NODES" "$TEMP_NEW_RAW_NODES"
    echo "  首次运行: 发现 $NEW_NODES_COUNT 个节点。"
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

echo "步骤 4: 解析节点为 Clash 格式..."
PARSE_RESULT=$(./convert_nodes.py "$TEMP_NEW_RAW_NODES" "$TEMP_PARSED_NODES_JSON")
echo "$PARSE_RESULT"

if [ ! -s "$TEMP_PARSED_NODES_JSON" ]; then
    echo "没有成功解析的节点。退出。"
    exit 0
fi

PARSED_NODES_COUNT=$(jq '. | length' "$TEMP_PARSED_NODES_JSON")
echo "  成功解析 $PARSED_NODES_COUNT 个节点。"

# 限制总测试节点数量
NODES_TO_TEST_COUNT=$PARSED_NODES_COUNT
if [ "$PARSED_NODES_COUNT" -gt "$MAX_NODES_FOR_CLASH_TEST" ]; then
    NODES_TO_TEST_COUNT="$MAX_NODES_FOR_CLASH_TEST"
    echo "  限制测试前 $MAX_NODES_FOR_CLASH_TEST 个节点。"
    jq ".[0:$MAX_NODES_FOR_CLASH_TEST]" "$TEMP_PARSED_NODES_JSON" > "$TEMP_PARSED_NODES_JSON.limited"
    mv "$TEMP_PARSED_NODES_JSON.limited" "$TEMP_PARSED_NODES_JSON"
fi

echo "步骤 5: 分批测试节点..."
BATCH_COUNT=$(( (NODES_TO_TEST_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))
echo "[]" > "$ALL_PASSED_NODES_JSON"

for ((i=0; i<BATCH_COUNT; i++)); do
    echo "  处理批次 $((i+1))/$BATCH_COUNT..."
    START=$((i * BATCH_SIZE))
    END=$((START + BATCH_SIZE))
    if [ $END -gt $NODES_TO_TEST_COUNT ]; then
        END=$NODES_TO_TEST_COUNT
    fi

    # 生成批次节点 JSON
    jq ".[$START:$END]" "$TEMP_PARSED_NODES_JSON" > "data/batch_$i.json"

    # 生成批次 Clash 配置文件
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
' "data/batch_$i.json" "$TEMP_CLASH_CONFIG"

    echo "proxy-groups:" >> "$TEMP_CLASH_CONFIG"
    echo "  - name: 'auto-test'" >> "$TEMP_CLASH_CONFIG"
    echo "    type: url-test" >> "$TEMP_CLASH_CONFIG"
    echo "    interval: 300" >> "$TEMP_CLASH_CONFIG"
    if jq -e '.[] | select(.type == "trojan" or .type == "vless")' "data/batch_$i.json" > /dev/null; then
        echo "    url: https://www.google.com/generate_204" >> "$TEMP_CLASH_CONFIG"
    else
        echo "    url: http://www.google.com/generate_204" >> "$TEMP_CLASH_CONFIG"
    fi
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

    echo "  运行 Clash 测试批次 $((i+1))..."
    ./clash/clash -f "$TEMP_CLASH_CONFIG" -d . > "$CLASH_LOG" 2>&1 &
    CLASH_PID=$!
    sleep 15
    if ! ps -p $CLASH_PID > /dev/null; then
        echo "错误: Clash 启动失败，查看 $CLASH_LOG。继续下一批次。"
        cat "$CLASH_LOG"
        # 清理批次临时文件
        rm -f "data/batch_$i.json" "$TEMP_CLASH_CONFIG"
        # 提交当前成果
        git config user.name 'github-actions[bot]'
        git config user.email 'github-actions[bot]@users.noreply.github.com'
        git add data/parsed_nodes.json data/passed_nodes.json data/all.txt data/clash.log data/convert_nodes.log data/test_clash_api.log data/previous_nodes.txt
        git commit -m "Save batch $((i+1)) results despite Clash failure" || echo "无中间结果需要提交"
        git push || {
            echo "错误: git push 失败，查看远程仓库状态："
            git status
            git log --oneline -n 5
            exit 1
        }
        continue
    fi

    if ! curl -s --connect-timeout 5 "http://127.0.0.1:9090/proxies" > /dev/null; then
        echo "错误: Clash API (127.0.0.1:9090) 不可用，查看 $CLASH_LOG。继续下一批次。"
        cat "$CLASH_LOG"
        kill $CLASH_PID 2>/dev/null
        # 清理批次临时文件
        rm -f "data/batch_$i.json" "$TEMP_CLASH_CONFIG"
        # 提交当前成果
        git config user.name 'github-actions[bot]'
        git config user.email 'github-actions[bot]@users.noreply.github.com'
        git add data/parsed_nodes.json data/passed_nodes.json data/all.txt data/clash.log data/convert_nodes.log data/test_clash_api.log data/previous_nodes.txt
        git commit -m "Save batch $((i+1)) results despite Clash API failure" || echo "无中间结果需要提交"
        git push || {
            echo "错误: git push 失败，查看远程仓库状态："
            git status
            git log --oneline -n 5
            exit 1
        }
        continue
    fi

    BATCH_ALL_NODES_FILE="data/batch_all_$i.txt"
    ./test_clash_api.py "$BATCH_ALL_NODES_FILE"

    kill $CLASH_PID 2>/dev/null

    # 合并测试通过的节点
    python3 -c '
import sys, json
passed_nodes_file = sys.argv[1]
all_nodes_json = sys.argv[2]
batch_json = sys.argv[3]
with open(passed_nodes_file, "r", encoding="utf-8") as f:
    passed = {line.split(":")[0].strip(): True for line in f if ": timeout" not in line and ": error" not in line}
with open(batch_json, "r", encoding="utf-8") as f:
    batch_nodes = json.load(f)
with open(all_nodes_json, "r", encoding="utf-8") as f:
    all_nodes = json.load(f)
all_nodes.extend([node for node in batch_nodes if node["name"] in passed])
with open(all_nodes_json, "w", encoding="utf-8") as f:
    json.dump(all_nodes, f, indent=2, ensure_ascii=False)
' "$BATCH_ALL_NODES_FILE" "$ALL_PASSED_NODES_JSON" "data/batch_$i.json"

    # 追加通过节点到 data/all.txt
    python3 -c '
import sys, json
with open(sys.argv[1], "r", encoding="utf-8") as f:
    passed = {line.split(":")[0].strip(): True for line in f if ": timeout" not in line and ": error" not in line}
with open(sys.argv[2], "r", encoding="utf-8") as f:
    batch_nodes = json.load(f)
with open(sys.argv[3], "a", encoding="utf-8") as f:
    for node in batch_nodes:
        if node["name"] in passed:
            f.write(f"{node['name']}: passed\n")
' "$BATCH_ALL_NODES_FILE" "data/batch_$i.json" "$ALL_NODES_FILE"

    # 验证文件存在
    if [ -s "$ALL_PASSED_NODES_JSON" ]; then
        echo "  批次 $((i+1)) 通过节点已保存到 $ALL_PASSED_NODES_JSON 和 $ALL_NODES_FILE。"
    else
        echo "  警告: 批次 $((i+1)) 无通过节点，$ALL_PASSED_NODES_JSON 可能为空。"
    fi

    # 提交批次结果
    git config user.name 'github-actions[bot]'
    git config user.email 'github-actions[bot]@users.noreply.github.com'
    git add data/parsed_nodes.json data/passed_nodes.json data/all.txt data/clash.log data/convert_nodes.log data/test_clash_api.log data/previous_nodes.txt
    git commit -m "Save batch $((i+1)) results" || echo "无中间结果需要提交"
    git push || {
        echo "错误: git push 失败，查看远程仓库状态："
        git status
        git log --oneline -n 5
        exit 1
    }

    # 清理批次临时文件
    rm -f "data/batch_$i.json" "$BATCH_ALL_NODES_FILE" "$TEMP_CLASH_CONFIG"
done

echo "步骤 6: 生成最终 Clash 配置文件..."
if [ ! -s "$ALL_PASSED_NODES_JSON" ]; then
    echo "没有测试通过的节点，跳过生成 $FINAL_CLASH_CONFIG。"
    exit 0
fi

PASSED_NODES_COUNT=$(jq '. | length' "$ALL_PASSED_NODES_JSON")
echo "  共 $PASSED_NODES_COUNT 个节点通过测试。"

cat << EOF > "$FINAL_CLASH_CONFIG"
port: 7890
socks-port: 7891
mode: rule
log-level: info
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
' "$ALL_PASSED_NODES_JSON" "$FINAL_CLASH_CONFIG" || {
    echo "错误: 无法生成 proxies 部分，查看 $ALL_PASSED_NODES_JSON 是否有效。"
    exit 1
}

echo "proxy-groups:" >> "$FINAL_CLASH_CONFIG"
echo "  - name: 'auto-test'" >> "$FINAL_CLASH_CONFIG"
echo "    type: url-test" >> "$FINAL_CLASH_CONFIG"
echo "    url: https://www.google.com/generate_204" >> "$FINAL_CLASH_CONFIG"
echo "    interval: 300" >> "$FINAL_CLASH_CONFIG"
echo "    proxies:" >> "$FINAL_CLASH_CONFIG"

python3 -c '
import yaml, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    config = yaml.safe_load(f)
proxy_names = [proxy["name"] for proxy in config.get("proxies", []) if isinstance(proxy, dict) and "name" in proxy]
with open(sys.argv[1], "a", encoding="utf-8") as f:
    for name in proxy_names:
        f.write(f"      - \"{name}\"\n")
' "$FINAL_CLASH_CONFIG" || {
    echo "错误: 无法生成 proxy-groups 部分，查看 $FINAL_CLASH_CONFIG 是否有效。"
    exit 1
}

echo "节点测试完成，$PASSED_NODES_COUNT 个节点保存到 $FINAL_CLASH_CONFIG 和 $ALL_NODES_FILE。"
