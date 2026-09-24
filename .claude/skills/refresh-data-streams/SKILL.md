---
name: refresh-data-streams
description: "Refresh Data Cloud Data Streams (mix of core CRM objects + Health Cloud clinical objects, all transported via the SalesforceDotCom connector) using the scripts/refresh-datastreams.sh shell script (fires refreshes via the same undocumented Aura endpoint the UI 'Refresh Now' button uses — no browser, no Playwright) and polls status via the salesforce-data360 MCP server (d360_datastream_get). Refreshes 17 streams sequentially — 10 core CRM (Account_Home, Contact_Home, Case_Home, Product2_Home, Pricebook2_Home, PricebookEntry_Home, Asset_Home, Task_Home, Entitlement_Home, ServiceAppointment_Home) + 7 Health Cloud (AllergyIntolerance_Home, CodeSet_Home, CodeSetBundle_Home, Medication_Home, PatientMedicalProcedure_Home, HealthCondition_Home, MedicationRequest_Home). NEVER refreshes the file-based pacemaker_iot_data stream (that lives in /datastream-file-upload). Use when user wants to refresh data streams, update data streams, or sync Salesforce-object-backed data streams."
---

# refresh-data-streams

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"refresh-data-streams"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: refresh-data-streams already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Refresh Data Cloud CRM Connector Data Streams end-to-end, using:

1. **`scripts/refresh-datastreams.sh`** — a headless shell script that fires the refresh trigger via the same undocumented `/aura` endpoint the UI's "Refresh Now" button hits (descriptor `serviceComponent://ui.cdp.components.controllers.datastreams.DataStreamDeploymentController/ACTION$processDataStream`).
2. **`salesforce-data360` MCP server (`d360_datastream_get`)** — polls each stream's post-refresh status.

**❌ NO Playwright, NO browser automation, NO SOQL, NO `curl` from the skill itself.** The skill just orchestrates two things: the shell script that fires refreshes, and the data360 MCP that polls status.

**Why the shell script instead of a pure MCP call:**

The public data360 `d360_datastream_run` tool refuses to refresh streams that use the SalesforceDotCom connector (which is ALL 17 streams in scope here — both the core CRM and Health Cloud ones, since Health Cloud objects flow through the same Salesforce connector):
- Non-interactive mode → `Connector type SalesforceDotCom is not allowed to run in non-interactive mode`.
- Interactive mode → `not allowed in interactive mode if refresh mode is not FULL_REFRESH`.

The UI's "Refresh Now" button hits a *different* internal `/aura` endpoint that accepts these mutations regardless of connector type or refresh mode. `scripts/refresh-datastreams.sh` wraps that same call directly, so we get the same behaviour headlessly — no Playwright, no browser, no session-cookie brittleness. Descriptor + params discovered by capturing the network request when clicking "Refresh Now" → "Full Refresh" in the DataStream detail page on **2026-07-15**.

**Why data360 MCP for polling:**

Once refresh is triggered, `d360_datastream_get` returns each stream's `lastRunStatus` (`PENDING → RUNNING → SUCCESS/FAILED`) — no SOQL, no Tooling API, no `sf data query`. Same channel used by `/refresh-data-cloud-components`. Every read after the trigger goes through `mcp__salesforce-data360__execute`. Polling logic is uniform across all 17 streams — Data Cloud does not distinguish between "core CRM" and "Health Cloud" for `lastRunStatus`.

**🚨 CRITICAL: Which Data Streams to Refresh**

All 17 streams use the **Salesforce CRM (SalesforceDotCom) connector** as their transport (verified via `d360_datastream_list`: `connectorType: SalesforceDotCom`, `connectorDetails.name: SalesforceDotCom_Home`). But the underlying source objects are a mix — **10 core CRM objects + 7 Health Cloud clinical objects**. Refreshing them is a single homogenous operation from Data Cloud's perspective; the split below is to be transparent about what's actually flowing.

**✅ REFRESH THESE (17 SalesforceDotCom-transported Data Streams):**

**Core CRM object streams (10):**
1. `Account_Home` — Account
2. `Contact_Home` — Contact
3. `Case_Home` — Case
4. `Product2_Home` — Product2
5. `Pricebook2_Home` — Pricebook2
6. `PricebookEntry_Home` — PricebookEntry
7. `Asset_Home` — Asset
8. `Task_Home` — Task
9. `Entitlement_Home` — Entitlement
10. `ServiceAppointment_Home` — ServiceAppointment

