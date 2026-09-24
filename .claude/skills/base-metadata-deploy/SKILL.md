---
name: base-metadata-deploy
description: Deploy base MedTech Solution Kit metadata using Salesforce CLI + salesforce-sobject-all MCP. Clones repo if needed, deploys ps-base metadata, assigns permission sets, activates price books, and imports sample data. Before each sample-data insert, Step 6.1a runs a natural-key dedup guard that deletes any pre-existing records in the org that match the incoming record (Account by Name, Person Account by FirstName+LastName+IsPersonAccount, Contact by name+email, Product2 by Name, PricebookEntry by Pricebook+Product, etc.) — this prevents duplicate rows that stock trial orgs ship with (e.g., three Accounts with the same name after re-runs). Standard Pricebook, users, profiles, and record types are never touched. Set SKIP_DEDUP=1 to disable the guard. CLI + MCP workflow with no browser automation and no Apex script execution. (The Clinical Care Coordinator user seed formerly here has moved to agent-setup-configuration Step 6b, since its Profile + UserRole ship in ps-post-pack, not ps-base.)
---

# base-metadata-deploy

## Purpose

Deploy base metadata for the Data360 Healthcare MedTech Solution Kit using a mix of Salesforce CLI and the currently-authenticated Salesforce hosted MCP servers (`salesforce-sobject-all`, `salesforce-headless-360`), with each channel scoped by the rule below.

**Channel rule (authoritative):**
- ✅ Salesforce CLI (`sf project deploy start`, `sf project deploy report`, `sf org display`, etc.) is used for metadata / deploy / file-oriented operations that are explicitly documented as CLI (Step 2 async deploy + polling, Step 2.5 stuck-deploy sweep via `sf org display` for the token, temp-file lifecycle in `/tmp/`).
- ✅ Salesforce MCP servers are used for the steps explicitly documented as MCP: `salesforce-sobject-all` for `getUserInfo` / `soqlQuery` / `getObjectSchema` / `updateSobjectRecord` / `deleteSobjectRecord` / `createSobjectRecord` (Steps 0.5, 1a-PSL, 1a, 3, 3.4, 3.5, 5, 6, 6b); `salesforce-headless-360` `dispatch_readonly` for FieldDefinition GETs (Step 3.6) and for Step 11's single-row `ValidationRule` `Metadata` GET + verification GET; `salesforce-headless-360` `dispatch` for the composite POST inserts (Step 6.1c) and Step 11's `ValidationRule` `Metadata` PATCH. Step 11's **primary** `ValidationRule` filterable lookup runs through the Salesforce CLI (`sf data query --use-tooling-api`) — the MCP `/tooling/query` route has been observed intermittently unsupported, so CLI is primary and MCP `dispatch_readonly` is documented fallback.
- ✅ **Step 6 record mutations use only the approved MCP channels defined in the Step 6 CHANNEL ENFORCEMENT block.** Any other channel (raw HTTP, `sf data tree import`, `sf apex run`, `sf data import bulk`, etc.) is a hard-fail skill violation.
- ❌ No browser automation.
- ❌ No Playwright tools.
- ❌ No JavaScript file generation.
- ✅ Windows PowerShell / Git Bash compatible commands throughout.

**Temporary File Policy (MANDATORY):**
Some steps require creating temporary files (SOQL queries, Apex scripts) to work around CLI limitations on Windows. These files MUST follow strict lifecycle rules:
- ✅ Create temp file ONLY when the step requires it (e.g. SOQL via --file flag for Windows compatibility)
- ✅ Use the file, parse output, extract values
- ✅ DELETE the file IMMEDIATELY after the step completes (`rm <filename>`)
- ✅ Use `/tmp/` paths when possible (auto-cleaned by OS) instead of repo root
- ❌ NEVER leave temporary SOQL/Apex/query files in the repo working tree
- ❌ NEVER skip cleanup, even on failure paths — wrap in try/finally semantics

This skill handles the complete base metadata deployment workflow including metadata deployment, permission set assignment, price book activation, and sample data import.

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username

---

## Preconditions

- Salesforce CLI must be installed
- Target org must be authenticated with Salesforce CLI
- Git must be installed (for cloning repository if needed)
- User must have System Administrator profile or equivalent permissions
- Windows PowerShell environment
- **IMPORTANT:** For uninterrupted execution, Salesforce CLI commands should be pre-approved in `.claude/settings.json`:
  ```json
  {
    "permissions": {
      "allow": [
        "bash:sf *"
      ]
    }
  }
  ```
  Without this, each `sf` command will prompt for approval, significantly slowing down deployment.

---

## Workflow

### Step 0-DS — Durable state read (mandatory, first action in this skill)

Before any other Step 0 work, this skill reads the shared durable state file so it can cooperate with the parent installer's orchestration and any prior skills' outputs.

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator), or the parent is on an older workflow. Continue as if this were a first-time run. Log a warning: `state file missing — proceeding without durable-state coordination`. At end of the run, Step N-final will create the file from scratch.

