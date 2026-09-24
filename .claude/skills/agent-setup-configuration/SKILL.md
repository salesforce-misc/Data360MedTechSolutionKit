---
name: agent-setup-configuration
description: "Automate complete Agent deployment workflow for Data360 MedTech Solution Kit using Salesforce CLI. Creates agent user via Apex, updates Agentforce_Service_Agent.bot-meta.xml AND PulseMedAssitant.agent (line 15 default_agent_user), deploys agents package (ps-post-pack), seeds the Clinical Care Coordinator user (Step 6b — required by the Cardiologist_Appointment flow's Get_User lookup; Profile + UserRole ship in ps-post-pack), assigns PulseSyncCustomPS to the agent user, activates Clinician_Copilot + Agentforce_Service_Agent, then publishes + activates the PulseMedAssitant authoring bundle (Step 9a) with the same agent user as its run-as identity. NO browser automation, CLI-only workflow. Use when user wants to setup agents, configure agents, deploy Clinician_Copilot, activate Agentforce agents, or publish PulseMedAssitant."
---

# agent-setup-configuration

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"agent-setup-configuration"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: agent-setup-configuration already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Automate complete Agent deployment workflow for Data360 MedTech Solution Kit using Salesforce CLI commands.

**✅ CLI-ONLY SOLUTION**

This skill automates the complete agent setup process without any browser automation. It uses Salesforce CLI commands exclusively to create agent users, update configuration files, deploy packages, and activate agents.

**Critical Constraints:**
- ❌ Do NOT generate JavaScript files
- ❌ Do NOT generate Playwright scripts
- ❌ Do NOT use browser automation
- ❌ **Do NOT skip agent activation (Steps 8 + 9) under any circumstance** — both agents MUST be activated. The skill is not "complete" until `sf agent activate` reports success for BOTH `Clinician_Copilot` AND `Agentforce_Service_Agent`.
- ❌ **Do NOT skip permission-set assignment (Step 7)** — `PulseSyncCustomPS` MUST be on the freshly-created agent user before agent activation. Without it, the bot run-as user has no object access and the agent breaks at first conversation. Verify the assignment after the assign call; if missing, re-run.
- ❌ **Do NOT skip Step 7.5 SetupEntityAccess binding (Employee Agent only)** — `Clinician_Copilot` is `<type>InternalCopilot</type>` and does NOT support `<botUser>`. Profile and permset access is controlled by the Setup UI's **"Profiles with Agent Access"** + **"Permission Sets with Agent Access"** tabs at `/lightning/setup/EinsteinCopilot/<Clinician_Copilot_botId>/edit`. Both tabs are views over the **`SetupEntityAccess`** SObject — writable via Apex DML. Step 7.5 inserts 2 rows (System Administrator profile-shadow permset + PulseSyncCustomPS, each bound to Clinician_Copilot only) and verifies the SOQL count. If a binding is missing, the Employee Agent appears active in Setup but **no user can launch it** because the launching user's profile/permset is not in the access list.
- ❌ **Do NOT bind Agentforce_Service_Agent via SetupEntityAccess in Step 7.5.** The Service Agent is `<type>ExternalCopilot</type>`. It runs as the user named in `<botUser>` (set in Step 4), and SetupEntityAccess rows on it have no runtime effect for Embedded Messaging conversations. The Service Agent's PulseSyncCustomPS assignment lives on the bot user (Step 7), NOT on the bot definition.
- ❌ **Do NOT treat "BotDefinition exists in SOQL" as proof of activation.** A `BotDefinition` row created by the metadata deploy can sit `Inactive` indefinitely; only `sf agent activate` flips it.
- ✅ Use Salesforce CLI commands ONLY
- ✅ **Execute ALL commands sequentially** - wait for each to complete before proceeding
- ✅ **STOP immediately if Step 1 fails** - user creation and XML update are critical
- 📸 **Screenshot Policy**: N/A - This is a CLI-only skill with no browser automation

**Complete Workflow (substitute → deploy → rollback):**
1. Create Agent User via Apex script
2. Parse email from output
3. Update Service Agent bot-meta.xml with agent user email — substitute `AGENT_USER_EMAIL` placeholder (Employee Agent does NOT need this)
<<<<<<< Updated upstream
   AND update `PulseMedAssitant.agent` `default_agent_user:` at line 15 with the same email (see Step 4.2)
=======
   AND update `PulseMedAssitant.agent` `default_agent_user:` at line 15 with the same email
>>>>>>> Stashed changes
4. Deploy Agents package (ps-post-pack)
5. Assign Permission Set to default user (also assign PulseSyncCustomPS to the agent user — Step 7)
6. Activate Employee Agent (Clinician_Copilot)
7. Activate Service Agent (Agentforce_Service_Agent)
<<<<<<< Updated upstream
8. Publish + activate PulseMedAssitant authoring bundle (Step 9a — creates BotDefinition + Active BotVersion)
9. **🚨 ROLLBACK bot-meta.xml + PulseMedAssitant.agent to placeholders** (ONLY on deploy success) — keeps repo org-agnostic and idempotent
=======
8. Publish + activate PulseMedAssitant authoring bundle (Step 9a)
9. **🚨 ROLLBACK bot-meta.xml to `AGENT_USER_EMAIL` placeholder** (ONLY on deploy success) — keeps repo org-agnostic and idempotent
>>>>>>> Stashed changes

**🚨 PLACEHOLDER PATTERN (org-agnostic repo):**

`Agentforce_Service_Agent.bot-meta.xml` ships with `<botUser>AGENT_USER_EMAIL</botUser>` — a literal placeholder string, NOT a real email. Each run:
- Substitutes `AGENT_USER_EMAIL` → real agent user email (e.g. `eagent1780504659747@test.com`)
- Deploys to org
- ON SUCCESS: rolls back the file to restore `AGENT_USER_EMAIL` placeholder
- ON FAILURE: leaves the file dirty so the user can debug what was about to deploy

This means:
- The repo never has org-specific emails committed
- Re-running the skill always finds `AGENT_USER_EMAIL` — Edit tool's `old_string` always matches
- Different orgs (sandbox, prod) all start from the same placeholder baseline

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username
- `repo_path` (optional): Path to the cloned Data360 repo root. Defaults to "." (current working directory — assumes Claude Code is launched from the repo root)

---

## Preconditions

Before running:

- Salesforce CLI authenticated with target org
- User has System Administrator profile or equivalent permissions
- The Data360 repository is already cloned locally and Claude Code is launched from its root (no git clone needed)
- Apex script exists at `scripts/apex/createAgentUser.apex`
- Service Agent bot meta file exists at `ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml`
- (Optional) PulseMedAssitant authoring bundle exists at `ps-post-pack/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent` — if present, Step 4.2 patches its `default_agent_user:` line and Step 9a publishes + activates it. If absent, both steps skip cleanly with a warning.
- **Note on which files need the agent-user email substitution:**
  - `Agentforce_Service_Agent.bot-meta.xml` → `<botUser>` tag (Step 4.1)
  - `PulseMedAssitant.agent` → line 15 `default_agent_user:` YAML value (Step 4.2)
  - `Clinician_Copilot` → does NOT require any botUser configuration; access is controlled by `SetupEntityAccess` rows in Step 7.5.

---

## Workflow

**CRITICAL EXECUTION RULES:**

1. ✅ **ALWAYS execute commands sequentially** - wait for each to complete
2. ✅ **STOP if Step 1-6 fails** - user creation and XML update are critical
3. ✅ **Parse Apex output** to extract agent user email
4. ✅ **Use Edit tool** to update XML (never Write tool on existing files)
5. ✅ **Verify XML update** before proceeding to deployment
6. ✅ **Wait for deployment** to complete before next step

**Step Execution Order:**
```
Step 0: Verify repository and files exist
   ↓
Step 0.4: MCP preflight — ensure salesforce-sobject-all MCP tools are callable in this session.
          If not, re-authenticate via scripts/authenticate-mcp-server.sh (with auto VS Code
          reload — SKIP_VSCODE_RELOAD is NOT set), then stop and instruct the user to send
          "continue" after the reload completes. Step 6b + 7 + 7.5 all require MCP.
   ↓
Step 0.5: Detect stale repo state (warn loudly if rollback failed in prior run)
   ↓
Step 1: Execute Apex script to create Agent User
   ↓
Step 2: Parse Agent User email from output (use `Created user:` marker, NOT first email)
   ↓
Step 3: Read Service Agent bot-meta.xml file (NOT Employee Agent)
   ↓
Step 4: Update Service Agent botUser tag with new email
<<<<<<< Updated upstream
        Step 4.2 (inline): Update PulseMedAssitant.agent default_agent_user
          (line 15) with the same agent user email — required so PulseMedAssitant
          is authoring-bundle-published as an ExternalCopilot with a valid run-as
          user in this org.
=======
        AND update PulseMedAssitant.agent default_agent_user (line 15) with the same email
>>>>>>> Stashed changes
   ↓
Step 5: Verify the Service Agent update (AND PulseMedAssitant update)
   ↓
Step 6: Deploy Agents Package (ps-post-pack)
   ↓
Step 7: Assign Permission Set (PulseSyncCustomPS) to agent user
   ↓
Step 7.5: Bind System Administrator profile + PulseSyncCustomPS to
          Clinician_Copilot ONLY via Apex DML on SetupEntityAccess.
          Inserts 2 rows. Idempotent — skips already-existing rows.
          Verifies SOQL count = 2 before continuing. Hard-stops on mismatch.
          Agentforce_Service_Agent is excluded — its access is via <botUser>
          (Step 4), not via SetupEntityAccess.
   ↓
Step 8: Activate Employee Agent (Clinician_Copilot)
   ↓
Step 9: Activate Service Agent (Agentforce_Service_Agent)
   ↓
<<<<<<< Updated upstream
Step 9a: Publish + activate PulseMedAssitant authoring bundle.
         Uses `sf agent publish authoring-bundle --api-name PulseMedAssitant`
         (requires @salesforce/plugin-agent ≥ 2.0.5 — Step 9a auto-installs it
         if the subcommand is unavailable) then `sf agent activate --api-name
         PulseMedAssitant`. Also assigns PulseSyncCustomPS to the agent user
         used by PulseMedAssitant (idempotent) — because the bundle is
         published with its own runtime user via default_agent_user, the same
         PS-assignment logic from Step 7 must apply to that user too.
   ↓
Step 9.5: 🚨 ROLLBACK bot-meta.xml + PulseMedAssitant.agent to placeholders
          (ONLY if Step 6 + Step 9a deploys succeeded — leave dirty on failure)
=======
Step 9a: Publish + activate PulseMedAssitant authoring bundle
         sf agent publish authoring-bundle --api-name PulseMedAssitant
         sf agent activate --api-name PulseMedAssitant
   ↓
Step 9.5: 🚨 ROLLBACK bot-meta.xml to AGENT_USER_EMAIL placeholder
          (ONLY if Step 6 deploy succeeded — leave dirty on failure)
>>>>>>> Stashed changes
   ↓
Step 10: Generate final completion report
```

