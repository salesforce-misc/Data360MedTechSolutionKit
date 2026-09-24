#!/usr/bin/env bash
# Enable the "Notebook AI" Beta Feature (Data Cloud) via CLI only — no browser,
# no Playwright. Adapts the same Aura-POST replay pattern as
# scripts/activate-mcp-servers.sh, targeting the Data Cloud Setup controller's
# enableBetaFeatureWithoutCascade action.
#
# Usage:
#   ./enable-notebook-ai.sh <ORG_ALIAS>
#
# Auth chain (mirrors activate-mcp-servers.sh):
#   sf org display access token -> /secur/frontdoor.jsp -> /secur/contentDoor
#   (sets sid cookie) -> GET /lightning/setup/BetaFeaturesSetup/home on the
#   *setup* subdomain (sets __Host-ERIC_PROD-* cookie carrying aura.token)
#   -> POST /aura enableBetaFeatureWithoutCascade { betaFeatureName: KnowledgeSpaceName }
#
# Note: uses an undocumented internal Aura endpoint. Not officially supported
# by Salesforce. May break on future releases.

set +H
set -eo pipefail

ORG_ALIAS="${1:-}"
if [ -z "$ORG_ALIAS" ]; then
  echo "Usage: $0 <ORG_ALIAS>" >&2
  exit 1
fi

# Notebook AI's internal beta-feature name (from browser network capture)
BETA_FEATURE_NAME="KnowledgeSpaceName"

