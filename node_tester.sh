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

# 清理旧的临时文件
rm -f "$TEMP_SOURCES_LIST" "$TEMP_ALL_RAW_NODES" "$TEMP_NEW_RAW_NODES" "$TEMP_SIMPLE_TEST_PASS" "$TEMP_CLASH_CONFIG"

echo "Step 1: Fetching main sources list from $SOURCES_LIST_URL..."
# 下载主要的 sources.list 文件
curl -s "$SOURCES_LIST_URL" | grep -v '^#' > "$TEMP_SOURCES_LIST"

if [ ! -s "$TEMP_SOURCES_LIST" ]; then
    echo "Error: Could not fetch or file is empty from $SOURCES_LIST_URL. Exiting."
    exit 1
fi

echo "Step 2: Recursively fetching node URLs from sub-sources..."
# 遍历 sources.list 中的每一个子 URL，下载其内容并合并
while IFS= read -r sub_url; do
    echo "  Fetching nodes from: $sub_url"
    curl -s "$sub_url" | grep -E 'hysteria2://|vmess://|trojan://|ss://|ssr://|vless://' >> "$TEMP_ALL_RAW_NODES"
done < "$TEMP_SOURCES_LIST"

if [ ! -s "$TEMP_ALL_RAW_NODES" ]; then
    echo "Error: No node URLs found after fetching all sub-sources. Exiting."
    exit 1
fi

echo "Step 3: Identifying new nodes for testing..."
# 如果 previous_nodes.txt 不存在，则视为所有都是新节点
if [ ! -f "$PREVIOUS_NODES_FILE" ]; then
    NEW_NODES_COUNT=$(wc -l < "$TEMP_ALL_RAW_NODES")
    cp "$TEMP_ALL_RAW_NODES" "$TEMP_NEW_RAW_NODES"
    echo "First run: Found $NEW_NODES_COUNT total nodes. All will be tested."
else
    # 找出新增的节点
    # 使用 comm -13 比较两个排序文件，输出只在第二个文件出现过的行
    sort "$PREVIOUS_NODES_FILE" > "$PREVIOUS_NODES_FILE.sorted"
    sort "$TEMP_ALL_RAW_NODES" > "$TEMP_ALL_RAW_NODES.sorted"
    
    comm -13 "$PREVIOUS_NODES_FILE.sorted" "$TEMP_ALL_RAW_NODES.sorted" > "$TEMP_NEW_RAW_NODES"
    
    NEW_NODES_COUNT=$(wc -l < "$TEMP_NEW_RAW_NODES")
    echo "Found $NEW_NODES_COUNT new nodes."
fi

# 更新 previous_nodes.txt 为当前的全部节点，以便下次比较
cp "$TEMP_ALL_RAW_NODES" "$PREVIOUS_NODES_FILE"

if [ "$NEW_NODES_COUNT" -eq 0 ]; then
    echo "No new nodes to test. Exiting."
    exit 0
fi

echo "Step 4: Performing simple connectivity test on new nodes..."
# 简单测试可以是对节点进行初步格式检查，或者尝试通过代理访问一个小型、稳定的外部网站。
# 这里仅作示例，实际的简单测试需要更复杂的逻辑，例如使用Python脚本解析URL并尝试连接。
# 假设我们只检查URL是否有效且包含已知协议头
grep -E 'hysteria2://|vmess://|trojan://|ss://|ssr://|vless://' "$TEMP_NEW_RAW_NODES" > "$TEMP_SIMPLE_TEST_PASS"

if [ ! -s "$TEMP_SIMPLE_TEST_PASS" ]; then
    echo "No new nodes passed the simple test. Exiting."
    exit 0
fi

echo "New nodes passed simple test:"
cat "$TEMP_SIMPLE_TEST_PASS"

echo "Step 5: Preparing Clash configuration for parallel testing..."
# 生成Clash配置，将通过简单测试的节点添加到proxies中
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

