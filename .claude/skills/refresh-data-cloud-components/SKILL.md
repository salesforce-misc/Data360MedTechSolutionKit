---
name: refresh-data-cloud-components
description: "Refresh Data Cloud components in sequence: Identity Resolution, Calculated Insights (2 insights), and Segment. Uses the salesforce-data360 MCP server end-to-end (d360_ir_list / d360_ir_run / d360_ir_get / d360_ci_run / d360_ci_run_status / d360_segment_get / d360_segment_publish) — NO curl, NO SOQL. Refreshes 'Unify Patient IOT Data' IR, 2 calculated insights ('Pacemaker Latest Transmission' + 'Pacemaker Patient Health Summary'), and 'Anomalous Pacemaker Battery' segment for the Healthcare Data Kit. Use when user wants to refresh data cloud components, trigger IR/CI/Segment refresh, or update data cloud calculations."
---

# refresh-data-cloud-components

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"refresh-data-cloud-components"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: refresh-data-cloud-components already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Refresh Data Cloud components in the correct sequence: Identity Resolution → Calculated Insights (one-by-one) → Segment (fire-and-forget).

This skill:
1. Refreshes Identity Resolution "Unify Patient IOT Data" and waits for `lastJobStatus = SUCCESS`.
2. Refreshes 2 Calculated Insights ONE AT A TIME, waiting for each to show `lastRunStatus = SUCCESS` before triggering the next:
   - CI 1/2: Pacemaker Latest Transmission → wait for SUCCESS
   - CI 2/2: Pacemaker Patient Health Summary → wait for SUCCESS
3. Triggers Segment "Anomalous Pacemaker Battery" publish (fire-and-forget).

**🚨 EXECUTION CHANNEL — data360 MCP ONLY:**

All triggers and status checks are driven by the `salesforce-data360` MCP server (`mcp__salesforce-data360__execute` tool). **NO `curl`, NO `sf apex run`, NO SOQL, NO Tooling API.** The prior version of this skill shelled out to `curl` against `/services/data/v66.0/ssot/...` — that has been replaced with the equivalent data360 MCP tools verified working end-to-end on 2026-07-16.

| Component action | data360 MCP tool | Parameter shape |
|---|---|---|
| List IRs | `d360_ir_list` | `{}` |
| Get IR (status poll) | `d360_ir_get` | `{"identityResolution": "<IR id, e.g. 1irxxxxxxxxxxxxxxxx>"}` |
| Trigger IR run | `d360_ir_run` | `{"identityResolution": "<IR id>", "input": {"callingApp": "MedTechInstaller", "callingAppInfo": "refresh-data-cloud-components skill"}}` |
| Trigger CI run | `d360_ci_run` | `{"apiName": "<CI api name, e.g. Pacemaker_Latest_Transmission__cio>"}` |
| Get CI run status | `d360_ci_run_status` | `{"apiName": "<CI api name>"}` |
| Get segment (to capture `marketSegmentId`) | `d360_segment_get` | `{"segmentApiName": "<segment api name, e.g. Anomalous_Pacemaker_Battery>"}` |
| Publish segment | `d360_segment_publish` | `{"segmentId": "<marketSegmentId, starts with 1sg>"}` |

**Prerequisites:**
- The `salesforce-data360` MCP server must be authenticated for the target org via `/mcp-setup`. Without that, every MCP call in this skill fails with `invalid_grant` / `request not supported on this domain`.
- Target org must have Data Cloud enabled and licensed.
- User must have "Manage Data Cloud" permission.
- Identity Resolution "Unify Patient IOT Data" must exist.
- 2 Calculated Insights must exist ("Pacemaker Latest Transmission" + "Pacemaker Patient Health Summary").
- Segment "Anomalous Pacemaker Battery" must exist.

**🚨 STATUS FIELDS — CASE AND NAMES:**

