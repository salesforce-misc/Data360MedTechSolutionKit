---
name: embed-service-agent-on-experience-site
description: "Configure a Salesforce Embedded Service (Agentforce Service Agent) deployment for use on an external website. Built incrementally — currently covers Step 1: Enable Messaging Channel (LiveMessageSettings.enableLiveMessage = true via Metadata API), Step 2: Register Site Domain (Visualforce a4j POST against /udd/Site/customSubdomain.apexp accepting Sites Terms of Use), Step 3: Install Embedded Service Package + Activate Messaging Channel (sf project deploy start -d ps-embeddedservice + sf apex run -f scripts/apex/activateMessagingChannel.apex), Step 4: Trusted Domains for Inline Frames (Metadata API CustomSite deploy sets the ESW_ESA Site iframe whitelist to exactly one host-only entry — the Experience Cloud Sites Domain `<prefix>.my.site.com`), Step 5: Publish ESA Web Deployment (salesforce-headless-360 MCP `dispatch` → POST /services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<EmbeddedServiceConfigId> where the Id is looked up via Tooling SOQL on EmbeddedServiceConfig.DeveloperName='ESA_Web_Deployment'; returns HTTP 201 {isSuccess:true} — pure API, no browser), and Step 6: Create a New Version of the Omni-Channel Flow (SOQL lookup of current org's ServiceChannel/Queue/BotDefinition IDs + Python substitution of stale source-org IDs in the repo's Route_Conversations_to_Agentforce_Service_Agents flow XML + Metadata API deploy — Salesforce auto-handles the version transition). All 6 steps are pure CLI / MCP — no Playwright anywhere. Use when the user wants to: 'enable messaging channel', 'register site domain', 'install embedded service package', 'activate messaging channel', 'add trusted domain for inline frames', 'publish ESA web deployment', 'publish embedded service', 'create new version of omni-channel flow', 'route conversations to PulseSync Assistant', 'refresh stale flow IDs', or otherwise begin wiring up a Salesforce service agent for an external site."
---

# embed-service-agent-on-experience-site

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"embed-service-agent-on-experience-site"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: embed-service-agent-on-experience-site already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Build the configuration required to embed an Agentforce Service Agent on an external website. The skill scope is **exactly 6 steps**: Step 1 (Enable Messaging Channel), Step 2 (Register Site Domain), Step 3 (Install Embedded Service Package + Activate Messaging Channel), Step 4 (Trusted Domains for Inline Frames), Step 5 (Publish ESA Web Deployment), Step 6 (Create a New Version of the Omni-Channel Flow). Each step was added one verified test at a time against a real org. **All 6 steps are implemented and verified.** **All 6 steps are pure CLI / MCP — no Playwright anywhere.** Step 5 previously used Playwright to click the Setup Publish button; it now dispatches the Connect API endpoint `POST /services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<Id>` through the `salesforce-headless-360` MCP (verified 2026-07-14 on org 00DJ5000000HYtg, HTTP 201 `{"isSuccess": true}`). CORS Configuration and Trusted URL / CSP Configuration are explicitly **out of scope** for this skill.

**Why incremental:** every Salesforce metadata type behaves slightly differently across API versions and org types. Adding all steps up front and hoping they work risks shipping broken automation. Each new step must be deployed once against a real org, the working command + response captured, and only then committed to this skill.

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username. The org must already be authenticated via `sf org login web -a <alias>`.
- `external_website_url` (currently unused — placeholder for a future iframe-allowlist refinement): The external website URL where the agent will be embedded. **Must be `https://`, must NOT end with `/`.** Example: `https://www.example.com`.

**Note:** Step 5 previously required a `username`+`password` pair for Playwright login. Those arguments are **no longer needed** — Step 5 now dispatches the Connect API `POST /connect/embeddedservice/embeddedserviceconfig/publish/<Id>` endpoint through the `salesforce-headless-360` MCP, which reuses the org's already-authenticated OAuth token from `/mcp-setup`.

---

## Preconditions

- Salesforce CLI installed and authenticated with the target org
- User has System Administrator profile or equivalent permissions
- For uninterrupted execution, `.claude/settings.json` should pre-approve:
  ```json
  {
    "permissions": {
      "allow": [
        "Bash:sf *",
        "Bash:mkdir *",
        "Bash:rm *"
      ]
    }
  }
  ```

---

## Workflow

```
Step 1: Enable Messaging Channel
   ↓ (runtime: retrieve LiveMessageSettings → flip enableLiveMessage to true → deploy → verify → cleanup)
Step 2: Register Site Domain
   ↓ (a) probe /udd/Site/customSubdomain.apexp — if registration form is absent, already done
   ↓ (b) if form is present: extract ViewState fields, POST with termsCB=on + registerDomain action
   ↓ (c) verify by re-probing the page (form must now be absent / page bounces to /0DM/o)
Step 3: Install Embedded Service Package + Activate Messaging Channel
   ↓ (a) sf project deploy start -d ps-embeddedservice
   ↓ (b) sf apex run -f scripts/apex/activateMessagingChannel.apex
   ↓ (c) verify MessagingChannel.ESA_Channel.IsActive = true
Step 4: Trusted Domains for Inline Frames (on the ESW_ESA Site provisioned by Step 3)
   ↓ (a) locate the ESW_ESA Site (Name LIKE 'ESW_ESA_Web_Deployment_%' AND UrlPathPrefix LIKE '%vforcesi')
   ↓ (b) detect My Domain prefix from instanceUrl
   ↓ (c) retrieve CustomSite, replace <siteIframeWhiteListUrls> block with the single Experience Cloud Sites Domain entry
   ↓     (<prefix>.my.site.com — NO scheme, NO path)
   ↓ (d) deploy → verify via SOQL → cleanup
Step 5: Publish ESA Web Deployment (salesforce-headless-360 MCP — pure API, no browser)
   ↓ (a) Tooling SOQL via mcp__salesforce-sobject-all__soqlQuery: SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='ESA_Web_Deployment'
   ↓ (b) mcp__salesforce-headless-360__dispatch → POST /services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<Id>
   ↓ (c) expect HTTP 201 with body {"isSuccess": true, ...} — publish is fire-and-forget on Salesforce's side
Step 6: Create a New Version of the Omni-Channel Flow
   ↓ (a) look up current org's ServiceChannel(LiveMessage), Queue(Messaging_Queue), BotDefinition(PulseSync Assistant) IDs
   ↓ (b) stage repo flow XML and substitute the 4 stale values (serviceChannelId, queueId, copilotId, copilotLabel)
   ↓ (c) sf project deploy start --source-dir → Salesforce auto-deactivates v1 + auto-activates v2
   ↓ (d) verify v2.Status='Active' and v2.Metadata has the corrected IDs → cleanup
```

---

### Step 1 — Enable Messaging Channel

**🚨 Verified working approach (deployed successfully on OrgRetailTest35 on 2026-06-12, deploy id `0Afbm00000Vr4lJCAR`):** the org-level "Messaging" toggle on `Setup → Messaging Settings` is controlled by the **`LiveMessageSettings`** metadata type with field `enableLiveMessage`.

**Why this type and not others:**

- The toggle's DOM (input id `liveMessageToggle`, name `toggle-livemessage`) maps to `LiveMessageSettings.enableLiveMessage`.
- `sf org list metadata --metadata-type Settings` lists `LiveMessage | Settings` as an available member, confirming the type name.
- The legacy `LiveAgentSettings` type is for the retired Live-Agent-chat product and is NOT what the modern Setup page binds to. `EngagementMessagingSettings` is queryable as an SObject but is not a deployable Settings metadata type.

**🚨 NEVER-DISABLE GUARD.** This step ONLY enables Messaging — it must never set `enableLiveMessage` to `false`. The skill works by retrieving the current state, **only** flipping `false` → `true`, and skipping the deploy entirely if the state is already `true`. There is no code path in this skill that can demote the setting from `true` back to `false`. Do NOT add such logic.

**Why runtime-retrieve-then-deploy (instead of shipping a template file):**

- The retrieved file already has the correct schema, namespace, and any version-specific fields the org expects. Hand-authoring a template can drift from what the org actually accepts.
- One source of truth: the org's own retrieve output. No template file to keep in sync.
- Fewer files in the skill folder = less to maintain. Cleanup is just `rm` of the runtime temp dir.

#### 1.1 Pre-check: retrieve current `enableLiveMessage` state

```bash
mkdir -p /c/tmp/dsaew-step1
sf project retrieve start \
  --target-org <org_alias> \
  --metadata "Settings:LiveMessage" \
  --output-dir /c/tmp/dsaew-step1 \
  --json
```

Expected file path on success: `/c/tmp/dsaew-step1/settings/LiveMessage.settings-meta.xml`

Read the current value:

```bash
CURRENT=$(grep -o '<enableLiveMessage>[^<]*</enableLiveMessage>' \
  /c/tmp/dsaew-step1/settings/LiveMessage.settings-meta.xml \
  | sed 's/<[^>]*>//g')
echo "Pre-deploy enableLiveMessage = $CURRENT"
```

**Decision tree:**

| `CURRENT` value | What to do |
|---|---|
| `true` | Already enabled. **Skip 1.2 entirely.** Jump to Step 1.3 (verify) and Step 1.4 (cleanup). Report `state: NoChange (already enabled)`. |
| `false` | Expected initial state. Proceed to 1.2 to flip it. |
| File missing / parse error / anything else | STOP per the orchestrator's strict error-resolution rule. Surface `ls -la /c/tmp/dsaew-step1/settings/` and the file contents to the user. |

#### 1.2 Flip `false` → `true` and deploy

In-place edit the retrieved file (no template, no separate folder):

