#!/bin/bash
# prefilter_nodes.sh

# 检查输入文件
if [ ! -s data/temp_all_raw_nodes.txt ]; then
  echo "警告: data/temp_all_raw_nodes.txt 为空，跳过预过滤" >> data/fetch_nodes.log
  touch data/filtered_nodes.txt
  exit 0
fi

# 去重并过滤无效节点
cat data/temp_all_raw_nodes.txt | grep -E "^(hysteria2|vmess|trojan|ss|ssr|vless)://" | sort -u > data/filtered_nodes.txt
echo "预过滤完成，生成 data/filtered_nodes.txt，节点数: $(wc -l < data/filtered_nodes.txt)" >> data/fetch_nodes.log
