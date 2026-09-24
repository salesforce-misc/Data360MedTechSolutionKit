---
name: agentforce-data-library
description: "Create single or multiple Agentforce Data Libraries (ADL) with PDF file uploads via the salesforce-headless-360 MCP server. Handles library creation, AWS S3 file upload via presigned URL, and indexing. Supports batch creation. Uses the Einstein Connect API (/einstein/data-libraries) through MCP dispatch — NOT curl, NOT sf apex. Use when user wants to create data libraries for Agentforce grounding with documents."
---

# agentforce-data-library

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"agentforce-data-library"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: agentforce-data-library already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Create one or multiple Agentforce Data Libraries (ADL) with file upload capability using the **`salesforce-headless-360` MCP server** to invoke Salesforce Einstein Connect API endpoints.

This skill automates the complete workflow for creating data libraries, uploading PDF files to Salesforce's AWS S3 storage, and starting the indexing process for Agentforce grounding — driven entirely through MCP `dispatch` / `dispatch_readonly` tool calls. The only curl invocation is the S3 PUT for the PDF payload itself, because S3 is an external service that MCP does not proxy.

**Key Features:**
- MCP-first: all Salesforce API calls go through `mcp__salesforce-headless-360__dispatch` and `mcp__salesforce-headless-360__dispatch_readonly`. **No `curl` against Salesforce endpoints. No `sf apex run`. No Bash-shelled auth token extraction.**
- Supports creating **single or multiple libraries** in one execution
- Uses correct Einstein API endpoint: `/services/data/v67.0/einstein/data-libraries`
- Uploads files to Salesforce's managed AWS S3 infrastructure (curl PUT — the only shell-out)
- Polls upload readiness with a bounded budget
- Monitors indexing progress through the 4 stages (`DATA_LAKE_OBJECT`, `DATA_MODEL_OBJECT`, `SEARCH_INDEX`, `RETRIEVER`)
- Returns library IDs for downstream agent / retriever configuration
- Processes libraries sequentially (never in parallel — same-org async pipeline can throttle otherwise)

Prerequisites:
- The `salesforce-headless-360` MCP server is registered and authenticated for the target org (verify with `claude mcp list`). If it is not, tell the user to run `/mcp-setup` first — this skill does NOT authenticate.
- Target org must have Agentforce Data Library feature enabled (visible at Setup → Agentforce Data Library)
- PDF files must exist at specified paths on the local filesystem
- User must have "Manage Einstein Features" or equivalent permission

---

## Why MCP instead of curl

The prior version of this skill authenticated via `sf org display --json`, extracted the access token, and shelled out to `curl` for every API call. That works but has three drawbacks:

1. **Token expiry mid-run**: session tokens expire after ~2 h; long polling loops had to re-run `sf org display` and thread the new token through Bash variables.
2. **Instance URL plumbing**: the skill had to resolve `instanceUrl` per run and interpolate it into every URL.
3. **No API discovery**: endpoint paths were hard-coded in the skill markdown; if Salesforce moved an endpoint or added a new one, the skill silently rotted.

The `salesforce-headless-360` MCP server solves all three:

- OAuth tokens are held server-side and refreshed transparently.
- The instance URL is resolved from the MCP session — the skill only supplies the API path (`/services/data/v67.0/...`).
- `discover` and `describe` provide runtime access to the OAS spec + Setup Operation Recipes; the ADL SOR (`ai-data-library-connect-api-genai.unified.setup.connect.api-oas-67.0`) documents all 17 endpoints and their exact payload shapes.

**The Salesforce Connect API calls are identical** — the same `/services/data/v67.0/einstein/data-libraries` endpoints, the same JSON bodies. Only the transport changes: `mcp__salesforce-headless-360__dispatch` in place of `curl`.

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username. Used only for reporting and for the `sf org display --target-org` diagnostic on Step 0. **The org alias is NOT threaded into any API call** — the MCP server resolves instance/auth from its own registered session.
- `mode` (optional): Execution mode - "healthcare" or  "custom" (default: "healthcare")
- `libraries` (optional): JSON array of library configurations (only used when mode="custom")

**Mode Options:**

**1. Healthcare Kit Mode (default):**
- Automatically creates all 3 libraries required for Data360 MedTech Solution Kit
- No additional parameters needed
- Libraries created:
  1. Pacemaker Implant Guide (Pacemaker Patient Guide.pdf)
  2. Patient Clinician Discharge And Interrogation Note (ClinicianNote_DischargeSummary.pdf)
  3. Patient OP (Mark_Smith_OP_Note.pdf)

**2. Custom Mode:**
- Requires `mode="custom"` parameter
- Requires `libraries` JSON array with custom library configurations

**Example Custom Libraries JSON:**
```json
[
  {
    "masterLabel": "My Custom Library",
    "developerName": "MyCustomLibrary",
    "description": "Custom library description",
    "pdfFile": "path/to/file.pdf"
  }
]
```

**Common Use Cases:**

