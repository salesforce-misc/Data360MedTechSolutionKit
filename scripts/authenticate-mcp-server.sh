#!/usr/bin/env bash
# Authenticate ALL Salesforce Standard hosted MCP servers headlessly — no browser click.
# Works for salesforce-sobject-all, salesforce-data-cloud-queries, and salesforce-data360
# (or any future Standard MCP server that follows the same OAuth auth-code + PKCE pattern).
#
# Usage:
#   ./authenticate-mcp-server.sh <ORG_ALIAS> <CONSUMER_KEY> <CONSUMER_SECRET>
# 
# What it does:
#   1. Grabs sf CLI's active access token for the target org (ONCE — shared across all servers)
#   2. Trades it for a Lightning browser session cookie via /secur/frontdoor.jsp (ONCE — sid cookie
#      is host-scoped to the org, valid for all servers)
#   3. For each hosted MCP server:
#      a. Generates fresh PKCE (code_verifier + code_challenge) — PER-SERVER (must be fresh each time)
#      b. Calls /services/oauth2/authorize?prompt=none — Salesforce returns the auth code
#         inline (works because the user is pre-authorized to this ECA on this org)
#      c. POSTs the code to /services/oauth2/token — gets access_token + refresh_token
#      d. Writes tokens into ~/.claude/.credentials.json under the '<server-name>|<hash>' key
#         that Claude Code reads on next tool call
#   4. Touches .claude/settings.local.json so Claude Code's file watcher reloads the registry
#   5. Detaches ONE sentinel per server that polls .credentials.json for up to 5 min and
#      promotes tokens to whatever hash key Claude Code creates
#
# Result: the next mcp__<server>__* tool call for any of the 3 servers uses the cached token —
# no browser popup, no "Needs Auth" state. Fully headless.
#
# Idempotency: safe to re-run — regenerates tokens each time. Sentinels from a prior run exit
# on their own within 5 min if they saw their target stub materialize.


set -eo pipefail

ORG_ALIAS="${1:-}"
KEY="${2:-}"
SECRET="${3:-}"
if [ -z "$ORG_ALIAS" ] || [ -z "$KEY" ] || [ -z "$SECRET" ]; then
    echo "Usage: $0 <ORG_ALIAS> <CONSUMER_KEY> <CONSUMER_SECRET>" >&2
    exit 1
fi

WORK="$HOME/.claude/mcp-multi-auth-work"
mkdir -p "$WORK"
COOKIE_JAR="$WORK/cookies.txt"
rm -f "$COOKIE_JAR"

# --- 1. Get sf token + org URL (ONCE) ---------------------------------------
SF_INFO="$WORK/sf.json"
# sf CLI sometimes prepends a "Warning: update available" line to stdout on Windows.
# Send stderr to /dev/null and strip anything before the first '{' from stdout so the
# result is pure JSON.
sf org display --target-org "$ORG_ALIAS" --json 2>/dev/null | sed -n '/^{/,$p' > "$SF_INFO" || true
if [ ! -s "$SF_INFO" ]; then
    echo "❌ sf org display failed for '$ORG_ALIAS'" >&2
    exit 1
fi

SF_INFO_WIN=$(cygpath -w "$SF_INFO" 2>/dev/null || echo "$SF_INFO")
SF_TOKEN=$(python3 -c "import json; print(json.load(open(r'${SF_INFO_WIN}'))['result']['accessToken'])")
ORG_URL=$(python3 -c "import json; print(json.load(open(r'${SF_INFO_WIN}'))['result']['instanceUrl'])")