---

### Step 0 — Verify repository and files exist

**CRITICAL: Check all required files before starting**

Check if repository exists:

```bash
ls "{repo_path}"
```

Verify Apex script exists:

```bash
ls "{repo_path}/scripts/apex/createAgentUser.apex"
```

Verify bot meta XML file exists:

```bash
ls "{repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml"
```

**If any file is missing:**
- Report error: "Required file not found: [file_path]"
- List available files in the directory
- Stop execution

**If all files exist:**
- Report: "✅ All required files verified"
- Continue to Step 0.4 (MCP preflight)

---

### Step 0.4 — MCP preflight (auto-authenticate + auto-reload if disconnected)

**Why:** Steps 6b (Clinical Care Coordinator user create), 7 (permission-set assign to agent user), and 7.5 (SetupEntityAccess bindings) all require the `salesforce-sobject-all` MCP. If the MCP is not registered, its OAuth token has expired, or its server process has been killed since the last `/mcp-setup`, those steps will fail with "tool not found" or 401. This preflight catches that state before the skill mutates anything.

**Detection (in-session, no shell):**

Attempt `ToolSearch(query: "select:mcp__salesforce-sobject-all__soqlQuery,mcp__salesforce-sobject-all__createSobjectRecord")` with `max_results: 2`.

- **If the search returns both tools' schemas** → MCP is live in this session. Continue to Step 0.5.
- **If the search returns `No matching deferred tools found`** → MCP is disconnected. Fall through to the auto-recovery block below.

**Auto-recovery block (only runs when detection fails):**

1. Verify the auth script and credential material exist:
   ```bash
   test -f scripts/authenticate-mcp-server.sh || { echo "❌ Auth script missing — cannot auto-recover. Re-run /mcp-setup manually."; exit 1; }
   test -f .claude/settings.local.json || { echo "❌ .claude/settings.local.json missing — re-run /mcp-setup manually."; exit 1; }
   ```

2. Extract the Consumer Key + Secret from `.claude/settings.local.json` (both `data360` and `salesforce-sobject-all` MCPs share the same Consumer Key + Secret per the /mcp-setup skill):
   ```bash
   KEY=$(python3 -c "import json; d = json.load(open('.claude/settings.local.json')); print(d['mcpServers']['salesforce-sobject-all']['oauth']['clientId'])")
   SECRET=$(python3 -c "import json; d = json.load(open('.claude/settings.local.json')); print(d['mcpServers']['salesforce-sobject-all']['oauth']['clientSecret'])")
   ```

3. Run the auth script with **auto-reload enabled** (do NOT set `SKIP_VSCODE_RELOAD=1`):
   ```bash
   bash scripts/authenticate-mcp-server.sh "{org_alias}" "$KEY" "$SECRET"
   ```
   The script writes fresh OAuth tokens to `~/.claude/.credentials.json`, then fires `vscode://workbench.action.reloadWindow` which reloads VS Code and re-connects the MCP.

4. **Stop the skill here.** The VS Code reload terminates the current Claude Code session's in-memory state. The user must send `continue` (or re-invoke the skill) after the reload finishes so Claude Code can pick up the fresh MCP tokens on the next prompt cycle.

**User-facing message:**
```
⚠️ salesforce-sobject-all MCP was disconnected — running auth recovery.

✅ OAuth tokens refreshed.
🔄 VS Code will reload automatically in ~2 seconds.

After reload completes, send "continue" and I'll resume at Step 1.
```

**When to skip this step:** if `ToolSearch` already returned MCP schemas for `mcp__salesforce-sobject-all__soqlQuery` and `mcp__salesforce-sobject-all__createSobjectRecord`, MCP is healthy — skip the recovery block and continue to Step 0.5.

---

### Step 0.5 — Detect stale repo state (warn loudly if rollback failed in a prior run)

**Why:** the repo's `Agentforce_Service_Agent.bot-meta.xml` is supposed to ship with the literal placeholder `<botUser>AGENT_USER_EMAIL</botUser>`. After Step 9.5, every successful run restores that placeholder. If a prior run's deploy succeeded but Step 9.5 was skipped (script aborted, rollback errored, manual interrupt, etc.), the file will still contain a real-looking org-specific email when this skill starts. The skill's Step 4 fallback handles it correctly — but the warning is buried, and silent accumulation of stale state across runs is a real risk.

**Loud check at the top of Step 0.5:**

```bash
if grep -q "<botUser>AGENT_USER_EMAIL</botUser>" "{repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml"; then
  echo "✅ Repo in canonical placeholder state — proceeding normally."
else
  CURRENT=$(grep -oE '<botUser>[^<]*</botUser>' "{repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml")
  echo ""
  echo "⚠️ ============================================================"
  echo "⚠️  REPO NOT IN CANONICAL PLACEHOLDER STATE — RECOVERY MODE"
  echo "⚠️ ============================================================"
  echo "⚠️  Agentforce_Service_Agent.bot-meta.xml currently contains:"
  echo "⚠️    $CURRENT"
  echo "⚠️"
  echo "⚠️  Expected: <botUser>AGENT_USER_EMAIL</botUser>"
  echo "⚠️"
  echo "⚠️  This means a prior run's Step 9.5 rollback did NOT execute."
  echo "⚠️  Possible causes:"
  echo "⚠️    - Prior run's deploy succeeded but rollback was skipped/aborted"
  echo "⚠️    - The repo was manually edited"
  echo "⚠️    - A prior run's deploy FAILED and the file was intentionally left dirty for debugging"
  echo "⚠️"
  echo "⚠️  Step 4 will substitute the current value with the new email"
  echo "⚠️  (fallback path) and proceed. Step 9.5 WILL fire on success and"
  echo "⚠️  restore the placeholder."
  echo "⚠️ ============================================================"
fi
```

**Do NOT abort on stale state** — the fallback in Step 4 handles it correctly. The warning's purpose is to make the recovery visible so the user can confirm the file isn't accumulating drift across runs.

**Continue to Step 1 regardless of canonical/stale outcome.**

---

### Step 1 — Execute Apex script to create Agent User

**CRITICAL: This step MUST succeed or entire workflow fails**

Run the Apex script to create agent user:

```bash
sf apex run -f "{repo_path}/scripts/apex/createAgentUser.apex" -o {org_alias}
```

**Expected output format examples:**
```
USER_DEBUG|User created: eagent1234567890@test.com
```

Or:
```
User Email: eagent1234567890@test.com
```

Or:
```
Created agent user: eagent1234567890@test.com
```

**If command fails:**
- Report full error message from SF CLI
- Check org authentication: `sf org display -o {org_alias}`
- Suggest: `sf org login web -a {org_alias}`
- Stop execution

**If command succeeds:**
- Capture full output for parsing
- Continue to Step 2

---

### Step 2 — Parse Agent User email from output

**🚨 CRITICAL: Extract email address from the Apex `Created user:` DEBUG marker — NOT "first email pattern in output".**

The Apex script's actual output contains MULTIPLE emails, most of which are NOT the agent user:

```
Execute Anonymous:  * @author            : ChangeMeIn@UserSettingsUnder.SFDoc        ← apex docstring boilerplate (WRONG)
Execute Anonymous:  * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc        ← apex docstring boilerplate (WRONG)
10:00:44.233|USER_INFO|[EXTERNAL]|005Hn00000JCBgL|storm.556c4752411403@salesforce.com ← executing user, NOT the new agent (WRONG)
10:00:52.810 (8824069353)|USER_DEBUG|[93]|DEBUG|Created user: eagent1781100044645@test.com  ← THE REAL ONE
```