1. **Healthcare Kit (default):** `/agentforce-data-library <org_alias>`
2. **Custom libraries:** `/agentforce-data-library <org_alias> --mode custom --libraries '[{...}]'`

---

## Preconditions

Before running:

- `salesforce-headless-360` MCP server registered + authenticated for the target org
- Target org must have Agentforce Data Library feature enabled
- Verify feature availability: Setup → Quick Find → "Agentforce Data Library" (page must exist)
- PDF file must exist at specified path
- User must have "Manage Einstein Features" or equivalent permission
- **IMPORTANT:** For uninterrupted execution, the MCP tools and Bash S3 upload should be pre-approved in `~/.claude/settings.json` (global) or `.claude/settings.json` (project):
  ```json
  {
    "permissions": {
      "allow": [
        "mcp__salesforce-headless-360__*",
        "Bash(curl -X PUT *)",
        "Bash(stat -c%s *)",
        "Bash(wc -c *)"
      ]
    }
  }
  ```

---

## MCP tool preamble (run once at the start of the skill)

Before making any MCP calls, load the four required tool schemas via `ToolSearch` so they become callable:

```
ToolSearch("select:mcp__salesforce-headless-360__dispatch,mcp__salesforce-headless-360__dispatch_readonly,mcp__salesforce-headless-360__discover,mcp__salesforce-headless-360__describe")
```

`discover` and `describe` are optional at runtime (paths are hard-coded below) but are useful if a Salesforce API version bump changes any endpoint shape — a single `discover("Einstein data libraries")` call re-verifies the current SOR.

---

## Workflow

**CRITICAL: Mode Detection**

### Step 0 — Verify MCP session (NO login here)

The `salesforce-headless-360` MCP server is expected to be pre-registered and authenticated for the target org. This skill does NOT authenticate.

Diagnostic: list a benign endpoint via MCP:

```
mcp__salesforce-headless-360__dispatch_readonly(url="/services/data/v67.0/limits", method="GET")
```

- HTTP 200 with a `limits` payload → session valid, proceed to Step 0A.
- HTTP 401 / "invalid_grant" / server-error → **STOP**. Report: `"salesforce-headless-360 MCP session invalid for <org_alias>. Run /mcp-setup before invoking agentforce-data-library."` Do not attempt any workaround.

### Step 0A — Check if libraries already exist

