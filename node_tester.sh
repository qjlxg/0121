#!/bin/bash
# node_tester.sh
# 完整版节点测试脚本：处理 587 个子来源 (~1755883 节点，过滤后 ~1500000，通过率 0.4% ~6000)
# 使用 data/backup_sources.list，生成 data/clash_config.yaml，适配 GitHub Actions

# --- 文件路径定义 ---
BACKUP_SOURCES_LIST="data/backup_sources.list"
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
FILTERED_NODES="data/filtered_nodes.txt"
FAILED_SUB_URLS="data/failed_sub_urls.txt"
TEMP_DIR="data/temp"

# --- 配置限制 ---
MAX_NODES_PER_ROUND=10000
BATCH_SIZE=200
MAX_BATCH_FILES=10
MAX_CONCURRENT_SUB=20  # 并行拉取子来源的最大并发数

# 初始化并清理临时文件
mkdir -p data clash "$TEMP_DIR"
rm -rf "$TEMP_DIR"/temp_*.txt "$TEMP_DIR"/batch_*.json "$TEMP_DIR"/batch_all_*.txt "$TEMP_DIR"/clash_config_batch_*.yaml
touch "$ALL_NODES_FILE" "$ALL_PASSED_NODES_JSON" "$FAILED_SUB_URLS"
echo "开始节点测试: $(date)" > "$CLASH_LOG"

# 检查磁盘空间
AVAILABLE_SPACE=$(df -k . | tail -1 | awk '{print $4}')
if [ "$AVAILABLE_SPACE" -lt 1000000 ]; then  # 少于 1GB
  echo "错误: 磁盘空间不足，仅剩 ${AVAILABLE_SPACE}KB" | tee -a "$CLASH_LOG"
  exit 1
fi

# 步骤 1: 检查 backup_sources.list
echo "步骤 1: 检查本地 sources 列表..." | tee -a "$CLASH_LOG"
if [ ! -s "$BACKUP_SOURCES_LIST" ]; then
  echo "错误: $BACKUP_SOURCES_LIST 不存在或为空。退出。" | tee -a "$CLASH_LOG"
  exit 1
fi
SUB_URL_COUNT=$(grep -v '^#' "$BACKUP_SOURCES_LIST" | grep -v '^$' | wc -l)
echo "  找到 $SUB_URL_COUNT 个子来源 URL。" | tee -a "$CLASH_LOG"

# 步骤 2: 并行拉取节点 URL
echo "步骤 2: 从子来源并行获取节点 URL..." | tee -a "$CLASH_LOG"
grep -v '^#' "$BACKUP_SOURCES_LIST" | grep -v '^$' | xargs -n 1 -P "$MAX_CONCURRENT_SUB" -I {} bash -c '
  echo "拉取 {} ..." >> "'"$CLASH_LOG"'"
  nodes=$(curl -s --retry 3 --connect-timeout 10 "{}" | grep -E "^(hysteria2|vmess|trojan|ss|ssr|vless)://")
  if [ -n "$nodes" ]; then
    echo "$nodes" >> "'"$TEMP_ALL_RAW_NODES"'"
    echo "成功从 {} 获取 $(echo "$nodes" | wc -l) 个节点" >> "'"$CLASH_LOG"'"
  else
    echo "失败: {} 无节点或无法访问" >> "'"$CLASH_LOG"'"
    echo "{}" >> "'"$FAILED_SUB_URLS"'"
  fi
'
if [ ! -s "$TEMP_ALL_RAW_NODES" ]; then
  echo "错误: 从子来源获取的节点 URL 为空。退出。" | tee -a "$CLASH_LOG"
  exit 1
fi
RAW_NODES_COUNT=$(wc -l < "$TEMP_ALL_RAW_NODES")
echo "  从 $SUB_URL_COUNT 个子来源获取 $RAW_NODES_COUNT 个原始节点。" | tee -a "$CLASH_LOG"

# 步骤 3: 运行预过滤模块
echo "步骤 3: 运行预过滤模块..." | tee -a "$CLASH_LOG"
bash prefilter_nodes.sh
if [ ! -s "$FILTERED_NODES" ]; then
  echo "错误: 预过滤后无有效节点，退出。" | tee -a "$CLASH_LOG"
  exit 1
