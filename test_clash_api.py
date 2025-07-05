#!/usr/bin/env python3

import requests
import json
import time
import sys
import yaml # 确保安装了 pyyaml

CLASH_CONTROLLER_URL = "http://127.0.0.1:9090"

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
        response = requests.get(f"{CLASH_CONTROLLER_URL}/proxies/{name}/delay?url=http://www.google.com/generate_204&timeout=8000")
        response.raise_for_status()
        return response.json().get("delay", "timeout")
    except requests.exceptions.RequestException:
        # 不打印每条错误到 stdout 或 stderr，减少日志量
        return "error"
    except Exception:
        # 不打印每条错误
        return "error"

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: python test_clash_api.py <output_results_file>\n")
        sys.exit(1)

    results_file = sys.argv[1]

    proxies = get_proxies()
    testable_proxies = [name for name in proxies if name not in ["auto-test", "GLOBAL"]]

    tested_count = 0
    passed_count = 0
    failed_count = 0

    with open(results_file, "w") as f_out: # 注意这里是 "w" (写入) 而不是 "a" (追加)
                                           # 因为每次运行会重新生成all.txt
        for name in testable_proxies:
            delay = test_proxy(name)
            result_line = f"{name}: {delay}ms"
            f_out.write(result_line + "\n")
            
            tested_count += 1
            if delay != "timeout" and delay != "error":
                passed_count += 1
            else:
                failed_count += 1
            
            time.sleep(0.05) # 小延迟

    sys.stdout.write(f"  Clash testing complete. Total nodes tested: {tested_count}, Passed: {passed_count}, Failed: {failed_count}.\n")