Before creating libraries, list what's in the org:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v67.0/einstein/data-libraries",
  method="GET"
)
```

**Expected response:**
```json
{
  "libraries": [
    {
      "libraryId": "1JDxx000000ABCD123",
      "masterLabel": "Pacemaker Implant Guide",
      "developerName": "PacemakerImplantGuide",
      "status": "IN_PROGRESS",
      "groundingSource": {
        "groundingFileRefs": [...]
      }
    }
  ],
  "totalSize": 3
}
```

**Check for each library in Healthcare Kit mode:**
- Pacemaker Implant Guide (developerName: `PacemakerImplantGuide`)
- Patient Clinician Discharge And Interrogation Note (developerName: `PatientClinicianDischargeAndInterrogationNote`)
- Patient OP (developerName: `PatientOP`)

**If library already exists:**
1. Skip creation (Step 3) — reuse the returned `libraryId`.
2. Skip upload readiness check (Step 4) — safe to assume ready if the library is already there.
3. Check `groundingSource.groundingFileRefs`. If **empty** → proceed with Steps 5–8 (upload the file).
4. If `groundingFileRefs` contains the target filename → report `library already complete`, skip to the next library.

### Step 0B — Determine execution mode

1. If `mode` parameter NOT provided or `mode="healthcare"`:
   - **Use Healthcare Kit Mode**
   - Automatically create 3 libraries:
     ```
     libraries = [
       {
         "masterLabel": "Pacemaker Implant Guide",
         "developerName": "PacemakerImplantGuide",
         "description": "Pacemaker implant patient guide for Agentforce grounding",
         "pdfFile": "MedTechDocuments/Pacemaker Patient Guide.pdf"
       },
       {
         "masterLabel": "Patient Clinician Discharge And Interrogation Note",
         "developerName": "PatientClinicianDischargeAndInterrogationNote",
         "description": "Clinician discharge summary and interrogation notes for Agentforce grounding",
         "pdfFile": "MedTechDocuments/ClinicianNote_DischargeSummary.pdf"
       },
       {
         "masterLabel": "Patient OP",
         "developerName": "PatientOP",
         "description": "Patient OP note for Agentforce grounding",
         "pdfFile": "MedTechDocuments/Mark_Smith_OP_Note.pdf"
       }
     ]
     ```

2. If `mode="custom"`:
   - **Use Custom Mode**
   - Require `libraries` parameter
   - If `libraries` not provided, error and stop

**CRITICAL: Multiple Library Processing**

For both Healthcare Kit and Custom modes:
- Process each library **sequentially** (NOT in parallel — the Data Lake Object provisioning is per-library and creating three at once causes back-end throttling)
- Track success/failure for each library
- On any library's terminal failure, continue with the remaining libraries (best-effort per-library — the run's overall exit code is set at Step 9.5)
- Report combined summary at end

---

### Step 1 — Verify PDF exists (per library)

```bash
test -f "MedTechDocuments/Pacemaker Patient Guide.pdf" && echo "EXISTS" || echo "NOT_FOUND"
```

**If NOT_FOUND:** report `"PDF file not found at: <path>"`, mark this library as failed, continue to the next library.

**If EXISTS:** capture file size for use in Step 8:

```bash
stat -c%s "MedTechDocuments/Pacemaker Patient Guide.pdf" 2>/dev/null || wc -c < "MedTechDocuments/Pacemaker Patient Guide.pdf"
```

Store as `FILE_SIZE` (integer bytes).

---

### Step 2 — Reserved (skipped in the MCP-first flow)

This step number is intentionally preserved from the legacy skill for cross-reference. Nothing runs here; proceed to Step 3.

---

### Step 3 — Create the library via MCP

**MCP call:**

```
mcp__salesforce-headless-360__dispatch(
  url="/services/data/v67.0/einstein/data-libraries",
  method="POST",
  body={
    "masterLabel": "Pacemaker Implant Guide",
    "developerName": "PacemakerImplantGuide",
    "description": "Pacemaker implant patient guide for Agentforce grounding",
    "groundingSource": {"sourceType": "SFDRIVE"}
  }
)
```

**Expected response (HTTP 201):**

```json
{
  "dataSpaceScopeId": "9gTxx000001Q1UXEA0",
  "description": "Pacemaker implant patient guide for Agentforce grounding",
  "developerName": "PacemakerImplantGuide",
  "groundingSource": {
    "groundingFileRefs": [],
    "groundingSourceType": "SFDRIVE",
    "indexMode": "BASIC"
  },
  "libraryId": "1JDxx000000ABCDAAA",
  "masterLabel": "Pacemaker Implant Guide",
  "sourceType": "SFDRIVE",
  "status": "IN_PROGRESS"
}
```

Extract `libraryId` and store as `LIBRARY_ID`.

**Error handling (`status_code` field from the MCP response):**

| HTTP | Meaning | Recovery |
|---|---|---|
| 201 | Library created | Proceed to Step 4 |
| 400 (`INVALID_REQUEST_STATE`, `already exists`, `duplicate`) | Library with that `developerName` already exists | Re-fetch list from Step 0A, reuse existing `libraryId`, skip to Step 4 |
| 400 (other) | Malformed body — check `masterLabel` non-empty, `developerName` alphanumeric+underscore only, `groundingSource.sourceType == "SFDRIVE"` | Report body + Salesforce message, fail-fast this library, continue to next |
| 401 | MCP session invalid | Report `"headless-360 MCP session invalid — run /mcp-setup"`, STOP entire skill |
| 403 | User lacks `Manage Einstein Features` permission | Report which permission is missing, fail-fast this library |
| 404 | Feature not enabled (`/einstein/data-libraries` route doesn't exist) | Report `"Agentforce Data Library feature not enabled in org"`, STOP entire skill (no library can be created) |
| 5xx | Salesforce transient | Wait 15 s, retry once. If retry fails, mark library failed, continue |

---

### Step 4 — Wait for the library's Data Lake Object to be provisioned

**Why this step exists**: `POST /einstein/data-libraries` returns immediately with `status: IN_PROGRESS` — the actual Data Lake Object + Data Model Object are provisioned asynchronously. If Step 5 (presigned URL generation) is called before provisioning finishes, Salesforce returns HTTP 400 with `INVALID_REQUEST_STATE` and message:

> "We're sorry for the delay. Data lake and data model object creation are taking longer than usual. Please wait for the process to finish and then retry."

Empirically, provisioning completes in **10–20 seconds** for new libraries. This was hit during the POC — the fix is a short bounded wait + a readiness probe.

**Two-part wait:**

1. **Static wait (baseline):** `sleep 15` — covers the typical case in one operation.
2. **Readiness probe (up to 90 s further):** call the readiness endpoint every 10 s:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v67.0/einstein/data-libraries/{LIBRARY_ID}/upload-readiness?waitMaxTime=60000",
  method="GET"
)
```

**Success response:**
```json
{
  "libraryId": "1JDxx000000ABCDAAA",
  "message": "Data object is active. Ready for file uploads.",
  "ready": true,
  "sourceType": "SFDRIVE"
}
```

Poll loop pseudocode:

```
sleep 15
for attempt in 1..9:
  r = dispatch_readonly("/services/data/v67.0/einstein/data-libraries/{LIB}/upload-readiness?waitMaxTime=60000", "GET")
  if r.status_code == 200 and r.body.ready == true:
    proceed to Step 5
  if r.status_code == 404:
    # Sometimes surfaces during the initial 10-20s window
    sleep 10; continue
  else:
    sleep 10
after loop:
  # ~105 s total budget spent
  report "Upload readiness timeout for {LIBRARY_ID}"
  mark this library failed
  continue to next library
```

