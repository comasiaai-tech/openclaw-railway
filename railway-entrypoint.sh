#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
CONFIG_FILE="${STATE_DIR}/openclaw.json"
PORT="${PORT:-8080}"

# Auto-generate gateway token if not set
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  if [ -f "${STATE_DIR}/.gateway-token" ]; then
    OPENCLAW_GATEWAY_TOKEN=$(cat "${STATE_DIR}/.gateway-token")
  else
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
  fi
fi

mkdir -p "${STATE_DIR}" "${WORKSPACE_DIR}"
echo -n "${OPENCLAW_GATEWAY_TOKEN}" > "${STATE_DIR}/.gateway-token"

# Always regenerate config to pick up env var changes
if true; then
  echo "==> Generating config..."
  MODEL="${OPENCLAW_DEFAULT_MODEL:-anthropic/claude-sonnet-4-6}"
  cat > "${CONFIG_FILE}" <<EOF
{
  "gateway": {
    "mode": "local", "bind": "loopback", "port": 18789,
    "trustedProxies": ["127.0.0.1", "::1"],
    "auth": { "mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}" },
    "controlUi": { "allowedOrigins": ["*"], "dangerouslyDisableDeviceAuth": true }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "${MODEL}" },
      "workspace": "${WORKSPACE_DIR}",
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    }
  },
  "tools": {
    "web": { "search": {"enabled":true}, "fetch": {"enabled":true} }
  },
  "channels": {
    "telegram": {
      "botToken": "${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": [8362202396]
    }
  }
}
EOF
fi

# Save API keys
touch "${STATE_DIR}/.env"
[ -n "${ANTHROPIC_API_KEY:-}" ] && \
  grep -q "ANTHROPIC_API_KEY" "${STATE_DIR}/.env" 2>/dev/null || \
  echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" >> "${STATE_DIR}/.env"
[ -n "${OPENAI_API_KEY:-}" ] && \
  grep -q "OPENAI_API_KEY" "${STATE_DIR}/.env" 2>/dev/null || \
  echo "OPENAI_API_KEY=${OPENAI_API_KEY:-}" >> "${STATE_DIR}/.env"

[ -f "${STATE_DIR}/.env" ] && { set -a; source "${STATE_DIR}/.env"; set +a; }

echo ""
echo "==========================================="
echo "  OpenClaw on Railway"
echo "==========================================="
echo "  Model: ${OPENCLAW_DEFAULT_MODEL:-anthropic/claude-sonnet-4-6}"
echo "  GATEWAY TOKEN (copy this!):"
echo "  ${OPENCLAW_GATEWAY_TOKEN}"
echo "==========================================="

export OPENCLAW_STATE_DIR="${STATE_DIR}"
export OPENCLAW_WORKSPACE_DIR="${WORKSPACE_DIR}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}"
export OPENCLAW_GATEWAY_URL="ws://127.0.0.1:18789?token=${OPENCLAW_GATEWAY_TOKEN}"
export HOME="/root"

# Write gateway pairing so agent/cron can authenticate to gateway
mkdir -p "${STATE_DIR}"
cat > "${STATE_DIR}/gateway-pairing.json" <<PAIREOF
{
  "version": 1,
  "gateway": {
    "url": "ws://127.0.0.1:18789",
    "token": "${OPENCLAW_GATEWAY_TOKEN}"
  }
}
PAIREOF
echo "==> Gateway pairing written"

# Configure Anthropic setup-token auth if provided
if [ -n "${ANTHROPIC_SETUP_TOKEN:-}" ]; then
  echo "==> Configuring Anthropic setup-token auth..."
  AUTH_DIR="${STATE_DIR}/agents/main/agent"
  mkdir -p "${AUTH_DIR}"
  cat > "${AUTH_DIR}/auth-profiles.json" <<AUTHEOF
{
  "version": 1,
  "profiles": {
    "anthropic:setup-token": {
      "type": "token",
      "provider": "anthropic",
      "token": "${ANTHROPIC_SETUP_TOKEN}"
    }
  },
  "order": {
    "anthropic": ["anthropic:setup-token"]
  }
}
AUTHEOF
  echo "==> Auth profile written to ${AUTH_DIR}/auth-profiles.json"
fi

# Reverse proxy: Railway $PORT -> gateway 18789
cat > /tmp/proxy.js <<'PROXYEOF'
const http = require("http");
const PORT = process.env.PORT || 8080;
const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200,{"Content-Type":"application/json"});
    return res.end(JSON.stringify({ok:true}));
  }
  const h = Object.assign({},req.headers);
  delete h["x-forwarded-for"]; delete h["x-forwarded-proto"];
  delete h["x-forwarded-host"]; delete h["x-forwarded-port"];
  const o = {hostname:"127.0.0.1",port:18789,
    path:req.url,method:req.method,headers:h};
  const p = http.request(o, r => {
    res.writeHead(r.statusCode,r.headers);
    r.pipe(res,{end:true});
  });
  p.on("error", () => {
    if(!res.headersSent){res.writeHead(502,{"Content-Type":"text/html"});
    res.end("<h2>Starting up...</h2><p>Refresh in a moment.</p>");}
  });
  req.pipe(p,{end:true});
});
server.on("upgrade",(req,socket)=>{
  const h2=Object.assign({},req.headers);
  delete h2["x-forwarded-for"]; delete h2["x-forwarded-proto"];
  delete h2["x-forwarded-host"]; delete h2["x-forwarded-port"];
  const o={hostname:"127.0.0.1",port:18789,
    path:req.url,method:req.method,headers:h2};
  const p=http.request(o);
  p.on("upgrade",(r,s)=>{
    socket.write("HTTP/1.1 101 Switching Protocols\r\n"
      +Object.entries(r.headers).map(([k,v])=>k+": "+v).join("\r\n")
      +"\r\n\r\n");
    s.pipe(socket);socket.pipe(s);
  });
  p.on("error",()=>socket.end());
  p.end();
});
server.listen(PORT,"0.0.0.0",()=>
  console.log("Proxy: "+PORT+" -> 18789"));
PROXYEOF

node /tmp/proxy.js &
echo "==> Starting OpenClaw gateway..."
exec openclaw gateway \
  --port 18789 --bind loopback \
  --allow-unconfigured