```bash
sed -i 's|<enableLiveMessage>false</enableLiveMessage>|<enableLiveMessage>true</enableLiveMessage>|' \
  /c/tmp/dsaew-step1/settings/LiveMessage.settings-meta.xml
```

Verify the edit landed:

```bash
grep enableLiveMessage /c/tmp/dsaew-step1/settings/LiveMessage.settings-meta.xml
# Must print: <enableLiveMessage>true</enableLiveMessage>
```

Deploy via `--source-dir`:

```bash
sf project deploy start \
  --target-org <org_alias> \
  --source-dir /c/tmp/dsaew-step1/settings \
  --json
```

> **Why `--source-dir` and not `--manifest` with a hand-rolled `package.xml`:** explicitly authoring `<name>LiveMessageSettings</name>` in `package.xml` triggered `Unknown type name 'LiveMessageSettings'` errors during local validation against this org's API version. The `--source-dir` form lets the CLI infer the manifest from the file itself and worked first try.

Expected JSON shape on success:

```json
{
  "result": {
    "status": "Succeeded",
    "success": true,
    "id": "0Afbm00000Vr4lJCAR",
    "details": {
      "componentSuccesses": [
        { "componentType": "LiveMessageSettings", "fullName": "LiveMessage", "state": "Changed" }
      ]
    }
  }
}
```

- `state: Changed` → toggle flipped from `false` to `true`. Proceed to 1.3.
- `state: NoChange` → already enabled (user pre-flipped it between 1.1 and 1.2). Proceed to 1.3.
- `status: Failed` → STOP per the strict error-resolution rule. Surface the `componentFailures[].problem` to the user.

#### 1.3 Verify via fresh retrieve

```bash
rm -rf /c/tmp/dsaew-step1-verify
mkdir -p /c/tmp/dsaew-step1-verify
sf project retrieve start \
  --target-org <org_alias> \
  --metadata "Settings:LiveMessage" \
  --output-dir /c/tmp/dsaew-step1-verify \
  --json

VERIFY=$(grep -o '<enableLiveMessage>[^<]*</enableLiveMessage>' \
  /c/tmp/dsaew-step1-verify/settings/LiveMessage.settings-meta.xml \
  | sed 's/<[^>]*>//g')
echo "Post-deploy enableLiveMessage = $VERIFY"
```

`VERIFY` MUST be `true`. If it's still `false`, the deploy didn't apply — STOP per the strict error-resolution rule and surface `/c/tmp/dsaew-step1-verify/settings/LiveMessage.settings-meta.xml` to the user.

#### 1.4 Cleanup runtime temp directories

Per the orchestrator's strict error-resolution rule: clean up only on full success. If any sub-step failed and was not resolved, leave artifacts in `/c/tmp/dsaew-step1*/` for debugging.

```bash
rm -rf /c/tmp/dsaew-step1
rm -rf /c/tmp/dsaew-step1-verify
```

Verify (must show no leftovers):

```bash
ls -d /c/tmp/dsaew-step1 /c/tmp/dsaew-step1-verify 2>&1 | grep -v "cannot access"
```

#### 1.5 Report

```text
✅ Step 1 — Enable Messaging Channel: COMPLETE

Org: <org_alias>
Pre-deploy state:  enableLiveMessage = <CURRENT>
Post-deploy state: enableLiveMessage = true (verified)
Deploy id:         <r.id from 1.2>
Component state:   <state from 1.2>  (Changed | NoChange)
```

---

### Step 2 — Register Site Domain

**🚨 Verified working approach on OrgRetailTest35 on 2026-06-12.** This action is the manual checklist step "Navigate to Setup → Sites → check the Sites Terms of Use checkbox → click Register My Salesforce Site Domain."

**Why no documented public API exists** (verified by elimination):

| Path tried | Result |
|---|---|
| Direct REST `PATCH /sobjects/Site/<id>` with `{Subdomain: ...}` | `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` — `Site` is not REST-writable |
| Metadata API `Settings:Site` (`SiteSettings`) | Has only `enableExpBuilderCopilot`, `enableProxyLoginICHeader`, `enableTopicsInSites` — no domain registration / ToU field |
| Metadata API `Settings:MyDomain` (`MyDomainSettings`) | Has `myDomainName` and `redirectForceComSiteUrls` but no Sites ToU acceptance flag |
| Metadata API `CustomSite` deploy with `<subdomain>` element added | Deploy reported `Succeeded` but `Site.Subdomain` stayed `null` — Salesforce silently ignored the element |
| Tooling SObject `CustomDomain` | `INVALID_TYPE` — does not exist on this org's API version |

**Working approach: Visualforce a4j POST against `/udd/Site/customSubdomain.apexp`** — the same endpoint the Setup UI uses. The page exposes a Visualforce + a4j AJAX form. Posting to it with `termsCB=on` + the `registerDomain` action key (plus the standard ViewState fields the page emits) registers the domain. Verified live: `Setup → Sites` page transitioned from showing the registration form to bouncing to `/0DM/o` (Sites list) after a single POST.

**🚨 Internal endpoint disclaimer.** `/udd/Site/customSubdomain.apexp` and the four `com.salesforce.visualforce.ViewState*` form fields are **not part of any documented public API**. They are Salesforce's internal Setup page wiring. They have been stable for years but Salesforce does not guarantee them. If a future Salesforce release breaks this pattern, fall back to a manual UI click and the rest of the skill still works (Step 2.0 detects the registered state on its own and short-circuits).

**No Playwright. Pure cURL.**

#### 2.0 Pre-check: detect whether the domain is already registered

The Setup page **renders the registration form only when the domain is not yet registered**. After registration, the same URL bounces to `/0DM/o` (the Sites list). This makes detection trivial: fetch the page, look for the literal text `"Register My Salesforce Site Domain"`. If absent → already registered, skip Step 2.

```bash
INSTANCE_URL=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")
ACCESS_TOKEN=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")

# Establish a real web session via frontdoor.jsp (Visualforce setup pages need a session cookie, NOT a Bearer token)
mkdir -p /c/tmp/dsaew-step2
COOKIES=/c/tmp/dsaew-step2/cookies.txt
PAGE=/c/tmp/dsaew-step2/page.html
rm -f "$COOKIES" "$PAGE"

curl -s -L -c "$COOKIES" \
  "${INSTANCE_URL}/secur/frontdoor.jsp?sid=${ACCESS_TOKEN}" \
  -o /dev/null

curl -s -L -b "$COOKIES" -c "$COOKIES" \
  "${INSTANCE_URL}/udd/Site/customSubdomain.apexp" \
  -o "$PAGE"

if grep -q "Register My Salesforce Site Domain" "$PAGE"; then
  echo "STATE=NotRegistered"   # proceed to 2.1
else
  echo "STATE=AlreadyRegistered"   # skip 2.1, jump to 2.3 verify
fi
```

- `NotRegistered` → proceed to 2.1.
- `AlreadyRegistered` → skip 2.1, jump straight to Step 2.3 (verify probe again confirms registered state, then 2.4 cleanup, 2.5 report).

#### 2.1 Extract ViewState fields and POST the registration

The Visualforce page emits four required form fields plus the form's data and the action button name. Extract them from the page already retrieved in 2.0, then POST.

```bash
python << 'PYEOF' > /c/tmp/dsaew-step2/postbody.txt
import re, urllib.parse
content = open(r'C:\tmp\dsaew-step2\page.html', encoding='utf-8', errors='replace').read()
def grab(name):
    m = re.search(r'<input[^>]+name="' + re.escape(name) + r'"[^>]+value="([^"]*)"', content)
    if not m: raise SystemExit(f'missing form field: {name}')
    return m.group(1)
fields = [
    ('AJAXREQUEST', '_viewRoot'),
    ('thePage:theForm', 'thePage:theForm'),
    ('thePage:theForm:setDomainPB:termsCB', 'on'),
    ('com.salesforce.visualforce.ViewState', grab('com.salesforce.visualforce.ViewState')),
    ('com.salesforce.visualforce.ViewStateVersion', grab('com.salesforce.visualforce.ViewStateVersion')),
    ('com.salesforce.visualforce.ViewStateMAC', grab('com.salesforce.visualforce.ViewStateMAC')),
    ('com.salesforce.visualforce.ViewStateCSRF', grab('com.salesforce.visualforce.ViewStateCSRF')),
    ('thePage:theForm:setDomainPB:registerDomain', 'thePage:theForm:setDomainPB:registerDomain'),
]
print(urllib.parse.urlencode(fields), end='')
PYEOF

# POST it
RESP=/c/tmp/dsaew-step2/postresp.html
curl -s -X POST "${INSTANCE_URL}/udd/Site/customSubdomain.apexp" \
  -b "$COOKIES" -c "$COOKIES" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "X-Requested-With: XMLHttpRequest" \
  -H "Accept: text/xml,application/xml" \
  -H "Faces-Request: partial/ajax" \
  -H "Referer: ${INSTANCE_URL}/udd/Site/customSubdomain.apexp" \
  --data-binary @/c/tmp/dsaew-step2/postbody.txt \
  -o "$RESP" -w "HTTP %{http_code}\n"

# Success indicator: the response is an a4j redirect XML pointing to /0DM/o
grep -q 'Ajax-Response.*redirect' "$RESP" && grep -q '/0DM/o' "$RESP" \
  && echo "POST result: registration submitted (redirect → /0DM/o)" \
  || { echo "❌ unexpected response — see $RESP"; exit 1; }
```

- Response contains `Ajax-Response: redirect` and `Location: /0DM/o` → registration accepted. Proceed to 2.2 verify.
- Anything else → STOP per the strict error-resolution rule. Surface `$RESP` to the user.

#### 2.2 Verify by re-probing the page

The same probe used in 2.0. After a successful registration, the form must be gone — the page now bounces to `/0DM/o`.

