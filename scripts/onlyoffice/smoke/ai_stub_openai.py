#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AI 插件联网验证桩（OpenAI 兼容 /v1 端点）——仅供 smoke，非产品件。

用途/验收断言（2026-09-07 AI 插件联网方案 A）：
  真机 AI 插件「自定义 provider」指向本桩后，chat 发出经 onInterceptRequest 放行的
  直连请求（ArkWeb 默认网络栈，不经 native/arkts 代调）。断言判据：
    1) 本桩日志出现 POST /v1/chat/completions（=请求已出网到达构建机=放行生效）；
    2) 插件 chat 窗口显示桩回复（=响应/流返回路径通）。

前提（真机 → 构建机网络）：
  构建机为 WSL2/Docker，容器 IP 172.x 真机不可达——需先打通宿主转发：
    Windows 侧（管理员）：netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=18999 connectaddress=<WSL容器IP> connectport=18999
    并放行 Windows 防火墙入站 18999（New-NetFirewallRule -DisplayName ai-stub -Direction Inbound -LocalPort 18999 -Protocol TCP -Action Allow）。
  桩 URL 形如 http://<宿主局域网IP>:18999/v1（provider 端点填 /v1）。

用法（在本仓库根目录执行；Ctrl+C 退出）：
  python3 scripts/onlyoffice/smoke/ai_stub_openai.py            # 默认 0.0.0.0:18999
  PORT=19000 python3 scripts/onlyoffice/smoke/ai_stub_openai.py # 换端口

正确目录：仓库根目录（相对引用仅脚本自身路径无关，无外部依赖；仅 python3 标准库）。

CORS 说明：AI 插件 iframe origin=http://localhost（编辑器仍由 onInterceptRequest 本地提供），
浏览器 preflight（OPTIONS + Authorization）必须被桩应答 ACAO:* 才会放行实际 POST。
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "18999"))
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_stub_requests.log")


def logline(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg)
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        logline("GET %s" % self.path)
        if self.path.startswith("/v1/models"):
            self._json({"object": "list", "data": [
                {"id": "stub-model", "object": "model", "owned_by": "stub"}]})
        else:
            self._json({"error": {"message": "stub: not found", "type": "stub"}}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        logline("POST %s auth=%s body=%s" % (self.path,
                                             (self.headers.get("Authorization") or "")[:32],
                                             raw[:300]))
        if self.path.endswith("/chat/completions"):
            req = json.loads(raw or "{}")
            model = req.get("model", "stub-model")
            # 回复内容=复读请求首条 user 消息（便于 UI 断言「桩回复=原句」）
            content = "ECHO:%s" % (
                (req.get("messages") or [{}])[-1].get("content", "")[:60])
            self._json({
                "id": "chatcmpl-stub", "object": "chat.completion", "created":
                int(time.time()), "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant",
                             "content": content}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1,
                          "total_tokens": 2}})
        else:
            self._json({"error": {"message": "stub: not found", "type": "stub"}}, 404)

    def log_message(self, fmt, *args):
        pass  # 静默（避免与 logline 重复）


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    logline("ai stub listening 0.0.0.0:%d (log: %s)" % (PORT, LOG))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        logline("ai stub stopped")
        sys.exit(0)
