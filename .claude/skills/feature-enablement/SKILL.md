---
name: feature-enablement
description: Automate Salesforce org feature enablement using Metadata API for Data Cloud, Einstein, Agentforce, Person Account, Allow OAuth User-Agent Flows, and Require PKCE Extension for Supported Authorization Flows (6 features across 5 Settings types). Uses Playwright MCP only for the Data Cloud Architect permission set step.
---

# feature-enablement

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"feature-enablement"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: feature-enablement already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Automate Salesforce org feature enablement with the **fewest possible Metadata API round-trips** and **zero user-facing manual remediation prompts**.

- **Metadata API path (consolidated, 6 features across 5 Settings types):** Data Cloud, Einstein, Agentforce, Person Account, Allow OAuth User-Agent Flows, Require PKCE Extension for Supported Authorization Flows → **ONE combined retrieve** + **ONE combined deploy** of only the settings that need flipping. The two OAuth toggles (User-Agent Flows + PKCE) share a single `OauthOidcSettings` metadata file — they always retrieve together and either both stay put or both deploy together as one member.
- **Playwright MCP path (1 task, ALWAYS Playwright):** Toggle the "default" data space in the Data Cloud Architect (`force.GenieAdmin`) permission set. The toggle is not exposed via Metadata API, Tooling API, Connect REST, or any other public Salesforce API.

**No manual remediation. Ever.** The skill never tells the user "open this URL in your browser and click X". Either the skill performs the action, or it logs that the action wasn't possible and continues to the next step / skill. The only hard stops are when the Metadata API itself rejects work (Step 1 retrieve fails, Step 3 deploy fails) — those are real failures the user must resolve before the rest of the install can run.

**Critical Constraints:**
- ❌ Do NOT generate JavaScript files
- ❌ Do NOT use Playwright for the 4 Metadata API steps
- ❌ Do NOT make per-setting retrieves or per-setting deploys
- ❌ Do NOT verify Data Cloud enablement with an extra Metadata API retrieve — Step 3.5's `/ssot/data-spaces` REST probe is the only verification, and is intentional (the Step 3 `Succeeded` status only confirms acceptance, not that async lakehouse provisioning landed)
- ❌ Do NOT ask the user to manually click anything
- ❌ Do NOT print "Manual Step Required" / "Please open this URL" / "Once you've completed this step, let me know" anywhere
- ❌ Do NOT confuse the inverted semantics of `OauthOidcSettings.blockOAuthUsrAgtFlow` — `true` = BLOCKED (UI toggle OFF), `false` = ALLOWED (UI toggle ON). The desired state for "Allow OAuth User-Agent Flows = ON" is `blockOAuthUsrAgtFlow=false`.
- ✅ Use SF CLI + Metadata API for the 6 features (one retrieve, one deploy) — 5 Settings types total; the 2 OAuth toggles share a single `OauthOidc` member backed by one `.settings` file
- ✅ Use MCP Playwright tools ONLY for the permission set step (Step 4)
- ✅ Person Account is IRREVERSIBLE — must NEVER appear in the deploy package if the retrieve already showed it as enabled
- ✅ Step 4 always closes the browser before returning, whether it succeeded, gracefully skipped, or errored

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username
- `tasks` (optional): Comma-separated list of tasks to run. If omitted, runs all tasks.
  - Valid values: `metadata` (covers all 5 Settings types — `CustomerDataPlatform`, `EinsteinGpt`, `AgentPlatform`, `Account`, `OauthOidc` — backing 6 logical features in one shot), `permission-set`
  - Example: `metadata,permission-set`
  - Legacy aliases still accepted: `data-cloud`, `einstein`, `agentforce`, `person-account`, `oauth-user-agent`, `pkce` → all map to `metadata`

---

## Preconditions

- **Caller has already run `sf org login web --alias <org_alias>` — this skill does NOT authenticate.** It will fail-fast in Step 0 if the cached session is missing.
- User has System Administrator profile or equivalent permissions
- For the `permission-set` step only: MCP Playwright tools must be available

---

## Workflow

**Step Execution Order — strictly linear:**
```
Step 0:    Verify SF CLI authentication                          [ STOP if no token ]
   ↓
Step 1:    ONE combined retrieve of all 5 Settings types         [ STOP if retrieve fails ]   ~1-2 min
           (backs 6 logical features — OauthOidc carries 2)
   ↓
Step 2:    Local XML parse → build "needs flipping" list         [ 0 API calls ]
   ↓
Step 3:    ONE combined deploy (only if list non-empty)          [ STOP if deploy fails ]   ~10-30 s
   ↓
Step 3.5:  Data Cloud provisioning HARD GATE                     [ Only if CustomerDataPlatform was flipped; blocks Step 4 until /ssot/data-spaces reports 'default' status=Active; polls up to 15 min, one re-deploy, polls another 15 min; STOPs the skill if 'default' is still not Active after 30 min ]   ~5s-30min
   ↓
Step 4:    Data Cloud Architect Permission Set → Playwright MCP  [ Graceful skip if "default" row not found; never STOPs the skill ]   ~30-60 s
   ↓
Step 5:    Cleanup + report                                      [ Always runs ]
```

**Data Cloud provisioning verification — where and why.** Step 3's `Succeeded` status means Salesforce accepted the `CustomerDataPlatform` flag, NOT that the lakehouse and `default` data space are queryable. That async provisioning is what **Step 3.5** verifies — and **blocks Step 4** until `/ssot/data-spaces` returns `default` with `status=Active`. Per user directive 2026-08-13 (`HCStrom11thAug2026Org1`): Step 4's permset toggle NEVER runs against an unprovisioned data space, because doing so leaves the org half-configured and every downstream skill fails hours later with cryptic 'default space not queryable' errors. Step 3.5 polls up to 15 min, re-deploys once, polls another 15 min, and STOPs the skill if `default` is still not `Active`.

**Notebook AI enablement — moved out.** Notebook AI beta feature enablement is owned by the `/notebook-ai` skill (Step 0), not this skill. Rationale: Notebook AI's Aura toggle has an async runtime dependency on Data Cloud lakehouse provisioning; by the time `/notebook-ai` runs later in the install, provisioning has been complete for many minutes, eliminating the race that made this fail from `/feature-enablement`. Every other toggle in this skill is synchronous; keeping this skill's contract narrow to synchronous flags makes both skills easier to reason about.

**Bounded recovery per failure mode, no loops.** Step 3.5 has at most ONE re-deploy between its two 15-min polling passes (blocking gate — STOPs the skill if `default` never becomes `Active`, per user directive 2026-08-13). Step 4 has at most ONE page refresh loop (3 attempts, ~3 min); it never retries beyond that, never prompts, never STOPs the skill — provisioning is already guaranteed by Step 3.5 by the time Step 4 runs, so any UI-side issue is a render race. Hard stops are Step 0 / 1 / 3 (Metadata API rejections) and Step 3.5 (provisioning gate exhaustion).

---

### Step 0 — Verify cached org session (NO login)

