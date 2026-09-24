---
name: prompt-template-add-retriever
description: "Automate adding Einstein retrievers to AI prompt templates using Salesforce CLI. Queries org for retriever API names via REST API, updates prompt template XML files with correct retriever references, increments version numbers, and deploys to org. NO browser automation, CLI-only workflow. Use when user wants to add retrievers to prompt templates, update prompt templates with retrievers, or configure AI prompt template retrievers."
---

# prompt-template-add-retriever

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"prompt-template-add-retriever"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: prompt-template-add-retriever already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Automate the process of adding Einstein retrievers to AI prompt templates using Salesforce CLI commands.

**✅ CLI-ONLY SOLUTION**

This skill automates the complete retriever configuration process for prompt templates. It queries the org for actual retriever API names, updates XML files with correct references, increments version numbers, and deploys the changes.

**Critical Constraints:**
- ❌ Do NOT generate JavaScript files
- ❌ Do NOT generate Playwright scripts
- ❌ Do NOT use browser automation
- ✅ Use Salesforce CLI commands ONLY
- ✅ **Execute ALL commands sequentially** - wait for each to complete before proceeding
- ✅ **Query org for retriever API names** - never hardcode retriever names
- 📸 **Screenshot Policy**: N/A - This is a CLI-only skill with no browser automation

**Complete Workflow (substitute → deploy → rollback):**
1. Query org for retriever API names via REST API
2. Match retrievers by label name (File_ADL_Pacemaker_Impla, DAI Patient OP Retriever, File_ADL_Patient_Clinici)
3. Read current prompt template files and extract version numbers
4. Update Monitor_Troubleshoot_Support with File_ADL_Pacemaker_Impla retriever (substitute placeholder)
5. Update Post_Implant_Care with File_ADL_Pacemaker_Impla retriever (substitute placeholder)
6. Update PacemakerDetailsForGuest with File_ADL_Pacemaker_Impla retriever (substitute placeholder)
7. Update DeviceRegulatoryInfo with File_ADL_Pacemaker_Impla retriever (substitute placeholder)
8. Update HomeMonitorSetupGuide with File_ADL_Pacemaker_Impla retriever (substitute placeholder)
9. Update WarrantyDurationDetails with File_ADL_Pacemaker_Impla retriever (substitute placeholder)
10. Update Patient_Implant_Op_Prompt with DAI Patient OP Retriever (substitute placeholder)
11. Update PatientSummary60Days with File_ADL_Patient_Clinici retriever (substitute placeholder)
12. Update Patient30DaysSummary with DAI Patient OP Retriever AND File_ADL_Patient_Clinici retrievers (substitute both placeholders)
13. Deploy all 9 MedTech templates to org
14. **🚨 ROLLBACK to placeholders ONLY IF deploy succeeded** — restore the literal placeholder strings, revert version numbers, remove the inserted EinsteinSearch templateDataProviders blocks. Keeps repo org-agnostic and idempotent.

**🚨 PLACEHOLDER PATTERN (org-agnostic repo):**

The repo files ship with placeholder strings, NOT real retriever IDs. Each run:
- Substitutes placeholder → real retriever name (org-specific 1Cx_* parent name)
- Deploys to org
- ON SUCCESS: rolls back the file edits to restore placeholders
- ON FAILURE: leaves files dirty so the user can debug what was about to deploy

This means:
- The repo never has org-specific IDs committed
- Re-running the skill always finds `ADL_PACEMAKER_IMPLANT` etc. — Edit tool's `old_string` always matches
- Different orgs (sandbox, prod) all start from the same placeholder baseline

**Placeholders in the repo:**
| File | Placeholder string(s) |
|---|---|
| Monitor_Troubleshoot_Support | `ADL_PACEMAKER_IMPLANT` (1 occurrence) |
| Post_Implant_Care | `ADL_PACEMAKER_IMPLANT` (1 occurrence) |
| PacemakerDetailsForGuest | `ADL_PACEMAKER_IMPLANT` (1 occurrence) |
| DeviceRegulatoryInfo | `ADL_PACEMAKER_IMPLANT` (1 occurrence) |
| HomeMonitorSetupGuide | `ADL_PACEMAKER_IMPLANT` (1 occurrence) |
| WarrantyDurationDetails | `ADL_PACEMAKER_IMPLANT` (1 occurrence) |
| Patient_Implant_Op_Prompt | `DAI_PATIENT_OP` (1 occurrence) |
| PatientSummary60Days | `ADL_PATIENT_CLINIC` (1 occurrence) |
| Patient30DaysSummary | `DAI_PATIENT_OP` (1 occurrence), `ADL_PATIENT_CLINIC` (1 occurrence) |

The MedTech templates ship with an active Apex `<templateDataProviders>` block (or no block at all) — there are no commented-out EinsteinSearch blocks. The skill inserts a fresh EinsteinSearch `<templateDataProviders>` block during substitution and removes it entirely during rollback.

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username
- `template_directory` (optional): Path to prompt templates directory. Defaults to "ps-post-pack/main/default/genAiPromptTemplates"

---

## Preconditions

Before running:

- Salesforce CLI authenticated with target org
- User has System Administrator profile or equivalent permissions
- Einstein retrievers must exist in the org:
  - **File_ADL_Pacemaker_Impla**
  - **DAI Patient OP Retriever**
  - **File_ADL_Patient_Clinici**
- Prompt template files exist in the specified directory:
  - Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - Post_Implant_Care.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - WarrantyDurationDetails.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - PatientSummary60Days.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
  - Patient30DaysSummary.genAiPromptTemplate-meta.xml (in ps-post-pack/main/default/genAiPromptTemplates)
- SF CLI project structure is valid (sfdx-project.json exists)
- The Data360 repository is already cloned locally and Claude Code is launched from its root (no git clone needed)

---

## Workflow

**CRITICAL EXECUTION RULES:**

1. ✅ **ALWAYS execute commands sequentially** - wait for each to complete
2. ✅ **Query org for retriever API names first** - never hardcode names
3. ✅ **Extract version numbers** before updating files
4. ✅ **Use Edit tool** to update XML (never Write tool on existing files)
5. ✅ **Increment version numbers** for all templates
6. ✅ **Wait for deployment** to complete before reporting success

