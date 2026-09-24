---
name: datakit-install
description: "End-to-end Data360 Healthcare Data Kit installation in one skill — merges the previous /datakit-metadata-deploy + /datakit-d360-deploy. Phase 0 gates Phase 1 behind a Data Cloud provisioning check via the salesforce-data360 MCP TenantLifecycle family (`d360_tenantlifecycle_status` for state, `d360_tenantlifecycle_enable`/`_retry` for recovery, `d360_tenantlifecycle_details` for Home Org Instance + Tenant Endpoint proof); hard-stops Phase 1 unless `isProvisioned=true` with Home Org Instance + Tenant Endpoint retrieved. Phase 1 ships the 612 metadata components from ps-datacloud via `sf project deploy start` with KeyQualifier cleanup, managed-DLO filtering, Tooling API status gate, and single-retry-on-real-failure. Phase 2 triggers the Data Kit install/activate via the salesforce-data360 MCP server (`d360_datakit_deploy` async → `d360_datakit_deploy_status` polling), with 5-attempt retry (1 initial + 4 retries), tiered backoff (30s for attempts 2-3, 60s for attempts 4-5), fail-fast on deterministic errors (permission/license/feature), and foreground chunked polling (5-min interval, 9 polls per attempt = 45 min per attempt). Phase 2 only runs AFTER Phase 1 confirms Status=Succeeded via Tooling API. Chains to /agentforce-data-library ONLY when both phases exit Complete. Use when user wants to deploy healthcare data kit metadata, install/activate the Data Kit, deploy Data360MedTechSolutionKit end-to-end, or any phrasing that covers both the metadata-shipping and the install/activate phase."
---

# datakit-install

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"datakit-install"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: datakit-install already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Install the Data360 Healthcare Data Kit into a Salesforce org end-to-end. This skill merges what was previously two separate skills (`/datakit-metadata-deploy` and `/datakit-d360-deploy`) into a single skill with two sequential phases, gated on each other:

- **Phase 1 — Metadata Deploy** ships the 612 metadata components from `ps-datacloud/` via Salesforce CLI. Uses `sf project deploy start`, handles KeyQualifier field cleanup, Data Kit XML Id rebind (Step 1.4a — rewrites source-org `MktDataConnection` Id + `importDirectory` User Id with the target org's actual Ids, preventing the `-1499079666` "Access denied — importDirectory does not belong to the current user" gack in Phase 2), managed DLO filtering, and single-shot retry on real failures. Verifies via Tooling API (the org is the source of truth).
- **Phase 2 — Data Kit Install/Activate** triggers the Data Kit installation via the `salesforce-data360` MCP server (`d360_datakit_deploy` async → `d360_datakit_deploy_status` polling). Handles up to 5 install attempts with tiered backoff and fail-fast on deterministic errors.

**Hard rule between the phases:** Phase 2 does NOT run unless Phase 1's Tooling API check returns `Status = Succeeded` with `NumberComponentErrors = 0`. Phase 1 failure = skill stops, no Phase 2, no downstream chain.

**Hard rule at skill exit:** the next skill (`/agentforce-data-library`) is auto-invoked ONLY when Phase 2 exits with `jobStatus = "Complete"`. Any non-Complete exit halts the installer chain.

**Merged from:**
- `/datakit-metadata-deploy` — functionality preserved verbatim as Phase 1 (Steps 1–10 renamed to 1.x)
- `/datakit-d360-deploy` — functionality preserved verbatim as Phase 2 (Steps 1–8 renamed to 2.x)

No behavior changes vs. the two source skills. Polling cadence, retry counts, backoff timings, fail-fast lists, error tables, exit-code contract, and cleanup rules are all identical to what shipped before.

---

## Arguments

- `org_alias` (required for Phase 1): Target Salesforce org alias or username. Passed to `sf project deploy start -o <org_alias>`.
- `org_alias` (informational for Phase 2): The `salesforce-data360` MCP server is bound to whichever org `/mcp-setup` was run against — this arg is informational for Phase 2 reports only. It does NOT change which org the MCP call hits.

---

## Preconditions

Before running:

- Salesforce CLI installed and target org authenticated (`sf org display --target-org <org_alias>` returns `Connected`).
- User is in the repository root containing `sfdx-project.json`.
- `ps-datacloud/` folder exists in the repository.
- Data Cloud is enabled + licensed on the target org.
- User has "Manage Data Cloud" permission set assigned.
- **`/mcp-setup` has been run against the target org** so `salesforce-data360` MCP is authenticated — without it, every `d360_*` call in Phase 2 returns `invalid_grant`.

**IMPORTANT:** For uninterrupted execution, pre-approve the shell commands this skill uses in `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "bash:sf *",
      "bash:grep *",
      "bash:find *",
      "bash:sed *",
      "bash:cat *",
      "bash:echo *",
      "bash:pwd",
      "bash:test *"
    ]
  }
}
```

Without pre-approval, users get prompted 10+ times during Phase 1 (each `sf`, `grep`, `sed`, `find`, `cat`, `test` call prompts separately). Pre-approval keeps the deploy under 2 minutes wall-clock instead of stretching to 10+.

---

## Workflow

### PHASE 0 — Data Cloud Provisioning Preflight (MANDATORY, runs BEFORE Phase 1)

Purpose: guarantee Data Cloud is fully provisioned in the target org before Phase 1 fires the `ps-datacloud` metadata deploy. Without this gate, the deploy validates against a half-provisioned schema and fails in ~10 seconds with hundreds of cascade errors ("no CustomObject named `ssot__X__dlm` found") that look like a metadata bug but are actually a timing bug — the org hadn't finished spinning up the SSOT namespace tables when the deploy ran.

**🚨 EXECUTION CHANNEL — data360 MCP ONLY.** Phase 0 uses the `salesforce-data360` MCP TenantLifecycle family end-to-end:

| Action | data360 MCP tool | Purpose |
|---|---|---|
| Check provisioning state | `d360_tenantlifecycle_status` | Returns `isLicensed` / `isProvisioned` / `provisionStatus` — the same source of truth the Setup → Data Cloud Setup → Home Org Details panel reads from |
| Enable provisioning | `d360_tenantlifecycle_enable` | Kicks off provisioning if licensed but not yet provisioned |
| Retry failed provisioning | `d360_tenantlifecycle_retry` | Re-enqueues the tenant creation job after a failed attempt |
| Fetch Home Org details | `d360_tenantlifecycle_details` | Returns `homeOrgId`, `homeOrgInstance`, `tenantEndpoint`, `tenantId`, `coreId` — proof provisioning fully completed |

Three states this gate distinguishes:
1. **Provisioned** → fetch Home Org details, log them, advance to Phase 1 (~1 second on a ready org)
2. **Licensed but not yet provisioned** → call `d360_tenantlifecycle_enable`, then poll status until ready
3. **Provisioning failed** → call `d360_tenantlifecycle_retry`, then poll status until ready

Hard rule: Phase 1 does NOT start until `d360_tenantlifecycle_status` returns `isProvisioned=true` AND `d360_tenantlifecycle_details` successfully returns `homeOrgInstance` + `tenantEndpoint`. Phase 0 hard-failure = skill stops, no Phase 1, no Phase 2.

Preconditions: `/mcp-setup` must have been run against the target org so `salesforce-data360` MCP is authenticated — every `d360_*` call below fails with `invalid_grant` otherwise. If Step 0.1 hits `invalid_grant`, stop the skill and instruct the user to re-run `/mcp-setup` against `<org_alias>`.

---

#### Step 0.1 — Check current provisioning status

```
mcp__salesforce-data360__execute
  toolName: d360_tenantlifecycle_status
  paramsJson: {}
```

Response shape:
```json
{
  "result": {
    "isActive": true,
    "isLicensed": true,
    "isProvisioned": true,
    "provisionStatus": "SUCCEEDED",
    "provisionStatusDetail": "SUCCEEDED"
  }
}
```

Decision matrix on the response:

| `isLicensed` | `isProvisioned` | `provisionStatus` | Meaning | Next step |
|---|---|---|---|---|
| `true` | `true` | `SUCCEEDED` | ✅ Fully provisioned | Jump to Step 0.4 (fetch details) |
| `true` | `false` | `IN_PROGRESS` / `WAITING` / `PENDING` / `null` | Provisioning already running or not yet started | Step 0.2 (enable if idle) → Step 0.3 (poll) |
| `true` | `false` | `FAILED` / `FAILEDWAITING` / any error code | Prior provisioning attempt failed | Step 0.2 (retry) → Step 0.3 (poll) |
| `false` | — | — | ❌ Not licensed — polling won't help | Hard stop: re-run `/feature-enablement`, or contact Salesforce for a Data Cloud license |

Hard stop if `isLicensed=false`:

```text
✗ Data Cloud not licensed on this org (isLicensed=false).
  This is NOT a wait-state — provisioning cannot succeed without a license.
  Root cause: /feature-enablement did not enable Data Cloud, or the org is not licensed for it.
  Fix: re-run /feature-enablement, or contact Salesforce for a Data Cloud license.
```

---

#### Step 0.2 — Kick off (or retry) provisioning if not yet provisioned

Runs only when Step 0.1 returned `isLicensed=true` AND `isProvisioned=false`.

Pick the correct MCP tool based on `provisionStatus` from Step 0.1:

- If `provisionStatus` is any failed state (`FAILED`, `FAILEDWAITING`, or any non-in-progress error code):

  ```
  mcp__salesforce-data360__execute
    toolName: d360_tenantlifecycle_retry
    paramsJson: { "cdpTenantLifecycleProvisioningRetryInput": { "installCIMPackage": true } }
  ```

- Otherwise (never enabled, or currently `IN_PROGRESS` / `WAITING` / `PENDING` / `null`) — call enable; if the tenant is already provisioning, the platform is idempotent and returns success without re-enqueuing:

  ```
  mcp__salesforce-data360__execute
    toolName: d360_tenantlifecycle_enable
    paramsJson: { "cdpTenantLifecycleProvisioningEnableInput": { "installCIMPackage": true } }
  ```

Both calls are asynchronous — the response confirms the request was accepted; actual completion is observed by polling Step 0.3.

If the enable/retry response itself errors (non-2xx, or `success=false`), surface the message and hard-stop. Do not enter Step 0.3 against a rejected trigger.

---

#### Step 0.3 — Poll `d360_tenantlifecycle_status` until provisioned

Configuration:
- **Poll interval:** 60 seconds
- **Poll ceiling per attempt:** 30 minutes (30 polls)
- **Max retry attempts:** 3 (initial + 2 retries via `d360_tenantlifecycle_retry`)
- **Absolute wall-clock ceiling:** 90 minutes (3 × 30-min windows)

Pseudocode (each iteration is one MCP call + one `Bash({command: "sleep 60"})` — FOREGROUND, never `run_in_background: true`, same rule as Phase 2's polling loop):

```
attempt = 1
while attempt <= 3:
    for poll in range(1, 31):
        r = mcp__salesforce-data360__execute(
              toolName="d360_tenantlifecycle_status",
              paramsJson={})
        s = r.result
        log(f"Poll {poll}/30 (attempt {attempt}/3): isProvisioned={s.isProvisioned}, "
            f"provisionStatus={s.provisionStatus}")

        if s.isProvisioned == True and s.provisionStatus == "SUCCEEDED":
            return "PROVISIONED"

        if s.provisionStatus in ("FAILED", "FAILEDWAITING") or is_error_status(s.provisionStatus):
            log(f"⚠ Provisioning failed on attempt {attempt} (status={s.provisionStatus}).")
            break  # exit inner poll, go to retry

        # else: IN_PROGRESS / WAITING / PENDING / null — keep polling
        Bash(command="sleep 60", timeout=90000)

    # Poll ceiling hit or provisioning failed — retry via MCP
    if attempt < 3:
        log(f"🔄 Retrying provisioning via d360_tenantlifecycle_retry (attempt {attempt+1}/3)...")
        mcp__salesforce-data360__execute(
          toolName="d360_tenantlifecycle_retry",
          paramsJson={"cdpTenantLifecycleProvisioningRetryInput": {"installCIMPackage": True}})
        Bash(command="sleep 60", timeout=90000)  # give the retry time to propagate

    attempt += 1

# Exhausted 3 attempts × 30 min = 90 min wall-clock
log("✗ Data Cloud failed to fully provision after 3 attempts × 30 min each.")
exit(1)  # HARD STOP — no Phase 1, no Phase 2
```

Exit criteria:
- `PROVISIONED` (Step 0.1 or Step 0.3 confirmed `isProvisioned=true` + `provisionStatus=SUCCEEDED`) → advance to Step 0.4
- Non-zero exit after 3 attempts → hard stop, skill fails

Wall-clock budget:
- Ready org: ~1 second (Step 0.1 answers positive immediately)
- Fresh org, provisioning succeeds first attempt: 5–20 min
- Second attempt succeeds after retry: 20–45 min
- All 3 attempts fail (rare): 90 min → hard error (Support ticket)

Why the retry loop matters: some fresh orgs get stuck at `provisionStatus=waiting` or `FAILEDWAITING` after the initial enable. `d360_tenantlifecycle_retry` re-enqueues the tenant creation job on Salesforce's side — exactly the recovery Support performs manually when a provisioning ticket lands with them; automating it here saves the ticket.

Why 3 attempts and not infinite: 3 × 30 min is a hard 90-min ceiling. Beyond that, no amount of retry will fix the underlying block (unsupported edition, region unavailable, license not granted at the backend). Silent infinite retry turns a 90-min recoverable issue into an 8-hour mystery — a clear hard-fail with a Support pointer is more useful.

---

#### Step 0.4 — Fetch Home Org details (final proof of successful provisioning)

Once Step 0.1 or Step 0.3 confirms `isProvisioned=true` + `provisionStatus=SUCCEEDED`, fetch the tenant metadata:

```
mcp__salesforce-data360__execute
  toolName: d360_tenantlifecycle_details
  paramsJson: {}
```

Response shape:
```json
{
  "result": {
    "connectionsCount": 1,
    "coreId": "core/prod/00Dbm00000to4xMEAQ",
    "dataSpacesCount": 1,
    "homeOrgId": "00Dbm00000to4xMEAQ",
    "homeOrgInstance": "CDP3-AWS-PROD21-USEAST2",
    "tenantEndpoint": "gm4dcyr-g8yg0zbwg02dkzrzgy.c360a.salesforce.com",
    "tenantId": "a360/prod21/d781a2e83498483e9e7bcfc9d1941b8f"
  }
}
```

**Strict gate — both fields required, poll every 60 seconds until populated:**

BOTH `homeOrgInstance` AND `tenantEndpoint` MUST be present and non-empty in the `d360_tenantlifecycle_details` response. Either being missing or empty means Data Cloud is not yet provisioned, regardless of what `d360_tenantlifecycle_status` reported.

Pseudocode (foreground poll — `Bash({command: "sleep 60"})`, never `run_in_background: true`):

```
for poll in range(1, 31):  # 30 polls × 60s = 30 min ceiling
    r = mcp__salesforce-data360__execute(
          toolName="d360_tenantlifecycle_details",
          paramsJson={})
    details = r.result
    home_org_instance = details.get("homeOrgInstance", "")
    tenant_endpoint  = details.get("tenantEndpoint", "")

    if home_org_instance and tenant_endpoint:
        log(f"✅ Data Cloud provisioned: homeOrgInstance={home_org_instance}, "
            f"tenantEndpoint={tenant_endpoint}")
        break  # advance to Phase 1

    log(f"Poll {poll}/30 — homeOrgInstance/tenantEndpoint not yet populated, "
        f"sleeping 60s")
    Bash(command="sleep 60", timeout=90000)
else:
    log("✗ Data Cloud provisioning did not populate homeOrgInstance + "
        "tenantEndpoint within 30 minutes. HARD STOP — no Phase 1, no Phase 2.")
    exit(1)
```

Trust chain (necessary AND sufficient for Phase 1):
1. `d360_tenantlifecycle_status` returned `isProvisioned=true` + `provisionStatus=SUCCEEDED` (Step 0.1 or 0.3)
2. `d360_tenantlifecycle_details` returned non-empty `homeOrgInstance` AND non-empty `tenantEndpoint` (this step)

Both must be true. If either is not satisfied, Phase 1 must NOT run.

Log to the user on success:

```text
═══ Phase 0 complete — Data Cloud provisioned successfully ═══

  Home Org ID:       <homeOrgId>
  Home Org Instance: <homeOrgInstance>
  Tenant Endpoint:   <tenantEndpoint>
  Tenant ID:         <tenantId>
  Core ID:           <coreId>
  Data Spaces:       <dataSpacesCount>
  Connections:       <connectionsCount>

  ✅ isLicensed=true, isProvisioned=true, provisionStatus=SUCCEEDED
  ✅ Home Org Instance + Tenant Endpoint retrieved — provisioning fully complete

  Advancing to Phase 1 (metadata deploy)...
```

Only after this confirmation may Phase 1 (ps-datacloud metadata deploy) begin. Phase 2 (Data Kit install) may only begin after Phase 1's Tooling API check confirms `Status = Succeeded` with `NumberComponentErrors = 0`.

---

### PHASE 1 — Data Kit Metadata Deploy (ps-datacloud, 612 components)

Phase 1 ships the metadata definitions — what data streams, DLOs, mappings, calculated insights, kit object templates, etc. exist. It uses `sf project deploy start` and verifies via Tooling API. Phase 2 runs ONLY after this phase's Tooling API check confirms success.

---

#### Step 1.1 — Validate repository structure (Quick Check Only)

**CRITICAL: Minimal validation only — assume we're already in the correct directory from previous steps.**

Quick validation:

```bash
pwd && test -f "sfdx-project.json" && echo "✓ sfdx-project.json found" && test -d "ps-datacloud" && echo "✓ ps-datacloud folder found"
```

**Why minimal validation?**
- If `/base-metadata-deploy` already ran successfully, we're in the correct directory.
- No need for full error handling and directory navigation.
- Saves time and reduces approval prompts.

If validation fails:
- stop execution
- report which file/folder is missing

---

#### Step 1.2 — Skip org authentication verification

**CRITICAL: Skip org authentication check entirely.**

**Reason:** If `/base-metadata-deploy` skill already ran successfully, the org is authenticated and connected. No need to verify again — this wastes time and adds unnecessary approval prompts.

**Skip these commands:**
- ❌ `sf org list` (not needed)
- ❌ `sf org login web` (not needed)

**Proceed directly to Step 1.3.**

---

#### Step 1.3 — Search for KeyQualifier fields

Search all metadata in ps-datacloud:

```bash
grep -rl "KeyQualifier" ps-datacloud/
```

KeyQualifier fields contain:

```xml
<usageTag>KeyQualifier</usageTag>
```

These are system-generated fields that cannot reliably deploy across orgs.

---

#### Step 1.4 — Remove KeyQualifier fields if found

If grep returns matching files:

```bash
find ps-datacloud/ -type f -name "*.xml" -exec sed -i '/<KeyQualifier>/d' {} \;
```

This removes lines containing `<KeyQualifier>` from all XML files.

Report removed fields to user.

Salesforce regenerates KeyQualifier fields automatically in target org.

---

#### Step 1.4a — Rebind org-specific Ids in Data Kit XMLs (MANDATORY, runs BEFORE Step 1.5's deploy)

**Why this step exists:** the Data Kit XMLs in `ps-datacloud/` embed **source-org identifiers** left behind by whoever originally exported the kit — a `MktDataConnection` Id inside the `UploadedFiles` object template, and a User Id prefix inside the `pacemaker_iot_data` data-stream template's `importDirectory` parameter. When Phase 2's `d360_datakit_deploy` job runs `UploadedFilesAdapter.validateImportDirectoryOwnership`, Salesforce parses the leading User Id from `importDirectory` and checks it against the running user's Id. When the source-org values ship untouched into a fresh install, the check fails with:

```
Access denied — importDirectory does not belong to the current user
StackTraceId: -1499079666
```

The gack surfaces during Phase 2, but the fix belongs in Phase 1 — the corrected values must be deployed *into* the org before Phase 2 reads them. Observed 2026-08-25 on `HCOrg3` (support ID `4539303-80175`). This step rewrites both XMLs in place BEFORE Step 1.5's `sf project deploy start`, using Ids discovered at runtime from the target org — never hardcoded.

**Two files rewritten, one substitution each:**

| File | Field | Discovered from |
|---|---|---|
| `ps-datacloud/main/default/dataKitObjectTemplates/UploadedFiles.dataKitObjectTemplate-meta.xml` | Both `id` and `url` occurrences of the `MktDataConnection` Id inside the `entityPayload` JSON | `SELECT Id FROM MktDataConnection WHERE DeveloperName = 'UploadedFiles'` |
| `ps-datacloud/main/default/dataStreamTemplates/pacemaker_iot_data_*.dataStreamTemplate-meta.xml` | The leading User Id prefix inside `<importDirectory>` `<value>` (portion before the first `/`; timestamp portion after the slash is preserved verbatim) | `SELECT Id FROM User WHERE Username = <install-running-username>` |

```bash
ORG="<org_alias>"

# ── (1) Discover HCOrg-side Ids ──────────────────────────────────────────────
# Uses the same $SF resolver convention as /external-client-app-deploy — bare
# `sf` on POSIX / working-Windows shells, `/c/PROGRA~1/sf/bin/sf.cmd` on shells
# that choke on the space in "C:\Program Files\...".
if command -v sf >/dev/null 2>&1 && sf --version >/dev/null 2>&1; then SF="sf"; else SF="/c/PROGRA~1/sf/bin/sf.cmd"; fi

RUNNING_USERNAME=$("$SF" org display --target-org "$ORG" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['username'])")

USER_ID=$("$SF" data query --target-org "$ORG" \
    --query "SELECT Id FROM User WHERE Username = '${RUNNING_USERNAME}' LIMIT 1" \
    --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
recs = (d.get('result') or {}).get('records') or []
uid = recs[0]['Id'] if recs else ''
print(uid if uid.startswith('005') else '')
")

CONN_ID=$("$SF" data query --target-org "$ORG" \
    --query "SELECT Id FROM MktDataConnection WHERE DeveloperName = 'UploadedFiles' LIMIT 1" \
    --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
recs = (d.get('result') or {}).get('records') or []
print(recs[0]['Id'] if recs else '')
")

if [ -z "$USER_ID" ]; then
    echo "❌ Step 1.4a: could not resolve a User.Id (prefix '005') for '${RUNNING_USERNAME}' in $ORG."
    echo "   The importDirectory ownership check will fail every retry until this is fixed."
    exit 1
fi

if [ -z "$CONN_ID" ]; then
    echo "❌ Step 1.4a: no MktDataConnection with DeveloperName='UploadedFiles' exists in $ORG."
    echo "   This connection is provisioned by Data Cloud during Phase 0."
    echo "   Re-run Phase 0 (or /feature-enablement) before retrying — do NOT proceed."
    exit 1
fi

echo "✅ Step 1.4a: discovered USER_ID=$USER_ID  CONN_ID=$CONN_ID"

# ── (2) Rewrite the two XMLs deterministically (Python — regex-based, so a
#     future kit re-export that ships a different source-org Id keeps working) ─
python3 - "$USER_ID" "$CONN_ID" <<'PY'
import re, sys, pathlib, glob
user_id, conn_id = sys.argv[1], sys.argv[2]

# --- File A: UploadedFiles.dataKitObjectTemplate-meta.xml ---------------------
# Replace ANY 18-char MktDataConnection Id (prefix '9cg') inside the entityPayload
# JSON blob with the target-org value. Both `id` and `url` occurrences are rewritten
# by the same regex — the prefix is unique to MktDataConnection.
p = pathlib.Path("ps-datacloud/main/default/dataKitObjectTemplates/UploadedFiles.dataKitObjectTemplate-meta.xml")
if not p.exists():
    raise SystemExit(f"❌ {p} not found — expected ps-datacloud bundle intact.")
xml = p.read_text(encoding='utf-8')
new_xml, n = re.subn(r"9cg[A-Za-z0-9]{15}", conn_id, xml)
if n == 0:
    raise SystemExit(f"❌ No MktDataConnection Id substitutions made in {p} — expected ≥1.")
if n != 2:
    print(f"⚠️  Expected 2 substitutions in {p} (url + id), got {n} — check the file structure.", file=sys.stderr)
p.write_text(new_xml, encoding='utf-8')
print(f"✅ {p}: rewrote {n} MktDataConnection Id occurrence(s) -> {conn_id}")

# --- File B: pacemaker_iot_data_*.dataStreamTemplate-meta.xml ----------------
# Rewrite only the leading User Id (prefix '005') inside the importDirectory <value>
# element. The portion after the first '/' (the per-user subfolder timestamp) is
# preserved verbatim — Salesforce owns that portion and would reject an arbitrary rewrite.
ds_files = glob.glob("ps-datacloud/main/default/dataStreamTemplates/pacemaker_iot_data_*.dataStreamTemplate-meta.xml")
if not ds_files:
    raise SystemExit("❌ No pacemaker_iot_data_*.dataStreamTemplate-meta.xml files found under ps-datacloud/.")
for ds_path in ds_files:
    p = pathlib.Path(ds_path)
    xml = p.read_text(encoding='utf-8')
    # Only inside importDirectory's <value>...</value>; captures the block, then
    # substitutes only the leading '005…' User Id prefix within.
    pattern = re.compile(
        r"(<fullName>importDirectory</fullName>\s*<paramName>importDirectory</paramName>\s*<value>)005[A-Za-z0-9]{15}(/[^<]*)</value>",
        re.MULTILINE,
    )
    if not pattern.search(xml):
        # File exists but doesn't have the expected importDirectory block — surface, don't silently pass.
        raise SystemExit(f"❌ importDirectory <value> block not matched in {p}; kit structure may have changed.")
    new_xml, n = pattern.subn(rf"\g<1>{user_id}\g<2></value>", xml)
    if n != 1:
        raise SystemExit(f"❌ Expected exactly 1 importDirectory substitution in {p}, got {n}.")
    p.write_text(new_xml, encoding='utf-8')
    print(f"✅ {p}: rewrote importDirectory User Id prefix -> {user_id}")
PY

# ── (3) Verify — no residual source-org sentinels of the two prefixes ────────
# CONN_ID check: grep for any 9cg... Id in dataKitObjectTemplates that is NOT the target.
# USER_ID check: use Python to read the importDirectory <value> directly from disk,
#   since </paramName> and <value> are on separate lines — a single-line grep can never
#   match across them and would always return empty (false "✅"), masking a bad rewrite.
RESIDUAL_CONN=$(grep -rEho "9cg[A-Za-z0-9]{15}" ps-datacloud/main/default/dataKitObjectTemplates/ 2>/dev/null | sort -u | grep -v "^${CONN_ID}\$" || true)

RESIDUAL_USER=$(python3 - "$USER_ID" <<'PY'
import re, sys, glob
expected_user_id = sys.argv[1]
pattern = re.compile(
    r"<paramName>importDirectory</paramName>\s*<value>(005[A-Za-z0-9]{15})/",
    re.MULTILINE,
)
residual = []
for path in glob.glob("ps-datacloud/main/default/dataStreamTemplates/pacemaker_iot_data_*.dataStreamTemplate-meta.xml"):
    xml = open(path, encoding="utf-8").read()
    for m in pattern.finditer(xml):
        found_id = m.group(1)
        if found_id != expected_user_id:
            residual.append(found_id)
if residual:
    print(" ".join(sorted(set(residual))))
PY
)

if [ -n "$RESIDUAL_CONN" ]; then
    echo "❌ Step 1.4a verify: residual non-target MktDataConnection Id(s) still present in dataKitObjectTemplates/: $RESIDUAL_CONN"
    exit 1
fi
if [ -n "$RESIDUAL_USER" ]; then
    echo "❌ Step 1.4a verify: residual non-target User Id prefix(es) still present in importDirectory: $RESIDUAL_USER"
    exit 1
fi

echo "✅ Step 1.4a complete: ps-datacloud XMLs now carry HCOrg-side Ids only. Advancing to Step 1.5."
```

**Idempotency:** the rewrites are regex-driven and self-normalizing — running the step twice in a row produces the same output. Safe on resumed runs.

**Local repo hygiene note:** same tradeoff as `/external-client-app-deploy` Step 1a — the rewrite modifies tracked files on disk. Either recommit after each org install (accept the diff as part of the deploy), or restore the source-org Ids after deploy. This skill takes the same "leave the diff visible" convention as the ECA skill for simplicity.

**Why this belongs before Step 1.5 and not somewhere else:**
- Phase 0 has already confirmed Data Cloud is provisioned, so `MktDataConnection` with `DeveloperName='UploadedFiles'` exists and is queryable.
- Step 1.5's `sf project deploy start` reads the XMLs from disk — the corrected values must be on disk before that call.
- The alternative (rewriting inside Phase 2, after Phase 1 landed the source-org Ids in the org) would require an extra MDT deploy to correct in-place, which is slower and racier.

---

#### Step 1.5 — Deploy metadata to target org

**CRITICAL: Deploy ONLY ONCE. Capture output on first execution.**

Deploy with 30-minute timeout and capture full output:

```bash
sf project deploy start -d ps-datacloud -o <org_alias> --wait 30 --json > /tmp/datakit_deploy_result.json 2>&1
```

**NEVER run deployment command multiple times to check status or capture output.**

If you need deployment details after execution:
```bash
cat /tmp/datakit_deploy_result.json
```

Flags:
- `-d ps-datacloud`: Deploy from ps-datacloud directory
- `-o <org_alias>`: Target org
- `--wait 30`: Wait up to 30 minutes
- `--json`: Return structured JSON output
- `> /tmp/datakit_deploy_result.json`: Save output to file for later parsing

Typical deployment time: 5–10 minutes.

**Important:**
- ✅ Run deployment command ONCE
- ✅ Capture output to file
- ✅ Parse file for deployment details
- ❌ DO NOT re-run deployment to get status
- ❌ DO NOT run multiple times to capture different outputs

---

#### Step 1.6 — Verify deployment status against the org FIRST (MANDATORY GATE)

**🚨 STRICT RULE — DO THIS FIRST, BEFORE ANYTHING ELSE 🚨**

**You MUST query the org's Tooling API to confirm the actual deployment status BEFORE:**
- ❌ Reading or trusting `/tmp/datakit_deploy_result.json`
- ❌ Reporting "deployment failed" to the user
- ❌ Entering Step 1.7 (failure handling)
- ❌ Running ANY destructive command (`rm -rf`, `find ... -delete`, folder removal)
- ❌ Asking the user to approve a fix
- ❌ Retrying the deployment

**The org is the ONLY source of truth. The local result file can be stale, partial, or from a prior run.**

**Mandatory verification command — run this immediately after Step 1.5:**

```bash
ACCESS_TOKEN=$(sf org display --target-org <org_alias> --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")
INSTANCE_URL=$(sf org display --target-org <org_alias> --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")

curl -s -G -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "q=SELECT Id, Status, NumberComponentsDeployed, NumberComponentsTotal, NumberComponentErrors, CreatedDate, CompletedDate FROM DeployRequest ORDER BY CreatedDate DESC LIMIT 1" \
  "$INSTANCE_URL/services/data/v62.0/tooling/query"
```

**Decision logic — use ONLY the org-returned values:**

| Org `Status` | `NumberComponentErrors` | `NumberComponentsDeployed` | Action |
|---|---|---|---|
| `Succeeded` | `0` | `612` | ✅ TRUE SUCCESS — skip Step 1.7 entirely, proceed to Step 1.8 |
| `Succeeded` | `0` | `< 612` | ⚠️ Investigate missing components (warning, not failure) |
| `Failed` | `> 0` | any | ❌ TRUE FAILURE — only NOW may you enter Step 1.7 |
| `InProgress` / `Pending` | — | — | ⏳ Wait and re-poll. Do NOT trigger Step 1.7 |

**Hard rules — violating these is a defect:**
- ❌ NEVER declare deployment failed without first running the Tooling API query above
- ❌ NEVER run `rm -rf`, `find ... -delete`, or any destructive command unless the org returns `Status = Failed` with `NumberComponentErrors > 0`
- ❌ NEVER enter Step 1.7 based on `/tmp/datakit_deploy_result.json` content alone
- ❌ NEVER prompt the user to approve a fix until org-status is verified as failed
- ✅ If the org says `Succeeded` but the local file says failed, TRUST THE ORG, ignore the file, and proceed to Step 1.8

**If — and only if — the Tooling API confirms a real failure, then proceed to Step 1.7. Otherwise skip Step 1.7 entirely.**

---

#### Step 1.7 — Handle deployment failures

**PRECONDITION (NON-NEGOTIABLE):** Step 1.6 (the Tooling API gate) must have returned `Status = Failed` with `NumberComponentErrors > 0` against the ORG. If you have not run that check, or if the org returned `Succeeded`, you MUST NOT enter this step. The local result file alone is NEVER sufficient grounds to enter Step 1.7.

**Step 1.7.1 — Read per-component error details from the local result file:**

The org-side `DeployRequest` query (Step 1.6) does not return per-component error messages — only counts. To classify the failure, read `componentFailures[]` from the local result file:

```bash
cat /tmp/datakit_deploy_result.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
failures = d.get('result', {}).get('details', {}).get('componentFailures', [])
for f in failures[:20]:
    print(f\"{f.get('componentType','?')}: {f.get('fullName','?')} → {f.get('problem','?')}\")
print(f'... ({len(failures)} total failures)')"
```

**Step 1.7.2 — Classify the error and apply the matching fix:**

| Error Pattern | Cause | Fix |
|---|---|---|
| `ssot__*__dlm` entity not accessible | Managed DLO restriction | Remove DLO folders, retry |
| KeyQualifier field error | System-generated field | Remove KeyQualifier fields, retry |
| InvalidProjectWorkspaceError | Not in SFDX project | Navigate to repo root |
| Authentication failure | Org disconnected | Re-authenticate org |
| Missing Data Cloud | Feature not enabled | Enable Data Cloud first |

**Fix for managed DLO errors:**

```bash
# Remove problematic DLO folders automatically
find ps-datacloud/ -type d -name "*__dlm" -exec rm -rf {} \;

# Retry deployment ONCE with output capture
sf project deploy start -d ps-datacloud -o <org_alias> --wait 30 --json > /tmp/datakit_deploy_retry.json 2>&1
```

**Retry Rules:**
- Only retry ONCE after fixing the error
- Capture retry output to separate file: `/tmp/datakit_deploy_retry.json`
- Parse the retry file for results
- Do NOT retry multiple times — if second attempt fails, report error and stop

After the retry, re-run Step 1.6 (Tooling API gate) against the ORG. If the retry's Tooling API row shows `Status = Succeeded` with 0 errors, proceed to Step 1.8. If not, STOP the skill — do NOT enter Phase 2.

---

#### Step 1.8 — Verify deployment success (component counts)

On success, deployment should show:

```json
{
  "status": "Succeeded",
  "result": {
    "id": "0Afaj00000ZacKLCAZ",
    "status": "Succeeded",
    "numberComponentsDeployed": 612,
    "numberComponentsTotal": 612,
    "numberComponentErrors": 0
  }
}
```

Component count must be 612.

If count differs:
- investigate missing components
- check for deployment warnings
- report discrepancy to user

---

#### Step 1.9 — Report Phase 1 status

On success:

```text
✅ Phase 1 — Metadata Deployment Successful!

Org: <org_alias>
Components Deployed: 612
Duration: <duration>
Deployment ID: <deployment_id>

Deployed Components:
  - DataPackageKitDefinition (1)
  - DataPackageKitObjects (99)
  - dataCalcInsightTemplates (5)
  - dataKitObjectDependencies (38)
  - dataKitObjectTemplates (41)
  - dataSourceBundleDefinitions (2)
  - dataSourceObjects (22)
  - dataSrcDataModelFieldMaps (319)
  - dataStreamTemplates (16)
  - DLO objects (56)
  - supporting metadata (13)

➡️  Proceeding to Phase 2 — Data Kit Install/Activate via data360 MCP...
```

On failure (after Step 1.7 retry also failed the Tooling API gate):

```text
❌ Phase 1 — Metadata Deployment Failed

Org: <org_alias>
Error: <verbatim error from componentFailures[]>
Deployment ID: <deployment_id>

Failed Components:
  - <componentType>: <fullName> → <problem>
  ...

🛑 Phase 2 (Data Kit Install/Activate) is BLOCKED — will NOT run.
🛑 Downstream installer chain is BLOCKED (agentforce-data-library, notebook-ai, ...).
🛑 Fix the root cause in the org, then re-run /datakit-install <org_alias>.
```

---

#### Step 1.10 — MANDATORY GATE before Phase 2

**Phase 2 runs ONLY if Step 1.6 confirmed `Status = Succeeded` with `NumberComponentErrors = 0` against the org (either on the first deploy or after the Step 1.7 single retry).**

**Trust deployment API result — no additional SOQL verification needed:**
- Tooling API `DeployRequest` already confirmed status = "Succeeded"
- Component count validated: 612 deployed, 0 errors
- Deployment ID confirms successful completion
- SOQL queries for Data Kit metadata may not be immediately available
- Tooling API is the authoritative source of truth

**Do NOT:**
- ❌ Ask user to verify in Salesforce UI
- ❌ Run SOQL queries for verification
- ❌ Wait for user confirmation to enter Phase 2
- ❌ Stop execution if Tooling API said Succeeded

**Do:**
- ✅ Trust Tooling API result (status + componentErrors)
- ✅ Automatically proceed to Phase 2 (no user prompt)
- ✅ Maintain installation momentum

---

### PHASE 2 — Data Kit Install/Activate (data360 MCP)

Phase 2 activates the Data Kit inside Data Cloud. This is where Data Cloud wires up data streams, calculated insights, identity resolution rules, DMO field mappings, and related list enrichments — an async server-side job that typically takes **30–45 minutes**.

**🚨 EXECUTION CHANNEL — data360 MCP ONLY:**

All triggers and status checks are driven by the `salesforce-data360` MCP server (`mcp__salesforce-data360__execute` tool). **NO `curl`, NO `sf apex run`, NO `sf org display`, NO Connect REST via curl, NO SOQL, NO Tooling API.** Verified working end-to-end on 2026-07-17 against jobId `08Paj00000tPyr4` which reached `Complete`.

| Action | data360 MCP tool | Parameter shape |
|---|---|---|
| Trigger install | `d360_datakit_deploy` | `{"dataKitDevName": "Data360MedTechSolutionKit", "asyncMode": true, "cdpDataKitDeployInput": {"components": []}}` |
| Poll status | `d360_datakit_deploy_status` | `{"jobId": "<jobId from previous response>"}` |

**Response shapes** (verified 2026-07-17):

- `d360_datakit_deploy` → `{"result": {"jobId": "08Paj00000tPyr4"}}` — capture `result.jobId` for polling.
- `d360_datakit_deploy_status` → `{"result": {"errors": [...], "jobId": "...", "jobResults": [...], "jobStatus": "Running|Complete|Error|Failed|Cancelled|Canceled|Aborted"}}` — gate on `result.jobStatus`.

---

#### Step 2.1 — Confirm data360 MCP is authenticated for the target org (optional but recommended)

Any cheap `d360_*` call works as a probe. `d360_datakit_list` is fastest:

```
mcp__salesforce-data360__execute
  toolName: d360_datakit_list
  paramsJson: {}
```

If this returns `invalid_grant` / `request not supported on this domain`, the data360 MCP is authenticated for a different org (or not at all). Stop the skill and instruct the user to re-run `/mcp-setup` against `<org_alias>` before continuing.

---

#### Step 2.2 — Skip metadata deployment re-verification

**CRITICAL: Skip metadata deployment re-verification.**

**Reason:** Phase 1 just completed and its Tooling API gate (Step 1.6) confirmed 612 components landed with 0 errors. No need to re-verify — this wastes time and adds unnecessary MCP calls.

**Assume:**
- ✅ Phase 1 completed successfully
- ✅ 612 components deployed to target org
- ✅ Data Kit metadata is ready

**Proceed directly to Step 2.3.**

---

#### Step 2.3 — Trigger the Data Kit install

```
mcp__salesforce-data360__execute
  toolName: d360_datakit_deploy
  paramsJson: {
    "dataKitDevName": "Data360MedTechSolutionKit",
    "asyncMode": true,
    "cdpDataKitDeployInput": { "components": [] }
  }
```

**IMPORTANT — trigger payload:**
- ✅ `dataKitDevName` must be `"Data360MedTechSolutionKit"` (developer name from ps-datacloud metadata, not the display name).
- ✅ `asyncMode` must be `true` — synchronous mode times out after 60s while the Data Kit is still installing.
- ✅ `cdpDataKitDeployInput.components` must be `[]` — empty array means "deploy all components in the kit". Passing specific components partially installs the kit.

**Success response:**
```json
{ "result": { "jobId": "08Paj00000XXXXXXX" } }
```

Capture `result.jobId` — every subsequent poll and every retry-status message references this jobId.

Report:
```text
🚀 Data Kit install triggered
   dataKitDevName: Data360MedTechSolutionKit
   asyncMode:      true
   jobId:          <jobId>
   Estimated time: 30–45 minutes
```

**If the trigger response has no `jobId` OR contains an `errors` field:**
- If the error is deterministic (fail-fast — see Step 2.5.5 table): STOP. Do NOT enter the polling loop. Surface the error. The installer chain must not proceed.
- Otherwise: retry the same `d360_datakit_deploy` call once after 30s. If the second trigger also fails, STOP.

---

#### Step 2.4 — Report initial trigger

On deployment started (initial response):

```text
🚀 Data Kit Install Started (via data360 MCP)

Org (alias):     <org_alias>
Data Kit:        Data360MedTechSolutionKit
✅ Job ID:       <jobId>
✅ Status:       Running (async)
⏳ Estimated Time: 30–45 minutes
⏳ Waiting for install to complete...

Polling d360_datakit_deploy_status every 5 minutes (max 9 polls = 45 min)…
```

On error (immediate trigger rejection):

```text
❌ Data Kit Install Trigger Failed

Org (alias):    <org_alias>
Error:          <verbatim error from data360 MCP response>

Possible Causes:
1. Metadata deployment not completed (need 612 components) — Phase 1 should have caught this
2. Data Cloud not enabled in org
3. Missing Data Cloud license
4. User lacks "Manage Data Cloud" permission
5. data360 MCP not authenticated for this org

Suggested Fix:
✅ Verify metadata deployment: /datakit-install <org_alias> (re-runs Phase 1's Tooling API gate)
✅ Check Data Cloud enabled: Setup → Data Cloud → Settings
✅ Verify license: Setup → Company Information → Licenses
✅ Check permissions: Setup → Users → Permission Sets → Data Cloud Admin
✅ Re-run /mcp-setup if the error is `invalid_grant`
```

---

#### Step 2.5 — Auto-monitor install every 5 minutes until Complete (45 min total wait)

**🚨 CRITICAL EXECUTION MODE — READ BEFORE WRITING ANY POLLING CODE:**

**This skill runs inside a sub-agent context (the `data360-healthcare-installer` orchestrator invokes it as a sub-agent). Sub-agents DO NOT receive `<task-notification>` callbacks for `run_in_background: true` tasks — those notifications go to the *parent* main loop, not to the sub-agent that spawned them. If a sub-agent kicks off a 30-45 min background task and returns final text, the sub-agent is DONE. The background task may complete successfully later, but no one is left in the sub-agent to act on it, and the orchestrator records "Check 1/9 = Running. Waiting for notification." as the sub-agent's final answer — even though the install actually finished.**

**Observed failure:** jobId `08PHn00000lZMgb` reached `Complete` at minute 30, but the sub-agent had already exited at minute 0 after the initial `run_in_background: true` Bash call returned. The orchestrator never proceeded to the next installer step.

**MANDATORY:** Use FOREGROUND CHUNKED POLLING. One poll per iteration. The sub-agent stays alive across the full 45 min because it keeps issuing tool calls (Bash sleep, then MCP status, then Bash sleep, ...).

**Expected install time:** 30–45 minutes
**Polling interval:** Every 5 minutes (300 s)
**Maximum polls:** 9 (45 minutes total — at minutes 5, 10, 15, 20, 25, 30, 35, 40, 45)
**Execution mode:** **FOREGROUND**, one Bash `sleep 300` + one `d360_datakit_deploy_status` call per iteration.

**Per-poll pseudocode:**

```
CHECK = 1
while CHECK <= 9:
    sleep(300)                                          # 5 min between polls (foreground Bash "sleep 300")
    r = d360_datakit_deploy_status({"jobId": JOB_ID})
    status = r.result.jobStatus
    errors = r.result.errors or []
    log(f"Check {CHECK}/9 (at minute {CHECK*5}): jobStatus={status}")

    if status == "Complete":
        # ✅ Terminal success — proceed to Step 2.7 (final report)
        return "Complete"

    if status in ("Failed", "Error", "Cancelled", "Canceled", "Aborted"):
        # ❌ Terminal failure — hand to Step 2.5.5 (retry wrapper)
        # Capture the errors[] array verbatim for the retry decision.
        return ("TerminalFailed", errors)

    # Otherwise "Running" / "InProgress" / "Queued" / "Pending" — keep polling
    CHECK += 1

# Loop exhausted at check 9 without terminal state → Timeout
return "Timeout"
```

**Sub-agent loop pseudocode (this is what the orchestrator's invocation of the skill must do):**

```
CHECK = 1
while CHECK <= 9:
    Bash(command="sleep 300", timeout=420000)        # foreground, one call
    r = mcp__salesforce-data360__execute(
          toolName="d360_datakit_deploy_status",
          paramsJson={"jobId": JOB_ID})
    status = r.result.jobStatus
    match status:
        "Complete"                                     → break, success → Step 2.7
        "Failed" | "Error" | "Cancelled" | "Canceled" | "Aborted"
                                                       → hand to Step 2.5.5
        _                                              → CHECK += 1, continue
```

**Execution model (BLOCKING FOREGROUND — do NOT background):**

- Each `sleep 300` is a single foreground `Bash({command: "sleep 300"})` call. 5 min per call is well under Bash's 10-min foreground cap.
- Between sleeps, issue exactly one `mcp__salesforce-data360__execute` call for `d360_datakit_deploy_status`.
- The sub-agent stays alive across all 9 checks because it keeps issuing tool calls (Bash sleep, MCP status, Bash sleep, MCP status, …).
- **DO NOT** use `run_in_background: true`. Sub-agents do not receive `<task-notification>` callbacks — a backgrounded polling loop silently abandons the install.
- **DO NOT** pack the whole 45-min loop into one foreground call. Bash's 10-min foreground cap kills it on the first `sleep 300`, and any retry restarts at check 1.

**Match ALL 5 terminal-failed values.** The Salesforce Data Kit install API returns any of `Failed`, `Error`, `Cancelled`, `Canceled`, `Aborted` depending on the root cause. Handling only `Failed` will silently poll for 45 min against a dead job — the wildcard "still in progress, keep polling" branch would waste up to 45 minutes per attempt and never trigger the retry.

**Timeout (9 polls exhausted, status still non-terminal):**

Report the jobId and last-observed status to the user. Do NOT auto-retry on Timeout — surface it:

```text
⏱️  Data Kit install did not reach a terminal state in 45 minutes.
    jobId:      <jobId>
    Last status: <status>

Ask the user whether to keep polling (extend by another 45 min) or stop.
Timeout is NOT auto-retried — only TerminalFailed triggers Step 2.5.5.
```

**After jobStatus = "Complete", AUTOMATICALLY invoke next skill (NEVER ask user):**

```
/agentforce-data-library <org_alias>
```

**What to Report (Keep Minimal):**
- ✅ "Polling started (foreground, 5 min interval, max 45 min — 9 polls)"
- ✅ "Check 1/9 (at 5 min): jobStatus = Running"
- ✅ "Check 2/9 (at 10 min): jobStatus = Running"
- ✅ "Check 6/9 (at 30 min): jobStatus = Complete"
- ✅ "✅ Data Kit install complete!"
- ✅ Then immediately: Invoke `/agentforce-data-library` automatically (no user prompt)

**Sub-agent must not return final text between polls.** Issue the next tool call directly. If the sub-agent emits final text after Check 1 with status Running, the orchestrator records that as the skill's outcome and the chain breaks — exactly the failure pattern this rewrite eliminates.

**What NOT to Report:**
- ❌ Detailed install timeline
- ❌ UI monitoring instructions
- ❌ Verification steps requiring user action
- ❌ "Would you like to..." questions
- ❌ "Should I proceed?" prompts

**IMPORTANT:**
- Poll using `d360_datakit_deploy_status` with `{"jobId": "..."}`
- Check every **5 minutes** (300 seconds)
- Maximum **9 polls (45 minutes total)** — covers the 30–45 min expected window
- Auto-proceed when Complete — NEVER ask user
- Do NOT wait for user input

---

#### Step 2.5.5 — Auto-retry on terminal failure (max 5 total attempts)

**CRITICAL: When Step 2.5 polling returns any terminal-failed `jobStatus` (`Failed`, `Error`, `Cancelled`, `Canceled`, `Aborted`), do NOT exit immediately.** The retry wrapper re-invokes `d360_datakit_deploy` (same params), captures the new `jobId`, and resumes polling on the same 5-minute / 45-minute cadence.

**Retry policy:**
- **5 total install attempts**: 1 initial (Step 2.3) + up to **4 retries** when an attempt ends in any terminal-failed state.
- **Each attempt polls for up to 45 minutes**, checking every 5 minutes (9 polls per attempt).
- Wait **30 seconds** between failure detection and the next retry for attempts 2–3 (gives the platform time to release locks the failed run held).
- Wait **60 seconds** between failure detection and retry for attempts 4–5 (escalates the platform-recovery window for stickier contention).
- **Fail-fast list** — if the captured `errors` array matches a deterministic platform error (license missing, feature off, permission denied), abort retries immediately. No point burning 4 more attempts on the same root cause.
- After **all 5 attempts fail**, STOP and report. The installer chain DOES NOT proceed.
- **Worst-case wall-clock**: 5 × 45 min poll + 2 × 30s gap + 2 × 60s gap ≈ **228 minutes** (~3 hr 48 min).

**Fail-fast error patterns (abort retries immediately):**

| Error code / message contains | Why we abort |
|---|---|
| `INSUFFICIENT_ACCESS` | User lacks Data Cloud admin permission — retries will all fail identically |
| `LICENSE_LIMIT_EXCEEDED` | Org doesn't have the Data Cloud license — admin must add license |
| `FEATURE_NOT_ENABLED` | Data Cloud feature isn't enabled — Step 1 (feature-enablement) didn't apply |
| `INVALID_TYPE` | Data Kit API version mismatch — retries won't fix |
| `permission` (case-insensitive) | Generic perm error — surface to user |
| `not licensed` | License issue, not transient |

Pseudocode:

```
attempts_used = 1                  # after Step 2.3's initial trigger, we've used 1 attempt
attempts_max = 5
attempt_log = [(1, JOB_ID, "TriggerAccepted")]
final = "Pending"

while attempts_used < attempts_max:
    outcome = poll_step_2_5(JOB_ID)  # returns "Complete", ("TerminalFailed", errors), or "Timeout"

    if outcome == "Complete":
        final = "Complete"
        attempt_log.append((attempts_used, JOB_ID, "Complete"))
        break

    if outcome == "Timeout":
        final = "Timeout"
        attempt_log.append((attempts_used, JOB_ID, "Timeout"))
        break

    # outcome is ("TerminalFailed", errors)
    _, errors = outcome
    err_text = "; ".join(str(e) for e in errors[:3]).lower()
    attempt_log.append((attempts_used, JOB_ID, f"TerminalFailed: {err_text[:200]}"))

    if is_fail_fast(err_text):
        final = "FailFastDeterministic"
        log(f"🛑 Fail-fast: {err_text}. Retries would fail identically. Aborting.")
        break

    # 🚨 DATASTREAM FAILURE — exit retry wrapper IMMEDIATELY after the FIRST failed attempt.
    # Do NOT let the 4 remaining retries execute against a stale DS — they will fail
    # identically. Query DataKitDeploymentLog and classify failed components via LOCAL
    # REPO GREP (ComponentType field in the SOQL response is UNRELIABLE — Step 2.5.6.2).
    failed_components = query_datakit_deployment_log()             # Step 2.5.6.1 SOQL
    data_stream_failures = classify_via_local_grep(                 # Step 2.5.6.2
        failed_components,
        repo_root="ps-datacloud/main/default"
    )                                                               # returns only DataStream rows
    if data_stream_failures:
        final = "DataStreamCleanupNeeded"
        log(f"🛑 Data Stream component failure detected on FIRST attempt "
            f"(classified via local repo grep — ComponentType from SOQL is unreliable). "
            f"Retries will NOT fix this. Exiting retry wrapper immediately and handing off "
            f"to Step 2.5.6 (AUTOMATED cleanup via Connect API).")
        attempt_log.append((attempts_used, JOB_ID,
            f"DataStreamCleanupNeeded: {[c['ComponentName'] for c in data_stream_failures]}"))
        break  # exit retry wrapper — do NOT use the 4 remaining retries

    if attempts_used >= attempts_max:
        final = "FailedAllAttempts"
        break

    # Tiered backoff
    gap = 30 if attempts_used < 3 else 60
    log(f"🔁 Attempt {attempts_used}/{attempts_max} failed. Waiting {gap}s before retry...")
    sleep(gap)

    # Re-trigger via data360 MCP
    r = mcp__salesforce-data360__execute(
          toolName="d360_datakit_deploy",
          paramsJson={
            "dataKitDevName": "Data360MedTechSolutionKit",
            "asyncMode": True,
            "cdpDataKitDeployInput": {"components": []}
          })

    new_job_id = r.result.jobId
    if not new_job_id:
        final = "ReDeployRejected"
        attempt_log.append((attempts_used, None, f"Re-deploy trigger rejected: {r}"))
        break

    JOB_ID = new_job_id
    attempts_used += 1
    attempt_log.append((attempts_used, JOB_ID, "TriggerAccepted"))

    # Loop continues: poll_step_2_5 with the new JOB_ID
```

**Reporting per attempt:**
- ✅ First-try success → `Attempt 1/5 (jobId <id>): Complete`
- 🔁 Recovered → `Attempt 1/5 Failed → Attempt 2/5 Complete`
- ❌ All 5 failed → per-attempt summary with jobIds + last error each
- 🛑 Fail-fast → `Attempt 1/5 Failed (deterministic): <error>. Aborting.`
- ⏱️ Timeout on final → `Attempt N/5: Timeout after 45 min. jobId <id>.`

**Exit-code contract (for orchestrator's per-skill execution gate):**

| Final status | Exit code | Orchestrator action |
|---|---|---|
| Complete | 0 | Auto-chain to `/agentforce-data-library` |
| FailedAllAttempts | 1 | STOP. Do NOT chain. Surface failure report. |
| ReDeployRejected | 1 | STOP. Do NOT chain. Surface failure report. |
| FailFastDeterministic | 1 | STOP. Do NOT chain. Surface deterministic-error report. |
| Timeout | 2 | STOP. Do NOT chain. Surface jobId + last status. |
| DataStreamCleanupNeeded | — (transient) | Automated cleanup via Step 2.5.6 (Connect API mapping/DMO/stream DELETE + poll + re-run). NOT a terminal exit code — resolves to `Complete`, `DataStreamMissing`, `AutomatedCleanupBlocked`, `DataStreamNotDeleted`, `UserAborted`, or `DataStreamCleanupFailedTwice`. |
| DataStreamMissing (Step 2.5.6.3 saw 0 rows) | 1 | STOP. Different failure mode; escalate with Support ID. |
| AutomatedCleanupBlocked (Steps 2.5.6.5-8 hit an unexpected error AND user handoff via 2.5.6.10 got `stop` or timed out) | 1 | STOP. Surface the blocked step + error verbatim. |
| DataStreamNotDeleted (Step 2.5.6.10 user replied `done` 3× but SOQL still showed the stream) | 1 | STOP. Investigate downstream dependencies. |
| UserAborted (Step 2.5.6.10 got `stop`) | 1 | STOP. Do NOT chain. |
| DataStreamCleanupFailedTwice | 1 | STOP. Do NOT loop Step 2.5.6 again — surface both attempts' logs. |
| Unknown / defensive fallback | 1 | STOP. Surface to user. |

**MANDATORY HARD-STOP RULE:**

If `final` is anything other than `Complete`, the installer chain MUST stop. Do NOT auto-invoke `/agentforce-data-library`. Do NOT auto-invoke any later skill. The user must fix the root cause in the org and re-run the skill (or re-invoke the installer agent, which will resume from this step).

**Failure escalation (only after all 5 attempts fail OR fail-fast triggers):**
1. Surface the `errors` array AND the per-attempt log to the user verbatim — they usually point at the offending Data Kit component (missing DLO, wrong API version, license missing) or a deterministic platform issue (license/perm/feature).
2. Common root causes that retries will NOT fix on their own (these often show up via fail-fast — the script aborts retries early):
   - Data Cloud feature license missing or expired (`LICENSE_LIMIT_EXCEEDED`).
   - Required permission set not assigned to the running user (`INSUFFICIENT_ACCESS`, `permission`).
   - Data Cloud feature not enabled on the org (`FEATURE_NOT_ENABLED`).
   - Metadata deployment didn't actually finish — verify 612 components landed (Phase 1 should have caught this via Tooling API).
   - Stale FLS on a Data Kit component (e.g. `Account.<field>__pc`) — verify running user has `PulseSyncBasePS` assigned.
   - Managed package conflict with an existing Data Kit.
3. Common root causes that DO benefit from retries (the 5-attempt budget is sized for these):
   - Platform contention / locked DLOs from the recent metadata deploy.
   - Async metadata still settling (1–3 min after Phase 1 finished).
   - Org in a maintenance / contention window.
4. Do NOT auto-proceed to `/agentforce-data-library` if `final != Complete`. The user must explicitly re-run the agent or this skill.

**Why retries help here:**
- Salesforce Data Kit installation can transiently fail on platform contention (locked DLOs, async metadata still settling) within the first 1–2 minutes after metadata deploy. A second `d360_datakit_deploy` call after a 30s pause typically succeeds because the platform has released the locks.
- Empirically observed: real-world Data Kit installs can take 2–3 attempts on a healthy day. The 5-attempt budget gives safety margin.
- Retries do NOT re-deploy metadata — they only re-trigger the *installation* of the already-deployed Data Kit components. Phase 1 remains valid; this section only covers the install/activate phase.

---

#### Step 2.5.6 — User-driven stale Data Stream cleanup (fires when Step 2.5.5 detects a DataStream component failure)

**When this step fires:** After Phase 2's very first terminal-failed attempt (the initial `d360_datakit_deploy` in Step 2.3, NOT after multiple retries), Step 2.5.5 queries `DataKitDeploymentLog`, and if any failed row is classified as a Data Stream component (via local repo grep on `ps-datacloud/main/default/dataStreamTemplates/`), retry is skipped and this step is invoked. Re-triggering `d360_datakit_deploy` against a stale/partial Data Stream in the org will fail identically — the DK install can only create fresh, not overwrite.

**🚨 EXPLICIT RULE — DO NOT RETRY ON DATASTREAM FAILURE.** Unlike other terminal failures which run the 5-attempt retry wrapper, a Data Stream failure exits the retry wrapper immediately after the FIRST failed attempt and hands off to this step. The 4 remaining retries are NOT used. The recovery path is: cleanup → re-deploy metadata → re-install DK (one round only).

**🧑 USER-DRIVEN CLEANUP — DO NOT AUTO-DELETE.** Field-validated 2026-08-10: automated Connect API cleanup produced ambiguous downstream states — after we deleted a Data Stream via the API, the underlying DLO lingered and blocked the next DK install (`"The Contact_Home data lake object already exists in this org and is linked to a data stream..."` — jobId `08Paj00000xrXVR` on org `HCTrailsignup10thAug`). The reliable recovery path is: skill identifies the failed component, tells the user exactly what to delete and where in Setup, user does the deletion in the UI (which handles all cascading cleanly), user confirms, skill verifies via SOQL + Connect API, then automatically re-runs Phase 1 + Phase 2.

**Recovery sequence:** (1) Identify the failed component via `DataKitDeploymentLog` → (2) Derive the human-readable Data Stream name → (3) Surface a detailed cleanup message with exact Setup navigation → (4) Wait for user's `done` reply → (5) Verify via SOQL AND Connect API that BOTH the Data Stream AND its underlying DLO are gone → (6) Auto-re-run Phase 1 → (7) Auto-re-run Phase 2.

---

##### Step 2.5.6.1 — Query `DataKitDeploymentLog` for the failed component

Query the platform's deployment log via `salesforce-sobject-all` MCP:

```
mcp__salesforce-sobject-all__soqlQuery
  paramsJson: {
    "q": "SELECT ComponentName, DeploymentStatus, DeploymentError, CreatedDate FROM DataKitDeploymentLog WHERE DeploymentStatus = 'Failed' AND ComponentName != null ORDER BY CreatedDate DESC LIMIT 20"
  }
```

Log every failed row to the user:

```text
❌ Component failed:
   ComponentName:   <ComponentName>
   DeploymentError: <DeploymentError>
   CreatedDate:     <CreatedDate>
```

Also extract the Salesforce Support ID from `DeploymentError` (regex: `Support ID:\s*(\d+-\d+)`) — surface it in the final report if the automated cleanup itself fails and the user needs to escalate.

##### Step 2.5.6.2 — Classify the failed component via local repo grep

🚨 **Do NOT trust `DataKitDeploymentLog.ComponentType`** — field-validated unreliable for the generic "Internal Error" signature.

Strip the trailing digits+underscore from `ComponentName` first:

```python
import re
raw_name  = component_name                              # e.g. "Contact_Home19"
stripped  = re.sub(r'\d+$', '', raw_name).rstrip('_')   # → "Contact_Home"
```

Grep the four DK type folders using the anchored `<stripped>_<digits>` filename pattern:

```bash
for TYPE in dataStreamTemplates dataLakeObjects dataSourceObjects dataKitObjectTemplates; do
    if ls ps-datacloud/main/default/${TYPE}/${STRIPPED}_*-meta.xml >/dev/null 2>&1; then
        MATCHED_TYPE="$TYPE"; break
    fi
done
```

Routing:
- `dataStreamTemplates/` matches → **DataStream** → continue to Step 2.5.6.3 (automated cleanup)
- Any other folder → NOT this flow — fall through to `FailedAllAttempts` in Step 2.8
- No match → escalate; the local repo may be stale (guard: check `ps-datacloud/main/default/dataStreamTemplates/` has ≥5 XML files; if not, fall through)

##### Step 2.5.6.3 — Confirm the Data Stream exists in the org (guard)

Via Connect API:

```
GET /services/data/v67.0/ssot/data-streams/<stripped>
```

- HTTP 200 → Data Stream exists in the org → proceed to Step 2.5.6.4
- HTTP 404 → Data Stream not present → skip cleanup, fall through to `FailedAllAttempts` (this isn't a stale-DS case)

Fetch the DLO Id from the response for later reference; also derive the DLO developer name as `<stripped>__dll` (e.g. `Contact_Home__dll`).

##### Step 2.5.6.4 — Surface the manual-cleanup message to the user (PRIMARY PATH)

🧑 **User-driven cleanup is the default.** The skill does NOT delete DMO mappings, DLOs, or Data Streams via API. Instead, it tells the user exactly what to delete and where to click in Setup, then waits for confirmation and verifies the outcome via API.

Display this EXACT block (substituting `<ComponentName>`, `<Data Stream Name>` from 2.5.6.2, and `<support_id>` from 2.5.6.1):

```text
🛑 ============================================================
🛑 DATA KIT INSTALL FAILED — MANUAL CLEANUP REQUIRED
🛑 ============================================================

The Data Kit install failed on a Data Stream component. Auto-retry
cannot fix this — the partially-provisioned Data Stream must be
manually removed from the org before the install can succeed.

   Failed component:       <ComponentName>
   Data Stream to delete:  <Data Stream Name>
   Salesforce Support ID:  <support_id>          (for reference if escalation is needed)

Please complete the following steps in your Salesforce org:

──────────────────────────────────────────────────────────────
STEP 1 — Delete the Data Stream
──────────────────────────────────────────────────────────────
   1. Open Setup → Data Cloud → Data Streams
   2. Find and click the Data Stream: <Data Stream Name>
   3. Under "Data Mapping", click "Review"
        • In the right pane ("Data Model entities"), remove every
          existing DMO mapping (click 🗑 next to each object → confirm)
        • Click "Save & Close" when the right pane is empty
   4. Back on the Data Stream record, click the dropdown (▼) next
      to the "New Formula Field" button (top-right)
   5. Click "Delete Data Stream" and confirm
   6. Wait until the record disappears from the Data Streams list

──────────────────────────────────────────────────────────────
STEP 2 — Confirm back to this skill
──────────────────────────────────────────────────────────────
   Once the Data Stream is fully deleted, reply here with: done

   The skill will then automatically:
     1. Verify via SOQL + Connect API that BOTH the Data Stream
        AND its underlying DLO (<Data Stream Name>__dll) are gone
     2. Re-run Phase 1 (metadata deploy) — recreates the definitions
        fresh in your org
     3. Re-run Phase 2 (Data Kit install) — should now succeed
        against the clean org state

   NOTE: The Setup UI's "Delete Data Stream" action normally cascades
   to the underlying DLO. If verification finds the DLO still lingering,
   the skill will surface a follow-up message with the specific fix.

To abort the installation entirely, reply: stop
```

##### Step 2.5.6.5 — Wait for the user's reply

Block until the user replies. Parse the reply case-insensitively:

- Reply matches `done` / `complete` / `deleted` / `finished` / `ok done` → proceed to Step 2.5.6.6 (verify deletion).
- Reply matches `stop` / `abort` / `cancel` → exit the skill with `final = "UserAborted"` (exit code `1`). Do NOT chain to `/agentforce-data-library`.
- Any other reply → re-ask; do NOT guess. Print:
  ```
  Please reply "done" (all three cleanup steps completed) or "stop" (abort the installation).
  ```

##### Step 2.5.6.6 — Verify BOTH Data Stream AND DLO are gone (do NOT trust "done" alone)

🚨 **The user's `done` reply is a claim, not proof.** Verify both artifacts are actually gone via API before re-running Phase 1. If either is still present, the DK install will fail again with the same error.

**Poll A — DataStream via `salesforce-sobject-all` MCP:**

```
mcp__salesforce-sobject-all__soqlQuery
  paramsJson: {
    "q": "SELECT Id, Name, DataStreamStatus FROM DataStream WHERE Name = '<Data Stream Name>'"
  }
```

**Poll B — DLO via Connect API:**

```
GET /services/data/v67.0/ssot/data-lake-objects/<Data Stream Name>__dll
```

**Terminal outcomes:**

| Poll A (Stream) | Poll B (DLO) | Action |
|---|---|---|
| `totalSize = 0` | HTTP 404 | ✅ BOTH GONE — proceed to Step 2.5.6.7 (auto re-run Phase 1 + Phase 2) |
| `totalSize = 0` | HTTP 200 | ❌ Data Stream deleted but DLO lingering — re-surface a targeted follow-up asking the user to also delete the DLO (see incomplete-cleanup message below) |
| `totalSize >= 1` (any status) | HTTP 404 | ❌ DLO gone but Data Stream still present — re-surface asking user to complete Step 1 (delete Data Stream) |
| `totalSize >= 1` (any status) | HTTP 200 | ❌ Neither is gone — re-surface the full cleanup message |

**Handling incomplete cleanup (any row above except "BOTH GONE"):**

Re-surface a targeted message showing what's still present. The pointer language depends on which artifact is lingering:

```text
⚠️  Verification failed — cleanup is not complete yet.

Current state in the org:
   Data Stream <Data Stream Name>:  <"still present" | "deleted">
   DLO <Data Stream Name>__dll:     <"still present" | "deleted">

Please complete the remaining action in Setup, then reply "done" again:

   <if Data Stream still present:>
     STEP 1 — Delete the Data Stream in Setup → Data Cloud → Data Streams:
        - Click <Data Stream Name>
        - Under "Data Mapping" → Review → remove all DMO mappings → Save & Close
        - Then click ▼ next to "New Formula Field" → Delete Data Stream

   <if DLO still present (Data Stream already deleted):>
     The "Delete Data Stream" action normally cascades to the DLO, but in
     this org it left the DLO behind. Please also delete it:
        - Setup → Data Cloud → Data Lake Objects
        - Find <Data Stream Name>__dll
        - Row dropdown (▼) → Delete → confirm
        - Wait until it disappears from the Data Lake Objects list

To abort, reply "stop".
```

**Retry cap:** if the user replies `done` **3 times in a row** and verification still fails, exit with `final = "DataStreamNotDeleted"` (exit code `1`). Surface the final state and recommend the user contact Salesforce Support with the `<support_id>` — something downstream in the org is preventing deletion (e.g. a Segment or CI referencing the DLO).

##### Step 2.5.6.7 — Auto-re-run Phase 1 then Phase 2 (only after verification passes)

🚨 **Precondition:** Step 2.5.6.6 must have confirmed BOTH:
- DataStream SOQL: `totalSize = 0`
- DLO Connect API GET: HTTP 404

If either is still present, do NOT enter Phase 1 re-run. Loop back to Step 2.5.6.5 (wait for another `done` reply).

Only after both are confirmed gone:

1. **Re-run Phase 1** (Steps 1.3 → 1.10) — `sf project deploy start -d ps-datacloud -o <org_alias> --wait 30 --json`. Because the user deleted the stale Data Stream + DLO, the deploy recreates both fresh in the org. Phase 1's Tooling API gate (Step 1.6) must still confirm `Status = Succeeded`.
2. **Re-run Phase 2** (Steps 2.3 → 2.5) — fresh `d360_datakit_deploy` call, new `jobId`. Retry counter resets to `attempts_used = 1`.

**Second-round outcome handling:**
- ✅ Both phases succeed → normal success path, chain to `/agentforce-data-library`.
- ❌ Phase 2 fails again with a DataStream component (same or different) → hard stop. Do NOT loop Step 2.5.6 again. Set `final = "DataStreamCleanupFailedTwice"` and surface the per-component log for human escalation with the `<support_id>`.
- ⚠️ Any other Phase 2 failure mode → falls through to the normal retry logic in Step 2.5.5 with a fresh attempt budget.

##### Reporting during the wait

```text
⏳ Waiting for manual cleanup...
   Failed component:       <ComponentName>
   Data Stream to delete:  <Data Stream Name>
   DLO to delete:          <Data Stream Name>__dll
   Salesforce Support ID:  <support_id>

   Reply "done" once all three steps are complete.
   Reply "stop" to abort.
```

##### Reporting after successful cleanup + re-run

```text
✅ Manual cleanup complete + Data Kit install succeeded!
   Data Stream removed:     <Data Stream Name>       (deleted by user in Setup)
   DLO removed:             <Data Stream Name>__dll  (cascaded from Data Stream delete, or deleted in follow-up if cascade left it)
   Verification:            ✅ SOQL returned totalSize=0; DLO GET returned HTTP 404
   Re-run Phase 1:          ✅ Tooling API confirmed Succeeded (789 components)
   Re-run Phase 2:          ✅ jobStatus = Complete
```

##### Exit-code contract additions for Step 2.5.6

| Final status | Exit code | Orchestrator action |
|---|---|---|
| `DataStreamCleanupNeeded` (transient — awaiting user's `done` reply) | — | Skill blocks in Step 2.5.6.5 until user replies. |
| `Complete` after manual cleanup + auto re-run | 0 | Auto-chain to `/agentforce-data-library`. |
| `DataStreamMissing` (Step 2.5.6.3 saw 0 rows — Data Stream was never provisioned; different failure mode) | 1 | STOP. Escalate with Support ID; not a stale-DS case. |
| `UserAborted` (Step 2.5.6.5 got `stop`) | 1 | STOP. Do NOT chain. |
| `DataStreamNotDeleted` (Step 2.5.6.6 verification failed 3× in a row after user replied `done`) | 1 | STOP. Something downstream (Segment / CI / other reference) is blocking deletion. Escalate with `<support_id>`. |
| `DataStreamCleanupFailedTwice` (post-cleanup re-run also failed on a DataStream component) | 1 | STOP. Surface both attempts' logs. Do NOT loop Step 2.5.6 again. |

##### Hard rules for Step 2.5.6

- 🧑 **User-driven cleanup is the primary path.** Do NOT auto-delete DMO mappings, Data Streams, or DLOs via API. Field-validated 2026-08-10: API-driven cleanup produced ambiguous states (DLO lingered after Data Stream delete, causing the next DK install to fail with "data lake object already exists"). The Setup UI handles cascading deletions correctly; the skill's job is to identify the failed component and guide the user precisely.
- ⛔ **DO NOT retry the Data Kit install (Phase 2) on the first DataStream failure.** Exit the retry wrapper immediately and enter this cleanup flow. Retries against a stale DS fail identically.
- ⛔ **NEVER loop Step 2.5.6 more than once per skill invocation.** If the post-cleanup re-run fails again on a Data Stream component, exit with `DataStreamCleanupFailedTwice`.
- ⛔ **NEVER trust the user's `done` reply as proof of deletion.** Verify via SOQL + Connect API in Step 2.5.6.6 before re-running Phase 1. If verification fails, re-surface a targeted message pointing at the incomplete step.
- ⛔ **NEVER re-run Phase 1 with the DLO still present in the org.** Field-validated 2026-08-10: Phase 2's `d360_datakit_deploy` refuses to install if the target DLO already exists (`"The Contact_Home data lake object already exists in this org and is linked to a data stream..."`, jobId `08Paj00000xrXVR` on org `HCTrailsignup10thAug`). Both the DataStream SObject (SOQL `totalSize=0`) AND the DLO Connect API record (`GET /data-lake-objects/<name>__dll` returns HTTP 404) must be confirmed gone before Phase 1 can begin.
- ✅ **DO ask the user to delete the Data Stream in Setup.** The Setup UI's "Delete Data Stream" action normally cascades to the underlying DLO. Only if verification (Step 2.5.6.6) shows the DLO is still lingering after the Data Stream is gone should the skill surface a targeted follow-up asking the user to delete the DLO directly (Setup → Data Cloud → Data Lake Objects). Never ask up front for two separate deletions when the cascade should handle it.
- ✅ **DO surface the Salesforce Support ID** from `DeploymentError`. If manual cleanup + re-run fails a second time (`DataStreamCleanupFailedTwice`), or if verification loops fail 3×, the user needs the Support ID to escalate to Salesforce.
- ✅ **DO log every failed component from `DataKitDeploymentLog`** — even non-Data-Stream ones. If multiple components failed simultaneously, the user needs to see all of them in the cleanup message.

---

#### Step 2.6 — Handle common errors

| Error | Where | Fix |
|---|---|---|
| `invalid_grant` / `request not supported on this domain` on any `d360_*` call | data360 MCP | data360 MCP not authenticated for this org — re-run `/mcp-setup` |
| 401 UNAUTHORIZED on `d360_*` | data360 MCP | Token expired — re-run `/mcp-setup` |
| 403 FORBIDDEN on `d360_datakit_deploy` | data360 MCP | Assign "Data Cloud Admin" permission set to the run-as user |
| `SFDC_PERMISSION_ERR` in the deploy job's `errors[]` (e.g. FLS on `Account.<field>__pc`) | Async install | Assign the base permission set that grants FLS on the offending field (usually `PulseSyncBasePS` from ps-base). Fail-fast triggers — retries won't help. |
| `INSUFFICIENT_ACCESS` in errors[] | Async install | Same as above — permset assignment |
| `LICENSE_LIMIT_EXCEEDED` in errors[] | Async install | Data Cloud license missing — admin must add |
| `FEATURE_NOT_ENABLED` in errors[] | Async install | Run `/feature-enablement` first |
| Timeout (Step 2.5's 45-min ceiling on final attempt) | Skill polling | Surface jobId + last status to user; ask whether to keep polling or stop |
| **DataKitDeploymentLog** row(s) with a DataStream-classified failed `ComponentName` (classified via local repo grep, since SOQL `ComponentType` is unreliable) | Post-terminal-failed diagnostic (on FIRST failed attempt) | **Retries won't fix; skill exits retry wrapper immediately.** Step 2.5.6 runs the AUTOMATED Connect API cleanup: enumerate DMO mappings on the failed DLO → DELETE each mapping → cascade-clear "only one DLO" errors via DMO DELETE → DELETE the Data Stream (`shouldDeleteDataLakeObject=true`) → poll SOQL until `totalSize=0` → re-run Phase 1 + Phase 2 automatically. User handoff (Step 2.5.6.10) fires ONLY if any of those API calls returns an unexpected error. |

---

#### Step 2.7 — Final report on success

Report after `final = "Complete"`:

```text
✅ Data Kit Install Complete (via data360 MCP)!

Org (alias):       <org_alias>
Data Kit:          Data360MedTechSolutionKit
Phase 1 status:    ✅ 612 components deployed (Tooling API verified)
Phase 2 final jobId: <jobId>
Phase 2 attempts:    <n>/5

═══════════════════════════════════════════════════

Per-attempt log:
  <attempt_log entries — one per attempt with jobId + outcome>

═══════════════════════════════════════════════════

⏱️  Total wall-clock:  <actual> minutes
Channels:
  - Phase 1: sf CLI (project deploy start + Tooling API DeployRequest query)
  - Phase 2: salesforce-data360 MCP (d360_datakit_deploy → d360_datakit_deploy_status)

Install Process Completed:
✅ Data streams initialization
✅ Calculated insights compilation
✅ Identity resolution rules processing
✅ Data model field mappings
✅ Related list enrichments

Next step in the installer chain: /agentforce-data-library
```

Then AUTOMATICALLY invoke the next skill:

```
/agentforce-data-library <org_alias>
```

Do NOT ask the user for permission — the installer chain auto-advances on `Complete`.

---

#### Step 2.8 — Final report on failure (any non-zero exit)

If `final` is anything other than `Complete`, print this block and STOP. The installer chain MUST NOT auto-advance.

```text
🛑 ============================================================
🛑 DATA KIT INSTALL FAILED — INSTALLER CHAIN STOPPED
🛑 ============================================================

Skill:         /datakit-install
Phase:         2 (data360 MCP install/activate)
Final status:  <FailedAllAttempts | ReDeployRejected | FailFastDeterministic | Timeout | UserAborted | DataStreamCleanupFailedTwice>
Attempts:      <n>/5
Last jobId:    <jobId>
Last error:    <verbatim error from data360 MCP response>

Failed components (from DataKitDeploymentLog):
  <one row per failure — ComponentName, ComponentType, DeploymentError>

Cleanup path attempted (if applicable):
  <e.g. "Step 2.5.6 fired for stale Data Stream Contact_Home — user replied 'done'
   after manual cleanup, Phase 1+2 re-ran, second attempt failed on Account_Home.
   Not looping Step 2.5.6 again — human escalation needed.">


Per-attempt log:
  <one line per attempt: attempt #, jobId, outcome>

Channels used:
  - Phase 1: sf CLI (project deploy start + Tooling API DeployRequest query) — Phase 1 was SUCCESSFUL
  - Phase 2: salesforce-data360 MCP (mcp__salesforce-data360__execute) — Phase 2 FAILED

Common root causes:
  • Data Cloud feature license missing or expired (LICENSE_LIMIT_EXCEEDED)
  • Required permission set not assigned (INSUFFICIENT_ACCESS)
  • Data Cloud feature isn't enabled — run /feature-enablement first (FEATURE_NOT_ENABLED)
  • Stale FLS on a Data Kit component — verify PulseSyncBasePS assigned
  • Managed package conflict with an existing Data Kit
  • Stale/partial Data Stream from a prior failed install — surfaces as DataKitDeploymentLog rows classified as DataStream (via local repo grep against ps-datacloud/main/default/dataStreamTemplates/, since SOQL ComponentType is unreliable). Handled AUTOMATICALLY by Step 2.5.6: skill exits the retry wrapper on the first DataStream failure, discovers DMO mappings on the failed DLO via Connect API, DELETEs each mapping (using cascade-via-DMO-DELETE for "only one DLO" blocks), DELETEs the Data Stream itself, polls until deletion completes, then re-runs Phase 1 + Phase 2 — all without user intervention. User handoff (Step 2.5.6.10) fires ONLY if any of those API calls returns an unexpected error. Only the SAME stale-DS pattern surfacing twice in one skill invocation triggers `DataStreamCleanupFailedTwice`.

🛑 INSTALLER WILL NOT PROCEED.
   Skills NOT run (blocked):
     • /agentforce-data-library
     • /notebook-ai
     • /document-ai
     • ... and all remaining installer steps

Next steps for the user:
  1. Read the error message above verbatim — it usually points at the exact fix.
  2. Fix the underlying issue in the org (permset, license, feature, FLS).
  3. Re-run /datakit-install <org_alias> manually,
     OR re-run the data360-healthcare-installer agent (it will skip completed
     early steps and resume from this one).
     Phase 1 is idempotent — re-running the skill will re-verify the 612
     components via Tooling API and skip re-deploying if they're still there.
```

---

## Important Rules

**CRITICAL — Two-phase gating (the core merged behavior):**
- 🚨 **Phase 2 does NOT run unless Phase 1's Tooling API check (Step 1.6) returned `Status = Succeeded` with `NumberComponentErrors = 0`.** Local result-file success alone is NOT sufficient.
- 🚨 **The next skill (`/agentforce-data-library`) is auto-invoked ONLY when Phase 2 exits with `jobStatus = "Complete"`.** Any non-Complete exit halts the installer chain.
- 🚨 **Phase 2's Step 2.2 (skip metadata re-verification) is safe ONLY because Phase 1's Step 1.6 already confirmed the deploy via Tooling API.** These two steps are load-bearing together — do not delete either.

**CRITICAL — Phase 1 Deployment Status Verification (MANDATORY GATE):**
- 🚨 **STRICTLY check the org's DeployRequest status FIRST before treating any deployment as failed**
- 🚨 **NEVER trust `/tmp/datakit_deploy_result.json` alone — query the org via Tooling API (Step 1.6) every time**
- 🚨 **NEVER run destructive commands (`rm -rf`, `find ... -delete`, folder removal) without an org-verified `Status = Failed` AND `NumberComponentErrors > 0`**
- 🚨 **NEVER prompt the user to approve a fix unless the org-verified status is `Failed`**
- 🚨 **If org says `Succeeded` and local file says failed → TRUST THE ORG, ignore the file, proceed to Step 1.8**
- 🚨 **Step 1.7 (failure handling) is gated behind Step 1.6 (org status verification) — no exceptions**

**CRITICAL — Phase 1 Deployment Execution:**
- 🚨 **DEPLOY ONLY ONCE** — Run `sf project deploy start` command ONE TIME ONLY
- 🚨 **CAPTURE OUTPUT TO FILE** — Use `> /tmp/datakit_deploy_result.json 2>&1` to save results
- 🚨 **PARSE FILE FOR DETAILS** — Use `cat /tmp/datakit_deploy_result.json` to read results
- 🚨 **NEVER RE-RUN DEPLOYMENT** to check status or capture different output
- 🚨 **DO NOT RUN MULTIPLE TIMES** for any reason except retry after error fix

**CRITICAL — Phase 2 Execution channel:**
- 🚨 **ALL Phase 2 triggers and status checks use `mcp__salesforce-data360__execute`.** NO `curl`, NO `sf apex run`, NO `sf org display`, NO SOQL, NO `--use-tooling-api`, NO Connect REST via curl. The prior REST/curl version has been retired.
- 🚨 The data360 MCP server must be authenticated for the target org via `/mcp-setup` before this skill runs. Otherwise every call fails with `invalid_grant`.

**CRITICAL — Phase 2 Terminal state matching:**
- 🚨 Match ALL 5 terminal-failed values in `result.jobStatus`: `Failed`, `Error`, `Cancelled`, `Canceled`, `Aborted`. Handling only `Failed` will silently poll for 45 min against a dead job.
- 🚨 The only terminal-success value is `Complete`. `Installed` is NOT a value the API returns for this endpoint.
- 🚨 Non-terminal values (any of `Running`, `InProgress`, `Queued`, `Pending`, or anything not in the terminal lists) mean "keep polling".

**CRITICAL — Phase 2 Trigger payload:**
- 🚨 `dataKitDevName` must be `"Data360MedTechSolutionKit"` (developer name, not display name).
- 🚨 `asyncMode` must be `true` — synchronous mode times out.
- 🚨 `cdpDataKitDeployInput.components` must be `[]` — empty array means "deploy all components in the kit".

**CRITICAL — Phase 2 Polling execution model:**
- 🚨 Poll cadence is **5 minutes** per check, max **9 checks per attempt** = 45 min per attempt.
- 🚨 Each `sleep 300` is a FOREGROUND `Bash({command: "sleep 300"})` call — NEVER `run_in_background: true`. Sub-agents do not receive `<task-notification>` callbacks; a backgrounded loop silently abandons the install.
- 🚨 Do NOT pack the whole 45-min loop into one foreground call. Bash's 10-min foreground cap kills it on the first `sleep 300`, and any retry restarts at check 1.
- 🚨 The sub-agent stays alive across all 9 checks by re-issuing (Bash sleep, MCP status, Bash sleep, MCP status, …) — one round-trip per check.

**CRITICAL — Phase 2 Retry policy:**
- ✅ Max **5 total attempts** (1 initial + 4 retries) on `TerminalFailed`.
- ✅ Tiered backoff: 30s for attempts 1→2 and 2→3; 60s for attempts 3→4 and 4→5.
- ✅ Fail-fast on `INSUFFICIENT_ACCESS`, `LICENSE_LIMIT_EXCEEDED`, `FEATURE_NOT_ENABLED`, `INVALID_TYPE`, `permission`, `not licensed` — abort retries immediately.
- ❌ Do NOT retry on `Timeout` — only on `TerminalFailed`.

**CRITICAL — Hard stop on failure (both phases):**
- 🛑 If Phase 1 fails (Tooling API confirms `Status = Failed` even after Step 1.7 retry), Phase 2 does NOT run and the installer chain stops.
- 🛑 If Phase 2 exit code is anything other than 0, the installer chain MUST stop. Do NOT auto-invoke `/agentforce-data-library`. Do NOT auto-invoke any later skill.
- 🛑 The user must fix the root cause in the org and re-run the skill (or re-invoke the installer agent, which will resume from this step).

**CRITICAL — No Approval Prompts:**
- ✅ **Pre-approve all commands** in `.claude/settings.json` to avoid approval prompts
- ✅ Commands to pre-approve: `bash:sf *`, `bash:grep *`, `bash:find *`, `bash:sed *`, `bash:cat *`, `bash:echo *`, `bash:pwd`, `bash:test *`
- ✅ Without pre-approval, user will be prompted 10+ times during deployment
- ✅ This significantly slows down the process (from 2 minutes to 10+ minutes)

**Workflow Optimization:**
- ✅ **Skip org authentication check** — Assume org already authenticated from base-metadata-deploy
- ✅ **Minimal repository validation** — Quick check only, assume correct directory
- ✅ **No redundant checks** — Trust previous steps completed successfully

**General Rules:**
- NEVER hardcode org names — always use provided `org_alias` parameter for Phase 1 (Phase 2's data360 MCP is bound to the target org via `/mcp-setup`).
- ALWAYS use `--json` flag for parseable output in Phase 1.
- ALWAYS check for KeyQualifier fields before Phase 1 deployment.
- ALWAYS retry Phase 1 deployment after cleanup if initial deployment fails (but only ONCE per attempt).
- ALWAYS validate Phase 1 component count is 612 after deployment.
- ALWAYS verify Phase 1 deployment via Tooling API (Step 1.6).
- ALWAYS automatically proceed to Phase 2 after Phase 1's Tooling API gate confirms success — never ask user.
- ALWAYS automatically proceed to `/agentforce-data-library` after Phase 2 exits `Complete` — never ask user.
- ALWAYS report per-attempt outcome + jobId in the Phase 2 final report.
- Remove managed DLO folders only if Phase 1 deployment errors occur (Step 1.7 handles this).
- Phase 1 timeout is 30 minutes — typical deployment takes 5–10 minutes (actual deployment ~18 seconds).
- Phase 2 estimated total time on success: **30–45 minutes** for the first attempt (typical). Worst case with all 5 attempts failing: ~228 min (~3 hr 48 min).
- Report both success and failure with structured output.
- Provide deployment ID (Phase 1) and jobId (Phase 2) for tracking in Salesforce.
- If Phase 1 deployment shows "unchanged" for all components, they were already deployed previously — Tooling API will still show `Succeeded`, and Phase 2 will proceed normally.

---

## Cleanup temp artifacts (MANDATORY before next skill)

Before declaring this skill complete, delete every temporary file/folder created during the run.

**Phase 1 cleanup:**

**Failure handling rule:**
- If the org-side `DeployRequest` query (Step 1.6) reports `Status = Failed`, **do NOT clean up** — keep `/tmp/datakit_deploy_result.json` (and `/tmp/datakit_deploy_retry.json` if Step 1.7 ran) so the failure can be inspected.
- Fix the underlying issue, retry the deploy, then run cleanup once Step 1.6 confirms `Status = Succeeded`.

**Files this skill creates in Phase 1 and must delete on success:**

```bash
rm -f /tmp/datakit_deploy_result.json
rm -f /tmp/datakit_deploy_retry.json
```

**Verification (must show no leftovers):**

```bash
ls /tmp/datakit_deploy_result.json /tmp/datakit_deploy_retry.json 2>&1 | grep -v "cannot access"
```

**Phase 2 cleanup:**

Phase 2 creates no scratch files — every trigger and status check is a direct MCP call with in-memory `paramsJson`. Nothing to delete for Phase 2.

The prior `curl`-based version of `/datakit-d360-deploy` created `datakit_api_kickoff.json`, `datakit_api_status.json`, `org_creds.json`, `datakit_api_poll.log`; the data360 MCP version does not.

**Rules:**
- ✅ Only delete the two Phase 1 files listed above. Do NOT delete any repo source.
- ✅ The `ps-datacloud/` folder and its contents are repo source — never touched by this cleanup.
- ❌ Skipping this step is not allowed once Step 1.6 confirms `Status = Succeeded` (Phase 1) and Phase 2 exits `Complete`.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"datakit-install"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.datakit-install` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