```bash
PAGE2=/c/tmp/dsaew-step2/page-after.html
curl -s -L -b "$COOKIES" -c "$COOKIES" \
  "${INSTANCE_URL}/udd/Site/customSubdomain.apexp" \
  -o "$PAGE2"

if grep -q "Register My Salesforce Site Domain" "$PAGE2"; then
  echo "❌ Domain still NOT registered — registration POST failed silently"; exit 1
else
  echo "✅ Domain registered — Setup page no longer renders the registration form"
fi
```

#### 2.3 Cleanup runtime temp directory

```bash
rm -rf /c/tmp/dsaew-step2
```

Verify (must show no leftovers):

```bash
ls -d /c/tmp/dsaew-step2 2>&1 | grep -v "cannot access"
```

**Cleanup-on-failure policy** (security): the cookie jar `cookies.txt` contains a live OAuth session cookie. **Always delete on both success AND failure paths.** Token leakage risk if left on disk. The page HTML files contain the same session cookie embedded in CSRF tokens and should also always be deleted.

#### 2.4 Report

```text
✅ Step 2 — Register Site Domain: COMPLETE

Org:               <org_alias>
Pre-state:         <NotRegistered | AlreadyRegistered>
POST result:       <registration submitted | skipped (already registered)>
Post-state:        Domain registered (Setup page no longer renders the form)
```

---

### Step 3 — Install Embedded Service Package + Activate Messaging Channel

**🚨 Verified working approach on OrgRetailTest35 on 2026-06-12 (deploy id `0Afbm00000VsCtZCAV`, 30 components Created, 0 failures).** This step matches the manual checklist:

```
- Install Embedded Service Package:
  sf project deploy start -d ps-embeddedservice.

- Activate Messaging Channel:
  sf apex run -f scripts/apex/activateMessagingChannel.apex
```

Pure CLI — no API calls, no Visualforce magic, no metadata templates.

#### 3.1 Deploy `ps-embeddedservice`

```bash
sf project deploy start \
  --target-org <org_alias> \
  --source-dir ps-embeddedservice \
  --json
```

Expected components (verified live — order may vary):

| Type | Name |
|---|---|
| `EmbeddedServiceConfig` | `ESA_Web_Deployment` |
| `MessagingChannel` | `ESA_Channel` |
| `Flow` | `Route_Conversations_to_Agentforce_Service_Agents` |
| `CustomSite` | `ESW_ESA_Web_Deployment_<timestamp>` |
| `Network` | `ESW_ESA_Web_Deployment_<timestamp>` |
| `DigitalExperienceBundle` | `site/ESW_ESA_Web_Deployment_<timestamp>1` |
| `DigitalExperience` | 17 nested children of the bundle |
| `Queue` | `Messaging_Queue` |
| `QueueRoutingConfig` | `Messaging_Routing_Channel` |
| `BrandingSet`, `NetworkBranding`, `StaticResource`, `DigitalExperienceConfig` | one each |

Total: 30 components. Verify the JSON response shows `status: Succeeded`, `success: true`, and `componentFailures: []` (or null). Any failures → STOP per the strict error-resolution rule.

> **Why this also creates an ESW Site that needs a Trusted Domain entry later.** The deploy provisions a brand-new `CustomSite: ESW_ESA_Web_Deployment_<timestamp>` plus its `1`-suffixed sibling. The "Trusted Domains for Inline Frames" allowlist for embedding the agent on the external website lives on **this** new CustomSite. That is the future Roadmap step (currently shown in the Setup UI as `Trusted Domains for Inline Frames` on the ESW deployment site), and it will be added to this skill once verified. **Step 3 only deploys the package — it does not configure the iframe allowlist.**

#### 3.2 Activate the Messaging Channel

```bash
sf apex run \
  --target-org <org_alias> \
  -f scripts/apex/activateMessagingChannel.apex
```

The Apex file ships with the repo and contains:

```apex
MessagingChannel channel = [SELECT Id, IsActive FROM MessagingChannel WHERE DeveloperName='ESA_Channel' LIMIT 1];
channel.IsActive = true;
update channel;
```

Verify the CLI output reads `Compiled successfully.` and `Executed successfully.` (no exceptions). Any `Execute Anonymous error` → STOP per the strict error-resolution rule and surface the apex log.

#### 3.3 Verify via SOQL

```bash
INSTANCE_URL=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")
ACCESS_TOKEN=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")

curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Id, DeveloperName, MasterLabel, IsActive FROM MessagingChannel WHERE DeveloperName='ESA_Channel'" \
  | python -c "
import json, sys
d = json.load(sys.stdin)
recs = d.get('records', [])
if not recs:
    print('❌ ESA_Channel MessagingChannel not found'); sys.exit(1)
ch = recs[0]
print(f\"ESA_Channel id={ch['Id']} | IsActive={ch['IsActive']}\")
sys.exit(0 if ch['IsActive'] else 1)
"
```

`IsActive=True` → proceed to 3.4. `False` or not found → STOP per the strict error-resolution rule.

#### 3.4 Report

```text
✅ Step 3 — Install Embedded Service Package + Activate Messaging Channel: COMPLETE

Org:                       <org_alias>
Deploy id:                 <r.id from 3.1>
Components Created:        <count from 3.1>
Component failures:        0
ESA_Channel.IsActive:      true (verified via SOQL)
ESW Site provisioned:      ESW_ESA_Web_Deployment_<timestamp>  ← Step 4 adds the iframe whitelist entries here
```

---

### Step 4 — Trusted Domains for Inline Frames

**🚨 Verified working approach on OrgRetailTest35 on 2026-06-12 (final deploy id `0Afbm00000VsJ8gCAF`).** Adds **the Experience Cloud Sites Domain** to the **`Trusted Domains for Inline Frames`** list on the ESW_ESA Site that Step 3 provisioned. The list lives on the `CustomSite` metadata as repeated `<siteIframeWhiteListUrls><url>...</url></siteIframeWhiteListUrls>` elements; no separate metadata type exists for it.

**Why exactly one URL — the Experience Cloud Sites Domain:** the only place the embedded service iframe is rendered for this installer is the **PulseSync Experience Cloud Site** at `<prefix>.my.site.com/PulseSync`. Salesforce only checks the **host** of the parent page (not the path) against this allowlist, so a single host-level entry `<prefix>.my.site.com` covers PulseSync and any other Experience Cloud site under the same host. The Salesforce Sites Domain (`*.my.salesforce-sites.com`) and My Domain (`*.my.salesforce.com`) are NOT needed for this installer because the agent is never embedded on Force.com Sites pages or directly on Lightning/Setup pages — only on the Experience Cloud storefront.

| Domain added | Source |
|---|---|
| `<myDomainPrefix>.my.site.com` | Experience Cloud Sites Domain — covers PulseSync and all other Experience sites on this org |

**🚨 Salesforce only accepts host-level entries — no scheme, no path.** Verified by deploy errors:

| Tried | Result |
|---|---|
| `https://storm-...my.site.com/PulseSync` (full URL with path) | ❌ `Enter a valid URL or URI. Use one of these formats: example.com, example.com:8080, *.example.com, https://example.com, or wss://example.com.` |
| `https://storm-...my.site.com` (host with scheme) | ✅ Works, but stored as-is — the UI shows the scheme |
| `storm-...my.site.com` (host only, no scheme) | ✅ Works — cleanest form, matches the format the UI displays |

**Use the host-only form (no scheme).**

**🚨 The deploy is a FULL replacement.** A `CustomSite` deploy replaces the full `<siteIframeWhiteListUrls>` set — what's in the deployed XML becomes the complete list. Re-deploying with 1 entry when the org has 3 will delete the other 2 (this is exactly how this skill simplified from the earlier 3-URL state to the current 1-URL state — by re-deploying with only the desired entry).

#### 4.1 Locate the ESW_ESA Site

The Step 3 deploy provisions two related Sites: a bare-name one (`ESW_ESA_Web_Deployment_<timestamp>` with `urlPathPrefix` ending in `vforcesi`) and a `1`-suffixed sibling (`...<timestamp>1`). The Setup → Embedded Service Deployments → ESA Web Deployment link points at the **bare-name** Site — that's where the iframe whitelist must live.

```bash
INSTANCE_URL=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")
ACCESS_TOKEN=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")

ESW_ESA_SITE_NAME=$(curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Name FROM Site WHERE Name LIKE 'ESW_ESA_Web_Deployment_%' AND UrlPathPrefix LIKE '%vforcesi' AND Status='Active' ORDER BY Name LIMIT 1" \
  | python -c "
import json, sys
d = json.load(sys.stdin)
recs = d.get('records', [])
print(recs[0]['Name'] if recs else '')
")

if [ -z "$ESW_ESA_SITE_NAME" ]; then
  echo "❌ No active ESW_ESA Site with urlPathPrefix ending '...vforcesi' found. Has Step 3 (deploy ps-embeddedservice) completed?"; exit 1
fi
echo "ESW_ESA Site Name: $ESW_ESA_SITE_NAME"
```

If empty → STOP per the strict error-resolution rule. The most likely cause is Step 3 hasn't been run yet.

#### 4.2 Compute the target Experience Cloud Sites Domain from the instance URL

```bash
# instanceUrl looks like: https://storm-359e620867b1f4.my.salesforce.com
# Extract the My Domain prefix and append .my.site.com (Experience Cloud Sites Domain)
MY_DOMAIN_PREFIX=$(echo "$INSTANCE_URL" | sed -E 's|https?://([^.]+)\..*|\1|')
TARGET_URL="${MY_DOMAIN_PREFIX}.my.site.com"
echo "My Domain prefix:           $MY_DOMAIN_PREFIX"
echo "Target Experience Cloud URL: $TARGET_URL"
```