The org is authenticated **once by the calling agent** before this skill runs. This skill must NOT call `sf org login web`.

```bash
sf org display --target-org <org_alias> --json
```

- Exit code 0 and JSON contains `result.accessToken` → session is valid, proceed to Step 1.
- Command fails or no token returned → **STOP** the skill and report: `"Org session not authenticated. Caller must run: sf org login web --alias <org_alias> before invoking feature-enablement."` Do not attempt login here.

---

### Step 1 — Combined retrieve of all 5 Settings types (ONE call)

(Note: 5 Settings types back 6 logical features — `OauthOidc` carries both User-Agent Flows and PKCE.)

This single retrieve captures the live state of every setting in one Metadata API round-trip.

```bash
mkdir -p /tmp/feat-check/force-app
cat > /tmp/feat-check/sfdx-project.json <<'EOF'
{
  "packageDirectories": [{"path": "force-app", "default": true}],
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "64.0"
}
EOF
cat > /tmp/feat-check/package.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>CustomerDataPlatform</members>
        <members>EinsteinGpt</members>
        <members>AgentPlatform</members>
        <members>Account</members>
        <members>OauthOidc</members>
        <name>Settings</name>
    </types>
    <version>64.0</version>
</Package>
EOF

cd /tmp/feat-check && sf project retrieve start \
  --target-org <org_alias> \
  --manifest /tmp/feat-check/package.xml \
  --output-dir /tmp/feat-check/retrieved \
  --api-version 64.0 \
  --json > /tmp/feat-check/retrieve.json 2>&1
```

**Expected output files (all 5 must be present):**
- `/tmp/feat-check/retrieved/settings/CustomerDataPlatform.settings-meta.xml`
- `/tmp/feat-check/retrieved/settings/EinsteinGpt.settings-meta.xml`
- `/tmp/feat-check/retrieved/settings/AgentPlatform.settings-meta.xml`
- `/tmp/feat-check/retrieved/settings/Account.settings-meta.xml`
- `/tmp/feat-check/retrieved/settings/OauthOidc.settings-meta.xml`

**Single API version v64.0 everywhere** — Agentforce requires v64+, the other 4 are backward-compatible at v64.

**Failure behaviour:** If the retrieve returns `status: Failed`, or any of the 5 expected XML files is missing → **STOP** the skill. Report the verbatim `result.messages[]` and `result.files[].error` content. Nothing is deployed when retrieve fails.

---

### Step 2 — Local XML parse → build the "needs flipping" list (0 API calls)

For each setting, **add it to `NEEDS_FLIP` only if the retrieve XML did NOT show it at its desired state.**

```bash
NEEDS_FLIP=()

# 1. Data Cloud
CDP_FILE=/tmp/feat-check/retrieved/settings/CustomerDataPlatform.settings-meta.xml
if grep -q "<enableCustomerDataPlatform>true</enableCustomerDataPlatform>" "$CDP_FILE"; then
    echo "✅ Data Cloud already enabled — skipping"
else
    NEEDS_FLIP+=("CustomerDataPlatform")
fi

# 2. Einstein
EIN_FILE=/tmp/feat-check/retrieved/settings/EinsteinGpt.settings-meta.xml
if grep -q "<enableEinsteinGptPlatform>true</enableEinsteinGptPlatform>" "$EIN_FILE"; then
    echo "✅ Einstein already enabled — skipping"
else
    NEEDS_FLIP+=("EinsteinGpt")
fi

# 3. Agentforce
AP_FILE=/tmp/feat-check/retrieved/settings/AgentPlatform.settings-meta.xml
if grep -q "<enableAgentPlatform>true</enableAgentPlatform>" "$AP_FILE"; then
    echo "✅ Agentforce already enabled — skipping"
else
    NEEDS_FLIP+=("AgentPlatform")
fi

# 4. Person Account — IRREVERSIBLE, strictest check
PA_FILE=/tmp/feat-check/retrieved/settings/Account.settings-meta.xml
if grep -q "<enableAccountTeams>true</enableAccountTeams>" "$PA_FILE"; then
    echo "✅ Person Account already enabled — OMITTED from deploy (irreversible safety)"
else
    NEEDS_FLIP+=("Account")
fi

# 5. OauthOidc — backs TWO logical features in one file:
#      • Allow OAuth User-Agent Flows  → blockOAuthUsrAgtFlow=false  (NOTE: INVERTED — false = ALLOWED)
#      • Require PKCE Extension        → isPkceRequired=true
#    Add to NEEDS_FLIP only if EITHER flag is not yet at its desired state.
OAUTH_FILE=/tmp/feat-check/retrieved/settings/OauthOidc.settings-meta.xml
OAUTH_NEEDS_FLIP="no"
# User-Agent flow is enabled when blockOAuthUsrAgtFlow is false (or absent — Salesforce treats missing as default-block, so we still flip).
if grep -q "<blockOAuthUsrAgtFlow>false</blockOAuthUsrAgtFlow>" "$OAUTH_FILE"; then
    USER_AGENT_OK="yes"
else
    USER_AGENT_OK="no"
    OAUTH_NEEDS_FLIP="yes"
fi
# PKCE is enabled when isPkceRequired is true.
if grep -q "<isPkceRequired>true</isPkceRequired>" "$OAUTH_FILE"; then
    PKCE_OK="yes"
else
    PKCE_OK="no"
    OAUTH_NEEDS_FLIP="yes"
fi
if [ "$OAUTH_NEEDS_FLIP" = "no" ]; then
    echo "✅ Allow OAuth User-Agent Flows + Require PKCE Extension already enabled — skipping"
else
    NEEDS_FLIP+=("OauthOidc")
    echo "🔧 OauthOidc needs flipping (user-agent OK=$USER_AGENT_OK, pkce OK=$PKCE_OK)"
fi
```

**The "skip if already enabled" rule:**

| Setting | XML check | If passes (already enabled) | If fails (not yet enabled) |
|---|---|---|---|
| `CustomerDataPlatform` | `enableCustomerDataPlatform=true` | Omit | Add to `NEEDS_FLIP` |
| `EinsteinGpt` | `enableEinsteinGptPlatform=true` | Omit | Add to `NEEDS_FLIP` |
| `AgentPlatform` | `enableAgentPlatform=true` | Omit | Add to `NEEDS_FLIP` |
| `Account` (Person Account) | `enableAccountTeams=true` | **Omit (irreversible)** | Add to `NEEDS_FLIP` |
| `OauthOidc` (User-Agent + PKCE) | BOTH `blockOAuthUsrAgtFlow=false` AND `isPkceRequired=true` | Omit | Add to `NEEDS_FLIP` (one entry, deploys both flags together) |

If `NEEDS_FLIP` is empty after parsing → log `✅ All 6 features already at desired state — no deploy needed` and **skip Step 3**, jump straight to Step 4.

---

### Step 3 — Combined deploy of only settings that need flipping (ONE call)

Build a single deploy zip containing **only the settings in `NEEDS_FLIP`**. Settings that were already enabled never appear in the deploy package.

