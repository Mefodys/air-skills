#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
echo "Checking repository prerequisites and MCP configuration."
command -v git >/dev/null
command -v python3 >/dev/null
python3 -m json.tool .mcp.json >/dev/null

healthcheck() {
  python3 - <<'PY'
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

with open(".mcp.json", encoding="utf-8") as source:
    servers = json.load(source)["mcpServers"]

# Keep credentials in memory; never include headers or response bodies in logs.
proxies = {
    scheme: os.environ[f"{scheme.upper()}_PROXY"]
    for scheme in ("http", "https")
    if os.environ.get(f"{scheme.upper()}_PROXY")
}
opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
for name, server in servers.items():
    if server.get("type") != "http":
        sys.exit(f"{name}: expected an HTTP MCP server.")
    headers = dict(server.get("headers", {}))
    for key, value in headers.items():
        def expand(match):
            variable = match.group(1)
            if not os.environ.get(variable):
                sys.exit(f"{name}: required personal secret {variable} is missing.")
            return os.environ[variable]
        headers[key] = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", expand, value)
    headers.update({
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    })
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "air-environment-healthcheck", "version": "1.0"},
        },
    }).encode()
    print(f"{name}: checking authenticated MCP initialization.", flush=True)
    while True:
        request = urllib.request.Request(server["url"], data=payload, headers=headers)
        try:
            with opener.open(request, timeout=30) as response:
                if "text/event-stream" in response.headers.get("Content-Type", ""):
                    message = None
                    for line in response:
                        if line.startswith(b"data:"):
                            candidate = json.loads(line[5:])
                            if candidate.get("id") == 1:
                                message = candidate
                                break
                else:
                    message = json.load(response)
            result = (message or {}).get("result", {})
            if not (result.get("protocolVersion") and result.get("serverInfo")
                    and isinstance(result.get("capabilities"), dict)):
                sys.exit(f"{name}: MCP initialize did not return a valid result.")
            print(f"{name}: authenticated MCP initialization passed.", flush=True)
            break
        except urllib.error.HTTPError as error:
            if error.code not in (408, 429) and error.code < 500:
                sys.exit(f"{name}: MCP endpoint returned HTTP {error.code}; check token access and endpoint.")
            print(f"{name}: waiting for service (HTTP {error.code}).", flush=True)
        except (urllib.error.URLError, TimeoutError, OSError):
            print(f"{name}: waiting for network/service readiness.", flush=True)
        time.sleep(5)
PY
}

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then
  healthcheck
fi
echo "Repository environment ready."