3. **If the file exists AND `<this-skill-name>` (`base-metadata-deploy`) is already in `state.completedSkills`** — a prior invocation *claimed* success. That is a checkpoint, not proof: durable state is only a cache; the Salesforce org is the source of truth. Run a lightweight critical-condition reconciliation against the org before deciding whether to no-op or fall through into the standard resume path:

   **Step 0-DS.a — Lightweight critical-condition reconciliation (reuses existing gate logic, no new framework).**

   Execute each check below using the same MCP tool the corresponding downstream step already uses (`mcp__salesforce-sobject-all__getUserInfo`, `mcp__salesforce-sobject-all__soqlQuery`). If a check requires a value cached later in the skill (e.g. `<userId>` for permset queries), call `getUserInfo` here to obtain it — the same call Step 0.5.1 makes:

   | Check | Query (reuses existing step's shape) | Required outcome |
   |---|---|---|
   | Running user identity resolvable | `getUserInfo` | Non-empty `identity.userId` |
   | ps-base fingerprint (permset + fields) | `SELECT Id FROM PermissionSet WHERE Name = 'PulseSyncBasePS' LIMIT 1` **AND** `SELECT COUNT(Id) c FROM FieldDefinition WHERE EntityDefinition.QualifiedApiName = 'Contact' AND QualifiedApiName IN ('License_Number__c','Battery_Score__c','Pacing_Performance_Score__c','Unified_Individual_Id__c','Atrial_Risk_Score__c','Last_Transmission__c')` — same as Step 0.5.2's Step-2-done fingerprint | permset exists; `c == 6` |
   | PulseSyncBasePS assigned to running user | `SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '<userId>' AND PermissionSet.Name = 'PulseSyncBasePS' LIMIT 1` — same as Step 0.5.2's Step-3-done check | one row |
   | Standard Pricebook active | `SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1` — same as Step 0.5.2's Step-5-done check | `IsActive = true` |
   | Sample-data landmark record present (Step 6 landed) | `SELECT COUNT(Id) c FROM Account WHERE Name = 'PulseSync Medical Device Clinic'` — same as Step 0.5.2's sample-data probe | `c >= 1` |
   | Data Cloud copy-field permissions (Step 6b landed) | `SELECT Field FROM FieldPermissions WHERE ParentId IN (SELECT Id FROM PermissionSet WHERE Label = 'Customer 360 Data Platform Integration') AND SobjectType = 'Contact' AND Field IN ('Contact.Last_Transmission__c','Contact.Battery_Score__c','Contact.Pacing_Performance_Score__c','Contact.Unified_Individual_Id__c','Contact.Atrial_Risk_Score__c')` — same as Step 0.5.2's Step-6b-done check | 5 rows, all with Read+Edit=true |

   These are the *same* checks Step 0.5 already runs; Step 0-DS.a executes just the "critical" subset earlier so a completed-state claim can be verified without triggering the full resume plan.

   **Step 0-DS.b — Decision rule:**

   - ✅ **All critical conditions hold in the org** → log `VERIFIED NO-OP: base-metadata-deploy already complete per state file AND org reconciliation confirmed` and return success. This is the durability guarantee against orchestrator retries when the org matches the claim.
   - ❌ **Any critical condition has drifted** (missing permset, missing custom field, unassigned permset, deactivated Standard Pricebook, missing landmark record, missing copy-field permissions) → log `RECONCILE: state file claims complete, but org has drifted on <condition> — falling through to Step 0.5 resume-state safeguard` and **continue into Step 0.5** as if the state file did not claim completion. Step 0.5's per-step checkpoint queries will figure out precisely which steps need to re-run; Step 6.1a's dedup guard and Step 6.4's SOQL count gate will keep the re-run safe and idempotent.

   Do NOT blindly return success solely because the skill name exists in `completedSkills`. Durable state is only a checkpoint; Salesforce is the source of truth.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory (if present):
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId` (Step 0.5 may refresh this if empty)
   - Nothing from `state.artifacts.base-metadata-deploy` (this skill hasn't written anything yet on this run)

5. **Sanity check:** if this skill's expected prior-skill artifacts are missing (`state.artifacts.mcp-setup` should exist before we run, since the LOCKED SKILL SEQUENCE puts `/mcp-setup` before `/base-metadata-deploy`) — log a warning but do NOT hard-fail. The Salesforce-side MCP registration is the true prerequisite; the state file is a secondary signal.

The state file is the **first** source of truth for cross-skill state. Step 0.5 (later in this skill) is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; update the file at Step N-final.

---

### Step 0 — Check Current Directory (Skip Repository Verification if Already in Repo)

**CRITICAL: Detect the repo by FINGERPRINT in the *current* working directory — never by folder name.**

The repository may live in any folder the user has open in VS Code (e.g. `Downloads/TestSkill`, `Data360MedTechSolutionKit`, a fork, a renamed clone, etc.). Do NOT match on the folder's name. Match on the presence of the repo's required files/folders inside the current working directory.

Check current directory and its fingerprint:

```bash
pwd
test -f "./sfdx-project.json" && test -d "./ps-base" && test -d "./ps-datacloud" && test -d "./scripts" && echo "REPO_OK" || echo "REPO_MISSING"
```

**If the fingerprint check prints `REPO_OK` (regardless of what `pwd` returns):**
- ✅ Report: "Repository detected in current working directory: $(pwd) — skipping repository verification"
- ✅ Skip Step 1 completely
- ✅ Proceed directly to **Step 0.5 (Resume-state safeguard)**. Do NOT skip Step 0.5 — it must run on every invocation, including the very first one, so the checkpoint queries can decide which downstream steps are already done vs pending. Only after Step 0.5 completes may the skill advance to Step 1a-PSL / 1a / 2 as the resume plan dictates.

**If the fingerprint check prints `REPO_MISSING`:**
- Proceed to Step 1 (the agent will clone INTO the current folder). Step 0.5 runs after Step 1 completes.

---

### Step 0.5 — Resume-state safeguard (MANDATORY on every invocation)

**Purpose:** This skill may be invoked against an org that already has partial state from a prior run — either because a previous run hit an MCP timeout (a common outcome on Storm/orgfarm), because the agent was stopped mid-flight, or because the user is intentionally re-running to converge to the desired state. In all three cases, in-memory state (`<userId>`, `<permSetId>`, `<standardPricebookId>`, `refs`, `<install_start_ts>`) does NOT survive across invocations. Rebuild it from the org before advancing to Step 1.

**Do NOT assume a resumed run can continue from wherever it stopped.** Each sub-step below verifies a checkpoint against the org; if the checkpoint holds, mark the step "already done" and skip its DML; if not, run it fresh. The dedup guard (Step 6.1a) makes the fresh-run path safe — a re-executed step will UPDATE existing rows rather than duplicate them.

**Step 0.5.1 — Cache the running user Id.**

```
mcp__salesforce-sobject-all__getUserInfo
```

Cache `identity.userId` as `<userId>` and `identity.username` for the run log. This value replaces whatever was in memory from a prior run.

**Step 0.5.2 — Detect the last successfully completed checkpoint.**

Run the queries below in order. For each, mark the corresponding step as "already done" if the check passes; otherwise leave it pending. Do NOT reorder or short-circuit — a later check passing is not proof that earlier ones did (e.g., a manual patch could have left `PulseSyncBasePS` assigned without ps-base having deployed cleanly).

| Checkpoint | Query | If passes, mark |
|---|---|---|
| Health Cloud PSLs assigned | `SELECT PermissionSetLicense.DeveloperName FROM PermissionSetLicenseAssign WHERE AssigneeId = '<userId>' AND PermissionSetLicense.DeveloperName IN ('HealthCloudGA_HealthCloudPsl','HealthCloudPlatformPsl')` — expect 2 rows | Step 1a-PSL done |
| Health Cloud permsets assigned | `SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE AssigneeId = '<userId>' AND PermissionSet.Name IN ('HealthCloudFoundation','HealthCloudUtilizationManagement','DiseaseSurveillance')` — expect 3 rows | Step 1a done |
| ps-base deployed | **Two-part fingerprint (BOTH parts required to mark Step 2 done):** (a) `SELECT Id FROM PermissionSet WHERE Name = 'PulseSyncBasePS' LIMIT 1` — expect 1 row; (b) `SELECT COUNT(Id) c FROM FieldDefinition WHERE EntityDefinition.QualifiedApiName = 'Contact' AND QualifiedApiName IN ('License_Number__c','Battery_Score__c','Pacing_Performance_Score__c','Unified_Individual_Id__c','Atrial_Risk_Score__c','Last_Transmission__c')` — expect c=6 (via `salesforce-headless-360` dispatch_readonly against `/services/data/v64.0/query`; matches Step 3.6's read of the same endpoint). If PulseSyncBasePS exists but any of the 6 Contact fields is missing, Step 2 must run again: an older ps-base deployment left the permset in place without the current field schema. | Step 2 done ONLY when both (a) and (b) pass |
| PulseSyncBasePS assigned | `SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '<userId>' AND PermissionSet.Name = 'PulseSyncBasePS' LIMIT 1` — expect 1 row | Step 3 done |
| Contact SOQL primary gate | `SELECT Id, License_Number__c, Battery_Score__c, Pacing_Performance_Score__c, Unified_Individual_Id__c, Atrial_Risk_Score__c, Last_Transmission__c FROM Contact LIMIT 1` — expect no INVALID_FIELD | Step 3.5 done |
| Standard Pricebook active | `SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1` — expect IsActive=true | Step 5 done; cache `<standardPricebookId>` |
| Sample data present | `SELECT COUNT(Id) c FROM Account WHERE Name = 'PulseSync Medical Device Clinic'` + one probe per major sObject — see Step 0.5.3 | Step 6 partially or fully done |
| Data Cloud FieldPermissions | `SELECT Field FROM FieldPermissions WHERE ParentId IN (SELECT Id FROM PermissionSet WHERE Label = 'Customer 360 Data Platform Integration') AND SobjectType = 'Contact' AND Field IN ('Contact.Last_Transmission__c','Contact.Battery_Score__c','Contact.Pacing_Performance_Score__c','Contact.Unified_Individual_Id__c','Contact.Atrial_Risk_Score__c')` — expect 5 rows all Read+Edit=true | Step 6b done |
| FSL rule deactivated | Primary channel: `sf data query --target-org <org_alias> --use-tooling-api --query "SELECT Active FROM ValidationRule WHERE EntityDefinition.QualifiedApiName = 'ServiceAppointment' AND ValidationName = 'Schedule_End_Required' AND NamespacePrefix = 'FSL'"` — expect Active=false. Fallback: MCP dispatch_readonly (v66.0). `ValidationName` (not `DeveloperName`). | Step 11 done |

**Step 0.5.3 — Rebuild the `refs` map from the org if Step 6 is partially complete.**

If the sample-data probe finds ANY records from `data/plan.json` but not ALL (i.e., Step 6 was interrupted), rebuild `refs` from the org before re-entering the Step 6 loop. For each `data/*.json` file listed in `plan.json`, in plan order:

1. For each record in the file, compute the natural-key WHERE clause the same way Step 6.1a does (`build_dedup_where` — Name / FirstName+LastName+IsPersonAccount / Subject / composite-key fallback).
2. Query the org: `SELECT Id FROM <sObjectType> WHERE <clause>`.
3. If `totalSize == 1`, populate `refs[referenceId] = row.Id`. This lets downstream records that use `@ref` resolve to the surviving org row instead of blindly re-inserting.
4. If `totalSize == 0`, leave `refs[referenceId]` unset — the record will be inserted fresh when Step 6.1 revisits it.
5. If `totalSize >= 2`, log a warning and adopt the oldest by `CreatedDate` (matches Step 6.1a's survivor-pick rule).

After the rebuild, the `refs` map is a coherent snapshot of the org's current state, and Step 6.1's iteration can proceed idempotently — matching records go through UPDATE, missing ones through INSERT.

**Step 0.5.4 — Capture a fresh `<install_start_ts>` for Step 6.4's post-load count gate.**

The Step 6.4 count gate compares `CreatedDate >= <install_start_ts>`. On a resumed run, the timestamp captured on the previous run is gone; capture a new one now:

```
mcp__salesforce-sobject-all__soqlQuery
  q: "SELECT SystemModstamp x FROM Organization LIMIT 1"
```

Cache the returned value as `<install_start_ts>`. Note: on a resumed run, records inserted in the previous run are now OLDER than this timestamp, so Step 6.4's count-since-start query will UNDER-count. Compensate by widening the check: `CreatedDate >= <install_start_ts> OR Id IN <refs_populated_in_step_0_5_3>`. If that produces false-positive PASS conditions, fall back to the natural-key-per-sObject verification in Step 6.4.

**Step 0.5.5 — Log the resume plan before proceeding.**

```
📋 Resume plan for this invocation:
  Step 1a-PSL:  [already done / to run]
  Step 1a:      [already done / to run]
  Step 2:       [already done / to run]
  Step 2.5:     always runs (sweep is stateless)
  Step 3:       [already done / to run]
  Step 3.4:     always runs (FLS verification)
  Step 3.5:     always runs (SOQL runtime check)
  Step 3.6:     always runs (secondary diagnostic)
  Step 5:       [already done / to run]
  Step 6:       [<n>/127 records already present — will UPDATE existing, INSERT missing]
  Step 6b:      [already done / to run]
  Step 11:      [already done / to run]
```

Surface this plan to the operator before any DML runs. On a first-time install, everything reads "to run"; on a full re-run of a completed org, everything reads "already done" and the skill exits after a clean Step 12 summary.

**Rule of thumb:** every step this skill contains must be idempotent enough that "already done" and "run fresh" produce the same final state. If a step can't satisfy that (e.g., Step 2's deploy is inherently a fresh operation), gate it on the checkpoint check above, don't try to make the DML itself idempotent.

---

### Step 1 — Verify Repository Context

The Data360 installer agent (or the user) must have already ensured cwd is the repo root before this skill runs. Quick sanity check:

```bash
test -f sfdx-project.json && test -d ps-base
```

If either check fails, abort with: `ERROR: not in repo root. Re-invoke the agent so Step 0 can clone or detect the repo.`

Do **not** attempt to clone or `cd` from inside this skill — repo provisioning is handled centrally by the agent.

---

### Step 1a-PSL — Assign Health Cloud Permission Set Licenses to the running user (MCP)

Automates the manual UI flow:
1. Click your avatar → **Settings** → **Advanced User Details** (or **Personal Information**).
2. Scroll to **Permission Set License Assignments** → **Edit Assignments**.
3. Enable **Health Cloud** and **Health Cloud Platform** → **Save**.

Two PSLs must be assigned to the running user BEFORE Step 1a (permission sets) runs — several of the `HealthCloud*` PermissionSets bundled with the Health Cloud managed package will refuse to assign if the running user does not first hold the underlying `HealthCloudGA_HealthCloudPsl` / `HealthCloudPlatformPsl` license. Order matters: **PSL first, then PermissionSet, then metadata deploy.**

> **Channel note:** this step uses the `salesforce-sobject-all` MCP server (same channel as Steps 0.5, 1a, 3, 3.4, 3.5, 5, 6, 6b). Do NOT fall back to any `sf` CLI equivalent — there isn't one for `PermissionSetLicenseAssign` insert on Windows without shelling to Apex.

**Object model (verified via `getObjectSchema`):**
- `PermissionSetLicense` — read-only license definition seeded by the Health Cloud package. Look up its `Id` via SOQL on `DeveloperName`.
- `PermissionSetLicenseAssign` — join row with exactly two required fields: `AssigneeId` (the User Id) and `PermissionSetLicenseId` (the license Id).

**Step 1a-PSL.0 — Confirm target org.**

Call `getUserInfo`. Cache `identity.userId` as `<userId>` (Step 1a will reuse the same cached value). Surface `identity.username` to the user.

**Step 1a-PSL.1 — Iterate the two Health Cloud PSLs.**

For each PSL `DeveloperName` in this list:
- `HealthCloudGA_HealthCloudPsl`   (`MasterLabel = "Health Cloud"`)
- `HealthCloudPlatformPsl`         (`MasterLabel = "Health Cloud Platform"`)

Perform an idempotent existence check followed by an insert if missing:

**Check existing assignment:**

```
soqlQuery:
  SELECT Id
  FROM PermissionSetLicenseAssign
  WHERE AssigneeId = '<userId>'
    AND PermissionSetLicense.DeveloperName = '<PSL DeveloperName>'
  LIMIT 1
```

If a row is returned, the user already holds this license. Continue to the next name — no DML.

**Look up the PSL:**

```
soqlQuery:
  SELECT Id
  FROM PermissionSetLicense
  WHERE DeveloperName = '<PSL DeveloperName>'
    AND Status = 'Active'
  LIMIT 1
```

If this returns zero rows, the Health Cloud managed package is not installed in the target org, or the PSL is not `Active`. Stop this skill and surface which PSL is missing. Do NOT retry: the fix is upstream — install/re-provision Health Cloud licensing — before re-running this skill.

Cache the returned Id as `<pslId>`.

**Insert the assignment:**

```
createSobjectRecord:
  sobject-name: PermissionSetLicenseAssign
  body:
    AssigneeId:              '<userId>'
    PermissionSetLicenseId:  '<pslId>'
```

**Step 1a-PSL.2 — Verify both assignments.**

After the loop, run one confirmation query:

```
soqlQuery:
  SELECT PermissionSetLicense.DeveloperName, PermissionSetLicense.MasterLabel
  FROM PermissionSetLicenseAssign
  WHERE AssigneeId = '<userId>'
    AND PermissionSetLicense.DeveloperName IN
        ('HealthCloudGA_HealthCloudPsl','HealthCloudPlatformPsl')
```

Expect exactly two rows. If either `DeveloperName` is missing, stop and report which PSL didn't stick.

**Success criteria:**
- Two `PermissionSetLicenseAssign` rows exist for `<userId>` covering `HealthCloudGA_HealthCloudPsl` and `HealthCloudPlatformPsl`.
- `<userId>` cached and reused by Step 1a below.

---

### Step 1a — Assign Health Cloud permission sets to the running user (MCP)

Assigns three Health Cloud permission sets (`HealthCloudFoundation`, `HealthCloudUtilizationManagement`, `DiseaseSurveillance`) to the running user via `salesforce-sobject-all` MCP (`soqlQuery` for the PermissionSet Ids, `createSobjectRecord` for each `PermissionSetAssignment`).

The three Health Cloud permission sets are shipped by the Health Cloud managed package, which is installed independently of this skill's metadata deploy. They already exist in the target org before Step 2 runs — that's why this step precedes the deploy. **Step 1a-PSL must have completed first** — several of these PermissionSets require the Health Cloud / Health Cloud Platform license to be held before they can be assigned.

> **Channel note:** this step uses the `salesforce-sobject-all` MCP server (same channel as Steps 0.5, 3, 3.4, 5, 6, 6b). Do NOT fall back to `sf org assign permset` here.

**Step 1a.0 — Confirm target org.**

Reuse `<userId>` cached from Step 1a-PSL.0. (If for some reason it isn't cached — e.g. the skill was resumed mid-run — call `getUserInfo` and cache `identity.userId` here. Step 3 will reuse the same cached value.)

**Step 1a.1 — Iterate the three Health Cloud permission sets.**

For each permission set name in this list:
- `HealthCloudFoundation`
- `HealthCloudUtilizationManagement`
- `DiseaseSurveillance`

Perform an idempotent existence check followed by an insert if missing:

**Check existing assignment:**

```
soqlQuery:
  SELECT Id
  FROM PermissionSetAssignment
  WHERE AssigneeId = '<userId>'
    AND PermissionSet.Name = '<permission set name>'
  LIMIT 1
```

If a row is returned, the user already has this permission set. Continue to the next name — no DML.

**Look up the permission set:**

```
soqlQuery:
  SELECT Id FROM PermissionSet WHERE Name = '<permission set name>' LIMIT 1
```

If this returns zero rows, the Health Cloud managed package is not installed in the target org. Stop this skill and surface which permission set is missing. Do NOT retry: the fix is upstream — install Health Cloud or verify the license — before re-running this skill.

Cache the returned Id as `<permSetId>`.

**Insert the assignment:**

```
createSobjectRecord:
  sobject-name: PermissionSetAssignment
  body:
    AssigneeId:      '<userId>'
    PermissionSetId: '<permSetId>'
```

**Step 1a.2 — Verify all three assignments.**

After the loop, run one confirmation query to make sure all three assignments exist for this user:

```
soqlQuery:
  SELECT PermissionSet.Name
  FROM PermissionSetAssignment
  WHERE AssigneeId = '<userId>'
    AND PermissionSet.Name IN
        ('HealthCloudFoundation','HealthCloudUtilizationManagement','DiseaseSurveillance')
```

Expect three rows. If any of the three names is missing from the result set, stop and report which one didn't stick.

**Success criteria:**
- Three `PermissionSetAssignment` rows exist for `<userId>` covering `HealthCloudFoundation`, `HealthCloudUtilizationManagement`, and `DiseaseSurveillance`.
- Verification query returned exactly three matching rows.
- `<userId>` cached and available for Step 3 to reuse.

---

### Step 2 — Deploy Base Metadata (5–10 min total window, 30-sec poll interval)

**CRITICAL: Skip org authentication verification**

**Reason:** If feature-enablement skill already ran successfully, the org is authenticated and connected. No need to verify again - this wastes time and adds unnecessary checks.

**Proceed directly to deployment without checking org authentication.**

---

#### Step 2a — Kick off the deployment (asynchronous)

Start the deploy in **async mode** so the CLI returns immediately with a Deployment Id. We then poll status ourselves on a fixed 30-second cadence. This is the only way to truthfully tell the user "still running" between checks — `--wait` would block the agent silently.

```bash
sf project deploy start \
  -d ps-base \
  --target-org <org_alias> \
  --async \
  --json > /tmp/ps_base_deploy_kickoff.json
```

Flags:
- `-d ps-base`: Deploy from ps-base directory (one bundled deployment — classes, objects, permsets, layouts, etc., all in one job)
- `--target-org <org_alias>`: Target org
- `--async`: Return immediately with the Deployment Id; do NOT block
- `--json`: Structured output

**Extract the Deployment Id (warning-tolerant parser):**

The Salesforce CLI may prepend a `»   Warning: @salesforce/cli update available…` line before the JSON block. A plain `json.load()` on that file fails with `JSONDecodeError`, which caused a past incident where the agent lost the Deployment Id, treated the kickoff as failed, and re-issued `sf project deploy start` — landing a duplicate deploy against the same org. The regex below extracts the JSON object regardless of pre-JSON noise.

```bash
DEPLOY_ID=$(python3 -c "import json, re; t=open('/tmp/ps_base_deploy_kickoff.json').read(); m=re.search(r'\{.*\}', t, re.DOTALL); d=json.loads(m.group(0)); assert d.get('status')==0, d; print(d['result']['id'])")
echo "Deployment Id: $DEPLOY_ID"
```

If `DEPLOY_ID` is empty or the kickoff JSON has `status != 0`, STOP and report the kickoff error verbatim. Do NOT enter the polling loop. Do NOT re-issue `sf project deploy start` — the CLI may have already submitted the deploy to the org even if the local parse failed; a retry would create a duplicate DeployRequest.

---

#### Step 2b — Polling gate: 5–10 min total window, re-check every 30 seconds (BLOCKING, NON-INTERACTIVE)

**Cadence contract:** the ps-base folder is only **~35 components** and typically deploys in under 30 seconds. The polling gate is designed to catch that fast-path immediately, tolerate a slow deploy up to ~5 minutes without complaint, and hard-stop at 10 minutes. Poll status every **30 seconds** during that window (up to **20 status checks** at 0, 30s, 1m, 1m30s, ... 9m30s). If the deployment is still not in a terminal state at minute 10, exit with a non-zero code and surface the deploy id — do NOT ask the user anything interactively; the parent agent (or user) reads the summary and decides whether to retry. Exit the loop AS SOON as the deployment reaches a terminal state (`Succeeded` / `Failed` / `Canceled`) — no minimum wait.

**Non-interactive contract:** this step MUST NOT open a prompt, MUST NOT invoke `AskUserQuestion`, and MUST NOT block waiting for the user to type anything. On success, proceed to Step 2.5 automatically. On failure or ceiling-hit, exit non-zero with the deploy id printed — the exit code IS the signal.

**HARD RULE — DO NOT PROCEED.** Until this gate prints `✅ Deployment Succeeded`, you MUST NOT:
- run any later step of this skill (Step 2.5 sweep, Step 3 permset assignment, Steps 3.4/3.5/3.6 gates, Step 5 pricebook, Step 6 data load, Step 6b copy-field permissions, Step 11 FSL rule, Step 12 summary)
- invoke any other skill in the installer chain
- run any "while we wait" check, probe, or sample command

The agent's only allowed action between polls is `sleep 30` followed by exactly **one** `sf project deploy report` call. No Connect REST API probes. No SOQL queries. No `ls`. No `cat`. Cadence is fixed — the agent must NOT interactively prompt the user during this loop.

```bash
# Cadence config
POLL_INTERVAL_SECONDS=30         # 30 seconds between status checks — fast enough for ~35-component ps-base
MAX_POLL_MINUTES=10              # hard ceiling — if still not terminal at 10 min, exit non-zero (no user prompt)
ELAPSED=0                        # tracks elapsed seconds (each tick adds POLL_INTERVAL_SECONDS)

while : ; do
    # Re-check deployment status — exactly one call per cycle
    sf project deploy report \
        --job-id "$DEPLOY_ID" \
        --target-org <org_alias> \
        --json > /tmp/ps_base_deploy_status.json

    STATUS=$(python3 -c "import json; print(json.load(open('/tmp/ps_base_deploy_status.json'))['result']['status'])")
    DONE=$(python3 -c "import json; print(json.load(open('/tmp/ps_base_deploy_status.json'))['result'].get('done', False))")
    DEPLOYED=$(python3 -c "import json; print(json.load(open('/tmp/ps_base_deploy_status.json'))['result'].get('numberComponentsDeployed', 0))")
    TOTAL=$(python3 -c "import json; print(json.load(open('/tmp/ps_base_deploy_status.json'))['result'].get('numberComponentsTotal', 0))")
    ERRORS=$(python3 -c "import json; print(json.load(open('/tmp/ps_base_deploy_status.json'))['result'].get('numberComponentErrors', 0))")

    # Format elapsed as [+MmSSs] for display (e.g. [+2m00s])
    ELAPSED_MIN=$((ELAPSED / 60))
    ELAPSED_SEC=$((ELAPSED % 60))
    printf '[+%dm%02ds] status=%s  done=%s  %s/%s  errors=%s\n' \
        "$ELAPSED_MIN" "$ELAPSED_SEC" "$STATUS" "$DONE" "$DEPLOYED" "$TOTAL" "$ERRORS"

    # Terminal states ----------------------------------------------------
    if [ "$STATUS" = "Succeeded" ]; then
        echo "✅ Deployment Succeeded — proceeding to Step 2.5 automatically (no user prompt)"
        break
    fi
    if [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Canceled" ]; then
        echo "❌ Deployment $STATUS — exiting non-zero. Deploy Id: $DEPLOY_ID"
        # Print first 5 component failures (informational, no prompt)
        python3 -c "
import json
d = json.load(open('/tmp/ps_base_deploy_status.json'))['result']
for f in (d.get('details', {}).get('componentFailures') or [])[:5]:
    print('  -', f.get('fullName'), '|', f.get('problem'))
"
        exit 1
    fi

    # Still in progress — check ceiling before sleeping
    MAX_POLL_SECONDS=$((MAX_POLL_MINUTES * 60))
    if [ "$ELAPSED" -ge "$MAX_POLL_SECONDS" ]; then
        echo "⚠️ Deployment still running after ${MAX_POLL_MINUTES} minutes — exiting non-zero. Deploy Id: $DEPLOY_ID"
        exit 2
    fi
    echo "   ↻ Still in progress. Sleeping ${POLL_INTERVAL_SECONDS}s before next check…"
    sleep "$POLL_INTERVAL_SECONDS"
    ELAPSED=$((ELAPSED + POLL_INTERVAL_SECONDS))
done
```

**What "done" means:**
- ✅ `result.status == "Succeeded"` AND `result.done == true` AND `numberComponentErrors == 0` → exit the loop, proceed to Step 2.5 automatically (no prompt).
- ❌ `result.status` ∈ { `Failed`, `Canceled` } → **STOP IMMEDIATELY.** Do NOT move to Step 2.5 or any later step; do NOT invoke the next skill in the installer chain. Print the deploy id, the failed status, and the first 5 component failures to stdout, then exit non-zero. **No interactive `AskUserQuestion` prompt.** The parent installer agent (or the user) reads the exit code + logged deploy id and decides whether to retry.
- ⏳ Anything else (`Pending`, `InProgress`, `Queued`) → sleep 30 seconds, re-poll. No other tool calls in between. No user prompts.

**Failure-stop rule (mandatory, applies even if other rules say "auto-chain"):**

```
IF deployment status is Failed OR Canceled
   OR numberComponentErrors > 0
   OR the loop hit MAX_POLL_MINUTES without reaching a terminal state
THEN
   Exit this skill with a non-zero exit code (no interactive prompt).
   Print the deploy id and failing components to stdout.
   DO NOT call /datakit-api-deploy.
   DO NOT call any other downstream skill.
   DO NOT auto-retry the deploy.
```

The parent installer agent (or the user monitoring the run) uses the non-zero exit + printed deploy id to decide the next action. The skill itself never blocks on an `AskUserQuestion` or similar interactive prompt.

This rule overrides the installer agent's "auto-chain on success" behavior — the chain only auto-advances on **clean** success of this gate.

**Cadence summary the agent prints (typical ps-base deploy completes on the very first poll — Succeeded within 30 seconds):**

```
[+0m00s] status=Succeeded    35/35    errors=0   ✅ Deployment Succeeded — proceeding to Step 2.5 automatically (no user prompt)
```

For a slower run (e.g. a busy org):

```
[+0m00s] status=Pending      0/35     errors=0   ↻ Still in progress. Sleeping 30s before next check…
[+0m30s] status=InProgress   12/35    errors=0   ↻ Still in progress. Sleeping 30s before next check…
[+1m00s] status=InProgress   28/35    errors=0   ↻ Still in progress. Sleeping 30s before next check…
[+1m30s] status=Succeeded    35/35    errors=0   ✅ Deployment Succeeded — proceeding to Step 2.5 automatically (no user prompt)
```

If the deployment is still `InProgress` at the **+10m00s** ceiling, the loop hits `MAX_POLL_SECONDS` and exits with code 2 — the agent surfaces the deploy id in the log and exits non-zero. **No interactive prompt is shown.** The parent installer agent (or the user monitoring the run) uses the exit code + printed deploy id to decide what to do next.

**Why this gate exists (do not skip):**
- Past runs jumped to Step 3 while the deploy was still mid-flight, then mis-reported the deployment as "stuck" because SOQL queries against not-yet-committed metadata returned nothing.
- The user explicitly asked for a 30-second polling cadence with **no other commands running between polls**. That is a hard contract — honor it.
- The gate is the ONLY thing in this skill that may run while the deploy is in flight. Steps 3+ are gated.

Store `$DEPLOY_ID` for the final summary.

---

### Step 2.5 — Sweep stuck/orphan deployments before continuing (MANDATORY GATE)

**Purpose:** After the ps-base deploy reports `Succeeded`, the org may still contain other deployments stuck in `InProgress` / `Pending` / `Canceling` from prior runs (Storm/orgfarm/xDO QBrix bootstrap, earlier installer attempts, etc.). These can hold metadata locks and silently break later steps in the installer chain (especially `datakit-api-deploy`, which fails with `We couldn't retrieve available objects for <orgId>. Try again later.` when the platform thinks a deploy is still mid-flight).

**PRECONDITION (NON-NEGOTIABLE):**
- Step 2's polling gate must have already exited with `✅ Deployment Succeeded` (i.e. our ps-base `$DEPLOY_ID` is in a terminal `Succeeded` state with `numberComponentErrors == 0`).
- If Step 2 has not yet returned `Succeeded`, this step MUST NOT run. **Never sweep mid-deploy.** Cancelling a peer deploy while our own is in flight risks releasing a lock the platform was deliberately holding for our deploy.

**Hard rule (bound by user requirement):**
- ✅ Run AFTER our ps-base deploy is done.
- ✅ Only inspect deploys still in `InProgress` / `Pending` / `Queued` / `Canceling` at that moment.
- ✅ Only cancel a peer deploy if its component list is **clearly not related** to this installer (xDO QBrix bootstrap residue, leftover IndustriesUnifiedPromotions retries, etc.).
- ❌ DO NOT cancel anything that contains ps-base / ps-datacloud / ps-eca / ps-embeddedservice / ps-pd-experience-optional / ps-post-pack components, or anything whose origin you can't classify with confidence.
- ❌ DO NOT proceed to Step 3 (PulseSyncBasePS assignment) or any later step until this gate completes. The gate is mandatory even when the ps-base deploy itself is clean.

**Step 2.5a — Identify all non-terminal DeployRequests OTHER than the one we just ran.**

Important: this query runs ONLY after Step 2 returned `Succeeded`. The `Id != '${DEPLOY_ID}'` clause guarantees we will never touch our own ps-base deploy. If the query returns zero rows, **skip directly to Step 3 (PulseSyncBasePS assignment)** — there is nothing to sweep, no PATCH calls, no logs, no temp files written.

```bash
ACCESS_TOKEN=$(sf org display --target-org <org_alias> --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['accessToken'])")
INSTANCE_URL=$(sf org display --target-org <org_alias> --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['instanceUrl'])")

# DEPLOY_ID is the ps-base deploy from Step 2 — never cancel that one
curl -s -G -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "q=SELECT Id, Status, NumberComponentsTotal, NumberComponentsDeployed, NumberComponentErrors, CreatedDate FROM DeployRequest WHERE Status IN ('InProgress','Pending','Queued','Canceling') AND Id != '${DEPLOY_ID}' ORDER BY CreatedDate ASC" \
  "$INSTANCE_URL/services/data/v62.0/tooling/query" > /tmp/stuck_deploys.json
```

If `totalSize == 0`, no stuck deploys → skip to Step 3.

**Step 2.5b — Inspect each stuck deployment's component list and classify:**

For every stuck deploy, fetch the component detail and decide if it's "irrelevant to this installer" (cancel) or "potentially load-bearing" (surface to user, do NOT auto-cancel):

```bash
python3 -c "
import json
d = json.load(open('/tmp/stuck_deploys.json'))
for r in d['records']:
    print(r['Id'], r['Status'], r['CreatedDate'], 'components=' + str(r['NumberComponentsTotal']))
"
```

For each `STUCK_ID` in that list:

```bash
curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${INSTANCE_URL}/services/data/v62.0/metadata/deployRequest/${STUCK_ID}?includeDetails=true" \
  > /tmp/stuck_${STUCK_ID}.json

python3 <<'PY'
import json, os
sid = os.environ['STUCK_ID']
d = json.load(open(f'/tmp/stuck_{sid}.json'))
det = d.get('deployResult', {}).get('details', {}) or {}
succ = det.get('componentSuccesses') or []
fail = det.get('componentFailures') or []
all_msgs = succ + fail
# Build the deploy fingerprint: distinct (componentType, fullName) pairs, excluding package.xml
fingerprint = sorted({(c.get('componentType','') or '?', c.get('fullName','') or '?')
                       for c in all_msgs
                       if (c.get('fullName') or '') != 'package.xml'})
print(f'--- {sid} ---')
for ct, fn in fingerprint:
    print(f'  {ct}: {fn}')

# Classification rules (extend conservatively — when unsure, surface to user)
IRRELEVANT_PATTERNS = (
    'xDO_Base_QBrix_Register',         # Storm/orgfarm xDO QBrix registry
    'QBrix_',                          # Any QBrix-* CustomMetadata row
    'DemoBrix_',                       # DemoBrix-* CustomMetadata row
    'xDO_',                            # Any xDO-prefixed CustomMetadata
    'IndustriesUnifiedPromotionsSettings',  # already enabled by feature-enablement
)
def is_irrelevant(ct, fn):
    if ct == 'CustomMetadata' and any(p in fn for p in IRRELEVANT_PATTERNS):
        return True
    return False

irrelevant = all(is_irrelevant(ct, fn) for ct, fn in fingerprint) and len(fingerprint) > 0
print(f'  → irrelevant_to_installer = {irrelevant}')
PY
```

**Classification rules (be conservative — false positives are worse than leaving a deploy alone):**

A peer deploy is eligible for auto-cancel ONLY when **every component** in its `componentSuccesses` + `componentFailures` list (excluding `package.xml`) matches one of the IRRELEVANT_PATTERNS. If even ONE component falls outside the irrelevant list, the deploy is treated as load-bearing → surface to user, do not cancel.

| Pattern | Origin | Action |
|---|---|---|
| `CustomMetadata: xDO_Base_QBrix_Register.QBrix_*` / `DemoBrix_*` / `xDO_*` | Storm/orgfarm xDO QBrix bootstrap residue | **Cancel (only if ALL components match)** |
| `IndustriesUnifiedPromotionsSettings: IndustriesUnifiedPromotions` (when feature-enablement already passed) | leftover from feature-enablement retry | **Cancel (only if ALL components match)** |
| Anything matching `ps-base` / `ps-datacloud` / `ps-pd-experience-optional` / `ps-embeddedservice` / `ps-eca` content (CustomField on Account/Contact/Order/Product2/Promotion, ApexClass `PulseSyncUtil`, PermissionSet `PulseSyncBasePS`, DLO/DLM components) | Could be a **prior installer run** that wasn't cleaned up | **DO NOT cancel.** Surface to user. Wait for user instruction. |
| Anything else (managed package install, customer-owned customizations, mixed bundle) | Unknown / load-bearing | **DO NOT cancel.** Surface to user. Wait for user instruction. |

If the deploy has zero components in its details (extremely rare, usually means a fresh `Pending` row that the platform hasn't expanded yet), treat it as **unknown → DO NOT cancel** and wait one more minute, then re-classify. If still empty, surface to user.

**Step 2.5c — Cancel only the irrelevant ones via Tooling/Metadata API:**

```bash
# For each STUCK_ID classified as irrelevant:
curl -s -X PATCH \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "${INSTANCE_URL}/services/data/v62.0/metadata/deployRequest/${STUCK_ID}" \
  -d '{"deployResult":{"status":"Canceling"}}' \
  -w "\nHTTP %{http_code}\n"
```

The platform accepts the request with HTTP 202 and moves the deploy to `Canceling`. Many of these deploys are actually no-ops (component already exists in the org), so the `Canceling` row may sit for a while before Salesforce GC reaps it — that's fine. The platform-level lock the deploy was holding is released as soon as the cancel is accepted.

**Step 2.5d — Verify the cancel was accepted (do NOT wait for terminal `Canceled`):**

```bash
sleep 15
for STUCK_ID in $CANCELED_IDS; do
  curl -s -G -H "Authorization: Bearer $ACCESS_TOKEN" \
    --data-urlencode "q=SELECT Status FROM DeployRequest WHERE Id = '${STUCK_ID}'" \
    "$INSTANCE_URL/services/data/v62.0/tooling/query"
done
```

Acceptable terminal-or-transitional statuses after the cancel: `Canceling`, `Canceled`, `Failed`. Any of those means the lock is released. **Do NOT block on `Canceled` — the platform may take hours to GC the row, but locks are released at `Canceling`.**

**Step 2.5e — If any stuck deploy was classified as "load-bearing":**

```
🛑 STOP — Step 2.5 found a stuck deploy that is NOT clearly irrelevant.

DeployRequest: <stuck_id>
Status:        InProgress
CreatedDate:   <date>
Components:    <n>

Sample components:
  - <componentType>: <fullName>
  - ...

This deploy may be from a prior installer attempt. Auto-cancelling it could
discard work the user wants to keep. Surfacing to the user.

Next step: ask the user whether to cancel this DeployRequest before proceeding.
DO NOT auto-proceed to Step 3 (or any later step).
```

**Step 2.5f — Cleanup temp files (always, even on failure):**

```bash
rm -f /tmp/stuck_deploys.json /tmp/stuck_*.json
```

**Why this gate exists (DO NOT skip):**
- Observed failure: a prior Storm-org bootstrap left DeployRequest `0Afg70000066ukeCAA` (a `CustomMetadata: xDO_Base_QBrix_Register.QBrix_1_xDO_Trialforce` write) stuck in `InProgress` for ~33 hours. While that row sat in flight, the `datakit-api-deploy` POST returned `jobStatus=Error` with the message `We couldn't retrieve available objects for <orgId>. Try again later.` — because the platform thought a deploy was still mid-flight and refused to compute the org's full object catalog for the Data Kit installer.
- Cancelling the orphan released the lock and let `datakit-api-deploy` succeed.
- This gate prevents that failure mode from recurring on every install.

---

> ### Channel change for Steps 0.5, 3, 3.4, 3.5, 5, 6, 6b
>
> These actions have been migrated from Salesforce CLI + Apex to the `salesforce-sobject-all` MCP server (Step 3.6 additionally uses `salesforce-headless-360` for FieldDefinition, and Step 11 uses `salesforce-headless-360` for the `ValidationRule` `Metadata` GET / PATCH / verification GET while its filterable lookup runs through the Salesforce CLI's `--use-tooling-api` route as the documented primary). Inside these steps only, use `mcp__salesforce-sobject-all__*` tools (`getUserInfo`, `soqlQuery`, `getObjectSchema`, `createSobjectRecord`, `updateSobjectRecord`, `deleteSobjectRecord`). Do NOT fall back to `sf org assign permset`, `sf apex run`, `sf data tree import`, or raw REST/Tooling curl inside these steps — those are the legacy commands this migration replaces. If an MCP tool call fails, apply the reconcile-first policy from Step 6.0a (for creates/updates) or retry the same MCP tool once (for reads); do not switch channels. The rest of the skill (Steps 0, 1, 2, 2.5, 11's ValidationRule filterable lookup + final verification re-query, 12) continues to use the CLI.
>
> The MCP server's target org is fixed by whichever org `/mcp-setup` was run against (bound in `.claude/settings.local.json`). It does not accept a per-call org argument. Confirm the target at the start of Step 0.5 via `getUserInfo` before any writes.

---

### Step 3 — Assign `PulseSyncBasePS` to the running user (MCP) — MOVED EARLIER

**Rationale for placement (2026-08-20 sequence revision):** Previously, `PulseSyncBasePS` was assigned in Step 4, AFTER a FieldDefinition-based materialization gate. On Storm/orgfarm orgs, FieldDefinition's metadata reflection cache lags several minutes behind an otherwise-successful Metadata API deploy — the ps-base deploy reports `Succeeded` and `numberComponentErrors=0`, but the 6 Contact custom fields remain invisible to FieldDefinition for 3–10 minutes. The old Step 3 waited up to ~4 min then HARD-FAILED, forcing an out-of-band bypass on every install.

The correct primary signal is **direct Contact SOQL** — the query engine reads the same field metadata the MCP loader will use downstream, and it's not gated by FieldDefinition's reflection cache. But direct Contact SOQL only proves fields exist; it does NOT prove the current user has FLS on them. Assigning `PulseSyncBasePS` first, then verifying FieldPermissions, then running a direct Contact SOQL query gives a single trust chain that all three preconditions hold before Step 6.

**Step 3.0 — Confirm target org (reuses `<userId>` from Step 1a if available).**

If Step 1a already ran, its `getUserInfo` call cached `<userId>` for reuse — skip this sub-step. Otherwise call `getUserInfo` now, surface `identity.username` to the user, and cache `identity.userId` as `<userId>` for the next sub-step.

**Step 3.1 — Idempotent existence check.**

Query for an existing assignment:

```
soqlQuery:
  SELECT Id
  FROM PermissionSetAssignment
  WHERE AssigneeId = '<userId>'
    AND PermissionSet.Name = 'PulseSyncBasePS'
  LIMIT 1
```

If a row is returned, this user already has the permission set. Skip to Step 3.2 — no DML.

**Step 3.2 — Look up the permission set.**

```
soqlQuery:
  SELECT Id FROM PermissionSet WHERE Name = 'PulseSyncBasePS' LIMIT 1
```

If this returns zero rows, the `ps-base/` metadata deploy from Step 2 has not applied cleanly — the `PulseSyncBasePS` permission set is missing. Stop this skill and surface the issue. Do NOT retry: the fix is upstream in the metadata deploy.

Cache the returned Id as `<permSetId>`.

**Step 3.3 — Insert the assignment.**

```
createSobjectRecord:
  sobject-name: PermissionSetAssignment
  body:
    AssigneeId:      '<userId>'
    PermissionSetId: '<permSetId>'
```

On success, the running user now has `PulseSyncBasePS`, which grants FLS to the custom Contact fields (`License_Number__c`, `Last_Transmission__c`, etc.) that Step 6 needs.

**Success criteria:**
- `getUserInfo` returned a valid username for the target org.
- Either an existing assignment was found (idempotent skip), or a new one was created.

---

### Step 3.4 — Verify `PulseSyncBasePS` grants FLS on the 6 required Contact fields (HARD GATE)

Permission set **assigned** ≠ proof that the currently-deployed permission set actually **contains** the FieldPermissions row for every required field. If a prior ps-base deploy shipped an older `PulseSyncBasePS.permissionset-meta.xml` that was missing one of the fields, Step 3.3 will happily succeed while Step 6 later fails with `INVALID_FIELD` on that column. This gate closes that loophole.

```
soqlQuery:
  SELECT Field, PermissionsRead, PermissionsEdit
  FROM FieldPermissions
  WHERE ParentId = '<permSetId>'
    AND SobjectType = 'Contact'
    AND Field IN ('Contact.License_Number__c','Contact.Battery_Score__c',
                  'Contact.Pacing_Performance_Score__c','Contact.Unified_Individual_Id__c',
                  'Contact.Atrial_Risk_Score__c','Contact.Last_Transmission__c')
```

**Expected:** 6 rows, every row with `PermissionsRead = true` AND `PermissionsEdit = true`.

**Decision rule:**
- ✅ 6 rows, all with Read+Edit true → advance to Step 3.5.
- ❌ Any of: fewer than 6 rows, or any row missing Read or Edit → HARD FAIL. `PulseSyncBasePS` in the org is out of date. Re-deploy ps-base (Step 2) with the latest `PulseSyncBasePS.permissionset-meta.xml` in the repo, then re-run this skill.

Do NOT try to patch missing FieldPermissions rows here — the source of truth is the ps-base metadata; patching them at runtime creates drift on the next deploy.

---

### Step 3.5 — Direct Contact SOQL runtime validation (PRIMARY GATE, replaces the FieldDefinition wait)

The Step 2 polling loop already asserted Deploy `Succeeded` and `numberComponentErrors=0`. Step 3.4 just verified the assigned permset grants FLS on all 6 Contact fields. This step adds the third and definitive check: **the fields are queryable via direct Contact SOQL as the running user right now**. That's the exact code path Step 6's MCP loader will use — if this passes, Step 6 will succeed on those columns.

**Step 3.5.1 — Query Contact directly for the 6 fields.**

```
mcp__salesforce-sobject-all__soqlQuery
  q: "SELECT Id, License_Number__c, Battery_Score__c, Pacing_Performance_Score__c, Unified_Individual_Id__c, Atrial_Risk_Score__c, Last_Transmission__c FROM Contact LIMIT 1"
```

The `LIMIT 1` clause ensures the query returns even against an empty Contact table. What matters is not the row count — it's whether SOQL parses and executes without `INVALID_FIELD`. If the query returns `totalSize == 0` because Contact is empty, that's still a PASS: the field metadata parsed cleanly.

**Step 3.5.2 — Decision rule with backoff, then STOP FOR NOW (no auto-redeploy).**

Direct SOQL is the authoritative runtime readiness signal — it uses the same query engine Step 6's MCP loader will hit. But observation from the 2026-08-20 run on `HCStrom14thAug2026Org1` showed direct SOQL/runtime schema propagation can lag several minutes on Storm/orgfarm orgs while Tooling and Metadata API already show the fields as materialized. **The deploy in that case was fine; only the runtime schema cache was slow.** So an INVALID_FIELD after ~60 seconds is NOT proof that the ps-base deploy failed, and this gate MUST NOT trigger an automatic redeploy.

| Attempt | Wait before retry | Cumulative wall-clock |
|---|---|---|
| 1 | 0s | 0s |
| 2 | 15s | 15s |
| 3 | 45s | 60s |

- ✅ Query succeeds (any row count, or empty result) → advance to Step 3.6 (secondary FieldDefinition diagnostic).
- ⏳ SOQL returns `INVALID_FIELD` on one of the 6 columns → sleep the tabled interval, retry.
- 🛑 After attempt 3, STOP FOR NOW — do NOT hard-fail the run in a way that suggests the deploy is broken, and do NOT automatically re-invoke Step 2:
  ```
  ⏸️ Step 3.5 — Contact runtime schema propagation still lagging after ~60s.

  Deploy Id (from Step 2): <DEPLOY_ID>
  Direct SOQL error:       <INVALID_FIELD message from Salesforce>
  Missing column(s):       <list extracted from the error>

  Step 2 reported Succeeded with 0 component errors, and Step 3.4 verified
  PulseSyncBasePS grants FLS on all 6 fields — those signals are intact.
  What's lagging is the runtime SOQL cache; Tooling/Metadata API typically
  see the fields well before the query engine does on Storm/orgfarm orgs.

  Action required (in order):
    1. STOP the current run here. Do NOT start the Step 6 data load.
    2. Do NOT re-invoke Step 2 (ps-base deploy) — the deploy is not the issue.
    3. Wait 3–5 minutes for the runtime cache to propagate.
    4. Re-invoke this skill. Step 0.5's resume-state safeguard will re-check
       every checkpoint, Steps 1a-PSL/1a/2/3 will skip (already done), and
       this Step 3.5 gate will retry the direct SOQL query. If it now passes,
       the run continues into Step 5. If it still lags, wait longer and
       re-invoke again.
    5. Only after multiple re-invocations spanning >30 minutes without
       progress should you consider a fresh ps-base deploy. In practice
       this has never been necessary — the lag always clears on its own.
  ```

Log this as `⏸️ pause`, not `❌ fail`. The exit code MUST signal "stopped for external convergence" to the parent agent (recommended: exit code 3 — distinct from Step 2's exit 1/2 and from Step 6.4's hard-fail), so the installer chain does NOT interpret this as a broken deploy and does NOT loop back into `/base-metadata-deploy` on its own. The operator (or the parent agent, on a delayed retry) decides when to re-invoke.

**Idempotency:** safe to re-invoke. On a re-run against an already-materialized org, the query succeeds on the first attempt. Step 0.5's checkpoint queries will report Steps 1a-PSL through 3.4 as "already done," and only Step 3.5 onward will actually re-execute.

---

### Step 3.6 — FieldDefinition secondary diagnostic (informational, ≤2 attempts)

Runs after the primary Step 3.5 gate has already passed. Purpose: catch the rare case where direct SOQL succeeds but FieldDefinition disagrees, which can indicate a describe-cache incoherence that other tools (Tooling API, admin UI) will observe.

Uses the `salesforce-headless-360` MCP `dispatch_readonly` tool. The `/services/data/query` endpoint (not Tooling) accepts `v64.0` cleanly on this route — the `v66.0` pin from Step 11 is scoped specifically to the `/tooling/*` sub-route where `v64.0` returned `ROUTE_NOT_FOUND` on the 2026-08-20 Org2 test. Do NOT "fix" this v64.0 → v66.0 without re-testing; the two routes have independent version-support surfaces.

```
mcp__salesforce-headless-360__dispatch_readonly
  method: GET
  url:    /services/data/v64.0/query?q=SELECT+Id%2CQualifiedApiName+FROM+FieldDefinition+WHERE+EntityDefinition.QualifiedApiName+%3D+%27Contact%27+AND+QualifiedApiName+IN+%28%27License_Number__c%27%2C%27Battery_Score__c%27%2C%27Pacing_Performance_Score__c%27%2C%27Unified_Individual_Id__c%27%2C%27Atrial_Risk_Score__c%27%2C%27Last_Transmission__c%27%29
```

**Attempts:** 2 max (attempt 1 immediate, attempt 2 after 15 seconds if `totalSize < 6`).

- ✅ `totalSize == 6` → log ✅ and advance.
- ⚠️ `totalSize < 6` after both attempts → log a WARNING with the missing field names and advance anyway. **Do NOT HARD FAIL here** — Step 3.5 is the authoritative signal; a FieldDefinition mismatch after Step 3.5 passes is a documentable cache-incoherence, not a blocker. Include this warning in Step 12's final summary so operators can inspect the org's Setup UI if downstream Setup-based tooling behaves oddly.

**Trust chain (Step 5+ may run only when ALL are true):**

1. Step 2 polling loop exited with `Status=Succeeded, numberComponentErrors=0`.
2. Step 2.5 stuck-deploy sweep completed cleanly (no load-bearing stuck deploys surfaced).
3. Step 3 assigned `PulseSyncBasePS` to the running user (or verified an existing assignment).
4. Step 3.4 verified 6 Contact FieldPermissions rows with Read+Edit both true.
5. **PRIMARY:** Step 3.5 direct Contact SOQL executed without `INVALID_FIELD`.
6. **SECONDARY:** Step 3.6 FieldDefinition query returned 6 (or was logged as a warning-only mismatch).

If ANY of items 1–5 is not satisfied, Step 5 (and everything after) must NOT run. Item 6 is warning-only.

**Log to the user on success:**

```text
✅ Step 3–3.6 — PulseSyncBasePS assigned; FLS verified on 6 Contact fields;
   direct Contact SOQL succeeded. Advancing to Step 5 (Standard Pricebook)...
```

> The skill assigns `PulseSyncBasePS` BEFORE the data load so that custom Contact fields are visible to the API. A second permission set — `Customer 360 Data Platform Integration` — is configured AFTER the data load in Step 6b.

---

### Step 5 — Activate the Standard Pricebook (MCP)

Runs the same logic as `PulseSyncUtil.activateStandardPricebook()` — via the `salesforce-sobject-all` MCP (`soqlQuery` for the Standard Pricebook, then `updateSobjectRecord` to set `IsActive=true` if it isn't already). PricebookEntry inserts on the Standard Pricebook require it to be active.

**Step 5.1 — Read current state.**

```
soqlQuery:
  SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1
```

If the query returns zero rows, the org has no Standard Pricebook (extremely unusual — indicates a fundamental org configuration problem). Stop this skill and surface the issue.

Cache the returned `Id` as `<standardPricebookId>` — Step 6 will use it to substitute the literal placeholder `"STANDARD_PRICEBOOK_ID"` in `pricebookentries.json`.

**Step 5.2 — Activate if needed (idempotent).**

If `IsActive` is `true`, skip the update — nothing to do.

If `IsActive` is `false`:

```
updateSobjectRecord:
  sobject-name: Pricebook2
  id:           '<standardPricebookId>'
  body:
    IsActive: true
```

**Success criteria:**
- Standard Pricebook exists and is `IsActive = true`.
- `<standardPricebookId>` is available in memory for Step 6's placeholder substitution.

---

### Step 6 — Import sample data from `data/plan.json` (MCP)

End-to-end data load driven by two Salesforce MCP servers:
- **`salesforce-headless-360`** `dispatch` → `POST /services/data/v67.0/composite/sobjects` is the **PRIMARY** insert channel for planEntries with 2+ zero-match rows (Step 6.1c).
- **`salesforce-sobject-all`** provides everything else: `soqlQuery` for dedup precheck, `@ref` resolution, and post-load verification; `getUserInfo` / `getObjectSchema` for identity + describe cache; `updateSobjectRecord` for single-match / multi-match survivor updates; `deleteSobjectRecord` for extra-duplicate cleanup; `createSobjectRecord` as the **FALLBACK** insert path (trivial ≤1-row queues, per-row composite rejections, post-reconcile absent rows on ambiguous timeout).

The step reads `data/plan.json`, which lists each sObject in dependency order and references one or more JSON files of records under `data/`.

---

**🚨 CHANNEL ENFORCEMENT — MANDATORY, NON-NEGOTIABLE (2026-08-18 incident + 2026-08-24 refactor):**

Step 6 record mutations MUST go through the two Salesforce MCP servers named above. No other channel is acceptable.

**Approved tools inside Step 6 (any other channel is a violation):**

- `mcp__salesforce-headless-360__dispatch` — **only** with `url == "/services/data/v67.0/composite/sobjects"` and `method == "POST"` (the composite insert PRIMARY path in Step 6.1c). No other `dispatch` targets inside Step 6.
- `mcp__salesforce-sobject-all__soqlQuery` — dedup precheck, reconciliation reads, post-load verification.
- `mcp__salesforce-sobject-all__createSobjectRecord` — single-record FALLBACK insert path (Step 6.1c's trivial-object / per-row / post-reconcile branches).
- `mcp__salesforce-sobject-all__updateSobjectRecord` — inline match-and-update path (Step 6.1a Call 4b).
- `mcp__salesforce-sobject-all__deleteSobjectRecord` — dedup extras cleanup (Step 6.1a Call 3) and reconcile-time duplicate collapse.
- `mcp__salesforce-sobject-all__getObjectSchema` / `mcp__salesforce-sobject-all__getUserInfo` — describe + identity.

**Explicit ban list — using ANY of these inside Step 6 is a HARD-FAIL skill violation:**

- `import urllib`, `import urllib.request`, `import urllib.parse` (raw HTTPS in Python)
- `import requests` (third-party HTTP client in Python)
- `import http.client` (stdlib HTTP client)
- `curl` invocations targeting `/services/data/*` (raw REST from bash)
- `sf apex run` (Apex script channel)
- `sf apex run -f <file>` (Apex file channel)
- `sf data tree import` (legacy tree loader)
- `sf data import bulk` / `sf data upsert bulk` / `sf data import resume` / `sf data bulk results` (Bulk API 2.0 CLI channel)
- `sf data create record` (CLI record channel)
- Any `ssl.CERT_NONE` context (indicates a home-rolled loader bypassing MCP)
- `mcp__salesforce-headless-360__dispatch` targeting any URL OTHER than `/services/data/v67.0/composite/sobjects` for the purpose of inserting sample records (composite/tree, jobs/ingest, and other Salesforce APIs are out of scope for Step 6 seed loading)

**Why (2026-08-18 incident on `HCInstallOrg`):** the sub-agent chose a Python `urllib` loader over MCP "for efficiency" — bulk-posting 127 records without invoking Step 6.1a's per-record dedup guard, and without invoking Step 6.3's post-load verification. Result: 17 duplicate Product2 groups, 20 duplicate Asset groups, 2× Charles Scott, 2× Metformin — plus `PatientMedicalProcedure = 0` records where the loader silently failed and never reported. The run self-declared "COMPLETE" while the org was materially dirty.

**Detection rule:** before the first insert-family mutation in Step 6, log the tool that will be used. If the tool name is not one of `mcp__salesforce-headless-360__dispatch` (for `POST /services/data/v67.0/composite/sobjects`) or `mcp__salesforce-sobject-all__createSobjectRecord`, HARD FAIL immediately with:

```
❌ SKILL VIOLATION: Step 6 must use an approved MCP channel.
   Attempted tool: <observed tool>
   Approved tools:
     - mcp__salesforce-headless-360__dispatch → POST /services/data/v67.0/composite/sobjects (PRIMARY)
     - mcp__salesforce-sobject-all__createSobjectRecord (FALLBACK / trivial-object / per-row / post-reconcile)
   
   Step 6.1a's dedup guard, Step 6.1c's composite batching, and Step 6.4's count
   verification depend on these channels. Bypassing them silently corrupts the org.
   
   Action required: restart Step 6 using the approved MCP tools. Do NOT write a
   Python/curl/CLI loader as a shortcut.
```

**Rationale (the shortcut is not faster in aggregate):** the MCP channels are ~2s slower per HTTP round-trip than a raw HTTPS POST, but Step 6.1a's dedup guard PLUS Step 6.4's count verification collectively prevent 30-90 minutes of downstream remediation when a shortcut misses duplicates or partial-inserts. The composite batch (200 rows per call via headless-360 `dispatch`) closes the throughput gap without giving up dedup or verification. The MCP channels are the shorter path when total cost — including cleanup — is measured.

---

**Step 6.0 — Resolve one more org-specific Id.**

Person Account `RecordTypeId` — used when inserting Person Account records (rows in `accounts.json` whose `Type == "PersonAccount"` or that contain `__pc` fields):

```
soqlQuery:
  SELECT Id FROM RecordType
  WHERE SobjectType = 'Account' AND IsPersonType = true
  LIMIT 1
```

If this returns zero rows, Person Accounts are not enabled in the target org. That's a `/feature-enablement` prerequisite failure — stop this skill and surface it.

Cache the returned Id as `<personAccountRecordTypeId>`.

**Step 6.0a — MCP timeout handling: reconcile first, retry only if needed (MANDATORY).**

The `salesforce-sobject-all` MCP occasionally returns a timeout on `createSobjectRecord` / `updateSobjectRecord`. A timeout is ambiguous — the request may have never reached Salesforce, or it may have committed with the response lost in transit. **Blind retry-on-timeout is banned:** a blind retry on a committed create produces a duplicate that Step 6.1a's dedup guard would have to clean up on the next run.

**Scope — reconcile-first applies globally; the full multi-read ladder does not.**

Every `createSobjectRecord` and `updateSobjectRecord` call in Step 6 and Step 6b uses reconcile-first timeout handling — no exceptions, no blind retries. But the **shape** of the reconciliation differs by call site:

- **Step 6 plan-data creates** (Step 6.1, Step 6.1a Call 4a, Step 6.2 preflight-adjusted rows) that go through the **single-record** `createSobjectRecord` path: use the full 4-read reconciliation ladder (3s / 7s / 20s / 15s = ~45s cumulative) documented immediately below. These are the calls where a silent-commit-plus-retry produces a duplicate the org can't easily distinguish from a valid record, so the extra visibility window is worth the wall-clock cost. **Note:** Step 6.1c's *composite* ambiguous-outcome reconciliation is a separate, wider window (3, 7, 20, 15, 30, 15 = 90 s cumulative — see Step 6.1c) and is not the ladder documented in this section.
- **Step 6 plan-data updates** (Step 6.1a Call 4b, Step 6.2 preflight-adjusted rows, Step 6b.4 Asset ContactId update): use the simpler re-query-once-then-retry-once policy in the "Policy — `updateSobjectRecord` timeout" section below. Updates don't create rows, so the duplicate-leak risk that motivates the ladder doesn't apply.
- **Step 6b FieldPermissions / ObjectPermissions creates**: use the simpler reconcile-once-then-retry-once policy documented at the bottom of this section under "Where the ladder applies". These rows are structurally deduplicated at the DB layer (composite key of ParentId + SobjectType + Field for FieldPermissions; ParentId + SObjectType for ObjectPermissions), so Salesforce rejects duplicate permission rows outright rather than silently creating parallel duplicates. The ladder's ~45s wait provides no additional safety for these calls.

The three policies together cover every create/update Step 6 and 6b issue. No create/update call is exempt from reconcile-first.

**Policy — `createSobjectRecord` timeout — MULTI-READ RECONCILIATION LADDER (3s / 7s / 20s / 15s):**

```
createSobjectRecord(sObjectType, cleanedBody)  # first attempt
    ↓ timeout
DO NOT retry create immediately. Salesforce may have committed the row silently
while the MCP response was lost; on Storm/orgfarm the newly-committed row can
remain invisible to follow-up SOQL for up to ~40 seconds (2026-08-20 Org2 test
observed exactly this on Case "Pre-Authorization for Pacemaker Implant" —
reconcile at ~2s returned totalSize=0, a retry then created a duplicate that
Step 6.4 had to clean up). Blind retry is banned; a single reconcile-then-retry
is also insufficient. Read four times with widening backoff, covering ~45s
cumulative — past the observed ~40s replication ceiling — before considering
a retry.

Reconciliation ladder:

    wait 3s   (cumulative: 3s)
        ↓
    soqlQuery: SELECT Id, CreatedDate FROM <sObjectType> WHERE <natural-key clause>
        ↓
    totalSize >= 1  → the create actually committed (adopt oldest-by-CreatedDate,
                      delete extras per Step 6.1a Call 3 if totalSize >= 2).
                      Store refs[referenceId] = survivor_id. DONE. NO retry.
    totalSize == 0  → continue ladder:

    wait 7s   (cumulative: 10s)
        ↓
    soqlQuery: same WHERE
        ↓
    totalSize >= 1  → adopt as above. DONE. NO retry.
    totalSize == 0  → continue ladder:

    wait 20s  (cumulative: 30s)
        ↓
    soqlQuery: same WHERE
        ↓
    totalSize >= 1  → adopt as above. DONE. NO retry.
    totalSize == 0  → continue ladder:

    wait 15s  (cumulative: 45s — past the observed ~40s replication ceiling)
        ↓
    soqlQuery: same WHERE
        ↓
    totalSize >= 1  → adopt as above. DONE. NO retry.
    totalSize == 0  → after 45s of visibility backoff the row is genuinely
                      absent. The original create most likely never committed.
                      Retry createSobjectRecord ONCE.

Post-retry reconcile (mandatory, guards against a second timeout leaking a
duplicate):

    createSobjectRecord(sObjectType, cleanedBody)  # retry
        ↓ (any outcome — success, timeout, or error)
    wait 3s
        ↓
    soqlQuery: same WHERE
        ↓
    totalSize >= 1  → adopt as above. DONE.
    totalSize == 0  → the retry did not land either. Log the record to
                      run.reconciliation_failures (per-sObject count) and
                      continue with the next record. Step 6.4's SOQL count
                      gate is the final safety net — a missing record will
                      trip its shortfall check and hard-fail before Step 6b.
```

**Where the ladder applies:**
- ✅ Every `createSobjectRecord` call inside Step 6.1 / 6.1a Call 4a / 6.2 for `data/plan.json` records (Account, Contact, Case, Product2, Pricebook2, PricebookEntry, CodeSet, CodeSetBundle, Medication, MedicationRequest, AllergyIntolerance, HealthCondition, PatientMedicalProcedure, Asset, Entitlement, ServiceAppointment, Task, and any future plan.json addition).
- ❌ **NOT** for Step 6b's `FieldPermissions` / `ObjectPermissions` writes. Those rows are structurally constrained by a natural composite key at the DB layer (ParentId + SobjectType + Field for FieldPermissions; ParentId + SObjectType for ObjectPermissions). Salesforce rejects duplicate permission rows outright rather than silently creating parallel duplicates, so the simpler reconcile-once-then-retry policy is sufficient there:
  ```
  createSobjectRecord(FieldPermissions or ObjectPermissions, body)
      ↓ timeout
  wait 3s → soqlQuery same WHERE → totalSize >= 1 → adopt; totalSize == 0 → retry once → reconcile once → adopt or fail
  ```

If the reconciliation SOQL itself fails (HTTP 400 on a malformed WHERE, or another timeout), record the failure in `run.reconciliation_failures` and continue with the next record — the deferred hard-fail block at the end of Step 6 will surface it before Step 6b runs.

**Cost note:** the ladder adds up to ~45s per Step 6 create-timeout event (only reaches step 4 when all prior reconciles return zero — an early match short-circuits). Timeouts should be uncommon (2 events across the 2026-08-20 Org2 run of 127 records). The trade is: at most a handful of ×45s waits per install versus a silent duplicate that Step 6.4 has to clean up post-hoc — and possibly downstream `@ref` mis-resolution if a later record referenced the retry Id before Step 6.4 ran. The 45s worst-case is strictly cheaper than that failure mode.

**Policy — `updateSobjectRecord` timeout:**

```
updateSobjectRecord(sObjectType, id, body)  # first attempt
    ↓ timeout
Re-query the target record for the fields being updated:
    ↓
soqlQuery: SELECT <fields in body> FROM <sObjectType> WHERE Id = '<id>'
    ↓
All fields already match the intended values → the update committed. Continue.
Any field does NOT match                     → retry updateSobjectRecord ONCE.
Row not found (rare — deletion race)         → log and continue; refs still points at
                                              the survivor Id from Step 6.1a's dedup pass.
```

**Retry cap:** exactly ONE retry per record after a successful reconciliation. If the retry also times out, run the reconciliation SOQL a second time; if it still shows the write didn't land, log the record to `run.reconciliation_failures` (per-sObject count) and continue. Step 6.4's SOQL count gate is the final safety net — a lost record will trip the count shortfall and hard-fail before Step 6b runs.

**Why this policy exists:** observed 2026-08-20 on `HCStrom14thAug2026Org1` — MCP timeout on Asset `02igL000003IhXpQAK` ContactId update, followed by a successful re-query showing the update had NOT landed. A blind retry-on-timeout without the reconciliation step would have silently created a duplicate CodeSet in the sibling case where the create HAD committed but the response was lost.

**What NOT to do (banned patterns):**

- ❌ Retry the create/update immediately on timeout without reconciling first.
- ❌ Retry more than once per record.
- ❌ Fall back to a different MCP tool or HTTP channel on timeout — Step 6's channel enforcement is absolute.
- ❌ Swallow the timeout silently and proceed to the next record — every timeout must be followed by a reconciliation attempt.

---

**Step 6.0b — Expected manifest preflight (MANDATORY, runs before Step 6.1's first mutation).**

Before any Step 6 insert or update fires, compute the expected record manifest from disk and log it. The manifest is the ground-truth "expected" count Step 6.4's post-load verification will compare against — computing it here (rather than deferring to Step 6.4.1) surfaces malformed data files, missing files, or plan/data drift **before** the first mutation lands.

1. Load `data/plan.json` from the current working directory.
2. For each planEntry, load every file listed in `planEntry.files` and count the JSON records (`.records[]` length).
3. Build the map `expectedManifest = { sObjectType: expected_count }`.
4. Assert the total against `plan.json`'s file list — if any referenced file is missing or unreadable, HARD FAIL now (do NOT enter Step 6.1).
5. Log the manifest to the operator in a table:

   ```text
   📋 Step 6.0b — Expected manifest built from data/plan.json
     Account                        4
     Contact                        2
     Task                           1
     Case                           10
     Product2                       12
     Pricebook2                     1
     PricebookEntry                 24
     CodeSet                        18
     CodeSetBundle                  18
     Medication                     5
     MedicationRequest              5
     AllergyIntolerance             6
     HealthCondition                4
     PatientMedicalProcedure        4
     Asset                          3
     Entitlement                    3
     ServiceAppointment             7
     ────────────────────────────────
     TOTAL                          127
   ```

6. Cache `expectedManifest` for reuse by Step 6.4.1 (no reload from disk there). Also cache the raw records per sObject so the bulk-first path in Step 6.1c can build batches without re-reading files.

The manifest is the source of truth for what "success" means — Step 6.4 compares `verified_in_org == expectedManifest[sObjectType]` for every sObject. No required object type may exit Step 6 without appearing in this map.

---

**Step 6.1 — Iterate `data/plan.json` in order and insert.**

Maintain `refs = {}` — a map from `referenceId` (as written in the JSON files) to the real Salesforce Id returned by the insert (composite batch or single-record fallback).

For each step in `plan.json`, in plan order:

1. Read the referenced data file (or reuse the cached records from Step 6.0b).
2. Look up the sObject's `createable` field list once via `getObjectSchema` and cache it. This is used to strip fields that this user cannot create (per FLS) — otherwise Salesforce returns `INVALID_FIELD_FOR_INSERT_UPDATE` for the entire record.
3. Initialize `insertQueue = []` for this planEntry. Rows destined for insert go here; matched rows update inline.
4. For each record in the file:
   - For any field value that is a string starting with `@`, look up the suffix in `refs` and substitute the real Id. If the reference is unknown, stop with a clear error — this means the data files are inconsistent with the plan order.
   - Replace `Pricebook2Id == "STANDARD_PRICEBOOK_ID"` with `<standardPricebookId>` from Step 5.
   - If the record is a Person Account (has `__pc` fields, or `Type == "PersonAccount"`), add `RecordTypeId: <personAccountRecordTypeId>` and remove the `Type` field. `Type` is not a real column for Account records.
   - Apply the Step 6.2 preflight transforms (Phone→string, `ServiceAppointment` temporal-fields defensive validation over `SchedStartTime` / `SchedEndTime` / `EarliestStartTime` / `DueDate`, `MedicationRequest.PatientId` Contact→Account swap) — these MUST run BEFORE the batch is assembled.
   - Remove any field name that does not appear in the sObject's `createable` list.
   - 🆕 **Pre-insert dedup guard (Step 6.1a) — MATCH-AND-UPDATE strategy:** before deciding create vs update, query the org for any existing record(s) matching this row's natural key (see Step 6.1a below).
     - **Zero matches** → append the cleaned body to `insertQueue` alongside its `referenceId` (deferred; the composite batch in Step 6.1c fires after the queue is fully built for this planEntry). DO NOT call `createSobjectRecord` here.
     - **Exactly one match** → call `updateSobjectRecord` inline on that Id with the cleaned body and store `refs[referenceId] = existing_id`. UPDATEs stay single-record (Step 6.0a's simpler timeout policy applies).
     - **More than one match** → delete the extras (keep the oldest by `CreatedDate`), then update the survivor with the cleaned body and store `refs[referenceId] = survivor_id`. UPDATE + DELETE stay single-record.
     - **Every plan.json row must land in the org with the exact field values from `data/*.json` — no skip, no drift.** **Never skip Step 6.1a** — the check is idempotent and safe for first-time runs (zero matches → append to queue → composite insert).
5. After the per-record loop finishes for this planEntry, hand `insertQueue` to Step 6.1c (bulk-first composite POST). Step 6.1c writes each successful row's Id into `refs[referenceId]`, then falls back to single-record `createSobjectRecord` (with the full 4-read reconciliation ladder) for any row Salesforce rejects with `success:false` or for any whole-chunk HTTP failure.
6. Advance to the next planEntry only after `refs` contains an Id for every `referenceId` in this planEntry that landed successfully. Downstream `@ref` lookups resolve against the populated `refs` map.

**Serial ordering across planEntries** stays a hard rule — the composite batch runs after all per-record dedup work for one planEntry, and before the next planEntry begins. This preserves parent → child ordering (Account → Contact → Product2 → PricebookEntry → …) and avoids `UNABLE_TO_LOCK_ROW`. Salesforce's composite/sobjects processes rows in submitted order within a chunk, so intra-planEntry ordering is also preserved.

**Trivial-object exception (single-record insert instead of composite):** for planEntries whose `insertQueue.length <= 1` after dedup, use the single-record `createSobjectRecord` path directly — one HTTP call either way, and the composite envelope adds no value. In the shipped MedTech dataset this covers Task (1 record) and Pricebook2 (1 record); any planEntry whose dataset reduces to ≤1 row after dedup (e.g. on a partial re-run) also takes this branch.

---

**Step 6.1a — Pre-insert dedup guard (MATCH-AND-UPDATE strategy, MCP-only): for EVERY record, check if a matching row already exists in the org. Update the existing row when there is exactly one match, delete extras only when there are multiple matches, and insert fresh only when there are zero matches.**

**🚨 THIS IS A MANDATORY, ORDERED SEQUENCE OF MCP CALLS — NOT PSEUDOCODE, NOT DOCUMENTATION.**
**🚨 The calls below MUST execute for every single record in every `data/*.json` file. Skipping any call for any record is a defect.**
**🚨 There is no "inferable"/"skip" path. If a record has a `Name` field OR a `FirstName`+`LastName` pair, dedup runs. Full stop.**
**🚨 GOAL: every plan.json row lands in the org with the exact field values from `data/*.json`. Match → UPDATE. No match → INSERT. Multiple matches → keep oldest, DELETE extras, UPDATE survivor. Never SKIP.**

**For each record in `data/*.json`, in this exact order:**

**MCP Call 1 — Build the WHERE clause (in-memory only, no tool call):**
- If the record body has a `Name` field → `WHERE Name = '<escaped-name>'` (for Person Accounts also append `AND IsPersonAccount = true`).
- Else if the record body has `FirstName` AND `LastName` → `WHERE FirstName = '<esc>' AND LastName = '<esc>' AND IsPersonAccount = true` (only if sObject supports `IsPersonAccount`).
- Else → concatenate every remaining scalar field the record body provides (after resolving `@ref` values against the `refs` map), AND-joined.
- SOQL escape rule: replace `\` with `\\` and `'` with `\'` in every string value before injecting.

**MCP Call 2 — Query the org for matches (include `CreatedDate` for tie-breaking):**
```
mcp__salesforce-sobject-all__soqlQuery
  q: "SELECT Id, CreatedDate FROM <sObjectType> WHERE <clause built above> ORDER BY CreatedDate ASC"
```
- If `totalSize == 0` → skip Call 3, proceed to Call 4a (INSERT).
- If `totalSize == 1` → skip Call 3, proceed to Call 4b (UPDATE).
- If `totalSize >= 2` → proceed to Call 3 (dedup collapse), then Call 4b (UPDATE the survivor).

**MCP Call 3 — Delete only the EXTRAS (keep the oldest by `CreatedDate`, delete the rest):**
```
survivor_id = query_result.records[0].Id     # oldest by ORDER BY CreatedDate ASC
extras      = query_result.records[1:]       # every match after the oldest
for each extra in extras:
    mcp__salesforce-sobject-all__deleteSobjectRecord
      sobject-name: <sObjectType>
      id:           <extra.Id>
```
- **Ignore `ENTITY_IS_DELETED` errors** (cascade race — the row is already gone, which is what we wanted).
- **FK-blocked delete on an extra** (restricted-delete FK, e.g. children still point at it) → log the error and continue; the survivor still gets UPDATE-ed in Call 4b, and the FK-blocked extra stays in the org until a downstream cleanup skill removes it. Do NOT halt the run — the plan.json row still lands via the UPDATE on the survivor.
- The single-match case (`totalSize == 1`) NEVER runs Call 3. That row is the survivor and goes straight to Call 4b.

**MCP Call 4a — QUEUE FOR INSERT (only when Call 2 returned `totalSize == 0`):**

Do NOT call `createSobjectRecord` here. Append the cleaned body + `referenceId` to `insertQueue` for this planEntry and continue to the next record. The composite batch in Step 6.1c is the primary insert channel — it fires once per planEntry after Call 2/3 have run for every record in the file.

```
insertQueue.append({ referenceId: <record.attributes.referenceId>, body: <cleaned record body> })
```

Only when `insertQueue.length` for the whole planEntry ends up as 0 or 1 (trivial-object exception in Step 6.1's "Advance to next planEntry" block) does the fallback single-record path fire directly:

```
mcp__salesforce-sobject-all__createSobjectRecord
  sobject-name: <sObjectType>
  body:         <cleaned record body>
```
- Store the returned Id in `refs[referenceId]`. The composite path (Step 6.1c) writes into `refs` the same way — the shape of the `refs` map is identical regardless of which path landed the row.

**MCP Call 4b — UPDATE (when Call 2 returned `totalSize >= 1`, applied to the survivor Id):**
```
mcp__salesforce-sobject-all__updateSobjectRecord
  sobject-name: <sObjectType>
  id:           <survivor_id>
  body:         <cleaned record body>
```
- Store `refs[referenceId] = survivor_id` so downstream `@ref` lookups resolve correctly.
- Strip any read-only fields from the update body (e.g. `IsPersonAccount`, computed fields, formula fields) — Salesforce rejects the whole record with `INVALID_FIELD_FOR_INSERT_UPDATE` otherwise. Use the same `createable` + `updateable` describe cache as the insert path.
- On per-record UPDATE failure, log the error and continue to the next record — this preserves the "load every row" contract even when a single row's update is rejected by a validation rule.

**Coverage requirement:** every record in every `data/*.json` file listed by `data/plan.json` runs through Calls 2 + (3 if needed) + (4a OR 4b). Zero exceptions. Zero skips. The `Never dedup these sObjects` blocklist below (User, Profile, RecordType, standard Pricebook) is the ONLY exclusion.

> After Step 6 finishes, EVERY plan.json row has a corresponding org record with the exact field values from `data/*.json`. Pre-existing matching rows were UPDATED to those values. Duplicates (2+ pre-existing matches) were collapsed to the oldest, which was then UPDATED. No `data/*.json` row is silently skipped. No org row that this installer doesn't own is destroyed on single-match.

**How to infer the natural key generically (this is the whole algorithm — no per-sObject tables):**

Given an incoming record body (fields the JSON specifies), a resolved `refs` map (`@ref` → real Id), and the target `sObjectType`:

1. **Drop system fields that can never be part of a natural key:** `attributes`, `Id`, `OwnerId`, `CreatedById`, `CreatedDate`, `LastModifiedById`, `LastModifiedDate`, `SystemModstamp`, `IsDeleted`, `LastActivityDate`, `LastViewedDate`, `LastReferencedDate`.
2. **Resolve every `@ref` value in the record body to its real Salesforce Id** (using the same `refs` map Step 6.1 populates). A record referencing `@accountRef1` matches against `AccountId = '<real Account Id>'`, not against the literal string `@accountRef1`.
3. **Drop long-text / rich-text / blob fields** — any field whose describe type is `textarea` with `length > 255`, `richtextarea`, `base64`, or `encryptedstring`. SOQL can't equality-filter these reliably, and they're rarely part of a natural key anyway. Cache the describe result once per sObject to avoid repeated calls.
4. **Drop Person Account `__pc` fields** when the incoming record is a Person Account. They cascade with the parent — matching on `FirstName + LastName + IsPersonAccount=true` already covers both sides.
5. **Drop polymorphic reference fields** — any field whose describe metadata reports `referenceTo` with more than one target sObject (`Task.WhoId` → [Contact, Lead, ...], `Task.WhatId` → [Account, Opportunity, ...], `Case.AccountId` when it can resolve to both Account and PersonAccount, `ServiceAppointment.ParentRecordId` → [Account, WorkOrder, Asset, ...], `Event.WhoId`, `Event.WhatId`). SOQL rejects equality-filter on polymorphic references without a `TYPEOF` clause, returning HTTP 400. Do NOT include these fields in the WHERE — infer the record's natural key from non-polymorphic fields instead.
6. **From what remains, pick the match fields:**
   - **If the sObject describe reports a `Name` field AND the record body specifies `Name`** → match on `Name = '<esc>'` alone. (Covers Account business, Product2, Pricebook2, Medication, CodeSet, CodeSetBundle, etc.)
   - **Else if the sObject is Person-Account-shaped (`IsPersonAccount=true` OR record has `FirstName`+`LastName` without `Name`)** → match on `FirstName + LastName [+ IsPersonAccount=true when the sObject supports it]`. (Covers Person Accounts and standalone Contacts.)
   - **Else if the sObject describe reports a `Subject` field AND the record body specifies `Subject`** → match on `Subject = '<esc>' [+ any non-polymorphic scalar the JSON also provided]`. Covers Task, Case, ServiceAppointment, Event. (`Subject` is filterable but not groupable — that constraint only matters for the post-load verification gate, not the pre-insert WHERE.)
   - **Else** → match on **every remaining scalar field the JSON provided** (after steps 1–5), `AND`-joined. This is the fallback that catches everything else — AllergyIntolerance, HealthCondition, MedicationRequest, PatientMedicalProcedure, PricebookEntry, Asset, Entitlement, and anything future `plan.json` files add. A record with (`PatientId=X, CodeId=Y, StartDateTime=Z`) matches only rows with all three equal.
7. **If step 6 produced zero match fields** (rare — record body was entirely `@ref` links to things not yet inserted, entirely long-text, or entirely polymorphic references) → log `no natural-key fields inferable for <type> record — skipping dedup guard` and proceed to insert. This is safer than a wrong WHERE.

**Escape rule (SOQL literals):** Salesforce SOQL string literals must escape backslashes and single quotes. Before injecting a value: `value.replace('\\', '\\\\').replace("'", "\\'")`. Date and DateTime values keep their ISO form **without quotes** (`FieldName = 2028-05-23T06:30:00.000+0000`, NOT `FieldName = '2028-05-23T06:30:00.000+0000'`). SOQL rejects DateTime literals wrapped in quotes with HTTP 400 (`invalid date`). Detect DateTime fields by their describe type (`datetime`) — cache the describe result once per sObject. Booleans and numbers also keep their literal form. Do NOT use string concatenation without escaping — sample data contains apostrophes (`O'Brien`, `L'Oréal`) that would otherwise break the query.

**Pseudocode (drop-in, one function for every sObject):**

```
# Called once per record, before createSobjectRecord.

SYSTEM_FIELDS = {"attributes", "Id", "OwnerId", "CreatedById", "CreatedDate",
                 "LastModifiedById", "LastModifiedDate", "SystemModstamp",
                 "IsDeleted", "LastActivityDate", "LastViewedDate", "LastReferencedDate"}
SKIP_TYPES = {"textarea_long", "richtextarea", "base64", "encryptedstring"}

def is_polymorphic(field_describe):
    # A reference field is polymorphic when its referenceTo array has >1 target sObject.
    # SOQL rejects equality-filter on polymorphic references without a TYPEOF clause.
    return (field_describe.type == "reference"
            and len(field_describe.referenceTo or []) > 1)

def build_dedup_where(sObjectType, recordBody, refs, describe_cache):
    describe = describe_cache.get_or_fetch(sObjectType)  # cache per sObject
    fields_by_name = {f.name: f for f in describe.fields}
    skip_names = {f.name for f in describe.fields
                  if f.type in SKIP_TYPES
                  or (f.type == "textarea" and (f.length or 0) > 255)
                  or is_polymorphic(f)}   # ← NEW: polymorphic references are unfilterable
    is_person = recordBody.get("Type") == "PersonAccount" or bool(recordBody.get("IsPersonAccount"))

    clauses = []
    for field, value in recordBody.items():
        if field in SYSTEM_FIELDS or field in skip_names:
            continue
        if is_person and field.endswith("__pc"):
            continue  # Person Account cascade fields
        # Resolve @ref values to real Ids
        if isinstance(value, str) and value.startswith("@"):
            resolved = refs.get(value[1:])
            if not resolved:
                # Referenced record not inserted yet — this field can't be a natural key.
                continue
            value = resolved
        # Format for SOQL — pass the field describe so DateTime literals stay unquoted.
        clauses.append(format_soql_predicate(field, value, fields_by_name.get(field)))

    # Prefer a Name-only key when the sObject supports it — cheaper, matches business-record dedup intent.
    if "Name" in fields_by_name and "Name" in recordBody:
        return [format_soql_predicate("Name", recordBody["Name"], fields_by_name["Name"])] \
               + person_account_qualifier(is_person, describe)

    # Person-Account-shaped record without a Name field on the body
    if is_person or ("FirstName" in recordBody and "LastName" in recordBody and "Name" not in recordBody):
        base = []
        for k in ("FirstName", "LastName"):
            if k in recordBody:
                base.append(format_soql_predicate(k, recordBody[k], fields_by_name.get(k)))
        return base + person_account_qualifier(is_person, describe)

    # ─── Explicit-key allowlist ───────────────────────────────────────────────
    # For sObjects where the generic "Subject-plus-surviving-scalars" heuristic
    # is known to collide under high-visibility-lag conditions, we pin an exact
    # required key set. All listed fields MUST be present on the record body;
    # if any is absent, the algorithm falls through to the generic branch.
    #
    # ServiceAppointment — `Subject + AppointmentType + Status + SchedStartTime`
    # uniquely identifies every intended record in `data/serviceappointments.json`
    # (SchedStartTime alone is unique across the 7 seeded rows; the 4-tuple is
    # trivially unique). This deterministic key eliminates the "reconcile
    # matched too few candidates during a 5xx retry" duplicate-leak observed
    # on the 2026-08-25 run.
    EXPLICIT_KEYS = {
        "ServiceAppointment": ("Subject", "AppointmentType", "Status", "SchedStartTime"),
    }
    explicit = EXPLICIT_KEYS.get(sObjectType)
    if explicit and all(k in recordBody for k in explicit):
        return [
            format_soql_predicate(k, recordBody[k], fields_by_name.get(k))
            for k in explicit
        ]

    # Subject-based objects (Task, Case, Event, and ServiceAppointment when its
    # explicit key above cannot be built) — Subject is filterable, and combining
    # it with the surviving scalar clauses gives a tighter natural key without
    # dragging polymorphic references into the WHERE.
    if "Subject" in fields_by_name and "Subject" in recordBody:
        subject_clause = format_soql_predicate("Subject", recordBody["Subject"], fields_by_name["Subject"])
        return [subject_clause] + [c for c in clauses if not c.startswith("Subject ")]

    # Everything else — AND-join whatever survived filtering
    return clauses  # may be empty → caller skips dedup

def person_account_qualifier(is_person, describe):
    if is_person and any(f.name == "IsPersonAccount" for f in describe.fields):
        return ["IsPersonAccount = true"]
    return []

# Run-scoped state — one instance per Step 6 execution. The list survives across
# every sObject batch and is inspected once at the end of Step 6 (see the deferred
# hard-fail block below).
run.malformed_dedup_sobjects = run.malformed_dedup_sobjects or []   # list of (sObjectType, sample_where, error_message)

def dedup_before_insert(sObjectType, recordBody, refs, describe_cache):
    if is_system_sobject(sObjectType):
        log(f"dedup: {sObjectType} is on the never-dedup list — skipping guard")
        return
    predicates = build_dedup_where(sObjectType, recordBody, refs, describe_cache)
    if not predicates:
        log(f"dedup: no natural-key fields inferable for {sObjectType} record — skipping guard")
        return
    where = " AND ".join(predicates)
    try:
        matches = soqlQuery(f"SELECT Id FROM {sObjectType} WHERE {where}")
    except SoqlError as e:
        # HTTP 400 on the dedup query means our WHERE was built wrong (polymorphic
        # reference we missed, quoted DateTime, unfilterable field type). The primary
        # algorithm should have caught this — a 400 here is a real defect. Do NOT silently
        # fall through as if dedup succeeded; that reintroduces the duplicate-leak this
        # guard exists to prevent (2026-08-18 incident on HCNewMedTechOrg18Aug: 6 sObjects
        # skipped, HealthCondition left with 3 stale duplicates from a prior install).
        #
        # But do NOT halt the run mid-batch either — that would leave the org partially
        # loaded (e.g. only Account+Contact from a 127-record load) and force a full
        # wipe-and-re-run to recover.
        #
        # Instead: record the failure in run-scoped state, log LOUDLY, continue the insert
        # unguarded for this record, and defer the hard-fail to the end of Step 6 (see the
        # "Deferred hard-fail" block below). This gives operators a clean org state to
        # inspect + a clear list of which sObjects need manual dedup or a skill fix.
        log(f"ERROR: dedup HTTP 400 for {sObjectType} — WHERE: {where} — {e}")
        run.malformed_dedup_sobjects.append((sObjectType, where, str(e)))
        return   # skip the delete loop; caller proceeds to insert unguarded
    for row in matches:
        try:
            deleteSobjectRecord(sObjectType, row.Id)
            log(f"dedup: deleted pre-existing {sObjectType} {row.Id} matched by ({where})")
        except DeleteFailedError as e:
            if "ENTITY_IS_DELETED" in e.message:
                continue  # cascade delete race — already gone
            log(f"dedup delete failed for {sObjectType} {row.Id}: {e.message} — continuing to insert")
            # Do NOT stop the whole run on a single delete failure. If the insert then fails
            # with DUPLICATE_VALUE, escalate at that point.
```

**HTTP 400 policy — deferred hard-fail (mandatory):**

If `soqlQuery` returns HTTP 400 while running the dedup WHERE, the primary algorithm built an unfilterable clause (polymorphic reference not detected, DateTime literal wrongly quoted, unsupported field type). The response is a **two-phase failure**:

1. **In-flight (per record):** log the error LOUDLY (`ERROR`, not `WARN`), record the failing sObject + the malformed WHERE clause + the error message in `run.malformed_dedup_sobjects`, skip the delete loop for this record, and proceed to insert the record unguarded. Continue processing the remaining records in the current sObject batch and all downstream sObjects in the plan.
2. **End of Step 6 (deferred hard-fail):** immediately before running the post-load verification gate, check `run.malformed_dedup_sobjects`. If it is non-empty, **exit Step 6 with a non-zero code and do NOT run Step 6b** — print each entry (sObjectType, sample WHERE, error) so the operator can inspect the org, decide whether to manually dedup, and fix the algorithm before the next run.

Why deferred, not immediate: an immediate halt on the first HTTP 400 leaves the org partially loaded (e.g., only Account+Contact from a 127-record load), forcing a full wipe-and-re-run to recover. A deferred hard-fail lets all 127 records land — the operator inspects the dirty sObjects in the org (typically just the 1-2 that hit the bug) and either cleans them manually or re-runs after fixing the skill. Same "silent leak is impossible" guarantee; much lower blast radius.

**Deferred hard-fail block (put this immediately before the post-load verification gate):**

```
if run.malformed_dedup_sobjects:
    print("❌ Step 6 dedup guard produced HTTP 400 for one or more sObjects:")
    for sobj, where, err in run.malformed_dedup_sobjects:
        print(f"  - {sobj}: {where}")
        print(f"    → {err}")
    print("The affected records were inserted WITHOUT dedup. Manual review required.")
    print("Fix the natural-key inference algorithm in Step 6.1a to cover these sObjects,")
    print("clean up any duplicates in the org, then re-run the skill.")
    print("Do NOT run Step 6b — the run is in a partially-guarded state.")
    exit_non_zero()
```

A "warn and skip and continue as if fine" fallback is banned — it silently reintroduces the exact duplicate leak Step 6.1a exists to prevent.

**Where this runs in the Step 6.1 loop:**

```
for planEntry in plan.json:
    insertQueue = []
    for record in load(planEntry.files):
        cleanedBody = strip_attributes_and_resolve_refs(record, refs)
        cleanedBody = apply_step_6_2_preflights(planEntry.sobject, cleanedBody)   # ServiceAppointment temporal fields (Start/End/Earliest/Due), PatientId→Account, Phone→string, __pc
        match_result = dedup_before_insert(planEntry.sobject, cleanedBody, refs, describe_cache)
        if match_result.totalSize == 0:
            insertQueue.append({ "referenceId": record.attributes.referenceId, "body": cleanedBody })
        elif match_result.totalSize == 1:
            updateSobjectRecord(planEntry.sobject, match_result.survivor_id, cleanedBody)   # inline UPDATE
            refs[record.attributes.referenceId] = match_result.survivor_id
        else:  # totalSize >= 2
            delete_extras(planEntry.sobject, match_result.extras)
            updateSobjectRecord(planEntry.sobject, match_result.survivor_id, cleanedBody)
            refs[record.attributes.referenceId] = match_result.survivor_id

    # After the per-record loop finishes, hand insertQueue to Step 6.1c.
    # Step 6.1c writes refs[referenceId] for every row it lands (composite or fallback).
    step_6_1c_insert(planEntry.sobject, insertQueue, refs)
```

---

### Step 6.1c — Bulk-first insert via `salesforce-headless-360` MCP `/composite/sobjects` (PRIMARY insert channel, with per-record fallback)

**Purpose.** Insert each planEntry's records in **one bulk HTTP call per sObject** instead of N sequential single-record calls. Confirmed working against the target org on 2026-08-21 via a probe: `POST /services/data/v67.0/composite/sobjects` through `mcp__salesforce-headless-360__dispatch` accepts up to **200 records per call**, returns HTTP 200 with a per-record `{id, success, errors[]}` array, and honors `allOrNone: false` (partial success).

**Speedup.** ~5–6 min → ~1 min for a full Step 6 sample-data load — one HTTP round-trip per object instead of ~12–18 sequential single-record calls per object.

**Where this runs.** **PRIMARY insert channel.** After Step 6.1a's dedup guard has classified every record for the planEntry into `insertQueue` (zero-match) vs inline UPDATE (one-match / multi-match survivor), Step 6.1c fires exactly one composite POST per planEntry to insert the queue. Single-record `createSobjectRecord` from Step 6.1 becomes the **fallback**, used only when (a) the composite call fails at the HTTP layer, (b) a specific row returns `success:false`, or (c) the trivial-object exception applies (`insertQueue.length <= 1`).

**Trivial-object exception (short-circuit to single-record):** if `insertQueue.length == 0` there's nothing to insert — return immediately. If `insertQueue.length == 1` — one record in the queue — skip the composite envelope and call `mcp__salesforce-sobject-all__createSobjectRecord` directly with the full 4-read reconciliation ladder (Step 6.0a). The composite envelope adds no wall-clock benefit at N=1 and losing the ladder for a single row is not worth it. In the shipped MedTech dataset this covers Task (1 row) and Pricebook2 (1 row); it also covers any planEntry whose post-dedup queue size drops to 0 or 1 on a partial re-run.

**Untouched by this subsection:**
- Step 6.1a dedup guard — still runs per record BEFORE the batch is built
- The multi-read reconciliation ladder for `createSobjectRecord` timeouts (Step 6.0 pre-load section) — still applies to the fallback path
- Step 6.2 field-preflight rules (Phone→string, ServiceAppointment temporal-fields defensive validation over SchedStartTime / SchedEndTime / EarliestStartTime / DueDate, MedicationRequest.PatientId Contact→Account swap, Person Account `__pc` fields) — MUST run BEFORE the bulk batch is built, exactly as they run today before the per-record insert. Same rules, same order.
- Step 6.3 / Step 6.4 verification gates — unchanged
- `refs` map handling — unchanged (each successful bulk row's returned Id is captured under its `referenceId`, exactly like the single-record path)
- Person Account `RecordTypeId` substitution, `STANDARD_PRICEBOOK_ID` placeholder replacement, Health Cloud patient FK resolution — all resolved into `cleanedBody` before the row enters `insertQueue`

**Bulk-first insert function (`step_6_1c_insert`) — called once per planEntry with `insertQueue` after Step 6.1a's dedup loop finishes:**

```
# insertQueue is a list of { "referenceId": <str>, "body": <cleaned dict> } already carrying:
#   - attributes stripped (via strip_attributes_and_resolve_refs)
#   - @refs resolved against the running refs map (parent Ids from prior planEntry composite results)
#   - STANDARD_PRICEBOOK_ID substituted
#   - Person Account RecordTypeId added / Type field removed
#   - Step 6.2 preflights applied (Phone→string, ServiceAppointment temporal fields (Start/End/Earliest/Due), MedicationRequest.PatientId Contact→Account)
#   - non-createable fields stripped via getObjectSchema cache
# The composite body is built from insertQueue here — nothing else transforms the row after this.

def step_6_1c_insert(sObjectType, insertQueue, refs):
    if len(insertQueue) == 0:
        log(f"Step 6.1c: {sObjectType} — insertQueue empty (all rows matched existing records); nothing to POST.")
        return

    # ────────────── Trivial-object exception ──────────────
    # One row in the queue — skip the composite envelope and use single-record with the full 4-read ladder.
    if len(insertQueue) == 1:
        row = insertQueue[0]
        log(f"Step 6.1c: {sObjectType} — single-row queue, using createSobjectRecord path.")
        newId = createSobjectRecord(sObjectType, row["body"])   # full Step 6.0a ladder applies
        refs[row["referenceId"]] = newId
        return

    # ────────────── Composite POST (primary path) ──────────────
    # Chunk to 200. plan.json entries in this repo max out around 24 (PricebookEntry), so a single chunk suffices;
    # the chunk loop is defensive for any future planEntry that grows past 200 rows.
    CHUNK_SIZE = 200
    for chunk_start in range(0, len(insertQueue), CHUNK_SIZE):
        chunk_slice = insertQueue[chunk_start : chunk_start + CHUNK_SIZE]
        chunk_keys  = [row["referenceId"] for row in chunk_slice]
        # composite/sobjects requires "attributes": {"type": <sObject>} on every row — do NOT re-attach referenceId.
        chunk_bodies = [ { "attributes": { "type": sObjectType }, **row["body"] } for row in chunk_slice ]

        resp = mcp__salesforce-headless-360__dispatch(
            method = "POST",
            url    = "/services/data/v67.0/composite/sobjects",
            body   = {
                "allOrNone": False,                # partial success — one bad row does not abort the chunk
                "records":   chunk_bodies
            }
        )

        # ───── Whole-chunk classification ─────
        bulk_call_failed = (
            resp is None
            or resp.get("status_code") not in (200, 201)
            or not isinstance(resp.get("body"), list)
            or len(resp["body"]) != len(chunk_slice)
        )

        if bulk_call_failed:
            # ─── Whole-chunk failure — HTTP layer error, timeout, or malformed response.
            # NEVER blind-replay the whole chunk. The composite POST may have committed some, all,
            # or none of the rows — we must reconcile per record before deciding what to retry.
            log(f"Step 6.1c: {sObjectType} chunk [{chunk_start},{chunk_start + len(chunk_slice)}) "
                f"failed at HTTP layer (resp={resp}). Entering per-row reconcile-first fallback.")

            # Per-row reconcile ladder — same shape as Step 6.0a but keyed by referenceId, so we
            # can tell whether the composite already committed each row. Any row that is now
            # visible in the org keeps its Id (adopted into refs); any row that is missing after
            # the bounded reconciliation window is retried EXACTLY ONCE via single-record
            # createSobjectRecord (which itself carries the full 4-read ladder). After that
            # retry a POST-RETRY reconciliation confirms the row is really present before we
            # declare success — the retry itself must not be assumed to have landed.
            #
            # Ladder tuple: (3, 7, 20, 15, 30, 15) = 90s cumulative. This is a defensive
            # bounded window, NOT a guarantee about Salesforce commit-visibility latency.
            # Salesforce does not publish a global replication-visibility SLA; the six-step
            # backoff is empirically sized to cover the /composite/sobjects visibility lag
            # observed on trial orgs (past runs saw >45s but <90s under load) with room to
            # spare, then hand off to a single-shot retry rather than waiting indefinitely.
            RECONCILE_LADDER_S = (3, 7, 20, 15, 30, 15)     # bounded window, 90s cumulative

            def reconcile_lookup(where_sql):
                """
                Walk the bounded window looking for the row. On any successful match,
                collapse duplicates deterministically (keep oldest by CreatedDate, delete
                the rest) and return the surviving Id. Return None only if the window
                closes with zero matches.
                """
                if not where_sql:
                    return None
                for wait_s in RECONCILE_LADDER_S:
                    sleep(wait_s)
                    matches = soqlQuery(
                        f"SELECT Id, CreatedDate FROM {sObjectType} "
                        f"WHERE {where_sql} ORDER BY CreatedDate ASC"
                    )
                    if matches.totalSize >= 1:
                        survivor = matches.records[0].Id
                        if matches.totalSize >= 2:
                            # Composite committed AND our retry would have committed — collapse
                            # to oldest, delete the rest. Same rule as Step 6.1a Call 3.
                            for extra in matches.records[1:]:
                                try:
                                    deleteSobjectRecord(sObjectType, extra.Id)
                                except DeleteFailedError as e:
                                    if "ENTITY_IS_DELETED" not in e.message:
                                        log(f"reconcile: could not delete duplicate {sObjectType} {extra.Id}: {e.message}")
                        return survivor
                return None

            for idx, row in enumerate(chunk_slice):
                ref_id = chunk_keys[idx]
                where_clause = build_dedup_where(sObjectType, row["body"], refs, describe_cache)
                where_sql    = " AND ".join(where_clause) if where_clause else None

                adopted_id = reconcile_lookup(where_sql)

                if adopted_id:
                    # The composite POST DID commit this row — never re-submit it. This is
                    # what preserves the "never blind-replay the batch" hard rule: only rows
                    # that reconcile_lookup returned None for can even reach the retry path.
                    log(f"Step 6.1c reconcile: {sObjectType} ref={ref_id} — composite POST committed silently, adopting {adopted_id}.")
                    refs[ref_id] = adopted_id
                    continue

                # 90s bounded window closed with no match — the composite POST didn't commit
                # this specific row. Retry ONLY this row via single-record fallback, which
                # carries its own reconciliation ladder as a safety net against a second
                # timeout leaking a duplicate.
                log(f"Step 6.1c reconcile: {sObjectType} ref={ref_id} — no commit observed after 90s bounded window; retrying THIS row only via createSobjectRecord.")
                try:
                    newId = createSobjectRecord(sObjectType, row["body"])   # full Step 6.0a ladder applies
                except Exception as e:
                    log(f"Step 6.1c reconcile: {sObjectType} ref={ref_id} — createSobjectRecord raised: {e}. "
                        f"Running post-retry reconciliation to determine committed state.")
                    newId = None

                # POST-RETRY RECONCILIATION — the retry itself is not authoritative.
                # createSobjectRecord may have returned an Id but be lost mid-response, or may
                # have raised while still committing (createSobjectRecord's own ladder tries hard
                # not to duplicate, but Step 6.1c owns the final declaration of success). Query
                # the org one more time on the same natural key before accepting the retry.
                confirmed_id = reconcile_lookup(where_sql) if where_sql else newId
                if confirmed_id:
                    refs[ref_id] = confirmed_id
                    if newId and newId != confirmed_id:
                        log(f"Step 6.1c post-retry: {sObjectType} ref={ref_id} — retry returned {newId} but reconciliation adopted {confirmed_id} (duplicates already collapsed).")
                    else:
                        log(f"Step 6.1c post-retry: {sObjectType} ref={ref_id} — verified present in org (Id={confirmed_id}).")
                elif newId:
                    # No SOQL match yet, but createSobjectRecord returned an Id — trust the
                    # returned Id and let Step 6.4's final count gate catch any drift.
                    refs[ref_id] = newId
                    log(f"Step 6.1c post-retry: {sObjectType} ref={ref_id} — createSobjectRecord returned {newId}; org visibility still lagging, deferring final verification to Step 6.4.")
                else:
                    # Retry raised AND no reconciliation match — record the failure and let
                    # Step 6.4's count gate hard-fail. Do NOT retry again; the "retry only
                    # missing rows, exactly once" rule stands.
                    run.reconciliation_failures = run.reconciliation_failures or {}
                    run.reconciliation_failures[sObjectType] = run.reconciliation_failures.get(sObjectType, 0) + 1
                    log(f"Step 6.1c post-retry: {sObjectType} ref={ref_id} — retry failed AND no row visible in org. Deferring to Step 6.4 count gate.")
            continue                                                    # next chunk

        # ───── Chunk returned — walk the per-record result array ─────
        for idx, row_result in enumerate(resp["body"]):
            ref_id = chunk_keys[idx]
            if row_result.get("success") is True and row_result.get("id"):
                refs[ref_id] = row_result["id"]
                continue

            # Per-record rejection — Salesforce accepted the batch envelope but this specific row failed.
            errors = row_result.get("errors", [])
            error_summary = "; ".join(f"{e.get('statusCode','?')}: {e.get('message','?')}" for e in errors)

            # Fail-fast on deterministic errors that will fail the retry the same way.
            if any(e.get("statusCode") == "CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY" for e in errors):
                raise CannotInsertUpdateActivateEntity(f"{sObjectType} ref={ref_id}: {error_summary}")

            log(f"Step 6.1c: composite rejected {sObjectType} row {idx} (ref={ref_id}): {error_summary}. "
                f"Retrying THIS row only via createSobjectRecord.")
            newId = createSobjectRecord(sObjectType, chunk_slice[idx]["body"])   # full Step 6.0a ladder applies
            refs[ref_id] = newId
```

**Key contract points:**
- The composite POST **never** blindly replays after an ambiguous outcome. Whole-chunk failures fall through the per-row reconcile ladder; only rows that are still absent after a 90s bounded visibility window are retried via single-record `createSobjectRecord`, and each retry is followed by a post-retry reconciliation before being accepted.
- HTTP 5xx / timeout / malformed response is treated as AMBIGUOUS (may or may not have committed), never as FAILED. Classification lives at line ~1500 (`bulk_call_failed`); the ambiguous branch is the per-row reconcile ladder immediately below it.
- `refs[referenceId]` is written exactly once per row, regardless of which branch (composite success, composite-then-reconcile adoption, per-row fallback with post-retry confirmation) landed it. Only rows for which `reconcile_lookup` returned `None` can enter the retry path — this is what preserves the "never replay the batch" rule structurally.
- The single-record fallback path carries its own 4-read ladder (Step 6.0a) — so even a retry that itself times out cannot leak a duplicate. The post-retry reconciliation in Step 6.1c then re-queries the natural key one more time so the retry's own reported Id is never trusted blindly.
- The insert body handed to composite is byte-identical to the body the pre-refactor per-record path would have sent — all preflights and cleanups happen upstream in Step 6.1.

**Failure taxonomy — bulk vs fallback split:**

| Failure class | Path taken | Rationale |
|---|---|---|
| MCP tool times out / returns `None` (ambiguous outcome — chunk may or may not have committed) | **Per-row reconcile ladder (3s/7s/20s/15s/30s/15s = 90s bounded window) → adopt committed rows into refs → single-record fallback for genuinely missing rows only → post-retry reconciliation before accepting the retry** | Never blind-replay. SOQL confirms per-row commit state before any retry decision; only truly absent rows re-enter the create path; the retry itself is re-verified. The 90s window is a defensive ceiling, not a claim about Salesforce visibility SLA. |
| HTTP 4xx/5xx from Salesforce (e.g. `INVALID_SESSION_ID`, 500 during a scoped downtime) | Same 90s-window per-row reconcile ladder → per-row fallback for missing rows only → post-retry reconciliation | Same reason — SOQL is the tie-breaker on which rows committed. HTTP 5xx is ambiguous, never failed. |
| HTTP 200 but `body` is not the expected per-record array | Same 90s-window per-row reconcile ladder → per-row fallback → post-retry reconciliation | Defensive; a malformed shape means we can't trust the response, so we trust SOQL. |
| HTTP 200 + per-record `success:false` on some rows (e.g. `DUPLICATE_VALUE`, `INVALID_TYPE`, `REQUIRED_FIELD_MISSING`) | THAT row falls back to `createSobjectRecord`; successful sibling rows keep their bulk-returned Id | Composite's `allOrNone=false` guarantees siblings landed; only the rejected row needs the fallback (which raises the same error the pre-bulk skill would). |
| HTTP 200 + per-record `success:false` with `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` | Halt Step 6 immediately | The sObject is not creatable in this org (missing feature license). A retry cannot fix this — surface and stop. |
| HTTP 200 + all rows succeed | Composite path — no fallback | Happy path — the common case. Each row's Id captured into `refs` in submitted order. |

**Consistency guarantees preserved:**

- ✅ `refs` map contents at the end of the loop are byte-identical to the pre-bulk path (same `referenceId → Id` mapping order, same Ids captured).
- ✅ Order of insertions within a sObject batch is preserved (Salesforce's composite/sobjects processes records in submitted order).
- ✅ Cross-object ordering (Account → Contact → Product2 → PricebookEntry → …) is unchanged — bulk operates per-planEntry only, not across planEntries.
- ✅ Every row that lands via the fallback path went through the exact same `createSobjectRecord` call the pre-bulk skill used — no new failure modes.
- ✅ The verification gate at Step 6.3 doesn't need to know whether a row came from the bulk or fallback path; it queries the org by `CreatedDate = TODAY` regardless.

**Where the fallback path is unavailable (do NOT bulk-POST these sObjects — stay per-record for now):**

Some sObjects have platform-side quirks that make a bulk composite/sobjects insert risky today. The bulk-first loop MUST detect these and short-circuit straight to the per-record path:

- `User` (create-with-role/profile has an idempotency lag that the multi-read ladder handles per record; batch behavior on User is inconsistent)
- `PermissionSetAssignment` (single-row inserts are already fast and go through the `salesforce-sobject-all` MCP path; not a Step 6.1 sObject anyway)
- Any sObject listed in Step 6.1a's "Never dedup these sObjects" blocklist above — those are system objects and stay single-row

The blocklist for BULK is identical to the dedup-blocklist above, with `User` explicitly included regardless of whether it appears in `plan.json`.

**Instrumentation (recommended):** log per planEntry.sobject:

```
Step 6.1c bulk: planEntry.sobject={sObj}  rows={n}  chunks={c}  bulk_ok={ok_count}  per_row_fallback={fb_count}  chunk_fallback={cfb_count}  elapsed={ms}ms
```

Aggregate at end of Step 6:

```
Step 6.1c bulk summary:
  Total sObjects loaded via bulk:        {x}/{y}
  Total rows via bulk path:              {bulk_row_total}
  Total rows via per-record fallback:    {fallback_row_total}
  Total elapsed:                         {sec}s   (vs prior per-record baseline: ~5–6 min)
```

**Testing hooks — how to force the fallback path for a debug run:**

- Set env var `SKIP_BULK_INSERT=1` before running the skill → `step_6_1c_insert` bypasses the composite POST for **every** planEntry and routes each queued row through single-record `createSobjectRecord` (same code path as the trivial-object exception, one row at a time). Use this to A/B compare composite vs per-record timings, or to isolate a hang to composite-specific behavior. All other logic — dedup guard, `refs` capture, preflights, Step 6.4 verification — is unchanged; only the transport for the zero-match insert queue differs.
- The `SKIP_BULK_INSERT` env var must be checked at the top of `step_6_1c_insert` (same location as `SKIP_DEDUP=1` is checked in Step 6.1a) and short-circuit the composite branch without affecting any other logic.

---

**Special case — Person Accounts and cascaded PersonContact rows:** deleting a Person Account auto-deletes its Contact side (the PersonContact). Do NOT dedup Contact rows first when the incoming record is a Person Account, and do NOT try to delete the PersonContact directly — Salesforce returns `INVALID_CROSS_REFERENCE_KEY: Cannot directly delete PersonContact records`. The `IsPersonAccount = true` qualifier the algorithm adds automatically covers both sides.

**Special case — records referenced by later inserts:** if a matching pre-existing record is a hard prerequisite for a downstream insert AND the downstream reference resolves by lookup rather than by `@ref` (rare in this plan.json), the delete is fine because we re-insert immediately with the same natural key and the new Id lands in `refs` for downstream use. `@ref`-based lookups always resolve against `refs`, never against the org, so pre-existing rows never bleed into the reference map.

**Never dedup these sObjects (fixed blocklist — system objects that must remain intact):**

- `User`, `UserRole`, `Profile`, `PermissionSet`, `PermissionSetAssignment`, `PermissionSetLicense`, `PermissionSetLicenseAssign`, `PermissionSetGroup`, `PermissionSetGroupComponent`
- `RecordType`, `RecordTypeSetting`, `BusinessProcess`
- `Pricebook2` **when `IsStandard = true`** — the Standard Pricebook is a singleton. (Deleting non-standard Pricebook2 by Name is fine; the algorithm's Name-based match handles it.)
- `Organization`, `NetworkMember`, `Group`, `GroupMember`
- Anything on the `salesforce-sobject-all` MCP server's deny-list

If `plan.json` ever references any of the above, that's a bug in `plan.json` — surface it and stop.

**Idempotency:** the guard is safe on a first-time install (zero matches → zero deletes → straight to insert) and safe on the Nth re-install (deletes prior sample data + any trial-org duplicates before re-inserting fresh). Because it infers the key from the record body, it automatically handles every sObject `plan.json` grows into — no code changes needed to add support for a new object type.

**Removal path:** if a future run needs to *keep* the pre-existing records (e.g. a customer's real data got mixed into a stock trial org), the operator can disable this guard by setting `SKIP_DEDUP=1` in the environment before running the skill — Step 6.1a checks that env var at the top and returns immediately if set. Document the reason in the run log so the run report calls it out.

**🚨 Verification — MANDATORY HARD-FAIL GATE (runs after Step 6 finishes, BEFORE Step 6b):**

The verification query varies per sObject, because not every sObject has a groupable `Name` field. For each sObject in `plan.json`, pick the query shape from the table below (based on the sObject's describe result — do NOT hardcode by name; the same rule applies to any future sObject with the matching shape):

| sObject shape | Verification query |
|---|---|
| Has a `Name` field AND `Name` is groupable in aggregate SOQL (Account, Product2, Pricebook2, Medication, CodeSet, CodeSetBundle, Asset, Entitlement) | `SELECT Name, COUNT(Id) c FROM <type> WHERE Name != null GROUP BY Name HAVING COUNT(Id) > 1` |
| Person Account (Account with `IsPersonAccount = true`) | `SELECT FirstName, LastName, COUNT(Id) c FROM Account WHERE IsPersonAccount = true GROUP BY FirstName, LastName HAVING COUNT(Id) > 1` |
| Has a `Subject` field but no groupable `Name` (Task, Case, ServiceAppointment, Event) — `Subject` is filterable but NOT groupable in aggregate SOQL. Scan the created-today rows and dedupe client-side. | `SELECT Id, Subject FROM <type> WHERE CreatedDate = TODAY` — then group by `Subject` in-memory and flag any `Subject` with `count > <expected-from-data-file>`. Expected count comes from counting `Subject` values in the corresponding `data/*.json`. |
| Has a natural composite key — no `Name`, no `Subject`, but has 2+ filterable/groupable reference or scalar fields. **Use the exact composite key from the table below**; do NOT infer at runtime (ambiguity across agents produced the 2026-08-18 leak). | `SELECT <keyField1>, <keyField2>, COUNT(Id) c FROM <type> GROUP BY <keyField1>, <keyField2> HAVING COUNT(Id) > 1` |

**Composite-key table (for sObjects in this repo's `data/plan.json` that fall through the Name/Subject branches):**

| sObject | Composite key | Rationale |
|---|---|---|
| `PricebookEntry` | `Pricebook2Id + Product2Id` | A PricebookEntry is unique per pricebook+product; `UnitPrice` varies by revision. |
| `MedicationRequest` | `PatientId + MedicationId` | One active order per patient+medication is the business rule. `PrescribedDate` varies by refill. |
| `HealthCondition` | `PatientId + ConditionCodeId` | One recorded condition per patient+condition-code. `OnsetStartDateTime` shifts on re-diagnosis. |
| `PatientMedicalProcedure` | `PatientId + CodeId` | One recorded procedure per patient+procedure-code. `StartDate/EndDate` vary by encounter. |
| `AllergyIntolerance` | `PatientId + AllergyCodeId` | One recorded allergy per patient+allergen. |

When a future `plan.json` adds a new sObject that lands in this branch, add its composite key here rather than inferring at call time. If the schema is unclear, halt and ask — don't guess.
| No filterable natural key at all (rare — should not happen for anything in this repo's `data/`) | Log `verification skipped for <type> — no filterable natural key`. Do NOT hard-fail on skip; do NOT hard-pass either — surface it in the run summary so the operator can review. |

**Decision rule:**

- ✅ If EVERY sObject returns `totalSize = 0` (or the client-side Subject grouping finds no over-count) → proceed to Step 6b.
- ❌ If ANY sObject returns a duplicate group **whose key values appear in the corresponding `data/*.json` file** → HARD STOP. Print each duplicate group (sObject, key values, count, Ids), exit Step 6 with a non-zero code, and do NOT run Step 6b. The dedup guard in Step 6.1a missed something and the skill must not silently proceed.

This gate exists because silent duplicate-leaks were observed in the field:
- 2026-08-17 on `hcInstall`: three Person Accounts and 17 Product2 names ended up duplicated because the sub-agent read Step 6.1a as pseudocode and skipped the per-record dedup calls entirely.
- 2026-08-18 on `HCNewMedTechOrg18Aug`: 6 sObjects (Task, Case, MedicationRequest, HealthCondition, PatientMedicalProcedure, ServiceAppointment) silently skipped dedup because the auto-built WHERE clauses returned HTTP 400 (polymorphic references, quoted DateTime literals). The Name-only backstop query was also a no-op for those sObjects, so the gate passed while dirty rows remained. This edition adds: polymorphic-reference detection (Step 5 of the natural-key algorithm), quoted-DateTime prevention (Escape rule), HTTP-400-raises-not-warns policy (see the pseudocode above), and this per-sObject-shape verification table.

Flipping this from "informational" to "hard-fail" makes the same class of failure impossible to ship silently — Step 6.1a's per-record calls remain the primary defense; this gate is the defense-in-depth backstop that guarantees callers can trust the exit code.

**Do NOT auto-delete post-hoc.** The correct fix on a hard-fail here is to (a) manually clean the duplicates in the org, then (b) re-run the skill so Step 6.1a re-executes with the guarantee it did NOT run correctly the first time.

**Step 6.2 — Field-level handling (PREFLIGHT rules — apply BEFORE the first insert of each sObject type, not as error recovery).**

Every rule below is a **required preflight transformation** of the record body. Do not wait for Salesforce to reject an insert before applying them — that produces the exact wasted-cycle friction observed on `HCStrom14thAug2026Org1` (MedicationRequest failed once with `id value of incorrect type`, ServiceAppointment failed once with "Both scheduled start and end are required"). Apply the transformation deterministically the moment the record body is loaded from disk.

- **Phone fields containing numeric values** (e.g. `"Phone": -4171`): coerce to a string before insert.
- **`ServiceAppointment` temporal fields** (**MUST run before the first ServiceAppointment insert**): four fields participate in this rule — `SchedStartTime`, `SchedEndTime`, `EarliestStartTime`, `DueDate`. As of the current [data/serviceappointments.json](../../../data/serviceappointments.json), all four are populated explicitly on every record, so this preflight is a defensive validation layer, not a routine derivation path. Semantics per field, in order:
    - **present in source** → preserve the source value verbatim, log nothing.
    - **missing but deterministically derivable from another present field** → derive and emit a warning naming the specific record `referenceId`, the missing field, and the field derivation used (see table below). This branch exists only to prevent a fresh install from wedging if a future source-data edit removes one field by mistake; it is NOT a license to silently fabricate.
    - **missing and NOT deterministically derivable** → HARD FAIL before insert, naming the record `referenceId` and the specific missing fields. Do NOT invent arbitrary business times to satisfy a required-field validation.

    Deterministic derivations (applied only on the "missing but derivable" branch):
    - `SchedEndTime` missing + `SchedStartTime` present → `SchedEndTime = SchedStartTime + 1 hour` (matches the appointment length convention already used by every seeded record).
    - `EarliestStartTime` missing + `SchedStartTime` present → `EarliestStartTime = SchedStartTime` (the seeded convention: patient becomes eligible at the scheduled start).
    - `DueDate` missing + `SchedEndTime` present (or already-derived above) → `DueDate = SchedEndTime` (the seeded convention: appointment must complete by its scheduled end).
    - `SchedStartTime` missing → hard fail. Every other field derives from this one; without it, nothing is safely derivable.

    Salesforce's platform validation (with the FSL `Schedule_End_Required` rule deactivated in Step 11) does NOT reject a ServiceAppointment lacking `EarliestStartTime` or `DueDate` at insert-time, but downstream Field Service scheduling algorithms depend on both. Populating all four in source is the correct posture for a MedTech seed load. This preflight is the safety net.
- **`MedicationRequest.PatientId`** (**MUST run before the first MedicationRequest insert**): the field is a lookup to the **Account** object (specifically the Person Account row). If the resolved `@ref` value points at a `PersonContact` Id (Contact-side of a Person Account), walk up to the parent Person Account Id and substitute that. Detection: after resolving the `@ref`, call `getObjectSchema` if needed to identify the Id's sObject — a leading `003` key prefix is Contact/PersonContact and MUST be swapped to the parent Account Id (`001` prefix) via `SELECT AccountId FROM Contact WHERE Id = '<id>' AND IsPersonAccount = true LIMIT 1`. If the `@ref` already resolves to an Account Id, pass through unchanged. Salesforce rejects the record with `id value of incorrect type: <contactId>` if a Contact/PersonContact Id is passed.
- **Person Account `__pc` fields**: include them when present on Account's `createable` field list (they should be, because Step 3 assigned `PulseSyncBasePS` which grants their FLS). Otherwise drop them from the body.

**Preflight audit (recommended):** immediately after loading each sObject's data file and BEFORE the first `createSobjectRecord` call, iterate every record body once and log the transformations applied. This produces a paper trail for post-run debugging and makes it obvious when a rule was skipped.

**Step 6.3 — Verify.**

For each sObject in `plan.json`, run:

```
soqlQuery:
  SELECT COUNT(Id) c FROM <sObject> WHERE CreatedDate = TODAY
```

Report each sObject as `inserted / expected`, where `expected` is the record count in the corresponding data file:

```
MedTech data loaded into {username}
  Account              {n}/{N}
  Contact              {n}/{N}
  ...
```

If the run stopped early, report the sObject that blocked and any sObjects that did not run.

**Cleanup and re-run.** To re-run, delete the records inserted in this run before re-invoking the skill:

```
soqlQuery:         SELECT Id FROM <sObject> WHERE CreatedDate = TODAY
deleteSobjectRecord: per result
```

Delete in the reverse of `plan.json` order (leaves before parents). Otherwise deletes fail with `DELETE_FAILED: foreign key`. Auto-created PersonContact records may return 400 on delete; they cascade with the parent Person Account and the error can be ignored.

**Known issues to watch for:**

1. **`STANDARD_PRICEBOOK_ID` placeholder.** `pricebookentries.json` contains the literal string `"STANDARD_PRICEBOOK_ID"`. Substitute in memory at runtime (Step 6.1); do not commit a per-org patched file.
2. **`PulseSyncBasePS` and field visibility.** Custom fields such as `License_Number__c` return `INVALID_FIELD` until the permission set is assigned. Step 3 handles this, and Step 3.4/3.5 verify it landed. If `INVALID_FIELD` persists after a freshly-assigned permission set, apply the Step 3.5 backoff (which handles runtime-schema propagation lag) rather than reconnecting the MCP server.
3. **`CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`.** The sObject is not creatable in the target org. Surface the error and stop.
4. **`UNABLE_TO_LOCK_ROW`.** Caused by parallel inserts of records sharing the same parent record. Insert serially within each sObject step (Step 6.1's plan-order iteration handles this).

**Success criteria:**
- Every sObject in `plan.json` was iterated in plan order.
- `@ref` substitutions all resolved (no unknown references).
- `STANDARD_PRICEBOOK_ID` was replaced with `<standardPricebookId>` for every `PricebookEntry`.
- Person Account records received `<personAccountRecordTypeId>` and had `Type` removed.
- Per-sObject `inserted / expected` counts reported.

---

**Step 6.4 — Post-load per-sObject count gate (HARD GATE, blocks Step 6b).**

Step 6.3 reports what the loader claims. Step 6.4 asserts what the org actually contains. **Both are required.**

**Step 6.4.1 — Compute expected counts from `data/plan.json`.**

For each sObject in `plan.json`, load its data file(s) and count `.records[]`. This is the ground-truth "expected" count for that sObject in this install. Cache the map `{sObjectType: expected_count}`.

For the shipped MedTech Solution Kit, expected counts are:

| sObject | Expected |
|---|---|
| Account | 4 |
| Contact | 2 |
| Task | 1 |
| Case | 10 |
| Product2 | 12 |
| Pricebook2 | 1 |
| PricebookEntry | 24 |
| CodeSet | 18 |
| CodeSetBundle | 18 |
| Medication | 5 |
| MedicationRequest | 5 |
| AllergyIntolerance | 6 |
| HealthCondition | 4 |
| PatientMedicalProcedure | 4 |
| Asset | 3 |
| Entitlement | 3 |
| ServiceAppointment | 7 |
| **Total** | **127** |

Recompute from `data/plan.json` at runtime — do not hard-code these numbers in the sub-agent's Python or JS. The table above is a reference for the operator; the runtime source of truth is `plan.json` + the referenced JSON files.

**Step 6.4.2 — Per-sObject verification strategy (three shapes).**

The generic "count created since `<install_start_ts>`" query works for most sObjects but has two known false-negative shapes on Health Cloud orgs, both surfaced by the 2026-08-20 Org2 test. Use the per-sObject rules below rather than the generic count in isolation:

**Shape A — Bulk-count-since-anchor (default):** For sObjects that have no pre-existing rows in a stock org (Account, Contact, Task, Case, Product2, Pricebook2 non-standard, CodeSetBundle, Medication, MedicationRequest, AllergyIntolerance, HealthCondition, PatientMedicalProcedure, Asset, Entitlement, ServiceAppointment):

```
mcp__salesforce-sobject-all__soqlQuery
  q: "SELECT COUNT(Id) c FROM <sObjectType> WHERE CreatedDate >= <install_start_ts>"
```

Cache the response as `{sObjectType: created_since_start_count}`. Compare against expected in Step 6.4.3.

**Shape B — Natural-key per-record verification (for sObjects where the Health Cloud managed package or org bootstrap seeds rows):**

- **CodeSet** — the Health Cloud managed package pre-installs ~25 CodeSets. A raw `COUNT(Id) FROM CodeSet` returns 43+ against 18 expected, which is a false negative on the shortfall check. Instead, load the expected `Code` values from `data/codesets.json` and verify each row is present:
  ```
  mcp__salesforce-sobject-all__soqlQuery
    q: "SELECT Code FROM CodeSet WHERE Code IN (<comma-separated Code values from codesets.json>)"
  ```
  Expected: `totalSize == 18` (or whatever count `codesets.json` contains at runtime). Every `Code` from `codesets.json` must appear exactly once in the response set. Missing codes list = expected − returned.

**Shape C — Foreign-key-scoped count (for junction/entry tables where the parent table is pre-populated):**

- **PricebookEntry (Standard Pricebook)** — the Standard Pricebook on a stock trial org already contains ~130+ entries from unrelated CPQ / product bootstrap. A raw `COUNT(Id) FROM PricebookEntry WHERE Pricebook2Id = <standardPricebookId>` returns 145+ against 12 expected, again a false negative. Instead, scope the count to the 12 Product2 Ids this installer created:
  ```
  mcp__salesforce-sobject-all__soqlQuery
    q: "SELECT COUNT(Id) c FROM PricebookEntry WHERE Pricebook2Id = '<standardPricebookId>' AND Product2Id IN (<12 Product2 Ids from refs map>)"
  ```
  Expected: `12`. The `Product2Id IN (...)` clause is populated from `refs` after Step 6.1 finishes inserting Products.

- **PricebookEntry (MedTech Pricebook)** — the non-standard MedTech Pricebook is created fresh by this install, so Shape A applies (bulk count since anchor).

**Adding future sObjects:** if a new `plan.json` entry falls into Shape B or C, add its verification rule here. A new sObject with no pre-existing org state defaults to Shape A. **Never** rely on Shape A for a table the managed package or org bootstrap may seed — surface Shape B/C explicitly.

**Step 6.4.2.1 — Query the org for records created since Step 6 started, per sObject (Shape A only).**

**Timestamp anchor (required):** Step 6.0 must capture the SOQL-formatted current time before the first `createSobjectRecord` call:

```
mcp__salesforce-sobject-all__soqlQuery
  q: "SELECT SystemModstamp x FROM Organization LIMIT 1"
```

Take the returned `x` value (an ISO-8601 datetime like `2026-08-18T13:45:22.000+0000`) and cache it as `<install_start_ts>`. This is the anchor Step 6.4 will compare against — it does NOT drift with the org's Locale timezone and is safe across UTC midnight boundaries.

(If Step 6.0 was already invoked earlier for Person Account RecordType resolution, capture the anchor there. If not, capture it at the top of Step 6 before Step 6.1's plan iteration begins.)

For each sObject in the expected-count map, query counts since the anchor:

```
mcp__salesforce-sobject-all__soqlQuery
  q: "SELECT COUNT(Id) c FROM <sObjectType> WHERE CreatedDate >= <install_start_ts>"
```

Note: the `<install_start_ts>` value goes INTO the SOQL literally, WITHOUT quotes — DateTime literals in SOQL are unquoted (see Step 6.1a's SOQL escape rule). Example rendered query: `SELECT COUNT(Id) c FROM Account WHERE CreatedDate >= 2026-08-18T13:45:22.000+0000`.

Cache the response as `{sObjectType: created_since_start_count}`.

**Why not `CreatedDate = TODAY`:** the `TODAY` literal uses the org's Locale timezone. An install that starts at 11pm local time and finishes at 1am the next day would report 0 records for everything inserted after midnight — a false hard-fail. Anchoring against a UTC timestamp captured at run-start eliminates this edge case entirely.

**Step 6.4.3 — Compare and hard-fail on any shortfall.**

For each sObject in `plan.json`, apply the pass/fail rule that matches its verification shape from Step 6.4.2:

- **Shape A (bulk count since anchor):**
  - ✅ `created_since_start >= expected` → PASS.
  - ❌ `created_since_start < expected` → shortfall.

- **Shape B (natural-key per-record — CodeSet):**
  - ✅ Every expected `Code` from `codesets.json` appears exactly once in the response → PASS.
  - ❌ Any expected `Code` is missing → shortfall. Report the missing `Code` values by name.

- **Shape C (FK-scoped count — Standard PricebookEntry):**
  - ✅ Scoped `COUNT(Id) == 12` (or whatever `pricebookentries.json` count is at runtime for the Standard Pricebook) → PASS.
  - ❌ Scoped count < expected → shortfall.

If EVERY sObject passes → advance to Step 6b.
If ANY sObject fails → HARD FAIL with a per-sObject report:

```
❌ Step 6.4 gate — one or more sObjects have fewer records than plan.json expected.

Shortfalls:
  <sObject>          expected=<N>  actual=<n>  missing=<N-n>
  <sObject>          expected=<N>  actual=<n>  missing=<N-n>

Full per-sObject counts:
  Account                        expected=4    actual=4    ✅
  Contact                        expected=2    actual=2    ✅
  ...
  PatientMedicalProcedure        expected=4    actual=0    ❌ MISSING 4

The Step 6 loader reported success but the org's SOQL disagrees. This can
happen when:
  - the loader bypassed MCP (see Step 6 channel enforcement) and its
    per-record errors weren't surfaced;
  - a REQUIRED_FIELD_MISSING or CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY hit
    silently mid-batch;
  - the sObject's feature license is not present in this org.

Action required: do NOT proceed to Step 6b or any downstream skill. Fix the
root cause (re-check the loader channel, verify feature licenses, inspect
the plan.json entry) and re-run Step 6 from the failing sObject onward.
Step 6.1a's dedup guard makes the re-run safe — records already present
are deleted before re-insertion.
```

**Idempotency:** safe to re-invoke. On a re-run against an already-loaded org, `CreatedDate = TODAY` will only count records inserted since local midnight — this correctly measures the current run's inserts, not accumulated inserts from prior partial runs.

**Trust chain (Step 6b may run only when ALL are true):**

1. Step 6.1 iterated every sObject in `plan.json` in plan order.
2. Step 6.1a's dedup guard ran on every record (per its own detection rule, including HTTP-400 halt on malformed WHERE).
3. Step 6.2 field-level handling ran (Phone coercion, ServiceAppointment temporal-fields defensive validation over SchedStartTime / SchedEndTime / EarliestStartTime / DueDate, __pc fields).
4. Step 6.3 reported per-sObject `inserted / expected` counts from the loader's memory.
5. **NEW:** Step 6.4's SOQL-verified counts match `plan.json` expected for every sObject.

If ANY of the five is not satisfied, Step 6b must NOT run.

**Log to the user on success:**

```text
✅ Step 6.4 — All 17 sObjects match plan.json expected counts (127/127 records verified in org).
   Advancing to Step 6b (Data Cloud copy-field permissions)...
```

---

### Step 6b — Enable Data Cloud copy-field permissions and link Assets to Contacts (MCP)

Uses `salesforce-sobject-all` MCP tools (`soqlQuery`, `createSobjectRecord`, `updateSobjectRecord`) to enable copy-field permissions and link Assets to Contacts. Runs AFTER the data load because its final pass links inserted Assets to inserted Contacts — running it earlier would be a no-op for that part. Do NOT run any Apex script for this step.

The step has four halves: (a) resolve the target permission set, (b) grant FLS on five Contact fields, (c) grant object-level permissions on Contact + Account, and (d) link Assets to their Account's HealthCloud Contact.

**Step 6b.1 — Resolve the permission set.**

```
soqlQuery:
  SELECT Id FROM PermissionSet
  WHERE Label = 'Customer 360 Data Platform Integration' LIMIT 1
```

If zero rows are returned, the prerequisite permission set is missing — skip the rest of Step 6b and surface the issue.

Cache the returned Id as `<permSetId>`.

**Step 6b.2 — Field permissions on Contact.**

For each of these five fields:
- `Last_Transmission__c`
- `Battery_Score__c`
- `Pacing_Performance_Score__c`
- `Unified_Individual_Id__c`
- `Atrial_Risk_Score__c`

Query for an existing FieldPermissions row:

```
soqlQuery:
  SELECT Id, PermissionsRead, PermissionsEdit FROM FieldPermissions
  WHERE ParentId = '<permSetId>'
    AND SobjectType = 'Contact'
    AND Field = 'Contact.<field>'
  LIMIT 1
```

- If the row is missing, `createSobjectRecord` on `FieldPermissions` with `{ ParentId, SobjectType: "Contact", Field: "Contact.<field>", PermissionsRead: true, PermissionsEdit: true }`.
- If the row exists and either `PermissionsRead` or `PermissionsEdit` is not `true`, `updateSobjectRecord` to set both flags to `true`.
- If both flags are already `true`, skip — no DML.

**Step 6b.3 — Object permissions on Contact and Account.**

For each object in `['Contact', 'Account']`:

```
soqlQuery:
  SELECT Id, PermissionsRead, PermissionsCreate, PermissionsEdit,
         PermissionsDelete, PermissionsViewAllRecords,
         PermissionsModifyAllRecords
  FROM ObjectPermissions
  WHERE ParentId = '<permSetId>' AND SObjectType = '<object>'
  LIMIT 1
```

- If the row is missing, `createSobjectRecord` on `ObjectPermissions` with `{ ParentId, SObjectType, PermissionsRead: true, PermissionsCreate: true, PermissionsEdit: true, PermissionsDelete: true, PermissionsViewAllRecords: true, PermissionsModifyAllRecords: true }`.
- If the row exists, check each flag in this dependency order — set any missing flag to `true`, then `updateSobjectRecord` once with all the needed changes:
  1. `PermissionsRead`
  2. `PermissionsEdit`
  3. `PermissionsCreate`
  4. `PermissionsDelete`
  5. `PermissionsViewAllRecords`
  6. `PermissionsModifyAllRecords`
- If all six are already `true`, skip — no DML.

The dependency order matters because Salesforce rejects assignments that violate prerequisites (e.g., setting `PermissionsCreate` requires `PermissionsRead` first).

**Step 6b.4 — Link Assets to HealthCloud Contacts (`contactUpdationIntoAsset()`).**

**Selector predicate — `isHealthCloudRecord__c = true` (why this field, and how to handle cardinality):**

The Contact used to own a MedTech Solution Kit Asset is the one whose Person Account has `isHealthCloudRecord__pc = true` in `accounts.json` — this flag cascades to the Contact side as `isHealthCloudRecord__c = true`. That's the single-source-of-truth marker for "this is the clinically-linked Contact." In the shipped `data/accounts.json`, exactly ONE Person Account (Mark Smith, `personAccRef1`) has this flag set to `true`; John Smith (`personAccRef2`) is `false` intentionally. Production orgs might have zero, one, or (via customer configuration or a partial prior install) multiple HealthCloud PersonAccounts. Handle all three cases explicitly — never pick arbitrarily.

Query the HealthCloud Contacts that have a parent Account:

```
soqlQuery:
  SELECT Id, AccountId FROM Contact
  WHERE isHealthCloudRecord__c = true AND AccountId != null
```

**Cardinality decision rule (per Account):**

Build a map `AccountId → [ContactId, ...]` from the query result. For each Asset processed in the next query, look up the parent's Account:

- **0 matches for the Asset's AccountId** → the parent Account has no HealthCloud Contact. **STOP this step and surface the issue.** Do NOT `updateSobjectRecord` on the Asset with `ContactId: null` — leaving Assets in an unlinked state is preferable to silently masking a data-shape problem in `accounts.json`. Log:
  ```
  🛑 Step 6b.4 — Asset <assetId> attached to Account <accountId>, but no
     Contact with isHealthCloudRecord__c = true exists for that Account.
     Expected: exactly 1 HealthCloud Contact per parent Account of an Asset.
     Check accounts.json — the corresponding Person Account should have
     isHealthCloudRecord__pc = true so the __c cascade populates the Contact.
     Skipping Asset link and continuing to Step 11.
  ```
  Log a WARNING but do not hard-fail — Step 11 and Step 12 should still run so the operator sees the full run summary. Track unlinked Asset Ids in `run.assets_missing_healthcloud_contact` and include them in Step 12.

- **Exactly 1 match** → the happy path. If `Asset.ContactId != <matched ContactId>`, `updateSobjectRecord` on `Asset` with `{ ContactId: <matched ContactId> }`. Skip Assets whose `ContactId` already matches.

- **>1 matches for the Asset's AccountId** → ambiguity. Multiple Contacts under the same parent Account both claim to be the HealthCloud Contact. **STOP and surface the issue** — do NOT pick the first one arbitrarily. Log:
  ```
  🛑 Step 6b.4 — Asset <assetId> attached to Account <accountId>, but
     <n> Contacts under that Account have isHealthCloudRecord__c = true:
       <contactId1>
       <contactId2>
       ...
     The linker requires exactly 1 HealthCloud Contact per Account so the
     Asset→Contact link is deterministic. Manual resolution required: pick
     the intended Contact, set isHealthCloudRecord__c = false on the others,
     then re-run this skill. Step 0.5's resume-state safeguard will pick up
     from this step.
  ```
  Track ambiguous Asset Ids in `run.assets_ambiguous_healthcloud_contact` and include them in Step 12. Do not update those Assets in this run.

Query the Assets attached to those Accounts (still runs even if some Accounts fall into the 0-match branch — we want to log the misses):

```
soqlQuery:
  SELECT Id, AccountId, ContactId FROM Asset
  WHERE AccountId IN (<full set of Account IDs from Assets, not just the map keys>)
```

Then iterate each Asset and apply the cardinality rule above.

**Success criteria:**
- Five Contact FieldPermissions rows present with both `PermissionsRead` and `PermissionsEdit` set to `true`.
- Contact + Account ObjectPermissions rows present with all six flags set to `true`.
- Every **deterministically linkable** Asset has its `ContactId` pointing at the single HealthCloud Contact under its parent Account (the "exactly 1 match" branch of the cardinality rule). Assets whose parent Account has 0 matches OR >1 matches are intentionally left unchanged, tracked in `run.assets_missing_healthcloud_contact` / `run.assets_ambiguous_healthcloud_contact`, and surfaced in Step 12's final summary. A run with non-empty `run.assets_*` counters is still a successful run — the linker is deterministic-only and refuses to guess.

---

### Step 6c — Create Clinical Care Coordinator User — MOVED

> **This step has moved.** The `Care Coordinator` Profile and `Care_Coordinator` UserRole required to create this user ship in **ps-post-pack**, not ps-base — so this step now lives in the [agent-setup-configuration](../agent-setup-configuration/SKILL.md) skill as **Step 6b**, immediately after the ps-post-pack deploy. Skip this step here and do not create the user during base-metadata-deploy; the required profile/role won't exist yet and the SOQL lookups will fail.

The content below is retained as historical reference only — do NOT execute it during base-metadata-deploy.

<details>
<summary>Legacy content (do not execute)</summary>

Seeds the `Clinical Care Coordinator` User that the `Cardiologist_Appointment` flow (ps-post-pack) looks up by full name. Without this user the flow's `Get_User` node returns zero rows, its downstream `Task.OwnerId` assignment gets a null, and the agent's "Book an appointment with my cardiologist" action fails at runtime.

Uses `salesforce-sobject-all` MCP tools (`soqlQuery`, `createSobjectRecord`) to create the user. Do NOT run any Apex script for this step.

**Step 6c.1 — Idempotency preflight.**

```
soqlQuery:
  SELECT Id FROM User
  WHERE FirstName = 'Clinical' AND LastName = 'Care Coordinator'
  LIMIT 1
```

If a row is returned, skip the rest of Step 6c and log `Clinical Care Coordinator user already exists (<Id>)`. Re-running this step on a subsequent install must NOT create a duplicate — the flow only looks up by full name and any matching user satisfies it.

**Step 6c.2 — Resolve Profile Id.**

```
soqlQuery:
  SELECT Id FROM Profile WHERE Name = 'Care Coordinator' LIMIT 1
```

Cache as `<profileId>`. If zero rows, STOP — `ps-base` metadata deploy did not complete (the profile ships with ps-base). Surface the issue rather than skipping.

**Step 6c.3 — Resolve UserRole Id.**

```
soqlQuery:
  SELECT Id FROM UserRole WHERE DeveloperName = 'Care_Coordinator' LIMIT 1
```

Cache as `<roleId>`. If zero rows, STOP — same reason as 6c.2.

**Step 6c.4 — Insert the User.**

Generate a unique-per-install suffix so re-runs against fresh orgs don't collide on `Username` (which is org-global unique across all Salesforce orgs). Use a random millisecond-scale timestamp:

- `unique` = current epoch millis as string (e.g. `1783511634637`)
- `aliasSuffix` = last 3 chars of `unique` (e.g. `637`)
- `alias` = first 8 chars of `"cr" + aliasSuffix`

```
createSobjectRecord:
  sobjectType: User
  data:
    FirstName: "Clinical"
    LastName: "Care Coordinator"
    Email: "cccare<unique>@test.com"
    Username: "cccare<unique>@test.com"
    Alias: "<alias>"
    ProfileId: "<profileId>"
    UserRoleId: "<roleId>"
    TimeZoneSidKey: "America/Chicago"
    LocaleSidKey: "en_US"
    EmailEncodingKey: "UTF-8"
    LanguageLocaleKey: "en_US"
```

**Success criteria:**
- Exactly one User with `FirstName = 'Clinical'` AND `LastName = 'Care Coordinator'` AND `IsActive = true` exists after this step.
- `Cardiologist_Appointment` flow's `Get_User` node (filter `Name = 'Clinical Care Coordinator'`) will now resolve.

**Verification (optional but recommended):**

```
soqlQuery:
  SELECT Id, Name, IsActive, Profile.Name FROM User
  WHERE Name = 'Clinical Care Coordinator' LIMIT 1
```

Expected: 1 row, `IsActive = true`, `Profile.Name = 'Care Coordinator'`.

**Step 6b runs exclusively through the `salesforce-sobject-all` MCP path above.** Do not switch channels for it. (Step 6c has moved to [agent-setup-configuration](../agent-setup-configuration/SKILL.md) Step 6b.)

</details>

---

### Step 11 — Deactivate FSL `Schedule_End_Required` validation rule on ServiceAppointment (Tooling API)

**Why:** The FSL managed package ships an active validation rule on `ServiceAppointment` named `Schedule_End_Required` (FullName: `ServiceAppointment.FSL__Schedule_End_Required`), formula `ISNULL(SchedEndTime) && NOT(ISNULL(SchedStartTime))`, error message *"Both scheduled start and end are required"*. It fires whenever a caller sets `SchedStartTime` without also setting `SchedEndTime`. The `Create_Service_Appointment` flow in ps-post-pack (called by the Agentforce Service Agent) passes only `SchedStartTime` + `EarliestStartTime` + `DueDate` — it does NOT populate `SchedEndTime` — so every agent-invoked Service Appointment creation fails with `FIELD_CUSTOM_VALIDATION_EXCEPTION` until this rule is deactivated. Observed 2026-08-18 on `HCNewMedTechOrg18Aug` after Step 10 activated the Agentforce Service Agent.

**Idempotency & scope:** the rule is a managed-package component (`NamespacePrefix=FSL`, `ManageableState=installed`) — its `Active` flag is toggleable per-org via Tooling API even though its formula/message cannot be edited. Only the `Active` flag is changed; formula, message, and error-display field are preserved verbatim. Safe on first-time runs (rule active → gets deactivated), safe on re-runs (already inactive → no-op).

**Step 11.1 — Locate the rule (Tooling API SOQL).**

The `salesforce-sobject-all` MCP does not expose Tooling API objects. The `salesforce-headless-360` MCP `dispatch_readonly` route for `/services/data/vXX.X/tooling/query` has been observed as intermittently unsupported on the currently-installed MCP server (`ROUTE_NOT_FOUND` on v64.0 in the 2026-08-20 test; `ROUTE_NOT_FOUND`-equivalent on v66.0 in the 2026-08-25 run). To avoid an install-time fallback dance, the **primary** lookup channel is the Salesforce CLI's `--use-tooling-api` flag, which has worked consistently across every run. The single-row `GET` and the PATCH itself remain on `dispatch` / `dispatch_readonly` because those routes DID work in the same 2026-08-25 run.

**⚠️ Two field/version constraints (both verified via failure on 2026-08-20 Org2 test — they apply to every Tooling channel, CLI or MCP):**

1. **The filterable field is `ValidationName`, NOT `DeveloperName`.** `ValidationRule.DeveloperName` throws `INVALID_FIELD` when used in a Tooling API SOQL WHERE clause. The correct filterable identifier is `ValidationName`.
2. **API version `v66.0` on the `salesforce-headless-360` routes.** `salesforce-headless-360`'s Tooling routing returned `ROUTE_NOT_FOUND` for `/services/data/v64.0/tooling/...` on the Org2 test; `v66.0` is the pinned MCP-side version. Salesforce itself continues to support v41–v68 org-wide — the `sf` CLI accepts whatever default API version it ships with, and the `--use-tooling-api` route is available on every currently-shipping CLI build.

**⚠️ Do NOT select `FullName` in a multi-row Tooling query.** `ValidationRule.FullName` is only queryable when the WHERE clause resolves to a single row; a multi-row `SELECT Id, FullName, ...` returns `MALFORMED_QUERY: When retrieving results with Metadata or FullName fields, the query qualifications must specify no more than one row for retrieval.` Filter by `EntityDefinition.QualifiedApiName + ValidationName + NamespacePrefix` (all queryable in bulk) and read `Metadata`/`FullName` only via the single-record GET endpoint.

**PRIMARY — Salesforce CLI `--use-tooling-api` lookup** (preserves the exact SOQL semantics required: `EntityDefinition.QualifiedApiName = 'ServiceAppointment'` AND `ValidationName = 'Schedule_End_Required'` AND `NamespacePrefix = 'FSL'`):

```bash
sf data query \
    --target-org <org_alias> \
    --use-tooling-api \
    --query "SELECT Id, ValidationName, NamespacePrefix, Active FROM ValidationRule WHERE EntityDefinition.QualifiedApiName = 'ServiceAppointment' AND ValidationName = 'Schedule_End_Required' AND NamespacePrefix = 'FSL'" \
    --json
```

Parse `result.records`. If empty, the FSL package isn't installed in this org — log `Step 11: Schedule_End_Required not present — skipping (FSL package not installed)` and proceed to Step 12. If exactly one row, cache the returned `Id` as `<validationRuleId>` and its `Active` flag for the Step 11.2 idempotency gate.

**Fallback (only if the CLI is unavailable in the runtime environment)** — the pre-existing MCP `dispatch_readonly` route with the same SOQL. Note: as of the 2026-08-25 run, this route has been observed as `ROUTE_NOT_FOUND`, so treat it as a fallback and do NOT wait on it if the CLI already succeeded:

```
mcp__salesforce-headless-360__dispatch_readonly
  method: GET
  url:    /services/data/v66.0/tooling/query?q=SELECT+Id%2CValidationName%2CNamespacePrefix%2CActive+FROM+ValidationRule+WHERE+EntityDefinition.QualifiedApiName+%3D+%27ServiceAppointment%27+AND+ValidationName+%3D+%27Schedule_End_Required%27+AND+NamespacePrefix+%3D+%27FSL%27
```

After a successful lookup (from either channel), fetch the current `Metadata` payload for the PATCH body using the single-record GET endpoint. The 2026-08-25 run confirmed this endpoint DOES work on the MCP `dispatch_readonly` channel — keep it here rather than switching to the CLI for one call:

```
mcp__salesforce-headless-360__dispatch_readonly
  method: GET
  url:    /services/data/v66.0/tooling/sobjects/ValidationRule/<validationRuleId>
```

**Step 11.2 — Read current `Active` state (idempotency check).**

If the retrieved record shows `Active: false` (both the top-level `Active` field AND `Metadata.active` will be `false`), log `Step 11: Schedule_End_Required already inactive — no change needed` and proceed to Step 12. **Do NOT PATCH an already-inactive rule** — it produces an audit-trail entry with no functional change.

**Step 11.3 — Deactivate via Tooling API PATCH.**

If `Active: true`:

```
mcp__salesforce-headless-360__dispatch
  method: PATCH
  url:    /services/data/v66.0/tooling/sobjects/ValidationRule/<validationRuleId>
  body:
    Metadata:
      active:               false
      description:          null   # preserve the current value verbatim (usually null)
      errorConditionFormula: "ISNULL(SchedEndTime) && NOT(ISNULL(SchedStartTime))"
      errorDisplayField:    "SchedEndTime"
      errorMessage:         "Both scheduled start and end are required"
```

Expected response: HTTP `204 No Content` with an empty body. That is the success signal for Tooling API PATCH — do NOT treat the empty body as a failure.

**Step 11.4 — Verify (explicit ValidationRule state check).**

After the PATCH, explicitly verify the resulting state via BOTH channels this skill uses so a channel-specific caching quirk cannot mask drift:

1. **Primary — Salesforce CLI** (same `--use-tooling-api` route used in Step 11.1):
   ```bash
   sf data query \
       --target-org <org_alias> \
       --use-tooling-api \
       --query "SELECT Id, Active FROM ValidationRule WHERE Id = '<validationRuleId>'" \
       --json
   ```
   Expect `result.records[0].Active == false`.

2. **Secondary — MCP single-row GET** (already known to work on `dispatch_readonly`):
   ```
   mcp__salesforce-headless-360__dispatch_readonly
     method: GET
     url:    /services/data/v66.0/tooling/sobjects/ValidationRule/<validationRuleId>
   ```
   Expect BOTH the top-level `Active: false` AND `Metadata.active: false`.

If any of the three assertions returns `true` (or the queries fail), surface the discrepancy and stop; do NOT proceed to Step 12.

**Success criteria:**
- Rule located, or Step 11 was a documented no-op (rule not present in this org).
- If located and previously active, it is now `Active: false` at the Tooling API layer.
- Formula, message, and error-display field values are unchanged.
- The downstream Agentforce `Create Service Appointment` flow no longer throws `FIELD_CUSTOM_VALIDATION_EXCEPTION` when creating records with `SchedStartTime` populated but `SchedEndTime` null.

**Do NOT re-activate.** This is a permanent runtime configuration for MedTech installs — the flow authorship has no equivalent SchedEndTime input. Re-activating would silently break agent-invoked appointment creation.

---

### Step 12 — Generate Final Summary

Report comprehensive deployment summary:

```text
✅ Base Metadata Deployment Complete!

Target Org: <org_alias>
Repository Path: <current working directory>

═══════════════════════════════════════════════════

📦 Metadata Deployment:
✅ Status: Succeeded
✅ Components Deployed: <count>
✅ Deployment ID: <deployment_id>
✅ Duration: <duration> minutes

═══════════════════════════════════════════════════

🎫 Permission Set License Assignments (via MCP):
✅ Health Cloud (HealthCloudGA_HealthCloudPsl)   (Step 1a-PSL — assigned to <username>)
✅ Health Cloud Platform (HealthCloudPlatformPsl) (Step 1a-PSL — assigned to <username>)

🔐 Permission Set Assignments (via MCP):
✅ HealthCloudFoundation             (Step 1a — assigned to <username>)
✅ HealthCloudUtilizationManagement  (Step 1a — assigned to <username>)
✅ DiseaseSurveillance               (Step 1a — assigned to <username>)
✅ PulseSyncBasePS                   (Step 3  — assigned to <username>)
✅ Customer 360 Data Platform Integration (Step 6b — permissions configured)

═══════════════════════════════════════════════════

💰 Price Book Configuration:
✅ Standard Price Book activated
✅ Standard Price Book Id: <pricebook_id>
✅ Price Book Entries updated from data/pricebookentries.json

═══════════════════════════════════════════════════

📊 Sample Data Import (via MCP, from data/plan.json):
✅ Status: Completed
✅ Records Imported: <record_count>

Imported Objects (in plan.json order):
  • Every sObject listed in data/plan.json — reported per-sObject
    as inserted / expected in Step 6.3's verification block.

═══════════════════════════════════════════════════

✅ Base Metadata Deployment Successful!

Next Steps:
1. Verify sample data in Salesforce UI
2. Verify Price Book Entries exist
4. Proceed with Data Kit deployment if needed
```

---

### Step N-final — Durable state write (mandatory, before returning to caller)

After Step 12 prints the final summary and every prior gate has passed, this skill must record its completion in the shared state file so the parent orchestrator can advance to the next skill.

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since Step 0-DS).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs).

3. Update ONLY these fields:
   - Append `"base-metadata-deploy"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.base-metadata-deploy`:
     ```jsonc
     {
       "deployId": "<Step 2 $DEPLOY_ID>",
       "componentsDeployed": <number>,
       "standardPricebookId": "<Step 5 cached Id>",
       "personAccountRecordTypeId": "<Step 6.0 cached Id>",
       "refsMap": { /* Step 6.1 refs map — full referenceId → real Id mapping */ },
       "recordCounts": {
         "Account": <n>, "Contact": <n>, "Task": <n>, "Case": <n>,
         "Product2": <n>, "Pricebook2": <n>, "PricebookEntry": <n>,
         "CodeSet": <n>, "CodeSetBundle": <n>, "Medication": <n>,
         "MedicationRequest": <n>, "AllergyIntolerance": <n>,
         "HealthCondition": <n>, "PatientMedicalProcedure": <n>,
         "Asset": <n>, "Entitlement": <n>, "ServiceAppointment": <n>
       },
       "fslRuleDeactivated": true | false,
       "assetsMissingHealthCloudContact": [ /* Step 6b.4 0-match Asset Ids */ ],
       "assetsAmbiguousHealthCloudContact": [ /* Step 6b.4 >1-match Asset Ids */ ],
       "completedTs": "<ISO-8601 timestamp>"
     }
     ```
   - Append to `state.warnings` any non-blocking issues surfaced during this run (Step 3.6 FieldDefinition mismatches, Step 6.0a reconciliation failures, Step 6b.4 unlinked-Asset cases, etc.).
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY prior step in this skill did NOT reach its intended outcome (e.g. deploy failed, Step 6.4 count gate failed, Step 11 FSL rule not deactivated), do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; Step 0-DS's "already complete" check will correctly identify that the prior attempt did not finish, and the resume-state safeguard at Step 0.5 will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. This skill has no reason to write secrets — only IDs, counts, timestamps, and flags. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"consumerKeyPresent": true` rather than the value.