```bash
mkdir -p /tmp/feat-deploy/settings

# Build dynamic package.xml from NEEDS_FLIP
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
  echo '    <types>'
  for s in "${NEEDS_FLIP[@]}"; do echo "        <members>$s</members>"; done
  echo '        <name>Settings</name>'
  echo '    </types>'
  echo '    <version>64.0</version>'
  echo '</Package>'
} > /tmp/feat-deploy/package.xml

# Write only the .settings files we need to flip
for s in "${NEEDS_FLIP[@]}"; do
  case "$s" in
    CustomerDataPlatform)
      cat > /tmp/feat-deploy/settings/CustomerDataPlatform.settings <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomerDataPlatformSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <enableCustomerDataPlatform>true</enableCustomerDataPlatform>
</CustomerDataPlatformSettings>
EOF
      ;;
    EinsteinGpt)
      cat > /tmp/feat-deploy/settings/EinsteinGpt.settings <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<EinsteinGptSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <enableEinsteinGptPlatform>true</enableEinsteinGptPlatform>
</EinsteinGptSettings>
EOF
      ;;
    AgentPlatform)
      cat > /tmp/feat-deploy/settings/AgentPlatform.settings <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<AgentPlatformSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <enableAgentPlatform>true</enableAgentPlatform>
</AgentPlatformSettings>
EOF
      ;;
    Account)
      cat > /tmp/feat-deploy/settings/Account.settings <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<AccountSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <personAccountsEnabled>true</personAccountsEnabled>
</AccountSettings>
EOF
      ;;
    OauthOidc)
      # Inverted semantics on blockOAuthUsrAgtFlow:
      #   blockOAuthUsrAgtFlow=false  ⇒  "Allow OAuth User-Agent Flows" UI toggle = ON
      # Setting isPkceRequired=true enables the "Require PKCE Extension" UI toggle.
      cat > /tmp/feat-deploy/settings/OauthOidc.settings <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<OauthOidcSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <blockOAuthUsrAgtFlow>false</blockOAuthUsrAgtFlow>
    <isPkceRequired>true</isPkceRequired>
</OauthOidcSettings>
EOF
      ;;
  esac
done

# Single combined deploy
sf project deploy start \
  --target-org <org_alias> \
  --metadata-dir /tmp/feat-deploy \
  --api-version 64.0 \
  --json > /tmp/feat-deploy-result.json 2>&1
```

**Inspect deploy result:** parse `/tmp/feat-deploy-result.json` for `result.status`. Classify each setting by `result.files[].state`:

- `state == "Changed"` → newly enabled (real flip)
- `state == "Unchanged"` → already at desired state (no-op deploy, harmless)
- `state == "Failed"` → deploy failed for this setting

**Failure behaviour:** If the deploy returns `status: Failed`, Salesforce's default `rollbackOnError: true` rolls back the entire zip. **STOP** the skill. Report the verbatim error and the list of settings that were rolled back.

**Data Cloud provisioning verification happens in Step 3.5, not here.** Step 3 only confirms that Salesforce accepted the `CustomerDataPlatform` setting (`status: Succeeded`). The async lakehouse provisioning that makes the `default` data space queryable is verified by **Step 3.5** — which probes `/ssot/data-spaces` and triggers ONE re-deploy if provisioning silently stalled. We do NOT run an extra Metadata API `retrieve` here; the cheap REST probe in Step 3.5 is the source of truth for "Data Cloud is actually queryable now."

**Validated empirically:**
- 3-setting combined deploy on `storm.46e42ea62d8cc6@salesforce.com` (`CustomerDataPlatform` + `EinsteinGpt` + `AgentPlatform`, with `Account` correctly omitted) returned `status: Succeeded`, all three `state: Changed`, in ~13 seconds.
- `OauthOidc` standalone deploy on `storm.212f6f600bc026@salesforce.com` (flipping `blockOAuthUsrAgtFlow` from `true` → `false` and `isPkceRequired` from `false` → `true`) returned `status: Succeeded`, one component `state: Changed`, deploy id `0Afaj00000cTZNuCAO`, in ~4 seconds. Re-retrieve confirmed both flags landed.

---

### Step 3.5 — HARD PROVISIONING GATE: block Step 4 until the `default` data space is confirmed provisioned (poll `/ssot/data-spaces` until success)

**Why this step exists:** Step 3's `Succeeded` status means Salesforce **accepted** the `CustomerDataPlatform` flag; it does NOT mean Data Cloud's lakehouse and `default` data space are fully provisioned and queryable. Provisioning is async — typical range is 5–120 seconds, occasionally longer on trial/dev orgs. **If Step 4 runs the permset toggle before the `default` space is provisioned, the toggle either graceful-skips (leaving the org half-configured) or races the provisioning UI and saves an inconsistent state.** Step 3.5 closes that gap by turning provisioning into a **hard blocking gate** — Step 4 does NOT start until the REST surface confirms `default` is `Active`.

This is a **hard gate**, not a best-effort probe. Per user directive 2026-08-13 (`HCStrom11thAug2026Org1`): "wait until it provisioned and after that only go ahead" to enable the default space on the permset.

**When this step runs:**

- ✅ Runs only if `CustomerDataPlatform` was in `NEEDS_FLIP` (i.e. Step 3 actually flipped Data Cloud on).
- ⏭ Skipped entirely if `CustomerDataPlatform` was NOT in `NEEDS_FLIP` (Data Cloud was already enabled, so provisioning is already complete — verified by the Step 1 combined retrieve returning the flag as `true`).
- ⏭ Skipped entirely if Step 3 was skipped (no settings needed flipping at all).

**Step 3.5.1 — Poll `/ssot/data-spaces` for the `default` space until it appears with `status=Active` (blocking, up to 15 min)**

Reuse the access token and instance URL from Step 0. Poll one HTTP GET every 15 s. **The polling loop does NOT time out early.** It only exits when either (a) `default` is present AND its `status == "Active"`, or (b) the 15-minute ceiling is reached, at which point Step 3.5.2 (one-shot re-deploy) fires and polling continues.

The `status=Active` check matters: on some orgs the row can appear with `status=Provisioning` for a short window before flipping to `Active`. Toggling the permset before `Active` is a race — the UI will render the row but the backend can reject the save.

```bash
INSTANCE_URL=<from Step 0>
ACCESS_TOKEN=<from Step 0>

INTERVAL=60      # 1-min cadence, indefinite (user directive 2026-08-14)
ELAPSED=0
DEFAULT_ACTIVE="no"

echo "Step 3.5.1: polling /ssot/data-spaces every ${INTERVAL}s until 'default' is Active (no ceiling)…"

while true; do
    HTTP=$(curl -s -o /tmp/feat-dc-spaces.json -w "%{http_code}" \
      "${INSTANCE_URL}/services/data/v67.0/ssot/data-spaces" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}")
    if [ "$HTTP" = "200" ]; then
        DEFAULT_ACTIVE=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/feat-dc-spaces.json'))
    spaces = d.get('dataSpaces') or d.get('records') or []
    hit = next((s for s in spaces if (s.get('name') or s.get('developerName') or s.get('label') or '').lower() == 'default'), None)
    if hit and (hit.get('status') or '').lower() == 'active':
        print('yes')
    else:
        print('no')
except Exception:
    print('no')
")
        if [ "$DEFAULT_ACTIVE" = "yes" ]; then
            echo "✓ Data Cloud provisioning confirmed — 'default' data space is Active (after ${ELAPSED}s)"
            break
        fi
    fi
    echo "  … still provisioning at ${ELAPSED}s (HTTP=${HTTP}); next poll in ${INTERVAL}s"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done
```

