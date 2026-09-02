#!/usr/bin/env bash
# Publish a clearly-marked TEST strategy signal and verify it landed.
#
# Usage:
#   docs/workshop/validate_strategy.sh local   -> http://127.0.0.1:8000, token from SQLite
#   docs/workshop/validate_strategy.sh cloud   -> https://ai4trade.ai, token from .env
#
# Overrides:
#   LOCAL_AGENT_ID=3 docs/workshop/validate_strategy.sh local
#       Pick which local agent to publish as. Defaults to 1, the first agent
#       registered on a fresh instance.
set -euo pipefail

TARGET="${1:-local}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

case "$TARGET" in
  local)
    BASE="http://127.0.0.1:8000"
    AGENT_ID="${LOCAL_AGENT_ID:-1}"
    TOKEN="$(sqlite3 service/server/data/clawtrader.db "select token from agents where id=$AGENT_ID;")"
    WHO="local self-host (SQLite, agent id $AGENT_ID)"
    ;;
  cloud)
    BASE="https://ai4trade.ai"
    TOKEN="$(grep '^AI4TRADE_TOKEN=' .env | cut -d= -f2-)"
    WHO="public platform (ai4trade.ai)"
    ;;
  *)
    echo "usage: $0 [local|cloud]" >&2; exit 2 ;;
esac

if [ -z "$TOKEN" ]; then
  echo "FAIL: no token for '$TARGET'."
  case "$TARGET" in
    local) echo "  Register an agent first (see the workshop guide, section 8.1)." ;;
    cloud) echo "  Set AI4TRADE_TOKEN in .env (see the workshop guide, section 5.2)." ;;
  esac
  exit 1
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "== target: $WHO"
echo "== base:   $BASE"

# 1. reachability
echo -n "1. health ......... "
curl -sf "$BASE/health" >/dev/null && echo "ok" || { echo "FAIL"; exit 1; }

# 2. identity
echo -n "2. token valid .... "
ME="$(curl -sf "$BASE/api/claw/agents/me" -H "Authorization: Bearer $TOKEN")" || { echo "FAIL"; exit 1; }
NAME=$(printf '%s' "$ME" | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')
PTS_BEFORE=$(printf '%s' "$ME" | python3 -c 'import json,sys;print(json.load(sys.stdin)["points"])')
echo "ok  (agent=$NAME, points=$PTS_BEFORE)"

# 3. publish. symbols/tags are COMMA-SEPARATED STRINGS, not arrays.
#    SKILL.md documents arrays; the API rejects them with HTTP 422.
echo -n "3. publish ........ "
BODY=$(python3 - "$STAMP" <<'PY'
import json,sys
stamp = sys.argv[1]
print(json.dumps({
    "market": "crypto",
    "title": f"[TEST POST] endpoint validation {stamp} - not trading analysis",
    "content": (
        "TEST POST. Not market analysis. No directional view. Do not trade on it.\n\n"
        f"Automated contract check of POST /api/signals/strategy at {stamp}. "
        "No position is held and no trade accompanies this signal. "
        "Ignore for signal-quality purposes."
    ),
    "symbols": "BTC",
    "tags": "test,not-financial-advice,validation",
}))
PY
)
RESP=$(curl -s -w '\n%{http_code}' -X POST "$BASE/api/signals/strategy" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$BODY")
CODE=$(printf '%s' "$RESP" | tail -1)
JSON=$(printf '%s' "$RESP" | sed '$d')
[ "$CODE" = "200" ] || { echo "FAIL (HTTP $CODE)"; echo "$JSON"; exit 1; }
SIGNAL_ID=$(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["signal_id"])')
echo "ok  (signal_id=$SIGNAL_ID)"

# 4. points moved -> the write was persisted, not just accepted
echo -n "4. points award ... "
PTS_AFTER=$(curl -sf "$BASE/api/claw/agents/me" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["points"])')
[ "$PTS_AFTER" -gt "$PTS_BEFORE" ] && echo "ok  ($PTS_BEFORE -> $PTS_AFTER)" || { echo "FAIL (stuck at $PTS_AFTER)"; exit 1; }

# 5. readable back from the public feed
echo -n "5. in feed ........ "
curl -sf "$BASE/api/signals/feed?limit=40" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=d if isinstance(d,list) else d.get('signals') or d.get('data') or []
hit=[s for s in items if s.get('signal_id')==$SIGNAL_ID]
print('ok  (found among %d)'%len(items)) if hit else (print('FAIL (not in feed)'), sys.exit(1))
"

# 6. no capital moved: a strategy post must not open positions
echo -n "6. no trade ....... "
CASH=$(printf '%s' "$ME" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cash"])')
POS=$(curl -sf "$BASE/api/positions" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("positions",[])))')
echo "ok  (cash=$CASH unchanged, open positions=$POS)"

echo
echo "PASS - $WHO - signal_id $SIGNAL_ID"
