---
name: assign-permission-to-app
description: Assign Pulse_Sync_App permission to current user via Permission Sets and Apex automation, then activate Patient_Account_Page as the org-default View page for the Account object via Metadata API. Uses SF CLI apex run + project retrieve/deploy - no browser automation.
---

# assign-permission-to-app

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"assign-permission-to-app"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: assign-permission-to-app already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Two responsibilities, run in sequence against the same org:

1. Assign Pulse_Sync_App permission to the currently logged-in user by executing a pre-built Apex script.
2. Activate the `Patient_Account_Page` Flexipage as the **org-default** View action override on the Account object by retrieving Account metadata, injecting the `<actionOverrides>` block, and deploying it back.

**Critical Constraints:**
- ❌ Do NOT use browser automation
- ❌ Do NOT use Playwright tools
- ❌ **Do NOT git clone**. The repo is already present in the current working directory (the folder VS Code has open). Run all commands from cwd. Cloning to a sibling folder would silently desync from the user's working tree and re-introduce stale placeholders.
- ✅ Use SF CLI apex run command
- ✅ Execute script: `scripts/apex/assignAppToCurrentUser.apex`
- ✅ Script calls: `AppProfileAssignmentHelper.assignAppToCurrentUser()`

**🚨 Windows + SF CLI exit-code quirk (verified June 2026):** On Windows hosts where `sf` is installed at `C:\Program Files\sf\bin\sf` (path with a space) and invoked through Git Bash, `sf` commands like `data query`, `project retrieve start`, and `project deploy start` may return shell exit code 1 EVEN WHEN THE COMMAND SUCCEEDED. The reliable signal is the JSON body, not the exit code:

- Top-level `"status": 0` → CLI succeeded
- `"result.status": "Succeeded"` AND `"success": true` → deploy/retrieve succeeded

Always parse the JSON. Never abort the skill on exit code 1 alone — re-read the JSON before declaring failure. This is a known shell wrapper issue, not a real failure.

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username

---

## Preconditions

Before running:
- Salesforce CLI authenticated with target org
- Repository: must be present in the **current working directory** (the folder VS Code has open). The folder name does not matter — only the fingerprint files (`sfdx-project.json`, `scripts/apex/...`, etc.) must exist in cwd.
- Script exists: `scripts/apex/assignAppToCurrentUser.apex`
- Apex class deployed: `AppProfileAssignmentHelper.cls`
- App exists: "Pulse_Sync_App"

---

## Workflow

### Step 1 — Verify script exists

Check if Apex script is present:

```bash
test -f "scripts/apex/assignAppToCurrentUser.apex" && echo "✅ Script found" || echo "❌ Script not found"
```

If not found:
- Report error: "Script not found: scripts/apex/assignAppToCurrentUser.apex"
- Check repository location
- Stop execution

---

### Step 2 — Execute Apex script

Run the script using SF CLI:

```bash
sf apex run -f scripts/apex/assignAppToCurrentUser.apex --target-org <org_alias>
```

**What the script does:**
1. Calls `AppProfileAssignmentHelper.assignAppToCurrentUser('Pulse_Sync_App')`
2. Creates Permission Set "Pulse_Sync_App_Access" (if not exists)
3. Grants app access to Permission Set via SetupEntityAccess
4. Assigns Permission Set to currently authenticated user
5. Returns success/error message

---

### Step 3 — Parse execution result

Check output for success indicators:

**Success Output:**
```
SUCCESS: Assigned app to current user
```

**Already Assigned Output:**
```
INFO: User already has permission set assigned
```

**Error Output:**
```
ERROR: App not found
ERROR: Permission Set creation failed
```

---

### Step 4 — Report result

On success:

```text
✅ Pulse_Sync_App Permission Assigned!

Org: <org_alias>
App: Pulse_Sync_App
Permission Set: Pulse_Sync_App_Access
Assigned To: Current authenticated user
```

On error:

```text
❌ App Permission Assignment Failed

Org: <org_alias>
Error: <error_message>

Possible Causes:
• App "Pulse_Sync_App" not found in org
• AppProfileAssignmentHelper class not deployed
• Insufficient permissions
• Org not authenticated

Suggested Fixes:
✅ Verify app exists: Setup → App Manager → Search "Pulse_Sync_App"
✅ Verify class deployed: Setup → Apex Classes → Search "AppProfileAssignmentHelper"
✅ Check permissions: User must have "Manage Profiles and Permission Sets"
✅ Re-authenticate: sf org login web -a <org_alias>
```

---

### Step 5 — Activate `Patient_Account_Page` as org-default View page on Account

**Purpose:** Override the standard Account `View` action so every user (regardless of profile or app) lands on the `Patient_Account_Page` Flexipage. This is done by adding an `<actionOverrides>` block (without `<formFactor>` separation per profile) to `Account.object-meta.xml` and deploying via Metadata API.

**Run this step ONLY after Step 4 reports success** (Pulse_Sync_App permission assigned). If Step 4 failed, abort — do not run Step 5.

**Precondition checks (hard gate — abort if any fails):**

```bash
# 1. Flexipage must exist in the org
sf data query --query "SELECT Id, MasterLabel FROM FlexiPage WHERE DeveloperName='Patient_Account_Page'" --target-org <org_alias>

# 2. Local Account metadata file must exist (will be overwritten with retrieved+modified version)
test -f "ps-base/main/default/objects/Account/Account.object-meta.xml" || echo "❌ Account.object-meta.xml missing"
```

If the FlexiPage query returns 0 rows, abort with:
```
❌ Step 5 aborted — Patient_Account_Page not found in org <org_alias>.
   The ps-post-pack package must be deployed before this skill runs.
```

#### 5a — Retrieve latest Account object metadata from the org

The local `Account.object-meta.xml` may be stale (or empty). Always retrieve the live version first so we don't overwrite fields/listViews/recordTypes/etc. that exist in the org but not locally.

```bash
# Retrieve into a temp staging folder so we don't clobber the working copy until merge succeeds
mkdir -p /c/tmp/account-retrieve
sf project retrieve start \
  --metadata "CustomObject:Account" \
  --target-org <org_alias> \
  --output-dir /c/tmp/account-retrieve \
  --json > /c/tmp/account-retrieve/retrieve.json
```

The retrieved file will be at one of:
- `/c/tmp/account-retrieve/main/default/objects/Account/Account.object-meta.xml`  (sf default layout)
- `/c/tmp/account-retrieve/objects/Account/Account.object-meta.xml`                (flat layout)

Locate it with:
```bash
RETRIEVED=$(find /c/tmp/account-retrieve -name "Account.object-meta.xml" | head -1)
test -n "$RETRIEVED" || { echo "❌ Retrieve failed"; exit 1; }
```

#### 5b — Inject the View action override

The block to inject is:

```xml
<actionOverrides>
    <actionName>View</actionName>
    <comment>Action override created by Lightning App Builder during activation.</comment>
    <content>Patient_Account_Page</content>
    <formFactor>Large</formFactor>
    <skipRecordTypeSelect>false</skipRecordTypeSelect>
    <type>Flexipage</type>
</actionOverrides>
```

**Idempotency rule:** if an `<actionOverrides>` element with `<actionName>View</actionName>` AND `<formFactor>Large</formFactor>` AND `<content>Patient_Account_Page</content>` already exists, skip the inject and log "ℹ️ View override already present".

**Replace rule (NOT abort):** if an `<actionOverrides>` element with `<actionName>View</actionName>` AND `<formFactor>Large</formFactor>` exists but with a **different** `<content>` (e.g. an SDO-installed default like `SDO_Account_Default`), **remove the existing block and insert the Patient_Account_Page block in its place**. The intent of this skill is to make `Patient_Account_Page` the View page; aborting on a pre-existing override defeats that purpose, since most orgs ship with one. Log:
```
ℹ️  Replacing existing View+Large override (was: <prior-flexipage>) with Patient_Account_Page
```

This rule applies ONLY to formFactor=Large. View+Small (mobile) and other action overrides (Edit, New, Tab, etc.) are left untouched.

