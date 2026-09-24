---
name: documentAiSkill
description: >
  Set up Salesforce Document AI end-to-end — authenticate org, create Document AI configuration,
  poll until runtime status is Ready, then create the DAI_Patient_OP Search Index and
  DAI Patient OP Retriever using the salesforce-data360 MCP server.
  Covers all 5 steps: org auth, config creation, runtime poll, search index creation, and retriever creation.
  Trigger on phrases like "set up Document AI", "create a Document AI model",
  "configure Document AI", "enable Document AI", "authenticate org for Document AI",
  "create DAI search index and retriever", "create document AI search index",
  "create DAI retriever", "create document AI retriever", "add retriever for DAI Patient OP",
  or "run search index and retriever step for document AI".
---

# Document AI Skill

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"document-ai"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: document-ai already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Prerequisites

- Salesforce CLI (`sf`) installed and accessible in the terminal
- A Salesforce org with Document AI enabled or eligible to be enabled
- The `salesforce-data360` MCP server must be authenticated for the target org via `/mcp-setup`
- The user must provide an **org alias** (already connected via `sf org login web` or JWT)

---

## Arguments

- `org_alias` (required): The Salesforce org alias the user provides — used for all CLI and API calls throughout this skill

**Before proceeding to any step, ask the user:**

> "Please provide your Salesforce org alias (e.g. `my-dev-org`)."

Store the response as `ORG_ALIAS`. Do not proceed until this value is supplied.

---

## Execution Rules

> **HARD RULE — ZERO EXCEPTIONS:**
> ALL steps (Step 1 through Step 9 and Cleanup) MUST be executed every time, in strict sequential order.
> - **Do NOT skip any step** — not for speed, not for convenience, not because a step "seems unnecessary".
> - **Do NOT parallelize steps** — Step N+1 must never start until Step N has completed successfully.
> - **If a step fails, STOP immediately.** Report the exact error to the user and wait for resolution before continuing. Do NOT silently skip the failed step.
> - **Each step depends on values captured in the previous step.** Missing values from a skipped step will cause downstream failures.
> - **Do NOT attempt alternate approaches** if the skill specifies a method. Follow the exact method written — no substitutions.

**Step execution order:**
```
Step 1: Authenticate / Verify Org → captures ACCESS_TOKEN, INSTANCE_URL
   ↓ (MUST complete before Step 2)
Step 2: Create Document AI Configuration → captures SOURCE_DMO, CONFIG_ID
   ↓ (MUST complete before Step 3)
Step 3: Poll Until Runtime Status Is Ready → confirms CONFIG_ID is Ready
   ↓ ⚠️ MUST WAIT — poll every 30s until runtimeStatus = "Ready" (up to 25 min). DO NOT proceed until Ready.
Step 4: Check MCP Connection + check if search index OR retriever already exists → STOP if either exists
   ↓ (neither exists → proceed)
Step 5: Create Search Index (sourceDmoDeveloperName hardcoded as DAI_Patient_OP__dlm)
   ↓ ⚠️ MUST WAIT — poll every 2 min until runtimeStatus = READY (up to 30 min)
Step 6: Poll Search Index Until READY → captures SEARCH_INDEX_ID + DAI_PATIENT_OP_SOURCE_DMO
   ↓ ⚠️ MUST reach runtimeStatus = READY. null / Processing / Initializing = keep polling. NEVER proceed to Step 7 until READY is confirmed.
Step 7: Create Retriever → uses SEARCH_INDEX_ID + DAI_PATIENT_OP_SOURCE_DMO → captures RETRIEVER_NAME, RETRIEVER_ID
   ↓ (MUST complete before Step 8)
Step 8: Verify Retriever → confirms isActive + 35 output fields
   ↓
Step 9: Final Report
   ↓
Cleanup: Delete temp artifacts
```

---

## Step 1 — Authenticate / Verify Org

Verify that the provided org alias is valid and the session is active:

```bash
sf org display --target-org <ORG_ALIAS>
```

**If successful** — confirm the details and proceed:

```
✅ Org verified successfully
   Alias:        <ORG_ALIAS>
   Username:     <username>
   Instance URL: <instanceUrl>
   Status:       Active
```

Run the JSON form to extract these values:

```bash
sf org display --target-org <ORG_ALIAS> --json
```

Capture for subsequent steps:
- `result.accessToken` → `ACCESS_TOKEN`
- `result.instanceUrl` → `INSTANCE_URL`

All subsequent API calls use:
```
Authorization: Bearer <ACCESS_TOKEN>
Content-Type: application/json
Base URL: <INSTANCE_URL>/services/data/v67.0
```

**If the command fails** (alias not found or session expired) — instruct the user to authenticate first:

```bash
sf org login web --alias <ORG_ALIAS>
```

Then re-run `sf org display` to confirm the session is active before continuing.

**If `accessToken` or `instanceUrl` are missing from the JSON output** — the session may be expired even if the command exited successfully. Instruct the user to re-authenticate:

```
❌ Could not extract accessToken or instanceUrl from org display output.
   Run: sf org login web --alias <ORG_ALIAS>
   Then retry.
```

---

## Step 2 — Create Document AI Configuration

Create a Document AI configuration on the authenticated org.

### Discover the Source DMO

Run the following SF CLI command to list all Unstructured DMOs:

```bash
sf api request rest "/services/data/v67.0/ssot/data-model-objects?category=Unstructured" --target-org <ORG_ALIAS>
```

**If this command fails** (non-zero exit or error in JSON) — report the error and stop:

```
❌ Failed to list Unstructured DMOs.
   Error: <error message>
   Check that Document AI is enabled on this org and the session is still active.
```

From the response, find the DMO whose name starts with `ADL` and contains `Patient_OP` or `PatientOP` in the middle or at the end. Exclude any DMO whose name contains `chunk` or `index`. Capture the matching DMO name as `SOURCE_DMO`.

**If no match is found**, report an error and stop:

```
❌ No matching Unstructured DMO found for Patient_OP.
   Ensure the Document AI extraction model has been provisioned on this org.
```

```
✅ Source DMO found: <SOURCE_DMO>
```

### Create the Configuration

```
POST <INSTANCE_URL>/services/data/v67.0/ssot/document-processing/configurations
```

**On success** (HTTP 2xx), capture from the response:
- `id` → `CONFIG_ID`

```
✅ Document AI configuration created.
   Config ID: <CONFIG_ID>
```

**On failure** (HTTP 4xx / 5xx or CLI error), report the full error response and stop:

```
❌ Failed to create Document AI configuration.
   HTTP Status: <status>
   Error: <error body>
   Check the request payload and ensure the org has Document AI enabled.
```

**Request body:**