WORK="${HOME}/.notebook_ai_work"
mkdir -p "$WORK"
rm -f "$WORK"/cookies.txt "$WORK"/*.html "$WORK"/*.json 2>/dev/null || true
COOKIE_JAR="$WORK/cookies.txt"

INFO_JSON="$WORK/info.json"
sf org display -o "$ORG_ALIAS" --json > "$INFO_JSON" 2>/dev/null || true
if [ ! -s "$INFO_JSON" ]; then
  echo "sf org display failed for alias '$ORG_ALIAS' (empty output)" >&2
  exit 1
fi

INFO_JSON_WIN=$(cygpath -w "$INFO_JSON")
TOKEN=$(python -c "import json; print(json.load(open(r'${INFO_JSON_WIN}'))['result']['accessToken'])")
INSTANCE=$(python -c "import json; print(json.load(open(r'${INFO_JSON_WIN}'))['result']['instanceUrl'])")
# BetaFeaturesSetup's page URL uses the setup subdomain, but that domain 302s
# to the lightning subdomain to complete auth — so the __Host-ERIC (aura.token)
# cookie is only ever minted for .lightning.force.com. The /aura POST therefore
# has to target the lightning subdomain (same as scripts/activate-mcp-servers.sh).
# Origin/Referer are kept on the setup subdomain to match what the browser sends.
SETUP_URL="${INSTANCE/.my.salesforce.com/.my.salesforce-setup.com}"
LIGHTNING_URL="${INSTANCE/.my.salesforce.com/.lightning.force.com}"

echo "== Instance      : $INSTANCE"
echo "== Setup domain  : $SETUP_URL"
echo "== Lightning     : $LIGHTNING_URL"
echo "== Beta feature  : $BETA_FEATURE_NAME  (Notebook AI)"
echo

# 1. frontdoor.jsp — plant the sid on the primary my.salesforce.com domain
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/fd.html" \
  -H "User-Agent: Mozilla/5.0" \
  "${INSTANCE}/secur/frontdoor.jsp?sid=${TOKEN}&retURL=/one/one.app" > /dev/null

# 2. follow the JS contentDoor redirect (plants sid on file.force.com if present)
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

# 3. warm the setup subdomain by loading BetaFeaturesSetup — this is what the
#    browser does when the tab opens, and it sets __Host-ERIC_PROD-* scoped to
#    the setup subdomain with a fresh aura.token (Max-Age is short, ~60s).
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L -o "$WORK/beta.html" \
  -H "User-Agent: Mozilla/5.0" \
  "${SETUP_URL}/lightning/setup/BetaFeaturesSetup/home"

# 4. extract fwuid, APPLICATION@markup://one:one loaded id, aura.token
FWUID=$(python -c "
import re, urllib.parse
h=open(r'$(cygpath -w "$WORK/beta.html")').read()
m=re.search(r'%22fwuid%22%3A%22([^%]+?)%22', h)
print(urllib.parse.unquote(m.group(1)) if m else '')
")
APP_LOADED=$(python -c "
import re, urllib.parse
h=open(r'$(cygpath -w "$WORK/beta.html")').read()
m=re.search(r'%22APPLICATION%40markup%3A%2F%2Fone%3Aone%22%3A%22([^%]+?)%22', h)
print(urllib.parse.unquote(m.group(1)) if m else '')
")
# Pick any __Host-ERIC cookie from the jar — the aura.token is passed as a
# form field on the POST, so cookie *scoping* doesn't matter, only the value.
# `|| true` so that an empty grep under `set -e` doesn't kill the script.
AURA_TOKEN=$( { grep "__Host-ERIC" "$COOKIE_JAR" | grep -F "salesforce-setup.com" | tail -1 | awk '{print $NF}'; } 2>/dev/null || true)
if [ -z "$AURA_TOKEN" ]; then
  AURA_TOKEN=$( { grep "__Host-ERIC" "$COOKIE_JAR" | tail -1 | awk '{print $NF}'; } 2>/dev/null || true)
fi

echo "== fwuid       : ${FWUID:0:40}${FWUID:+…}"
echo "== app_loaded  : ${APP_LOADED:0:40}${APP_LOADED:+…}"
echo "== aura_token  : ${AURA_TOKEN:0:40}${AURA_TOKEN:+…}"
echo

if [ -z "$FWUID" ] || [ -z "$APP_LOADED" ] || [ -z "$AURA_TOKEN" ]; then
  echo "FAIL: missing FWUID/APP_LOADED/AURA_TOKEN from BetaFeaturesSetup page load" >&2
  exit 1
fi

# 5. build and POST the Aura action
# NOTE: descriptor was renamed from enableBetaFeatureWithoutCascade -> enableBetaFeature
# (verified 2026-08-31 against HCOrg3). The old name still returns HTTP 200 but with
# an empty actions[] array — a silent no-op. Do NOT restore the old name.
MSG_JSON="{\"actions\":[{\"id\":\"1;a\",\"descriptor\":\"serviceComponent://ui.cdp.components.setup.controllers.CdpSetupController/ACTION\$enableBetaFeature\",\"callingDescriptor\":\"UNKNOWN\",\"params\":{\"betaFeatureName\":\"${BETA_FEATURE_NAME}\"}}]}"
CTX_JSON="{\"mode\":\"PROD\",\"fwuid\":\"${FWUID}\",\"app\":\"one:one\",\"loaded\":{\"APPLICATION@markup://one:one\":\"${APP_LOADED}\"},\"dn\":[],\"globals\":{\"setupAppContextId\":\"all\",\"density\":\"VIEW_ONE\"},\"uad\":true}"
URI="/lightning/setup/BetaFeaturesSetup/home"

m=$(MSG="$MSG_JSON" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['MSG']))")
c=$(CTX="$CTX_JSON" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['CTX']))")
t=$(TOK="$AURA_TOKEN" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['TOK']))")
u=$(URI_="$URI" python -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['URI_']))")

respfile="$WORK/resp.json"
code=$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o "$respfile" -w "%{http_code}" \
  -X POST "${LIGHTNING_URL}/aura?r=1&ui-cdp-components-setup-controllers.CdpSetup.enableBetaFeature=1" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "Origin: ${SETUP_URL}" -H "Referer: ${SETUP_URL}${URI}" \
  -H "User-Agent: Mozilla/5.0" \
  --data "message=${m}&aura.context=${c}&aura.pageURI=${u}&aura.token=${t}")

state=$(RESPFILE_WIN="$(cygpath -w "$respfile")" python -c "
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
            if 'already' in msg.lower() or 'enabled' in msg.lower():
                print('IDEMPOTENT')
            else:
                print(f'ERROR:{msg[:200]}')
        else:
            ret = a.get('returnValue')
            print(f'{st}:{ret}' if ret is not None else st)
    elif 'actions' in d and not d['actions']:
        # Empty actions[] = Salesforce silently dropped the descriptor (stale name).
        # Not idempotent success; treat as failure so caller notices.
        print('STALE_DESCRIPTOR:server dropped action (renamed descriptor)')
    elif 'exceptionMessage' in d:
        print(f\"EXCEPTION:{d['exceptionMessage'][:200]}\")
    elif 'event' in d and 'descriptor' in d.get('event',{}):
        print(f\"EVENT:{d['event']['descriptor']}\")
    else:
        print(f'UNKNOWN_SHAPE:{list(d.keys())[:5]}')
except Exception as e:
    print(f'PARSE_ERR:{e}:{raw[:120]!r}')
")

echo "== HTTP=$code  aura_state=$state"
case "$state" in
  SUCCESS*|IDEMPOTENT)
    echo "== ✅ Notebook AI enabled (or already enabled)"
    exit 0
    ;;
  *)
    echo "== ⚠️  Enable failed — see $respfile for full response"
    head -c 2000 "$respfile"
    echo
    exit 1
    ;;
esac
