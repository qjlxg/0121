#!/usr/bin/env python3

import requests
import json
import time
import sys
import yaml
from concurrent.futures import ThreadPoolExecutor, as_completed
import logging

CLASH_CONTROLLER_URL = "http://127.0.0.1:9090"
logging.basicConfig(filename="data/test_clash_api.log", level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s")

def get_proxies():
    for attempt in range(3):
        try:
            response = requests.get(f"{CLASH_CONTROLLER_URL}/proxies", timeout=10)
            response.raise_for_status()
            return response.json().get("proxies", {})
        except Exception as e:
            logging.error(f"获取 Clash 代理失败 (尝试 {attempt + 1}/3): {e}")
            if attempt < 2:
                time.sleep(5)
    logging.error("所有尝试获取 Clash 代理均失败")
    return {}

def test_proxy(name):
    for attempt in range(2):
        try:
            response = requests.get(
                f"{CLASH_CONTROLLER_URL}/proxies/{name}/delay?url=https://www.google.com/generate_204&timeout=15000",
                timeout=18
            )
            response.raise_for_status()
            delay = response.json().get("delay", "timeout")
            logging.info(f"测试 {name}: {delay}ms")
            return delay
        except Exception as e:
            logging.warning(f"测试 {name} 失败 (尝试 {attempt + 1}/2): {e}")
            if attempt < 1:
                time.sleep(2)
    logging.error(f"测试 {name} 失败")
    return "error"

def parallel_test_proxies(proxies, max_workers=5):
    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_proxy = {executor.submit(test_proxy, name): name for name in proxies}
        for future in as_completed(future_to_proxy):
            name = future_to_proxy[future]
            try:
                delay = future.result()
                results.append((name, delay))
            except Exception as e:
                logging.error(f"并行测试 {name} 异常: {e}")
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
    logging.info(f"测试总结: 总计 {tested_count}，通过 {passed_count}，失败 {failed_count}")