- **`DEFAULT_ACTIVE == "yes"`** → provisioning landed. **Proceed to Step 4.**
- **`DEFAULT_ACTIVE == "no"` after 15 min** → provisioning has stalled. **Proceed to Step 3.5.2 (one-shot re-deploy), then to Step 3.5.3 (a second polling pass).**

**Step 3.5.2 — One-shot re-deploy of `CustomerDataPlatform` (only reached when Step 3.5.1 hits the 15-min ceiling)**

Re-deploy the exact same `CustomerDataPlatform.settings` already on disk under `/tmp/feat-deploy/settings/`. Salesforce treats this as idempotent — if the org's flag is already `true`, the redeploy is a no-op (`state: Unchanged`); if provisioning silently rolled back, the redeploy re-triggers it.

```bash
mkdir -p /tmp/feat-dc-reverify/settings

SRC=/tmp/feat-deploy/settings/CustomerDataPlatform.settings
DST=/tmp/feat-dc-reverify/settings/CustomerDataPlatform.settings
if [ -f "$SRC" ]; then
    cp "$SRC" "$DST"
    echo "Step 3.5.2: reusing CustomerDataPlatform.settings from Step 3 (/tmp/feat-deploy)"
else
    cat > "$DST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomerDataPlatformSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <enableCustomerDataPlatform>true</enableCustomerDataPlatform>
</CustomerDataPlatformSettings>
EOF
    echo "Step 3.5.2: source from Step 3 missing — wrote fresh CustomerDataPlatform.settings"
fi

cat > /tmp/feat-dc-reverify/package.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>CustomerDataPlatform</members>
        <name>Settings</name>
    </types>
    <version>64.0</version>
</Package>
EOF

sf project deploy start \
  --target-org <org_alias> \
  --metadata-dir /tmp/feat-dc-reverify \
  --api-version 64.0 \
  --json > /tmp/feat-dc-reverify-result.json 2>&1
RE_RC=$?
echo "Re-deploy exit code: $RE_RC"
```

**Step 3.5.3 — Second polling pass (blocking, up to 15 more min)**

Re-run the same polling loop from Step 3.5.1 for another 15 min. This gives the re-deploy time to trigger backend provisioning and for `default` to become `Active`.

```bash
ELAPSED=0
MAX_ELAPSED=900   # another 15 min after the re-deploy
DEFAULT_ACTIVE2="no"

echo "Step 3.5.3: second polling pass after re-deploy — max ${MAX_ELAPSED}s"

while [ $ELAPSED -lt $MAX_ELAPSED ]; do
    HTTP=$(curl -s -o /tmp/feat-dc-spaces2.json -w "%{http_code}" \
      "${INSTANCE_URL}/services/data/v67.0/ssot/data-spaces" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}")
    if [ "$HTTP" = "200" ]; then
        DEFAULT_ACTIVE2=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/feat-dc-spaces2.json'))
    spaces = d.get('dataSpaces') or d.get('records') or []
    hit = next((s for s in spaces if (s.get('name') or s.get('developerName') or s.get('label') or '').lower() == 'default'), None)
    if hit and (hit.get('status') or '').lower() == 'active':
        print('yes')
    else:
        print('no')
except Exception:
    print('no')
")
        if [ "$DEFAULT_ACTIVE2" = "yes" ]; then
            echo "✓ Data Cloud provisioning confirmed after re-deploy — 'default' is Active (after additional ${ELAPSED}s)"
            break
        fi
    fi
    echo "  … still provisioning at ${ELAPSED}s (HTTP=${HTTP}); next poll in 15s"
    sleep 15
    ELAPSED=$((ELAPSED + 15))
done
```

- **`DEFAULT_ACTIVE2 == "yes"`** → log `✅ Data Cloud provisioned after re-deploy — 'default' Active` and **proceed to Step 4.**
- **`DEFAULT_ACTIVE2 == "no"` after another 15 min (total 30 min elapsed in Step 3.5)** → **STOP the skill.** Provisioning has not landed after two polling passes and a re-deploy. Continuing to Step 4 would run the permset toggle against an unprovisioned data space, which is exactly what this gate exists to prevent.

**Step 3.5 STOP report (only reached when both polling passes exhaust without `default` becoming Active):**

```
❌ INSTALLATION HALTED — Data Cloud provisioning did not complete within the 30-minute gate

Skill: /feature-enablement
Step:  3.5 (post-deploy Data Cloud provisioning gate)

Probed:  GET ${INSTANCE_URL}/services/data/v67.0/ssot/data-spaces
Polling: 15 s cadence, 15 min ceiling per pass, one re-deploy of CustomerDataPlatform between passes
Result:  'default' data space either absent or non-Active after 30 min of polling + one re-deploy

Why this stops the installer:
  Step 4 enables the 'default' data space on the Data Cloud Architect permission set (GenieAdmin).
  Toggling it before the space is Active leaves the org half-configured — the checkbox saves
  but every downstream skill (data kit install, agentforce data library, data streams) hits
  'default space not found / not queryable' errors that surface hours later as cryptic failures.

Likely causes:
  • Trial/dev org where Data Cloud licensing has not fully activated
  • CustomerDataPlatform accepted at metadata layer but backend lakehouse provisioning failed silently
  • Region-specific provisioning outage

Suggested action:
  Wait 5–10 minutes and re-run `/feature-enablement <org_alias>`.
  The Step 1 combined retrieve will detect that CustomerDataPlatform is already true and skip Step 3,
  and Step 3.5 will start a fresh polling pass. Once 'default' is Active, Step 4 will toggle the
  permset and the installer chain can proceed.

The installer will NOT auto-continue. Waiting for the user's explicit go-ahead.
```

**Step 3.5 outcome reporting (record one of these for the Step 5 report):**

| Step 3.5 outcome | What gets logged | Skill behaviour |
|---|---|---|
| Step skipped — `CustomerDataPlatform` not in `NEEDS_FLIP` | `⏭ Data Cloud was already enabled — provisioning gate skipped` | Continue to Step 4 |
| `default` space became Active during the first polling pass | `✅ Data Cloud provisioned — 'default' Active (after Xs)` | Continue to Step 4 |
| `default` still not Active after 15 min → re-deploy → Active during second pass | `ℹ️  Data Cloud provisioning lagged; re-deployed CustomerDataPlatform → ✅ 'default' Active (after Xs total)` | Continue to Step 4 |
| `default` still not Active after re-deploy + second 15-min pass (30 min total) | `❌ Step 3.5 STOP — see report above` | **STOP the skill** — the installer chain halts here per Rule 5 of the STRICT ERROR-RESOLUTION RULE in AGENT.md |
| Re-deploy itself errored | Continue polling in Step 3.5.3 anyway — the re-deploy is idempotent, the polling gate is what matters. If Step 3.5.3 still doesn't see Active, apply the row above (STOP). |

