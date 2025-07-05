#!/bin/bash

# 主要的 sources.list 文件 URL
SOURCES_LIST_URL="https://raw.githubusercontent.com/qjlxg/ss/refs/heads/master/sources.list"

# 文件路径定义
ALL_NODES_FILE="data/all.txt"                  # 最终 Clash 测试通过的节点
PREVIOUS_NODES_FILE="data/previous_nodes.txt"  # 上次测试的所有节点，用于增量比较
TEMP_SOURCES_LIST="data/temp_sources_list.txt" # 从 SOURCES_LIST_URL 下载的列表
TEMP_ALL_RAW_NODES="data/temp_all_raw_nodes.txt" # 从所有子 URL 合并得到的原始节点列表
TEMP_NEW_RAW_NODES="data/temp_new_raw_nodes.txt" # 新发现的原始节点，待测试
TEMP_SIMPLE_TEST_PASS="data/temp_simple_test_pass.txt" # 简单测试通过的节点
TEMP_CLASH_CONFIG="data/clash_config.yaml"     # 生成的 Clash 配置文件

# 清理旧的临时文件，确保每次运行都是干净的状态
rm -f "$TEMP_SOURCES_LIST" "$TEMP_ALL_RAW_NODES" "$TEMP_NEW_RAW_NODES" "$TEMP_SIMPLE_TEST_PASS" "$TEMP_CLASH_CONFIG"

echo "Step 1: Fetching main sources list..."
curl -s "$SOURCES_LIST_URL" | grep -v '^#' > "$TEMP_SOURCES_LIST"

if [ ! -s "$TEMP_SOURCES_LIST" ]; then
    echo "Error: Could not fetch main sources list or it is empty. Exiting."
    exit 1
fi

echo "Step 2: Recursively fetching node URLs from sub-sources..."
SUB_URL_COUNT=0
while IFS= read -r sub_url; do
    if [ -z "$sub_url" ]; then
        continue
    fi
    curl -s "$sub_url" | grep -E 'hysteria2://|vmess://|trojan://|ss://|ssr://|vless://' >> "$TEMP_ALL_RAW_NODES"
    ((SUB_URL_COUNT++))
done < "$TEMP_SOURCES_LIST"
echo "  Finished fetching from $SUB_URL_COUNT sub-source URLs."

if [ ! -s "$TEMP_ALL_RAW_NODES" ]; then
    echo "Error: No node URLs found after fetching all sub-sources. Exiting."
    exit 1
fi

echo "Step 3: Identifying new nodes for testing..."
if [ ! -f "$PREVIOUS_NODES_FILE" ]; then
    NEW_NODES_COUNT=$(wc -l < "$TEMP_ALL_RAW_NODES")
    cp "$TEMP_ALL_RAW_NODES" "$TEMP_NEW_RAW_NODES"
    echo "  First run: Found $NEW_NODES_COUNT total nodes. All will be tested."
else
    sort "$PREVIOUS_NODES_FILE" > "$PREVIOUS_NODES_FILE.sorted"
    sort "$TEMP_ALL_RAW_NODES" > "$TEMP_ALL_RAW_NODES.sorted"
    
    comm -13 "$PREVIOUS_NODES_FILE.sorted" "$TEMP_ALL_RAW_NODES.sorted" > "$TEMP_NEW_RAW_NODES"
    
    NEW_NODES_COUNT=$(wc -l < "$TEMP_NEW_RAW_NODES")
    echo "  Found $NEW_NODES_COUNT new nodes."
fi

cp "$TEMP_ALL_RAW_NODES" "$PREVIOUS_NODES_FILE"

if [ "$NEW_NODES_COUNT" -eq 0 ]; then
    echo "No new nodes to test. Exiting."
    exit 0
fi

echo "Step 4: Performing simple connectivity test on new nodes..."
grep -E 'hysteria2://|vmess://|trojan://|ss://|ssr://|vless://' "$TEMP_NEW_RAW_NODES" > "$TEMP_SIMPLE_TEST_PASS"

if [ ! -s "$TEMP_SIMPLE_TEST_PASS" ]; then
    echo "No new nodes passed the simple test. Exiting."
    exit 0
fi
echo "  $(wc -l < "$TEMP_SIMPLE_TEST_PASS") nodes passed simple test and will be forwarded to Clash."

echo "Step 5: Preparing Clash configuration for parallel testing..."
cat << EOF > "$TEMP_CLASH_CONFIG"
port: 7890
sock-port: 7891
mode: rule
log-level: info
allow-lan: false
external-controller: 127.0.0.1:9090 # Clash Dashboard 端口
secret: "" # 可选的Clash外部控制器密码

proxies:
EOF

# --- 调用外部 Python 脚本来转换节点 ---
./convert_nodes.py "$TEMP_SIMPLE_TEST_PASS" "$TEMP_CLASH_CONFIG"

# 添加一个 proxy-group 用于同时测试所有节点
echo "proxy-groups:" >> "$TEMP_CLASH_CONFIG"
echo "  - name: 'auto-test'" >> "$TEMP_CLASH_CONFIG"
echo "    type: url-test" >> "$TEMP_CLASH_CONFIG"
echo "    url: http://www.google.com/generate_204" # 测试URL
echo "    interval: 300" # 测试间隔，秒
echo "    proxies:" >> "$TEMP_CLASH_CONFIG"

# 动态添加所有代理的名称到 proxy-group 中
# 同样使用外部 Python 脚本，以避免 Bash 语法问题
python3 -c '
import yaml
import sys

with open(sys.argv[1], "r") as f:
    config = yaml.safe_load(f)

proxy_names = [proxy["name"] for proxy in config.get("proxies", [])]

with open(sys.argv[1], "a") as f:
    for name in proxy_names:
        f.write(f"      - \"{name}\"\n")
' "$TEMP_CLASH_CONFIG"


echo "Step 6: Running Clash for connectivity testing in parallel..."
./clash -f "$TEMP_CLASH_CONFIG" -d . &
CLASH_PID=$!
echo "  Clash started with PID: $CLASH_PID. Waiting for it to load..."

sleep 10 

# --- 调用外部 Python 脚本进行 Clash API 测试 ---
./test_clash_api.py "$ALL_NODES_FILE"

kill $CLASH_PID
echo "Clash stopped."

echo "Step 7: Saving Clash test results to $ALL_NODES_FILE."
echo "节点测试和更新过程已完成。详细测试结果已保存到 $ALL_NODES_FILE"