IS_SANDBOX=$(python3 -c "
import json
d = json.load(open(r'${SF_INFO_WIN}'))['result']
print('true' if d.get('isSandbox') or d.get('isScratch') else 'false')
")

# Derive the URL prefix based on Production vs Sandbox
if [ "$IS_SANDBOX" = "true" ]; then
    URL_PREFIX="https://api.salesforce.com/platform/mcp/v1/sandbox"
else
    URL_PREFIX="https://api.salesforce.com/platform/mcp/v1"
fi

echo "== Org URL       : $ORG_URL"
echo "== Consumer      : ${KEY:0:12}...${KEY: -4}"
echo "== URL prefix    : $URL_PREFIX"
echo

# --- 2. Trade sf access token for a browser session cookie (ONCE) -----------
curl -sSL -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "User-Agent: Mozilla/5.0" \
    "${ORG_URL}/secur/frontdoor.jsp?sid=${SF_TOKEN}&retURL=/one/one.app" \
    -o "$WORK/fd.html" > /dev/null

FD_HTML_WIN=$(cygpath -w "$WORK/fd.html" 2>/dev/null || echo "$WORK/fd.html")
REDIR=$(python3 -c "
import re
h=open(r'${FD_HTML_WIN}').read()
m=re.search(r'window\.location\.replace\(\"([^\"]+)\"\)', h)
print(m.group(1) if m else '')
")
if [ -n "$REDIR" ]; then
    curl -sSL -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "User-Agent: Mozilla/5.0" \
        "$REDIR" -o "$WORK/fd2.html" > /dev/null
fi

if ! grep -qE "\bsid\b" "$COOKIE_JAR"; then
    echo "❌ frontdoor.jsp did not set a session cookie" >&2
    exit 1
fi
echo "== Session       : ✅ sid cookie captured"
echo

# ============================================================================
# Per-server auth flow
# ============================================================================
#
# Servers to authenticate. Add more entries here to authenticate additional
# Standard MCP servers. Each entry maps a Claude-Code MCP registration name
# to its hosted URL path.
#
# Format: '<claude-mcp-name>|<url-suffix>'
#   <claude-mcp-name>: the name Claude Code stores this MCP server under in
#                      .credentials.json (e.g. 'salesforce-sobject-all')
#   <url-suffix>:      appended to $URL_PREFIX to form the full hosted URL
#                      (e.g. '/platform/sobject-all' → '<prefix>/platform/sobject-all')
SERVERS=(
    "salesforce-sobject-all|/platform/sobject-all"
    "salesforce-data-cloud-queries|/data/data-cloud-queries"
    "salesforce-data360|/data/data360"
    "salesforce-headless-360|/platform/headless-360"
)

# ============================================================================
# Register each server in ~/.claude.json (if not already registered)
# ============================================================================
# Without this, Claude Code has no idea the server exists — the MCP panel
# never lists it, and no credential stub ever gets created. `claude mcp add`
# is the documented way, but the CLI is not always on PATH (Windows/VSCode-only
# installs), so we edit the config file directly. This is the same schema
# Claude Code writes when the CLI is invoked.
CLAUDE_JSON="$HOME/.claude.json"
if [ ! -f "$CLAUDE_JSON" ]; then
    # Fall back to Windows-style HOME if unix HOME is a WSL-ish path
    CLAUDE_JSON_ALT=$(cygpath -w "$HOME/.claude.json" 2>/dev/null || echo "")
    [ -n "$CLAUDE_JSON_ALT" ] && [ -f "$CLAUDE_JSON_ALT" ] && CLAUDE_JSON="$CLAUDE_JSON_ALT"
fi

if [ -f "$CLAUDE_JSON" ] && command -v python3 >/dev/null 2>&1; then
    CLAUDE_JSON_WIN=$(cygpath -w "$CLAUDE_JSON" 2>/dev/null || echo "$CLAUDE_JSON")
    SERVERS_STR=$(printf '%s\n' "${SERVERS[@]}")
    CLAUDE_JSON_WIN="$CLAUDE_JSON_WIN" \
    URL_PREFIX="$URL_PREFIX" \
    KEY="$KEY" \
    SECRET="$SECRET" \
    SERVERS_STR="$SERVERS_STR" \
    python3 <<'PY'
import json, os, pathlib, shutil
p = pathlib.Path(os.environ['CLAUDE_JSON_WIN'])
d = json.loads(p.read_text(encoding='utf-8'))
mcp = d.setdefault('mcpServers', {})
key = os.environ['KEY']
secret = os.environ['SECRET']
url_prefix = os.environ['URL_PREFIX']

changed = False
for line in os.environ['SERVERS_STR'].splitlines():
    line = line.strip()
    if not line:
        continue
    name, suffix = line.split('|', 1)
    url = url_prefix + suffix
    desired = {
        'type': 'http',
        'url':  url,
        'oauth': {
            'clientId':     key,
            'callbackPort': 38000,
            'clientSecret': secret
        }
    }
    existing = mcp.get(name)
    if existing == desired:
        continue
    if existing is None:
        print(f'== Registering NEW MCP server in ~/.claude.json: {name}')
    else:
        # Only rewrite if url/clientId/clientSecret differ — preserves user tweaks
        old_url = existing.get('url')
        old_cid = (existing.get('oauth') or {}).get('clientId')
        old_sec = (existing.get('oauth') or {}).get('clientSecret')
        if old_url == url and old_cid == key and old_sec == secret:
            continue
        print(f'== Updating existing MCP server registration: {name}')
    if not changed:
        bak = p.with_suffix('.json.bak-before-auth-script')
        if not bak.exists():
            shutil.copy2(p, bak)
    mcp[name] = desired
    changed = True

if changed:
    p.write_text(json.dumps(d, indent=2), encoding='utf-8')
else:
    print('== All standard MCP servers already registered in ~/.claude.json')
PY
    echo
fi

authenticate_one_server() {
    local server_name="$1"
    local url_suffix="$2"
    local mcp_url="${URL_PREFIX}${url_suffix}"
    local server_work="${WORK}/${server_name}"
    mkdir -p "$server_work"

    echo "── ${server_name} ────────────────────────────────────────────────"
    echo "   URL: $mcp_url"

    # --- 3a. Fresh PKCE per server (required — reusing across servers fails) ---
    local pkce_env="$server_work/pkce.env"
    python3 -c "
import secrets, hashlib, base64
verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b'=').decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
print(f'VERIFIER={verifier}')
print(f'CHALLENGE={challenge}')
" > "$pkce_env"
    # shellcheck disable=SC1090
    source "$pkce_env"

    # --- 3b. Get auth code via /services/oauth2/authorize?prompt=none -----
    local state="autoauth_${server_name}_$(date +%s)"
    local auth_url="${ORG_URL}/services/oauth2/authorize?prompt=none&response_type=code&client_id=${KEY}&code_challenge=${CHALLENGE}&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A38000%2Fcallback&state=${state}&scope=mcp_api+refresh_token"

    curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -D "$server_work/authz_hdr.txt" --max-redirs 0 -o "$server_work/authz.html" \
        -H "User-Agent: Mozilla/5.0" \
        "$auth_url" > /dev/null

    local consent_url
    consent_url=$(grep -i '^location:' "$server_work/authz_hdr.txt" | sed 's/^[Ll]ocation: //' | tr -d '\r')
    if [ -z "$consent_url" ]; then
        echo "   ❌ /oauth2/authorize did not return a redirect Location" >&2
        return 1
    fi

    curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "User-Agent: Mozilla/5.0" \
        -o "$server_work/consent.html" \
        "$consent_url" > /dev/null

    local consent_win
    consent_win=$(cygpath -w "$server_work/consent.html" 2>/dev/null || echo "$server_work/consent.html")
    local code
    code=$(CONSENT_HTML_WIN="$consent_win" python3 <<'PY'
import os, re, urllib.parse
html = open(os.environ['CONSENT_HTML_WIN'], encoding='utf-8', errors='ignore').read()
m = re.search(r'code=([^&"\'\s]+)', html)
if m:
    print(urllib.parse.unquote(m.group(1)))
PY
)

    if [ -z "$code" ]; then
        # Fallback to consent-form POST
        echo "   Consent form path — submitting approve..." >&2
        local approve_url="${ORG_URL}/setup/secur/RemoteAccessAuthorizationPage.apexp"
        local approve_body
        approve_body=$(CONSENT_HTML_WIN="$consent_win" python3 <<'PY'
import os, re, urllib.parse
html = open(os.environ['CONSENT_HTML_WIN'], encoding='utf-8', errors='ignore').read()
pairs = []
for m in re.finditer(r'<input[^>]*type=["\']hidden["\'][^>]*>', html, re.IGNORECASE):
    tag = m.group(0)
    n = re.search(r'name=["\']([^"\']+)["\']', tag)
    v = re.search(r'value=["\']([^"\']*)["\']', tag)
    if n:
        pairs.append((n.group(1), v.group(1) if v else ''))
pairs.append(('save', 'Allow'))
print(urllib.parse.urlencode(pairs))
PY
)
        curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
            -D "$server_work/approve_hdr.txt" \
            --max-redirs 0 -o "$server_work/approve.html" \
            -H "User-Agent: Mozilla/5.0" \
            -X POST "$approve_url" --data "$approve_body" > /dev/null

        local approve_loc
        approve_loc=$(grep -i '^location:' "$server_work/approve_hdr.txt" | sed 's/^[Ll]ocation: //' | tr -d '\r')
        code=$(APPROVE_LOC="$approve_loc" python3 <<'PY'
import os, re, urllib.parse
s = os.environ.get('APPROVE_LOC', '')
m = re.search(r'code=([^&]+)', s)
if m: print(urllib.parse.unquote(m.group(1)))
PY
)
    fi

    if [ -z "$code" ]; then
        echo "   ❌ Could not extract OAuth authorization code" >&2
        return 1
    fi
    echo "   Code:    ${code:0:20}... (${#code} chars)"

    # --- 3c. Exchange code for tokens --------------------------------------
    curl -sS -X POST "${ORG_URL}/services/oauth2/token" \
        --data-urlencode "grant_type=authorization_code" \
        --data-urlencode "client_id=${KEY}" \
        --data-urlencode "client_secret=${SECRET}" \
        --data-urlencode "code=${code}" \
        --data-urlencode "code_verifier=${VERIFIER}" \
        --data-urlencode "redirect_uri=http://localhost:38000/callback" \
        -o "$server_work/tokens.json" > /dev/null

    local tokens_win
    tokens_win=$(cygpath -w "$server_work/tokens.json" 2>/dev/null || echo "$server_work/tokens.json")
    local access refresh
    access=$(python3 -c "import json; print(json.load(open(r'${tokens_win}')).get('access_token',''))")
    refresh=$(python3 -c "import json; print(json.load(open(r'${tokens_win}')).get('refresh_token',''))")

    if [ -z "$access" ]; then
        echo "   ❌ Token exchange failed" >&2
        cat "$server_work/tokens.json" >&2
        return 1
    fi
    echo "   Access:  ✅ ${#access}-char JWT"
    echo "   Refresh: ✅ ${#refresh}-char token"

    # --- 3d. Write into ~/.claude/.credentials.json ------------------------
    local cred_file="${HOME}/.claude/.credentials.json"
    local cred_win
    cred_win=$(cygpath -w "$cred_file" 2>/dev/null || echo "$cred_file")

    SERVER_NAME="$server_name" SERVER_URL="$mcp_url" \
    ACCESS="$access" REFRESH="$refresh" CRED_WIN="$cred_win" python3 <<'PY'
import json, os, hashlib, pathlib
cred_path = pathlib.Path(os.environ['CRED_WIN'])
if cred_path.exists():
    cred = json.loads(cred_path.read_text(encoding='utf-8') or '{}')
else:
    cred = {}
mcp = cred.setdefault('mcpOAuth', {})
server_name = os.environ['SERVER_NAME']
server_url  = os.environ['SERVER_URL']

# Find all existing keys for this server
existing = [k for k in mcp.keys() if k.startswith(f'{server_name}|')]
url_only_hash = hashlib.sha256(server_url.encode()).hexdigest()[:16]
url_only_key  = f'{server_name}|{url_only_hash}'
cc_created    = [k for k in existing if k != url_only_key]

if cc_created:
    if url_only_key in mcp:
        del mcp[url_only_key]
        print(f'   Pruned legacy URL-only key: {url_only_key}')
    target_keys = cc_created
elif existing:
    target_keys = existing
else:
    print(f'   Fallback: writing to URL-only key {url_only_key}')
    target_keys = [url_only_key]

for key in target_keys:
    entry = mcp.get(key, {})
    entry.update({
        'serverName': server_name,
        'serverUrl':  entry.get('serverUrl') or server_url,
        'accessToken': os.environ['ACCESS'],
        'discoveryState': entry.get('discoveryState') or {
            'authorizationServerUrl': server_url,
            'oauthMetadataFound': True
        },
        'refreshToken': os.environ['REFRESH'],
        'scope': 'refresh_token mcp_api'
    })
    mcp[key] = entry
    print(f'   Wrote token under key: {key}')

cred_path.write_text(json.dumps(cred, indent=2), encoding='utf-8')
PY

    echo "   ✅ ${server_name} authenticated"
    echo
    return 0
}

# ============================================================================
# Bootstrap: force Claude Code to create credential stubs for all 3 servers
# ============================================================================
# `claude mcp list` triggers connection attempts against every registered MCP.
# For OAuth servers with no valid token, Claude Code writes empty stubs under
# its own correctly-hashed keys. Running this ONCE before we write tokens
# ensures our writes land on the keys the extension is actually watching.
if command -v claude >/dev/null 2>&1; then
    echo "== Bootstrap: forcing Claude Code to create credential stubs..."
    claude mcp list >/dev/null 2>&1 || true
    echo
fi

# ============================================================================
# Process each server
# ============================================================================
FAIL=0
for entry in "${SERVERS[@]}"; do
    server_name="${entry%%|*}"
    url_suffix="${entry##*|}"
    authenticate_one_server "$server_name" "$url_suffix" || FAIL=$((FAIL + 1))
done

# --- Clear "Needs Auth" cache for the servers we just authenticated ----------
# Claude Code caches its "Needs Auth" verdict per server in this file. If a
# server was previously seen as unauthenticated (empty stub in .credentials.json),
# an entry is written here. On subsequent UI panel refreshes, Claude Code trusts
# this cache and shows "Needs Auth" even after tokens land in .credentials.json.
# We remove entries for the servers we just authenticated so the next MCP panel
# refresh re-checks credentials and flips to ✓ Connected.
NEEDS_AUTH_CACHE="$HOME/.claude/mcp-needs-auth-cache.json"
if [ -f "$NEEDS_AUTH_CACHE" ] && command -v python3 >/dev/null 2>&1; then
    SERVERS_JSON=$(printf '%s\n' "${SERVERS[@]}" | awk -F'|' '{print $1}' | python3 -c "
import sys, json
print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))
")
    NEEDS_AUTH_CACHE_WIN=$(cygpath -w "$NEEDS_AUTH_CACHE" 2>/dev/null || echo "$NEEDS_AUTH_CACHE")
    CACHE_WIN="$NEEDS_AUTH_CACHE_WIN" NAMES_JSON="$SERVERS_JSON" python3 <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ['CACHE_WIN'])