**Step 3.5 binding rules:**

- **This is a hard gate.** Step 4 does NOT start until `/ssot/data-spaces` returns `default` with `status=Active`. No exceptions.
- At most ONE re-deploy between the two polling passes. Never loop the re-deploy.
- First polling pass: 15 s cadence, 15 min ceiling. Second polling pass: same. Total wall-clock ceiling: 30 min.
- After the 30-min ceiling, STOP the skill per the user's 2026-08-13 directive — do NOT graceful-skip forward to Step 4. The permset toggle is meaningless without a provisioned space, and running Step 4 anyway masks the provisioning failure until much later in the installer chain.
- The re-deploy uses ONLY `CustomerDataPlatform` — never the full 5-setting package. This step does not re-flip any other setting.
- No interactive input. The polling loop runs autonomously — the user only sees per-poll progress lines.

---

### Step 4 — Data Cloud Architect → "default" data space toggle (ALWAYS Playwright MCP, graceful skip)

**Why Playwright (no API alternative exists, ever):** The "Data Cloud Data Space Management → default data space → enabled" toggle inside the managed `force.GenieAdmin` permission set is **not exposed via any public Salesforce API**. Confirmed empirically:
- ❌ Metadata API `retrieve` of `PermissionSet:GenieAdmin` → `"Entity of type 'PermissionSet' named 'GenieAdmin' cannot be found"`
- ❌ Metadata API `retrieve` of `PermissionSet:force__GenieAdmin` → `"Metadata API received improper input"`
- ❌ Metadata types `DataspaceScope` and `DataSpace` are NOT registered in the Metadata Coverage Report
- ❌ Tooling API SOQL on `DataspaceScopeAccess` → `"sObject type 'DataspaceScopeAccess' is not supported"`
- ❌ `sf org list metadata --metadata-type PermissionSet` does NOT include `GenieAdmin`

UI automation via Playwright is the **only** available path.