fi
FILTERED_NODES_COUNT=$(wc -l < "$FILTERED_NODES")
echo "  预过滤后剩余 $FILTERED_NODES_COUNT 个节点。" | tee -a "$CLASH_LOG"

# 步骤 4: 识别新节点
echo "步骤 4: 识别新节点..." | tee -a "$CLASH_LOG"
if [ ! -f "$PREVIOUS_NODES_FILE" ]; then
  NEW_NODES_COUNT=$FILTERED_NODES_COUNT
  cp "$FILTERED_NODES" "$TEMP_NEW_RAW_NODES"
  echo "  首次运行: 发现 $NEW_NODES_COUNT 个节点。" | tee -a "$CLASH_LOG"
else
  sort "$PREVIOUS_NODES_FILE" > "$TEMP_DIR/previous_nodes.sorted"
  sort "$FILTERED_NODES" > "$TEMP_DIR/filtered_nodes.sorted"
  comm -13 "$TEMP_DIR/previous_nodes.sorted" "$TEMP_DIR/filtered_nodes.sorted" > "$TEMP_NEW_RAW_NODES"
  NEW_NODES_COUNT=$(wc -l < "$TEMP_NEW_RAW_NODES")
  echo "  发现 $NEW_NODES_COUNT 个新节点。" | tee -a "$CLASH_LOG"
fi
cp "$FILTERED_NODES" "$PREVIOUS_NODES_FILE"
rm -f "$TEMP_DIR/previous_nodes.sorted" "$TEMP_DIR/filtered_nodes.sorted"

if [ "$NEW_NODES_COUNT" -eq 0 ]; then
  echo "没有新节点需要测试。退出。" | tee -a "$CLASH_LOG"
  exit 0
fi

# 步骤 5: 解析节点为 Clash 格式
echo "步骤 5: 解析节点为 Clash 格式..." | tee -a "$CLASH_LOG"
PARSE_RESULT=$(python3 convert_nodes.py "$TEMP_NEW_RAW_NODES" "$TEMP_PARSED_NODES_JSON" 2>&1)
echo "$PARSE_RESULT" | tee -a "$CLASH_LOG"
if [ ! -s "$TEMP_PARSED_NODES_JSON" ]; then
  echo "没有成功解析的节点。退出。" | tee -a "$CLASH_LOG"
  exit 0
fi
PARSED_NODES_COUNT=$(jq '. | length' "$TEMP_PARSED_NODES_JSON")
echo "  成功解析 $PARSED_NODES_COUNT 个节点。" | tee -a "$CLASH_LOG"

# 分轮测试
TOTAL_ROUNDS=$(( (PARSED_NODES_COUNT + MAX_NODES_PER_ROUND - 1) / MAX_NODES_PER_ROUND ))
echo "将分 $TOTAL_ROUNDS 轮测试，每轮最多 $MAX_NODES_PER_ROUND 个节点。" | tee -a "$CLASH_LOG"