A naive "first email" extraction returns `ChangeMeIn@UserSettingsUnder.SFDoc` — a placeholder docstring address. The bot-meta.xml deploy will succeed (XML validation doesn't validate emails), but the agent will break at runtime because `botUser` resolves to a non-existent user.

**Correct extraction — match on the `Created user:` marker:**

```bash
AGENT_USER_EMAIL=$(grep -oE 'Created user: [a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$APEX_OUTPUT_FILE" \
  | head -1 \
  | awk '{print $NF}')
echo "Extracted agent_user_email=$AGENT_USER_EMAIL"
```

The `awk '{print $NF}'` strips the `Created user: ` prefix and leaves just the email. The `head -1` defends against multiple matches if the Apex script ever logs the line twice.

**Apex script contract (createAgentUser.apex MUST emit this marker):**

The Apex script writes:
```apex
System.debug('Created user: ' + newUser.Email);
```

which Salesforce's debug log renders as:
```
HH:MM:SS.SSS (...)|USER_DEBUG|[N]|DEBUG|Created user: <email>
```

If the Apex script ever changes the marker text, this regex must change with it. The marker is the contract.

**Fallback markers (less reliable — only if `Created user:` produces no match):**

```bash
# Fallback 1: bare "User Email: <email>" (some older versions of the script use this)
[ -z "$AGENT_USER_EMAIL" ] && AGENT_USER_EMAIL=$(grep -oE 'User Email: [a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$APEX_OUTPUT_FILE" | head -1 | awk '{print $NF}')

# Fallback 2: "Created agent user:"
[ -z "$AGENT_USER_EMAIL" ] && AGENT_USER_EMAIL=$(grep -oE 'Created agent user: [a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$APEX_OUTPUT_FILE" | head -1 | awk '{print $NF}')
```

**🛑 NEVER use a bare email regex against the full apex output.** It will match `ChangeMeIn@UserSettingsUnder.SFDoc` (docstring) or the executing user's email — both wrong.

**If no email found from any marker:**
- Report error: "❌ Could not extract user email from Apex output via `Created user:` marker"
- Show the full Apex output for debugging
- Verify `scripts/apex/createAgentUser.apex` emits a `System.debug('Created user: ' + newUser.Email);` line
- Stop execution (do NOT proceed with a guessed email)

**If email found:**
- Validate it isn't a known false-positive: reject if it matches `ChangeMeIn@UserSettingsUnder.SFDoc` or contains `salesforce.com` (the executing admin's email — agent users always use synthetic `@example.com` or `@orgfarm.salesforce.com` style addresses)
- Store email in variable: `AGENT_USER_EMAIL`
- Report: "✅ Agent User created: {AGENT_USER_EMAIL}"
- Continue to Step 3

---

### Step 3 — Read Service Agent bot-meta.xml file

**Read the Service Agent XML configuration:**

**IMPORTANT:** Only Agentforce_Service_Agent requires botUser configuration. Clinician_Copilot does NOT need botUser update.

```
Tool: Read
file_path: {repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml
```

Check if `<botUser>` tag exists in the XML.

**Expected XML structure:**
```xml
<Bot xmlns="http://soap.sforce.com/2006/04/metadata">
    ...
    <botUser></botUser>
    ...
</Bot>
```

Or:
```xml
<Bot xmlns="http://soap.sforce.com/2006/04/metadata">
    ...
    <botUser>old@example.com</botUser>
    ...
</Bot>
```

**If file cannot be read:**
- Report error: "❌ Cannot read bot-meta.xml"
- Check file path and permissions
- Stop execution

**If file read successfully:**
- Store XML content for editing
- Continue to Step 4

---

### Step 4 — Update Service Agent botUser tag AND PulseMedAssitant default_agent_user with new email

**CRITICAL: Use Edit tool to update files (never Write tool)**

**IMPORTANT:** This step updates TWO files:
1. `Agentforce_Service_Agent.bot-meta.xml` — the `<botUser>` XML tag
2. `PulseMedAssitant.agent` — the `default_agent_user:` YAML field at line 15

Clinician_Copilot does NOT require botUser configuration.

**Step 4.1 — Update Agentforce_Service_Agent.bot-meta.xml**

**Canonical case (placeholder pattern — repo state):**

The repo file ships with `<botUser>AGENT_USER_EMAIL</botUser>`. Substitute the placeholder with the real email:

```
Tool: Edit
file_path: {repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml
old_string: <botUser>AGENT_USER_EMAIL</botUser>
new_string: <botUser>{agent_user_email}</botUser>
```

**Fallback cases (only if `AGENT_USER_EMAIL` placeholder is missing):**

If a previous run failed mid-flow without rollback, the file may contain a stale email or be empty. Read the file first to detect:

- If contains `<botUser></botUser>` → empty tag, replace with `<botUser>{agent_user_email}</botUser>`
- If contains `<botUser>old@example.com</botUser>` → stale email from a prior run, replace with `<botUser>{agent_user_email}</botUser>`
- If `<botUser>` tag is missing entirely → insert after `</botVersions>`

In all fallback cases, log a warning: `⚠️ Repo file was not in canonical placeholder state — previous run may have failed without rollback`.

**Step 4.2 — Update PulseMedAssitant.agent (default_agent_user)**

The PulseMedAssitant authoring bundle stores its runtime user in a YAML field at **line 15** of `PulseMedAssitant.agent`. Update it with the same freshly-created agent user email so the bundle deploys with a valid run-as user.

**Locate the file first (path may vary by repo layout):**

```bash
# Primary path per user spec:
PULSEMED_FILE="{repo_path}/force-app/force-app/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"

# Fallback path (if authoring bundle ships under ps-post-pack):
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE="{repo_path}/ps-post-pack/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"

# Last-resort discovery:
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE=$(find "{repo_path}" -type f -name "PulseMedAssitant.agent" | head -1)
```

**If `PULSEMED_FILE` is empty / file not found:**
- Log a warning: `⚠️ PulseMedAssitant.agent not found — skipping Step 4.2 (bundle may not ship in this repo revision)`
- Continue to Step 5 (do NOT stop — the PulseMedAssitant bundle is optional in older repo revisions)

**If `PULSEMED_FILE` is found — read it and edit the `default_agent_user:` line:**

The line format (line 15) is a YAML key with a quoted email value, e.g.:

```yaml
default_agent_user: "eagent1787224813402@test.com"
```

Read the file to capture the current value on line 15, then use Edit to substitute:

```
Tool: Edit
file_path: <PULSEMED_FILE>
old_string: default_agent_user: "<current_value_on_line_15>"
new_string: default_agent_user: "{agent_user_email}"
```

If the current value on line 15 is a known placeholder like `AGENT_USER_EMAIL` or an empty string `""`, use that as the `old_string`. Otherwise use the actual email currently present (from the file read).

**If Edit fails on either file:**
- Report error: "❌ Failed to update {which file}"
- Show current content of the target tag/line
- Stop execution

**If both edits succeed:**
- Report: "✅ Service Agent bot configuration updated with Agent User: {agent_user_email}"
- Report: "✅ PulseMedAssitant default_agent_user updated with Agent User: {agent_user_email}"
- Note: "Clinician_Copilot does not require botUser configuration"
- Continue to Step 4.2 (PulseMedAssitant substitution)

---

### Step 4.2 — Update PulseMedAssitant.agent default_agent_user (line 15)

**Why:** The PulseMedAssitant authoring bundle ships with a source-org placeholder value at line 15:

```yaml
access:
    default_agent_user: "eagent1787224813402@test.com"
```

Before we deploy the bundle (Step 6) and publish it to a runtime agent (Step 9a), that placeholder MUST be replaced with the real agent user email captured in Step 2 — otherwise `sf agent publish authoring-bundle` compiles a Bot whose run-as user does not exist in the target org, and every conversation fails at first turn.

**Locate the file (path may vary by repo layout — try in this order):**

```bash
PULSEMED_FILE="{repo_path}/ps-post-pack/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE="{repo_path}/force-app/force-app/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE=$(find "{repo_path}" -type f -name "PulseMedAssitant.agent" | head -1)
```

**If `PULSEMED_FILE` is not found:**
- Log a warning: `⚠️ PulseMedAssitant.agent not found — skipping Step 4.2 (bundle may not ship in this repo revision)`
- Log a matching skip in `state.warnings`
- Continue to Step 5 (do NOT stop — the bundle is optional in older repo revisions; Step 9a will detect this and also skip)

**If `PULSEMED_FILE` is present — read it and capture the current line-15 value:**

```bash
CURRENT_LINE=$(sed -n '15p' "$PULSEMED_FILE" | tr -d '\r')
CURRENT_VALUE=$(echo "$CURRENT_LINE" | grep -oE '"[^"]*"' | tr -d '"')
echo "Current default_agent_user on line 15: $CURRENT_VALUE"
```

**Canonical case (source-org placeholder):**

If `CURRENT_VALUE` matches the well-known source-org placeholder `eagent1787224813402@test.com`, substitute it:

```
Tool: Edit
file_path: <PULSEMED_FILE>
old_string: default_agent_user: "eagent1787224813402@test.com"
new_string: default_agent_user: "{agent_user_email}"
```

**Fallback cases (repo file is not in the canonical placeholder state):**