| Component | Status field | Observed values |
|---|---|---|
| Identity Resolution | `lastJobStatus` on `d360_ir_get` response | `IN_PROGRESS`, `SUCCESS`, `FAILED` (UPPERCASE) |
| Calculated Insight | `lastRunStatus` on `d360_ci_run_status` response | `PENDING`, `PROCESSING`, `SUCCESS`, `FAILED` (UPPERCASE) |
| Segment | `publishStatus` on `d360_segment_publish` response | `PUBLISHING`, `PUBLISHED`, `FAILED` (UPPERCASE) |

All status values are UPPERCASE. Comparisons must be exact — never Title-case the value.

**Temp file policy:** This skill writes **no** temp files. Every read/write goes through the data360 MCP tool call directly.

---

## Arguments

- `org_alias` (optional): Target Salesforce org alias or username. The data360 MCP server is bound to whichever org `/mcp-setup` was run against — this arg is informational only (used in the final report). It does NOT change which org the MCP call hits.

---

## Preconditions

Before running:

- `/mcp-setup` has been run successfully and `salesforce-data360` MCP is authenticated for the target org.
- Target org has Data Cloud enabled and licensed.
- User has "Manage Data Cloud" permission.
- The three components ("Unify Patient IOT Data" IR, 2 CIs, "Anomalous Pacemaker Battery" segment) exist in the org.

There are NO `sf` CLI or `curl` preconditions — this skill never shells out.

---

## Workflow

### Step 1 — Confirm target org via getUserInfo (informational)

Optional but recommended — surfaces which org the MCP server is bound to, so the final report matches the user's expectation:

```
mcp__salesforce-sobject-all__getUserInfo
```

Read `identity.username` from the response and cache it as `<orgUsername>`. If the user passed `org_alias` in and it does not match `<orgUsername>`, warn but proceed — the MCP server is what dictates the target, not the argument.

---

### Step 2 — List Identity Resolutions and find "Unify Patient IOT Data"

```
mcp__salesforce-data360__execute
  toolName: d360_ir_list
  paramsJson: {}
```

**Success response shape (result field):**
```json
{
  "result": {
    "identityResolutions": [
      {
        "id": "1irxxxxxxxxxxxxxxxx",
        "label": "Unify Patient IOT Data",
        "configurationType": "individual",
        "rulesetStatus": "PUBLISHED"
      },
      ...
    ]
  }
}
```

Parse `result.identityResolutions`, find the entry where `label == "Unify Patient IOT Data"`, and cache its `id` as `<IR_ID>`.

**If not found:**
- Report error: Identity Resolution "Unify Patient IOT Data" not found.
- Cannot proceed. Stop the skill.

---

### Step 3 — Trigger Identity Resolution run

```
mcp__salesforce-data360__execute
  toolName: d360_ir_run
  paramsJson: {
    "identityResolution": "<IR_ID>",
    "input": {
      "callingApp": "MedTechInstaller",
      "callingAppInfo": "refresh-data-cloud-components skill"
    }
  }
```

**Success response:**
```json
{ "result": { "resultCode": "SuccessfullySubmittedIdentityResolutionJobRunRequest" } }
```

Report:
```text
✅ Identity Resolution "Unify Patient IOT Data" refresh triggered
   IR id: <IR_ID>
   Result: SuccessfullySubmittedIdentityResolutionJobRunRequest
```

---

### Step 3A — Poll IR until `lastJobStatus = SUCCESS` (max 20 min, 60 s cadence)

**Do NOT proceed to CIs until IR status = SUCCESS.**

Poll loop — up to 20 iterations, 60 s between iterations:

For each iteration `i` in 1..20:
1. Call:
   ```
   mcp__salesforce-data360__execute
     toolName: d360_ir_get
     paramsJson: {"identityResolution": "<IR_ID>"}
   ```
2. Read `result.lastJobStatus` (UPPERCASE — e.g. `IN_PROGRESS`, `SUCCESS`, `FAILED`).
3. Log: `IR poll <i>/20 (minute <i>): lastJobStatus=<status>`.
4. If `status == "SUCCESS"` → break, proceed to Step 4.
5. If `status == "FAILED"` → hand to Step 3B retry block.
6. Otherwise (`IN_PROGRESS`, or any other transient value) — sleep 60 s and continue.