for ((round=0; round<TOTAL_ROUNDS; round++)); do
  echo "处理第 $((round+1))/$TOTAL_ROUNDS 轮..." | tee -a "$CLASH_LOG"
  ROUND_START=$((round * MAX_NODES_PER_ROUND))
  ROUND_END=$((ROUND_START + MAX_NODES_PER_ROUND))
  if [ $ROUND_END -gt $PARSED_NODES_COUNT ]; then
    ROUND_END=$PARSED_NODES_COUNT
  fi
  NODES_TO_TEST_COUNT=$((ROUND_END - ROUND_START))

  # 提取本轮节点
  jq ".[$ROUND_START:$ROUND_END]" "$TEMP_PARSED_NODES_JSON" > "$TEMP_DIR/parsed_nodes_round.json"
  mv "$TEMP_DIR/parsed_nodes_round.json" "$TEMP_PARSED_NODES_JSON"

  echo "  本轮测试 $NODES_TO_TEST_COUNT 个节点..." | tee -a "$CLASH_LOG"
  BATCH_COUNT=$(( (NODES_TO_TEST_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))

  for ((i=0; i<BATCH_COUNT; i++)); do
    echo "  处理批次 $((i+1))/$BATCH_COUNT..." | tee -a "$CLASH_LOG"
    START=$((i * BATCH_SIZE))
    END=$((START + BATCH_SIZE))
    if [ $END -gt $NODES_TO_TEST_COUNT ]; then
      END=$NODES_TO_TEST_COUNT
    fi

    # 生成批次节点 JSON
    jq ".[$START:$END]" "$TEMP_PARSED_NODES_JSON" > "$TEMP_DIR/batch_$i.json"

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
    yaml.dump(proxies_list if proxies_list else [], f, allow_unicode=True, default_flow_style=False, sort_keys=False)
' "$TEMP_DIR/batch_$i.json" "$TEMP_CLASH_CONFIG"

    echo "proxy-groups:" >> "$TEMP_CLASH_CONFIG"
    echo "  - name: 'auto-test'" >> "$TEMP_CLASH_CONFIG"
    echo "    type: url-test" >> "$TEMP_CLASH_CONFIG"
    echo "    interval: 300" >> "$TEMP_CLASH_CONFIG"
    if jq -e '.[] | select(.type == "trojan" or .type == "vless")' "$TEMP_DIR/batch_$i.json" > /dev/null; then
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

    # 保存批次配置文件供调试
    cp "$TEMP_CLASH_CONFIG" "$TEMP_DIR/clash_config_batch_$i.yaml"

    echo "  运行 Clash 测试批次 $((i+1))..." | tee -a "$CLASH_LOG"
    ./clash/clash -f "$TEMP_CLASH_CONFIG" -d . > "$CLASH_LOG" 2>&1 &
    CLASH_PID=$!
    sleep 15
    if ! ps -p $CLASH_PID > /dev/null; then
      echo "错误: Clash 启动失败，查看 $CLASH_LOG。继续下一批次。" | tee -a "$CLASH_LOG"
      cat "$CLASH_LOG"
      continue
    fi

    if ! curl -s --connect-timeout 5 "http://127.0.0.1:9090/proxies" > /dev/null; then
      echo "错误: Clash API (127.0.0.1:9090) 不可用，查看 $CLASH_LOG。继续下一批次。" | tee -a "$CLASH_LOG"
      cat "$CLASH_LOG"
      kill $CLASH_PID 2>/dev/null
      continue
    fi

    BATCH_ALL_NODES_FILE="$TEMP_DIR/batch_all_$i.txt"
    python3 test_clash_api.py "$BATCH_ALL_NODES_FILE" 2>&1 | tee -a "$CLASH_LOG"

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
    all_nodes = json.load(f) if f.read(1) else []
all_nodes.extend([node for node in batch_nodes if node["name"] in passed])
with open(all_nodes_json, "w", encoding="utf-8") as f:
    json.dump(all_nodes, f, indent=2, ensure_ascii=False)
' "$BATCH_ALL_NODES_FILE" "$ALL_PASSED_NODES_JSON" "$TEMP_DIR/batch_$i.json"

    # 追加通过节点到 data/all.txt
    python3 -c '
import sys, json
passed_nodes_file = sys.argv[1]
batch_json = sys.argv[2]
all_nodes_file = sys.argv[3]
try:
    with open(passed_nodes_file, "r", encoding="utf-8") as f:
        passed = {line.split(":")[0].strip(): True for line in f if ": timeout" not in line and ": error" not in line}
    with open(batch_json, "r", encoding="utf-8") as f:
        batch_nodes = json.load(f)
    with open(all_nodes_file, "a", encoding="utf-8") as f:
        for node in batch_nodes:
            if node["name"] in passed:
                f.write(f"{node['name']}: passed\n")
except Exception as e:
    print(f"错误: 追加到 {all_nodes_file} 失败: {e}")
' "$BATCH_ALL_NODES_FILE" "$TEMP_DIR/batch_$i.json" "$ALL_NODES_FILE" || {
      echo "警告: 追加通过节点到 $ALL_NODES_FILE 失败，查看脚本输出。" | tee -a "$CLASH_LOG"
    }

    # 验证文件存在并记录通过节点数
    BATCH_PASSED_COUNT=$(grep -c ": passed" "$BATCH_ALL_NODES_FILE" 2>/dev/null || echo 0)
    echo "  批次 $((i+1)) 测试完成: $BATCH_PASSED_COUNT 个节点通过。" | tee -a "$CLASH_LOG"
    if [ "$BATCH_PASSED_COUNT" -eq 0 ]; then
      echo "  警告: 批次 $((i+1)) 无通过节点，检查 $BATCH_ALL_NODES_FILE 和 $CLASH_LOG。" | tee -a "$CLASH_LOG"
      grep ": timeout" "$BATCH_ALL_NODES_FILE" | head -n 5 >> "$CLASH_LOG"
      grep ": error" "$BATCH_ALL_NODES_FILE" | head -n 5 >> "$CLASH_LOG"
    fi
    if [ -s "$ALL_PASSED_NODES_JSON" ]; then
      echo "  批次 $((i+1)) 通过节点已保存到 $ALL_PASSED_NODES_JSON 和 $ALL_NODES_FILE。" | tee -a "$CLASH_LOG"
    else
      echo "  警告: 批次 $((i+1)) 无通过节点，$ALL_PASSED_NODES_JSON 可能为空。" | tee -a "$CLASH_LOG"
    fi

    # 提交批次结果
    git config user.name 'github-actions[bot]'
    git config user.email 'github-actions[bot]@users.noreply.github.com'
    git add data/parsed_nodes.json data/passed_nodes.json data/all.txt data/clash.log data/convert_nodes.log data/test_clash_api.log data/previous_nodes.txt data/clash_config_batch_*.yaml data/prefilter_nodes.log data/failed_sub_urls.txt
    git commit -m "保存轮次 $((round+1)) 批次 $((i+1)) 结果" || echo "无中间结果需要提交"
    git push || {
      echo "错误: git push 失败，查看远程仓库状态：" | tee -a "$CLASH_LOG"
      git status
      git log --oneline -n 5
      exit 1
    }
  done

  # 清理旧的批次配置文件，保留最后 MAX_BATCH_FILES 个
  ls -t "$TEMP_DIR"/clash_config_batch_*.yaml 2>/dev/null | tail -n +$MAX_BATCH_FILES | xargs -I {} rm -f {}