```json
{
  "label": "DIA Patient OP Schema",
  "name": "DIA_Patient_OP_Schema",
  "description": "Configuration crated for extracting report details",
  "sourceDmoDeveloperName": "<SOURCE_DMO>",
  "mlModel": "sfdc_ai__DefaultGPT54",
  "activationStatus": "ACTIVATED",
  "fileConfig": {
    "fileTypes": ["application/pdf"]
  },
  "schemaConfig": "{\"$schema\":\"https://json-schema.org/draft-07/schema\",\"title\":\"DocAI_OP_Notes\",\"type\":\"object\",\"properties\":{\"patientName\":{\"type\":\"string\"},\"dob\":{\"type\":\"string\"},\"hospital\":{\"type\":\"string\"},\"patientID\":{\"type\":\"string\"},\"procedure\":{\"type\":\"string\"},\"dateOfImplant\":{\"type\":\"string\"},\"implantSite\":{\"type\":\"string\"},\"deviceModel\":{\"type\":\"string\"},\"deviceSerial\":{\"type\":\"string\"},\"indication\":{\"type\":\"string\"},\"fluoroscopyTime\":{\"type\":\"number\"},\"estimatedBloodLoss\":{\"type\":\"number\"},\"atrialLeadModel\":{\"type\":\"string\"},\"atrialLeadSerial\":{\"type\":\"string\"},\"atrialLeadPosition\":{\"type\":\"string\"},\"ventricularLeadModel\":{\"type\":\"string\"},\"ventricularLeadSerial\":{\"type\":\"string\"},\"ventricularLeadPosition\":{\"type\":\"string\"},\"raSensing\":{\"type\":\"string\"},\"raThreshold\":{\"type\":\"string\"},\"raLeadImpedance\":{\"type\":\"string\"},\"rvSensing\":{\"type\":\"string\"},\"rvThreshold\":{\"type\":\"string\"},\"rvLeadImpedance\":{\"type\":\"string\"},\"idpMode\":{\"type\":\"string\"},\"idpLowerRate\":{\"type\":\"string\"},\"idpUpperTrackingRate\":{\"type\":\"string\"},\"idpAtrialSensitivity\":{\"type\":\"string\"},\"idpVentricularSensitivity\":{\"type\":\"string\"},\"idpAtrialOutput\":{\"type\":\"string\"},\"idpVentricularOutput\":{\"type\":\"string\"},\"idpAVDelay\":{\"type\":\"string\"},\"procedureNarrative\":{\"type\":\"string\"}},\"required\":[\"patientName\",\"dob\",\"hospital\",\"patientID\",\"procedure\"]}",
  "extractedDloConfig": {
    "DocAI_OP_Notes": {
      "name": "DAI_Patient_OP__dll",
      "label": "DAI Patient OP",
      "category": "Other",
      "fields": {}
    }
  }
}
```

---

## Step 3 — Poll Until Runtime Status Is Ready

Using `CONFIG_ID` captured in Step 2, poll the configuration status endpoint until `runtimeStatus` is `"Ready"`, or until a timeout of **25 minutes** is reached.

### Poll Command

```bash
sf api request rest "ssot/document-processing/configurations/<CONFIG_ID>" \
  --target-org <ORG_ALIAS>
```

**If the poll command itself fails** (CLI error or non-2xx response), report and stop:

```
❌ Poll request failed on attempt <N>.
   Error: <error message>
   Config ID: <CONFIG_ID>
   Resolve the error before retrying.
```

### Polling Logic

- **Interval:** every **30 seconds**
- **Timeout:** 25 minutes (50 attempts)
- **Success condition:** `"runtimeStatus": "Ready"`
- **In-progress conditions:** `"runtimeStatus": "Processing"`, `"runtimeStatus": "Initializing"`, or `"runtimeStatus": "Submitted"` — keep polling. `Submitted` means the config is queued but not yet active — treat as transient, keep polling.
- **Failure condition:** `"runtimeStatus": "Failed"` or `"activationStatus": "DEACTIVATED"` — stop and report error
- **Unknown status:** any other `runtimeStatus` value — log the value and keep polling; do not stop

### Status Display

Print progress on each poll attempt:

```
⏳ [Attempt 1/50] Runtime Status: Processing — waiting 30s...
⏳ [Attempt 2/50] Runtime Status: Initializing — waiting 30s...
...
✅ Document AI configuration is Ready!
   Config ID:      <CONFIG_ID>
   Runtime Status: Ready
   Status:         Activated
```

If the timeout is reached without `Ready` status:

```
❌ Timed out after 25 minutes. Last Runtime Status: <last_runtimeStatus>
   Config ID: <CONFIG_ID>
   Check the org manually or re-run the skill.
```

---

## Step 4 — Check MCP Connection, Search Index and Retriever Existence

**🚨 EXECUTION CHANNEL — data360 MCP ONLY for Steps 4–8:**

All operations from this point are driven by the `salesforce-data360` MCP server (`mcp__salesforce-data360__execute` tool). **NO `curl`, NO `sf` CLI, NO bash, NO Python.**