#### 4.3 Retrieve the CustomSite

```bash
mkdir -p /c/tmp/dsaew-step4
sf project retrieve start \
  --target-org <org_alias> \
  --metadata "CustomSite:${ESW_ESA_SITE_NAME}" \
  --output-dir /c/tmp/dsaew-step4 \
  --json

SITE_FILE="/c/tmp/dsaew-step4/sites/${ESW_ESA_SITE_NAME}.site-meta.xml"
[ -f "$SITE_FILE" ] || { echo "❌ Retrieve did not produce $SITE_FILE"; exit 1; }
```

#### 4.4 Set the iframe whitelist to exactly one entry + deploy

The skill enforces a **canonical single-entry state**: after this step the ESW_ESA Site's iframe whitelist contains exactly `<prefix>.my.site.com` and nothing else. Any pre-existing entries (host-only forms, `https://`-prefixed forms, leftover entries from earlier Step 4 attempts, or extra org-policy URLs the user may have added manually) are **replaced**, not merged. This matches the "set the trusted domain to the Experience Cloud Sites Domain" instruction in the manual checklist.

> If you need to ADD a new entry while preserving custom URLs the user has manually added, see the **Step 4.4 alt — union-merge** section at the end of Step 4 below. The default replace-all behavior is what was verified end-to-end on OrgRetailTest35.

```bash
python << 'PYEOF'
import os, re

site_file = os.environ['SITE_FILE']
target = os.environ['TARGET_URL']
content = open(site_file, encoding='utf-8').read()

# Extract existing <url> values for the report
existing = re.findall(r'<siteIframeWhiteListUrls>\s*<url>([^<]+)</url>\s*</siteIframeWhiteListUrls>', content)
print('Existing entries:', existing)

# Idempotency: if existing == [target] exactly, no-op
if existing == [target]:
    print(f'NoChange: iframe whitelist already contains exactly {target}')
    raise SystemExit(0)

# Replace the entire <siteIframeWhiteListUrls> block set with a single canonical entry
# Strip ALL existing <siteIframeWhiteListUrls>...</siteIframeWhiteListUrls> blocks first
content_new = re.sub(
    r'(    <siteIframeWhiteListUrls>\s*<url>[^<]+</url>\s*</siteIframeWhiteListUrls>\s*)+',
    '',
    content,
    flags=re.MULTILINE,
)
new_block = (
    f'    <siteIframeWhiteListUrls>\n'
    f'        <url>{target}</url>\n'
    f'    </siteIframeWhiteListUrls>\n'
)
content_new, n = re.subn(r'(    <siteType>)', new_block + r'\1', content_new, count=1)
if n != 1:
    raise SystemExit('failed to find <siteType> anchor')

open(site_file, 'w', encoding='utf-8', newline='').write(content_new)
print(f'Wrote 1 entry: {target}')
PYEOF

# Deploy
sf project deploy start \
  --target-org <org_alias> \
  --source-dir /c/tmp/dsaew-step4/sites \
  --json \
  | python -c "
import json, sys
d = json.load(sys.stdin); r = d.get('result', {})
print('status:', r.get('status'), 'success:', r.get('success'), 'id:', r.get('id'))
for c in r.get('details', {}).get('componentSuccesses') or []:
    print(' OK ', c.get('componentType'), '|', c.get('fullName'), '|', c.get('state'))
for c in r.get('details', {}).get('componentFailures') or []:
    print(' FAIL', c.get('componentType'), '|', c.get('fullName'), '|', c.get('problem'))
"
```

- `status: Succeeded` with one `CustomSite` component → proceed to 4.5.
- Any `componentFailures[].problem` mentioning `Enter a valid URL or URI` → STOP. The skill wrote a `<url>` value Salesforce rejects (path, scheme on wrong domain, malformed). Surface the exact failure message and the offending `<url>` line.
- Other deploy failures → STOP per the strict error-resolution rule.

#### 4.5 Verify via SOQL

```bash
SITE_ID=$(curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Id FROM Site WHERE Name='${ESW_ESA_SITE_NAME}'" \
  | python -c "import json,sys; print(json.load(sys.stdin)['records'][0]['Id'])")

curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Url FROM SiteIframeWhiteListUrl WHERE SiteId='${SITE_ID}' ORDER BY Url" \
  | python -c "
import json, sys, os
d = json.load(sys.stdin)
urls = [r['Url'] for r in d.get('records', [])]
target = os.environ['TARGET_URL']
print('Iframe whitelist on the ESW_ESA Site:')
for u in urls: print(' -', u)
print(f'Target ({target}) present:', target in urls)
print(f'Exactly one entry:', len(urls) == 1)
sys.exit(0 if (target in urls and len(urls) == 1) else 1)
"
```

Target present AND exactly one entry → proceed to 4.6. Either missing → STOP per the strict error-resolution rule and surface the SOQL response.

#### 4.6 Per-step cleanup

Per-step cleanup runs ONLY on success of this step. The Final cleanup section at the end of the skill runs unconditionally as a backstop.

```bash
rm -rf /c/tmp/dsaew-step4
```

#### 4.7 Report

```text
✅ Step 4 — Trusted Domains for Inline Frames: COMPLETE

Org:                  <org_alias>
ESW_ESA Site:         <ESW_ESA_SITE_NAME> (Site Id: <SITE_ID>)
My Domain prefix:     <MY_DOMAIN_PREFIX>
Target URL:           <TARGET_URL>  ← single Experience Cloud Sites Domain entry, host-only form
Pre-deploy entries:   <list from 4.4 Python>
Post-deploy entries:  1 (verified via SOQL)
Component state:      <Changed | NoChange (already exactly this single entry)>
Deploy id:            <id from 4.4 — only when state was Changed>
```

---

#### Step 4.4 alt — union-merge (NOT the default)

If a future need arises to **add** the Experience Cloud Sites Domain while preserving entries the user added manually (e.g. additional partner Experience sites), use this Python rewriter instead of the replace-all variant in 4.4. **This is NOT the default** — it's parked here for reference.

```python
existing_set = set(existing)
if target not in existing_set:
    # Append target to the existing list, preserve order
    final_urls = existing + [target]
else:
    final_urls = existing
# (then re-emit ALL final_urls as <siteIframeWhiteListUrls> blocks before <siteType>)
```

---

### Step 5 — Publish ESA Web Deployment

**🚨 Verified working approach on 00DJ5000000HYtg on 2026-07-14 (HTTP 201, `{"isSuccess": true}`).** This step used to require Playwright — the Setup UI Publish button was the only reliable surface after the previous "no public API exists" investigation. That investigation missed a Connect REST endpoint that Salesforce added: `POST /services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<EmbeddedServiceConfigId>`. Re-testing against the `salesforce-headless-360` MCP confirmed this endpoint publishes the deployment in one call, no browser, no username/password.

**Why the switch to headless-360 (and away from Playwright):**
- **No browser session needed.** Playwright required a fresh username+password every run because Lightning Setup pages reject the CLI's API-only token. headless-360 reuses the org's already-authenticated OAuth token that `/mcp-setup` cached.
- **Deterministic response.** HTTP 201 + `{"isSuccess": true}` is a machine-readable success signal. Playwright's "click Publish then leave it" was fire-and-forget with no verification path.
- **Faster.** ~1 second (single HTTP call) versus ~15–20 seconds (browser navigate + login + wait + click).
- **No credentials.** The username+password args are no longer needed for this step.

**The endpoint URL is computed, not hardcoded.** The `EmbeddedServiceConfig.Id` is org-specific — look it up at runtime via Tooling SOQL on `EmbeddedServiceConfig.DeveloperName='ESA_Web_Deployment'`. On the verified test org (00DJ5000000HYtg) the Id was `04IJ5000000XZJ5MAO` and the working POST URL was `/services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/04IJ5000000XZJ5MAO`.

#### 5.1 Pre-check: look up the EmbeddedServiceConfig Id

Use the `salesforce-sobject-all` MCP's `soqlQuery` tool with `useToolingApi: true` (EmbeddedServiceConfig is a setup metadata entity — the standard Data API returns `INVALID_TYPE`).

```
mcp__salesforce-sobject-all__soqlQuery({
  q: "SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='ESA_Web_Deployment' LIMIT 1",
  useToolingApi: true
})
```

Extract `records[0].Id` from the response and hold it as `$ESA_CONFIG_ID`. If the array is empty, Step 3 (Install Embedded Service Package) has not completed — stop and surface the error.

#### 5.2 Pre-write capability probe — verify `dispatch` (write) path is live

Step 5.1's `soqlQuery` proves the `salesforce-sobject-all` MCP is authenticated, but not that the `salesforce-headless-360` `dispatch` capability (a different MCP server, different OAuth session) actually works. Probe it with a cheap read-only call BEFORE the first `dispatch` POST — this catches an expired or wrong-org headless-360 session before publishing.

```
mcp__salesforce-headless-360__dispatch_readonly({
  method: "GET",
  path: "/services/data/v67.0/limits"
})
```

**Pass condition:** any 2xx response.

**Fail behavior:**
- `invalid_grant` / `INVALID_SESSION_ID` / `401` → the headless-360 MCP OAuth token expired or is authenticated for a different org. STOP; instruct the user to re-run `/mcp-setup <org_alias>`. Do NOT proceed to 5.3.
- Any other non-2xx → surface verbatim, STOP.

#### 5.3 POST the publish endpoint via `salesforce-headless-360`

The headless-360 MCP's `dispatch` tool accepts any Salesforce Connect / REST API endpoint under `/services/data/*`. No auth header assembly — the MCP injects the cached OAuth token automatically.

```
mcp__salesforce-headless-360__dispatch({
  method: "POST",
  path: "/services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<ESA_CONFIG_ID>",
  body: {}
})
```