**Why ElementTree, not regex (verified June 2026):** the live retrieved `Account.object-meta.xml` is ~230+ `<actionOverrides>` blocks for every action × formFactor combination. A non-greedy regex like `<actionOverrides>.*?</actionOverrides>` is correct in isolation but does NOT survive `re.sub(...)`-based replacement when ElementTree-style namespace prefixes appear (the file uses `xmlns="http://soap.sforce.com/2006/04/metadata"`). The previous regex implementation over-deleted siblings on a real org file. Use the namespace-aware `xml.etree.ElementTree` parser below — it identifies the exact node, removes one block, and appends one new block. Tested against the SDO_Account_Default conflict.

**Implementation (Python ElementTree, runs from cwd):**

```bash
python3 - <<'PY'
import xml.etree.ElementTree as ET
import pathlib, sys

NS = 'http://soap.sforce.com/2006/04/metadata'
ET.register_namespace('', NS)
ns = {'sf': NS}

# Locate retrieved file (handles both layouts: with/without main/default prefix)
candidates = list(pathlib.Path('/c/tmp/account-retrieve').rglob('Account.object-meta.xml')) \
           + list(pathlib.Path(r'C:\tmp\account-retrieve').rglob('Account.object-meta.xml'))
src = next(iter(candidates), None)
if src is None:
    print('❌ retrieved Account.object-meta.xml not found under /c/tmp/account-retrieve')
    sys.exit(1)

tree = ET.parse(src)
root = tree.getroot()

# Find existing View+Large overrides
to_remove = []
already_present = False
for ao in root.findall('sf:actionOverrides', ns):
    name_el = ao.find('sf:actionName', ns)
    ff_el   = ao.find('sf:formFactor', ns)
    ct_el   = ao.find('sf:content', ns)
    if name_el is None or ff_el is None:
        continue
    if name_el.text == 'View' and ff_el.text == 'Large':
        existing = ct_el.text if ct_el is not None else ''
        if existing == 'Patient_Account_Page':
            already_present = True
        else:
            print(f'ℹ️  Replacing existing View+Large override (was: {existing}) with Patient_Account_Page')
            to_remove.append(ao)

if already_present and not to_remove:
    print('ℹ️  View override already present — no change')
    # still write through so deploy is a no-op against unchanged source
else:
    for ao in to_remove:
        root.remove(ao)
    new_ao = ET.SubElement(root, f'{{{NS}}}actionOverrides')
    ET.SubElement(new_ao, f'{{{NS}}}actionName').text                = 'View'
    ET.SubElement(new_ao, f'{{{NS}}}comment').text                   = 'Action override created by Lightning App Builder during activation.'
    ET.SubElement(new_ao, f'{{{NS}}}content').text                   = 'Patient_Account_Page'
    ET.SubElement(new_ao, f'{{{NS}}}formFactor').text                = 'Large'
    ET.SubElement(new_ao, f'{{{NS}}}skipRecordTypeSelect').text      = 'false'
    ET.SubElement(new_ao, f'{{{NS}}}type').text                      = 'Flexipage'

ET.indent(tree, space='    ')
out = pathlib.Path('ps-base/main/default/objects/Account/Account.object-meta.xml')
out.parent.mkdir(parents=True, exist_ok=True)
tree.write(out, xml_declaration=True, encoding='UTF-8')
print(f'✅ Wrote {out}')
PY
```

This script always exits 0 on success (whether replace, insert, or no-op). Only filesystem / parse errors cause non-zero exit.

#### 5c — Deploy the modified Account object

```bash
sf project deploy start \
  --source-dir "ps-base/main/default/objects/Account/Account.object-meta.xml" \
  --target-org <org_alias> \
  --wait 10 \
  --json > /c/tmp/account-retrieve/deploy.json
```

Parse `result.status` from `deploy.json`. Expected: `Succeeded`.

#### 5d — Verify the override took effect

Re-retrieve the live Account metadata into a separate folder and inspect with Python (portable across Windows/macOS/Linux; not dependent on `bash ** glob` or `grep -A` flags):