| Action | data360 MCP tool | Parameter shape |
|---|---|---|
| List existing search indexes | `d360_search_index_list` | `{}` |
| Create search index | `d360_search_index_create` | See Step 5 payload |
| Get search index (status poll) | `d360_search_index_get` | `{"searchIndexApiNameOrId": "DAI_Patient_OP"}` |
| List existing retrievers | `d360_retriever_list` | `{}` |
| Create retriever | `d360_retriever_create` | `{"retriever": {"label": "...", "configuration": {...}}}` — See Step 7 payload |
| Get retriever (verify) | `d360_retriever_get` | `{"retrieverIdOrName": "<RETRIEVER_NAME>"}` |

Call both list tools upfront to confirm the data360 MCP is reachable AND check what already exists:

**4a — Check search index:**
```
mcp__salesforce-data360__execute
  toolName: d360_search_index_list
  paramsJson: {}
```

Parse the response:
- If `developerName == "DAI_Patient_OP"` already exists → report it and **STOP**. The search index already exists — no need to continue.
- If not found → proceed to Step 4b.

**4b — Check retriever:**
```
mcp__salesforce-data360__execute
  toolName: d360_retriever_list
  paramsJson: {}
```

Parse the response:
- If `label == "DAI Patient OP Retriever"` already exists → report its `name` and `id` and **STOP**. The retriever already exists — no need to continue.
- If not found → proceed to Step 5.

**If either call returns `invalid_grant` or `request not supported on this domain`:**
- The data360 MCP is not authenticated for this org.
- Stop and instruct the user to re-run `/mcp-setup` before continuing.

---

## Step 5 — Create Search Index

```
mcp__salesforce-data360__execute
  toolName: d360_search_index_create
  paramsJson: {
    "createSemanticSearchDefRecord": {
      "label": "DAI Patient OP",
      "developerName": "DAI_Patient_OP",
      "searchType": "HYBRID",
      "sourceDmoDeveloperName": "DAI_Patient_OP__dlm",
      "chunkDmoName": "DAI Patient OP chunk",
      "chunkDmoDeveloperName": "DAI_Patient_OP_chunk",
      "vectorDmoName": "DAI Patient OP index",
      "vectorDmoDeveloperName": "DAI_Patient_OP_index",
      "parsingConfigurations": [],
      "preProcessingConfigurations": [],
      "postProcessingConfigurations": [],
      "rankingConfigurations": [],
      "semanticSearchRankingConfigurations": [],
      "transformConfigurations": [],
      "chunkingConfiguration": {
        "fieldLevelConfigurations": [
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "deviceModel__c",           "sourceDmoFieldName": "deviceModel",           "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "dateOfImplant__c",         "sourceDmoFieldName": "dateOfImplant",         "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpAtrialOutput__c",       "sourceDmoFieldName": "idpAtrialOutput",       "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpUpperTrackingRate__c",  "sourceDmoFieldName": "idpUpperTrackingRate",  "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "SourceRecordId__c",        "sourceDmoFieldName": "Source Record Id",      "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "raSensing__c",             "sourceDmoFieldName": "raSensing",             "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "patientID__c",             "sourceDmoFieldName": "patientID",             "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "hospital__c",              "sourceDmoFieldName": "hospital",              "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpLowerRate__c",          "sourceDmoFieldName": "idpLowerRate",          "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "procedureNarrative__c",    "sourceDmoFieldName": "procedureNarrative",    "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "rvSensing__c",             "sourceDmoFieldName": "rvSensing",             "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpAVDelay__c",            "sourceDmoFieldName": "idpA-VDelay",           "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "ventricularLeadPosition__c","sourceDmoFieldName": "ventricularLeadPosition","sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "raLeadImpedance__c",       "sourceDmoFieldName": "raLeadImpedance",       "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "atrialLeadModel__c",       "sourceDmoFieldName": "atrialLeadModel",       "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "dob__c",                   "sourceDmoFieldName": "dob",                   "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "ventricularLeadSerial__c", "sourceDmoFieldName": "ventricularLeadSerial", "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "ventricularLeadModel__c",  "sourceDmoFieldName": "ventricularLeadModel",  "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "atrialLeadSerial__c",      "sourceDmoFieldName": "atrialLeadSerial",      "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "deviceSerial__c",          "sourceDmoFieldName": "deviceSerial",          "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpVentricularOutput__c",  "sourceDmoFieldName": "idpVentricularOutput",  "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "atrialLeadPosition__c",    "sourceDmoFieldName": "atrialLeadPosition",    "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "ProcessTimestamp__c",      "sourceDmoFieldName": "Process Timestamp",     "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "rvLeadImpedance__c",       "sourceDmoFieldName": "rvLeadImpedance",       "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "rvThreshold__c",           "sourceDmoFieldName": "rvThreshold",           "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpMode__c",               "sourceDmoFieldName": "idpMode",               "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "patientName__c",           "sourceDmoFieldName": "patientName",           "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpVentricularSensitivity__c","sourceDmoFieldName": "idpVentricularSensitivity","sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "procedure__c",             "sourceDmoFieldName": "procedure",             "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "implantSite__c",           "sourceDmoFieldName": "implantSite",           "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "raThreshold__c",           "sourceDmoFieldName": "raThreshold",           "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "idpAtrialSensitivity__c",  "sourceDmoFieldName": "idpAtrialSensitivity",  "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "ProcessId__c",             "sourceDmoFieldName": "Process Id",            "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}},
          {"sourceDmoDeveloperName": "DAI_Patient_OP__dlm", "sourceDmoFieldDeveloperName": "indication__c",            "sourceDmoFieldName": "indication",            "sourceDmoName": "DAI Patient OP", "decorators": [], "config": {"id": "passage_extraction", "userValues": [{"id": "strip_html", "value": "true"}, {"id": "max_tokens", "value": "512"}]}}
        ]
      },
      "vectorEmbedding": {
        "vectorEmbeddingRelatedFields": []
      },
      "vectorEmbeddingConfiguration": {
        "embeddingModel": {
          "id": "e5_large_v2",
          "userValues": [
            {"id": "dimension", "value": "1024"},
            {"id": "max_token_limit", "value": "512"}
          ]
        },
        "index": {
          "id": "HNSW",
          "userValues": [
            {"id": "hnswEfConstruction", "value": "2000"},
            {"id": "M", "value": "64"}
          ]
        },
        "similarityMetric": "COSINE"
      }
    }
  }
```