**Error handling:**

| Condition | Recovery |
|---|---|
| `ready: true` | Proceed to Step 5 |
| `ready: false` after full budget (~105 s) | Mark library failed, continue to next library |
| HTTP 404 for the readiness endpoint | Retry until budget exhausted — Salesforce is provisioning; this is transient |
| HTTP 5xx | Same as `ready: false` timeout — mark failed, continue |

**Do NOT** attempt Step 5 while `ready` is false; it will fail with `INVALID_REQUEST_STATE` and consume attempts unnecessarily.

---

### Step 5 — Generate presigned upload URL via MCP

**MCP call:**

```
mcp__salesforce-headless-360__dispatch(
  url="/services/data/v67.0/einstein/data-libraries/{LIBRARY_ID}/file-upload-urls",
  method="POST",
  body={"files": [{"fileName": "Pacemaker Patient Guide.pdf"}]}
)
```

**IMPORTANT:** Do NOT include `mimeType` in the request. It is returned in `uploadUrls[].headers` and used automatically in Step 6.

**Expected response (HTTP 201):**

```json
{
  "libraryId": "1JDxx000000ABCDAAA",
  "uploadUrls": [
    {
      "fileName": "Pacemaker Patient Guide.pdf",
      "filePath": "$agentforce_data_library$/1JDxx000000ABCDAAA/Pacemaker Patient Guide.pdf",
      "headers": {"Content-Type": "application/pdf"},
      "uploadUrl": "https://aws-prod24-apsouth2-cdp1-lakehouse-2.s3.ap-south-2.amazonaws.com/sfdrive/..."
    }
  ]
}
```