# Python 脚本用于将不同格式的 URL 转换为 Clash 兼容的配置，并追加到 TEMP_CLASH_CONFIG
python3 -c '
import sys
import base64
import json
import urllib.parse
import re

def parse_url(url):
    try:
        if url.startswith("vmess://"):
            encoded_str = url[8:]
            decoded_str = base64.b64decode(encoded_str).decode("utf-8")
            config = json.loads(decoded_str)
            # Generate a unique name for Clash
            name_base = config.get("ps", config.get("add", "vmess_node"))
            name = f"vmess_{re.sub(r"[^a-zA-Z0-9_.-]", "_", name_base)}_{config["port"]}"
            return {
                "name": name,
                "type": "vmess",
                "server": config["add"],
                "port": int(config["port"]),
                "uuid": config["id"],
                "alterId": int(config.get("aid", 0)),
                "cipher": config.get("scy", "auto"),
                "tls": config.get("tls", "") == "tls",
                "skip-cert-verify": config.get("host", "").endswith(".cloudflared.com"), # Example for specific domain
                "network": config.get("net", "tcp"),
                "ws-opts": {
                    "path": config.get("path", "/"),
                    "headers": {"Host": config.get("host", config["add"])}
                } if config.get("net") == "ws" else None,
                "grpc-opts": {
                    "serviceName": config.get("serviceName", "")
                } if config.get("net") == "grpc" else None,
                "udp": True # Usually Vmess supports UDP
            }
        elif url.startswith("ss://"):
            # ss://method:password@server:port#name
            parts = url[5:].split('@')
            auth_part = base64.b64decode(parts[0]).decode("utf-8")
            method, password = auth_part.split(':', 1)
            server_port_name = parts[1].split('#')
            server, port = server_port_name[0].split(':')
            name_raw = urllib.parse.unquote(server_port_name[1]) if len(server_port_name) > 1 else f"{server}:{port}"
            name = f"ss_{re.sub(r"[^a-zA-Z0-9_.-]", "_", name_raw)}_{port}"
            return {
                "name": name,
                "type": "ss",
                "server": server,
                "port": int(port),
                "cipher": method,
                "password": password,
                "udp": True
            }
        elif url.startswith("trojan://"):
            # trojan://password@server:port#name
            parts = url[9:].split('@')
            password = parts[0]
            server_port_name = parts[1].split('#')
            server, port = server_port_name[0].split(':')
            name_raw = urllib.parse.unquote(server_port_name[1]) if len(server_port_name) > 1 else f"{server}:{port}"
            name = f"trojan_{re.sub(r"[^a-zA-Z0-9_.-]", "_", name_raw)}_{port}"
            return {
                "name": name,
                "type": "trojan",
                "server": server,
                "port": int(port),
                "password": password,
                "tls": True,
                "sni": server, # Default SNI to server
                "skip-cert-verify": False,
                "udp": True
            }
        elif url.startswith("vless://"):
            # vless://uuid@server:port?params#name
            parsed_url = urllib.parse.urlparse(url)
            uuid = parsed_url.username
            server_port = parsed_url.netloc.split(":")
            server = server_port[0]
            port = int(server_port[1]) if len(server_port) > 1 else 443 # Default VLESS port
            query_params = urllib.parse.parse_qs(parsed_url.query)
            name_raw = urllib.parse.unquote(parsed_url.fragment) if parsed_url.fragment else f"{server}:{port}"
            name = f"vless_{re.sub(r"[^a-zA-Z0-9_.-]", "_", name_raw)}_{port}"

            return {
                "name": name,
                "type": "vless",
                "server": server,
                "port": port,
                "uuid": uuid,
                "tls": query_params.get("security", [""])[0] == "tls" or query_params.get("type", [""])[0] in ["ws", "grpc"],
                "flow": query_params.get("flow", [""])[0] if query_params.get("flow", [""])[0] != "" else None,
                "network": query_params.get("type", ["tcp"])[0],
                "ws-opts": {
                    "path": query_params.get("path", ["/"])[0],
                    "headers": {"Host": query_params.get("host", [server])[0]}
                } if query_params.get("type", [""])[0] == "ws" else None,
                "grpc-opts": {
                    "serviceName": query_params.get("serviceName", [""])[0]
                } if query_params.get("type", [""])[0] == "grpc" else None,
                "udp": True
            }
        elif url.startswith("hysteria2://"):
            # hysteria2://server:port?param=value#name
            parsed_url = urllib.parse.urlparse(url)
            server_port = parsed_url.netloc.split(":")
            server = server_port[0]
            port = int(server_port[1]) if len(server_port) > 1 else 443
            query_params = urllib.parse.parse_qs(parsed_url.query)
            name_raw = urllib.parse.unquote(parsed_url.fragment) if parsed_url.fragment else f"{server}:{port}"
            name = f"h2_{re.sub(r"[^a-zA-Z0-9_.-]", "_", name_raw)}_{port}"
            
            return {
                "name": name,
                "type": "hysteria2",
                "server": server,
                "port": port,
                "obfs": query_params.get("obfs", ["none"])[0],
                "obfs-password": query_params.get("obfsParam", [""])[0],
                "auth": query_params.get("auth", [""])[0],
                "up": int(query_params.get("up", ["0"])[0]),
                "down": int(query_params.get("down", ["0"])[0]),
                "fast-open": query_params.get("fastOpen", ["true"])[0].lower() == "true",
                "quic": True,
                "tls": True,
                "sni": query_params.get("sni", [server])[0],
                "alpn": query_params.get("alpn", ["h3"])[0].split(","),
                "udp": True
            }
        elif url.startswith("ssr://"):
            # SSR parsing is complex due to base64 encoding and specific parameters.
            # This is a highly simplified placeholder. Clash does not natively support SSR directly;
            # it often requires a converter or a Clash kernel with SSR support.
            # For demonstration, we will attempt a basic parsing.
            encoded_str = url[6:]
            decoded_str = base64.b64decode(encoded_str.replace('-', '+').replace('_', '/')).decode("utf-8")
            # SSR format: server:port:protocol:method:obfs:password_base64/?params_base64#name_base64
            parts = decoded_str.split(":")
            if len(parts) >= 6:
                server = parts[0]
                port = int(parts[1])
                protocol = parts[2]
                method = parts[3]
                obfs = parts[4]
                
                remaining = parts[5].split("/?")
                password_b64 = remaining[0]
                password = base64.b64decode(password_b64.replace('-', '+').replace('_', '/')).decode("utf-8")

                params_part = ""
                if len(remaining) > 1:
                    params_name_part = remaining[1].split("#")
                    params_part = params_name_part[0]
                    name_b64 = params_name_part[1] if len(params_name_part) > 1 else ""
                    name_raw = base64.b64decode(name_b64.replace('-', '+').replace('_', '/')).decode("utf-8") if name_b64 else f"{server}:{port}"
                else:
                    name_raw = f"{server}:{port}"

                name = f"ssr_{re.sub(r"[^a-zA-Z0-9_.-]", "_", name_raw)}_{port}"

                # Clash native does not support SSR, this might be invalid for regular Clash
                # A custom Clash kernel (e.g., Clash.Meta) or a converter is often needed.
                return {
                    "name": name,
                    "type": "ss", # Treat as SS if no native SSR support
                    "server": server,
                    "port": port,
                    "cipher": method,
                    "password": password,
                    "udp": True
                    # Many SSR-specific options (protocol, obfs, obfs_param) would be lost here
                    # unless using Clash.Meta with specific configurations.
                }
            return None # Invalid SSR format
        else:
            sys.stderr.write(f"Unknown protocol: {url}\n")
            return None

    except Exception as e:
        sys.stderr.write(f"Error parsing URL {url}: {e}\n")
        return None