Capture from the response:
- `result.id` → `SEARCH_INDEX_ID`

```
✅ Search Index created successfully.
   Search Index ID: <SEARCH_INDEX_ID>
   Name:            DAI_Patient_OP
```

**If creation fails:**
- First call `d360_search_index_list` to check if it was silently created before reporting error.
- If found → capture its `id` as `SEARCH_INDEX_ID` and proceed to Step 6.
- If not found → report the full error verbatim and stop.

---

## Step 6 — Poll Search Index Until READY

Poll every 2 minutes until `runtimeStatus = READY` (max 30 minutes = 15 attempts):

```
mcp__salesforce-data360__execute
  toolName: d360_search_index_get
  paramsJson: {"searchIndexApiNameOrId": "DAI_Patient_OP"}
```

**Status values:**
- `READY` → proceed to Step 7
- `Processing` / `Initializing` / `null` → keep polling (wait 2 min between each poll). `null` means the index is not yet activated — this is a transient state, NOT a failure. DO NOT proceed to Step 7 while status is `null`.
- `Failed` → stop and report error

**🚨 STRICT RULE — NO EXCEPTIONS:**
Step 7 (Create Retriever) MUST NOT be invoked unless `runtimeStatus = READY` is explicitly confirmed.
If the 15-attempt timeout is exhausted and `runtimeStatus` is still `null`, `Processing`, or `Initializing` → STOP and report error. Never create the retriever on a non-READY search index.

**Progress report per poll:**
```
⏳ [Attempt N/15] runtimeStatus: Processing — waiting 2 min...
```

**On READY** — capture both values from the response:
- `result.id` → `SEARCH_INDEX_ID`
- `result.sourceDmoDeveloperName` → `DAI_PATIENT_OP_SOURCE_DMO` (value: `DAI_Patient_OP__dlm`)