```bash
sf project retrieve start --metadata "CustomObject:Account" --target-org <org_alias> --output-dir /c/tmp/account-verify --json > /c/tmp/account-verify-retrieve.log 2>&1
```

Note: the SF CLI on some Windows builds returns exit code 1 even when the retrieve succeeds — the JSON inside the log file is the source of truth. Grep `"status": "Succeeded"` from the log if you need to confirm.

Then verify with ElementTree (no shell glob, no grep):

```bash
python3 - <<'PY'
import xml.etree.ElementTree as ET, pathlib, sys

NS = 'http://soap.sforce.com/2006/04/metadata'
ns = {'sf': NS}

candidates = list(pathlib.Path('/c/tmp/account-verify').rglob('Account.object-meta.xml')) \
           + list(pathlib.Path(r'C:\tmp\account-verify').rglob('Account.object-meta.xml'))
src = next(iter(candidates), None)
if src is None:
    print('❌ verify retrieve produced no Account.object-meta.xml')
    sys.exit(1)

tree = ET.parse(src)
ok = False
for ao in tree.getroot().findall('sf:actionOverrides', ns):
    name_el = ao.find('sf:actionName', ns)
    ff_el   = ao.find('sf:formFactor', ns)
    ct_el   = ao.find('sf:content', ns)
    if (name_el is not None and name_el.text == 'View'
        and ff_el is not None and ff_el.text == 'Large'
        and ct_el is not None and ct_el.text == 'Patient_Account_Page'):
        ok = True
        break

if ok:
    print('✅ Verified: Account View+Large override → Patient_Account_Page')
    sys.exit(0)
print('❌ Verification failed — Patient_Account_Page not found in re-retrieved Account metadata')
sys.exit(1)
PY
```

**Hard gate:** if the verify Python script exits non-zero, the skill MUST report failure and skip cleanup. Do not declare success.

#### 5e — Report result

On success:
```text
✅ Account Record Page Activated

Org: <org_alias>
FlexiPage: Patient_Account_Page
Object: Account
Action: View (formFactor=Large)
Scope: Org default (all profiles, all record types — skipRecordTypeSelect=false)
Deploy ID: <deployId>
```

On error, surface the SF CLI deploy errors verbatim plus the FlexiPage existence check result so the user can diagnose without re-running.

---

## Important Rules

**CRITICAL - Execution:**
- ✅ **ALWAYS verify script exists** before running
- ✅ **ALWAYS parse output** for success/error indicators
- ✅ **NEVER use browser automation** for this task
- ✅ **Execute from repository root** (the current working directory — whatever folder VS Code has open). Do NOT cd into a folder named `Data360MedTechSolutionKit` or any other hardcoded name; the repo files are expected to live directly in cwd.

**General Rules:**
- NEVER hardcode org names — always use provided org_alias parameter
- Script is idempotent — safe to run multiple times
- Only assigns to current authenticated user (not all users)
- Permission Set approach (not Profile modification)
- Fast execution — typically completes in 1-2 seconds

---

## Files Used

| File | Purpose |
|------|---------|
| `scripts/apex/assignAppToCurrentUser.apex` | Entry point script (Steps 1-4) |
| `ps-post-pack/main/default/classes/AppProfileAssignmentHelper.cls` | Apex class with assignment logic |
| `ps-post-pack/main/default/classes/AppProfileAssignmentHelper.cls-meta.xml` | Metadata file |
| `ps-base/main/default/objects/Account/Account.object-meta.xml` | Account object metadata — overwritten in Step 5b with retrieved+modified version |
| `ps-post-pack/main/default/flexipages/Patient_Account_Page.flexipage-meta.xml` | The FlexiPage that becomes the org-default View page (Step 5) — must already exist in org |

**Verify files deployed:**

```bash
sf data query --query "SELECT Id, Name FROM ApexClass WHERE Name='AppProfileAssignmentHelper'" --target-org <org_alias>
sf data query --query "SELECT Id, MasterLabel FROM FlexiPage WHERE DeveloperName='Patient_Account_Page'" --target-org <org_alias>
```