# Use a set to keep track of names to ensure uniqueness
# Clash requires unique proxy names.
used_names = set()
def get_unique_name(base_name):
    name = base_name
    counter = 1
    while name in used_names:
        name = f"{base_name}_{counter}"
        counter += 1
    used_names.add(name)
    return name

with open(sys.argv[1], "r") as f:
    nodes_to_convert = f.readlines()

with open(sys.argv[2], "a") as config_file: # Open in append mode for proxies
    for url in nodes_to_convert:
        url = url.strip()
        if url:
            clash_proxy_config = parse_url(url)
            if clash_proxy_config:
                original_name = clash_proxy_config.get("name", "Unnamed")
                clash_proxy_config["name"] = get_unique_name(original_name)
                
                config_file.write(f'- {{name: "{clash_proxy_config["name"]}", type: {clash_proxy_config["type"]}, server: "{clash_proxy_config["server"]}", port: {clash_proxy_config["port"]}')

                # Append protocol-specific parameters
                if clash_proxy_config["type"] == "vmess":
                    config_file.write(f', uuid: "{clash_proxy_config["uuid"]}", alterId: {clash_proxy_config["alterId"]}, cipher: "{clash_proxy_config["cipher"]}", tls: {str(clash_proxy_config["tls"]).lower()}, network: "{clash_proxy_config["network"]}"')
                    if clash_proxy_config.get("skip-cert-verify"):
                        config_file.write(f', skip-cert-verify: {str(clash_proxy_config["skip-cert-verify"]).lower()}')
                    if clash_proxy_config["network"] == "ws" and clash_proxy_config.get("ws-opts"):
                        config_file.write(f', ws-opts: {{path: "{clash_proxy_config["ws-opts"]["path"]}", headers: {{"Host": "{clash_proxy_config["ws-opts"]["headers"]["Host"]}"}}}}')
                    if clash_proxy_config["network"] == "grpc" and clash_proxy_config.get("grpc-opts"):
                        config_file.write(f', grpc-opts: {{serviceName: "{clash_proxy_config["grpc-opts"]["serviceName"]}"}}')
                elif clash_proxy_config["type"] == "ss":
                    config_file.write(f', cipher: "{clash_proxy_config["cipher"]}", password: "{clash_proxy_config["password"]}"')
                elif clash_proxy_config["type"] == "trojan":
                    config_file.write(f', password: "{clash_proxy_config["password"]}", tls: {str(clash_proxy_config["tls"]).lower()}, sni: "{clash_proxy_config["sni"]}"')
                    if clash_proxy_config.get("skip-cert-verify"):
                        config_file.write(f', skip-cert-verify: {str(clash_proxy_config["skip-cert-verify"]).lower()}')
                elif clash_proxy_config["type"] == "vless":
                    config_file.write(f', uuid: "{clash_proxy_config["uuid"]}", tls: {str(clash_proxy_config["tls"]).lower()}, network: "{clash_proxy_config["network"]}"')
                    if clash_proxy_config.get("flow"):
                         config_file.write(f', flow: "{clash_proxy_config["flow"]}"')
                    if clash_proxy_config["network"] == "ws" and clash_proxy_config.get("ws-opts"):
                        config_file.write(f', ws-opts: {{path: "{clash_proxy_config["ws-opts"]["path"]}", headers: {{"Host": "{clash_proxy_config["ws-opts"]["headers"]["Host"]}"}}}}')
                    if clash_proxy_config["network"] == "grpc" and clash_proxy_config.get("grpc-opts"):
                        config_file.write(f', grpc-opts: {{serviceName: "{clash_proxy_config["grpc-opts"]["serviceName"]}"}}')
                elif clash_proxy_config["type"] == "hysteria2":
                    config_file.write(f', obfs: "{clash_proxy_config["obfs"]}", obfs-password: "{clash_proxy_config["obfs-password"]}", auth: "{clash_proxy_config["auth"]}", up: {clash_proxy_config["up"]}, down: {clash_proxy_config["down"]}, fast-open: {str(clash_proxy_config["fast-open"]).lower()}, quic: {str(clash_proxy_config["quic"]).lower()}, tls: {str(clash_proxy_config["tls"]).lower()}, sni: "{clash_proxy_config["sni"]}", alpn: {json.dumps(clash_proxy_config["alpn"])}')
                
                config_file.write("}}\n")
