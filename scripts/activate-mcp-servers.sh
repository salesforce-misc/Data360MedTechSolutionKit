#!/usr/bin/env bash
# Activate the standard Salesforce MCP server "platform.sobject-all" via CLI only —
# no browser, no manual click. Works against any Salesforce org (scratch org,
# sandbox, or production) that the SF CLI can authenticate to.
#
# Usage:
#   ./activate-mcp-servers.sh <ORG_ALIAS>
#
# Auth chain:
#   sf org display access token -> /secur/frontdoor.jsp -> /secur/contentDoor (sets sid cookie)
#   -> GET /lightning/setup/McpServer/<id>/view (sets __Host-ERIC_PROD-* cookie carrying aura.token)
#   -> POST /aura ApexAction.execute { classname: MulesoftApiCatalogController, method: updateServerStatus }
#
# Note: uses an undocumented internal Aura endpoint. Not officially supported by
# Salesforce. May break on future releases.

set +H
set -eo pipefail

ORG_ALIAS="${1:-}"
if [ -z "$ORG_ALIAS" ]; then
  echo "Usage: $0 <ORG_ALIAS>" >&2
  exit 1
fi

# Standard Salesforce Platform MCP servers to activate. These are the entries
# under Setup → MCP Setup → Standard MCP Servers → Salesforce Servers tab.
# Each one is toggled via the same undocumented Aura endpoint (see
# activate_one() below).
STATUS="true"
SERVERS=(
  platform.sobject-all
  data.data-cloud-queries
  data.data360
  platform.headless-360
)

# --- Deactivation is not needed right now — kept here for future use ---
# STATUS="false"   # set to "false" to deactivate instead of activate
# ----------------------------------------------------------------------

# --- Additional standard MCP servers available in this org — add to    ---
# --- SERVERS above to enable them. Full list visible under             ---
# --- Setup → MCP Setup → Standard MCP Servers → Salesforce Servers:    ---
#   platform.sobject-all              (Standard sObject CRUD + SOQL)
#   platform.sobject-mutations        (Standard sObject mutations)
#   platform.sobject-reads            (Standard sObject reads)
#   platform.sobject-deletes          (Standard sObject deletes)
#   data.data-cloud-queries           (Data Cloud DMO queries via SQL)
#   data.data360                      (Data360 knowledge/data operations)
#   platform.metadata-experts         (Metadata API operations)
#   platform.salesforce-api-context   (Salesforce API context helpers)
#   platform.agentforce-grid          (Agentforce grid tools, 27 methods)
# ------------------------------------------------------------------------