```
✅ Search Index DAI_Patient_OP is READY.
   Search Index ID: <SEARCH_INDEX_ID>
   Source DMO:      DAI_Patient_OP__dlm
```

**On timeout (15 attempts exhausted):**
```
❌ Search Index did not reach READY in 30 minutes.
   Last status: <runtimeStatus>
   Check Setup → Data Cloud → Search Indexes → DAI_Patient_OP and retry.
```
Stop.

---

## Step 7 — Create Retriever

```
mcp__salesforce-data360__execute
  toolName: d360_retriever_create
  paramsJson: {
    "retriever": {
      "label": "DAI Patient OP Retriever",
      "description": "Individual retriever for DAI Patient OP DMO with 35 direct fields",
      "configuration": {
      "queryType": "NoCode",
      "input": {"id": "<SEARCH_INDEX_ID>"},
      "isActive": true,
      "queryFilter": {},
      "numberOfResults": 10,
      "retrievalMode": "Basic",
      "citationConfiguration": {"type": "Default"},
      "outputFields": [
        {"label": "atrialLeadModel",           "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "atrialLeadModel__c",           "relationships": []},
        {"label": "atrialLeadPosition",        "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "atrialLeadPosition__c",        "relationships": []},
        {"label": "atrialLeadSerial",          "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "atrialLeadSerial__c",          "relationships": []},
        {"label": "dateOfImplant",             "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "dateOfImplant__c",             "relationships": []},
        {"label": "deviceModel",               "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "deviceModel__c",               "relationships": []},
        {"label": "deviceSerial",              "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "deviceSerial__c",              "relationships": []},
        {"label": "dob",                       "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "dob__c",                       "relationships": []},
        {"label": "estimatedBloodLoss",        "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "estimatedBloodLoss__c",        "relationships": []},
        {"label": "fluoroscopyTime",           "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "fluoroscopyTime__c",           "relationships": []},
        {"label": "hospital",                  "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "hospital__c",                  "relationships": []},
        {"label": "idpA-VDelay",               "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpAVDelay__c",                "relationships": []},
        {"label": "idpAtrialOutput",           "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpAtrialOutput__c",           "relationships": []},
        {"label": "idpAtrialSensitivity",      "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpAtrialSensitivity__c",      "relationships": []},
        {"label": "idpLowerRate",              "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpLowerRate__c",              "relationships": []},
        {"label": "idpMode",                   "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpMode__c",                   "relationships": []},
        {"label": "idpUpperTrackingRate",      "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpUpperTrackingRate__c",      "relationships": []},
        {"label": "idpVentricularOutput",      "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpVentricularOutput__c",      "relationships": []},
        {"label": "idpVentricularSensitivity", "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "idpVentricularSensitivity__c", "relationships": []},
        {"label": "implantSite",               "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "implantSite__c",               "relationships": []},
        {"label": "indication",                "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "indication__c",                "relationships": []},
        {"label": "patientID",                 "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "patientID__c",                 "relationships": []},
        {"label": "patientName",               "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "patientName__c",               "relationships": []},
        {"label": "procedure",                 "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "procedure__c",                 "relationships": []},
        {"label": "procedureNarrative",        "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "procedureNarrative__c",        "relationships": []},
        {"label": "Process Id",                "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "ProcessId__c",                 "relationships": []},
        {"label": "Process Timestamp",         "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "ProcessTimestamp__c",          "relationships": []},
        {"label": "raLeadImpedance",           "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "raLeadImpedance__c",           "relationships": []},
        {"label": "raSensing",                 "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "raSensing__c",                 "relationships": []},
        {"label": "raThreshold",               "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "raThreshold__c",               "relationships": []},
        {"label": "rvLeadImpedance",           "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "rvLeadImpedance__c",           "relationships": []},
        {"label": "rvSensing",                 "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "rvSensing__c",                 "relationships": []},
        {"label": "rvThreshold",               "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "rvThreshold__c",               "relationships": []},
        {"label": "ventricularLeadModel",      "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "ventricularLeadModel__c",      "relationships": []},
        {"label": "ventricularLeadPosition",   "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "ventricularLeadPosition__c",   "relationships": []},
        {"label": "ventricularLeadSerial",     "relatedDmoName": "<DAI_PATIENT_OP_SOURCE_DMO>", "relatedDmoFieldName": "ventricularLeadSerial__c",     "relationships": []}
      ]
    }
  }
  }
```