' "$TEMP_SIMPLE_TEST_PASS" "$TEMP_CLASH_CONFIG"

# 添加一个proxy-group用于同时测试所有节点
echo "proxy-groups:" >> "$TEMP_CLASH_CONFIG"
echo "  - name: 'auto-test'" >> "$TEMP_CLASH_CONFIG"
echo "    type: url-test" >> "$TEMP_CLASH_CONFIG"
echo "    url: http://www.google.com/generate_204" # 测试URL
echo "    interval: 300" # 测试间隔，秒
echo "    proxies:" >> "$TEMP_CLASH_CONFIG"

# 动态添加所有代理的名称到proxy-group
python3 -c '
import yaml
import sys

# Load the current config to get proxy names
with open(sys.argv[1], "r") as f:
    config = yaml.safe_load(f)

proxy_names = [proxy["name"] for proxy in config.get("proxies", [])]

# Append the proxy group section
with open(sys.argv[1], "a") as f:
    for name in proxy_names:
        f.write(f"      - \"{name}\"\n")
' "$TEMP_CLASH_CONFIG"

echo "Step 6: Running Clash for connectivity testing in parallel..."
# 启动Clash后台进程
./clash -f "$TEMP_CLASH_CONFIG" -d . &
CLASH_PID=$!
echo "Clash started with PID: $CLASH_PID"