Extract into local variables:
- `UPLOAD_URL` = `body.uploadUrls[0].uploadUrl` (AWS S3 presigned URL, valid **15 minutes**)
- `FILE_PATH` = `body.uploadUrls[0].filePath` (used in Step 8's indexing body)
- `CONTENT_TYPE` = `body.uploadUrls[0].headers["Content-Type"]` (should be `application/pdf`)

**Error handling:**

| HTTP | Meaning | Recovery |
|---|---|---|
| 201 | URL generated | Proceed to Step 6 |
| 400 (`INVALID_REQUEST_STATE`) | Data Lake Object provisioning still running | Loop back to Step 4 readiness probe (should not happen if Step 4 completed properly) |
| 400 (other) | Malformed `files[]` — verify each entry has `fileName` only | Report body, mark library failed |
| 404 | `libraryId` invalid / library deleted between Step 3 and Step 5 | Report, mark library failed |
| 401 | Session invalid | STOP skill |
| 5xx | Salesforce transient | Wait 15 s, retry once |

---

### Step 6 — Upload the PDF to AWS S3 (curl — external service, MCP does NOT proxy S3)

This is the **only** shell-out to `curl` in the skill. S3 is external to Salesforce; MCP does not tunnel through to it. The presigned URL contains a temporary AWS credential and expires in 15 minutes.

```bash
curl -X PUT \
  "$UPLOAD_URL" \
  -H "Content-Type: application/pdf" \
  --upload-file "MedTechDocuments/Pacemaker Patient Guide.pdf" \
  -w "HTTP=%{http_code}\n" \
  -s -o /dev/null
```

**Success:** `HTTP=200` with empty response body.

**Error handling:**

| Result | Meaning | Recovery |
|---|---|---|
| HTTP 200 | Uploaded | Proceed to Step 8 |
| HTTP 403 (`AccessDenied` / `SignatureDoesNotMatch`) | Presigned URL expired (>15 min since Step 5) | Go back to Step 5, regenerate URL, retry |
| HTTP 400 | Corrupted PDF or size mismatch | Run `file "path/to/file.pdf"` — must report `PDF document`. Verify `FILE_SIZE > 0`. If PDF is valid, regenerate URL (Step 5) and retry once |
| Connection reset / timeout | Network / firewall / AWS blip | Wait 10 s, retry once. If second attempt fails, mark library failed |
| HTTP 500 / 503 (from S3) | Transient AWS | Exponential backoff: 30 s, 60 s, 120 s — up to 3 retries |

**For files > 100 MB:** add `--max-time 600` (10 min) to the curl invocation.

---

### Step 7 — Reserved (file size already captured in Step 1)

Step 1 captured `FILE_SIZE` for use in Step 8. Proceed to Step 8.

---

### Step 8 — Trigger indexing via MCP

**MCP call:**

```
mcp__salesforce-headless-360__dispatch(
  url="/services/data/v67.0/einstein/data-libraries/{LIBRARY_ID}/indexing",
  method="POST",
  body={
    "uploadedFiles": [
      {
        "filePath": "$agentforce_data_library$/1JDxx000000ABCDAAA/Pacemaker Patient Guide.pdf",
        "fileSize": 478680
      }
    ]
  }
)
```

**CRITICAL — Payload shape gotcha (validated empirically during MCP POC):**

- The `/indexing` endpoint expects `uploadedFiles[]` with exactly two keys per entry: `filePath` and `fileSize`.
- `fileSize` is a **positive integer** (bytes) — not a string, not a float.
- Do NOT pass `fileName` here. If you do, Salesforce returns HTTP 400 `JSON_PARSER_ERROR: Unrecognized field "fileName"`. `fileName` is only used in Step 5 (`file-upload-urls`).

**Expected response (HTTP 201):**

```json
{
  "filesAccepted": 1,
  "libraryId": "1JDxx000000ABCDAAA",
  "message": "Provisioning started",
  "sourceType": "SFDRIVE",
  "status": "IN_PROGRESS"
}
```

Indexing runs asynchronously in the background (4 stages, typically 2–10 minutes).

**Error handling:**

| HTTP | Meaning | Recovery |
|---|---|---|
| 201 | Indexing pipeline started | Proceed to Step 9 (monitor) |
| 400 (`JSON_PARSER_ERROR: Unrecognized field "fileName"`) | Payload includes `fileName` (used in Step 5, not Step 8) | Fix payload to `{"filePath","fileSize"}` only, retry |
| 400 (`filePath` invalid) | Path doesn't match `$agentforce_data_library$/{LIBRARY_ID}/{filename}` | Use the exact `filePath` returned by Step 5 — do NOT reconstruct it manually |
| 400 (`fileSize` invalid) | `fileSize` sent as string or missing | Cast to int, retry |
| 404 | Library deleted / ID invalid | Report, mark library failed |
| 409 | File already indexed for this library | Treat as success (idempotent) — skip Step 9 monitoring for this file, continue |
| 500 | Backend indexing service unavailable | Wait 60 s, retry once. If it fails again, mark library failed |

---

### Step 9 — Monitor indexing status via MCP

**MCP call:**

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v67.0/einstein/data-libraries/{LIBRARY_ID}/status",
  method="GET"
)
```

**Response:**

```json
{
  "indexingStatus": {
    "currentStage": "SEARCH_INDEX",
    "lastUpdatedAt": 1779201936211,
    "libraryId": "1JDxx000000KCQODGA5",
    "stages": {
      "DATA_LAKE_OBJECT": {"completedAt": 1779201815000, "status": "SUCCESS"},
      "DATA_MODEL_OBJECT": {"completedAt": 1779201815000, "status": "SUCCESS"},
      "SEARCH_INDEX":     {"startedAt":   1779201815000, "status": "IN_PROGRESS"},
      "RETRIEVER":        {"status": "SCHEDULED"}
    },
    "status": "IN_PROGRESS"
  }
}
```

**Indexing Stages:**

1. **DATA_LAKE_OBJECT** — file stored in Salesforce Data Lake (AWS S3)
2. **DATA_MODEL_OBJECT** — data model created
3. **SEARCH_INDEX** — search index and vector embeddings generated
4. **RETRIEVER** — retriever configured for Agentforce grounding

**🚨 API status inconsistency (known Salesforce issue, preserved from legacy skill):**

The top-level `indexingStatus.status` field can remain `IN_PROGRESS` even after all 4 stages complete with `status: SUCCESS`. Do NOT wait for `status == "READY"` alone.

**Completion criteria (use EITHER):**
1. `indexingStatus.status == "READY"` (ideal), OR
2. All 4 stages `status == "SUCCESS"` **AND** the library detail endpoint confirms `groundingSource.groundingFileRefs` is non-empty **AND** `retrieverId` (or `retrieverDeveloperName`) is populated.

The library detail is fetched with:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v67.0/einstein/data-libraries/{LIBRARY_ID}",
  method="GET"
)
```

**Fail-fast condition:** any stage with `status == "FAILED"` (or overall `status == "FAILED"`) → mark library failed, do NOT keep polling.

Typical wall-clock: **2–10 minutes** for all 4 stages to complete.

---

### Step 9.5 — MANDATORY: wait for ALL libraries to reach READY

**Hard gate.** The skill MUST NOT report success — and the orchestrator MUST NOT advance to the next skill (`/document-ai` / `/create-individual-retrievers` etc.) — until every library created in this run has reached READY (or the functional-equivalent state defined in Step 9).

**Polling parameters (fixed — do NOT shorten):**

| Parameter | Value |
|---|---|
| Check interval | **2 minutes** (`sleep 120` between polling passes) |
| Maximum total wait | **15 minutes** (≤ 8 polling passes per library) |
| Per-library check | `mcp__salesforce-headless-360__dispatch_readonly` on `/einstein/data-libraries/{libraryId}/status` |
| Per-library completion | `indexingStatus.status == "READY"` **OR** all 4 stages `SUCCESS` + `groundingFileRefs` non-empty + `retrieverId` present |
| Failure-on-stage | Any stage `status == "FAILED"` → fail-fast for that library |

**Implementation sketch (pseudocode — the model runs the MCP calls; no Bash loop needed):**