---

## Success Criteria

Installation is successful when:

**Phase 1 — App Permission (Steps 1-4):**

✅ Script exists at correct path  
✅ Apex execution completes without errors  
✅ Output shows "SUCCESS: Assigned app to current user"  
✅ Permission Set "Pulse_Sync_App_Access" exists  
✅ Current user has Permission Set assigned  
✅ User can access "Pulse_Sync_App" in App Launcher  

**Phase 2 — Account Record Page Activation (Step 5):**

✅ FlexiPage `Patient_Account_Page` exists in org (precondition check passed)  
✅ Account object metadata retrieved successfully into `/c/tmp/account-retrieve/`  
✅ `<actionOverrides>` block injected (or already-present, idempotent path)  
✅ `Account.object-meta.xml` deployed with status `Succeeded`  
✅ Re-retrieved Account metadata contains `<content>Patient_Account_Page</content>` under the View action override  

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"assign-permission-to-app"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.assign-permission-to-app` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| Script not found | Wrong directory | Navigate to repo root |
| Class not found | Not deployed | Deploy ps-post-pack package first |
| App not found | Wrong app name | Verify app name in Setup |
| Permission denied | Insufficient permissions | Assign System Admin or equivalent |
| Org not authenticated | Token expired | Run: sf org login web -a <org_alias> |

---

## Example Execution

User command:
```
/assign-permission-to-app MyHealthcareOrg
```

Execution flow:
1. Verify script exists ✅
2. Run: `sf apex run -f scripts/apex/assignAppToCurrentUser.apex --target-org MyHealthcareOrg` ✅
3. Parse output: "SUCCESS: Assigned app to current user" ✅
4. Report success ✅

**Actual execution output:**
```
✅ Permission Set: Pulse_Sync_App_Access
✅ App: Pulse_Sync_App
✅ Assigned to: user@example.com
```

---

## Cleanup temp artifacts (MANDATORY before next skill)

Before declaring this skill complete, delete every temporary file/folder created during the run.

**Failure handling rule:**
- If apex execution (Phase 1) or the Account metadata retrieve/deploy/verify (Phase 2 / Step 5) fails, **do NOT clean up** — leave artifacts for debugging.
- Fix the underlying issue, retry, then run cleanup once both phases report success.
- **Hard rule for Step 5:** Never run this cleanup until Step 5d verification has confirmed the override is present in the re-retrieved metadata. Cleaning up before verification means we lose the staged retrieve files needed to diagnose deploy failures.

**Files this skill creates and must delete (run unconditionally — `-f` silently ignores missing files, so leftover artifacts from earlier failed runs are also cleaned up here):**

```bash
# Repo-root SOQL temp files (created in Step 5a precondition checks)
rm -f verify_app_perm.soql

# Apex output capture (created when stdout is redirected for parsing)
rm -f /c/tmp/assign_app.out
```

**Step 5 staging artifacts (ALWAYS delete after success):**

```bash
rm -rf /c/tmp/account-retrieve
rm -rf /c/tmp/account-verify
rm -f /c/tmp/account-verify-retrieve.log
```

**Repo state after Step 5:**

The deployed `ps-base/main/default/objects/Account/Account.object-meta.xml` now contains the retrieved live metadata plus the View override. This is intentional — it's the new source of truth for that file. **Do NOT revert** it; subsequent runs are idempotent and will detect the override is already present.

**Verification (must show no leftovers):**

```bash
ls verify_app_perm.soql /c/tmp/assign_app.out /c/tmp/account-verify-retrieve.log 2>&1 | grep -v "cannot access"
ls -d /c/tmp/account-retrieve /c/tmp/account-verify 2>&1 | grep -v "cannot access"
```

**Rules:**
- ✅ Only delete the files/folders listed above. Do NOT touch `scripts/apex/assignAppToCurrentUser.apex` — it's repo source.
- ✅ Do NOT delete `ps-base/main/default/objects/Account/Account.object-meta.xml` — it now contains the deployed override and must persist.
- ❌ Skipping this step is not allowed once both phases report success.
