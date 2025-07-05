#!/usr/bin/env python3

import sys
import base64
import json
import urllib.parse
import re
import html

def parse_url(url_raw):
    url = html.unescape(url_raw)
    try:
        if url.startswith("vmess://"):
            encoded_str = url[8:]
            try:
                decoded_str = base64.b64decode(encoded_str).decode("utf-8")
            except:
                try:
                    decoded_str = base64.b64decode(encoded_str).decode("latin-1")
                except:
                    return None
            try:
                config = json.loads(decoded_str)
            except json.JSONDecodeError:
                return None
            name_base = config.get("ps", config.get("add", "vmess_node"))
            name = f"vmess_{re.sub(r'[^a-zA-Z0-9_.-]', '_', name_base)}_{config['port']}"
            return {
                "name": name,
                "type": "vmess",
                "server": config["add"],
                "port": int(config["port"]),
                "uuid": config["id"],
                "alterId": int(config.get("aid", 0)),
                "cipher": config.get("scy", "auto"),
                "tls": config.get("tls", "") == "tls",
                "skip-cert-verify": True,
                "network": config.get("net", "tcp"),
                "ws-opts": {
                    "path": config.get("path", "/"),
                    "headers": {"Host": config.get("host", config["add"])}
                } if config.get("net") == "ws" else None,
                "grpc-opts": {
                    "serviceName": config.get("serviceName", "")
                } if config.get("net") == "grpc" else None,
                "udp": True
            }
        elif url.startswith("ss://"):
            parts = url[5:].split('@')
            if len(parts) < 2: return None
            auth_part_encoded = parts[0]
            try:
                auth_part_decoded = base64.b64decode(auth_part_encoded).decode("utf-8")
            except:
                try:
                    auth_part_decoded = base64.b64decode(auth_part_encoded).decode("latin-1")
                except:
                    return None
            if ':' not in auth_part_decoded: return None
            method, password = auth_part_decoded.split(':', 1)
            server_port_name = parts[1].split('#')
            if ':' not in server_port_name[0]: return None
            server, port = server_port_name[0].split(':', 1)
            name_raw = urllib.parse.unquote(server_port_name[1]) if len(server_port_name) > 1 else f"{server}:{port}"
            name = f"ss_{re.sub(r'[^a-zA-Z0-9_.-]', '_', name_raw)}_{port}"
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
            parsed_url = urllib.parse.urlparse(url)
            password = parsed_url.username
            server = parsed_url.hostname
            if not server or not password: return None
            port = parsed_url.port if parsed_url.port else 443
            name_raw = urllib.parse.unquote(parsed_url.fragment) if parsed_url.fragment else f"{server}:{port}"
            name = f"trojan_{re.sub(r'[^a-zA-Z0-9_.-]', '_', name_raw)}_{port}"
            query_params = urllib.parse.parse_qs(parsed_url.query)
            return {
                "name": name,
                "type": "trojan",
                "server": server,
                "port": int(port),
                "password": password,
                "tls": True,
                "sni": query_params.get("sni", [server])[0],
                "alpn": query_params.get("alpn", ["h2", "http/1.1"])[0].split(","),
                "skip-cert-verify": query_params.get("skip-cert-verify", ["true"])[0].lower() == "true",
                "udp": True
            }
        elif url.startswith("vless://"):
            parsed_url = urllib.parse.urlparse(url)
            uuid = parsed_url.username
            server_port = parsed_url.netloc.split(":")
            server = server_port[0]
            port = int(server_port[1]) if len(server_port) > 1 else 443
            query_params = urllib.parse.parse_qs(parsed_url.query)
            name_raw = urllib.parse.unquote(parsed_url.fragment) if parsed_url.fragment else f"{server}:{port}"
            name = f"vless_{re.sub(r'[^a-zA-Z0-9_.-]', '_', name_raw)}_{port}"
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
            parsed_url = urllib.parse.urlparse(url)
            server_port = parsed_url.netloc.split(":")
            server = server_port[0]
            port = int(server_port[1]) if len(server_port) > 1 else 443
            query_params = urllib.parse.parse_qs(parsed_url.query)
            name_raw = urllib.parse.unquote(parsed_url.fragment) if parsed_url.fragment else f"{server}:{port}"
            name = f"h2_{re.sub(r'[^a-zA-Z0-9_.-]', '_', name_raw)}_{port}"
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
            encoded_str = url[6:]
            try:
                decoded_str = base64.urlsafe_b64decode(encoded_str + '==').decode("utf-8")
            except:
                try:
                    decoded_str = base64.urlsafe_b64decode(encoded_str + '==').decode("latin-1")
                except:
                    return None
            parts = decoded_str.split(":")
            if len(parts) >= 6:
                server = parts[0]
                port = int(parts[1])
                method = parts[3]
                remaining = parts[5].split("/?")
                password_b64 = remaining[0]
                try:
                    password = base64.urlsafe_b64decode(password_b64 + '==').decode("utf-8")
                except:
                    try:
                        password = base64.urlsafe_b64decode(password_b64 + '==').decode("latin-1")
                    except:
                        return None
                params_part = ""
                if len(remaining) > 1:
                    params_name_part = remaining[1].split("#")
                    params_part = params_name_part[0]
                    name_b64 = params_name_part[1] if len(params_name_part) > 1 else ""
                    name_raw = base64.urlsafe_b64decode(name_b64 + '==').decode("utf-8") if name_b64 else f"{server}:{port}"
                else:
                    name_raw = f"{server}:{port}"
                name = f"ssr_{re.sub(r'[^a-zA-Z0-9_.-]', '_', name_raw)}_{port}"
                return {
                    "name": name,
                    "type": "ss",
                    "server": server,
                    "port": int(port),
                    "cipher": method,
                    "password": password,
                    "udp": True
                }
            return None
        else:
            return None
    except Exception as e:
        print(f"解析错误: {url_raw} - {str(e)}", file=sys.stderr)
        return None

used_names = set()
def get_unique_name(base_name):
    name = base_name
    counter = 1
    while name in used_names:
        name = f"{base_name}_{counter}"
        counter += 1
    used_names.add(name)
    return name

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write("用法: python convert_nodes.py <input_nodes_file> <output_json_file>\n")
        sys.exit(1)
    input_nodes_file = sys.argv[1]
    output_json_file = sys.argv[2]
    total_nodes_processed = 0
    with open(input_nodes_file, "r", encoding="utf-8", errors="ignore") as f:
        nodes_to_convert = f.readlines()
    proxies_list = []
    for url in nodes_to_convert:
        total_nodes_processed += 1
        url = url.strip()
        if url:
            clash_proxy_config = parse_url(url)
            if clash_proxy_config:
                original_name = clash_proxy_config.get("name", "Unnamed")
                clash_proxy_config["name"] = get_unique_name(original_name)
                proxies_list.append(clash_proxy_config)
    with open(output_json_file, "w", encoding="utf-8") as f_out:
        json.dump(proxies_list, f_out, indent=2, ensure_ascii=False)
    sys.stdout.write(f"  处理了 {total_nodes_processed} 个原始节点，成功解析 {len(proxies_list)} 个到 Clash 格式并保存到 {output_json_file}。\n")