---

## Error Handling

### Repository Errors

**Repository not found:**
```text
❌ Repository Error

Error: cwd is not the Data360 repo root (sfdx-project.json missing)

Suggested Fix:
1. Re-invoke the data360-healthcare-installer agent — its Step 0 will clone
   the repo (public or internal mirror) automatically.
2. Or, clone manually INTO the folder VS Code currently has open
   (do NOT cd into a subfolder — the installer expects the repo
   contents to live directly in the current working directory):
     # From the folder VS Code has open:
     git init
     git remote add origin <repo-url-the-user-provides>
     git fetch origin --depth=1
     git checkout -f -B main origin/main   # or whatever the default branch is
   then re-run the installer.
```

**Missing directories:**
```text
❌ Repository Structure Error

Error: Required directory missing
  Missing: ps-base

Suggested Fix:
1. Verify repository is complete (the clone may have been interrupted)
2. Delete the partial clone and re-invoke the data360-healthcare-installer
   agent — Step 0 will re-clone cleanly.
```

---

### Authentication Errors

**Org not authenticated:**
```text
❌ Authentication Error

Error: Org '<org_alias>' not found in authenticated orgs

Suggested Fix:
1. Authenticate with org:
   sf org login web --alias <org_alias>
2. Verify org alias is correct
3. Retry deployment
```