Capture from the response:
- `result.name` (top-level, `1Cx_` prefix) → `RETRIEVER_NAME` — **use this for all subsequent GET calls**
- `result.id` → `RETRIEVER_ID`

> **IMPORTANT:** The top-level `name` (`1Cx_` prefix) is the parent identifier used for GET/verify.
> The nested `activeConfiguration.name` (`1Cy_` prefix) is a config version only — do NOT use it in GET calls.

**If creation fails:**
- First call `d360_retriever_list` again to check if the retriever was silently created before reporting an error.
- If found → use that retriever's `name` and proceed to Step 8.
- If not found → report the full error verbatim and stop.

---

## Step 8 — Verify Retriever

```
mcp__salesforce-data360__execute
  toolName: d360_retriever_get
  paramsJson: {"retrieverIdOrName": "<RETRIEVER_NAME>"}
```

Confirm from the response:
- `isActive: true`
- `outputFields` count = 35

If either check fails → report the discrepancy to the user and stop.

---

## Step 9 — Final Report

```text
✅ Document AI Setup Complete!

Org:            <ORG_ALIAS>
Instance:       <INSTANCE_URL>

📋 Document AI Configuration
   Config ID:      <CONFIG_ID>
   Runtime Status: Ready

📋 Search Index
   Search Index ID: <SEARCH_INDEX_ID>
   Name:            DAI_Patient_OP
   Status:          READY

📋 Retriever
   Retriever Name:  <RETRIEVER_NAME>
   Retriever ID:    <RETRIEVER_ID>
   Source DMO:      DAI_Patient_OP__dlm
   Output Fields:   35
   Status:          Active and Verified

Channel (Steps 4–8): salesforce-data360 MCP
         d360_search_index_create → d360_search_index_get → d360_retriever_create → d360_retriever_get

🔗 Test in Retriever Playground:
   Setup → Retriever Playground → Select "DAI Patient OP Retriever"
```

---

## Cleanup

Delete any temp files created during this skill run:

```bash
rm -f /tmp/search_index_payload.json
```

---

## Error Reference

| Error | Cause | Fix |
|---|---|---|
| `invalid_grant` on Steps 4–8 | data360 MCP not authenticated | Re-run `/mcp-setup` |
| `DAI_Patient_OP__dlm` not found | Step 2 Document AI config not complete | Check Step 2 succeeded and the DMO was created |
| Search index `Failed` status | Platform error during index build | Check Setup → Data Cloud → Search Indexes, delete and retry |
| Search index timeout | Index taking longer than 30 min | Check Setup → Data Cloud → Search Indexes manually, retry once READY |
| Duplicate retriever | Retriever already created | List retrievers, report existing `name` and stop |
| `ITEM_NOT_FOUND` on Step 8 GET | Used `1Cy_` config name instead of `1Cx_` parent `name` | Use `result.name` (top-level) from Step 7 response |

---

## Notes

- Never hardcode credentials — always derive `ACCESS_TOKEN` from `sf org display --json`.
- API version `v67.0` for Document AI endpoints.
- All Steps 1–3 depend on `ACCESS_TOKEN` and `INSTANCE_URL` captured in Step 1.
- DMO naming uses `__dlm` suffix (Data Lake Model), not `__c`.
- The data360 MCP server (Steps 4–8) is bound to the org via `/mcp-setup` — `ORG_ALIAS` does NOT control which org is targeted by MCP calls.
- `DAI_Patient_OP__dlm` is the fixed DMO API name — same across all orgs, created by the Document AI configuration in Step 2.
- Steps 4–8 write NO temp files — all operations go through the data360 MCP tool directly.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"document-ai"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.document-ai` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