**Note on `lastJobCompleted`:** it reflects the PREVIOUS run while the current one is in progress — do NOT compare it against "now". Gate only on `lastJobStatus`.

**Sleep between polls:** use a foreground `Bash({command: "sleep 60"})` call. Each sleep is well under any Bash foreground cap. Do NOT `run_in_background: true` — this skill polls interactively; the sub-agent stays alive across all 20 iterations by re-issuing the MCP call each round.

**Timeout (20 iterations exhausted, still not terminal):**
```text
❌ Identity Resolution did not reach SUCCESS within 20 minutes
   Current lastJobStatus: <status>
   IR id: <IR_ID>

🛑 STOPPING. Timeout (still IN_PROGRESS) is NOT auto-retried — surface to user.
```

---

### Step 3B — Auto-retry IR on `FAILED` (max 3 total attempts)

**When Step 3A returns `FAILED`, re-issue the trigger and re-poll.** Up to 3 total attempts (1 initial + 2 retries) with a 30 s gap between failure and retry.

Pseudocode (data360 MCP native, no shell):

```
attempt = 1
final = "Pending"

while attempt <= 3:
    log(f"==== IR attempt {attempt} / 3 ====")

    # Re-trigger
    d360_ir_run({"identityResolution": IR_ID, "input": {...}})

    # Poll up to 20 min
    poll = "Pending"
    for i in 1..20:
        r = d360_ir_get({"identityResolution": IR_ID})
        status = r.result.lastJobStatus  # UPPERCASE
        log(f"Attempt {attempt} — minute {i}: lastJobStatus={status}")
        if status == "SUCCESS":
            poll = "Success"; break
        if status == "FAILED":
            poll = "Failed"; break
        sleep(60)

    if poll == "Success":
        final = "Success"; break

    if poll == "Failed" and attempt < 3:
        log(f"🔁 IR failed on attempt {attempt}. Waiting 30s before retry...")
        sleep(30)
        attempt += 1
        continue

    if poll == "Failed":
        final = "FailedAllAttempts"; break

    # poll == "Pending" → 20-min timeout on this attempt
    final = "Timeout"; break

match final:
    Success           → proceed to Step 4
    FailedAllAttempts → log "❌ IR failed after 3 attempts. Stopping."; exit non-zero
    Timeout           → log "⏱️ IR did not finish in 20 min on attempt {attempt}."; exit non-zero
```

**Reporting:**
- ✅ First-try success → `IR attempt 1/3: Success`
- 🔁 Recovered after retry → `IR attempt 1/3: Failed → 2/3: Success`
- ❌ All 3 failed → `IR attempts 1, 2, 3 all Failed. Stopping. Cannot proceed to CIs.`
- ⏱️ Timeout → surfaced to user, no auto-retry.

---

### Step 4 — Refresh Calculated Insights ONE AT A TIME (strictly sequential)

**Only execute this step after IR shows `lastJobStatus = SUCCESS`.**

**🚨 CRITICAL EXECUTION RULES:**
- ✅ Refresh each CI one at a time.
- ✅ Wait for each CI to show `lastRunStatus = SUCCESS` before triggering the next.
- ❌ NEVER parallelize CIs.
- ❌ NEVER trigger CI 2 until CI 1 shows `SUCCESS`.

**CI order (strictly sequential):**

| # | Display Name | API Name (`apiName` on `d360_ci_run` / `d360_ci_run_status`) |
|---|---|---|
| 1 | Pacemaker Latest Transmission | `Pacemaker_Latest_Transmission__cio` |
| 2 | Pacemaker Patient Health Summary | `Pacemaker_Patient_Health_Summary__cio` |

For EACH CI, in order, perform steps 4.1 → 4.4.

#### 4.1 — Trigger CI refresh

```
mcp__salesforce-data360__execute
  toolName: d360_ci_run
  paramsJson: {"apiName": "<CI_API_NAME>"}
```

Success response typically returns `{"result": {"success": true, "errors": []}}` or a run identifier — anything without an `errors` array populated counts as accepted.