**Expected response** (verified 2026-07-14 on 00DJ5000000HYtg):

```json
{
  "status": 201,
  "body": {
    "isSuccess": true,
    "publishStatus": "Success",
    "embeddedServiceConfigId": "04IJ5000000XZJ5MAO"
  }
}
```

**Success gate:** `body.isSuccess === true` AND `status === 201`. Anything else → surface the response to the user and stop.

#### 5.4 No cleanup, no lingering browser

Step 5 creates no on-disk artefacts, opens no browser, and holds no session. The MCP call returns immediately and the skill advances to Step 6.

#### 5.5 Report

```text
✅ Step 5 — Publish ESA Web Deployment: COMPLETE

Org:                       <org_alias>
EmbeddedServiceConfig Id:  <ESA_CONFIG_ID>
Endpoint invoked:          POST /services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<ESA_CONFIG_ID>
Transport:                 salesforce-headless-360 MCP (dispatch)
Response:                  HTTP 201 · isSuccess=true · publishStatus=Success
```

**Real-world reference (00DJ5000000HYtg, 2026-07-14):** EmbeddedServiceConfig Id `04IJ5000000XZJ5MAO`. Dispatched via `mcp__salesforce-headless-360__dispatch` with `method=POST` and `path=/services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/04IJ5000000XZJ5MAO`. Response was HTTP 201 with `{"isSuccess": true, "publishStatus": "Success"}`. No browser, no username/password, no lingering session.

**Fallback (only if the Connect endpoint returns 404 on a future release):** revert to Playwright by re-adding the previous logic (git blame this file for the last Playwright version). The rest of the skill remains unchanged.

---

### Step 6 — Create a New Version of the Omni-Channel Flow

**🚨 Verified working approach on OrgRetailTest35 on 2026-06-12 (deploy id `0Afbm00000VsXA1CAN`).** The repo's `Route_Conversations_to_Agentforce_Service_Agents.flow-meta.xml` ships with **4 stale Salesforce IDs** that point at a different (source) org. The manual checklist's "deactivate → re-pick service channel → re-pick agent → re-pick queue → save as new version → activate" sequence is exactly Salesforce's UI nudge to refresh those 4 IDs against the current org. This skill does the same refresh declaratively: look up current IDs via SOQL, substitute them into a staged copy of the XML, deploy.

**Salesforce auto-handles version transitions on flow deploy.** When `sf project deploy start` deploys a flow XML whose previous version was `Active`, Salesforce automatically:
1. Deactivates the previous version (sets `Status: Obsolete`)
2. Creates a new version with `VersionNumber = previous + 1`
3. Activates the new version (sets `Status: Active`)

No Tooling API PATCH is needed. No explicit deactivate-first step is needed. **One `sf project deploy start` call replaces the entire 6-click manual sequence.**

**The 4 stale values to replace** (verified by inspecting the repo XML at [ps-embeddedservice/main/default/flows/Route_Conversations_to_Agentforce_Service_Agents.flow-meta.xml](ps-embeddedservice/main/default/flows/Route_Conversations_to_Agentforce_Service_Agents.flow-meta.xml)):

| Field name in XML | Stale value (source org, `*ak0*` prefix) | Fix: query the current org for |
|---|---|---|
| `serviceChannelId` | `0N9ak000002SmzqCAC` | `SELECT Id FROM ServiceChannel WHERE DeveloperName='sfdc_livemessage'` |
| `queueId` | `00Gak00000P0YzOEAV` | `SELECT Id FROM Group WHERE Type='Queue' AND DeveloperName='Messaging_Queue'` |
| `copilotId` | `0Xxak000001ppCnCAI` | `SELECT Id FROM BotDefinition WHERE MasterLabel='PulseSync Assistant'` |
| `copilotLabel` | `PulseSync Assistant` (the repo already ships this correct label) | The literal string `PulseSync Assistant` — org-independent, no substitution needed |

The other input parameters in the flow (`serviceChannelLabel`, `serviceChannelDevName`, `routingType`, `queueLabel`) are **org-independent strings** — they don't need refreshing.

#### 6.1 Look up the 4 current org IDs

```bash
INSTANCE_URL=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")
ACCESS_TOKEN=$(sf org display --target-org <org_alias> --json | python -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")

# ServiceChannel for LiveMessage
SERVICE_CHANNEL_ID=$(curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Id FROM ServiceChannel WHERE DeveloperName='sfdc_livemessage' LIMIT 1" \
  | python -c "import json,sys; r=json.load(sys.stdin)['records']; print(r[0]['Id'] if r else '')")

# Queue Messaging_Queue
QUEUE_ID=$(curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Id FROM Group WHERE Type='Queue' AND DeveloperName='Messaging_Queue' LIMIT 1" \
  | python -c "import json,sys; r=json.load(sys.stdin)['records']; print(r[0]['Id'] if r else '')")

# BotDefinition PulseSync Assistant
COPILOT_ID=$(curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/query" \
  --data-urlencode "q=SELECT Id FROM BotDefinition WHERE MasterLabel='PulseSync Assistant' LIMIT 1" \
  | python -c "import json,sys; r=json.load(sys.stdin)['records']; print(r[0]['Id'] if r else '')")

# All three must be non-empty
if [ -z "$SERVICE_CHANNEL_ID" ] || [ -z "$QUEUE_ID" ] || [ -z "$COPILOT_ID" ]; then
  echo "❌ Missing IDs:"
  echo "  ServiceChannel(LiveMessage):       $SERVICE_CHANNEL_ID"
  echo "  Group(Messaging_Queue):            $QUEUE_ID"
  echo "  BotDefinition(PulseSync Assistant): $COPILOT_ID"
  echo ""
  echo "Prerequisite sources:"
  echo "  • ServiceChannel(LiveMessage) + Group(Messaging_Queue) → provisioned by Step 3 (deploy ps-embeddedservice)"
  echo "  • BotDefinition(PulseSync Assistant)                    → provisioned by ps-post-pack (deployed by the installer BEFORE this skill runs)"
  echo ""
  echo "If a specific ID is empty, confirm the corresponding source deployment completed against <org_alias>."
  exit 1
fi
echo "ServiceChannel(LiveMessage):       $SERVICE_CHANNEL_ID"
echo "Group(Messaging_Queue):            $QUEUE_ID"
echo "BotDefinition(PulseSync Assistant): $COPILOT_ID"
```

If any ID is missing → STOP per the orchestrator's strict error-resolution rule. The most likely cause is Step 3 hasn't been run yet (it ships the messaging channel, queue, and bot).

#### 6.2 Stage the flow XML and substitute the 4 stale values

```bash
mkdir -p /c/tmp/dsaew-step6/flows
cp ps-embeddedservice/main/default/flows/Route_Conversations_to_Agentforce_Service_Agents.flow-meta.xml \
   /c/tmp/dsaew-step6/flows/

FLOW_FILE=/c/tmp/dsaew-step6/flows/Route_Conversations_to_Agentforce_Service_Agents.flow-meta.xml

python << PYEOF
p = r"$FLOW_FILE"
sc, q, c = "$SERVICE_CHANNEL_ID", "$QUEUE_ID", "$COPILOT_ID"
s = open(p, encoding='utf-8').read()

# The 3 stale IDs that the manual UI workflow refreshes.
# copilotLabel is already correct in the repo XML (`PulseSync Assistant`) and is
# org-independent, so no substitution is required for it — the manual UI step of
# "choose PulseSync Assistant" leaves the same label value in place.
replacements = {
    '0N9ak000002SmzqCAC': sc,                                              # serviceChannelId
    '00Gak00000P0YzOEAV': q,                                               # queueId
    '0Xxak000001ppCnCAI': c,                                               # copilotId
}
for old, new in replacements.items():
    if old not in s:
        # Idempotency: if the file was already-corrected (e.g. previous Step 6 run), skip
        print(f'(skip) {old[:40]}... not found — already replaced or repo XML changed')
        continue
    s = s.replace(old, new)
    print(f'replaced {old[:40]}... -> {new[:40]}...')
open(p, 'w', encoding='utf-8', newline='').write(s)
PYEOF
```