**Authentication expired:**
```text
❌ Authentication Expired

Error: Org session expired for '<org_alias>'

Suggested Fix:
1. Re-authenticate:
   sf org login web --alias <org_alias>
2. Retry deployment
```

---

### Deployment Errors

**Metadata deployment failed:**
```text
❌ Metadata Deployment Failed

Org: <org_alias>
Deployment ID: <deployment_id>

Failed Components (first 5):
1. <component_type>.<component_name>: <error_message>
2. <component_type>.<component_name>: <error_message>
3. ...

Suggested Fix:
1. Check deployment status in Setup → Deployment Status
2. Review full error details with deployment ID
3. Fix component errors and retry
```

**Deployment timeout:**
```text
❌ Deployment Timeout

Error: Deployment exceeded 15-minute timeout

Deployment ID: <deployment_id>

Suggested Fix:
1. Check deployment status in Salesforce UI
2. Increase timeout if needed
3. Check org limits (API usage, storage)
4. Retry with: sf project deploy start -d ps-base --target-org <org_alias> --wait 30
```

---

### Permission Set Errors

**Permission set not found:**
```text
❌ Permission Set Assignment Failed

Error: Permission set 'PulseSyncBasePS' not found

Possible Causes:
- Metadata deployment incomplete
- Permission set not in ps-base metadata
- Different permission set name

Suggested Fix:
1. Verify metadata deployment completed successfully
2. Check if PulseSyncBasePS exists in org:
   sf data query -q "SELECT Id, Name FROM PermissionSet WHERE Name = 'PulseSyncBasePS'" --target-org <org_alias>
3. Retry metadata deployment if needed
```