Report:
```text
🔄 CI <N>/2: <Display Name> (<CI_API_NAME>) — refresh triggered
```

#### 4.2 — Poll CI `lastRunStatus` until `SUCCESS` (max 10 min, 30 s cadence)

CI runs go `PENDING → PROCESSING → SUCCESS/FAILED`. Initial `PENDING` lasts ~30 s before flipping.

Sleep 30 s once up front, then poll for up to 20 iterations (30 s each = 10 min):

```
sleep(30)  # initial wait before first poll — CI registers as PENDING for ~30s

for i in 1..20:
    r = d360_ci_run_status({"apiName": CI_API_NAME})
    status = r.result.lastRunStatus  # UPPERCASE
    log(f"CI {CI_DISPLAY} poll {i}/20 ({i*30}s): lastRunStatus={status}")
    if status == "SUCCESS":
        log(f"✅ CI {CI_DISPLAY} Success"); break
    if status == "FAILED":
        log(f"❌ CI {CI_DISPLAY} Failed → hand to Step 4.3 retry"); break
    sleep(30)
```

**Verification:**
- ✅ `SUCCESS` → CI complete. Continue to Step 4.4.
- ⏳ `PENDING` / `PROCESSING` → sleep 30 s, poll again.
- ❌ `FAILED` → trigger Step 4.3 retry (max 3 total per CI).

**Timeout (all 20 polls exhausted, still not terminal):**
```text
❌ CI <Display Name> did not complete within 10 minutes
   Current lastRunStatus: <status>
🛑 STOPPING. Cannot proceed to next CI until this one shows SUCCESS.
```

#### 4.3 — Auto-retry CI on `FAILED` (max 3 total attempts per CI)

Same shape as Step 3B — 3 total attempts, 30 s gap between failure and retry. Retries apply **per CI** — a Failed-then-recovered CI does NOT extend retries to subsequent CIs. If all 3 attempts fail for one CI, stop the entire skill (downstream CIs may depend on earlier ones).

Pseudocode:

```
attempt = 1
ci_final = "Pending"

while attempt <= 3:
    log(f"==== CI {CI_DISPLAY} attempt {attempt} / 3 ====")

    d360_ci_run({"apiName": CI_API_NAME})

    poll = "Pending"
    sleep(30)  # initial wait
    for i in 1..20:
        r = d360_ci_run_status({"apiName": CI_API_NAME})
        status = r.result.lastRunStatus
        log(f"Attempt {attempt} — poll {i}/20: lastRunStatus={status}")
        if status == "SUCCESS":
            poll = "Success"; break
        if status == "FAILED":
            poll = "Failed"; break
        sleep(30)

    if poll == "Success":
        ci_final = "Success"; break

    if poll == "Failed" and attempt < 3:
        log(f"🔁 CI {CI_DISPLAY} failed on attempt {attempt}. Waiting 30s before retry...")
        sleep(30)
        attempt += 1
        continue

    if poll == "Failed":
        ci_final = "FailedAllAttempts"; break

    ci_final = "Timeout"; break

match ci_final:
    Success           → proceed to Step 4.4
    FailedAllAttempts → log "❌ CI {CI_DISPLAY} failed after 3 attempts. Stopping."; exit non-zero
    Timeout           → log "⏱️ CI {CI_DISPLAY} did not finish in 10 min."; exit non-zero
```

**Reporting:**
- ✅ First-try success → `CI {N}/2 {Display}: attempt 1/3: Success`
- 🔁 Recovered → `CI {N}/2 {Display}: 1/3 Failed → 2/3 Success`
- ❌ All 3 failed → `CI {N}/2 {Display}: attempts 1, 2, 3 all Failed. Stopping; subsequent CIs not run.`

#### 4.4 — Report success and continue to next CI

```text
✅ CI <N>/2: <Display Name> — lastRunStatus: SUCCESS
   Proceeding to next CI...
```

#### 4.5 — Execute order

Repeat 4.1 → 4.4 sequentially for both CIs:

1. **CI 1/2:** Pacemaker Latest Transmission → trigger → wait → SUCCESS → next
2. **CI 2/2:** Pacemaker Patient Health Summary → trigger → wait → SUCCESS → done

**🚨 DO NOT trigger CI 2 until CI 1's `lastRunStatus = SUCCESS`.**

After both CIs complete successfully, proceed to Step 5 (Segment).

```text
✅ All 2 Calculated Insights completed successfully (sequential)

Status Summary:
1. Pacemaker Latest Transmission:      lastRunStatus=SUCCESS
2. Pacemaker Patient Health Summary:   lastRunStatus=SUCCESS

Proceeding to Segment publish...
```

---

### Step 5 — Get segment `marketSegmentId` via `d360_segment_get`

**Only execute this step after both CIs show `lastRunStatus = SUCCESS`.**

**🚨 CRITICAL:** the publish endpoint requires the **`marketSegmentId`** (starts with `1sg`), NOT the `segmentApiName` and NOT any list-response `id` field.

```
mcp__salesforce-data360__execute
  toolName: d360_segment_get
  paramsJson: {"segmentApiName": "Anomalous_Pacemaker_Battery"}
```

**Success response shape:**
```json
{
  "result": {
    "segments": [
      {
        "apiName": "Anomalous_Pacemaker_Battery",
        "displayName": "Anomalous Pacemaker Battery",
        "marketSegmentId": "1sgXXXXXXXXXXXXXXX",
        "marketSegmentDefinitionId": "3HXXXXXXXXXXXXXXXX",
        "segmentStatus": "ACTIVE"
      }
    ]
  }
}
```

Cache `result.segments[0].marketSegmentId` as `<SEGMENT_ID>`. That's what goes into Step 6's publish call.

**If not found (empty `segments` array or missing `marketSegmentId`):**
- Report error: Segment "Anomalous Pacemaker Battery" not found.
- Stop. User must create the segment first.

> **Why one-step here:** `d360_segment_get` (single-segment lookup by `segmentApiName`) returns `marketSegmentId` directly. The prior REST version needed a two-step lookup (list → single GET) because the list endpoint returns `id: null`. The MCP `d360_segment_get` collapses that into one call.

---

### Step 6 — Publish segment via `d360_segment_publish` (fire-and-forget)

**🚨 CRITICAL: Fire the publish and proceed to Step 7 IMMEDIATELY. Do NOT poll segment status.**

Unlike IR and CIs, segment publish is fire-and-forget — the skill reports success as soon as the publish trigger returns.

```
mcp__salesforce-data360__execute
  toolName: d360_segment_publish
  paramsJson: {"segmentId": "<SEGMENT_ID>"}
```

**Success response (observed 2026-06-10 via REST; same shape from MCP):**
```json
{
  "result": {
    "errors": [{}],
    "jobId": "5d3228e8-b09f-49e0-afb3-f90e7d3f6299",
    "partitionId": "1sgHn000000TNRT_...",
    "publishStatus": "PUBLISHING",
    "segmentId": "1sgHn000000TNRTIA4",
    "success": true
  }
}
```

The presence of `"jobId"`, `"publishStatus": "PUBLISHING"`, or `"success": true` confirms the trigger was accepted. Note: `errors: [{}]` appears even on success — an empty object inside the array, not a real error.

Report:
```text
✅ Segment "Anomalous Pacemaker Battery" publish triggered
   marketSegmentId: <SEGMENT_ID>
   jobId: <jobId>
   publishStatus: PUBLISHING (running asynchronously — skill does NOT wait)
```

**🚨 DO NOT poll segment status. Proceed directly to Step 7 once a publish is accepted (or all retries exhausted).**

#### 6.1 — Auto-retry segment publish on trigger failure (max 3 total attempts)

If the response does NOT contain `success: true`, `jobId`, or `publishStatus: PUBLISHING`, re-issue the publish up to 2 more times, 30 s gap. Segment publish is fire-and-forget — retries apply ONLY to the trigger HTTP response, not to async publishing progress.