> **Why the 4 stale IDs are in the repo at all:** the flow XML was authored in a different Salesforce org and committed to the repo. Salesforce IDs are 18-char org-specific identifiers (the 4–6th chars indicate the source org's pod/instance), so any flow that hardcodes IDs and gets shared across orgs has this problem. The manual checklist's "re-pick the dropdown values" sequence is the UI workaround; this skill's substitution is the declarative equivalent.

#### 6.3 Deploy — Salesforce handles the version dance

```bash
sf project deploy start \
  --target-org <org_alias> \
  --source-dir /c/tmp/dsaew-step6/flows \
  --json \
  | python -c "
import json, sys
d = json.load(sys.stdin); r = d.get('result', {})
print('status:', r.get('status'), 'success:', r.get('success'), 'id:', r.get('id'))
for c in r.get('details', {}).get('componentSuccesses') or []:
    print(' OK ', c.get('componentType'), '|', c.get('fullName'), '|', c.get('state'))
for c in r.get('details', {}).get('componentFailures') or []:
    print(' FAIL', c.get('componentType'), '|', c.get('fullName'), '|', c.get('problem'))
"
```

Expected JSON shape on success:

```json
{
  "result": {
    "status": "Succeeded",
    "success": true,
    "id": "0Afbm00000VsXA1CAN",
    "details": {
      "componentSuccesses": [
        { "componentType": "Flow", "fullName": "Route_Conversations_to_Agentforce_Service_Agents", "state": "Changed" }
      ]
    }
  }
}
```

- `status: Succeeded` → proceed to 6.4.
- `status: Failed` with `INVALID_CROSS_REFERENCE_KEY` on `serviceChannelId` / `queueId` / `copilotId` → STOP. The lookup in 6.1 returned a stale value or the entity was deleted between 6.1 and 6.3. Re-run 6.1.
- Other failures → STOP per the strict error-resolution rule.

#### 6.4 Verify v2 is Active and has the corrected IDs

```bash
curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/tooling/query" \
  --data-urlencode "q=SELECT Id, VersionNumber, Status, LastModifiedDate FROM Flow WHERE MasterLabel='Route Conversations to Agentforce Service Agents' ORDER BY VersionNumber DESC LIMIT 5" \
  | python -m json.tool

# Read the active version's Metadata and assert the 4 corrected values
ACTIVE_FLOW_ID=$(curl -s -G -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/tooling/query" \
  --data-urlencode "q=SELECT Id FROM Flow WHERE MasterLabel='Route Conversations to Agentforce Service Agents' AND Status='Active' LIMIT 1" \
  | python -c "import json,sys; r=json.load(sys.stdin)['records']; print(r[0]['Id'] if r else '')")

curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${INSTANCE_URL}/services/data/v62.0/tooling/sobjects/Flow/${ACTIVE_FLOW_ID}" \
  | python -c "
import json, sys, os
d = json.load(sys.stdin)
md = d.get('Metadata', {})
print(f\"VersionNumber={d['VersionNumber']}, Status={d['Status']}\")
ip_map = {}
for ac in md.get('actionCalls', []) or []:
    if ac.get('name') == 'Route_to_agent':
        for ip in ac.get('inputParameters', []):
            v = ip.get('value', {})
            if v: ip_map[ip.get('name')] = v.get('stringValue')
expected = {
    'serviceChannelId': os.environ['SERVICE_CHANNEL_ID'],
    'queueId': os.environ['QUEUE_ID'],
    'copilotId': os.environ['COPILOT_ID'],
    'copilotLabel': 'PulseSync Assistant',
}
ok = True
for k, want in expected.items():
    got = ip_map.get(k)
    mark = '✅' if got == want else '❌'
    if got != want: ok = False
    print(f'  {mark} {k}: {got}')
sys.exit(0 if ok else 1)
" SERVICE_CHANNEL_ID="$SERVICE_CHANNEL_ID" QUEUE_ID="$QUEUE_ID" COPILOT_ID="$COPILOT_ID"
```

All 4 values must match. Any `❌` → STOP per the strict error-resolution rule and surface the SOQL response.

#### 6.5 Per-step cleanup

```bash
rm -rf /c/tmp/dsaew-step6
```

Per-step cleanup runs ONLY on success of this step. The Final cleanup section at the end of the skill runs unconditionally as a backstop.

#### 6.6 Report

```text
✅ Step 6 — Create a New Version of the Omni-Channel Flow: COMPLETE

Org:                      <org_alias>
Flow:                     Route Conversations to Agentforce Service Agents
Pre-deploy active version: v<N> (auto-deactivated)
New active version:        v<N+1> (verified Status='Active')
Refreshed IDs:
  • serviceChannelId =     <SERVICE_CHANNEL_ID>
  • queueId =              <QUEUE_ID>
  • copilotId (PulseSync Assistant) = <COPILOT_ID>
  • copilotLabel =         PulseSync Assistant
Deploy id:                 <r.id from 6.3>
Component state:           Changed
```

---

## Final cleanup (MANDATORY before skill returns)

After all completed steps' per-step cleanup runs (Step 1.4, Step 2.3), execute one final cleanup pass that nukes **every** artefact this skill could have created — even if a per-step cleanup was skipped, blocked by a `Permission denied`, or interrupted before reaching its own cleanup. This is a security backstop: several of these temp files contain a live OAuth session cookie or a frontdoor URL with the access token in the query string.

**Always run this on BOTH the success and failure paths.** On a partial-failure path (e.g. Step 2 succeeded, Step 3 failed) the per-step cleanups for completed steps already deleted their own files, but the failed step may have left token-bearing artefacts on disk — that's exactly why this final pass exists.

```bash
# Step 1 staging dirs
rm -rf /c/tmp/dsaew-step1
rm -rf /c/tmp/dsaew-step1-verify

# Step 2 staging dir (cookies.txt, page.html, page-after.html, postbody.txt, postresp.html)
rm -rf /c/tmp/dsaew-step2

# Step 3 has no on-disk staging — `sf project deploy start -d ps-embeddedservice` operates on
# the existing repo source and `sf apex run -f scripts/apex/...` reads an existing repo file. No
# temp dirs are created by Step 3, so nothing to delete here.

# Step 4 staging dir (retrieved CustomSite XML for the ESW_ESA Site)
rm -rf /c/tmp/dsaew-step4

# Step 5 has no on-disk staging — the salesforce-headless-360 MCP dispatches the publish
# endpoint via an HTTP call and returns immediately. Nothing to delete here.

# Step 6 staging dir (corrected Flow XML)
rm -rf /c/tmp/dsaew-step6

# Verification (must show no leftovers)
ls -d /c/tmp/dsaew-step1 /c/tmp/dsaew-step1-verify /c/tmp/dsaew-step2 /c/tmp/dsaew-step4 /c/tmp/dsaew-step6 2>&1 | grep -v "cannot access"
```

**Token-leakage rules** (these files MUST be deleted even on a failure path):

| File | Why it's sensitive |
|---|---|
| `/c/tmp/dsaew-step2/cookies.txt` | Contains the live `sid` session cookie set by `/secur/frontdoor.jsp?sid=<token>` |
| `/c/tmp/dsaew-step2/page.html` | Server-rendered HTML embeds the access token in a few internal links and the four ViewState fields can be replayed against this org for as long as the session lasts |
| `/c/tmp/dsaew-step2/postbody.txt` | URL-encoded form body that includes the four ViewState fields |
| `/c/tmp/dsaew-step2/postresp.html` | Response from the registration POST; replayable by anyone with shell access until the session expires |

**Repo files this skill never touches** — do NOT delete:
- `ps-embeddedservice/**` (repo source consumed by Step 3.1)
- `scripts/apex/activateMessagingChannel.apex` (repo source consumed by Step 3.2)
- `.claude/**` (this skill itself + other skills)

---

## Important Rules

- 🚨 **Strict error-resolution rule** (inherited from orchestrator AGENT.md): if any sub-step fails or returns an error, STOP, try the documented recovery first, and surface the error to the user with full details. Do NOT advance to the next sub-step until the user explicitly says "proceed".
- 🚨 **Never-disable guard:** the only allowed payload for `enableLiveMessage` is `true`. There is no path in this skill that writes `false`. Do not add one.
- ❌ **Do NOT modify any other working skill** under `.claude/skills/` to extend this one. New steps are added by editing THIS skill's `SKILL.md` only.
- ❌ **Do NOT ship a template `metadata/` folder.** Step 1 retrieves the relevant metadata from the org at runtime, edits in place, deploys, and cleans up. Templates would drift from what the org actually accepts across API versions.
- ❌ **Do NOT skip the Final cleanup section.** Step 2 writes a session-cookie jar and a frontdoor-token-bearing HTML page to `/c/tmp/dsaew-step2/`. Leaving those on disk is a token-leakage risk. The Final cleanup runs unconditionally on both the success path AND every failure path.
- ❌ **Do NOT use full-URL or path-bearing entries in the iframe whitelist (Step 4).** Salesforce only accepts host-only forms (`example.com`, `*.example.com`, `https://example.com`, `wss://example.com`, or `example.com:8080`). Anything else fails the deploy with `Enter a valid URL or URI`. The skill writes bare host names — no scheme, no path.
- ❌ **Do NOT trust the `<siteIframeWhiteListUrls>` block as additive.** A `CustomSite` deploy is a FULL replacement of the block. Re-deploying with 1 entry when the org has 3 deletes 2. Step 4's Python rewriter writes a canonical single-entry state (just the Experience Cloud Sites Domain) — any extra entries the user added manually will be dropped. Use the `Step 4.4 alt — union-merge` variant if you need additive behaviour.
- ❌ **Do NOT explicitly deactivate the previous flow version before deploying Step 6.** `sf project deploy start` against a flow XML whose previous version was Active triggers Salesforce's automatic version transition (old→Obsolete + new→Active). Deactivating first via Tooling API is unnecessary and risks leaving the org in a no-active-version state if the deploy then fails.
- ❌ **Do NOT use Tooling API PATCH to set `Flow.Status='Active'` after Step 6's deploy.** It's redundant — Salesforce already activated the new version automatically. The PATCH is only needed when the previous version was Inactive (rare in our installer chain).
- ✅ **Idempotent:** re-running Step 1 on an org where Messaging is already enabled is a no-op (Step 1.1 short-circuits). Re-running Step 2 on an org where the Sites domain is already registered is a no-op (Step 2.0 short-circuits — the page no longer renders the registration form). Re-running Step 3 deploys the same package; `MessagingChannel.IsActive=true` is already true on a re-run, the Apex `update` is a no-op DML. Re-running Step 4 when the iframe whitelist already contains exactly the single Experience Cloud Sites Domain entry is a no-op (Step 4.4's Python check `existing == [target]` exits before deploying). Re-running Step 6 when the staged XML matches the active version's content creates an identical v3 — Salesforce still does the version dance, but the user's runtime state is unchanged. The Python substitution loop's "(skip) ... already replaced" branch makes repeated runs visibly diff-clean.
- ✅ **One-file skill (`SKILL.md`):** no metadata folder. Step 1 uses Metadata API runtime retrieve; Step 2 uses an internal Visualforce a4j POST (no metadata file required); Step 3 uses pure CLI (`sf project deploy start` against the existing `ps-embeddedservice/` repo source + `sf apex run` against the existing `scripts/apex/activateMessagingChannel.apex`); Step 4 uses Metadata API runtime retrieve + edit-in-place + redeploy of the `CustomSite` for the ESW_ESA Site that Step 3 provisioned; Step 5 dispatches the Connect REST endpoint `POST /connect/embeddedservice/embeddedserviceconfig/publish/<Id>` through the `salesforce-headless-360` MCP after a Tooling SOQL lookup of `EmbeddedServiceConfig.DeveloperName='ESA_Web_Deployment'` — no browser, no username/password, HTTP 201 `{isSuccess:true}`; Step 6 reads the repo's flow XML, substitutes 4 stale IDs with current org values from SOQL lookups, and redeploys via Metadata API (Salesforce auto-handles the version transition).
- ✅ **Verify Step 5's response** — the dispatch call returns HTTP 201 with `{"isSuccess": true, "publishStatus": "Success"}` on success. Treat any other status or `isSuccess: false` as a hard failure and surface to the user. (This is a change from the previous Playwright implementation where verification was skipped because no API returned a result — headless-360's Connect endpoint DOES return a machine-readable result.)
- ❌ **Do NOT hardcode the EmbeddedServiceConfig Id in Step 5.** The Id is org-specific (15/18-char Salesforce ID where the 4–6th chars encode the org's pod). Always look it up at runtime via Tooling SOQL. The verified-test Id `04IJ5000000XZJ5MAO` is for 00DJ5000000HYtg only and will not work on any other org.

---

## Example Usage

### Example 1 — Step 1 only

**User:** "Enable Messaging Channel on OrgRetailTest35"

**Skill:**
1. Retrieves current `LiveMessageSettings` from the org → `enableLiveMessage = false`
2. In-place edits `/c/tmp/dsaew-step1/settings/LiveMessage.settings-meta.xml` → `enableLiveMessage = true`
3. Deploys via `sf project deploy start --source-dir /c/tmp/dsaew-step1/settings` → `state: Changed`
4. Re-retrieves to verify → `enableLiveMessage = true` ✅
5. Cleans up `/c/tmp/dsaew-step1*` directories
6. Reports the deploy id, the state transition, and verified post-deploy value

### Example 2 — Step 2 (Register Site Domain)

**User:** "Register the Salesforce Site domain on OrgRetailTest35"

**Skill:**
1. Frontdoor-authenticates: `curl /secur/frontdoor.jsp?sid=<token>` → cookie jar at `/c/tmp/dsaew-step2/cookies.txt`
2. Fetches `/udd/Site/customSubdomain.apexp` → page HTML at `/c/tmp/dsaew-step2/page.html`
3. Pre-check: page contains `"Register My Salesforce Site Domain"` → `STATE=NotRegistered`, proceed
4. Extracts the four `com.salesforce.visualforce.ViewState*` fields from the HTML
5. Builds form-urlencoded body (`AJAXREQUEST=_viewRoot`, `termsCB=on`, `registerDomain=...`, ViewState fields) → `/c/tmp/dsaew-step2/postbody.txt`
6. POSTs to `/udd/Site/customSubdomain.apexp` → response is `Ajax-Response: redirect, Location: /0DM/o` ✅
7. Re-fetches the page → registration form is gone (page bounces to `/0DM/o`) ✅
8. Final cleanup deletes `/c/tmp/dsaew-step2/` (token-leakage protection — runs on success AND failure paths)
9. Reports `Pre-state: NotRegistered, Post-state: Domain registered`

### Example 3 — Step 3 (Install Embedded Service Package + Activate Messaging Channel)

**User:** "Install the embedded service package on OrgRetailTest35"

**Skill:**
1. `sf project deploy start -d ps-embeddedservice --target-org OrgRetailTest35 --json` → 30 components Created (`EmbeddedServiceConfig`, `MessagingChannel`, `Flow`, `CustomSite`, `DigitalExperienceBundle`, `Network`, `Queue`, etc.), 0 failures
2. `sf apex run -f scripts/apex/activateMessagingChannel.apex --target-org OrgRetailTest35` → `Compiled successfully. Executed successfully.` (1 SOQL, 1 DML)
3. Verifies via `SELECT IsActive FROM MessagingChannel WHERE DeveloperName='ESA_Channel'` → `IsActive: true` ✅
4. Reports the deploy id, component count, and verified `ESA_Channel.IsActive = true`
5. Step 3 creates no on-disk artefacts — Final cleanup is still run as a backstop in case earlier steps were also part of the same skill invocation

### Example 4 — Step 4 (Trusted Domains for Inline Frames)

**User:** "Add the Experience Cloud Sites Domain to the embedded service iframe whitelist on OrgRetailTest35"

**Skill:**
1. Locates the ESW_ESA Site provisioned by Step 3 → `Name='ESW_ESA_Web_Deployment_<timestamp>'`, `urlPathPrefix` ending `vforcesi`
2. Computes My Domain prefix from `instanceUrl` → e.g. `storm-359e620867b1f4`
3. Computes the single target host: `<prefix>.my.site.com` (Experience Cloud Sites Domain)
4. `sf project retrieve start --metadata "CustomSite:<NAME>"` → `/c/tmp/dsaew-step4/sites/<NAME>.site-meta.xml`
5. Reads existing `<siteIframeWhiteListUrls>` blocks:
   - **Already exactly `[target]`** → `state: NoChange`, skip deploy, jump to verify
   - **Anything else** (empty / different / extra entries) → strips ALL existing blocks, writes one canonical `<siteIframeWhiteListUrls><url>{target}</url></siteIframeWhiteListUrls>`, deploys via `sf project deploy start --source-dir`
6. Verifies via `SELECT Url FROM SiteIframeWhiteListUrl WHERE SiteId='<id>'` → exactly one entry, equal to target ✅
7. Per-step cleanup deletes `/c/tmp/dsaew-step4/`
8. Reports the deploy id, pre-state entries, and the post-deploy single-entry whitelist

**Real-world deploy id reference (OrgRetailTest35, 2026-06-12):** `0Afbm00000VsJ8gCAF` — simplified the iframe whitelist on `ESW_ESA_Web_Deployment_1768908454395` from 2 entries (`storm-...my.site.com` + `storm-...my.salesforce.com`) down to exactly 1 entry (`storm-...my.site.com`). The earlier 3-entry deploy id `0Afbm00000VsO57CAF` represents an older variant that included Salesforce Sites Domain and My Domain — those were dropped because only the Experience Cloud Sites Domain is needed for the PulseSync embedding scenario.

### Example 5 — Step 5 (Publish ESA Web Deployment)

**User:** "Publish the ESA Web Deployment on 00DJ5000000HYtg"

**Skill:**
1. `mcp__salesforce-sobject-all__soqlQuery({ q: "SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='ESA_Web_Deployment' LIMIT 1", useToolingApi: true })` → returns `records[0].Id = 04IJ5000000XZJ5MAO`
2. `mcp__salesforce-headless-360__dispatch({ method: "POST", path: "/services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/04IJ5000000XZJ5MAO", body: {} })` → response is HTTP 201 with body `{"isSuccess": true, "publishStatus": "Success", "embeddedServiceConfigId": "04IJ5000000XZJ5MAO"}`
3. Success gate: `status === 201` AND `body.isSuccess === true` → verified ✅
4. Report to user: `Endpoint: POST /connect/embeddedservice/embeddedserviceconfig/publish/04IJ5000000XZJ5MAO · HTTP 201 · publishStatus=Success`

**Real-world reference (00DJ5000000HYtg, 2026-07-14):** EmbeddedServiceConfig Id `04IJ5000000XZJ5MAO`. Dispatched through `salesforce-headless-360` MCP — no browser, no username/password. Response: HTTP 201, `{"isSuccess": true, "publishStatus": "Success"}`. Total wall-clock: ~1 second.

### Example 6 — Step 6 (Create a New Version of the Omni-Channel Flow)

**User:** "Refresh the routing flow so the stale IDs from the source-org repo XML get replaced with this org's actual IDs"

**Skill:**
1. SOQL lookups against the current org:
   - `SELECT Id FROM ServiceChannel WHERE DeveloperName='sfdc_livemessage'` → `0N9bm000003I46gCAC`
   - `SELECT Id FROM Group WHERE Type='Queue' AND DeveloperName='Messaging_Queue'` → `00Gbm00000Kg1llEAB`
   - `SELECT Id FROM BotDefinition WHERE MasterLabel='PulseSync Assistant'` → `0Xxbm000002DEqQCAW`
2. Stages `ps-embeddedservice/.../Route_Conversations_to_Agentforce_Service_Agents.flow-meta.xml` to `/c/tmp/dsaew-step6/flows/`
3. Python substitutes the 3 stale IDs: `serviceChannelId`, `queueId`, `copilotId` (each replaced with the SOQL result). `copilotLabel` is already `PulseSync Assistant` in the repo XML and is org-independent, so no substitution is required for it — the manual UI's "choose PulseSync Assistant" step leaves the same label value in place.
4. `sf project deploy start --source-dir /c/tmp/dsaew-step6/flows --json` → `Status: Succeeded`. Salesforce auto-deactivates v1 (sets `Status: Obsolete`) and auto-activates v2 (sets `Status: Active`)
5. Verifies via Tooling SOQL → v2 is `Active`, all 4 fields (3 refreshed IDs + the pre-existing `PulseSync Assistant` label) match ✅
6. Per-step cleanup deletes `/c/tmp/dsaew-step6/`
7. Reports the deploy id, version transition, and the 4 refreshed values

**Real-world deploy id reference (OrgRetailTest35, 2026-06-12):** `0Afbm00000VsXA1CAN` — went from `v1 (Active, with 4 stale source-org IDs)` → `v1 (Obsolete) + v2 (Active, with the 4 corrected current-org IDs)`. Single `sf project deploy start` call replaced the entire 6-click manual sequence (deactivate → re-pick service channel → re-pick agent → re-pick queue → save as new version → activate).

---

## Failure scenarios (and where the strict rule applies)

| Failure | Sub-step | Action |
|---|---|---|
| `sf org display` returns "no such org" | (precondition) | STOP. Tell user to run `sf org login web -a <alias>`. |
| **Step 1** ||
| Step 1.1 retrieve returns `Failed` or empty file | 1.1 | STOP. Surface CLI output. Likely the org doesn't expose `Settings:LiveMessage`. |
| Pre-deploy state is neither `true` nor `false` (e.g. file malformed) | 1.1 | STOP. Surface the file contents. |
| `sed` edit fails or grep verification doesn't show `true` | 1.2 | STOP. Surface the file. |
| Deploy returns `status: Failed` | 1.2 | STOP. Surface `componentFailures[].problem`. |
| Post-deploy verify still shows `false` | 1.3 | STOP. Surface re-retrieved file. |
| **Step 2** ||
| `frontdoor.jsp` returns login form (cookie jar empty) | 2.0 | STOP. CLI session expired — user must run `sf org login web -a <alias>` and retry. |
| `customSubdomain.apexp` page fetch returns non-200 or empty body | 2.0 | STOP. Surface page content + HTTP code. Likely a setup-domain redirect issue. |
| Required ViewState fields missing in retrieved page HTML | 2.1 | STOP. Salesforce changed the page structure. Surface the page HTML for human inspection. |
| POST response is NOT `Ajax-Response: redirect → /0DM/o` | 2.1 | STOP. Surface the response body. Either ToU acceptance failed or the form contract changed. |
| Verify probe still finds the registration form after POST | 2.2 | STOP. Surface the post-POST page HTML. The POST silently failed despite returning success-shaped XML. |
| **Step 3** ||
| `sf project deploy start -d ps-embeddedservice` returns `Failed` | 3.1 | STOP. Surface `componentFailures[].problem`. Common causes: missing `LiveMessageSettings.enableLiveMessage = true` (Step 1 not done) or unregistered Sites domain (Step 2 not done). |
| `sf apex run` reports compile error or `Execute Anonymous error` | 3.2 | STOP. Surface the apex log. Most likely cause: Step 3.1 didn't complete, so `MessagingChannel.ESA_Channel` doesn't exist. |
| Verify shows `IsActive=False` after Apex run | 3.3 | STOP. Surface SOQL response. Apex DML committed but `IsActive` didn't flip — investigate validation rules / org permissions. |
| **Step 4** ||
| No active ESW_ESA Site with `urlPathPrefix` ending `vforcesi` found | 4.1 | STOP. Step 3 (deploy `ps-embeddedservice`) hasn't completed or its CustomSite was renamed. |
| `sf project retrieve` produces no Site XML file | 4.3 | STOP. Surface CLI output. The ESW_ESA Site name from 4.1 didn't match a deployable CustomSite member. |
| `<siteType>` anchor not found in retrieved XML | 4.4 | STOP. Salesforce changed the CustomSite schema or the retrieved file is empty. Surface `$SITE_FILE`. |
| Deploy fails with `Enter a valid URL or URI` | 4.4 | STOP. The skill wrote a `<url>` value Salesforce rejects. Verify all entries are bare hosts (no scheme, no path). Surface the offending `<url>` line. |
| Deploy fails for any other reason | 4.4 | STOP. Surface `componentFailures[].problem`. |
| Post-deploy SOQL verify shows the target URL absent OR more than 1 entry remains | 4.5 | STOP. Surface the SOQL response and the deployed `$SITE_FILE` for diff. Either the deploy didn't apply (deferred-deploy artefact) or the rewriter's strip-all regex missed an existing block (anchor mismatch in the regex). |
| **Step 5** ||
| Tooling SOQL returns 0 records for `EmbeddedServiceConfig.DeveloperName='ESA_Web_Deployment'` | 5.1 | STOP. Step 3 (deploy `ps-embeddedservice`) hasn't completed — it provisions the EmbeddedServiceConfig. |
| `salesforce-headless-360` MCP not available / unauthenticated | 5.2 | STOP. Re-run `/mcp-setup` — Step 5 depends on the 4th hosted MCP being registered. Verify via `claude mcp list` that `salesforce-headless-360` is present with a valid token. |
| Dispatch returns HTTP 404 (endpoint not found) | 5.2 | STOP. Salesforce may have moved / retired the endpoint. Surface the response. Fallback: revert Step 5 to the Playwright implementation (see git blame for the last Playwright version). |
| Dispatch returns HTTP 401 / 403 | 5.2 | STOP. OAuth token is stale or the user lacks the `Modify All Data` / `Customize Application` permission required to publish. Re-run `/mcp-setup` to refresh tokens; if still failing, assign the missing permset. |
| Dispatch returns HTTP 201 but body has `isSuccess: false` | 5.2 | STOP. Surface the full response body. Salesforce accepted the request but rejected the publish — usually a pre-condition (e.g. deployment is in an invalid state, missing required config). |
| Dispatch returns HTTP 5xx | 5.2 | Retry once after 30s. If still 5xx, STOP and surface. Salesforce platform issue. |
| **Step 6** ||
| One or more of the 3 SOQL ID lookups returns 0 records | 6.1 | STOP. The current org doesn't have the prerequisite entity. Prerequisite sources: `ServiceChannel(LiveMessage)` + `Group(Messaging_Queue)` come from Step 3's `ps-embeddedservice` deploy; `BotDefinition(PulseSync Assistant)` comes from `ps-post-pack` (deployed by the installer BEFORE this skill). Surface the missing entity name so the operator can verify the corresponding source deployment. |
| Python substitution prints `(skip) ...` for ALL 4 values on first run | 6.2 | This is fine ONLY if the deploy below proceeds and v+1 is created — that means the repo XML was already pre-corrected by an earlier run. If the substitution skipped because the repo file's stale IDs are different from what's documented here, the skill's hardcoded "stale value" list is out of date. STOP and surface the file. |
| Deploy returns `INVALID_CROSS_REFERENCE_KEY` on `serviceChannelId` / `queueId` / `copilotId` | 6.3 | STOP. The lookup in 6.1 returned a stale value or the entity was deleted between 6.1 and 6.3. Re-run 6.1. |
| Deploy returns `Failed` for any other reason | 6.3 | STOP. Surface `componentFailures[].problem`. |
| Verify shows v_new is `Inactive` instead of `Active` | 6.4 | STOP. Salesforce did not auto-activate the new version. The previous version may have been Inactive (rare in our installer chain). Manually PATCH `Flow.Status='Active'` via Tooling API on the new version's Id, then re-run 6.4. |
| Verify shows v_new is Active but one of the 4 fields doesn't match | 6.4 | STOP. Surface the diff. Salesforce accepted the deploy but a field didn't apply — likely an org-level validation rule on the flow input parameter. |

---

## Scope (6 steps total — fixed)

The skill scope is fixed at 6 steps. Anything not on this list is **deliberately out of scope** and must NOT be added without an explicit instruction from the user.

| Step | Status | Pattern |
|---|---|---|
| 1. Enable Messaging Channel | ✅ Implemented | Metadata API runtime retrieve + edit-in-place + deploy of `LiveMessageSettings` |
| 2. Register Site Domain | ✅ Implemented | Visualforce a4j POST against the internal `/udd/Site/customSubdomain.apexp` Setup endpoint |
| 3. Install Embedded Service Package + Activate Messaging Channel | ✅ Implemented | Pure CLI: `sf project deploy start -d ps-embeddedservice` + `sf apex run -f scripts/apex/activateMessagingChannel.apex` |
| 4. Trusted Domains for Inline Frames | ✅ Implemented | Metadata API runtime retrieve + Python rewriter (canonical single Experience Cloud Sites Domain entry, host-only) + redeploy `CustomSite` |
| 5. Publish ESA Web Deployment | ✅ Implemented (salesforce-headless-360 MCP — pure API) | Tooling SOQL on `EmbeddedServiceConfig.DeveloperName='ESA_Web_Deployment'` to get the Id via `mcp__salesforce-sobject-all__soqlQuery` (with `useToolingApi: true`), then `mcp__salesforce-headless-360__dispatch` → `POST /services/data/v67.0/connect/embeddedservice/embeddedserviceconfig/publish/<Id>`. Returns HTTP 201 with `{"isSuccess": true, "publishStatus": "Success"}` — machine-readable success. No browser, no username/password, no lingering session. Reuses the OAuth token that `/mcp-setup` cached for the `salesforce-headless-360` MCP. |
| 6. Create a New Version of the Omni-Channel Flow | ✅ Implemented | SOQL lookup of current org IDs (`ServiceChannel`/`Group`/`BotDefinition`) + Python substitution of repo's stale source-org IDs + Metadata API redeploy of the flow XML. Salesforce auto-handles the version transition (old→Obsolete + new→Active). |

**Out of scope (NOT in this skill):**

- ❌ CORS Configuration — adding entries to `CorsWhitelistOrigin` (external website URL, `*.my.salesforce-scrt.com`, CloudFront image host).
- ❌ Trusted URL / CSP Configuration — adding entries to `CspTrustedSite` (external website URL with `frame-src`, CloudFront images host with `img-src + style-src`).

These are intentionally NOT part of this skill. The user has scoped this skill to exactly the 6 steps above. If a future user asks to add CORS or CSP automation, that is a **separate skill**.

No shipped metadata templates anywhere in this skill — every step retrieves what it needs from the org at runtime, edits in place, and redeploys.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"embed-service-agent-on-experience-site"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.embed-service-agent-on-experience-site` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