# 等待Clash启动并加载配置
sleep 10 # 增加等待时间，确保Clash完全启动并加载节点

# 使用Clash的外部控制器API进行测试
python3 -c '
import requests
import json
import time
import sys

CLASH_CONTROLLER_URL = "http://127.0.0.1:9090"
RESULTS_FILE = sys.argv[1] # Path to data/all.txt

def get_proxies():
    try:
        response = requests.get(f"{CLASH_CONTROLLER_URL}/proxies")
        response.raise_for_status()
        return response.json().get("proxies", {})
    except Exception as e:
        sys.stderr.write(f"Error getting proxies from Clash API: {e}\n")
        return {}

def test_proxy(name):
    try:
        # Request a test for a specific proxy
        # Increased timeout to 8000ms for potentially slow nodes
        response = requests.get(f"{CLASH_CONTROLLER_URL}/proxies/{name}/delay?url=http://www.google.com/generate_204&timeout=8000")
        response.raise_for_status() # Use raise_for_status to catch HTTP errors
        return response.json().get("delay", "timeout")
    except requests.exceptions.RequestException as e:
        sys.stderr.write(f"Request error testing proxy {name}: {e}\n")
        return "error"
    except Exception as e:
        sys.stderr.write(f"General error testing proxy {name}: {e}\n")
        return "error"

proxies = get_proxies()
# Filter out the 'auto-test' group itself, only test individual proxies
testable_proxies = [name for name in proxies if name not in ["auto-test", "GLOBAL"]]

tested_results = []
# Open ALL_NODES_FILE in append mode
with open(RESULTS_FILE, "a") as f_out:
    for name in testable_proxies:
        delay = test_proxy(name)
        result_line = f"{name}: {delay}ms"
        tested_results.append(result_line)
        f_out.write(result_line + "\n") # Write each result to file immediately
        sys.stdout.write(f"Tested {name}: {delay}ms\n")
        time.sleep(0.05) # Small delay to avoid overwhelming Clash API

sys.stdout.write("Clash testing complete.\n")
' "$ALL_NODES_FILE"

# 停止Clash进程
kill $CLASH_PID
echo "Clash stopped."

echo "Step 7: Saving Clash test results to $ALL_NODES_FILE."
echo "Node testing and update process complete."