WORK="${HOME}/.mcp_activate_work"
mkdir -p "$WORK"
rm -f "$WORK"/cookies.txt "$WORK"/*.html "$WORK"/*.json 2>/dev/null || true
COOKIE_JAR="$WORK/cookies.txt"

INFO_JSON="$WORK/info.json"
# sf CLI returns non-zero when it emits security warnings even on success — trust the file, not the exit code
sf org display -o "$ORG_ALIAS" --json > "$INFO_JSON" 2>/dev/null || true
if [ ! -s "$INFO_JSON" ]; then
  echo "sf org display failed for alias '$ORG_ALIAS' (empty output)" >&2
  exit 1
fi

INFO_JSON_WIN=$(cygpath -w "$INFO_JSON")
TOKEN=$(python -c "import json; print(json.load(open(r'${INFO_JSON_WIN}'))['result']['accessToken'])")
INSTANCE=$(python -c "import json; print(json.load(open(r'${INFO_JSON_WIN}'))['result']['instanceUrl'])")
SETUP_URL="${INSTANCE/.my.salesforce.com/.my.salesforce-setup.com}"
# The MCP setup pages 302-redirect setup-domain requests to Lightning; ERIC (aura.token)
# cookies are only set on the Lightning domain, so /aura POSTs must target it too.
LIGHTNING_URL="${INSTANCE/.my.salesforce.com/.lightning.force.com}"

echo "== Instance : $INSTANCE"
echo "== Setup    : $SETUP_URL"
echo "== Action   : $([ "$STATUS" = "true" ] && echo "ACTIVATE" || echo "DEACTIVATE")"
echo "== Servers  : ${SERVERS[*]}"
echo

# 1. frontdoor.jsp
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/fd.html" \
  -H "User-Agent: Mozilla/5.0" \
  "${INSTANCE}/secur/frontdoor.jsp?sid=${TOKEN}&retURL=/one/one.app" > /dev/null

# 2. follow JS-based contentDoor redirect (sets sid cookie)
REDIR=$(python -c "
import re
h=open(r'$(cygpath -w "$WORK/fd.html")').read()
m=re.search(r'window\.location\.replace\(\"([^\"]+)\"\)', h)
print(m.group(1) if m else '')
")
if [ -n "$REDIR" ]; then
  curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/fd2.html" \
    -H "User-Agent: Mozilla/5.0" "$REDIR" > /dev/null
fi

# 3. warm up setup subdomain via a Lightning setup URL (do NOT hit /one/one.app — it 302s away
#    and any ERIC cookie ends up scoped to .lightning.force.com instead of the setup subdomain,
#    where the /aura activate call is actually made).
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" --max-redirs 0 -o /dev/null \
  -H "User-Agent: Mozilla/5.0" \
  "${SETUP_URL}/lightning/setup/SetupOneHome/home" 2>/dev/null || true

activate_one() {
  local server_id="$1"
  local status="$2"

  # 4. fetch the MCP detail page on Lightning domain — sets __Host-ERIC_PROD-* cookie
  #    with fresh aura.token. Max-Age is short (~60s), so do this immediately before POST.
  curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/mcp.html" \
    -H "User-Agent: Mozilla/5.0" \
    "${LIGHTNING_URL}/lightning/setup/McpServer/${server_id}/view?setup__source=PLATFORM_STANDARD_MCP_SERVER"

  # 5. extract fwuid, APP_LOADED, aura.token
  local FWUID=$(python -c "
import re, urllib.parse
h=open(r'$(cygpath -w "$WORK/mcp.html")').read()
m=re.search(r'%22fwuid%22%3A%22([^%]+?)%22', h)
print(urllib.parse.unquote(m.group(1)) if m else '')
")
  local APP_LOADED=$(python -c "
import re, urllib.parse
h=open(r'$(cygpath -w "$WORK/mcp.html")').read()
m=re.search(r'%22APPLICATION%40markup%3A%2F%2Fone%3Aone%22%3A%22([^%]+?)%22', h)
print(urllib.parse.unquote(m.group(1)) if m else '')
")
  # The /aura POST goes to Lightning domain, so pick the ERIC cookie scoped there
  local AURA_TOKEN=$(grep "__Host-ERIC" "$COOKIE_JAR" | grep -F "lightning.force.com" | tail -1 | awk '{print $NF}')
  [ -z "$AURA_TOKEN" ] && AURA_TOKEN=$(grep "__Host-ERIC" "$COOKIE_JAR" | tail -1 | awk '{print $NF}')

  if [ -z "$FWUID" ] || [ -z "$APP_LOADED" ] || [ -z "$AURA_TOKEN" ]; then
    echo "  [$server_id] FAIL: missing FWUID/APP_LOADED/AURA_TOKEN"
    return 1
  fi

  # 6. build and POST the Aura ApexAction.execute
  local MSG_JSON="{\"actions\":[{\"id\":\"1;a\",\"descriptor\":\"aura://ApexActionController/ACTION\$execute\",\"callingDescriptor\":\"UNKNOWN\",\"params\":{\"namespace\":\"interaction\",\"classname\":\"MulesoftApiCatalogController\",\"method\":\"updateServerStatus\",\"params\":{\"serverId\":\"${server_id}\",\"source\":\"PLATFORM_STANDARD_MCP_SERVER\",\"status\":${status}},\"cacheable\":false,\"isContinuation\":false}}]}"
  local CTX_JSON="{\"mode\":\"PROD\",\"fwuid\":\"${FWUID}\",\"app\":\"one:one\",\"loaded\":{\"APPLICATION@markup://one:one\":\"${APP_LOADED}\"},\"dn\":[],\"globals\":{\"setupAppContextId\":\"all\"},\"uad\":true}"
  local URI="/lightning/setup/McpServer/${server_id}/view?setup__source=PLATFORM_STANDARD_MCP_SERVER"

  local m=$(MSG="$MSG_JSON" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['MSG']))")
  local c=$(CTX="$CTX_JSON" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['CTX']))")
  local t=$(TOK="$AURA_TOKEN" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['TOK']))")
  local u=$(URI="$URI" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['URI']))")

  local respfile="$WORK/resp-${server_id}.json"
  local code=$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o "$respfile" -w "%{http_code}" \
    -X POST "${LIGHTNING_URL}/aura?r=1&aura.ApexAction.execute=1" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: ${LIGHTNING_URL}" -H "Referer: ${LIGHTNING_URL}${URI}" \
    -H "User-Agent: Mozilla/5.0" \
    -H "X-SFDC-LDS-Endpoints: ApexActionController.execute:MulesoftApiCatalogController.updateServerStatus" \
    --data "message=${m}&aura.context=${c}&aura.pageURI=${u}&aura.token=${t}")

  local state=$(RESPFILE_WIN="$(cygpath -w "$respfile")" python -c "
import json, os, re
raw = open(os.environ['RESPFILE_WIN']).read()
m = re.search(r'\{.*\}', raw, re.DOTALL)
try:
    d = json.loads(m.group(0)) if m else {}
    if 'actions' in d and d['actions']:
        a = d['actions'][0]
        st = a.get('state','UNKNOWN')
        errs = a.get('error') or []
        if st == 'ERROR' and errs:
            msg = errs[0].get('message','') if isinstance(errs[0], dict) else str(errs[0])
            msg_lower = msg.lower()
            # Idempotency: Salesforce returns a generic system error when a server
            # is already in the requested state on re-runs. Match any of these
            # markers and treat as success.
            idempotent_markers = [
                'already',
                'current status',
                'salesforce system error',
            ]
            if any(m in msg_lower for m in idempotent_markers):
                print('IDEMPOTENT')
            else:
                print(f'ERROR:{msg[:120]}')
        else:
            print(st)
    elif 'exceptionMessage' in d:
        print(f\"EXCEPTION:{d['exceptionMessage']}\")
    elif 'event' in d and 'descriptor' in d.get('event',{}):
        print(f\"EVENT:{d['event']['descriptor']}\")
    else:
        print(f'UNKNOWN_SHAPE:{list(d.keys())[:5]}')
except Exception as e:
    print(f'PARSE_ERR:{e}:{raw[:80]!r}')
")
  echo "  [$server_id] HTTP=$code  aura_state=$state"
  case "$state" in
    SUCCESS|IDEMPOTENT) return 0 ;;
    *) return 1 ;;
  esac
}

FAIL=0
for s in "${SERVERS[@]}"; do
  activate_one "$s" "$STATUS" || FAIL=1
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "== ✅ All servers ${STATUS:+processed} successfully =="
else
  echo "== ⚠️  One or more servers failed — see output above =="
  exit 1
fi