d = json.loads(p.read_text()) if p.exists() else {}
names = json.loads(os.environ['NAMES_JSON'])
removed = [n for n in names if n in d]
for n in removed:
    del d[n]
p.write_text(json.dumps(d, indent=2))
if removed:
    print(f"== Cleared 'Needs Auth' cache entries: {', '.join(removed)}")
else:
    print("== 'Needs Auth' cache had no stale entries for authenticated servers")
PY
fi

# --- Touch settings.local.json to trigger MCP registry reload ---------------
SETTINGS_FILE=".claude/settings.local.json"
if [ -f "$SETTINGS_FILE" ]; then
    touch "$SETTINGS_FILE" 2>/dev/null || true
    echo "== Touched $SETTINGS_FILE to trigger MCP registry reload"
fi

# --- Detach ONE sentinel per server (all share the same script) -------------
SENTINEL_SCRIPT="$(dirname "$0")/all-mcp-server-sentinel.py"
if [ -f "$SENTINEL_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
    SENTINEL_SCRIPT_WIN=$(cygpath -w "$SENTINEL_SCRIPT" 2>/dev/null || echo "$SENTINEL_SCRIPT")
    for entry in "${SERVERS[@]}"; do
        server_name="${entry%%|*}"
        url_suffix="${entry##*|}"
        mcp_url="${URL_PREFIX}${url_suffix}"
        url_only_hash=$(python3 -c "import hashlib; print(hashlib.sha256('$mcp_url'.encode()).hexdigest()[:16])")
        source_key="${server_name}|${url_only_hash}"

        SERVER_URL="$mcp_url" SERVER_NAME="$server_name" \
        nohup python3 "$SENTINEL_SCRIPT_WIN" \
            --server-name "$server_name" \
            --source-key "$source_key" \
            --timeout-sec 300 \
            --poll-interval-sec 2 \
            > "$HOME/.claude/${server_name}-sentinel.log" 2>&1 &
        disown 2>/dev/null || true
        echo "== Detached sentinel for $server_name (PID $!)"
    done
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "== ✅ All standard MCP servers authenticated — fully automatic =="
    echo "   Servers processed: ${#SERVERS[@]}"
    exit 0
else
    echo "== ⚠️  $FAIL server(s) failed authentication — see errors above ==" >&2
    exit 1
fi