```
LIBRARY_IDS   = [ids created in Steps 3–8 above]
PENDING_IDS   = LIBRARY_IDS.copy()
READY_IDS     = []
FAILED_IDS    = []
ELAPSED       = 0
CHECK_INTERVAL = 120   # seconds
MAX_TOTAL_WAIT = 900   # 15 min

while PENDING_IDS and ELAPSED < MAX_TOTAL_WAIT:
  sleep CHECK_INTERVAL          # 120s
  ELAPSED += CHECK_INTERVAL
  STILL_PENDING = []
  for LIB_ID in PENDING_IDS:
    status = mcp__salesforce-headless-360__dispatch_readonly(
      url=f"/services/data/v67.0/einstein/data-libraries/{LIB_ID}/status",
      method="GET"
    ).body.indexingStatus

    if status.status == "READY":
      READY_IDS.append(LIB_ID); continue

    if status.status == "FAILED" or any(s.status == "FAILED" for s in status.stages.values()):
      failed_stages = [k for k,v in status.stages.items() if v.status == "FAILED"]
      FAILED_IDS.append((LIB_ID, failed_stages))
      continue

    all_success = all(status.stages.get(s, {}).get("status") == "SUCCESS"
                      for s in ["DATA_LAKE_OBJECT","DATA_MODEL_OBJECT","SEARCH_INDEX","RETRIEVER"])
    if all_success:
      # Functional check — fetch library detail
      detail = mcp__salesforce-headless-360__dispatch_readonly(
        url=f"/services/data/v67.0/einstein/data-libraries/{LIB_ID}",
        method="GET"
      ).body
      refs = (detail.get("groundingSource") or {}).get("groundingFileRefs", [])
      ret_id = detail.get("retrieverId") or detail.get("retrieverDeveloperName") or ""
      if refs and ret_id:
        READY_IDS.append(LIB_ID)
      else:
        STILL_PENDING.append(LIB_ID)   # retriever not yet published
    else:
      STILL_PENDING.append(LIB_ID)
  PENDING_IDS = STILL_PENDING

# Gate
if PENDING_IDS or FAILED_IDS:
  raise Error("ADL READY-STATE GATE FAILED — see per-library detail in report")
```

**Hard rules:**

- ✅ The skill is **only complete** when `len(READY_IDS) == len(LIBRARY_IDS)`, `PENDING_IDS` is empty, `FAILED_IDS` is empty.
- ❌ Do NOT shorten the 2-minute interval — Salesforce's indexing pipeline is back-end rate-limited; polling more aggressively wastes MCP calls without speeding anything up.
- ❌ Do NOT extend the 15-minute timeout in this skill. If a library legitimately needs longer (rare), surface it to the user and let them re-run after manual inspection. Hiding a slow indexing failure behind a longer wait makes downstream failures (`/create-individual-retrievers` not finding the retriever) much harder to diagnose.
- ❌ Do NOT skip Step 9.5 even if Step 8 returned `IN_PROGRESS` for all libraries — that response only confirms the request was accepted, not that anything indexed.
- ⚠️ On **fail-fast** (any stage `FAILED`), the skill MUST mark that library failed and NOT retry within the same run. Recovery is: delete the library, fix the root cause (file too large, malformed PDF, missing permission), re-run the skill.
- ⚠️ The orchestrator (`data360-healthcare-installer`) treats any non-empty `FAILED_IDS` from this skill as a hard stop. The next skill is **never** auto-invoked when Step 9.5 fails.

---

### Step 10 — Report completion

**Success (all libraries READY):**

```text
✅ Agentforce Data Libraries Created!

Org: <org_alias>

📊 Summary: {ready_count}/{total_count} libraries READY

════════════════════════════════════════════

✅ Ready Libraries:

1. Pacemaker Implant Guide
   Library ID: 1JDxx000000ABCD001
   File: Pacemaker Patient Guide.pdf ({file_size_1} KB)
   Status: READY

2. Patient Clinician Discharge And Interrogation Note
   Library ID: 1JDxx000000ABCD002
   File: ClinicianNote_DischargeSummary.pdf ({file_size_2} KB)
   Status: READY

3. Patient OP
   Library ID: 1JDxx000000ABCD003
   File: Mark_Smith_OP_Note.pdf ({file_size_3} KB)
   Status: READY

════════════════════════════════════════════

Next Steps:
1. Navigate to Agent Builder
2. Go to Agent → Data tab
3. Add each library as a data source
4. Save agent configuration
5. Test agent with grounded questions about the documents
```

**Partial / failure:**

```text
❌ ADL READY-STATE GATE FAILED

Org: <org_alias>
Ready:   {ready_count} of {total_count}
Pending: {pending_count} (still IN_PROGRESS after 15 min)
Failed:  {failed_count}

════════════════════════════════════════════

❌ Failed Libraries:

- 1JDxx000000ABCD002 (Patient Clinician Discharge)
  Failed stage: SEARCH_INDEX
  Inspect: dispatch_readonly GET /services/data/v67.0/einstein/data-libraries/1JDxx000000ABCD002/status

⏳ Still Pending:

- 1JDxx000000ABCD003 (Patient OP)
  Currently at stage: SEARCH_INDEX (IN_PROGRESS)
  Retry: /agentforce-data-library <org_alias> — will pick up existing library and continue polling.

Skill did NOT report success. Downstream skills (e.g. /document-ai, /create-individual-retrievers) are BLOCKED.
```