**Step Execution Order:**
```
Step 0: Verify repository and template files exist
   ↓
Step 1: Query org for retriever API names via REST API
   ↓
Step 2: Parse retriever API names by label
   ↓
Step 3: Read current prompt template files
   ↓
Step 4: Update Monitor_Troubleshoot_Support template (File_ADL_Pacemaker_Impla retriever)  ← MANDATORY
          - PRESERVE the existing apex://getStructuredData block
   ↓
Step 4.1: Update Post_Implant_Care template (File_ADL_Pacemaker_Impla retriever)  ← MANDATORY
          - No existing templateDataProviders block — insert fresh
   ↓
Step 4.2: Update PacemakerDetailsForGuest template (File_ADL_Pacemaker_Impla retriever)  ← MANDATORY
          - No existing templateDataProviders block — insert fresh
   ↓
Step 4.3: Update DeviceRegulatoryInfo template (File_ADL_Pacemaker_Impla retriever)  ← MANDATORY
          - No existing templateDataProviders block — insert fresh
   ↓
Step 4.4: Update HomeMonitorSetupGuide template (File_ADL_Pacemaker_Impla retriever)  ← MANDATORY
           - PRESERVE the existing apex://getStructuredData block
   ↓
Step 4.5: Update WarrantyDurationDetails template (File_ADL_Pacemaker_Impla retriever)  ← MANDATORY
           - PRESERVE the existing apex://getStructuredData block
   ↓
Step 4.6: Update Patient_Implant_Op_Prompt template (DAI Patient OP Retriever)  ← MANDATORY
          - PRESERVE the existing apex://PulseSyncUtil block
   ↓
Step 4.7: Update PatientSummary60Days template (File_ADL_Patient_Clinici retriever)  ← MANDATORY
          - PRESERVE the existing apex://getStructuredData block
   ↓
Step 4.8: Update Patient30DaysSummary template (DAI Patient OP Retriever + File_ADL_Patient_Clinici retriever)  ← MANDATORY
          - PRESERVE the existing apex://getSmmarizePatientDetails block
   ↓
Step 5: Deploy all 9 MedTech templates to org
   ↓
Step 5.5: 🚨 ROLLBACK to placeholders (ONLY on deploy success)
          - Restore placeholder strings (ADL_PACEMAKER_IMPLANT, etc.)
          - Revert version numbers (_12 → _11, _10 → _9, etc.)
          - Remove the inserted EinsteinSearch templateDataProviders blocks
          - On deploy FAILURE: skip rollback, leave files dirty for debugging
   ↓
Step 6: Generate final completion report
```

---

### Step 0 — Verify repository and template files exist

**CRITICAL: Check all required files before starting**

Check if template directory exists:

```bash
ls "{template_directory}"
```

Verify all template files exist:

```bash
ls "ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml"
ls "ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml"
```

**If any file is missing:**
- Report error: "Required template file not found: [file_path]"
- List available files in the directory
- Stop execution

**If all files exist:**
- Report: "✅ All required template files verified"
- Continue to Step 1

---

### Step 1 — Query org for retriever API names via `salesforce-headless-360` MCP

**CRITICAL: Get actual retriever API names from org via the `salesforce-headless-360` MCP server. NO `sf data query`, NO `sf org display | jq -r '.result.accessToken'`, NO `curl`.**

The Data Cloud Retrievers Connect endpoint (`/services/data/v67.0/ssot/machine-learning/retrievers`) is a plain HTTP GET that the `salesforce-headless-360` MCP server handles natively — it injects the org's OAuth token, hits the org's My Domain URL, and returns parsed JSON. There is no need to hand-extract an access token or shell out to `curl`.

**Note on SObject SOQL alternatives:** `EinsteinSearchRetriever` is NOT a real SObject in modern Data Cloud orgs — attempting `SELECT ... FROM EinsteinSearchRetriever` via `sf data query` or the `salesforce-sobject-all` MCP returns `sObject type 'EinsteinSearchRetriever' is not supported`. The Connect API endpoint is the only correct source for retriever `label` + version-suffixed `name` values. Use `salesforce-headless-360` `dispatch_readonly`.

**Tool call:**

```
mcp__salesforce-headless-360__dispatch_readonly
  url: /services/data/v67.0/ssot/machine-learning/retrievers
  method: GET
```

The `url` is a relative Connect API path — pass it verbatim, do NOT prepend the org host. The MCP server resolves the host from the authenticated session.

**Expected `body` shape (returned as `status_code: 200`, JSON in `body`):**

```json
{
  "retrievers": [
    {
      "id": "1Cxhg00000000knCAA",
      "name": "File_PacemakerImplantGuide_1Cx_kwh8363957c",
      "label": "File_PacemakerImplantGuide",
      "activeConfiguration": { "isActive": true, ... },
      ...
    },
    { "name": "DAI_Patient_OP_Retriever_1Cx_...", "label": "DAI Patient OP Retriever", ... },
    { "name": "File_PatientClinicianDischargeAndInterro_1Cx_...", "label": "File_PatientClinicianDischargeAndInterro", ... },
    ...
  ],
  "totalSize": 7
}
```

**Note on retriever labels vs. Step 2 match rules:** the label strings the org actually returns are `File_PacemakerImplantGuide`, `DAI Patient OP Retriever`, and `File_PatientClinicianDischargeAndInterro` — NOT `File_ADL_Pacemaker_Impla` / `File_ADL_Patient_Clinici`. Step 2's fuzzy match rules ("label starts with `File_` AND label contains `PacemakerImplant`" etc.) are designed for exactly this case and match correctly. Do NOT hard-code label equality.

**If the MCP call fails:**
- Report error: "❌ Could not query retrievers via `salesforce-headless-360` MCP"
- Check that the four hosted Standard MCPs are registered and authenticated (`/mcp-setup` must have run against this org)
- Verify with `python3 -c "import json,pathlib; d=json.loads(pathlib.Path.home().joinpath('.claude.json').read_text()); print('salesforce-headless-360' in d.get('mcpServers',{}))"`
- Suggest: re-run `/mcp-setup <org_alias>` — this refreshes the MCP OAuth token
- Stop execution

**If the MCP call succeeds:**
- Capture the parsed JSON body (`body.retrievers`) for parsing
- Continue to Step 2

---

### Step 2 — Parse retriever API names by label

**CRITICAL: Extract API names for each retriever by matching label**

Parse the JSON response to extract API names (DeveloperName or name field) for:

**Retriever 1: Pacemaker ADL**
- Match rule: label starts with `File_` AND label contains `Pacemaker_Impla` OR `PacemakerImplant` in the middle or at the end (not at the very start after `File_` prefix)
- Extract: `name` field value
- Store in variable: `file_adl_pacemaker_retriever_api_name`

**Retriever 2: DAI Patient OP Retriever**
- Search for: `"label": "DAI Patient OP Retriever"`
- Extract: `name` field value
- Store in variable: `dai_patient_op_retriever_api_name`

**Retriever 3: Patient Clinician ADL**
- Match rule: label starts with `File_` AND label contains `Patient_Clinici` OR `PatientClinician` in the middle or at the end (not at the very start after `File_` prefix)
- Extract: `name` field value
- Store in variable: `file_adl_patient_clinici_retriever_api_name`