**Assignment permission denied:**
```text
❌ Permission Set Assignment Failed

Error: Insufficient permissions to assign permission sets

Suggested Fix:
1. Verify user has 'Manage Profiles and Permission Sets' permission
2. Assign System Administrator profile
3. Retry assignment
```

---

### Price Book Errors

**Price Book activation failed:**
```text
❌ Price Book Activation Failed

Error: Apex execution failed in activatePricebook.apex

Apex Error: [error message]

Suggested Fix:
1. Check if Standard Price Book exists:
   sf data query -q "SELECT Id, Name, IsStandard FROM Pricebook2 WHERE IsStandard = true" --target-org <org_alias>
2. Review Apex script for errors
3. Retry the apex script automatically
```

**Price Book query returned no results:**
```text
❌ Standard Price Book Not Found

Error: Query returned 0 records for active Standard Price Book

Possible Causes:
- activatePricebook.apex failed silently
- Standard Price Book deleted
- Org configuration issue

Suggested Fix:
1. Check Standard Price Book status:
   sf data query -q "SELECT Id, Name, IsStandard, IsActive FROM Pricebook2 WHERE IsStandard = true" --target-org <org_alias>
2. Auto-retry Step 5 (activatePricebook.apex)
```

---

### Data Import Errors

**Data load (Step 6) failed via MCP:**