---

## Important Rules

**CRITICAL — Transport:**
- 🚨 **ALWAYS use `salesforce-headless-360` MCP** for Salesforce API calls (`dispatch` for writes, `dispatch_readonly` for GETs).
- 🚨 **NEVER shell out to `curl` for Salesforce endpoints.** The one exception is Step 6's S3 PUT — S3 is not a Salesforce endpoint.
- 🚨 **NEVER call `sf apex run` or use Apex to hit these APIs.**
- 🚨 **NEVER extract the access token via `sf org display --json` and pass it in a header manually** — MCP holds the token server-side.

**CRITICAL — Correct API Endpoint:**
- 🚨 **ALWAYS use:** `/services/data/v67.0/einstein/data-libraries`
- 🚨 **NEVER use:** `/services/data/v67.0/connect/einstein/data-libraries` (returns 404)
- The `/connect/` path is INCORRECT and will fail
- API version v67.0 is required; v66.0 works but is being phased out

**CRITICAL — Request Body Structure:**
- 🚨 **Step 3 (create):** `masterLabel`, `developerName`, `description`, `groundingSource: {"sourceType": "SFDRIVE"}`
- 🚨 **NOT:** `name`, `dataSourceType` (old/incorrect structure)
- 🚨 **developerName** must be alphanumeric + underscores only (no spaces) — e.g. `PacemakerImplantGuide`
- 🚨 **Step 5 (presigned URL):** `files: [{"fileName": "…"}]` — do NOT include `mimeType`
- 🚨 **Step 8 (indexing):** `uploadedFiles: [{"filePath": "…", "fileSize": <int bytes>}]` — do NOT include `fileName`

**CRITICAL — File Upload Flow:**
- 🚨 Upload directly to AWS S3 using the presigned URL (curl PUT).
- 🚨 File size in **bytes as an integer** — get via `stat -c%s` or `wc -c`.
- 🚨 Presigned URLs expire in **15 minutes** — complete Step 6 quickly.
- 🚨 Use `/indexing` endpoint (not `/index`).

**General Rules:**
- NEVER hardcode org names — the MCP session is scoped to the registered org
- ALWAYS verify PDF file exists (Step 1) before starting upload
- ALWAYS run the Step 4 readiness probe before Step 5 (Data Lake Object activates asynchronously)
- ALWAYS use the exact `filePath` returned by Step 5's response (do NOT reconstruct it)
- Library ID starts with `1JD` (18-character Salesforce ID)
- Indexing has 4 stages, takes 2–10 minutes wall-clock

**Mode Rules:**
- **Healthcare Kit Mode (default):** creates 3 fixed libraries; no `libraries` param needed
- **Custom Mode:** requires `mode="custom"` and `libraries` parameter
- Process libraries sequentially — NEVER in parallel
- If one library fails, continue processing remaining libraries (per-library best-effort)
- Track success/failure for each library separately
- Report combined summary at end with all successes, pending, and failures

**API Version:**
- **Use v67.0** for all Einstein Connect API calls
- API version is baked into the path — the MCP does NOT auto-upgrade it

---

## Error Handling & Recovery — Full Matrix

**Step 3 (Library Creation) Errors:**

| HTTP | Salesforce message pattern | Cause | Recovery |
|---|---|---|---|
| 400 | `already exists`, `duplicate` | Library with `developerName` already exists | Re-fetch list from Step 0A, reuse existing `libraryId`, skip to Step 4 |
| 400 | `INVALID_REQUEST_STATE` | Provisioning pending on a very recent prior operation | Wait 15 s, retry once |
| 400 | Other | Malformed body | Verify body shape; fail-fast this library |
| 401 | `invalid_grant` | MCP session invalid | STOP entire skill; user must re-run `/mcp-setup` |
| 403 | `INSUFFICIENT_ACCESS` | Missing "Manage Einstein Features" permission | Report, fail-fast |
| 404 | Feature not enabled | ADL not on this org | STOP entire skill |
| 5xx | Any | Salesforce transient | Wait 15 s, retry once; if it fails, mark library failed |

**Step 4 (Upload Readiness) Errors:**

| Condition | Cause | Recovery |
|---|---|---|
| `ready: false` for full ~105 s budget | Data Lake Object still provisioning (rare — usually 10–20 s) | Mark library failed, continue to next |
| 404 during initial probe | Provisioning race window (normal within first ~10 s) | Retry until budget exhausted |
| 5xx | Salesforce transient | Same as `ready: false` timeout |

**Step 5 (Presigned URL) Errors:**