- If `CURRENT_VALUE` is a different email (e.g. left over from a prior run against a different org that didn't roll back): substitute whatever is currently on line 15 with the new email using the actual `CURRENT_VALUE` as the `old_string`.
- If `CURRENT_VALUE` is empty (i.e. `default_agent_user: ""`): substitute the empty pair with the new email.
- If line 15 is not `default_agent_user:` at all (file has been re-formatted): STOP and surface the file so the operator can fix the layout — do NOT guess a line number.

Log a warning for any fallback case: `⚠️ PulseMedAssitant.agent was not in canonical placeholder state — previous run may have failed without rollback`.

**If Edit fails:**
- Report error: "❌ Failed to update PulseMedAssitant.agent default_agent_user"
- Show the current file line 15
- Stop execution (do NOT proceed to Step 5 with a mismatched state)

**If Edit succeeds:**
- Report: "✅ PulseMedAssitant default_agent_user updated with Agent User: {agent_user_email}"
- Continue to Step 5

---

### Step 5 — Verify the Service Agent update

**CRITICAL: Verify Service Agent XML was updated correctly before proceeding**

Read the updated Service Agent file to confirm:

```
Tool: Read
file_path: {repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml
```

Search for the updated line: `<botUser>{agent_user_email}</botUser>`

**If found:**
- Report: "✅ Verification successful - Service Agent botUser tag contains: {agent_user_email}"
- Report: "ℹ️ Note: Employee Agent does not require botUser configuration"
- Continue to the PulseMedAssitant verification below.

**If not found:**
- Report error: "❌ Verification failed - Service Agent botUser tag not updated correctly"
- Show current XML content
- Stop execution

**PulseMedAssitant verification (only if Step 4.2 did not skip):**

If Step 4.2 substituted the `.agent` file, verify line 15 now contains the new email:

```bash
sed -n '15p' "$PULSEMED_FILE" | grep -F "$agent_user_email" \
  && echo "✅ Verification successful - PulseMedAssitant default_agent_user contains: $agent_user_email" \
  || { echo "❌ Verification failed - PulseMedAssitant.agent line 15 does not contain $agent_user_email"; exit 1; }
```

If Step 4.2 skipped (file not present), skip this verification too. Continue to Step 6.

---

### Step 6 — Deploy Agents Package

**CRITICAL: Only proceed if Steps 0-5 completed successfully**

Navigate to repository directory and deploy ps-post-pack:

```bash
cd "{repo_path}" && sf project deploy start -d ps-post-pack -o {org_alias}
```

Wait for deployment to complete (may take several minutes).

**Expected output:**
```
Deploy ID: 0Af...
Deploy Status: Succeeded
```

**Common errors and solutions:**

**Error 1: FlexiPage related list error**
```
Error: Could not find related list [<relatedListApiName>] for entity [Account]
```

Solution:
- This occurs when a Data Cloud Related List doesn't exist on the Account object yet
- Affected related lists in `Patient_Account_Page.flexipage-meta.xml`:
  - `Patient_Medication_Request__pr` (Medications)
  - `Allergy_Intolerance__pr` (Allergy)
  - `Patient_Medical_Procedure__pr` (Medical Procedure)
  - `Patient_Health_Condition__pr` (Health Condition)
  - `pacemaker_iot_data__pr` (Pacemaker IOT)
- Comment out the failing related list component in `ps-post-pack/main/default/flexipages/Patient_Account_Page.flexipage-meta.xml`
- Retry deployment

**Error 2: Other deployment failures**
- Report full error message
- Check if botUser XML was updated correctly
- Verify org has required permissions
- Stop execution (do not proceed to next steps)

**If deployment succeeds:**
- Report: "✅ Agents package deployed successfully"
- Report Deploy ID for reference
- Continue to Step 6b

---

### Step 6b — Create Clinical Care Coordinator User (MCP)

**Why here (not in base-metadata-deploy):** The `Cardiologist_Appointment` flow's `Get_User` node looks up a User with full name `Clinical Care Coordinator`. That user requires the `Care Coordinator` Profile and `Care_Coordinator` UserRole, both of which ship in **ps-post-pack** — NOT ps-base. This step therefore must run AFTER Step 6's ps-post-pack deploy, not during base-metadata-deploy. Running it earlier fails with "Profile not found" and stops the install.

Uses `salesforce-sobject-all` MCP tools (`soqlQuery`, `createSobjectRecord`) — do NOT use Apex here.

**Step 6b.1 — Idempotency preflight.**

```
soqlQuery:
  SELECT Id FROM User
  WHERE FirstName = 'Clinical' AND LastName = 'Care Coordinator'
  LIMIT 1
```

If a row is returned, log `Clinical Care Coordinator user already exists (<Id>)` and skip the rest of Step 6b. Re-runs on the same org must NOT create a duplicate — the flow only looks up by full name and any matching user satisfies it.

**Step 6b.2 — Resolve Profile Id.**

```
soqlQuery:
  SELECT Id FROM Profile WHERE Name = 'Care Coordinator' LIMIT 1
```

Cache as `<profileId>`. If zero rows, STOP — ps-post-pack deploy (Step 6) did not land the profile. Surface the issue rather than skipping.

**Step 6b.3 — Resolve UserRole Id.**

```
soqlQuery:
  SELECT Id FROM UserRole WHERE DeveloperName = 'Care_Coordinator' LIMIT 1
```

Cache as `<roleId>`. If zero rows, STOP — same reason as 6b.2.

**Step 6b.4 — Insert the User.**

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

---

### Step 6c — Assign PersonAccount Layout to System Administrator (idempotent)

**Why:** The FlexiPage `Patient_Account_Page` uses `force:relatedListContainer` in the Clinical Data tab, which reads the classic layout assigned to the viewing user's profile + record type. For System Administrator to see the canonical 3 related lists (Assets, Case, Service Appointment), every PersonAccount RecordType must be assigned to `PersonAccount-Person Account Layout`.

This step is idempotent: already-correct assignments are left alone; missing or incorrect ones are set.

**Step 6c.1 — Resolve all PersonAccount RecordTypes on the target org:**

```bash
sf data query --target-org {org_alias} \
  -q "SELECT DeveloperName FROM RecordType WHERE SobjectType='Account' AND IsPersonType=true"
```

Capture the DeveloperName list (e.g. `PersonAccount`, `SDO_PersonAccounts`). If zero rows: skip Step 6c entirely — no PA record types exist, nothing to assign.

**Step 6c.2 — Check current assignments for System Administrator:**

⚠️ **Tooling API `ProfileLayout` does NOT support the `RecordType.DeveloperName` / `RecordType.SobjectType` / `RecordType.IsPersonType` relationship traversal.** Attempting a single joined query returns `No such column 'DeveloperName' on entity 'RecordType'` and the step silently skips. Use the two-step lookup below — the PA RecordType Ids from Step 6c.1 filter `ProfileLayout` by Id, and layout Ids are resolved to names in a separate lookup.

**Step 6c.2a — Query ProfileLayout by RecordType Ids collected in Step 6c.1:**

```bash
sf data query --use-tooling-api --target-org {org_alias} -q \
  "SELECT RecordTypeId, LayoutId FROM ProfileLayout
   WHERE Profile.Name='System Administrator'
   AND RecordTypeId IN ({comma_separated_pa_rt_ids_from_step_6c.1})"
```

**Step 6c.2b — Resolve the LayoutIds returned above to Layout Names:**

```bash
sf data query --use-tooling-api --target-org {org_alias} -q \
  "SELECT Id, Name FROM Layout WHERE Id IN ({comma_separated_layout_ids_from_step_6c.2a})"
```

Build a map `{LayoutId → LayoutName}`, then combine with Step 6c.2a's rows to compute `{RecordTypeId → LayoutName}`. Build a set of RecordType Ids (or their DeveloperNames from Step 6c.1) where the resolved `LayoutName` is already `PersonAccount-Person Account Layout`. Anything NOT in that set needs assignment.

**Step 6c.3 — Skip condition:**

If every PA RecordType from Step 6c.1 is already correctly assigned, log: `✅ System Administrator already has PersonAccount-Person Account Layout for all PA RecordTypes — skipping.` Continue to Step 7.

**Step 6c.4 — Generate Admin.profile-meta.xml (only for RecordTypes needing assignment):**

Write to `/c/tmp/profile-patch/force-app/main/default/profiles/Admin.profile-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Profile xmlns="http://soap.sforce.com/2006/04/metadata">
    <layoutAssignments>
        <layout>PersonAccount-Person Account Layout</layout>
        <recordType>PersonAccount.<DeveloperName_1></recordType>
    </layoutAssignments>
    <!-- one <layoutAssignments> block per RecordType from the delta -->
</Profile>
```

Also drop a minimal `sfdx-project.json` at `/c/tmp/profile-patch/` so `sf project deploy start` recognizes the folder.

**Step 6c.5 — Deploy the profile patch:**

```bash
sf project deploy start -d /c/tmp/profile-patch -o {org_alias}
```

Expected: `Status: Succeeded`.

**Step 6c.6 — Verify (loop-until-100%-success fallback, hard-fail gate):**

Re-run the query from Step 6c.2. Every PA RecordType from **Step 6c.1** (the FULL list, not the Step 6c.3 delta — the delta may have been miscomputed, which is exactly the 2026-09-02 HCOrg1 failure mode where the delta contained only `PersonAccount` while `SDO_PersonAccounts` was quietly left on `HLS - Person Account Layout`) under System Administrator must show `Layout.Name = 'Person Account Layout'`.

**Fallback loop — retry until every PA RecordType is correct or MAX_ATTEMPTS is exhausted:**

```
MAX_ATTEMPTS = 5
attempt = 1
while attempt <= MAX_ATTEMPTS:
    unresolved = [rt for rt in PA_RT_FROM_STEP_6C_1
                  if lookup_layout_for_recordtype(rt) != 'Person Account Layout']
    if not unresolved:
        log("✅ Step 6c.6: all {n} PA RecordTypes now on 'Person Account Layout'")
        break

    log(f"⚠️  Attempt {attempt}/{MAX_ATTEMPTS} — {len(unresolved)} PA RecordType(s) still wrong: {unresolved}. Regenerating profile with a <layoutAssignments> block per RecordType and redeploying…")

    # Regenerate Admin.profile-meta.xml with ONE <layoutAssignments> block per
    # RecordType in `unresolved`. Overwrite the file from Step 6c.4 — do not append.
    write_profile(unresolved)

    # Redeploy via Step 6c.5.
    deploy_id = sf_project_deploy_start('/c/tmp/profile-patch', org_alias)
    require deploy_id.status == 'Succeeded'  # if the deploy itself fails, hard-fail immediately — do not swallow

    attempt += 1

else:
    # Loop exhausted MAX_ATTEMPTS without every RecordType converging.
    # HARD FAIL — do NOT append 'agent-setup-configuration' to completedSkills.
    # A resumed run will re-enter Step 6c and reconcile.
    raise SkillFailure(
        f"Step 6c.6 could not converge after {MAX_ATTEMPTS} attempts. "
        f"Still-wrong RecordTypes: {unresolved}. "
        f"Common causes: (1) 'Person Account Layout' does not exist under the PersonAccount object in this org — "
        f"check via `SELECT Id, Name FROM Layout WHERE EntityDefinitionId='PersonAccount'`; "
        f"(2) System Administrator profile is missing IPermissionsModifyAllData / edit-profile perms; "
        f"(3) the profile deploy is being blocked by an org-level layout permission — check the deploy result verbose output."
    )
```

**Success criteria for this step (both must hold):**
1. The `unresolved` list is empty (every PA RecordType from Step 6c.1 verifies against `Person Account Layout`).
2. The final deploy in the loop returned `Status: Succeeded`.

If either fails, the skill returns failure and `agent-setup-configuration` is NOT written to `state.completedSkills` — the durable-state wrapper at the bottom of this SKILL.md will not persist completion, and the next installer run will re-execute Step 6c from a clean slate.

**Cleanup:**

```bash
rm -rf /c/tmp/profile-patch
```

---

### Step 7 — Assign PulseSyncCustomPS Permission Set to the Agent User (MANDATORY)

**🚨 CRITICAL — DO NOT SKIP. Without this permset on the agent user, both bots will fail at first conversation with object-access errors. The CLI's `sf org assign permset` defaults to the running CLI user (a System Administrator), NOT the freshly-created agent user, so use the targeted Apex assignment below.**

Run an Apex block that:
1. Looks up the agent User by the email captured in Step 2.
2. Looks up the `PulseSyncCustomPS` PermissionSet.
3. Inserts a `PermissionSetAssignment` if and only if one doesn't already exist for that pair.

The `createAgentUser.apex` script in some repo branches already assigns `PulseSyncCustomPS` as part of user creation. The block below is idempotent — if the assignment is already present, it logs and exits cleanly. Run it unconditionally; never skip this step on the assumption "the apex already did it."

```bash
cat > /c/tmp/assignPermsetToAgentUser.apex <<APEX
String agentEmail = '{agent_user_email}';
User u = [SELECT Id, Username, Email FROM User WHERE Email = :agentEmail LIMIT 1];
PermissionSet ps = [SELECT Id, Name FROM PermissionSet WHERE Name = 'PulseSyncCustomPS' LIMIT 1];
List<PermissionSetAssignment> existing = [SELECT Id FROM PermissionSetAssignment
                                          WHERE AssigneeId = :u.Id AND PermissionSetId = :ps.Id LIMIT 1];
if (existing.isEmpty()) {
    insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
    System.debug('Assigned PulseSyncCustomPS to ' + u.Username);
} else {
    System.debug('PulseSyncCustomPS already assigned to ' + u.Username);
}
APEX

sf apex run -f /c/tmp/assignPermsetToAgentUser.apex --target-org {org_alias}
```

**Expected debug line:** either `Assigned PulseSyncCustomPS to <username>` (first run) or `PulseSyncCustomPS already assigned to <username>` (re-run).

**Hard verification — before proceeding to Step 8:**

```bash
sf data query --target-org {org_alias} \
  -q "SELECT COUNT() FROM PermissionSetAssignment WHERE Assignee.Email = '{agent_user_email}' AND PermissionSet.Name = 'PulseSyncCustomPS'"
```

Expected: **`totalSize: 1`**. If `0`:
- Re-run the Apex block once.
- Re-query.
- If still `0`, **STOP** — surface the apex log. Do NOT proceed to Step 8 (agents activated without this permset will appear "active" in Setup but break the moment a user talks to them).

**Cleanup of the temp Apex file:**

```bash
rm -f /c/tmp/assignPermsetToAgentUser.apex
```

Continue to Step 8 only after verification confirms the assignment.

---

### Step 7.5 — Bind System Administrator profile + PulseSyncCustomPS to Clinician_Copilot ONLY (MANDATORY — runs BEFORE activation)

**🚨 SCOPE — this step targets ONLY `Clinician_Copilot`. The Service Agent (`Agentforce_Service_Agent`) is excluded.**

| Agent | How it gets access | Where it's configured |
|---|---|---|
| `Agentforce_Service_Agent` (`type=ExternalCopilot`) | Via `<botUser>` in bot-meta.xml | **Step 4** — set in `Agentforce_Service_Agent.bot-meta.xml` to point at the agent user. Service agents run as the bot user; profile/permset bindings on the bot itself are not used. |
| `Clinician_Copilot` (`type=InternalCopilot`) | Via `SetupEntityAccess` rows binding (Profile-shadow PS + PulseSyncCustomPS) → BotDefinition | **THIS STEP (7.5)** — Apex DML inserts 2 rows. The Employee Agent runs as the launching user, so launching users need their profile or permset on the agent's access list. |

**Why the Service Agent is intentionally NOT bound here:** the Service Agent has a `<botUser>` (set in Step 4 to e.g. `eagent1781609906384@test.com`). When a customer chats with it via Embedded Messaging, the bot runs as the bot user — there is no per-customer profile in play. Adding `SetupEntityAccess` rows for the Service Agent would have no effect on its runtime behavior; its access is governed entirely by the bot user's own permsets (Step 7 already assigns PulseSyncCustomPS to that user).

**Why the Employee Agent needs SetupEntityAccess:** `Clinician_Copilot` is `<type>InternalCopilot</type>` with `agentType: AgentforceEmployeeAgent`. It does NOT support `<botUser>` (Salesforce returns: *"The bot type InternalCopilot doesn't support the Bot User setting"* — verified 2026-06-16 deploy `0Afg7000006AjRpCAK`). Instead, the Setup UI at `/lightning/setup/EinsteinCopilot/<botId>/edit` → **Agent Access** tab exposes:

- **"Profiles with Agent Access"** — which profiles can launch the agent
- **"Permission Sets with Agent Access"** — which permsets can launch the agent

**Both tabs are views over the same physical table: `SetupEntityAccess` (writable via Apex DML).** Each row binds one Profile (via its profile-shadow PermissionSet) OR one PermissionSet to one Bot via:
- `ParentId` = PermissionSet Id (a profile-shadow permset for profile bindings, OR a regular PermissionSet for permset bindings)
- `SetupEntityId` = `BotDefinition.Id` (e.g. `0Xxg7000000jfLZCAY` for Employee Agent)
- `SetupEntityType` = auto-derived to `'BotDefinition'` (DO NOT set this field — it's read-only and Apex insert fails with `Field is not writeable: SetupEntityAccess.SetupEntityType` if you try)

**This step writes those rows directly via Apex DML.** It does NOT depend on Salesforce's auto-bind-during-deploy behavior, which is org-version-dependent and unreliable. Verified working 2026-06-16: 2 rows inserted via Apex (System Administrator profile-shadow permset + PulseSyncCustomPS), both immediately visible in the Setup UI.

**Apex script template — bind ONLY the Employee Agent (2 rows):**

```bash
cat > /c/tmp/bindEmployeeAgentAccess.apex <<'APEX'
// Bind System Administrator profile + PulseSyncCustomPS to Clinician_Copilot ONLY.
// Writes to SetupEntityAccess — the table behind the Setup UI's
// "Profiles with Agent Access" + "Permission Sets with Agent Access" tabs.
//
// Agentforce_Service_Agent is intentionally excluded — its access is via <botUser> in
// bot-meta.xml (Step 4), not via SetupEntityAccess. Adding rows for the Service
// Agent here would have no runtime effect.

// Resolve the System Administrator profile's shadow PermissionSet.
// Salesforce stores per-profile permset rows in PermissionSet with IsOwnedByProfile=true.
Profile sysAdmin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
PermissionSet adminShadowPS = [
    SELECT Id, Name FROM PermissionSet
    WHERE ProfileId = :sysAdmin.Id AND IsOwnedByProfile = true LIMIT 1
];
System.debug('System Admin shadow permset: ' + adminShadowPS.Id + ' (' + adminShadowPS.Name + ')');

// Resolve PulseSyncCustomPS
PermissionSet pulseSyncPS = [SELECT Id FROM PermissionSet WHERE Name = 'PulseSyncCustomPS' LIMIT 1];
System.debug('PulseSyncCustomPS: ' + pulseSyncPS.Id);

// Resolve Clinician_Copilot BotDefinition
BotDefinition employeeBot = [
    SELECT Id, DeveloperName FROM BotDefinition
    WHERE DeveloperName = 'Clinician_Copilot' LIMIT 1
];
Id employeeBotId = employeeBot.Id;
System.debug('Clinician_Copilot BotId: ' + employeeBotId);

// Pre-query existing SetupEntityAccess rows (idempotency)
List<SetupEntityAccess> existing = [
    SELECT Id, ParentId FROM SetupEntityAccess
    WHERE SetupEntityId = :employeeBotId AND SetupEntityType = 'BotDefinition'
];
Set<Id> existingParents = new Set<Id>();
for (SetupEntityAccess s : existing) existingParents.add(s.ParentId);

// Build the desired 2-row binding set:
//   (System Admin shadow PS, Employee Bot)
//   (PulseSyncCustomPS,       Employee Bot)
List<SetupEntityAccess> toInsert = new List<SetupEntityAccess>();
for (Id parentId : new List<Id>{adminShadowPS.Id, pulseSyncPS.Id}) {
    if (!existingParents.contains(parentId)) {
        // CRITICAL: do NOT set SetupEntityType — it is read-only and auto-derived from SetupEntityId prefix.
        // Including it causes: "Field is not writeable: SetupEntityAccess.SetupEntityType"
        toInsert.add(new SetupEntityAccess(ParentId = parentId, SetupEntityId = employeeBotId));
    }
}

if (toInsert.isEmpty()) {
    System.debug('Both Employee Agent bindings already present — no DML needed');
} else {
    insert toInsert;
    System.debug('Inserted ' + toInsert.size() + ' SetupEntityAccess rows for Clinician_Copilot');
    for (SetupEntityAccess s : toInsert) {
        System.debug('  Bound ParentId=' + s.ParentId + '  to BotId=' + s.SetupEntityId);
    }
}
APEX

sf apex run -f /c/tmp/bindEmployeeAgentAccess.apex --target-org {org_alias}
```

**Hard verification — before proceeding to Step 8:**

```bash
sf data query --target-org {org_alias} -q "SELECT COUNT() FROM SetupEntityAccess WHERE SetupEntityType = 'BotDefinition' AND SetupEntityId IN (SELECT Id FROM BotDefinition WHERE DeveloperName = 'Clinician_Copilot')"
```

Expected: **`totalSize: 2`** (Employee Agent × 2 bindings: System Admin shadow permset + PulseSyncCustomPS).

If `< 2` after the Apex run, re-run the Apex once. If still `< 2`, STOP and surface:

- The Apex log
- The current SOQL count
- A row-by-row dump of what IS present:
  ```bash
  sf data query --target-org {org_alias} \
    -q "SELECT Parent.Name, Parent.Label, SetupEntityId FROM SetupEntityAccess WHERE SetupEntityType = 'BotDefinition' AND SetupEntityId IN (SELECT Id FROM BotDefinition WHERE DeveloperName = 'Clinician_Copilot')"
  ```

**Cleanup of the temp Apex file:**

```bash
rm -f /c/tmp/bindEmployeeAgentAccess.apex
```

Continue to Step 8 only after the SOQL count returns 2.

**Why this works:** `SetupEntityAccess` is the underlying table for ALL "Permission Set Group" / Profile permset / agent-access bindings in Setup UI. It accepts Apex DML on `INSERT` (and `DELETE` to remove bindings). The `Field is not writeable: SetupEntityAccess.SetupEntityType` error is the only gotcha — leave that field out and Salesforce derives it from the SetupEntityId's 3-character prefix (`0Xx` → `BotDefinition`).

**Why we use the profile-shadow permset and not the Profile directly:** the Setup UI's "Profiles with Agent Access" tab actually doesn't bind Profiles — it binds the **profile-shadow PermissionSet** that Salesforce auto-creates for every Profile. These rows have `IsOwnedByProfile = true` and `Name = 'X00<encoded_profile_id>...'`. The `PulseSyncCustomPS` (a regular permset) and the System Admin shadow permset are both ParentIds on `SetupEntityAccess` — they're distinguished only by which tab the UI puts them in based on `IsOwnedByProfile`.

---

### Step 8 — Activate Employee Agent (Clinician_Copilot) — MANDATORY

**🚨 BOTH AGENTS MUST BE ACTIVATED. This step CANNOT be skipped, marked as "non-critical", or treated as optional.** A `BotDefinition` created by the metadata deploy is `Inactive` by default; without `sf agent activate`, the App Launcher entry exists but the agent never runs.

```bash
sf agent activate --api-name Clinician_Copilot --target-org {org_alias}
```

**Expected output (verbatim):** `Agent Clinician_Copilot activated.`

**Retry policy:**
- On failure containing `"still being provisioned"` / `"BotDefinition not found"` / `"Bot is not yet ready"` → wait 30s, retry. Up to **5 attempts** total (older guidance said 3 — bumping to 5 because deploy-to-activate provisioning lag has been observed at >2 minutes on fresh orgs).
- On any other failure → STOP and surface the CLI output. Do NOT continue to Step 9 — both agents must succeed together as a unit.

**Hard verification:**

```bash
sf data query --target-org {org_alias} \
  -q "SELECT Id, MasterLabel, DeveloperName FROM BotVersion WHERE BotDefinition.DeveloperName = 'Clinician_Copilot' AND Status = 'Active'"
```

Expected: **`totalSize: 1`**. If `0`, the CLI's success message lied about activation (rare but observed) — re-run `sf agent activate` once and re-verify. If still `0`, STOP and surface the SOQL response.

Continue to Step 9 only after verification shows an Active BotVersion.

---

### Step 9 — Activate Service Agent (Agentforce_Service_Agent) — MANDATORY

**🚨 SAME RULE AS STEP 8 — DO NOT SKIP, DO NOT TREAT AS OPTIONAL.** The Service Agent is the one wired to the Embedded Messaging chat icon on the storefront — without it, every chat session opens to a non-functional bot.

```bash
sf agent activate --api-name Agentforce_Service_Agent --target-org {org_alias}
```

**Expected output (verbatim):** `Agent Agentforce_Service_Agent activated.`

**Retry policy:** identical to Step 8 — up to 5 attempts, 30s between retries, on `"provisioning"` / `"not yet ready"` / `"BotDefinition not found"` errors.

**Hard verification:**

```bash
sf data query --target-org {org_alias} \
  -q "SELECT Id, MasterLabel, DeveloperName FROM BotVersion WHERE BotDefinition.DeveloperName = 'Agentforce_Service_Agent' AND Status = 'Active'"
```

Expected: **`totalSize: 1`**. If `0`, re-run activation once and re-verify. If still `0`, STOP and surface the SOQL response — the Service Agent is a hard dependency for the storefront chat icon and the install is incomplete without it.

Continue to Step 9a (PulseMedAssitant publish + activate) only after BOTH Step 8 AND Step 9 verifications confirm Active BotVersions.

---

<<<<<<< Updated upstream
### Step 9a — Publish + activate PulseMedAssitant authoring bundle (agent-user-aware)

**Purpose:** After Step 6's `ps-post-pack` deploy landed the `PulseMedAssitant` authoring bundle and Step 4.2 stamped the correct `default_agent_user` in the source YAML, publish the bundle to a runtime agent definition (creates `BotDefinition` + compiled `BotVersion`) and activate it. Also ensure the agent user has `PulseSyncCustomPS` — same pattern as Step 7, but scoped to the user this bundle runs as (which is the same email since Step 4.2 wrote the Step 2 email into line 15).

**Precondition:** Step 4.2 successfully updated `PulseMedAssitant.agent` line 15 with `{agent_user_email}`. If Step 4.2 skipped (bundle not present in this repo revision), skip Step 9a entirely with a matching `state.warnings` entry.

**Step 9a.1 — Detect the bundle:**

```bash
PULSEMED_FILE="{repo_path}/ps-post-pack/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE="{repo_path}/force-app/force-app/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"
=======
### Step 9a — Publish + activate PulseMedAssitant authoring bundle

**Purpose:** After the ps-post-pack deploy has landed the `PulseMedAssitant` authoring bundle and Step 4.2 has stamped the correct `default_agent_user`, publish the bundle to a runtime agent definition and activate it.

**Precondition:** Step 4.2 successfully updated `PulseMedAssitant.agent` line 15 with the freshly-created agent user email. If Step 4.2 was skipped (because the authoring bundle is not present in this repo revision), skip Step 9a entirely.

**Detection — is the PulseMedAssitant bundle in play?**

```bash
# Prefer the primary path; fall back to discovery.
PULSEMED_FILE="{repo_path}/force-app/force-app/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE="{repo_path}/ps-post-pack/main/default/aiAuthoringBundles/PulseMedAssitant/PulseMedAssitant.agent"
>>>>>>> Stashed changes
[ -f "$PULSEMED_FILE" ] || PULSEMED_FILE=$(find "{repo_path}" -type f -name "PulseMedAssitant.agent" | head -1)

if [ -z "$PULSEMED_FILE" ] || [ ! -f "$PULSEMED_FILE" ]; then
  echo "ℹ️  PulseMedAssitant bundle not present in this repo — skipping Step 9a."
  # Continue to Step 9.5
  exit 0
fi
```

<<<<<<< Updated upstream
**Step 9a.2 — Ensure `sf agent publish authoring-bundle` is available.**

The publish subcommand was added in `@salesforce/plugin-agent ≥ 2.0.5`. Older `sf` CLI installs (2.113.x) ship without it. Detect and install on demand:

```bash
if ! sf help agent 2>&1 | grep -q "agent publish"; then
  echo "Installing @salesforce/plugin-agent (needed for 'sf agent publish authoring-bundle')..."
  sf plugins install @salesforce/plugin-agent
fi
```

**Step 9a.3 — Stage the bundle in a minimal sfdx project.**

`sf agent publish authoring-bundle` walks `<CWD>/<default_package>/aiAuthoringBundles/<bundle>`. The repo's `sfdx-project.json` has `ps-datacloud` as `default`, and the bundle is nested at `ps-post-pack/main/default/aiAuthoringBundles/PulseMedAssitant/` — so the command cannot find it from either the repo root or `ps-post-pack/`.

Rather than mutating `sfdx-project.json` (which is source-of-truth for the whole install), stage the bundle in a scratch dir with a minimal sfdx layout that puts the bundle at the depth the plugin expects:

```bash
STAGE=/c/tmp/pma-publish
rm -rf "$STAGE"
mkdir -p "$STAGE/main/default/aiAuthoringBundles"
cp -r "$(dirname "$PULSEMED_FILE")" "$STAGE/main/default/aiAuthoringBundles/"
cat > "$STAGE/sfdx-project.json" <<EOF
{
  "packageDirectories":[{"path":"main","default":true}],
  "name":"pma-publish",
  "namespace":"",
  "sfdcLoginUrl":"https://login.salesforce.com",
  "sourceApiVersion":"66.0"
}
EOF
```

**Step 9a.4 — Publish (run from the staged dir):**

```bash
(cd "$STAGE" && sf agent publish authoring-bundle --api-name PulseMedAssitant -o {org_alias})
```

Expected output: `✓ Agent 'PulseMedAssitant' published successfully`. Publish walks 4 stages internally (`Validate Bundle` → `Publish Agent` → `Retrieve Metadata` → `Deploy Metadata`). If any stage fails, STOP and surface the CLI output — do NOT proceed to activate.

**Step 9a.5 — Activate:**
=======
**Publish the authoring bundle to a runtime agent definition:**

```bash
sf agent publish authoring-bundle --api-name PulseMedAssitant -o {org_alias}
```

Expected: publish reports success and the runtime `BotDefinition` for `PulseMedAssitant` exists in the org.

**Activate the published agent:**
>>>>>>> Stashed changes

```bash
sf agent activate --api-name PulseMedAssitant -o {org_alias}
```

<<<<<<< Updated upstream
Expected output (verbatim): `PulseMedAssitant v1 activated.`

**Retry policy:** up to 5 attempts, 30s between retries, on `"provisioning"` / `"not yet ready"` / `"BotDefinition not found"` errors. Same as Steps 8/9.

**Step 9a.6 — Assign `PulseSyncCustomPS` to the PulseMedAssitant run-as user (idempotent).**

Because PulseMedAssitant runs as the user named in `default_agent_user` (same email as Steps 4.1 / 7 wrote), this is usually a no-op — Step 7's Apex block already assigned the permset. But re-run the block idempotently in case:
- the Step 7 assignment was somehow lost between Step 7 and Step 9a
- the PulseMedAssitant bundle is being run against a different agent user than Clinician_Copilot / Agentforce_Service_Agent

Reuse the Apex template from Step 7 (looks up user by email, looks up PS by name, inserts assignment if and only if none exists). Verify via SOQL:

```bash
sf data query --target-org {org_alias} \
  -q "SELECT COUNT() FROM PermissionSetAssignment WHERE Assignee.Email = '{agent_user_email}' AND PermissionSet.Name = 'PulseSyncCustomPS'"
```

Expected: `totalSize: 1`. If `0`, re-run the Apex once. If still `0` after retry, STOP — a live agent without PulseSyncCustomPS on its run-as user breaks at first conversation with object-access errors.

**Step 9a.7 — Hard verification of activation:**

```bash
sf data query --target-org {org_alias} \
  -q "SELECT Id, DeveloperName, Status FROM BotVersion WHERE BotDefinition.DeveloperName = 'PulseMedAssitant' AND Status = 'Active'"
```

Expected: `totalSize: 1`. Also verify the `BotDefinition.Type = 'ExternalCopilot'`:

```bash
sf data query --target-org {org_alias} \
  -q "SELECT Id, DeveloperName, Type FROM BotDefinition WHERE DeveloperName = 'PulseMedAssitant'"
```

Expected: 1 row with `Type = ExternalCopilot`. If Type is `InternalCopilot` or `Bot`, STOP — the bundle template was `SvcCopilotTmpl__AgentforceServiceAgent` and MUST compile to ExternalCopilot for Embedded Messaging to route to it.

**Cleanup:**

```bash
rm -rf "$STAGE"
```

**Step 9a artifacts to record in `state.artifacts["agent-setup-configuration"]`:**

```json
{
  "pulseMedAssitantBotId": "<Id from Step 9a.7>",
  "pulseMedAssitantVersionId": "<BotVersion.Id from Step 9a.7>",
  "pulseMedAssitantRunAsUser": "{agent_user_email}",
  "pulseMedAssitantPublishedAt": "<ISO-8601 ts>"
}
```

Continue to Step 9.5 (rollback) only after BOTH `BotVersion Status=Active` AND `PermissionSetAssignment count=1` verifications pass, OR the Step 9a.1 detection block skipped this step entirely.
=======
Expected output (verbatim): `Agent PulseMedAssitant activated.`

**Retry policy:** identical to Steps 8/9 — up to 5 attempts, 30s between retries, on `"provisioning"` / `"not yet ready"` / `"BotDefinition not found"` errors. Publish must succeed before activate is retried; if publish fails, do NOT proceed to activate — surface the CLI output and STOP.

**Hard verification:**

```bash
sf data query --target-org {org_alias} \
  -q "SELECT Id, MasterLabel, DeveloperName FROM BotVersion WHERE BotDefinition.DeveloperName = 'PulseMedAssitant' AND Status = 'Active'"
```

Expected: **`totalSize: 1`**. If `0`, re-run activation once and re-verify. If still `0`, STOP and surface the SOQL response.

Continue to Step 9.5 (rollback) only after verification shows an Active BotVersion for PulseMedAssitant, OR the detection block skipped this step entirely.
>>>>>>> Stashed changes

---

### Step 9.5 — Rollback bot-meta.xml to AGENT_USER_EMAIL placeholder

**🚨 THIS STEP IS MANDATORY ON DEPLOY SUCCESS — DO NOT SKIP.**

The repo must remain org-agnostic. After Step 6's deploy succeeded and the agents activated, restore the placeholder so the next run (this org or another org) starts clean.

**Precondition:** Step 6 deploy reported `Status: Succeeded`. If deploy failed, skip this step entirely — leave the file dirty so the user can inspect what was about to deploy. Agent activation failures (Steps 8-9) DO NOT block rollback because the agents may activate later automatically; the deploy is the load-bearing operation.

**Reverse the substitution from Step 4:**

```
Tool: Edit
file_path: {repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml
old_string: <botUser>{agent_user_email}</botUser>
new_string: <botUser>AGENT_USER_EMAIL</botUser>
```

Where `{agent_user_email}` is the email captured in Step 2.

**Verify rollback:**

```bash
grep -E "<botUser>" {repo_path}/ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml
```

Expected output: `<botUser>AGENT_USER_EMAIL</botUser>`

**If verification fails:**
- Report: `❌ Rollback verification failed for Agentforce_Service_Agent.bot-meta.xml — manual cleanup required`
- The org has the deployed configuration regardless; only the local repo state is dirty
- Continue to Step 10 with a warning

**If verification passes:**
- Report: "✅ Rollback complete — Agentforce_Service_Agent.bot-meta.xml restored to AGENT_USER_EMAIL placeholder"
- Continue to the PulseMedAssitant rollback below.

**PulseMedAssitant.agent rollback (only if Step 4.2 substituted the file):**

Restore the source-org placeholder so re-runs are idempotent:

```
Tool: Edit
file_path: <PULSEMED_FILE>            # same path resolved in Step 4.2 / Step 9a.1
old_string: default_agent_user: "{agent_user_email}"
new_string: default_agent_user: "eagent1787224813402@test.com"
```

**Verify PulseMedAssitant rollback:**

```bash
sed -n '15p' "$PULSEMED_FILE" | grep -F 'eagent1787224813402@test.com' \
  && echo "✅ Rollback complete — PulseMedAssitant.agent line 15 restored to placeholder" \
  || echo "⚠️  PulseMedAssitant rollback verification failed — manual cleanup required (org state is unaffected; only local repo)"
```

If Step 4.2 was skipped (bundle not present), skip this rollback too.

Continue to Step 10.

---

### Step 10 — Generate Final Completion Report

Generate comprehensive completion report:

```text
✅ Agent Setup and Configuration Completed!

Org: {org_alias}
Repository: {repo_path}

═══════════════════════════════════════════════════

📋 Execution Results:

1. ✅ Agent User Created
   Email: {agent_user_email}
   
2. ✅ Bot Configuration Updated
   File: Agentforce_Service_Agent.bot-meta.xml
   botUser: {agent_user_email}
   
3. ✅ Agents Package Deployed
   Package: ps-post-pack
   Deploy ID: {deploy_id}
   Status: Succeeded
   
4. ✅ Permission Set Assigned to Agent User
   Permission Set: PulseSyncCustomPS
   Assigned To: {agent_user_email}

5. ✅ Clinician_Copilot Access Bindings (SetupEntityAccess)
   - Profile: System Administrator (via shadow permset)
   - Permission Set: PulseSyncCustomPS
   Note: Agentforce_Service_Agent uses <botUser> (Step 4) instead of SetupEntityAccess

6. ✅ Employee Agent Activation
   Agent: Clinician_Copilot
   Status: {status}
   
7. ✅ Service Agent Activation
   Agent: Agentforce_Service_Agent
   Status: {status}

═══════════════════════════════════════════════════

🔗 Verify Agent Setup:

1. Navigate to: Setup → Agents
2. Find: Clinician_Copilot and Agentforce_Service_Agent
3. Verify Status: Both show "Active"
4. Test both agents' functionality

═══════════════════════════════════════════════════

📝 Next Steps (Optional):

If you want to commit the configuration change to git:

cd "{repo_path}"
git add ps-post-pack/main/default/bots/Agentforce_Service_Agent/Agentforce_Service_Agent.bot-meta.xml
git commit -m "Configure agent user: {agent_user_email}"
git push

═══════════════════════════════════════════════════

✅ Agent setup workflow completed successfully!
```

---

## Important Rules

**CRITICAL - Execution Sequence:**
- 🚨 **ALWAYS execute commands sequentially** - wait for each to complete
- 🚨 **STOP immediately if Steps 0-5 fail** - user creation and XML update are critical
- 🚨 **Wait for deployment to complete** before proceeding to next step
- 🚨 **Do NOT run commands in parallel** - must be sequential

**CRITICAL - File Handling:**
- ✅ **Always verify files exist** before reading/editing
- ✅ **Use Edit tool** to update existing XML (never Write)
- ✅ **Verify XML update** after editing (Step 5)
- ✅ **Use absolute file paths** for all operations

**CRITICAL - Error Handling:**
- ✅ **Parse Apex output** to extract email address
- ✅ **Stop if email not found** in Apex output
- ✅ **Stop if XML update fails** or verification fails
- ✅ **Stop if deployment fails** - do not proceed to permission set
- ❌ **Permission-set assignment (Step 7) is NOT optional** — STOP if assignment fails AND the SOQL verification shows 0 rows. The previous "continue if permset fails (non-critical)" rule is REMOVED. An agent without `PulseSyncCustomPS` on its run-as user will appear active but fail at first conversation.
- ❌ **Agent activation (Steps 8 + 9) is NOT optional** — both bots MUST end with an Active BotVersion verified via SOQL. The previous "continue if activation fails" rule is REMOVED.
- ✅ **Retry agent activation up to 5 times** (bumped from 3) if provisioning errors occur. If still failing, STOP — do not declare success.

**CRITICAL - CLI Commands:**
- ✅ **ONLY use Salesforce CLI** - no browser automation
- ✅ **Change to repo directory** before deploy commands
- ✅ **Report clear status** messages at each step
- ✅ **Capture command output** for error reporting

**General Rules:**
- NEVER generate JavaScript files
- NEVER write automation scripts to disk
- NEVER overwrite XML with Write tool (use Edit only)
- NEVER skip XML verification step (Step 5)
- NEVER proceed to deployment if email extraction fails
- NEVER proceed to permission set if deployment fails
- NEVER suggest manual completion of any step - automate everything
- ALWAYS report errors with full context
- ALWAYS provide actionable error messages
- Estimated time: 5-10 minutes for complete workflow

---

## Example Usage

### Example 1: Basic agent setup

**User:** "Setup agents in <YOUR_ORG_ALIAS>"

**Skill:**
1. Verifies repository exists
2. Verifies Apex script exists
3. Verifies bot-meta.xml exists
4. Executes: `sf apex run -f scripts/apex/createAgentUser.apex -o <YOUR_ORG_ALIAS>`
5. Parses output → Extracts email: `eagent1234567890@test.com`
6. Reads bot-meta.xml
7. Updates `<botUser>` tag with `eagent1234567890@test.com`
8. Verifies update
9. Deploys: `cd repo && sf project deploy start -d ps-post-pack -o <YOUR_ORG_ALIAS>`
10. Assigns permset: `sf org assign permset -n PulseSyncCustomPS -o <YOUR_ORG_ALIAS>`
11. Activates Employee Agent: `sf agent activate --api-name Clinician_Copilot -o <YOUR_ORG_ALIAS>`
12. Activates Service Agent: `sf agent activate --api-name Agentforce_Service_Agent -o <YOUR_ORG_ALIAS>`
13. Reports completion

---

### Example 2: Error handling - Apex script not found

**User:** "Setup agents in TestOrg"

**Skill:** [Checks for Apex script]

**Error:** `Apex script not found: scripts/apex/createAgentUser.apex`

**Skill:**
```text
❌ Apex Script Not Found

Org: TestOrg

Required File: scripts/apex/createAgentUser.apex

Available files in scripts/apex/:
- createSampleData.apex
- assignPermissionSets.apex

Suggested Fix:
1. Verify repository is cloned correctly
2. Check if createAgentUser.apex exists in the repo
3. Pull latest changes: git pull origin main
4. Retry skill execution

Cannot proceed without Apex script.
```

---

### Example 3: Error handling - Deployment failed

**User:** "Setup agents in ProdOrg"

**Skill:** [Creates user, updates XML, starts deployment]

**Error:** `Deploy failed: Could not find related list [<relatedListApiName>] for entity [Account]`

**Skill:**
```text
❌ Deployment Failed

Org: ProdOrg

Error: FlexiPage related list issue
Could not find related list [<relatedListApiName>] for entity [Account]

This occurs when Data Cloud Related List doesn't exist on Account object.

Automatic Fix:
1. Comment out the failing related list component in:
   ps-post-pack/main/default/flexipages/Patient_Account_Page.flexipage-meta.xml
2. Retry deployment automatically
3. Data Cloud Related List will be created in Step 8 (data-cloud-related-list skill)
```

---

## Success Criteria

Agent setup is successful when **ALL** of these are true (no exceptions, no "non-critical" carve-outs):

✅ Repository and required files verified
✅ Apex script executed successfully
✅ Agent user email extracted from output (via the `Created user:` marker)
✅ bot-meta.xml file read successfully
✅ botUser tag updated with new email
✅ XML update verified
✅ Agents package deployed successfully
✅ **`PulseSyncCustomPS` PermissionSetAssignment exists on the agent user** — verified via SOQL `SELECT COUNT() FROM PermissionSetAssignment WHERE Assignee.Email = '<email>' AND PermissionSet.Name = 'PulseSyncCustomPS'` returning 1
✅ **2 SetupEntityAccess rows exist** binding (System Administrator profile-shadow permset + PulseSyncCustomPS) to Clinician_Copilot — verified via SOQL `SELECT COUNT() FROM SetupEntityAccess WHERE SetupEntityType = 'BotDefinition' AND SetupEntityId IN (SELECT Id FROM BotDefinition WHERE DeveloperName = 'Clinician_Copilot')` returning 2. (Agentforce_Service_Agent is intentionally excluded — its access is via `<botUser>` in bot-meta.xml, not SetupEntityAccess.)
✅ **`Clinician_Copilot` has an Active BotVersion** — verified via SOQL `SELECT Id FROM BotVersion WHERE BotDefinition.DeveloperName = 'Clinician_Copilot' AND Status = 'Active'` returning ≥ 1
✅ **`Agentforce_Service_Agent` has an Active BotVersion** — verified via SOQL `SELECT Id FROM BotVersion WHERE BotDefinition.DeveloperName = 'Agentforce_Service_Agent' AND Status = 'Active'` returning ≥ 1
✅ **(If PulseMedAssitant bundle present) PulseMedAssitant has an Active BotVersion AND `BotDefinition.Type = 'ExternalCopilot'`** — verified via SOQL `SELECT Id FROM BotVersion WHERE BotDefinition.DeveloperName = 'PulseMedAssitant' AND Status = 'Active'` returning ≥ 1, and `SELECT Type FROM BotDefinition WHERE DeveloperName = 'PulseMedAssitant'` returning `ExternalCopilot`.
✅ **(If PulseMedAssitant bundle present) `PulseSyncCustomPS` PermissionSetAssignment on PulseMedAssitant run-as user** — verified via the same SOQL count-1 check as Step 7, run against the same email that Step 4.2 wrote into line 15.
✅ bot-meta.xml rolled back to placeholder (Step 9.5, first half)
✅ **(If PulseMedAssitant bundle present) PulseMedAssitant.agent line 15 rolled back to `eagent1787224813402@test.com` placeholder** (Step 9.5, PulseMed half)
✅ Comprehensive completion report provided

**If ANY of the SOQL verifications above returns 0 rows, the skill MUST report failure — even if the CLI commands all reported success.** Salesforce's `sf agent activate` command, `sf agent publish authoring-bundle`, and `sf org assign permset` have all been observed to report success while the side effect didn't land; the SOQL verification is the only reliable signal.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"agent-setup-configuration"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.agent-setup-configuration` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---

## Notes

- Agent activation via CLI is retried up to 5 times if provisioning errors occur
- Permission set assignment is MANDATORY - skill stops if it fails
- XML update must succeed - deployment will fail without correct botUser
- Deployment can take 5-10 minutes depending on org size
- Both Clinician_Copilot and Agentforce_Service_Agent use the same agent user account

---

## Cleanup temp artifacts (MANDATORY before next skill)

Before declaring this skill complete, delete every temporary file/folder created during the run.

**Failure handling rule:**
- If a step fails (deploy, permset, activation), **do NOT clean up** — leave artifacts for debugging.
- Fix the underlying issue, retry the failed step, then run cleanup once both agents are activated.
- The Step 9.5 rollback (`<botUser>AGENT_USER_EMAIL</botUser>`) is a separate concern — that's repo state, not temp files. It still runs as defined in Step 9.5.

**Files this skill creates and must delete:**

```bash
rm -f /c/tmp/createAgentUser.out
rm -f /c/tmp/ps_post_deploy.json
```

**Verification (must report no remaining agent-setup scratch):**

```bash
ls /c/tmp/createAgentUser.out /c/tmp/ps_post_deploy.json 2>&1 | grep -v "cannot access"
```

**Rules:**
- ✅ Only delete the files listed above. Do NOT delete `scripts/apex/createAgentUser.apex` or any repo source.
- ✅ Step 9.5 (bot-meta.xml rollback to placeholder) is unrelated to this cleanup and must still run.
- ❌ Skipping this step is not allowed once both agents are activated.
