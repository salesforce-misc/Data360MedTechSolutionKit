#!/usr/bin/env bash
# Refresh Data Cloud Data Streams (CRM Connector or otherwise) via the same
# undocumented Aura endpoint the UI "Refresh Now" button uses. Fully headless —
# no browser, no Playwright.
#
# Usage:
#   ./refresh-datastreams.sh <ORG_ALIAS> <StreamName1> [StreamName2] [...]
#
# Example:
#   ./refresh-datastreams.sh storm.6cc50869d07237@salesforce.com Account_Home Contact_Home Product2_Home
#
# Why this exists:
#   The public Connect REST API's d360_datastream_run endpoint refuses to
#   refresh CRM Connector streams:
#     - non-interactive mode: "Connector type SalesforceDotCom is not allowed to run in non-interactive mode"
#     - interactive mode:     "not allowed in interactive mode if refresh mode is not FULL_REFRESH"
#   The UI's "Refresh Now" button hits a *different* internal endpoint that
#   accepts these mutations regardless of connector type or refresh mode.
#   This script wraps that same call directly, so we skip the browser entirely.
#
# Auth chain (identical to scripts/activate-mcp-servers.sh):
#   sf org display access token -> /secur/frontdoor.jsp -> sid cookie
#   -> GET /lightning/r/DataStream/<id>/view (sets __Host-ERIC_PROD-* cookie carrying aura.token)
#   -> POST /aura ...processDataStream { recordId, processAllFiles: true }
#
# Discovered by capturing the network request when clicking "Refresh Now" → "Full Refresh"
# in the DataStream detail page on 2026-07-15. Descriptor:
#   serviceComponent://ui.cdp.components.controllers.datastreams.DataStreamDeploymentController/ACTION$processDataStream
#
# Note: uses an undocumented internal Aura endpoint. Not officially supported by
# Salesforce. May break on future releases. Same caveat as activate-mcp-servers.sh.

set +H
set -eo pipefail

ORG_ALIAS="${1:-}"
if [ -z "$ORG_ALIAS" ] || [ "$#" -lt 2 ]; then
  echo "Usage: $0 <ORG_ALIAS> <StreamName1> [StreamName2] [...]" >&2
  exit 1
fi
shift
STREAM_NAMES=("$@")