| HTTP | Cause | Recovery |
|---|---|---|
| 400 (`INVALID_REQUEST_STATE`) | Data Lake Object not ready (should not happen if Step 4 completed) | Loop back to Step 4 |
| 400 (other) | Malformed `files[]` | Fix payload, retry |
| 404 | `libraryId` invalid | Report, mark failed |
| 401 | Session invalid | STOP skill |

**Step 6 (S3 Upload) Errors:**

| Condition | Cause | Recovery |
|---|---|---|
| HTTP 403 | Presigned URL expired (>15 min) | Regenerate URL (Step 5), retry once |
| HTTP 400 | Corrupted PDF | Verify with `file "..."` — must be `PDF document`. Retry Step 5 + Step 6 |
| Connection reset / timeout | Network / firewall | Wait 10 s, retry once |
| HTTP 5xx from S3 | AWS transient | Exponential backoff 30 s → 60 s → 120 s, up to 3 retries |

**Step 8 (Indexing Trigger) Errors:**

| HTTP | Cause | Recovery |
|---|---|---|
| 400 (`JSON_PARSER_ERROR: Unrecognized field "fileName"`) | Payload includes `fileName` — that field is only for Step 5 | Remove `fileName` from `uploadedFiles[]`, keep only `filePath` + `fileSize`, retry |
| 400 (invalid `filePath`) | Reconstructed path doesn't match Step 5's response | Use `filePath` verbatim from Step 5, retry |
| 400 (invalid `fileSize`) | Sent as string or missing | Cast to int, retry |
| 404 | Library deleted between Step 3 and Step 8 | Report, mark failed |
| 409 | File already indexed for this library | Treat as success (idempotent) |
| 500 | Backend indexing unavailable | Wait 60 s, retry once |

**Step 9 (Status) Errors:**

| Condition | Cause | Recovery |
|---|---|---|
| Any stage `FAILED` | File-specific failure (too big, malformed, unsupported content) | Fail-fast for that library. User must delete the library and re-run with a fixed file |
| Overall `status: IN_PROGRESS` after 15 min but all stages `SUCCESS` | Known API status inconsistency | Verify via library detail endpoint (`groundingFileRefs` + `retrieverId`); if both present, treat as READY |
| HTTP 404 | Library deleted mid-run | Report, mark failed |

---

## Discovery via MCP (optional but recommended when the skill breaks)

If Salesforce changes a payload shape or endpoint path (rare but has happened at major API version bumps), the skill will start returning HTTP 400s from Step 3 / 5 / 8. Before assuming a bug, re-run:

```
mcp__salesforce-headless-360__discover(
  query="Einstein data libraries create Agentforce grounding",
  limit=5
)
```

Then describe the top hit:

```
mcp__salesforce-headless-360__describe(
  id="ai-data-library-connect-api-genai.unified.setup.connect.api-oas-67.0"
)
```

The `steps[]` array in the SOR is the authoritative source for endpoint paths, HTTP methods, and payload shapes. If the SOR disagrees with this skill, the SOR wins — update the skill.

---

## ✅ COMPLETION CHECKLIST

Verify all items before marking complete:

| # | Task | Verification |
|---|---|---|
| 0 | MCP session valid | `dispatch_readonly` on `/services/data/v67.0/limits` returned HTTP 200 |
| 0A | Existing libraries checked | List-libraries call ran; overlapping libraries reused, not recreated |
| 1 | PDF exists for every library in the run | `test -f` passed; `FILE_SIZE > 0` captured |
| 3 | Each library created (or reused) | `libraryId` captured for every entry in the run |
| 4 | Each library's Data Lake Object provisioned | `upload-readiness` returned `ready: true` before Step 5 |
| 5 | Each library got a presigned URL | `UPLOAD_URL` + `FILE_PATH` captured for every entry |
| 6 | PDF uploaded to S3 | curl PUT returned HTTP 200 |
| 8 | Indexing triggered | `POST /indexing` returned HTTP 201 with `filesAccepted: 1` |
| 9.5 | READY gate cleared | All library IDs in `READY_IDS`; `PENDING_IDS` and `FAILED_IDS` both empty |
| 10 | Completion report emitted | Report includes every library's ID, filename, size, final status |

---

## Integration with the Data360 Healthcare Installer

This skill runs after `/datakit-d360-deploy` and before `/notebook-ai` in the 24-step installer.

```
Workflow position:
6. /datakit-d360-deploy       ← runs BEFORE
7. /agentforce-data-library   ← this skill
8. /notebook-ai               ← runs AFTER (blocked until Step 9.5 passes)
```

If Step 9.5 emits a non-empty `PENDING_IDS` or `FAILED_IDS`, the installer must halt at the end of this skill and surface the failure report. Downstream skills that reference the retrievers (`/document-ai-retriever`, `/prompt-template-add-retriever`, `/agent-setup-configuration`) will not find the retrievers if this skill's Step 9.5 gate is bypassed.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"agentforce-data-library"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.agentforce-data-library` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