Pseudocode:

```
attempt = 1
seg_final = "Pending"
last_response = None

while attempt <= 3:
    log(f"==== Segment publish attempt {attempt} / 3 ====")
    r = d360_segment_publish({"segmentId": SEGMENT_ID})
    last_response = r

    # Accept any of: success=true, jobId present, publishStatus="PUBLISHING"
    if r.result.get("success") or r.result.get("jobId") or r.result.get("publishStatus") == "PUBLISHING":
        seg_final = "Triggered"
        log(f"✅ Segment publish triggered on attempt {attempt}")
        break

    log(f"❌ Segment publish did not return success on attempt {attempt}: {r}")
    if attempt < 3:
        log("🔁 Waiting 30s before retry...")
        sleep(30)
        attempt += 1
        continue
    seg_final = "FailedAllAttempts"
    break

match seg_final:
    Triggered         → proceed to Step 7 (async publish runs in background — do NOT poll)
    FailedAllAttempts → log "⚠️ Segment publish trigger failed after 3 attempts. Last response: {last_response}. Continuing to Step 7 — IR + CIs already verified Successful."
                        # Do NOT exit non-zero — segment is fire-and-forget and IR + CIs already succeeded.
```

**Reporting:**
- ✅ First-try success → `Segment publish: attempt 1/3: triggered`
- 🔁 Recovered → `Segment publish: 1/3 failed → 2/3 triggered`
- ⚠️ All 3 failed → `Segment publish: attempts 1, 2, 3 all failed to trigger. Last response: {...}`. Final report still runs.

---

### Step 7 — Generate final report

Generate report after Step 3B (IR success), Step 4.5 (both CIs success), and Step 6.1 (segment publish triggered or reported failed).

```text
✅ Data Cloud Components Refresh Complete!

Org (username): <orgUsername>
Channel:        salesforce-data360 MCP (mcp__salesforce-data360__execute)

═══════════════════════════════════════════════════

🔍 Identity Resolution (verified):
✅ Name:            Unify Patient IOT Data
✅ id:              <IR_ID>
✅ lastJobStatus:   SUCCESS

═══════════════════════════════════════════════════

📊 Calculated Insights (2) — refreshed sequentially, all verified SUCCESS:
✅ 1/2 Pacemaker Latest Transmission       — lastRunStatus: SUCCESS
✅ 2/2 Pacemaker Patient Health Summary    — lastRunStatus: SUCCESS

═══════════════════════════════════════════════════

🎯 Segment (fire-and-forget):
✅ Name:            Anomalous Pacemaker Battery
✅ marketSegmentId: <SEGMENT_ID>
✅ Publish:         Triggered (jobId <jobId>, running asynchronously — not waiting for completion)

═══════════════════════════════════════════════════

⏱️  Total processing time: <actual> minutes

Next Step:
Auto-proceed to the next installer step (`/copy-field-sync`).
```

---

### Step 9 — Error handling

If any MCP call returns an error (401, 403, 404, `INVALID_TYPE`, network timeout, etc.), surface it in the shape:

```text
❌ Data Cloud Component Refresh Failed

Org:                 <orgUsername>
Failed component:    <IR | CI | Segment>
MCP tool:            <d360_ir_run | d360_ci_run | d360_segment_publish | ...>
Params:              <the exact paramsJson used>
Error (verbatim):    <the MCP response>

Possible causes:
• Component not found in org
• Data Cloud not enabled
• Missing permissions
• Invalid component configuration
• data360 MCP not authenticated for this org — re-run /mcp-setup

Suggested fixes:
✅ Re-run /mcp-setup if the error is `invalid_grant` / `request not supported on this domain`
✅ Verify Data Cloud enabled: Setup → Data Cloud → Settings
✅ Check permissions: Setup → Users → Permission Sets → Data Cloud Admin
✅ Verify component exists: Setup → Data Cloud → <Component Type>
```

Common errors:

| Error | Suggested fix |
|---|---|
| Identity Resolution not found in `d360_ir_list` | Create "Unify Patient IOT Data" IR first |
| Calculated Insight `apiName` returns 404 on `d360_ci_run_status` | Verify CI API name ends with `__cio` and matches ps-datacloud metadata |
| `d360_segment_get` returns empty `segments` array | Create "Anomalous Pacemaker Battery" segment first |
| `invalid_grant` / `request not supported on this domain` | data360 MCP is bound to a different org — re-run `/mcp-setup` |
| 401 UNAUTHORIZED | data360 MCP token expired — re-run `/mcp-setup` |
| 403 FORBIDDEN | Assign "Data Cloud Admin" permission set to the run-as user |

---

## Important Rules

**CRITICAL — Execution channel:**
- 🚨 **ALL triggers and status checks use `mcp__salesforce-data360__execute`.** NO `curl`, NO `sf apex run`, NO SOQL, NO `--use-tooling-api`. The prior REST version has been retired.
- 🚨 The data360 MCP server must be authenticated for the target org via `/mcp-setup` before this skill runs. Otherwise every call fails with `invalid_grant`.

**CRITICAL — Execution sequence:**
- 🚨 **ALWAYS execute in this order:** Identity Resolution → Calculated Insights (2 sequential) → Segment.
- 🚨 **DO NOT run in parallel** — components must refresh sequentially.
- 🚨 **Identity Resolution MUST complete first** (`lastJobStatus = SUCCESS` verified) before any CI.
- 🚨 **Each CI MUST complete (`lastRunStatus = SUCCESS`) before triggering the next CI.**
- 🚨 **CI refresh order:** Pacemaker Latest Transmission → Pacemaker Patient Health Summary.
- 🚨 **Segment is FIRE-AND-FORGET** — trigger publish and proceed immediately, do NOT wait for completion.

**CRITICAL — Status field names and casing:**
- 🚨 IR uses `lastJobStatus` (camelCase) on `d360_ir_get` response. NOT `LastRunStatus`. NOT `Status`.
- 🚨 CI uses `lastRunStatus` (camelCase) on `d360_ci_run_status` response. NOT `LastRunStatus`. NOT `CalculatedInsightStatus`.
- 🚨 Segment publish is keyed by `marketSegmentId` (starts with `1sg`), captured from `d360_segment_get`'s `result.segments[0].marketSegmentId`. NOT `id`. NOT `apiName`.
- 🚨 ALL status values are UPPERCASE: `IN_PROGRESS`, `PROCESSING`, `PENDING`, `SUCCESS`, `FAILED`, `PUBLISHING`. Compare against UPPERCASE constants exactly.
- 🚨 IR `lastJobCompleted` is a STALE FIELD: it shows the previous run's timestamp while the current run is in progress. Gate ONLY on `lastJobStatus`.

**CRITICAL — Retry policy:**
- ✅ IR: 3 total attempts on `FAILED`, 30 s gap between failure and retry. `Timeout` is NOT auto-retried — surface to user.
- ✅ CI: 3 total attempts per CI on `FAILED`, 30 s gap. If one CI fails after 3 attempts, stop the skill — do NOT skip to the next CI.
- ✅ Segment: 3 total attempts on trigger failure, 30 s gap. Segment failure does NOT halt the skill (IR + CIs already succeeded) — surface the failure in the final report.

**CRITICAL — Segment:**
- ✅ **Fire-and-forget pattern** — trigger publish via `d360_segment_publish` and proceed immediately.
- ❌ **DO NOT poll segment status** — publish runs asynchronously in background.
- ❌ **DO NOT wait for `PUBLISHED` status** — skill completes after trigger succeeds (`publishStatus: PUBLISHING`).
- 🚨 **Use `marketSegmentId` (starts with `1sg`) in `d360_segment_publish`'s `segmentId` parameter.** NOT `apiName`. NOT the null `id` from any list response.