**Graceful skip principle:** If the "Data Cloud Data Space Management" page does not render the `default` row (e.g. Data Cloud was just deployed in Step 3 and the org hasn't surfaced the data-space UI yet, or licensing keeps the section hidden), **do NOT prompt the user to do anything manually**. Log a single short note, close the browser, and let the calling agent proceed to the next skill in the install sequence.

**Step 4.0 — Load Playwright MCP tools**

```
ToolSearch("select:mcp__plugin_playwright_playwright__browser_navigate,mcp__plugin_playwright_playwright__browser_snapshot,mcp__plugin_playwright_playwright__browser_click,mcp__plugin_playwright_playwright__browser_wait_for,mcp__plugin_playwright_playwright__browser_handle_dialog,mcp__plugin_playwright_playwright__browser_close")
```

**Step 4.1 — Get instance URL and access token**

```bash
sf org display --target-org <org_alias> --json
```

Extract `result.instanceUrl` and `result.accessToken`.

**Step 4.2 — Query the permission set ID**

```bash
mkdir -p /tmp/permset-query
echo "SELECT Id FROM PermissionSet WHERE Name = 'GenieAdmin' LIMIT 1" > /tmp/permset-query/q.soql
sf data query --target-org <org_alias> --file /tmp/permset-query/q.soql --json
```

Extract `PERMSET_ID` from `result.records[0].Id`.

**If the SOQL returns 0 records** (Data Cloud not provisioned, GenieAdmin permset doesn't exist on this org) → log `ℹ️  Data Cloud Architect permission set not found in this org — skipping default data space enablement` and **continue to Step 5 (cleanup)**. Do NOT launch Playwright. Do NOT prompt the user.

**Step 4.3 — Build frontdoor URL that lands DIRECTLY on the DataspaceScopes edit page**

```
{instanceUrl}/secur/frontdoor.jsp?sid={accessToken}&retURL=/{PERMSET_ID}/e?s=DataspaceScopes
```

The `retURL` query parameter `/{PERMSET_ID}/e?s=DataspaceScopes` lands the user on the **edit form for the Data Cloud Data Space Management section** of the Data Cloud Architect permission set, bypassing two manual clicks. The page opens already in edit mode with the data-space checkboxes rendered.

**Step 4.4 — Navigate via Playwright**

```
Tool: mcp__plugin_playwright_playwright__browser_navigate
  url: <frontdoor URL from 4.3>

Tool: mcp__plugin_playwright_playwright__browser_wait_for
  time: 3
```

**Step 4.5 — Snapshot, then look for the `default` data space row**

```
Tool: mcp__plugin_playwright_playwright__browser_snapshot
```

Inspect the snapshot for a row labeled `default` containing an `Enabled` checkbox.

**Decision tree (this is the heart of the graceful-skip logic):**

- **`default` row IS in the snapshot** → proceed to Step 4.6 (click + save).

- **`default` row is NOT in the snapshot** → run **Step 4.5a** (refresh loop, up to 3 minutes). If the row still does not appear after the loop exhausts, fall through to the graceful-skip block below.

  **Rationale:** a blank `DataspaceScopes` page is usually a Lightning/Aura render race OR the org's Data Cloud provisioning is still catching up on the UI side even though Step 3.5 confirmed the `default` data space exists server-side. Give it **up to 3 minutes** by refreshing every 60 s until the row shows up. This is bounded and non-interactive. Data Cloud provisioning verification is still handled upstream in Step 3.5; this step only compensates for the UI-side lag on the DataspaceScopes edit page.

**Step 4.5a — Refresh the same URL every 60 s (max 3 attempts, ~3 min total)**

Reuse the exact frontdoor URL from Step 4.3 — do not change it, do not re-fetch the access token, do not re-query the permset ID.

Loop up to 3 times. After each `browser_navigate`, wait 60 s, snapshot, and check for the `default` row.

```
# Attempt 1
Tool: mcp__plugin_playwright_playwright__browser_wait_for
  time: 60                              # wait 1 min for the async UI to settle before re-loading

Tool: mcp__plugin_playwright_playwright__browser_navigate
  url: <same frontdoor URL from Step 4.3>

Tool: mcp__plugin_playwright_playwright__browser_wait_for
  time: 4                               # short render wait after nav

Tool: mcp__plugin_playwright_playwright__browser_snapshot

# If `default` row present → break out and proceed to Step 4.6.
# If still absent → repeat the block above (Attempt 2, Attempt 3).
```

After each attempt, inspect the new snapshot for the `default` row.

- **`default` row appears at any point during the loop** → log `ℹ️  Default data space row appeared after page refresh (attempt <N>/3, ~<N>min waited)` and **immediately proceed to Step 4.6** (click + save). Do NOT continue the loop.
- **`default` row still missing after 3 attempts (~3 min total)** → fall through to the graceful-skip block below. Do NOT refresh again. Do NOT redeploy. Do NOT probe additional APIs from this step.

**Loop bounds are hard limits:**
- Maximum 3 refresh attempts.
- 60 s wait before each refresh (first wait happens BEFORE the first refresh — gives the async UI 1 min to catch up before you retry).
- Total wall-clock budget: ~3 minutes. Never exceed this.
- No interactive input. The loop runs autonomously.

**Graceful-skip fallback (only reached when Step 4.5a refresh-loop exhausted 3 attempts without the row appearing):**

Log a single line:

```
ℹ️  Data Cloud Data Space Management option not available for enabling the Data Space — skipping this option and continuing
```

Then **immediately close the browser** (Step 4.7) and **continue to Step 5 (cleanup)**. Do NOT prompt the user. Do NOT print a frontdoor URL. Do NOT say "manual step required". Do NOT wait for confirmation.

**Step 4 recovery rules (binding):**

- At most 3 refresh attempts in Step 4.5a, one every 60 s. Bounded to ~3 min total. Never more.
- Step 4 does NOT diagnose Data Cloud provisioning and does NOT redeploy `CustomerDataPlatform`. Those responsibilities live in **Step 3.5** — never inside this step. This keeps Step 4 single-responsibility: toggle the UI, or graceful-skip.
- Step 4 STILL never STOPs the skill and STILL never prompts the user. The two terminal outcomes remain: enable, or graceful skip.

**Step 4.6 — Click the `default` checkbox, then Save**

```
Tool: mcp__plugin_playwright_playwright__browser_click
  target: <default checkbox ref>
  element: "default data space Enabled checkbox"

Tool: mcp__plugin_playwright_playwright__browser_click
  target: <Save button ref>
  element: "Save"
```

A browser-native alert dialog will appear with the text `"Your selections were saved."`. Handle it:

```
Tool: mcp__plugin_playwright_playwright__browser_handle_dialog
  accept: true
```

**Step 4.7 — Close browser (always runs)**

```
Tool: mcp__plugin_playwright_playwright__browser_close
```

The browser is closed regardless of which Step 4.5 branch was taken.

**Step 4 outcome reporting (record one of these for the Step 5 report):**

| Step 4 outcome | What gets logged | Skill behaviour |
|---|---|---|
| `default` row found on first snapshot, clicked, saved successfully | `✅ Default data space enabled in Data Cloud Architect` | Continue to Step 5 |
| `default` row appeared during Step 4.5a refresh loop (attempt 1/2/3), clicked, saved successfully | `ℹ️  Default data space row appeared after page refresh (attempt <N>/3, ~<N>min waited)` then `✅ Default data space enabled in Data Cloud Architect` | Continue to Step 5 |
| `default` row not in first snapshot AND not in any of the 3 refresh snapshots (~3 min elapsed) | `ℹ️  Data Cloud Data Space Management option not available for enabling the Data Space — skipping this option and continuing` | Continue to Step 5 |
| Permset SOQL returned 0 records | `ℹ️  GenieAdmin permset not present — skipped` | Continue to Step 5 (refresh not run) |
| Playwright errored (timeout, page failed to load, etc.) | `⚠️  Step 4 errored: <error>. Default data space not toggled — continuing.` | Continue to Step 5 |

**Step 4 NEVER stops the skill. Step 4 NEVER prompts the user.** Whatever happens, the browser closes and Step 5 (cleanup + report) runs.

---

### Step 5 — Cleanup + generate completion report

See "Cleanup" and "Success Report" below.

---

## Error Handling

The skill has exactly **one execution path with one graceful skip**:

| Failure point | Behaviour |
|---|---|
| Step 0 (auth check) fails | STOP — report "session not authenticated" |
| Step 1 (combined retrieve) fails | STOP — report verbatim retrieve error; user fixes root cause and re-runs |
| Step 3 (combined deploy) fails | STOP — report verbatim deploy error; rollback already happened (rollbackOnError=true); user fixes root cause and re-runs |
| Step 3.5 — `default` data space NOT `Active` after two 15-min polling passes + one re-deploy (30 min total) | **STOP the skill** — report the Step 3.5 STOP block; do NOT continue to Step 4. Step 4's toggle is meaningless without a provisioned space, and running it anyway masks the provisioning failure until later in the installer chain (per user directive 2026-08-13, `HCStrom11thAug2026Org1`) |
| Step 4 (Playwright) — `default` row not visible on UI even though Step 3.5 confirmed provisioning | LOG + CLOSE BROWSER + CONTINUE — never STOPs the skill (this is a UI render race, not a provisioning failure; provisioning is guaranteed by the Step 3.5 gate) |
| Step 4 (Playwright) — any other Playwright error | LOG + CLOSE BROWSER + CONTINUE — never STOPs the skill, never prompts the user |

The Step 0 / 1 / 3 / 3.5 failures are about API-layer operations the user must resolve before the install can continue. **Step 3.5 is a hard gate — it STOPs the skill on failure to prevent downstream corruption from an unprovisioned `default` space.** Step 4 remains best-effort (UI-only fallback for the permset toggle); it never STOPs because by the time it runs, Step 3.5 has already guaranteed the backend state.

---

## Important Rules

### Absolute Prohibitions

- ❌ NEVER generate `.js`, `.mjs`, `.ts` files
- ❌ NEVER use Playwright/browser automation for Steps 1–3
- ❌ NEVER use Metadata API, Tooling API, Connect REST, or any other API substitute for Step 4 — it MUST be Playwright
- ❌ NEVER skip the Tier 1 cleanup of `org_creds.json` and `frontdoor_url.txt` (credential safety — Tier 2 scratch cleanup is best-effort, see Cleanup section)
- ❌ NEVER call `sf` CLI with interactive flags that prompt for confirmation
- ❌ NEVER include `Account` (Person Account) in the deploy package if the retrieve XML showed `enableAccountTeams=true` (irreversible)
- ❌ NEVER make per-setting retrieves — Step 1 is one combined retrieve only
- ❌ NEVER make per-setting deploys — Step 3 is one combined deploy only
- ❌ NEVER retry a failed step in an unbounded loop — Step 3.5 may re-deploy `CustomerDataPlatform` AT MOST ONCE, Step 4 may refresh the DataspaceScopes page AT MOST 3 TIMES (60 s between each, ~3 min total); nothing else retries
- ❌ NEVER fall back to an alternate code path on failure — STOP (Steps 0/1/3) or LOG + CONTINUE (Steps 3.5 / 4)
- ❌ NEVER verify Data Cloud enablement with an extra Metadata API retrieve — Step 3.5 uses the cheap `/ssot/data-spaces` REST probe instead; full retrieves are not used for verification
- ❌ NEVER print "Manual Step Required" / "Please open this URL" / "Please click X" / "Once you've completed this step, let me know" / similar handoff messages anywhere in the skill output
- ❌ NEVER pause Step 4 to wait for the user to do anything — Playwright either does it or skips it

### Required Behaviors

- ✅ Step 1 ALWAYS runs ONE combined retrieve of all 5 Settings types (backing 6 logical features — `OauthOidc` carries 2) in a single call
- ✅ Step 2 ALWAYS parses XMLs locally (no API calls)
- ✅ Step 3 ALWAYS runs ONE combined deploy of only settings in `NEEDS_FLIP`, OR is skipped entirely if `NEEDS_FLIP` is empty
- ✅ Step 3.5 ALWAYS runs ONLY if `CustomerDataPlatform` was in `NEEDS_FLIP`; uses at most ONE re-deploy (`CustomerDataPlatform`-only) with bounded 90 s / 60 s probe windows; ALWAYS continues to Step 4 regardless of outcome
- ✅ Step 4 ALWAYS uses Playwright MCP, ALWAYS closes the browser before returning, ALWAYS continues to Step 5 regardless of outcome
- ✅ ALWAYS classify deploy results by `result.files[].state`:
  - All `state == "Unchanged"` → report `⏭ Already enabled — no-op deploy (no changes applied)`
  - At least one `state == "Changed"` or `"Created"` → report `✅ Deployed (newly enabled)`
- ✅ Person Account: omit from deploy if XML showed `enableAccountTeams=true`
- ✅ Single API version v64.0 everywhere (retrieve and deploy)
- ✅ ALWAYS execute steps in series (sequential) — never in parallel

---

## Success Report

```text
✅ Salesforce Feature Enablement Completed

Org: <org_alias>
Instance: {instance_url}
Duration: {total_time}

Step 1 — Combined retrieve (all 5 Settings types in one call):
✅ Completed in {N} sec — captured live state of all 6 features (5 Settings types; OauthOidc carries 2 features)

Step 2 — Per-feature decisions (skip-if-already-enabled):
  Data Cloud:                       <⏭ Already enabled | 🔧 Needs flipping>
  Einstein:                         <⏭ Already enabled | 🔧 Needs flipping>
  Agentforce:                       <⏭ Already enabled | 🔧 Needs flipping>
  Person Account:                   <⏭ Already enabled (omitted from deploy — irreversible safety) | 🔧 Needs flipping>
  Allow OAuth User-Agent Flows:     <⏭ Already enabled | 🔧 Needs flipping>   (OauthOidc.blockOAuthUsrAgtFlow → false)
  Require PKCE Extension:           <⏭ Already enabled | 🔧 Needs flipping>   (OauthOidc.isPkceRequired → true)

Step 3 — Combined deploy:
  ✅ {N} setting(s) deployed in one zip
  Each setting state per Salesforce:
    <setting1>: <Changed | Unchanged>
    ...
  [or: ⏭ Skipped — every setting was already enabled]

Step 3.5 — Data Cloud provisioning verification:
  <one of:>
    ⏭ Skipped — CustomerDataPlatform was not in NEEDS_FLIP (already enabled)
    ✅ Data Cloud provisioned — 'default' data space present (no re-deploy needed)
    ℹ️  Data Cloud provisioning lagged — re-deployed CustomerDataPlatform → ✅ provisioned
    ⚠️  Data Cloud provisioning did not surface 'default' within the verification window — continued to Step 4
    ⚠️  Step 3.5 re-deploy errored: <error> — continued to Step 4

Step 4 — Data Cloud Architect → default data space (Playwright):
  <one of:>
    ✅ Default data space enabled — "Your selections were saved." dialog confirmed
    ℹ️  Default data space row appeared after page refresh (attempt <N>/3, ~<N>min waited) → ✅ Default data space enabled
    ℹ️  Data Cloud Data Space Management not available after 3 refreshes (~3 min) — skipped (no impact on remaining install steps)
    ℹ️  GenieAdmin permset not present — skipped
    ⚠️  Step 4 errored: <error> — default data space not toggled, continuing

Total Metadata API calls: <1 if no flips needed | 2 if flips needed>

✅ Org is now ready for Data Kit deployment

Next Steps:
1. Run: /datakit-api-deploy <org_alias>
2. Run: /datakit-api-deploy <org_alias>
3. Monitor Data Kit installation (25-35 minutes)
```

---

## Failure Report (Step 0, 1, or 3 stopped the skill)

```text
🛑 Salesforce Feature Enablement — STOPPED at Step <0|1|3>

Org: <org_alias>

✅ Steps that completed before the failure: <list>

🛑 Failed step: Step <N> — <step name>

Error reported by Salesforce:
   <verbatim error message>

What this means:
   <one-sentence explanation tied to the specific failure, e.g.
    • Step 0: cached SF CLI session is missing or expired
    • Step 1: the org rejected the Settings retrieve — typically a missing PSL
    • Step 3: the deploy was rolled back — typically a license/feature provisioning issue>

Re-run the skill once the underlying issue is resolved:
   /feature-enablement <org_alias>
```

Note: Step 4 never produces a failure report — its outcomes (success / graceful skip / error) are all reported as part of the **Success Report**, not the Failure Report. Step 4 is best-effort; the skill always completes if Steps 0/1/3 completed.

---

## Dependencies

### Required for Metadata API steps (1–3)

- Salesforce CLI installed and authenticated (`sf` command available)
- Target org has the relevant Permission Set Licenses Active:
  - `GenieDataPlatformStarterPsl` (Data Cloud)
  - `EinsteinGPTPromptTemplatesPsl` and related Einstein PSLs
  - `GlobalPromotionsManagementPsl`

### Required for Playwright step (Step 4 only)

- MCP Playwright tools available in deferred tools list
- System Administrator profile on target org

---

## Integration with Data Kit Deployment

This skill must run BEFORE Data Kit deployment:

```
Workflow Order:
1. /feature-enablement <org_alias>         ← Run FIRST
   └─ One retrieve + one deploy via Metadata API + Playwright (best-effort) for permission set

2. /datakit-api-deploy <org_alias>    ← Run SECOND
   └─ Deploys 612 metadata components

3. /datakit-api-deploy <org_alias>         ← Run THIRD
   └─ Triggers Data Kit installation (25-35 min)
```

If Step 4 gracefully skipped (default data space couldn't be enabled), the Data Kit install continues normally. The default data space can be enabled later by re-running `/feature-enablement <org_alias> tasks=permission-set` once Data Cloud has fully provisioned.

---

## ✅ COMPLETION CHECKLIST

Verify all items before marking complete:

| # | Task | Verification |
|---|------|--------------|
| 0 | Org session verified | `sf org display` returned `result.accessToken` |
| 1 | Combined retrieve | All 5 `*.settings-meta.xml` files present in `/tmp/feat-check/retrieved/settings/` (`CustomerDataPlatform`, `EinsteinGpt`, `AgentPlatform`, `Account`, `OauthOidc`) |
| 2 | Local parse classified each setting | `NEEDS_FLIP` array contains only settings where the XML did NOT show the desired-state values; Person Account omitted if `enableAccountTeams=true`; `OauthOidc` added if EITHER `blockOAuthUsrAgtFlow≠false` OR `isPkceRequired≠true` |
| 3 | Combined deploy | If `NEEDS_FLIP` empty → deploy skipped. If non-empty → `sf project deploy start` returned `Succeeded` for all members. |
| 3.5 | Data Cloud provisioning verified | Either: `CustomerDataPlatform` was NOT in `NEEDS_FLIP` so the step was skipped; OR `/ssot/data-spaces` confirmed `default` exists (with or without one re-deploy); OR a "did not surface within window" warning was logged and skill continued to Step 4. |
| 4 | Data Cloud Architect default data space | Either: "Your selections were saved." dialog appeared on first snapshot OR after one of the 3 refresh attempts (~3 min max), OR a graceful-skip log was emitted (row still absent after all 3 refreshes, permset not found, or Playwright errored). Browser was closed. Skill continued to Step 5. |
| 5 | Cleanup | **Tier 1 (mandatory):** `org_creds.json` and `frontdoor_url.txt` are deleted. **Tier 2 (best-effort, 2-second budget):** `/tmp/feat-*`, `/tmp/permset-query`, `.playwright-mcp/` removed when possible; leftover empty dirs are non-sensitive and acceptable on Windows. |

---

## Cleanup temp artifacts (two tiers — security-critical vs best-effort)

Cleanup has **two tiers** with different guarantees. This split exists because the SF CLI metadata-cache scanner keeps file handles open on the retrieve directory for 30-60s after retrieve completes. On Linux/macOS that's invisible (POSIX permits unlink while a file is open). On Windows it raises `WinError 32` and a retry loop can stall the skill for 30+ seconds for **no security benefit** — the held-open files are non-sensitive XML setting flags. Don't burn wall-clock on leftovers that don't matter.

### Tier 1 — Credential files (MANDATORY, synchronous, no retries, no timeout)

These files contain a Salesforce access token or session URL. **Delete them every time, on both success and failure paths. Never skip. Never retry-loop.** Per-file `os.unlink` is reliable on Windows for these files because nothing else holds handles to them.

```bash
# Tier 1 — credential exposure: delete immediately, fail loud if delete itself fails
rm -f frontdoor_url.txt
rm -f org_creds.json
```

Cross-platform alternative when running from Python/bash on Windows:

```bash
python3 -c "
import pathlib
for f in ('frontdoor_url.txt', 'org_creds.json'):
    p = pathlib.Path(f)
    if p.exists():
        p.unlink()
"
```

If a Tier 1 deletion raises an error, **surface it** — that's a real problem (e.g. file is locked by another process the user must know about). Do not swallow.

### Tier 2 — Scratch directories (best-effort, 2-second total budget)

These hold only `.settings-meta.xml` files (live-state snapshots of feature flags), deploy result JSON, Step 3.5's provisioning-probe responses + one-shot re-deploy package, and a SOQL query file. **None of them contain credentials or tokens.** They're hygiene, not security. If Windows file handles hold the directory open longer than 2 seconds, **log one line and move on** — the next skill run clobbers them anyway.

```bash
python3 << 'PYEOF'
import shutil, pathlib, time
BUDGET_SEC = 2.0
targets = [
    pathlib.Path(r'/tmp/feat-check'),
    pathlib.Path(r'/tmp/feat-deploy'),
    pathlib.Path(r'/tmp/permset-query'),
    pathlib.Path(r'/tmp/feat-deploy-result.json'),
    # Step 3.5 — provisioning probe + one-shot re-deploy scratch
    pathlib.Path(r'/tmp/feat-dc-spaces.json'),
    pathlib.Path(r'/tmp/feat-dc-spaces2.json'),
    pathlib.Path(r'/tmp/feat-dc-reverify'),
    pathlib.Path(r'/tmp/feat-dc-reverify-result.json'),
    pathlib.Path('.playwright-mcp'),
]
deadline = time.monotonic() + BUDGET_SEC
remaining = []
for t in targets:
    if not t.exists():
        continue
    try:
        if t.is_dir():
            shutil.rmtree(t, ignore_errors=False)
        else:
            t.unlink()
    except OSError:
        # Windows file-handle race — try ONCE more before deadline, then give up
        if time.monotonic() < deadline:
            try:
                if t.is_dir():
                    shutil.rmtree(t, ignore_errors=True)
                else:
                    t.unlink(missing_ok=True)
            except OSError:
                pass
        if t.exists():
            remaining.append(str(t))
if remaining:
    print(f"ℹ️  Tier 2 cleanup: {len(remaining)} scratch path(s) still held by OS (non-sensitive, will be overwritten on next run): {remaining}")
else:
    print("✓ All scratch artifacts removed")
PYEOF
```

Windows path note: if `/tmp` is Git-Bash-translated, the script works as-is. From cmd.exe / PowerShell, substitute `r'C:\tmp\feat-check'` etc. The behavior contract is the same: **2-second budget, log-and-continue on leftover.**

### Cleanup-on-failure policy

- ✅ **Tier 1 ALWAYS runs**, on success AND on every failure path (Step 0 / 1 / 3 STOPs, Step 3.5 warnings, Step 4 errors). Credential files must never persist.
- ❌ **Tier 2 does NOT run on Step 3 deploy failure** — the user needs `/tmp/feat-deploy/` (package.xml + `*.settings`) to debug the deploy.
- ❌ **Tier 2 does NOT run when Step 3.5 logged a "did not surface within window" warning OR its re-deploy errored** — the user needs `/tmp/feat-dc-reverify-result.json` and the probe responses to investigate why provisioning stalled. (Skill still continued to Step 4, but the evidence is worth keeping.)
- ❌ **Tier 2 does NOT run on Step 4 Playwright error** — `.playwright-mcp/` snapshots + console logs are the failure evidence the user needs. Browser is still closed regardless.
- ✅ **Tier 1 still runs in all ❌ cases above** — credential safety is unconditional.

### Verification (informational only — Tier 2 leftovers are acceptable)

```bash
# Tier 1 verification — MUST be empty
ls frontdoor_url.txt org_creds.json 2>&1 | grep -v "cannot access" || echo "  (Tier 1 clean)"

# Tier 2 verification — leftovers are NON-FATAL informational
ls -d /tmp/feat-check /tmp/feat-deploy /tmp/permset-query /tmp/feat-dc-reverify .playwright-mcp 2>&1 | grep -v "cannot access" || echo "  (Tier 2 clean)"
ls /tmp/feat-deploy-result.json /tmp/feat-dc-spaces.json /tmp/feat-dc-spaces2.json /tmp/feat-dc-reverify-result.json 2>&1 | grep -v "cannot access"
```

If Tier 1 verification finds either file present after the cleanup ran, that's a **bug** — surface it. If Tier 2 verification finds leftovers, that's **expected on Windows when SF CLI scanner is still holding handles** — do not surface, do not retry, the next run handles it.

### What NOT to delete

- Anything under `.claude/` — your skill / agent definitions
- Anything in the repo root that existed at run start (`settings.json`, `sfdx-project.json`, root `package.xml`, etc.)

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"feature-enablement"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.feature-enablement` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