Step 6 has three distinct failure surfaces, each with its own diagnostic path. **Identify which surface hit before deciding a fix** — the underlying MCP tool differs and the retry semantics differ.

**Surface A — Headless 360 composite batch error (whole-chunk failure of `mcp__salesforce-headless-360__dispatch → POST /services/data/v67.0/composite/sobjects`):**

```text
❌ Sample Data Load Failed (Step 6.1c, Headless 360 composite batch)

The composite POST for planEntry <sObject> failed at the HTTP layer.
Symptoms: dispatch returned null, non-200/201 status, malformed body,
or a body whose length did not match the chunk size.

What already happened automatically (per Step 6.1c pseudocode):
  1. Step 6.1c ran the per-row reconcile ladder (3s / 7s / 20s / 15s / 30s / 15s
     = 90s bounded window) against every row in the chunk.
  2. Rows the composite DID commit were adopted into `refs`; duplicates
     collapsed to oldest by CreatedDate.
  3. Rows still absent after the 90s bounded window were retried EXACTLY ONCE
     via mcp__salesforce-sobject-all__createSobjectRecord (which itself carries
     the full 4-read 45s reconciliation ladder from Step 6.0a).
  4. Each retry was followed by a post-retry reconciliation query on the same
     natural key before the row was accepted into `refs` — the retry's own
     returned Id is never trusted blindly.
  5. The whole batch was NEVER blindly replayed. Only rows the reconcile ladder
     could not locate in the org were eligible to enter the retry path.

If this error is still surfacing, the fallback path also failed. Common causes:
  - MCP session token expired mid-run (INVALID_SESSION_ID). Re-run
    `/mcp-setup` and re-invoke the skill; Step 0.5 will resume.
  - Salesforce-side outage window (transient 5xx). Wait a few minutes
    and re-invoke; Step 0-DS.a's org reconciliation will decide whether
    to no-op or continue from Step 0.5.
  - Chunk body invalid before it left the client (unlikely — Step 6.2
    preflight transforms already ran; check the recorded chunk body
    for polymorphic reference formatting).
```