**If any retriever not found:**
- Report error: "❌ Required retriever not found: [label_name]"
- List all available retrievers from JSON response
- Suggest creating missing retrievers first
- Stop execution

**If all retrievers found:**
- Report: "✅ Retrieved API names:"
  - File_ADL_Pacemaker_Impla: {file_adl_pacemaker_retriever_api_name}
  - DAI Patient OP Retriever: {dai_patient_op_retriever_api_name}
  - File_ADL_Patient_Clinici: {file_adl_patient_clinici_retriever_api_name}
- Continue to Step 3

---

### Step 3 — Read current prompt template files

**Read all template files to extract current version identifiers:**

**CRITICAL: Extract the FULL `activeVersionIdentifier` value as-is from the file — do NOT assume any format. The value may be a simple name like `Monitor_Troubleshoot_Support_2` or a hash-based identifier like `Ekk3YHLs3rO/uHnUAkPFDLsTgfQE4u/XXlsB6BS2Hgc=_2`. Always read what is actually in the file.**

**For each file:**
1. Read the full value between `<activeVersionIdentifier>` tags → store as `{template}_current_identifier`
2. Split on the last `_` → extract the number at the end → store as `{template}_current_version`
3. Build next identifier → replace only the `_N` suffix with `_N+1` → store as `{template}_next_identifier`

**File 1: Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml
```

- Store full identifier: `monitor_current_identifier` (e.g. `Ekk3YHLs3rO/uHnUAkPFDLsTgfQE4u/XXlsB6BS2Hgc=_2`)
- Store version number: `monitor_current_version` (e.g. `2`)
- Build next identifier: `monitor_next_identifier` (e.g. `Ekk3YHLs3rO/uHnUAkPFDLsTgfQE4u/XXlsB6BS2Hgc=_3`)

**File 2: Post_Implant_Care.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml
```

- Store full identifier: `post_implant_current_identifier`
- Store version number: `post_implant_current_version`
- Build next identifier: `post_implant_next_identifier`

**File 3: PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml
```

- Store full identifier: `pacemaker_guest_current_identifier`
- Store version number: `pacemaker_guest_current_version`
- Build next identifier: `pacemaker_guest_next_identifier`

**File 4: DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml
```

- Store full identifier: `device_regulatory_current_identifier`
- Store version number: `device_regulatory_current_version`
- Build next identifier: `device_regulatory_next_identifier`

**File 5: HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml
```

- Store full identifier: `home_monitor_guide_current_identifier`
- Store version number: `home_monitor_guide_current_version`
- Build next identifier: `home_monitor_guide_next_identifier`

**File 6: WarrantyDurationDetails.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml
```

- Store full identifier: `warranty_duration_current_identifier`
- Store version number: `warranty_duration_current_version`
- Build next identifier: `warranty_duration_next_identifier`

**File 7: Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml
```

- Store full identifier: `patient_implant_op_current_identifier`
- Store version number: `patient_implant_op_current_version`
- Build next identifier: `patient_implant_op_next_identifier`

**File 8: PatientSummary60Days.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml
```

- Store full identifier: `patient_summary_60_current_identifier`
- Store version number: `patient_summary_60_current_version`
- Build next identifier: `patient_summary_60_next_identifier`

**File 9: Patient30DaysSummary.genAiPromptTemplate-meta.xml**

```
Tool: Read
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml
```

- Store full identifier: `patient_30_days_current_identifier`
- Store version number: `patient_30_days_current_version`
- Build next identifier: `patient_30_days_next_identifier`

**If version identifier cannot be extracted:**
- Report error: "❌ Cannot parse version identifier from: [filename]"
- Show current activeVersionIdentifier value
- Stop execution

**If all versions extracted successfully:**
- Report: "✅ Current version identifiers:"
  - Monitor_Troubleshoot_Support: `{monitor_current_identifier}`
  - Post_Implant_Care: `{post_implant_current_identifier}`
  - PacemakerDetailsForGuest: `{pacemaker_guest_current_identifier}`
  - DeviceRegulatoryInfo: `{device_regulatory_current_identifier}`
  - HomeMonitorSetupGuide: `{home_monitor_guide_current_identifier}`
  - WarrantyDurationDetails: `{warranty_duration_current_identifier}`
  - Patient_Implant_Op_Prompt: `{patient_implant_op_current_identifier}`
  - PatientSummary60Days: `{patient_summary_60_current_identifier}`
  - Patient30DaysSummary: `{patient_30_days_current_identifier}`
- Continue to Step 4

---