**General rules:**
- NEVER hardcode org names — the data360 MCP server is bound to the target org by `/mcp-setup`, not by any argument to this skill.
- ALWAYS report each component refresh status.
- ALWAYS execute components in sequence (IR → CIs → Segment).
- NEVER skip any component — all three must be refreshed.
- Provide clear error messages with the exact MCP tool + `paramsJson` that failed.
- Estimated total processing time: **20–25 minutes** (IR ~15 min, 2 CIs ~5–8 min total, Segment trigger immediate).

---

## Example Usage

### Example 1: End-to-end happy path

**User:** "Refresh Data Cloud components in MyHealthcareOrg"

**Skill:**
1. `mcp__salesforce-sobject-all__getUserInfo` → confirms target org.
2. `mcp__salesforce-data360__execute { toolName: d360_ir_list, paramsJson: {} }` → find "Unify Patient IOT Data", capture `<IR_ID>`.
3. `mcp__salesforce-data360__execute { toolName: d360_ir_run, paramsJson: {identityResolution: <IR_ID>, input: {...}} }` → trigger.
4. Poll every 60 s via `d360_ir_get` until `lastJobStatus == "SUCCESS"` (max 20 min).
5. `mcp__salesforce-data360__execute { toolName: d360_ci_run, paramsJson: {apiName: "Pacemaker_Latest_Transmission__cio"} }` → trigger CI 1.
6. Poll every 30 s via `d360_ci_run_status` until `lastRunStatus == "SUCCESS"` (max 10 min).
7. `mcp__salesforce-data360__execute { toolName: d360_ci_run, paramsJson: {apiName: "Pacemaker_Patient_Health_Summary__cio"} }` → trigger CI 2.
8. Poll every 30 s via `d360_ci_run_status` until `lastRunStatus == "SUCCESS"` (max 10 min).
9. `mcp__salesforce-data360__execute { toolName: d360_segment_get, paramsJson: {segmentApiName: "Anomalous_Pacemaker_Battery"} }` → capture `<SEGMENT_ID>`.
10. `mcp__salesforce-data360__execute { toolName: d360_segment_publish, paramsJson: {segmentId: <SEGMENT_ID>} }` → fire-and-forget.
11. Report summary with all IDs and job IDs.

### Example 2: Error — component not found

**User:** "Refresh Data Cloud components in TestOrg"

**Skill:** `d360_ir_list` returns no entry with `label == "Unify Patient IOT Data"`.

**Report:**
```text
❌ Identity Resolution Refresh Failed

Org:                 TestOrg
Failed component:    Identity Resolution "Unify Patient IOT Data"
MCP tool:            d360_ir_list
Error:               Not found in org

Possible causes:
• Identity Resolution not created yet
• IR name is different
• Data Cloud not fully provisioned

Suggested fixes:
✅ Navigate to Setup → Data Cloud → Identity Resolutions
✅ Verify "Unify Patient IOT Data" exists
✅ Check IR is active (not draft)
✅ Create IR if missing

Cannot proceed without Identity Resolution. Please create "Unify Patient IOT Data" IR first.
```

---

## Success Criteria

Refresh is successful when:

✅ `salesforce-data360` MCP server is authenticated for the target org (via `/mcp-setup`).
✅ Identity Resolution "Unify Patient IOT Data" triggered via `d360_ir_run` and verified `lastJobStatus = SUCCESS` via `d360_ir_get`.
✅ CI 1/2 Pacemaker Latest Transmission triggered via `d360_ci_run` and verified `lastRunStatus = SUCCESS` via `d360_ci_run_status`.
✅ CI 2/2 Pacemaker Patient Health Summary triggered via `d360_ci_run` and verified `lastRunStatus = SUCCESS` (only after CI 1 SUCCESS).
✅ Segment "Anomalous Pacemaker Battery" `marketSegmentId` captured via `d360_segment_get`.
✅ Segment publish triggered via `d360_segment_publish` (fire-and-forget — `publishStatus = PUBLISHING` or `success = true` or `jobId` present is sufficient; no wait for `PUBLISHED`).
✅ All MCP calls returned without an error field populated.
✅ NO `curl`, NO `sf` CLI, NO SOQL, NO Tooling API used at any step.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"refresh-data-cloud-components"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.refresh-data-cloud-components` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