**Surface B — Per-row rejection inside a successful composite response (HTTP 200, one row's `success:false`):**

```text
❌ Sample Data Load Failed (Step 6.1c, per-row composite rejection)

The composite POST returned HTTP 200 for planEntry <sObject>, but the
per-record result array reported success:false for row <idx> (ref=<referenceId>).

Sibling rows in the same chunk kept their bulk-returned Ids — only this
row is affected. Step 6.1c automatically retried THIS row via
mcp__salesforce-sobject-all__createSobjectRecord to surface the same
Salesforce error the pre-bulk skill would have surfaced.

Common causes (raised verbatim by Salesforce):
  - CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY
    The sObject is not creatable in the target org (missing feature license).
    Step 6.1c fails FAST on this — no retry. Stop and surface the error.
  - REQUIRED_FIELD_MISSING: <FieldName>
    Salesforce needs a field the data file doesn't supply. Example:
      REQUIRED_FIELD_MISSING: PersonGenderIdentity is required for Person Account
  - INVALID_FIELD (or field not in `createable` list)
    The permission set from Step 3 (PulseSyncBasePS) is missing FLS on a
    custom Contact field. Re-run Step 3 or verify the permset was assigned.
  - DUPLICATE_VALUE
    Composite tried to insert a row whose natural key already exists in the
    org — indicates Step 6.1a's dedup guard missed the row (likely a
    malformed WHERE hitting the deferred hard-fail block).
  - Unknown @ref
    A record in a downstream data file references an @refId that wasn't
    produced upstream — either the plan.json order is wrong, or an upstream
    record failed to insert (surface the parent record's error first).
```

**Surface C — Single-record fallback (`mcp__salesforce-sobject-all__createSobjectRecord`) error:**

```text
❌ Sample Data Load Failed (Step 6.1c fallback / trivial-object path,
    single-record createSobjectRecord)

A single-record createSobjectRecord call returned an error. This path fires
in three cases:
  1. Trivial-object exception (queue size ≤ 1 for the planEntry).
  2. Per-row retry after a composite response reported success:false.
  3. Post-reconcile retry for a row still absent after Step 6.1c's 90s
     bounded ambiguous-outcome window.

The error is the Salesforce API's verbatim response. Common causes are
the same as Surface B (CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, REQUIRED_FIELD_MISSING,
INVALID_FIELD, DUPLICATE_VALUE, unknown @ref). The 4-read reconciliation
ladder (Step 6.0a) has already run for MCP timeouts, so a surfaced error
here means the record could not be created after reconciliation.

Suggested Fix (all three surfaces):
1. Read the per-record error message returned by the MCP tool — it is the
   Salesforce API's verbatim response.
2. Identify which surface hit (A / B / C above) — the retry policy for
   each differs, and re-running blind may re-hit the same failure.
3. Fix the root cause:
   - Validation rule blocking the insert? Disable / amend.
   - Required field missing? Update data/<file>.json to include it.
   - FLS / permset issue? Verify Step 3's assignment succeeded and Steps
     3.4/3.5 passed.
   - Feature license missing? Enable it via /feature-enablement and re-run.
4. Re-run the skill. Step 6 is idempotent when re-run: Step 6.1a's dedup
   guard MATCHES-and-UPDATES existing rows and INSERTS only missing ones;
   Step 6.4's SOQL count gate is the final safety net.
```

**Step 6 reported zero net inserts for a tier (informational):**
This is normal and expected when the org already has all the sample data from
a prior run. Step 6 skipped every already-existing record and inserted
nothing new. No action needed.

---

### Apex Execution Errors

**Apex compilation failed:**
```text
❌ Apex Execution Failed

Script: <script_name>.apex
Error: Compilation failed

Apex Error:
<compilation_error_message>

Suggested Fix:
1. Check if script file exists
2. Review script syntax
3. Check org API version compatibility
4. Fix errors and retry
```

**Apex runtime error:**
```text
❌ Apex Execution Failed

Script: <script_name>.apex
Error: Runtime exception

Apex Error:
<runtime_error_message>

Suggested Fix:
1. Check if required data exists (Orders, Price Books, etc.)
2. Review error message for root cause
3. Auto-retry the apex script after data validation
```

---

## Important Rules

### Absolute Requirements

- ✅ ALWAYS respect the channel rule in the Purpose section: Salesforce CLI for the metadata / deploy / file-oriented steps explicitly documented as CLI, Salesforce MCP servers for the steps explicitly documented as MCP, and only the approved MCP channels for Step 6 record mutations (per CHANNEL ENFORCEMENT).
- ✅ ALWAYS verify org authentication before starting
- ✅ ALWAYS stop execution on errors (do not proceed)
- ✅ ALWAYS report clear error messages with suggested fixes
- ✅ ALWAYS provide deployment IDs for troubleshooting
- ✅ ALWAYS ask for org_alias if not provided
- ✅ ALWAYS use Windows PowerShell / Git Bash compatible commands for file operations
- ✅ ALWAYS validate each step before proceeding to next

### Absolute Prohibitions

- ❌ NEVER use browser automation
- ❌ NEVER use Playwright tools
- ❌ NEVER generate JavaScript files
- ❌ NEVER skip error handling
- ❌ NEVER proceed after a failed step
- ❌ NEVER hardcode org names

---

## Step Execution Order

**CRITICAL: Steps must execute in this exact order:**

```
0. Check Current Directory (if already in repo, skip Step 1)
   ↓
0.5 Resume-state safeguard (ALWAYS runs)
    ↓ getUserInfo → cache <userId>
    ↓ Query each checkpoint (PSLs, permsets, PulseSyncBasePS, Pricebook, sample data, Data Cloud grants, FSL rule)
    ↓ Rebuild refs map from org if Step 6 was partially completed on a prior run
    ↓ Capture fresh <install_start_ts>
    ↓ Log a resume plan before any DML
    ↓
1. Verify/Clone Repository (SKIP if cwd fingerprint already matches the repo — folder name is irrelevant)
   ↓
1a-PSL. Assign Health Cloud Permission Set Licenses to the running user (MCP)
    ↓ Health Cloud (HealthCloudGA_HealthCloudPsl), Health Cloud Platform (HealthCloudPlatformPsl)
    ↓ Idempotent check-then-create per PSL — skips if Step 0.5 already flagged done
    ↓
1a. Assign Health Cloud permission sets to the running user (MCP)
    ↓ HealthCloudFoundation, HealthCloudUtilizationManagement, DiseaseSurveillance
    ↓ Idempotent check-then-create — skips if Step 0.5 already flagged done
    ↓
2. Deploy Metadata (ps-base) - Skip org authentication check
   ↓ VALIDATION: Parse JSON, verify status="Succeeded", componentErrors=0
   ↓ Skips ONLY if Step 0.5's two-part fingerprint passes: PulseSyncBasePS exists AND all 6 Contact custom fields visible in FieldDefinition. Permset-only match is NOT sufficient — an older ps-base could have left the permset behind without the current field schema.
   ↓
2.5 Sweep stuck/orphan deployments (MANDATORY GATE — always runs)
    ↓ Identify all non-terminal DeployRequests in the org other than $DEPLOY_ID
    ↓ Auto-cancel irrelevant deploys (xDO QBrix bootstrap, stray feature-enablement retries)
    ↓ STOP if any stuck deploy looks load-bearing (ps-* components, unknown patterns)
    ↓
3. Assign PulseSyncBasePS permission set to the running user (MCP) — MOVED EARLIER
   ↓ Reuses <userId>
   ↓
3.4 Verify PulseSyncBasePS grants FLS on 6 Contact fields (HARD GATE)
    ↓ SELECT FieldPermissions WHERE ParentId=<permSetId> AND SobjectType='Contact' AND Field IN (...)
    ↓ Expect 6 rows with Read+Edit true. Fail → re-deploy ps-base.
    ↓
3.5 Direct Contact SOQL runtime validation (PRIMARY GATE, replaces FieldDefinition wait)
    ↓ SELECT the 6 custom fields FROM Contact LIMIT 1 as the running user
    ↓ 3 attempts, 15s/45s backoff — no minutes-long stall on Storm/orgfarm cache lag
    ↓
3.6 FieldDefinition secondary diagnostic (informational, ≤2 attempts)
    ↓ Warning-only mismatch — Step 3.5 is the authoritative signal
    ↓
5. Activate Standard Pricebook (MCP)
   ↓ Cache <standardPricebookId> for Step 6's STANDARD_PRICEBOOK_ID substitution
   ↓
6. Load sample data from data/plan.json (MCP)
   ↓ 6.0   Capture <install_start_ts> anchor
   ↓ 6.0a  Reconcile-first MCP timeout handling — never blind-retry a create/update
   ↓ 6.0b  Expected manifest preflight — build {sObjectType: expected_count} from plan.json before any mutation
   ↓ 6.1   Iterate plan.json in order, resolve @refs and STANDARD_PRICEBOOK_ID
   ↓ 6.1a  Dedup guard (Match → UPDATE inline / Multi → collapse + UPDATE survivor / None → append to insertQueue)
   ↓ 6.1c  PRIMARY: composite/sobjects POST via salesforce-headless-360 (allOrNone=false, up to 200/call) once per planEntry; single-record createSobjectRecord ONLY for trivial (≤1-row) queues, per-row failures, or post-reconcile absent rows on ambiguous timeout
   ↓ 6.2   Preflight fixups applied BEFORE the row enters insertQueue: ServiceAppointment temporal fields (SchedStartTime / SchedEndTime / EarliestStartTime / DueDate) defensive validation, MedicationRequest.PatientId → Person Account Id, Phone→string, __pc fields
   ↓ 6.3   Per-sObject inserted/expected counts (from loader memory, compared against 6.0b manifest)
   ↓ 6.4   SOQL-verified 127/127 hard gate (Shape A/B/C rules unchanged; widened to include refs-populated Ids on resumed runs)
   ↓
6b. Enable Data Cloud copy-field permissions + link Assets to HealthCloud Contacts (MCP)
    ↓ Configures FieldPermissions on 5 Contact fields + ObjectPermissions on Contact/Account
    ↓ Runs the contactUpdationIntoAsset() equivalent — links Assets to their Account's HealthCloud Contact
    ↓
    (Step 6c — Clinical Care Coordinator User seed — has moved to agent-setup-configuration
     Step 6b, right after ps-post-pack deploys the required profile + role.)
    ↓
11. Deactivate ServiceAppointment.FSL__Schedule_End_Required (Tooling API PATCH)
    ↓ Filterable query by (EntityDefinition + DeveloperName + NamespacePrefix) — never SELECT FullName in multi-row
    ↓
12. Generate Summary Report (includes any fallback/deviation warnings from Steps 3.6, 6.0a reconciliations, and Step 6.4)
```

**Key Enhancements (in this version):**
- ✅ **Step 1a-PSL NEW:** Assigns the two Health Cloud Permission Set Licenses (`Health Cloud`, `Health Cloud Platform`) before Step 1a — required because several `HealthCloud*` PermissionSets will not assign without the underlying PSL held by the running user
- ✅ **Step 1a NEW:** Assigns three Health Cloud permission sets before the deploy runs (MCP)
- ✅ **Step 2 Validation:** Parse JSON deployment result, verify component count and errors
- ✅ **Step 2.5 (MANDATORY):** Sweep the org for stuck/orphan DeployRequests after `Succeeded`. Auto-cancel deploys whose components are clearly irrelevant to this installer (xDO QBrix bootstrap residue, stray feature-enablement retries). STOP and surface to user when a stuck deploy could be load-bearing (any ps-* component or unknown pattern). Prevents `datakit-api-deploy` from failing with `We couldn't retrieve available objects for <orgId>. Try again later.` due to platform locks held by orphan deploys.
- ✅ **Steps 0.5, 3, 3.4, 3.5, 5, 6, 6b use MCP:** These steps drive the `salesforce-sobject-all` MCP server (`soqlQuery` / `createSobjectRecord` / `updateSobjectRecord` / `getObjectSchema` / `getUserInfo`) end-to-end — resume-state checkpoints, PulseSyncBasePS assignment, FLS verification, direct Contact SOQL, Standard Pricebook activation, sample-data dedup/update/fallback insert, and copy-field FLS/CRUD grants. Step 3.6 uses `salesforce-headless-360` for FieldDefinition; Step 6.1c uses `salesforce-headless-360` `dispatch` → `POST /composite/sobjects` as the **primary** insert channel for multi-row planEntries (single-record `createSobjectRecord` remains the fallback for trivial queues, per-row failures, and post-reconcile absent rows on ambiguous timeout — with a post-retry reconciliation before acceptance); Step 11's `ValidationRule` filterable lookup runs through the Salesforce CLI (`sf data query --use-tooling-api`) as **primary** (MCP `dispatch_readonly` is documented fallback), while the single-row `Metadata` GET, the PATCH, and the verification GET run through `salesforce-headless-360` on `v66.0` Tooling routes. **No Apex scripts are executed in this skill** — legacy `scripts/apex/*.apex` files in the repo are not part of this workflow. (Clinical Care Coordinator user seed, formerly Step 6c, has moved to `agent-setup-configuration` Step 6b, right after ps-post-pack deploys the required profile + role.)
- ✅ All remaining `sf` CLI commands use `--json` flag for structured, parseable output
- ✅ Comprehensive error handling stops execution on critical failures

**Original Optimizations (retained):**
- ✅ Step 0 added: Check if already in repository
- ✅ Step 1: Skip entirely if already in repo directory
- ✅ Step 2: Skip org authentication verification (trust feature-enablement)

---

## Dependencies

### Required Tools

- Salesforce CLI (`sf` command)
- Git (for cloning repository)
- Windows PowerShell (for file replacement)
- Bash or Git Bash (for running commands)

### Required Permissions

User must have:
- System Administrator profile OR
- Customize Application permission
- Manage Profiles and Permission Sets permission
- Modify All Data permission
- Author Apex permission

### Required Org Features

- Standard Price Book must exist
- Orders must be enabled
- Products must be enabled
- Price Books must be enabled

---

## Success Criteria

Deployment is successful when ALL of the following are verified:

### Repository & Deploy (Steps 0–2.5)
✅ Current directory verified (already in repo) OR repository cloned/navigated to
✅ Metadata deployed successfully — JSON confirms status="Succeeded", componentErrors=0
✅ Stuck/orphan DeployRequests swept — either none present, or only irrelevant ones cancelled

### Health Cloud Permission Set Licenses (Step 1a-PSL — MCP)
✅ Two PermissionSetLicenseAssign rows exist for the running user covering:
  - HealthCloudGA_HealthCloudPsl (Health Cloud)
  - HealthCloudPlatformPsl (Health Cloud Platform)

### Health Cloud Permission Sets (Step 1a — MCP)
✅ Three PermissionSetAssignment rows exist for the running user covering:
  - HealthCloudFoundation
  - HealthCloudUtilizationManagement
  - DiseaseSurveillance
✅ `<userId>` cached from getUserInfo for downstream steps to reuse

### Resume-state Safeguard (Step 0.5 — MCP)
✅ `<userId>` re-cached via getUserInfo at the start of the run
✅ Checkpoint queries run for every downstream step (PSLs, permsets, PulseSyncBasePS, Pricebook, sample data, Data Cloud grants, FSL rule)
✅ `refs` map rebuilt from the org when Step 6 was partially completed on a prior invocation
✅ Fresh `<install_start_ts>` captured
✅ Resume plan logged to the operator before any DML

### Base Permission Set (Step 3 — MCP)
✅ PulseSyncBasePS assigned to the running user
✅ Assignment is idempotent — existing assignment skipped, missing one created via createSobjectRecord

### FLS + Runtime Validation (Steps 3.4 / 3.5 / 3.6 — HARD GATES)
✅ Step 3.4: 6 Contact FieldPermissions rows exist under PulseSyncBasePS with Read+Edit=true
✅ Step 3.5: direct Contact SOQL succeeded (no INVALID_FIELD) on the 6 custom columns — PRIMARY gate
✅ Step 3.6: FieldDefinition returned 6 (or logged a warning-only mismatch that Step 12 surfaces)

### Price Book Configuration (Step 5 — MCP)
✅ Standard Pricebook queried and IsActive is true (either verified already-active, or flipped via updateSobjectRecord)
✅ `<standardPricebookId>` cached for Step 6's STANDARD_PRICEBOOK_ID placeholder substitution

### Data Load (Step 6 — MCP)
✅ Every sObject in `data/plan.json` iterated in plan order
✅ Step 6.0a reconcile-first timeout handling applied — no blind retries on MCP timeouts; natural-key SOQL confirms whether each create/update landed before retrying
✅ Step 6.0b expected manifest computed from `data/plan.json` + `data/*.json` BEFORE any mutation, cached for Step 6.4 comparison
✅ Step 6.1c composite/sobjects POST is the PRIMARY insert channel (via `salesforce-headless-360` `dispatch` → `POST /services/data/v67.0/composite/sobjects`, `allOrNone=false`, up to 200 records per call); `salesforce-sobject-all` `createSobjectRecord` is used only for (a) trivial ≤1-row queues, (b) per-row `success:false` rejections from the composite response, and (c) rows still absent after Step 6.1c's 90s bounded per-row reconciliation window on an ambiguous whole-chunk outcome — with a post-retry reconciliation on the same natural key before that row is accepted
✅ Step 6.2 preflight fixups applied BEFORE the row enters `insertQueue` (ServiceAppointment temporal fields — SchedStartTime / SchedEndTime / EarliestStartTime / DueDate — defensive validation, MedicationRequest.PatientId → Person Account Id, phone coercion, __pc fields)
✅ `@ref` values resolved from the in-memory refs map — no unknown references; parent composite results feed child planEntries in order
✅ `STANDARD_PRICEBOOK_ID` placeholder substituted with the cached ID for every PricebookEntry
✅ Person Account records received `<personAccountRecordTypeId>` and had `Type` removed
✅ Non-createable fields stripped per `getObjectSchema` cache before insert
✅ **Step 6.1a dedup guard ran before every insert** — matching rows go through inline `updateSobjectRecord` (single-match) or dedup-collapse + update (multi-match); only zero-match rows enter `insertQueue` for the composite batch. Guard is disabled when `SKIP_DEDUP=1` is set.
✅ Ambiguous-outcome protection — when the composite POST times out, returns HTTP 5xx, or returns a malformed body, per-row SOQL reconcile over a 90s bounded window (3s / 7s / 20s / 15s / 30s / 15s) determines which rows committed; only genuinely absent rows retry via the single-record fallback path, and each retry is followed by a post-retry reconciliation on the same natural key before the row is accepted into `refs`. HTTP 5xx / timeout / malformed body is treated as AMBIGUOUS, not FAILED. The whole batch is never blindly replayed.
✅ Per-sObject `inserted / expected` counts reported in Step 6.3's verification block (compared against the Step 6.0b manifest)
✅ Post-load Step 6.4 re-queries every sObject in the manifest (Shape A / B / C) — no required object type may exit Step 6 without SOQL confirmation that `expected = existing + newly-created = verified_in_org`

### Copy-Field Permissions and Asset→Contact linking (Step 6b — MCP)
✅ Five Contact FieldPermissions rows present with PermissionsRead=true, PermissionsEdit=true
✅ Contact + Account ObjectPermissions rows present with all six flags set to true
✅ Every **deterministically linkable** Asset (parent Account with exactly 1 HealthCloud Contact) has its ContactId pointing at that Contact. Zero-match and ambiguous Assets are tracked in `run.assets_missing_healthcloud_contact` / `run.assets_ambiguous_healthcloud_contact` and surfaced in Step 12 — the linker is deterministic-only.

### Clinical Care Coordinator User — MOVED
(Formerly Step 6c here. Now runs in `agent-setup-configuration` Step 6b, immediately after ps-post-pack deploys the required `Care Coordinator` Profile and `Care_Coordinator` UserRole. See that skill for verification criteria.)

### FSL Validation Rule Deactivation (Step 11 — CLI-primary lookup, MCP-supported Metadata GET/PATCH)
✅ `ServiceAppointment.FSL__Schedule_End_Required` located via filterable Tooling SOQL on (EntityDefinition + ValidationName + NamespacePrefix) at API v66.0 — NEVER via multi-row `SELECT FullName`; NEVER via `DeveloperName` (that field throws INVALID_FIELD on ValidationRule)
✅ Rule Active=false at both the top-level field AND Metadata.active — or Step 11 was a documented no-op (FSL package not installed)

### Final Reporting (Step 12)
✅ Final summary generated with:
  - ✅ Deployment ID and component count
  - ✅ Per-sObject data import counts
  - ✅ Permission set assignment results (Step 1a-PSL + Step 1a + Step 3 + Step 6b)
  - ✅ All validation checkpoints passed

**Note:** Org authentication validation is skipped to avoid redundancy and speed up deployment.

---

## Integration with Other Skills

This skill is part of the complete Data360 Healthcare MedTech Solution Kit deployment workflow:

```
Deployment Sequence:

1. /feature-enablement <org_alias>
   └─ Enable Data Cloud, Einstein, Agentforce, Person Accounts

2. /base-metadata-deploy <org_alias>          ← THIS SKILL
   └─ Deploy base app metadata and sample data

3. /datakit-api-deploy <org_alias>
   └─ Deploy Data Kit metadata (612 components)

4. /datakit-api-deploy <org_alias>
   └─ Trigger Data Kit installation
```

**This skill should run AFTER feature enablement and BEFORE Data Kit deployment.**

---

## Example Usage

### Example 1: User provides org (after feature-enablement)

**User:** "Deploy base metadata to MyOrg"

**Skill:**
1. Step 0: checks current directory (already in repo, skips Step 1)
2. Step 0.5: resume-state safeguard — caches `<userId>`, runs checkpoint queries, rebuilds `refs` if needed, logs the resume plan
3. Step 1a-PSL: assigns Health Cloud Permission Set Licenses via MCP (Health Cloud, Health Cloud Platform) — skipped if Step 0.5 flagged done
4. Step 1a: assigns Health Cloud permission sets via MCP (HealthCloudFoundation, HealthCloudUtilizationManagement, DiseaseSurveillance) — skipped if Step 0.5 flagged done
5. Step 2: deploys ps-base metadata (async, 30-second polling, 10-min ceiling) — skipped ONLY if Step 0.5's two-part fingerprint passes (PulseSyncBasePS exists AND all 6 Contact custom fields are visible in FieldDefinition). If PulseSyncBasePS exists but any of the 6 fields is missing, Step 2 runs again — an older ps-base deployment left the permset in place without the current field schema.
6. Step 2.5: sweeps stuck deployments (auto-cancels irrelevant ones)
7. Step 3: assigns PulseSyncBasePS to the running user via MCP — MOVED EARLIER
8. Step 3.4: verifies 6 Contact FieldPermissions under PulseSyncBasePS have Read+Edit=true
9. Step 3.5: primary runtime gate — direct Contact SOQL succeeds (3 attempts, 15s/45s backoff)
10. Step 3.6: secondary FieldDefinition diagnostic (≤2 attempts, warning-only mismatch)
11. Step 5: activates the Standard Pricebook via MCP
12. Step 6: loads sample data from data/plan.json via MCP with reconcile-first timeout recovery
13. Step 6b: enables Data Cloud copy-field permissions + links Assets to HealthCloud Contacts via MCP
14. Step 11: deactivates the FSL Schedule_End_Required validation rule — primary `ValidationRule` filterable lookup via Salesforce CLI (`sf data query --use-tooling-api`), Metadata GET / PATCH / verification GET via `salesforce-headless-360` `dispatch` / `dispatch_readonly` on `v66.0` Tooling routes, with a final CLI re-query confirming `Active=false`
15. Step 12: reports summary (including any Step 3.6 warnings and Step 6.0a reconciliations)

---

### Example 2: User doesn't provide org

**User:** "Deploy base metadata"

**Skill:** "Which org would you like to deploy to? Please provide the org alias or username."

**User:** "HCOrg1"

**Skill:** [Proceeds with deployment workflow]

---

### Example 3: Repository doesn't exist

**User:** "Deploy base metadata to MyOrg"

**Skill:**
```text
📦 Verifying repository context...
❌ cwd is not the Data360 repo root.

This skill expects the data360-healthcare-installer agent to have run Step 0
(repo provisioning) first. Re-invoke the agent to clone or detect the repo,
then it will chain into this skill automatically.
```

---

## Notes

- This skill deploys BASE metadata only (ps-base folder)
- For Data Kit metadata, use `/datakit-api-deploy` skill separately
- Sample data import may take 2-5 minutes depending on data volume
- Apex scripts may take 10-30 seconds each
- Total deployment time: 5-10 minutes typically
- All operations are CLI-based with no UI automation

---

## Cleanup temp artifacts (MANDATORY before skill returns)

This skill creates the following scratch files/folders during a successful run. **All of them must be deleted before the skill returns** — see the agent's "Workspace Hygiene" rule for the global policy. Do this only on clean success; on failure, leave artifacts so the user can inspect.

**Files this skill creates (in repo root unless noted):**

```bash
# Step 2 — async deploy kickoff + polling
rm -f /tmp/ps_base_deploy_kickoff.json
rm -f /tmp/ps_base_deploy_status.json
```

Steps 1a-PSL, 1a, 4, 5, 6, 6b are MCP-based and do not create scratch files — reads and writes go through `mcp__salesforce-sobject-all__*` and (for Step 6.1c's composite POST and Step 11's `ValidationRule` `Metadata` GET / PATCH / verification GET) `mcp__salesforce-headless-360__*` tools directly. Step 11's primary `ValidationRule` filterable lookup uses the Salesforce CLI (`sf data query --use-tooling-api`) rather than an MCP call.

**Files this skill explicitly does NOT create anymore (legacy artifacts from prior implementations):**
- ❌ `verify_deployment.soql` — the SOQL verification step (old Step 3) has been removed
- ❌ `query_pricebook.soql` — Standard Pricebook is now resolved in-memory via MCP `soqlQuery`
- ❌ `data/pricebookentries.json.bak` — the MCP loader never modifies the data file
- ❌ `data/.resolved/` — no scratch directory
- ❌ `scripts/resolve_refs.py` — the broken pre-resolver is gone
- ❌ `tree_import_log.txt` / `tree_import_result.json` — `sf data tree import` is no longer used
- ❌ `_curl_body_*.json` — the Composite REST POSTs from the previous Python loader are gone; MCP tools handle transport internally

**Verification (must show no leftovers):**

```bash
ls /tmp/ps_base_deploy_kickoff.json /tmp/ps_base_deploy_status.json 2>&1 | grep -v "No such"
# All legacy artifacts must be absent too:
ls verify_deployment.soql query_pricebook.soql data/pricebookentries.json.bak \
   tree_import_log.txt tree_import_result.json _curl_body_*.json 2>&1 | grep -v "cannot access"
ls -d data/.resolved 2>&1 | grep -v "cannot access"
```

**What NOT to delete:**
- `data/plan.json`, `data/*.json` — repo-tracked sample-data files (Step 6 reads them in place; never modifies them)
- `scripts/apex/*.apex`, `scripts/python_wrapper.sh` — repo-tracked

**Cleanup-on-failure policy (do NOT clean up on these):**
- ❌ Deploy returned `Failed` / `Canceled`
- ❌ Polling loop hit the 45-min ceiling
- ❌ Step 1a-PSL couldn't find `HealthCloudGA_HealthCloudPsl` or `HealthCloudPlatformPsl` (Health Cloud licensing not provisioned)
- ❌ Step 1a couldn't find one of the Health Cloud permission sets
- ❌ Step 3 couldn't find `PulseSyncBasePS`
- ❌ Step 6 hit a `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` or unresolved `@ref`

In all those cases, leave the JSON dumps and logs in place so the user can read them.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded (ps-base deploy Succeeded, permsets assigned, Standard Pricebook activated, all sample-data inserts verified, temp files cleaned up), record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at Step 0-DS at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"base-metadata-deploy"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.base-metadata-deploy` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include:
     - `"completedTs": "<ISO-8601 timestamp>"`
     - `"psBaseDeployId": "<Deploy Id from Step 2>"`
     - `"permsetsAssigned": ["HealthCloudGA_HealthCloudPsl", "HealthCloudPlatformPsl", "PulseSyncBasePS", ...]` (whichever were assigned in Steps 1a-PSL / 1a / 3)
     - `"standardPricebookActivated": true` (from Step 4)
     - `"sampleDataInserted": { "Account": <n>, "Contact": <n>, "Product2": <n>, "PricebookEntry": <n>, ... }` (counts per object from Step 6)
     - `"dedupGuardTriggered": <true if Step 6.1a deleted any pre-existing records, else false>`
   - Append to `state.warnings` any non-blocking issues surfaced during this run (e.g. `"Step 6: 2 duplicate Accounts dedup-guarded before insert"`).
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome — deploy returned `Failed`/`Canceled`, polling hit the 45-min ceiling, a required permset wasn't found, a sample-data insert failed with `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` — do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; Step 0-DS at the top will correctly identify that the prior attempt did not finish, and Step 0.5's resume-state safeguard will reconcile against the org before proceeding (skipping deploys/insertions that already landed).

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