done

# 步骤 6: 生成最终 Clash 配置文件
echo "步骤 6: 生成最终 Clash 配置文件..." | tee -a "$CLASH_LOG"
if [ ! -s "$ALL_PASSED_NODES_JSON" ]; then
  echo "没有测试通过的节点，生成空的 $FINAL_CLASH_CONFIG。" | tee -a "$CLASH_LOG"
  cat << EOF > "$FINAL_CLASH_CONFIG"
port: 7890
socks-port: 7891
mode: rule
log-level: info
allow-lan: false
external-controller: 127.0.0.1:9090
secret: ""

proxies: []
proxy-groups:
  - name: 'auto-test'
    type: url-test
    url: https://www.google.com/generate_204
    interval: 300
    proxies: []
EOF
  exit 0
fi

PASSED_NODES_COUNT=$(jq '. | length' "$ALL_PASSED_NODES_JSON")
echo "  共 $PASSED_NODES_COUNT 个节点通过测试。" | tee -a "$CLASH_LOG"

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
    yaml.dump(proxies_list if proxies_list else [], f, allow_unicode=True, default_flow_style=False, sort_keys=False)
' "$ALL_PASSED_NODES_JSON" "$FINAL_CLASH_CONFIG" || {
  echo "错误: 无法生成 proxies 部分，查看 $ALL_PASSED_NODES_JSON 是否有效。" | tee -a "$CLASH_LOG"
  cat "$ALL_PASSED_NODES_JSON"
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
  echo "错误: 无法生成 proxy-groups 部分，查看 $FINAL_CLASH_CONFIG 是否有效。" | tee -a "$CLASH_LOG"
  cat "$FINAL_CLASH_CONFIG"
  exit 1
}

echo "节点测试完成，$PASSED_NODES_COUNT 个节点保存到 $FINAL_CLASH_CONFIG 和 $ALL_NODES_FILE。" | tee -a "$CLASH_LOG"

# 步骤 7: 提交最终结果
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'
git add data/parsed_nodes.json data/passed_nodes.json data/all.txt data/clash.log data/convert_nodes.log data/test_clash_api.log data/previous_nodes.txt data/clash_config.yaml data/clash_config_batch_*.yaml data/prefilter_nodes.log data/failed_sub_urls.txt
git commit -m "保存最终结果: $PASSED_NODES_COUNT 个节点通过" || echo "无最终结果需要提交"
git push || {
  echo "错误: git push 失败，查看远程仓库状态：" | tee -a "$CLASH_LOG"
  git status
  git log --oneline -n 5
  exit 1
}