WORK="${HOME}/.datastream_refresh_work"
mkdir -p "$WORK"
rm -f "$WORK"/cookies.txt "$WORK"/*.html "$WORK"/*.json 2>/dev/null || true
COOKIE_JAR="$WORK/cookies.txt"

INFO_JSON="$WORK/info.json"
sf org display -o "$ORG_ALIAS" --json > "$INFO_JSON" 2>/dev/null || true
if [ ! -s "$INFO_JSON" ]; then
  echo "sf org display failed for alias '$ORG_ALIAS' (empty output)" >&2
  exit 1
fi

INFO_JSON_WIN=$(cygpath -w "$INFO_JSON" 2>/dev/null || echo "$INFO_JSON")
TOKEN=$(python -c "import json; print(json.load(open(r'${INFO_JSON_WIN}'))['result']['accessToken'])")
INSTANCE=$(python -c "import json; print(json.load(open(r'${INFO_JSON_WIN}'))['result']['instanceUrl'])")
LIGHTNING_URL="${INSTANCE/.my.salesforce.com/.lightning.force.com}"

echo "== Instance : $INSTANCE"
echo "== Lightning: $LIGHTNING_URL"
echo "== Streams  : ${STREAM_NAMES[*]}"
echo

# 1. frontdoor.jsp
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/fd.html" \
  -H "User-Agent: Mozilla/5.0" \
  "${INSTANCE}/secur/frontdoor.jsp?sid=${TOKEN}&retURL=/one/one.app" > /dev/null

REDIR=$(python -c "
import re
h=open(r'$(cygpath -w "$WORK/fd.html" 2>/dev/null || echo "$WORK/fd.html")').read()
m=re.search(r'window\.location\.replace\(\"([^\"]+)\"\)', h)
print(m.group(1) if m else '')
")
if [ -n "$REDIR" ]; then
  curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/fd2.html" \
    -H "User-Agent: Mozilla/5.0" "$REDIR" > /dev/null
fi

# 2. Look up DataStream record IDs by Name via REST API (avoids Windows CMD
#    single-quote mangling issues that break `sf data query` for SOQL with quoted values).
STREAMS_QUOTED=$(printf "'%s'," "${STREAM_NAMES[@]}" | sed 's/,$//')
QUERY_URL="${INSTANCE}/services/data/v66.0/query?q=SELECT+Id,Name+FROM+DataStream+WHERE+Name+IN+(${STREAMS_QUOTED})"
# URL-encode the parentheses + commas + quotes so the query string is valid
QUERY_URL=$(URL="$QUERY_URL" python -c "
import os, urllib.parse
u = os.environ['URL']
# Only quote the query-string value, not the whole URL
if '?q=' in u:
    base, q = u.split('?q=', 1)
    print(base + '?q=' + urllib.parse.quote(q, safe='=+'))
else:
    print(u)
")
RECORDS_JSON="$WORK/records.json"
curl -sS -H "Authorization: Bearer $TOKEN" "$QUERY_URL" > "$RECORDS_JSON"

RECORDS_WIN=$(cygpath -w "$RECORDS_JSON" 2>/dev/null || echo "$RECORDS_JSON")
declare -A STREAM_IDS
while IFS='|' read -r name id; do
  # Strip any trailing \r (Windows line endings from python's print)
  name="${name%$'\r'}"
  id="${id%$'\r'}"
  [ -n "$name" ] && STREAM_IDS["$name"]="$id"
done < <(python -c "
import json
d = json.load(open(r'${RECORDS_WIN}'))
# REST returns records at top level; sf CLI wraps in result.records. Handle both.
records = d.get('records') if 'records' in d else d.get('result', {}).get('records', [])
for r in records:
    print(f\"{r.get('Name','')}|{r.get('Id','')}\")
")

# Validate we found every stream
MISSING=()
for s in "${STREAM_NAMES[@]}"; do
  if [ -z "${STREAM_IDS[$s]:-}" ]; then
    MISSING+=("$s")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "❌ Could not find DataStream(s) by Name: ${MISSING[*]}" >&2
  echo "   Verify the streams exist and are active in the target org." >&2
  exit 1
fi

refresh_one() {
  local stream_name="$1"
  local record_id="${STREAM_IDS[$stream_name]}"

  # 3. Fetch the DataStream detail page — sets __Host-ERIC_PROD-* cookie with fresh aura.token
  #    Also gives us fwuid + APP_LOADED for the aura.context payload.
  curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/ds.html" \
    -H "User-Agent: Mozilla/5.0" \
    "${LIGHTNING_URL}/lightning/r/DataStream/${record_id}/view"

  local FWUID=$(python -c "
import re, urllib.parse
h=open(r'$(cygpath -w "$WORK/ds.html" 2>/dev/null || echo "$WORK/ds.html")').read()
m=re.search(r'%22fwuid%22%3A%22([^%]+?)%22', h)
print(urllib.parse.unquote(m.group(1)) if m else '')
")
  local APP_LOADED=$(python -c "
import re, urllib.parse
h=open(r'$(cygpath -w "$WORK/ds.html" 2>/dev/null || echo "$WORK/ds.html")').read()
m=re.search(r'%22APPLICATION%40markup%3A%2F%2Fone%3Aone%22%3A%22([^%]+?)%22', h)
print(urllib.parse.unquote(m.group(1)) if m else '')
")
  local AURA_TOKEN=$(grep "__Host-ERIC" "$COOKIE_JAR" | grep -F "lightning.force.com" | tail -1 | awk '{print $NF}')
  [ -z "$AURA_TOKEN" ] && AURA_TOKEN=$(grep "__Host-ERIC" "$COOKIE_JAR" | tail -1 | awk '{print $NF}')

  if [ -z "$FWUID" ] || [ -z "$APP_LOADED" ] || [ -z "$AURA_TOKEN" ]; then
    echo "  [$stream_name] ($record_id) FAIL: missing FWUID/APP_LOADED/AURA_TOKEN"
    return 1
  fi

  # 4. Build and POST the Aura call. Descriptor + params from the captured UI request:
  #    serviceComponent://ui.cdp.components.controllers.datastreams.DataStreamDeploymentController/ACTION$processDataStream
  #    processAllFiles: true  → Full Refresh (Incremental is processAllFiles: false)
  local MSG_JSON="{\"actions\":[{\"id\":\"1;a\",\"descriptor\":\"serviceComponent://ui.cdp.components.controllers.datastreams.DataStreamDeploymentController/ACTION\$processDataStream\",\"callingDescriptor\":\"UNKNOWN\",\"params\":{\"recordId\":\"${record_id}\",\"processAllFiles\":true}}]}"
  local CTX_JSON="{\"mode\":\"PROD\",\"fwuid\":\"${FWUID}\",\"app\":\"one:one\",\"loaded\":{\"APPLICATION@markup://one:one\":\"${APP_LOADED}\"},\"dn\":[],\"uad\":true}"
  local URI="/lightning/r/DataStream/${record_id}/view"

  local m=$(MSG="$MSG_JSON" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['MSG']))")
  local c=$(CTX="$CTX_JSON" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['CTX']))")
  local t=$(TOK="$AURA_TOKEN" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['TOK']))")
  local u=$(URI="$URI" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['URI']))")

  local respfile="$WORK/resp-${stream_name}.json"
  local code=$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o "$respfile" -w "%{http_code}" \
    -X POST "${LIGHTNING_URL}/aura?r=1&ui-cdp-components-controllers-datastreams.DataStreamDeployment.processDataStream=1" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: ${LIGHTNING_URL}" -H "Referer: ${LIGHTNING_URL}${URI}" \
    -H "User-Agent: Mozilla/5.0" \
    -H "X-SFDC-LDS-Endpoints: DataStreamDeploymentController.processDataStream" \
    --data "message=${m}&aura.context=${c}&aura.pageURI=${u}&aura.token=${t}")

  local state=$(RESPFILE_WIN="$(cygpath -w "$respfile" 2>/dev/null || echo "$respfile")" python -c "
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
            # Idempotency: if a refresh is already running, Salesforce says so.
            idempotent_markers = [
                'already',
                'existing refresh is running',
                'in progress',
            ]
            if any(m in msg_lower for m in idempotent_markers):
                print('IDEMPOTENT')
            else:
                print(f'ERROR:{msg[:200]}')
        else:
            print(st)
    elif 'exceptionMessage' in d:
        print(f\"EXCEPTION:{d['exceptionMessage']}\")
    else:
        print(f'UNKNOWN_SHAPE:{list(d.keys())[:5]}')
except Exception as e:
    print(f'PARSE_ERR:{e}:{raw[:120]!r}')
")
  echo "  [$stream_name] ($record_id) HTTP=$code  aura_state=$state"
  case "$state" in
    SUCCESS|IDEMPOTENT) return 0 ;;
    *) return 1 ;;
  esac
}

FAIL=0
for s in "${STREAM_NAMES[@]}"; do
  refresh_one "$s" || FAIL=1
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "== ✅ All ${#STREAM_NAMES[@]} data stream(s) refresh triggered successfully =="
  echo "   Use mcp__salesforce-data360__execute (toolName=d360_datastream_get) to poll"
  echo "   lastRunStatus per stream. Values: PENDING → RUNNING → SUCCESS (or FAILED)."
else
  echo "== ⚠️  One or more streams failed — see output above =="
  exit 1
fi