**Health Cloud clinical object streams (7):**
11. `AllergyIntolerance_Home` — AllergyIntolerance (HL7 FHIR-aligned)
12. `CodeSet_Home` — CodeSet (clinical coding — SNOMED / ICD / RxNorm)
13. `CodeSetBundle_Home` — CodeSetBundle (versioned collection of CodeSets)
14. `Medication_Home` — Medication
15. `PatientMedicalProcedure_Home` — PatientMedicalProcedure
16. `HealthCondition_Home` — HealthCondition (patient diagnoses)
17. `MedicationRequest_Home` — MedicationRequest (prescription records)

**❌ NEVER REFRESH THESE (handled elsewhere or not applicable):**
- `pacemaker_iot_data` — File Upload connector, handled by `/datastream-file-upload`
- Any other file-based stream (Customer Engagement Feed, POS Customer, Website Customer, Customer Affinities, etc.) if they exist

Streams backed by Salesforce objects (whether core CRM or Health Cloud) need the "Refresh Now" trigger to re-ingest deltas. File-based streams are updated when files are uploaded — refreshing them here is a no-op at best, harmful at worst.

**Constraints:**
- ✅ Skill uses `scripts/refresh-datastreams.sh` (bash) + `mcp__salesforce-data360__execute` only.
- ❌ NO Playwright / `mcp__plugin_playwright_playwright__*` tools.
- ❌ NO `sf data query` / SOQL / Tooling API from the skill.
- ✅ The shell script itself makes an Aura POST to `/aura?...processDataStream=1` — that is an undocumented internal endpoint, not a public API. Salesforce may break it on future releases. This is an accepted risk; the public `d360_datastream_run` cannot refresh CRM Connector streams.
- ✅ Refreshes fire **serially** inside the shell script (one at a time, in the exact order passed to the script).

**Temp file policy:**
- The shell script writes its own scratch files under `~/.datastream_refresh_work/` — they are cleaned at the top of every script invocation. The skill itself creates no temp files.

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username. Passed through to `scripts/refresh-datastreams.sh` for the `sf org display` credential fetch. The data360 MCP server is bound to whatever org `/mcp-setup` was run against — the `org_alias` argument does not switch the MCP target.

---

## Preconditions

Before running:

- `bash`, `python`, and `sf` CLI must be on PATH (Git-Bash on Windows is fine — the shell script uses `cygpath` for path translation).
- Salesforce CLI must be authenticated for `<org_alias>` (`sf org login web -a <org_alias>`). The shell script re-fetches the token via `sf org display` internally.
- `/mcp-setup` has been run against `<org_alias>` so the `salesforce-data360` MCP server is authenticated. Without it, every `d360_datastream_get` call returns `invalid_grant`.
- Data Cloud enabled + provisioned in the target org.
- The 17 Data Streams listed above (10 core CRM + 7 Health Cloud) must exist and be active in the target org.
- User must have "Manage Data Cloud" permission (needed by the Aura endpoint).

---

## Workflow

### Step 0 — Verify prerequisites

Sanity-check the local environment (fail early rather than mid-way through the run):

```bash
which sf         || { echo "❌ 'sf' CLI missing"; exit 1; }
which python     || { echo "❌ 'python' missing"; exit 1; }
which bash       || { echo "❌ 'bash' missing"; exit 1; }
test -f scripts/refresh-datastreams.sh || { echo "❌ scripts/refresh-datastreams.sh missing"; exit 1; }
test -x scripts/refresh-datastreams.sh || chmod +x scripts/refresh-datastreams.sh
```

Confirm the org alias is authenticated (informational — the script will re-run this internally):

```bash
sf org display -o <org_alias> --json | python -c "import json,sys; d=json.load(sys.stdin); print('OK:', d['result']['username'])"
```

If any of the above fails, stop the skill and surface the missing item.

---

### Step 1 — Confirm target org via data360 MCP (optional but recommended)

Confirm the `salesforce-data360` MCP is authenticated for the same org the shell script will hit. Any cheap read works — `d360_datastream_list` with `limit: 1` is fastest and does not depend on any named stream existing:

```
mcp__salesforce-data360__execute
  toolName: d360_datastream_list
  paramsJson: {"limit": 1}
```

If this returns `invalid_grant` / `request not supported on this domain`, the data360 MCP is authenticated for a different org (or not at all). Stop and instruct the user to re-run `/mcp-setup` against `<org_alias>` before continuing.

---

### Step 2 — Fire all 17 refreshes in one shell script call

The shell script accepts an org alias plus an ordered list of stream names, fires each refresh serially via `/aura`, and prints per-stream status (`SUCCESS` / `IDEMPOTENT` / `ERROR`) to stdout.

**One invocation for all 17 streams:**

```bash
bash scripts/refresh-datastreams.sh <org_alias> \
  Account_Home Contact_Home Case_Home Product2_Home Pricebook2_Home \
  PricebookEntry_Home Asset_Home Task_Home Entitlement_Home ServiceAppointment_Home \
  AllergyIntolerance_Home CodeSet_Home CodeSetBundle_Home Medication_Home \
  PatientMedicalProcedure_Home HealthCondition_Home MedicationRequest_Home
```

**What the script does internally (documented for transparency — the skill just runs the script):**

1. `sf org display` → grabs `accessToken` + `instanceUrl` for `<org_alias>`.
2. `frontdoor.jsp?sid=<token>` → establishes an authenticated browser-equivalent cookie jar (Lightning session).
3. REST GET `/services/data/v66.0/query?q=SELECT+Id,Name+FROM+DataStream+WHERE+Name+IN+(...)` → resolves the 17 stream names to record IDs. (This is inside the script — the skill itself doesn't run SOQL.)
4. For each stream:
   - GET `/lightning/r/DataStream/<id>/view` → refreshes the `__Host-ERIC_PROD-*` cookie carrying `aura.token`, and extracts `fwuid` + `APPLICATION@markup://one:one` from the page.
   - POST `/aura?...processDataStream=1` with descriptor `DataStreamDeploymentController/ACTION$processDataStream`, params `{recordId, processAllFiles: true}` → this is the exact call the UI's "Refresh Now" → "Full Refresh" button makes.
   - Parses the response's `actions[0].state`:
     - `SUCCESS` → refresh triggered.
     - `IDEMPOTENT` → an existing refresh is already running for this stream; treated as success.
     - Anything else → per-stream failure, exit non-zero at the end.

**Interpret the script's stdout:**

Expected per-stream line:

```
  [<Stream_Name>] (<recordId>) HTTP=200  aura_state=SUCCESS
```

Terminal footer on success (skill continues to Step 3):

```
== ✅ All 17 data stream(s) refresh triggered successfully ==
   Use mcp__salesforce-data360__execute (toolName=d360_datastream_get) to poll
   lastRunStatus per stream. Values: PENDING → RUNNING → SUCCESS (or FAILED).
```

Terminal footer on failure (skill hands to Step 4 — retry logic):

```
== ⚠️  One or more streams failed — see output above ==
```

**If the shell script exits non-zero:**

Do NOT proceed to Step 3 yet. Skip to Step 4 (retry) — the script will need to be re-run for the failing streams only. Do NOT re-run all 17 (successful triggers are already in flight).

---

### Step 3 — Poll each stream's `lastRunStatus` via `d360_datastream_get`

Once the shell script reports all triggers accepted, poll each stream's status via the data360 MCP. The trigger is asynchronous — Salesforce needs **10–15 minutes per stream** to actually process the data (verified on this org 2026-07-17).

**Poll cadence:** 5 minutes between rounds, max 4 rounds (20 minutes total). Each round iterates through all 17 streams once.

> **Why 5 min and not 30 s:** empirically Data Cloud data-stream refreshes take 10–15 min per stream to move from `PENDING → RUNNING → SUCCESS` on a healthy org. Polling every 30 seconds burns MCP calls without changing the outcome — all 17 streams stay `PENDING` for the first ~5–10 min. The 5-min cadence gives 4 status checks over a 20-min window, which is enough to catch the state changes without wasted calls.

**Per stream, per round:**

```
mcp__salesforce-data360__execute
  toolName: d360_datastream_get
  paramsJson: {"recordIdOrDeveloperName": "<stream_name>"}
```

Read `result.lastRunStatus` (UPPERCASE — `PENDING`, `RUNNING`, `SUCCESS`, `FAILED`). Classify each stream:

| `lastRunStatus` | Meaning | Action |
|---|---|---|
| `SUCCESS` | Stream refreshed and processed | Mark as done. |
| `PENDING` / `RUNNING` | Still processing | Keep polling. |
| `FAILED` | Refresh terminated with error | Add to retry list. |
| Anything else | Unexpected state | Log verbatim, keep polling one more round, then treat as `FAILED`. |

**Round loop pseudocode:**

```
done       = set()          # streams that reached SUCCESS
failed     = set()          # streams that reached FAILED
target     = set(all 17 stream names)

for round in 1..4:
    for stream in sorted(target - done - failed):
        r = d360_datastream_get({"recordIdOrDeveloperName": stream})
        status = r.result.lastRunStatus
        log(f"Round {round}/4 (minute {round*5}) — {stream}: lastRunStatus={status}")
        if status == "SUCCESS":
            done.add(stream)
        elif status == "FAILED":
            failed.add(stream)

    if done == target:
        break   # all 17 SUCCESS → proceed to Step 5

    if (done | failed) == target:
        break   # every stream is terminal (some SUCCESS, some FAILED) → hand to Step 4 for retry

    # Otherwise some streams are still PENDING/RUNNING — wait 5 minutes
    sleep(300)
```

**Sleep between rounds:** use a foreground `Bash({command: "sleep 300"})` call. Not backgrounded — the sub-agent stays alive by re-issuing the MCP call each round. 300s (5 min) is well under Bash's 10-min hard cap.

> **Why 5 min and not 30 s** (verified 2026-07-17 on the target org): Data Cloud data-stream refreshes stay in `PENDING` for ~5–10 min before flipping to `RUNNING`/`SUCCESS`. Polling every 30 seconds just burns MCP calls without changing the outcome. The 5-min cadence hits reality once per real state change; 4 polls covers a 20-min window per attempt.

**Timeout (4 rounds exhausted, still some streams non-terminal):**

Report the still-non-terminal streams to the user and continue with any that DID finish. Do NOT auto-retry on timeout — surface it:

```text
⏱️  Some streams still not terminal after 20 minutes:

Still processing:
- <stream_name>: <lastRunStatus>
- ...

Successful:
- <count> / 17 reached SUCCESS

Failed:
- <count> / 17 reached FAILED

Do NOT auto-retry on timeout. Ask the user whether to keep polling (extend by another 10–20 min)
or stop here. Data Cloud stream refreshes on a busy org can occasionally exceed 20 min.
```

---

### Step 4 — Retry FAILED streams (max 2 additional attempts per stream)

**When Step 3 collects one or more streams in `failed`, and `attempts_used[stream] < 3`, re-fire them via the shell script — one script call, only the failed streams passed.**

Retry policy — fixed:

- **3 total attempts per stream** (1 initial from Step 2 + up to 2 retries).
- Wait 30 seconds between the previous round's failure detection and the retry `bash` call.
- Retries apply per stream — a stream that succeeds after retry does NOT block the others.
- After all 3 attempts fail for a given stream, stop retrying THAT stream (report failure). Continue with any streams still succeeding.
- Timeout (Step 3's 20-min ceiling) is NOT auto-retried — surface to user.

Pseudocode:

```
attempts_used = {stream: 1 for stream in target}   # after Step 2 each stream has 1 attempt

while failed and any(attempts_used[s] < 3 for s in failed):
    retryable = [s for s in failed if attempts_used[s] < 3]
    log(f"🔁 Retrying {len(retryable)} failed stream(s): {retryable}")
    sleep(30)

    # One shell script invocation for just the failed streams
    bash("scripts/refresh-datastreams.sh <org_alias> " + " ".join(retryable))

    for s in retryable:
        attempts_used[s] += 1

    # Move retried streams back to PENDING and re-run Step 3 polling for them only
    failed -= set(retryable)
    # ... (re-poll via d360_datastream_get for just `retryable`, same 30s cadence
    #      and 15-min ceiling, updating `done` and `failed` per the Step 3 loop)

# When the while loop exits, every stream is either in `done`, in `failed`
# with attempts_used[s] == 3, or timed out.
```

**Reporting per stream:**

- ✅ First-try success → `<stream>: attempt 1/3: SUCCESS`
- 🔁 Recovered → `<stream>: 1/3 FAILED → 2/3 SUCCESS` (or `→ 3/3 SUCCESS`)
- ❌ All 3 failed → `<stream>: attempts 1, 2, 3 all FAILED. Not retrying.`

**If ANY stream ends in `failed` after 3 attempts:**

Report the failing streams but do NOT halt the skill — surface the failure in the final report. The remaining streams that succeeded are still useful. This is a soft failure, unlike IR / CI failures which downstream skills depend on. The next installer step (`/copy-field-sync`) does NOT depend on all streams being SUCCESS.

---

### Step 5 — Final report

Generate the report after Step 3 (all streams terminal) and Step 4 (retries exhausted or all recovered).

```text
✅ Data Streams refresh complete!

Org (alias):     <org_alias>
Channel:         scripts/refresh-datastreams.sh (Aura trigger)
                 + salesforce-data360 MCP (d360_datastream_get status poll)

═══════════════════════════════════════════════════

📊 Per-stream results (17 SalesforceDotCom-transported Data Streams — 10 core CRM + 7 Health Cloud):

 1. ✅ Account_Home                    — lastRunStatus: SUCCESS  (attempt 1/3)
 2. ✅ Contact_Home                    — lastRunStatus: SUCCESS  (attempt 1/3)
 3. ✅ Case_Home                       — lastRunStatus: SUCCESS  (attempt 1/3)
 4. ✅ Product2_Home                   — lastRunStatus: SUCCESS  (attempt 1/3)
 5. ✅ Pricebook2_Home                 — lastRunStatus: SUCCESS  (attempt 1/3)
 6. ✅ PricebookEntry_Home             — lastRunStatus: SUCCESS  (attempt 1/3)
 7. ✅ Asset_Home                      — lastRunStatus: SUCCESS  (attempt 2/3, recovered)
 8. ✅ Task_Home                       — lastRunStatus: SUCCESS  (attempt 1/3)
 9. ✅ Entitlement_Home                — lastRunStatus: SUCCESS  (attempt 1/3)
10. ✅ ServiceAppointment_Home         — lastRunStatus: SUCCESS  (attempt 1/3)
11. ✅ AllergyIntolerance_Home         — lastRunStatus: SUCCESS  (attempt 1/3)
12. ✅ CodeSet_Home                    — lastRunStatus: SUCCESS  (attempt 1/3)
13. ✅ CodeSetBundle_Home              — lastRunStatus: SUCCESS  (attempt 1/3)
14. ✅ Medication_Home                 — lastRunStatus: SUCCESS  (attempt 1/3)
15. ✅ PatientMedicalProcedure_Home    — lastRunStatus: SUCCESS  (attempt 1/3)
16. ✅ HealthCondition_Home            — lastRunStatus: SUCCESS  (attempt 1/3)
17. ✅ MedicationRequest_Home          — lastRunStatus: SUCCESS  (attempt 1/3)

═══════════════════════════════════════════════════

⏱️  Total time (trigger + polling): <actual> minutes

Retry summary:
- <n> streams succeeded on first attempt
- <n> streams recovered after retry
- <n> streams failed after 3 attempts (see per-stream results above)

Next step: this is the OPTIONAL final skill in Mode 2 — installation complete.
```

If any streams failed after 3 attempts, mark them explicitly with ❌ and include the last error message from the shell script + last `lastRunStatus` from the MCP poll. Do NOT halt the installer chain on soft failure.

---

### Step 6 — Error handling

Common errors and their fixes:

| Error | Where | Fix |
|---|---|---|
| `sf org display failed for alias '<alias>' (empty output)` | Shell script | `sf org login web -a <alias>` |
| `Could not find DataStream(s) by Name: <names>` | Shell script (Step 2 SOQL) | Verify the stream exists and is active in the target org; `ps-datacloud` must have deployed cleanly |
| `[<stream>] (<id>) FAIL: missing FWUID/APP_LOADED/AURA_TOKEN` | Shell script | `frontdoor.jsp` didn't establish the Lightning session — re-authenticate with `sf org login web -a <alias>` |
| `[<stream>] (<id>) HTTP=200 aura_state=ERROR:...` | Shell script | Read the error message — usually "not allowed", "not published", or a validation on the source object. Fix upstream and re-run. |
| `invalid_grant` / `request not supported on this domain` on `d360_datastream_get` | data360 MCP | data360 MCP not authenticated for this org — re-run `/mcp-setup` |
| 401 UNAUTHORIZED on `d360_datastream_get` | data360 MCP | Token expired — re-run `/mcp-setup` |
| 403 FORBIDDEN on `d360_datastream_get` | data360 MCP | Assign "Data Cloud Admin" permission set to the run-as user |
| Timeout on Step 3 (still PENDING/RUNNING at 20 min) | Skill polling | Surface to user; ask whether to keep polling or stop |

---

## Important Rules

**CRITICAL — Execution channel:**
- 🚨 **Trigger uses `scripts/refresh-datastreams.sh` ONLY.** NOT Playwright, NOT `d360_datastream_run` (which refuses CRM Connector streams), NOT SOQL DML.
- 🚨 **Status polling uses `mcp__salesforce-data360__execute` → `d360_datastream_get` ONLY.** NOT `sf data query`, NOT SOQL, NOT Playwright snapshots.
- 🚨 The `salesforce-data360` MCP server must be authenticated for the target org via `/mcp-setup` before this skill runs — otherwise Step 3 fails immediately.

**CRITICAL — Which streams:**
- 🚨 **ONLY refresh the 17 streams** listed above — 10 core CRM object streams + 7 Health Cloud clinical object streams. All share `connectorType: SalesforceDotCom`.
- 🚨 **NEVER refresh** `pacemaker_iot_data` (that's `/datastream-file-upload`'s job — different connector: `UploadedFiles`).
- 🚨 **NEVER refresh** any other file-based stream (Customer Engagement Feed, POS Customer, Website Customer, Customer Affinities) if they exist in the org.

**CRITICAL — Retry policy:**
- ✅ Failed streams get up to 2 retries (3 total attempts).
- ✅ 30 s gap between failure detection and retry.
- ✅ Retries fire via a fresh `bash scripts/refresh-datastreams.sh <org> <only failed>` call — never rerun successful streams.
- ❌ Do NOT auto-retry on `Step 3` timeout (streams stuck in `PENDING`/`RUNNING` at 15-min ceiling). Surface to user.

**CRITICAL — Serial ordering:**
- ✅ The shell script fires refreshes serially inside its `for` loop — do not spawn concurrent invocations for the same org.
- ✅ Never call the shell script twice in parallel — the second call may fight over the cookie jar in `~/.datastream_refresh_work/`.

**CRITICAL — Undocumented endpoint:**
- ⚠️  The `/aura?...processDataStream=1` POST inside the shell script is an undocumented internal Salesforce endpoint. It is the same call the UI's "Refresh Now" → "Full Refresh" button makes. It may break on future Salesforce releases. The public `d360_datastream_run` cannot refresh CRM Connector streams (documented failure modes above), so this is the only headless path currently available. Accepted risk.

**General rules:**
- NEVER hardcode org names — always pass `<org_alias>` through to the shell script.
- ALWAYS confirm the shell script exists at `scripts/refresh-datastreams.sh` before invoking (Step 0).
- ALWAYS proceed to Step 3 polling only after Step 2's shell script prints its success footer.
- Estimated total time: **15–20 minutes** (17 triggers ≈ 30s + polling at 5-min cadence, 4 rounds max = 20-min ceiling). Verified on 2026-07-17: all 17 streams stayed in `PENDING` for ~5–10 min before flipping to `RUNNING`/`SUCCESS`.

---

## Data Streams to Refresh

All 17 streams share the same connector transport: `connectorType = SalesforceDotCom`, `connectorDetails.name = SalesforceDotCom_Home`. The categorization below is by source-object type (core CRM vs. Health Cloud clinical) — Data Cloud itself treats them uniformly for refresh purposes.

**Core CRM object streams (10):**

| # | Data Stream Name | Salesforce source object |
|---|---|---|
| 1 | Account_Home | Account |
| 2 | Contact_Home | Contact |
| 3 | Case_Home | Case |
| 4 | Product2_Home | Product2 |
| 5 | Pricebook2_Home | Pricebook2 |
| 6 | PricebookEntry_Home | PricebookEntry |
| 7 | Asset_Home | Asset |
| 8 | Task_Home | Task |
| 9 | Entitlement_Home | Entitlement |
| 10 | ServiceAppointment_Home | ServiceAppointment |

**Health Cloud clinical object streams (7):**

| # | Data Stream Name | Health Cloud source object |
|---|---|---|
| 11 | AllergyIntolerance_Home | AllergyIntolerance |
| 12 | CodeSet_Home | CodeSet |
| 13 | CodeSetBundle_Home | CodeSetBundle |
| 14 | Medication_Home | Medication |
| 15 | PatientMedicalProcedure_Home | PatientMedicalProcedure |
| 16 | HealthCondition_Home | HealthCondition |
| 17 | MedicationRequest_Home | MedicationRequest |

---

## Example Usage

### Example 1: Happy path

**User:** "Refresh Data Streams in MyHealthcareOrg"

**Skill:**
1. Step 0: `which sf`, `which python`, `which bash`, `test -f scripts/refresh-datastreams.sh` → all pass.
2. Step 1: `mcp__salesforce-data360__execute { toolName: d360_datastream_list, paramsJson: {"limit": 1} }` → returns 200 OK. Data360 MCP is authenticated.
3. Step 2: `bash scripts/refresh-datastreams.sh MyHealthcareOrg Account_Home Contact_Home ... MedicationRequest_Home` → all 17 print `aura_state=SUCCESS` and the footer says `✅ All 17 data stream(s) refresh triggered successfully`.
4. Step 3: loop over 17 streams, poll `d360_datastream_get` per stream every 5 min (up to 4 rounds = 20-min window). All 17 typically reach `lastRunStatus=SUCCESS` within 15–20 min.
5. Step 5: final report with 17 green checkmarks.

### Example 2: Two streams fail on first attempt

**User:** "Refresh Data Streams in MyHealthcareOrg"

**Skill:**
1. Steps 0–2 as above.
2. Step 3: 15 streams reach `SUCCESS`, `Asset_Home` and `Entitlement_Home` reach `FAILED`.
3. Step 4: sleeps 30 s, re-runs `bash scripts/refresh-datastreams.sh MyHealthcareOrg Asset_Home Entitlement_Home`. Both print `aura_state=SUCCESS`.
4. Step 3 (re-poll for the 2 retried streams): poll at 5-min cadence; both reach `SUCCESS` within ~10 min.
5. Step 5: final report shows `Asset_Home` and `Entitlement_Home` as `attempt 2/3, recovered`; the other 15 as `attempt 1/3`.

### Example 3: Data360 MCP not authenticated for this org

**User:** "Refresh Data Streams in NewOrg"

**Skill:**
- Step 1: `d360_datastream_list` returns `invalid_grant / request not supported on this domain`.

**Report:**
```text
❌ salesforce-data360 MCP is not authenticated for NewOrg.

The trigger step could still run (via scripts/refresh-datastreams.sh),
but Step 3 status polling would fail. Stopping here to prevent partial run.

Fix: re-run /mcp-setup against NewOrg, then re-run /refresh-data-streams NewOrg.
```

---

## Success Criteria

Refresh is successful when:

✅ Step 0 preconditions pass (bash, python, sf, script present).
✅ Step 1 confirms `salesforce-data360` MCP is authenticated for the target org.
✅ Step 2's `scripts/refresh-datastreams.sh` exits 0 with `✅ All 17 data stream(s) refresh triggered successfully`.
✅ Step 3 polling reaches `lastRunStatus = SUCCESS` for all 17 streams (or fewer if some fail after 3 attempts — soft failure).
✅ Step 5 final report generated with per-stream status.
✅ **No Playwright, no browser, no `sf data query`, no SOQL, no `curl` from the skill itself.**

---

## Cleanup temp artifacts

The shell script self-cleans on invocation (`rm -f "$WORK"/*` at the top of each run — see `refresh-datastreams.sh` line 46). The skill itself creates no temp files.

Nothing to delete from the skill side.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"refresh-data-streams"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.refresh-data-streams` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