### Step 4 — Update Monitor_Troubleshoot_Support template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Pacemaker_Impla (parent name from API query — uses `1Cx_*` prefix)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{monitor_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{monitor_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{monitor_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{monitor_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PACEMAKER_IMPLANT` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml
old_string: ADL_PACEMAKER_IMPLANT
new_string: {!$EinsteinSearch:{file_adl_pacemaker_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**CRITICAL: The existing `apex://getStructuredData` templateDataProviders block MUST be preserved.** Insert the new EinsteinSearch block BEFORE the existing Apex block:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_pacemaker_retriever_api_name}</definition>
    <description>File_ADL_Pacemaker_Impla</description>
    <label>File_ADL_Pacemaker_Impla</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_pacemaker_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update Monitor_Troubleshoot_Support template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ Monitor_Troubleshoot_Support updated: version _{monitor_current_version} → _{monitor_current_version + 1}"
- Report: "  Retriever: {file_adl_pacemaker_retriever_api_name}"
- Continue to Step 4.1

---

### Step 4.1 — Update Post_Implant_Care template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Pacemaker_Impla (same retriever as Monitor_Troubleshoot_Support)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{post_implant_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{post_implant_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{post_implant_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{post_implant_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PACEMAKER_IMPLANT` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml
old_string: ADL_PACEMAKER_IMPLANT
new_string: {!$EinsteinSearch:{file_adl_pacemaker_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**NOTE: This template has NO existing templateDataProviders block.** Insert before `</templateVersions>`:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_pacemaker_retriever_api_name}</definition>
    <description>File_ADL_Pacemaker_Impla</description>
    <label>File_ADL_Pacemaker_Impla</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_pacemaker_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update Post_Implant_Care template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ Post_Implant_Care updated: version _{post_implant_current_version} → _{post_implant_current_version + 1}"
- Report: "  Retriever: {file_adl_pacemaker_retriever_api_name}"
- Continue to Step 4.2

---

### Step 4.2 — Update PacemakerDetailsForGuest template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Pacemaker_Impla (same retriever as Monitor_Troubleshoot_Support and Post_Implant_Care)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{pacemaker_guest_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{pacemaker_guest_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{pacemaker_guest_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{pacemaker_guest_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PACEMAKER_IMPLANT` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml
old_string: ADL_PACEMAKER_IMPLANT
new_string: {!$EinsteinSearch:{file_adl_pacemaker_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**NOTE: This template has NO existing templateDataProviders block.** Insert before `</templateVersions>`:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_pacemaker_retriever_api_name}</definition>
    <description>File_ADL_Pacemaker_Impla</description>
    <label>File_ADL_Pacemaker_Impla</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_pacemaker_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update PacemakerDetailsForGuest template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ PacemakerDetailsForGuest updated: version _{pacemaker_guest_current_version} → _{pacemaker_guest_current_version + 1}"
- Report: "  Retriever: {file_adl_pacemaker_retriever_api_name}"
- Continue to Step 4.3

---

### Step 4.3 — Update DeviceRegulatoryInfo template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Pacemaker_Impla (same retriever as Monitor_Troubleshoot_Support, Post_Implant_Care, PacemakerDetailsForGuest)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{device_regulatory_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{device_regulatory_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{device_regulatory_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{device_regulatory_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PACEMAKER_IMPLANT` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml
old_string: ADL_PACEMAKER_IMPLANT
new_string: {!$EinsteinSearch:{file_adl_pacemaker_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**NOTE: This template has NO existing templateDataProviders block.** Insert before `</templateVersions>`:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_pacemaker_retriever_api_name}</definition>
    <description>File_ADL_Pacemaker_Impla</description>
    <label>File_ADL_Pacemaker_Impla</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_pacemaker_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update DeviceRegulatoryInfo template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ DeviceRegulatoryInfo updated: version _{device_regulatory_current_version} → _{device_regulatory_current_version + 1}"
- Report: "  Retriever: {file_adl_pacemaker_retriever_api_name}"
- Continue to Step 4.4

---

### Step 4.4 — Update HomeMonitorSetupGuide template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Pacemaker_Impla (same retriever as other MedTech templates)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{home_monitor_guide_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{home_monitor_guide_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{home_monitor_guide_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{home_monitor_guide_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PACEMAKER_IMPLANT` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml
old_string: ADL_PACEMAKER_IMPLANT
new_string: {!$EinsteinSearch:{file_adl_pacemaker_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**CRITICAL: The existing `apex://getStructuredData` templateDataProviders block MUST be preserved.** Insert the new EinsteinSearch block BEFORE the existing Apex block:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_pacemaker_retriever_api_name}</definition>
    <description>File_ADL_Pacemaker_Impla</description>
    <label>File_ADL_Pacemaker_Impla</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_pacemaker_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update HomeMonitorSetupGuide template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ HomeMonitorSetupGuide updated: version _{home_monitor_guide_current_version} → _{home_monitor_guide_current_version + 1}"
- Report: "  Retriever: {file_adl_pacemaker_retriever_api_name}"
- Continue to Step 4.5

---

### Step 4.5 — Update WarrantyDurationDetails template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Pacemaker_Impla (same retriever as other MedTech templates)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{warranty_duration_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{warranty_duration_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{warranty_duration_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{warranty_duration_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PACEMAKER_IMPLANT` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml
old_string: ADL_PACEMAKER_IMPLANT
new_string: {!$EinsteinSearch:{file_adl_pacemaker_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**CRITICAL: The existing `apex://getStructuredData` templateDataProviders block MUST be preserved.** Insert the new EinsteinSearch block BEFORE the existing Apex block:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_pacemaker_retriever_api_name}</definition>
    <description>File_ADL_Pacemaker_Impla</description>
    <label>File_ADL_Pacemaker_Impla</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_pacemaker_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update WarrantyDurationDetails template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ WarrantyDurationDetails updated: version _{warranty_duration_current_version} → _{warranty_duration_current_version + 1}"
- Report: "  Retriever: {file_adl_pacemaker_retriever_api_name}"
- Continue to Step 4.6

---

### Step 4.6 — Update Patient_Implant_Op_Prompt template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml`

**Retriever:** DAI Patient OP Retriever (parent name from API query — uses `1Cx_*` prefix)

**Operation 1: Increment version identifiers**
(both activeVersionIdentifier and versionIdentifier)

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{patient_implant_op_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{patient_implant_op_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{patient_implant_op_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{patient_implant_op_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `DAI_PATIENT_OP` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml
old_string: DAI_PATIENT_OP
new_string: {!$EinsteinSearch:{dai_patient_op_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block BEFORE existing apex://PulseSyncUtil block**

**CRITICAL: The existing `apex://PulseSyncUtil` templateDataProviders block MUST be preserved.** Insert the new EinsteinSearch block BEFORE the existing Apex block:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{dai_patient_op_retriever_api_name}</definition>
    <description>DAI Patient OP Retriever</description>
    <label>DAI Patient OP Retriever</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}{!$Input:Id}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;deviceModel&quot;,&quot;deviceSerial&quot;,&quot;implantSite&quot;,&quot;patientName&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{dai_patient_op_retriever_api_name}</referenceName>
</templateDataProviders>
```


**If Edit fails:**
- Report error: "❌ Failed to update Patient_Implant_Op_Prompt template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ Patient_Implant_Op_Prompt updated: version _{patient_implant_op_current_version} → _{patient_implant_op_current_version + 1}"
- Report: "  Retriever: {dai_patient_op_retriever_api_name}"
- Continue to Step 4.7

---

### Step 4.7 — Update PatientSummary60Days template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml`

**Retriever:** File_ADL_Patient_Clinici (parent name from API query — uses `1Cx_*` prefix)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{patient_summary_60_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{patient_summary_60_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{patient_summary_60_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{patient_summary_60_next_identifier}</versionIdentifier>
```

**Operation 2: Replace `ADL_PATIENT_CLINIC` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml
old_string: ADL_PATIENT_CLINIC
new_string: {!$EinsteinSearch:{file_adl_patient_clinici_retriever_api_name}.results}
```

**Operation 3: Insert new EinsteinSearch `<templateDataProviders>` block**

**CRITICAL: The existing `apex://getStructuredData` templateDataProviders block MUST be preserved.** Insert the new EinsteinSearch block BEFORE the existing Apex block:

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_patient_clinici_retriever_api_name}</definition>
    <description>File_ADL_Patient_Clinici</description>
    <label>File_ADL_Patient_Clinici</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_patient_clinici_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update PatientSummary60Days template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ PatientSummary60Days updated: version _{patient_summary_60_current_version} → _{patient_summary_60_current_version + 1}"
- Report: "  Retriever: {file_adl_patient_clinici_retriever_api_name}"
- Continue to Step 4.8

---

### Step 4.8 — Update Patient30DaysSummary template (MANDATORY — do NOT skip)

**File path:** `ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml`

**Retrievers:** DAI Patient OP Retriever AND File_ADL_Patient_Clinici (both parent names from API query — use `1Cx_*` prefix)

**Operation 1: Increment version identifiers (both `<activeVersionIdentifier>` and `<versionIdentifier>`)**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml
old_string: <activeVersionIdentifier>{patient_30_days_current_identifier}</activeVersionIdentifier>
new_string: <activeVersionIdentifier>{patient_30_days_next_identifier}</activeVersionIdentifier>
```

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml
old_string: <versionIdentifier>{patient_30_days_current_identifier}</versionIdentifier>
new_string: <versionIdentifier>{patient_30_days_next_identifier}</versionIdentifier>
```

**Operation 2a: Replace `DAI_PATIENT_OP` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml
old_string: DAI_PATIENT_OP
new_string: {!$EinsteinSearch:{dai_patient_op_retriever_api_name}.results}
```

**Operation 2b: Replace `ADL_PATIENT_CLINIC` placeholder in `<content>`**

```
Tool: Edit
file_path: ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml
old_string: ADL_PATIENT_CLINIC
new_string: {!$EinsteinSearch:{file_adl_patient_clinici_retriever_api_name}.results}
```

**Operation 3: Insert TWO new EinsteinSearch `<templateDataProviders>` blocks BEFORE existing apex://getSmmarizePatientDetails block**

**CRITICAL: The existing `apex://getSmmarizePatientDetails` templateDataProviders block MUST be preserved.** Insert both new EinsteinSearch blocks BEFORE the existing Apex block.

**Block 1 — DAI Patient OP Retriever (no outputFieldNames):**

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{dai_patient_op_retriever_api_name}</definition>
    <description>DAI Patient OP Retriever</description>
    <label>DAI Patient OP Retriever</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Id}</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{dai_patient_op_retriever_api_name}</referenceName>
</templateDataProviders>
```

**Block 2 — File_ADL_Patient_Clinici (outputFieldNames: Chunk):**

```xml
<templateDataProviders>
    <definition>invocable://getEinsteinRetrieverResults/{file_adl_patient_clinici_retriever_api_name}</definition>
    <description>File_ADL_Patient_Clinici</description>
    <label>File_ADL_Patient_Clinici</label>
    <parameters>
        <definition>primitive://String</definition>
        <isRequired>true</isRequired>
        <parameterName>searchText</parameterName>
        <valueExpression>{!$Input:Question}</valueExpression>
    </parameters>
    <parameters>
        <definition>primitive://List&lt;String&gt;</definition>
        <isRequired>false</isRequired>
        <parameterName>outputFieldNames</parameterName>
        <valueExpression>[&quot;Chunk&quot;]</valueExpression>
    </parameters>
    <referenceName>EinsteinSearch:{file_adl_patient_clinici_retriever_api_name}</referenceName>
</templateDataProviders>
```

**If Edit fails:**
- Report error: "❌ Failed to update Patient30DaysSummary template"
- Show current XML content
- Stop execution

**If Edit succeeds:**
- Report: "✅ Patient30DaysSummary updated: version _{patient_30_days_current_version} → _{patient_30_days_current_version + 1}"
- Report: "  Retrievers: {dai_patient_op_retriever_api_name} AND {file_adl_patient_clinici_retriever_api_name}"
- Continue to Step 4.9

---

### Step 4.9 — Verify all 9 files contain correct `{!$EinsteinSearch:` expressions (MANDATORY before deploy)

After completing Steps 4–4.8, run this verification grep before proceeding to deploy:

```bash
grep -l "{!:" ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml \
  ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml \
  2>/dev/null && echo "❌ BROKEN EXPRESSIONS FOUND" || echo "✅ No broken expressions"
```

**If output is `✅ No broken expressions`** → proceed to Step 5 (deploy).

**If output is `❌ BROKEN EXPRESSIONS FOUND`** → the `{!$EinsteinSearch:` expression was corrupted to `{!:` in one or more files. Fix each affected file immediately using the Edit tool before deploying:

```
Tool: Edit
file_path: <affected file>
old_string: {!:<retriever_api_name>.results}
new_string: {!$EinsteinSearch:<retriever_api_name}.results}
```

Re-run the grep verification after fixing. Only proceed to Step 5 when zero files contain `{!:`.

**DO NOT proceed to deploy with broken `{!:` expressions** — the deploy will succeed but retrievers will not be wired as blue resource references in Prompt Builder.

---

### Step 5 — Deploy all 9 MedTech templates to org

Use `--metadata` flags to deploy the MedTech templates:

```bash
sf project deploy start \
  --metadata "GenAiPromptTemplate:Monitor_Troubleshoot_Support" \
  --metadata "GenAiPromptTemplate:Post_Implant_Care" \
  --metadata "GenAiPromptTemplate:PacemakerDetailsForGuest" \
  --metadata "GenAiPromptTemplate:DeviceRegulatoryInfo" \
  --metadata "GenAiPromptTemplate:HomeMonitorSetupGuide" \
  --metadata "GenAiPromptTemplate:WarrantyDurationDetails" \
  --metadata "GenAiPromptTemplate:Patient_Implant_Op_Prompt" \
  --metadata "GenAiPromptTemplate:PatientSummary60Days" \
  --metadata "GenAiPromptTemplate:Patient30DaysSummary" \
  --target-org {org_alias} \
  --wait 10
```

Wait for deployment to complete (1-2 minutes).

**Expected output:**
```
Status: Succeeded
Components: 9/9 (100%)
Deploy ID: 0Af...
```

**If deployment fails for any reason:**
- Report full error message
- Check XML validity
- Stop execution

**If deployment succeeds:**
- Report: "✅ All 9 MedTech prompt templates deployed successfully"
- Report Deploy ID for reference
- Continue to Step 5.4 (post-deploy verification — mandatory) before Step 5.5 rollback

**If deployment result is ambiguous** (`sf project deploy start` timed out, exit code non-zero without a clear failure payload, or the CLI returned but the local JSON is truncated/unreadable):
- Do NOT re-run `sf project deploy start`. A blind retry would try to deploy the same 9 templates twice; on many orgs that produces version-conflict errors and hides the real deploy status.
- Do NOT enter Step 5.5 rollback yet.
- Perform a read reconciliation first: query the org's Tooling API `DeployRequest` for the most recent deploy attempt against these 9 templates and decide from its authoritative status.

```bash
ACCESS_TOKEN=$(sf org display --target-org {org_alias} --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")
INSTANCE_URL=$(sf org display --target-org {org_alias} --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")

curl -s -G -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "q=SELECT Id, Status, NumberComponentsDeployed, NumberComponentsTotal, NumberComponentErrors, CreatedDate FROM DeployRequest ORDER BY CreatedDate DESC LIMIT 1" \
  "$INSTANCE_URL/services/data/v62.0/tooling/query"
```

Decide from the org's row:
- `Status = Succeeded` AND `NumberComponentErrors = 0` → treat as success; proceed to Step 5.4.
- `Status = InProgress` / `Pending` → wait 60 s and re-query the same row; do NOT re-deploy.
- `Status = Failed` → treat as deterministic failure; STOP; do NOT retry (a real failure needs the user to inspect `componentFailures[]`, not a blind re-deploy).

---

### Step 5.4 — Post-deploy verification (Salesforce-side, org-authoritative)

Prove all 9 templates deployed with the expected content by querying the org — do NOT infer success from the CLI's `Status: Succeeded` JSON alone.

```bash
ACCESS_TOKEN=$(sf org display --target-org {org_alias} --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")
INSTANCE_URL=$(sf org display --target-org {org_alias} --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")

# Query Tooling API for the 9 GenAiPromptTemplate records this skill just deployed.
curl -s -G -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "q=SELECT DeveloperName, MasterLabel FROM GenAiPromptTemplate WHERE DeveloperName IN ('Monitor_Troubleshoot_Support','Post_Implant_Care','PacemakerDetailsForGuest','DeviceRegulatoryInfo','HomeMonitorSetupGuide','WarrantyDurationDetails','Patient_Implant_Op_Prompt','PatientSummary60Days','Patient30DaysSummary')" \
  "$INSTANCE_URL/services/data/v62.0/tooling/query"
```

**Expected manifest — 9 templates by DeveloperName:**

1. `Monitor_Troubleshoot_Support`
2. `Post_Implant_Care`
3. `PacemakerDetailsForGuest`
4. `DeviceRegulatoryInfo`
5. `HomeMonitorSetupGuide`
6. `WarrantyDurationDetails`
7. `Patient_Implant_Op_Prompt`
8. `PatientSummary60Days`
9. `Patient30DaysSummary`

**Pass condition:** the Tooling API row set contains all 9 DeveloperName values. `totalSize == 9`.

**Fail behavior:**
- `totalSize < 9` → identify the missing DeveloperName(s), report each by name, STOP the skill. Do NOT proceed to Step 5.5 rollback (leaving files dirty helps the user debug the actual missing template).
- Any Tooling API error → surface verbatim, STOP.

Only after this Step passes (all 9 templates present, expected manifest reconciled) does the skill enter Step 5.5.

---

### Step 5.5 — Rollback to placeholders (ONLY on deploy success)

**🚨 THIS STEP IS MANDATORY ON DEPLOY SUCCESS — DO NOT SKIP.**

The repo must remain org-agnostic. After confirming the deploy succeeded, reverse every Edit operation from Steps 4-4.5 so the files return to their placeholder state. This makes future runs idempotent.

**Precondition:** Deploy in Step 5 reported `Status: Succeeded`. If deploy failed, skip this step entirely — leave the files dirty so the user can inspect what was about to deploy.

**For each of the 9 MedTech template files, reverse the 3 Edit operations:**

**C. Rollback Monitor_Troubleshoot_Support:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_pacemaker_retriever_api_name>.results}
new_string: ADL_PACEMAKER_IMPLANT
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block entirely (the `apex://getStructuredData` block must remain).

**CRITICAL: The `apex://getStructuredData` templateDataProviders block must NOT be removed — only the EinsteinSearch block added in Step 4 gets removed.**

**D. Rollback Post_Implant_Care:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_pacemaker_retriever_api_name>.results}
new_string: ADL_PACEMAKER_IMPLANT
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block entirely (this template has no other blocks — after rollback it should have no templateDataProviders block).

**E. Rollback PacemakerDetailsForGuest:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_pacemaker_retriever_api_name>.results}
new_string: ADL_PACEMAKER_IMPLANT
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block entirely (this template has no other blocks — after rollback it should have no templateDataProviders block).

**F. Rollback DeviceRegulatoryInfo:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_pacemaker_retriever_api_name>.results}
new_string: ADL_PACEMAKER_IMPLANT
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block entirely (this template has no other blocks — after rollback it should have no templateDataProviders block).

**G. Verify all placeholders are restored:**

```bash
echo "=== Placeholder verification ==="
grep -E "(activeVersionIdentifier|ADL_PACEMAKER_IMPLANT|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|ADL_PACEMAKER_IMPLANT|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/Post_Implant_Care.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|ADL_PACEMAKER_IMPLANT|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|ADL_PACEMAKER_IMPLANT|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|ADL_PACEMAKER_IMPLANT|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|ADL_PACEMAKER_IMPLANT|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/WarrantyDurationDetails.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|DAI_PATIENT_OP|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|ADL_PATIENT_CLINIC|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/PatientSummary60Days.genAiPromptTemplate-meta.xml" | head -3
grep -E "(activeVersionIdentifier|DAI_PATIENT_OP|ADL_PATIENT_CLINIC|EinsteinSearch:)" "ps-post-pack/main/default/genAiPromptTemplates/Patient30DaysSummary.genAiPromptTemplate-meta.xml" | head -5
```

Expected output: each file shows the placeholder string (`ADL_PACEMAKER_IMPLANT`, `DAI_PATIENT_OP`, or `ADL_PATIENT_CLINIC`) and the original version number.

If verification fails for any file, report: `❌ Rollback verification failed for {filename} — manual cleanup required` and continue to Step 6 with a warning. The org has the deployed version regardless; only the local repo state is dirty.

If verification passes:
- Report: "✅ Rollback complete — all 9 MedTech templates restored to placeholder state"
- Continue to Step 6

**H. Rollback HomeMonitorSetupGuide:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_pacemaker_retriever_api_name>.results}
new_string: ADL_PACEMAKER_IMPLANT
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block. The `apex://getStructuredData` block must remain intact.

**I. Rollback WarrantyDurationDetails:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_pacemaker_retriever_api_name>.results}
new_string: ADL_PACEMAKER_IMPLANT
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block. The `apex://getStructuredData` block must remain intact.

**J. Rollback Patient_Implant_Op_Prompt:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<dai_patient_op_retriever_api_name>.results}
new_string: DAI_PATIENT_OP
```

Revert version numbers back to original.

Remove inserted EinsteinSearch `<templateDataProviders>` block. The `apex://PulseSyncUtil` block must remain intact.


**K. Rollback PatientSummary60Days:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_patient_clinici_retriever_api_name>.results}
new_string: ADL_PATIENT_CLINIC
```

Revert version numbers back to original.

Remove the inserted EinsteinSearch `<templateDataProviders>` block. The `apex://getStructuredData` block must remain intact.

**L. Rollback Patient30DaysSummary:**

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<dai_patient_op_retriever_api_name>.results}
new_string: DAI_PATIENT_OP
```

```
Tool: Edit (replace_all: true)
old_string: {!$EinsteinSearch:<file_adl_patient_clinici_retriever_api_name>.results}
new_string: ADL_PATIENT_CLINIC
```

Revert version numbers back to original.

Remove BOTH inserted EinsteinSearch `<templateDataProviders>` blocks (the DAI Patient OP block and the File_ADL_Patient_Clinici block). The `apex://getSmmarizePatientDetails` block must remain intact.

---

---

### Step 6 — Generate final completion report

Generate comprehensive completion report:

```text
✅ Prompt Template Retrievers Updated and Deployed!

Org: {org_alias}
Instance: {instanceUrl}

═══════════════════════════════════════════════════

📋 Templates Updated:

1. ✅ Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml
   Version: _{monitor_current_version} → _{monitor_current_version + 1}
   Retriever: File_ADL_Pacemaker_Impla
   API Name: {file_adl_pacemaker_retriever_api_name}
   Status: Deployed

2. ✅ Post_Implant_Care.genAiPromptTemplate-meta.xml
   Version: _{post_implant_current_version} → _{post_implant_current_version + 1}
   Retriever: File_ADL_Pacemaker_Impla
   API Name: {file_adl_pacemaker_retriever_api_name}
   Status: Deployed

3. ✅ PacemakerDetailsForGuest.genAiPromptTemplate-meta.xml
   Version: _{pacemaker_guest_current_version} → _{pacemaker_guest_current_version + 1}
   Retriever: File_ADL_Pacemaker_Impla
   API Name: {file_adl_pacemaker_retriever_api_name}
   Status: Deployed

4. ✅ DeviceRegulatoryInfo.genAiPromptTemplate-meta.xml
   Version: _{device_regulatory_current_version} → _{device_regulatory_current_version + 1}
   Retriever: File_ADL_Pacemaker_Impla
   API Name: {file_adl_pacemaker_retriever_api_name}
   Status: Deployed

5. ✅ HomeMonitorSetupGuide.genAiPromptTemplate-meta.xml
   Version: _{home_monitor_guide_current_version} → _{home_monitor_guide_current_version + 1}
   Retriever: File_ADL_Pacemaker_Impla
   API Name: {file_adl_pacemaker_retriever_api_name}
   Status: Deployed

6. ✅ WarrantyDurationDetails.genAiPromptTemplate-meta.xml
   Version: _{warranty_duration_current_version} → _{warranty_duration_current_version + 1}
   Retriever: File_ADL_Pacemaker_Impla
   API Name: {file_adl_pacemaker_retriever_api_name}
   Status: Deployed

7. ✅ Patient_Implant_Op_Prompt.genAiPromptTemplate-meta.xml
   Version: _{patient_implant_op_current_version} → _{patient_implant_op_current_version + 1}
   Retriever: DAI Patient OP Retriever
   API Name: {dai_patient_op_retriever_api_name}
   Status: Deployed

8. ✅ PatientSummary60Days.genAiPromptTemplate-meta.xml
   Version: _{patient_summary_60_current_version} → _{patient_summary_60_current_version + 1}
   Retriever: File_ADL_Patient_Clinici
   API Name: {file_adl_patient_clinici_retriever_api_name}
   Status: Deployed

9. ✅ Patient30DaysSummary.genAiPromptTemplate-meta.xml
   Version: _{patient_30_days_current_version} → _{patient_30_days_current_version + 1}
   Retrievers: DAI Patient OP Retriever AND File_ADL_Patient_Clinici
   API Names: {dai_patient_op_retriever_api_name} AND {file_adl_patient_clinici_retriever_api_name}
   Status: Deployed

═══════════════════════════════════════════════════

🔗 Verify Prompt Templates:

1. Navigate to: Setup → Einstein Search → Prompt Templates
2. Verify new versions appear for all 9 MedTech templates
3. Check retriever connections are correct
4. Test templates with sample queries

═══════════════════════════════════════════════════

📊 Deployment Details:

Deploy ID: {deploy_id}
Deployed Components: 9
Status: Success

═══════════════════════════════════════════════════

✅ All prompt templates updated with retrievers successfully!

Next: Test prompt templates in Agentforce Agent configuration.
```

---

## Important Rules

**CRITICAL - Execution Sequence:**
- 🚨 **ALWAYS execute commands sequentially** - wait for each to complete
- 🚨 **Query org for retriever API names first** - never hardcode
- 🚨 **Wait for deployment to complete** before reporting success
- 🚨 **Do NOT run commands in parallel** - must be sequential

**CRITICAL - Retriever Mapping:**
- ✅ **Monitor_Troubleshoot_Support** uses File_ADL_Pacemaker_Impla Retriever
- ✅ **Post_Implant_Care** uses File_ADL_Pacemaker_Impla Retriever
- ✅ **PacemakerDetailsForGuest** uses File_ADL_Pacemaker_Impla Retriever
- ✅ **DeviceRegulatoryInfo** uses File_ADL_Pacemaker_Impla Retriever
- ✅ **HomeMonitorSetupGuide** uses File_ADL_Pacemaker_Impla Retriever
- ✅ **WarrantyDurationDetails** uses File_ADL_Pacemaker_Impla Retriever
- ✅ **Patient_Implant_Op_Prompt** uses DAI Patient OP Retriever
- ✅ **PatientSummary60Days** uses File_ADL_Patient_Clinici Retriever
- ✅ **Patient30DaysSummary** uses DAI Patient OP Retriever AND File_ADL_Patient_Clinici Retriever
- ✅ **Always query org** for actual API names - never hardcode

**CRITICAL - Version Management:**
- ✅ **Always read current version** before updating
- ✅ **Increment both** activeVersionIdentifier and versionIdentifier
- ✅ **Version numbers must match** between both tags

**CRITICAL - XML Editing:**
- ✅ **Always use Edit tool** to update existing XML (never Write)
- ✅ **Preserve XML formatting** and indentation
- ✅ **Update all three references**: content placeholder, definition, referenceName
- ✅ **Verify XML is valid** after each edit

**CRITICAL - CLI Commands:**
- ✅ **ONLY use Salesforce CLI** - no browser automation
- ✅ **Change to repo directory** before deploy commands
- ✅ **Wait for API responses** before parsing
- ✅ **Capture command output** for error reporting

**General Rules:**
- NEVER generate JavaScript files
- NEVER write automation scripts to disk.
- NEVER hardcode retriever API names - always query org
- NEVER skip version increment
- NEVER deploy without verifying all edits succeeded
- NEVER proceed to deploy if any template file contains `{!:` — this is a broken EinsteinSearch expression; fix it to `{!$EinsteinSearch:` using the Edit tool before deploying (Step 4.9 is the mandatory verification gate)
- ALWAYS report errors with full context
- ALWAYS provide actionable error messages
- Estimated time: 2-5 minutes for complete workflow

---

## Example Usage

### Example 1: Basic template update

**User:** "Add retrievers to prompt templates in <YOUR_ORG_ALIAS>"

**Skill:**
1. Verifies template files exist
2. Queries org for retrievers via `salesforce-headless-360` MCP `dispatch_readonly` → `GET /services/data/v67.0/ssot/machine-learning/retrievers`
3. Parses API names:
   - File_ADL_Pacemaker_Impla → `File_ADL_Pacemaker_Impla_1Cx_abc123`
   - DAI Patient OP Retriever → `DAI_Patient_OP_Retriever_1Cx_xyz789`
4. Reads current versions:
   - Monitor_Troubleshoot_Support: _3
   - Post_Implant_Care: _2
   - PacemakerDetailsForGuest: _1
   - DeviceRegulatoryInfo: _1
   - HomeMonitorSetupGuide: _2
   - WarrantyDurationDetails: _1
   - Patient_Implant_Op_Prompt: _1
5. Updates all 7 MedTech templates with incremented versions and appropriate retrievers
6. Deploys all 7 templates: `sf project deploy start --metadata ...`
7. Reports completion with Deploy ID

---

### Example 2: Error handling - Retriever not found

**User:** "Add retrievers to prompt templates in TestOrg"

**Skill:** [Queries retrievers via API]

**Error:** `Required retriever not found: File_ADL_Pacemaker_Impla`

**Skill:**
```text
❌ Required Retriever Not Found

Org: TestOrg

Missing Retriever: File_ADL_Pacemaker_Impla

Available Retrievers:
- Product_Individual_Retriever_V2_1 (label: Product Individual)
- Another_Retriever_V1 (label: Another)

Suggested Fix:
1. Verify Einstein retrievers are created in Data Cloud
2. Check retriever labels match exactly:
   - "File_ADL_Pacemaker_Impla"
3. Navigate to: Setup → Einstein Search → Retrievers
4. Create missing retrievers if needed
5. Retry skill execution

Cannot proceed without all required retrievers.
```

---

### Example 3: Error handling - Version parsing failed

**User:** "Add retrievers to prompt templates in ProdOrg"

**Skill:** [Reads template files]

**Error:** `Cannot parse version number from: Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml`

**Skill:**
```text
❌ Version Number Parsing Failed

Org: ProdOrg

File: Monitor_Troubleshoot_Support.genAiPromptTemplate-meta.xml

Current activeVersionIdentifier:
<activeVersionIdentifier>Monitor_Troubleshoot_Support</activeVersionIdentifier>

Expected Format:
<activeVersionIdentifier>Monitor_Troubleshoot_Support_3</activeVersionIdentifier>

Suggested Fix:
1. Check if template file has version number suffix (_11, _12, etc.)
2. Auto-add version number if missing using Edit tool
3. Verify XML structure is valid
4. Retry skill execution

Cannot proceed without valid version numbers.
```

---

## Success Criteria

Prompt template update is successful when:

✅ Repository and template files verified
✅ REST API call to retrieve retrievers succeeded
✅ File_ADL_Pacemaker_Impla retriever API name extracted
✅ DAI Patient OP Retriever API name extracted
✅ File_ADL_Patient_Clinici retriever API name extracted
✅ Current version numbers extracted from all 9 MedTech templates
✅ Monitor_Troubleshoot_Support updated with incremented version and File_ADL_Pacemaker_Impla retriever
✅ Post_Implant_Care updated with incremented version and File_ADL_Pacemaker_Impla retriever
✅ PacemakerDetailsForGuest updated with incremented version and File_ADL_Pacemaker_Impla retriever
✅ DeviceRegulatoryInfo updated with incremented version and File_ADL_Pacemaker_Impla retriever
✅ HomeMonitorSetupGuide updated with incremented version and File_ADL_Pacemaker_Impla retriever
✅ WarrantyDurationDetails updated with incremented version and File_ADL_Pacemaker_Impla retriever
✅ Patient_Implant_Op_Prompt updated with incremented version and DAI Patient OP Retriever
✅ PatientSummary60Days updated with incremented version and File_ADL_Patient_Clinici retriever
✅ Patient30DaysSummary updated with incremented version and both DAI Patient OP Retriever and File_ADL_Patient_Clinici retrievers
✅ All templates deployed successfully to org
✅ Comprehensive completion report provided

---

## Notes

- Version numbers are automatically incremented for each template
- File_ADL_Pacemaker_Impla Retriever is used by 6 of the 9 MedTech templates; DAI Patient OP Retriever is used by Patient_Implant_Op_Prompt and Patient30DaysSummary; File_ADL_Patient_Clinici is used by PatientSummary60Days and Patient30DaysSummary; Patient30DaysSummary uses TWO retrievers (DAI Patient OP and File_ADL_Patient_Clinici)
- Retriever API names are queried from org - never hardcoded
- Always verify deployment success before considering update complete
- Templates must have version numbers in format: `{TemplateName}_{version}`
- REST API endpoint requires Data Cloud provisioning to be complete

---

## Cleanup temp artifacts (MANDATORY before next skill)

Before declaring this skill complete, delete every temporary file/folder created during the run.

**Failure handling rule:**
- If the deploy fails (Step 5), **do NOT clean up** — leave the modified template files dirty for inspection.
- Fix the underlying issue, retry the deploy, then perform Step 5.5 (rollback to placeholders) AND this cleanup.
- Step 5.5 (placeholder restore in repo) is a SEPARATE concern from this temp cleanup; both must run after a successful deploy.

**Files this skill creates and must delete:**

```bash
rm -f /c/tmp/prompt_deploy.json
```

**Verification (must report no remaining prompt-template scratch):**

```bash
ls /c/tmp/prompt_deploy.json 2>&1 | grep -v "cannot access"
```

**Rules:**
- ✅ Only delete the files listed above. The 9 MedTech prompt-template XMLs are repo source — Step 5.5 handles their rollback.
- ❌ Skipping this step is not allowed once deploy succeeded and rollback is verified.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"prompt-template-add-retriever"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.prompt-template-add-retriever` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
