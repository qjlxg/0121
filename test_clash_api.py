#!/usr/bin/env python3

import requests
import json
import time
import sys
import yaml
from concurrent.futures import ThreadPoolExecutor, as_completed

CLASH_CONTROLLER_URL = "http://127.0.0.1:9090"

def get_proxies():
    try:
        response = requests.get(f"{CLASH_CONTROLLER_URL}/proxies", timeout=10)
        response.raise_for_status()
        return response.json().get("proxies", {})
    except Exception as e:
        sys.stderr.write(f"获取 Clash 代理失败: {e}\n")
        return {}

def test_proxy(name):
    try:
        response = requests.get(
            f"{CLASH_CONTROLLER_URL}/proxies/{name}/delay?url=https://www.google.com/generate_204&timeout=10000",
            timeout=12
        )
        response.raise_for_status()
        return response.json().get("delay", "timeout")
    except:
        return "error"

def parallel_test_proxies(proxies, max_workers=10):
    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_proxy = {executor.submit(test_proxy, name): name for name in proxies}
        for future in as_completed(future_to_proxy):
            name = future_to_proxy[future]
            try:
                delay = future.result()
                results.append((name, delay))
            except Exception as e:
                results.append((name, "error"))
    return results

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("用法: python test_clash_api.py <output_results_file>\n")
        sys.exit(1)
    results_file = sys.argv[1]
    proxies = get_proxies()
    testable_proxies = [name for name in proxies if name not in ["auto-test", "GLOBAL"]]
    tested_count = 0
    passed_count = 0
    failed_count = 0
    with open(results_file, "w", encoding="utf-8") as f_out:
        for name, delay in parallel_test_proxies(testable_proxies):
            result_line = f"{name}: {delay}ms"
            f_out.write(result_line + "\n")
            tested_count += 1
            if delay != "timeout" and delay != "error":
                passed_count += 1
            else:
                failed_count += 1
    sys.stdout.write(f"  Clash 测试完成。总计测试节点: {tested_count}，通过: {passed_count}，失败: {failed_count}。\n")
