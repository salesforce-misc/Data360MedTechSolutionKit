---
name: copy-field-sync
description: "Automate Data Cloud Copy Field sync for Contact object using Playwright browser automation. Syncs the Pacemaker Patient Health Summary (default) and Unified Individual prod default copy fields for the Healthcare Data Kit. Uses MCP Playwright tools only. Use when user wants to sync copy fields, start field sync, or configure Data Cloud copy fields."
---

# copy-field-sync

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"copy-field-sync"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: copy-field-sync already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Automate Data Cloud Copy Field synchronization for the Contact object using Playwright browser automation.

The skill **only initiates** sync for the Contact Copy Fields. It does NOT check Sync History, does NOT poll status, and does NOT wait for completion. The actual data sync runs in the background on Salesforce after the dialog "Start Sync" button is clicked — that is fire-and-forget from this skill's perspective.

**Target wall-clock: under 60 seconds for both fields.** If the skill takes longer than ~2 min, something is wrong (selector mismatch, slow page load, etc.) — fix the root cause, don't add waits.

**Critical Constraints:**
- ❌ Do NOT generate JavaScript files
- ❌ Do NOT generate Playwright scripts (.js, .mjs, .ts files)
- ❌ Do NOT check Sync History after starting a sync
- ❌ Do NOT poll for "Complete" / "Success" status
- ✅ Exactly ONE `browser_snapshot` + ONE resolved retry are permitted per control lookup after an initial selector miss (see Step 4 fallback). ✅ ONE additional `browser_snapshot` is permitted per lookup as a bounded hydration re-check, but ONLY when the first fallback snapshot contains positive evidence of Lightning Setup still hydrating — a `status "Loading"` node or an empty-content-region skeleton (see Step 3 hydration rule and Step 4 attempt-2b). ❌ Do NOT re-snapshot outside those cases, do NOT re-click the same target, do NOT loop retries, do NOT add `browser_wait_for(time: N)` or sleeps.
- ✅ Use MCP Playwright tools ONLY via direct tool calls
- ✅ Pattern (per field): click field name in list → click Start Sync → click Start Sync in dialog → navigate back to list. Repeat for next field.

This skill syncs the following Data Cloud Copy Fields on Contact object:
1. Pacemaker Patient Health Summary (default)
2. Unified Individual prod default

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username

---

## Preconditions

- Salesforce CLI authenticated with target org (run via `sf org login web -a <org_alias>` if not already)
- User has System Administrator profile or equivalent permissions
- Data Cloud must be enabled and provisioned
- The Pacemaker Patient Health Summary and Unified Individual prod default Contact Copy Fields exist (created by the data kit deploy)
- MCP Playwright tools available (load via ToolSearch in Step 0)
- For uninterrupted execution, `.claude/settings.json` should pre-approve `mcp__plugin_playwright_playwright__*` and `bash:sf *`.

---

## Workflow

```
Step 0: Load Playwright tool schemas
   ↓
Step 1: Get org credentials (instanceUrl + accessToken)
   ↓
Step 2: Launch browser via frontdoor (auto-login)
   ↓
Step 3: Navigate to Copy Fields list page
   ↓
Step 4: Sync each Copy Field (loop over 2 fields) — click row → click Start Sync → click Start Sync in dialog → navigate back to list
   ↓
Step 5: Close browser & generate report
```

**Step 4 browser interactions:** happy path = 7 (per field: 1 click field row + 1 click Start Sync + 1 click dialog Start Sync = 3 clicks × 2 fields = 6, plus 1 navigate back to list between fields). Worst case with fallbacks = up to 15 (per control lookup, at most one fallback snapshot; and, only when that snapshot contains positive evidence the page is still hydrating, ONE additional `browser_snapshot` as a bounded hydration re-check — see the Step 3 hydration rule and the Step 4 Start Sync control resolution). This count covers Step 4 only; Steps 0–3 (tool-schema load, `sf` CLI call, two `browser_navigate` calls) and Step 5 (`browser_close`) each contribute their own tool calls on top. Should complete in well under 2 min end-to-end.

---

### Step 0 — Load Playwright tools

```
ToolSearch(
  query: "select:mcp__plugin_playwright_playwright__browser_navigate,mcp__plugin_playwright_playwright__browser_click,mcp__plugin_playwright_playwright__browser_snapshot,mcp__plugin_playwright_playwright__browser_close",
  max_results: 4
)
```

Snapshot is loaded for one-time selector verification only (not for status polling).

---

### Step 1 — Get org credentials

```bash
sf org display --target-org <org_alias> --json
```

Extract:
- `result.instanceUrl` — base URL for navigation
- `result.accessToken` — used for `frontdoor.jsp?sid=` auto-login

If the command fails ("No org with alias"), STOP and report. Tell the user to run `sf org login web -a <org_alias>`.

---

### Step 2 — Launch browser and auto-login

```
mcp__plugin_playwright_playwright__browser_navigate(
  url: "{instanceUrl}/secur/frontdoor.jsp?sid={accessToken}"
)
```

This drops the user into Lightning, already logged in. No password, no MFA, no screenshot needed.

If the page redirects to a login form, the CLI session expired — STOP and ask the user to run `sf org login web -a <org_alias>`.

---

### Step 3 — Navigate to Copy Fields list

```
mcp__plugin_playwright_playwright__browser_navigate(
  url: "{instanceUrl}/lightning/setup/ObjectManager/Contact/Enrichment-CopyFields/view"
)
```

The list page shows the Copy Fields. Row text is the field label (e.g. `Pacemaker Patient Health Summary`, `Unified Individual prod default`).

**One-time selector verification:** if a `click(target: "text=<field label>")` fails, take ONE snapshot, find the actual link selector, and retry using that pattern.

**Bounded hydration re-check on row resolution.** Lightning Setup's Copy Fields list has been observed to show a `status "Loading"` node in the grid container for ~1–2 seconds after `browser_navigate` completes. If — and ONLY if — the fallback snapshot above shows a `status` node with accessible name `Loading` (case-insensitive) in the grid/main content region, OR shows the grid scaffolding (column headers) present with the row body empty, then this is NOT a "row missing" outcome. Take exactly ONE additional `browser_snapshot` as a hydration re-check (this is the only situation in which a second snapshot is permitted for row resolution). Do NOT add `browser_wait_for(time: N)`, sleeps, or polling loops. After the re-check snapshot: if the expected row is now present, click it using the tool-native actionable reference from THIS second snapshot; if the row is still absent or the page still shows `Loading`, fail row resolution normally with diagnostics that record "hydration re-check exhausted". The re-check is NOT a generic retry — it exists only to distinguish "list hasn't hydrated yet" from "the field no longer exists in the org".

---

### Step 4 — Sync each Copy Field (fire-and-forget)

**No waits between actions** — Playwright's auto-wait handles element appearance. **No `browser_wait_for(time: N)` and no polling loops.** Beyond the happy-path clicks, this step permits per control lookup: (1) ONE fallback `browser_snapshot` after an initial selector miss (attempt 2 below), PLUS (2) exactly ONE additional hydration re-check `browser_snapshot` — but **only** when the fallback snapshot contains the positive hydration evidence defined in attempt 2b (a `status "Loading"` node or an empty-content-region skeleton in the target region). No other extra tool calls are permitted per lookup: no third snapshot, no timers, no sleeps, no polling.

#### Start Sync control resolution (applies to BOTH detail-page and confirmation-dialog clicks)

For each of the two Start Sync clicks per field (detail page, then dialog), follow this exact three-attempt sequence:

1. **First attempt (hard-coded selector).** Issue the `browser_click` with the current hard-coded selector:
   - Detail page: `target: "button:has-text('Start Sync')"`, `element: "Start Sync button on field detail"`
   - Confirmation dialog: `target: "div[role='dialog'] button:has-text('Start Sync')"`, `element: "Confirm Start Sync in dialog"`

   If the click succeeds, proceed. If it fails (selector not found / element not actionable), go to attempt 2.

2. **Second attempt (one snapshot → resolve from accessible UI).** Take exactly ONE `browser_snapshot` and inspect the returned accessibility tree for the actionable Start Sync control:
   - **Preferred candidates (case-insensitive exact match on accessible name):** `Start Sync`, `Sync Now`, `Enable Sync`, `Run Sync`. Scan the snapshot for a role=`button` whose accessible name matches one of these four labels. Detail page: the button must be outside any `role='dialog'` container. Confirmation dialog: the button must be inside the FIRST `role='dialog'` container in the snapshot.
   - **Fallback candidates (generic — use only as a last resort):** `Start` (accessible name equal to just `Start`), or `Sync` (accessible name equal to just `Sync`). These generic candidates may be used ONLY when the snapshot proves there is exactly one visible actionable candidate in the correct page/dialog context AND none of the preferred candidates matched. If two or more buttons named `Start` (or `Sync`) exist in the correct context, do NOT guess — treat the control as unresolvable and fall through to attempt 3.
   - Use the exact actionable element/reference/locator exposed by the `browser_snapshot` result. Do not invent a CSS selector when the snapshot provides a tool-native element reference. Issue one `browser_click` using that reference.

   Take at most ONE snapshot per control lookup at this attempt. Do not sleep before or after. Do not screenshot. If a preferred or fallback candidate resolves, issue the click and this attempt is complete.

2b. **Bounded hydration re-check (permitted ONLY when the attempt-2 snapshot contains positive evidence of Lightning Setup hydration in progress).** If — and ONLY if — the attempt-2 snapshot shows one of the following in the primary content region that should contain the Start Sync control (detail page for detail-page lookups; inside the first `role='dialog'` container for dialog lookups):
   - a `status` node with accessible name `Loading` (case-insensitive), OR
   - the target content region is present but the entire button list where Start Sync would live is empty / absent while sibling scaffolding (page heading, tabs, breadcrumb) is present — a clearly-still-loading skeleton, not a rendered-but-different UI,

   then this is NOT a "control missing" outcome. Take exactly ONE additional `browser_snapshot` as a hydration re-check. This is the ONLY situation in which a second snapshot is permitted per control lookup. Do not gate this re-check on a timer; do not add `browser_wait_for(time: N)`; do not sleep; the re-check is a single tool call.

   After the hydration re-check snapshot:
   - **If the expected control is now present** (preferred or fallback candidate matches per the attempt-2 rules), issue one `browser_click` using the tool-native actionable reference from THIS second snapshot. The lookup is complete.
   - **If the snapshot still shows the same `Loading` state OR the control is still absent**, fall through to attempt 3 with diagnostics that specifically note "hydration re-check exhausted."

   The hydration re-check is NOT a generic retry. It exists solely to distinguish "Lightning Setup content hasn't hydrated yet" from "Salesforce has removed or renamed the control." Any control lookup that has already resolved via attempt 1 or attempt 2 does NOT get a re-check — only lookups whose attempt-2 snapshot proves the page is still loading.

3. **Third attempt: none.** If attempt 1, attempt 2, and (where triggered) the attempt-2b hydration re-check all fail — control not present in the accessibility tree, or the resolved click still errors — the field FAILS. Record the exact selector attempted at step 1, the accessible-name candidates observed at step 2 (or "none found"), whether the hydration re-check was triggered and its outcome (or "not triggered — snapshot showed no loading indicator"), and the underlying tool error. Move on per the "field failure semantics" rule below.

**Field failure semantics.** A field counts as **successfully initiated** ONLY after the confirmation-dialog Start Sync click (attempt 1 or attempt 2) succeeds without error. If the detail-page click fails on both attempts, OR the dialog click fails on both attempts, the field is FAILED — do NOT record it as initiated.

After ANY field's outcome (success OR failure), continue to the second field when it is safe to do so (see below). Do not abort the loop early on a failure that leaves the browser in a recoverable state.

**Safe-to-continue rule.** Before starting field #2, the browser must be back on the Copy Fields list page. Issue the `browser_navigate` back to the list even if field #1 failed — this resets any half-open detail page or lingering dialog. If field #1's failure left an open dialog that the navigate does not dismiss, log the failure and STOP the loop (do not attempt field #2); Step 5 still closes the browser cleanly.

#### 4.1 — Pacemaker Patient Health Summary (default)

Perform in order:

1. Click the field row:
   ```
   mcp__plugin_playwright_playwright__browser_click(
     target: "text=Pacemaker Patient Health Summary",
     element: "Field row: Pacemaker Patient Health Summary"
   )
   ```
   If this row click itself fails on the first attempt, apply the same one-snapshot fallback: snapshot, resolve the row link/button by its accessible name (`Pacemaker Patient Health Summary` — exact or case-insensitive contains), and issue one `browser_click` on the resolved target. If both attempts fail, this field is FAILED.

2. Click Start Sync on the detail page, following the Start Sync control resolution sequence above.

3. Click Start Sync in the confirmation dialog, following the Start Sync control resolution sequence above.

If all three steps succeed, print: `✅ Pacemaker Patient Health Summary — sync initiated` and record `initiated[0] = true`.

If any step fails, print: `❌ Pacemaker Patient Health Summary — <which step> failed: <exact selector or resolution failure detail>` and record `initiated[0] = false`.

Navigate back to the Copy Fields list before attempting field #2 (see safe-to-continue rule):

```
mcp__plugin_playwright_playwright__browser_navigate(
  url: "{instanceUrl}/lightning/setup/ObjectManager/Contact/Enrichment-CopyFields/view"
)
```

#### 4.2 — Unified Individual prod default

Perform the same three-step sequence as 4.1, substituting the field label:

1. Click the field row:
   ```
   mcp__plugin_playwright_playwright__browser_click(
     target: "text=Unified Individual prod default",
     element: "Field row: Unified Individual prod default"
   )
   ```
   With the one-snapshot row-lookup fallback as in 4.1.

2. Click Start Sync on the detail page — same Start Sync control resolution.

3. Click Start Sync in the confirmation dialog — same Start Sync control resolution.

If all three succeed, print: `✅ Unified Individual prod default — sync initiated` and record `initiated[1] = true`.

If any step fails, print: `❌ Unified Individual prod default — <which step> failed: <detail>` and record `initiated[1] = false`.

After the final confirm click (success OR failure), **skip any "navigate back to list" call** — proceed directly to Step 5 (close browser).

#### Step 4 outcome

After both 4.1 and 4.2 have been attempted (or 4.2 was skipped per the safe-to-continue rule):

- `sum(initiated) == 2` → both fields initiated. Step 5 emits the full-success report. Step "Durable state wrapper — write last" may append `"copy-field-sync"` to `state.completedSkills`.
- `sum(initiated) < 2` → partial (1/2) or failure (0/2). Step 5 emits the partial/failure report per "Failure handling". Step "Durable state wrapper — write last" MUST NOT append `"copy-field-sync"` to `state.completedSkills`; append a warning to `state.warnings` describing the exact selector/UI failure(s) instead.

---

### Step 5 — Close browser and report

Always close the browser cleanly, regardless of whether Step 4 succeeded fully, partially, or failed:

```
mcp__plugin_playwright_playwright__browser_close()
```

Then emit the report based on `sum(initiated)` from Step 4's outcome:

**If `sum(initiated) == 2` (both fields initiated):**

```text
✅ Copy Field Sync Initiated (2 of 2 fields)

Org: <org_alias>
Instance: {instanceUrl}

Sync initiated for:
1. ✅ Pacemaker Patient Health Summary (default)
2. ✅ Unified Individual prod default

Note: This skill only INITIATES the sync. Salesforce processes it in the
background; verification (if desired) can be done later in Setup → Object
Manager → Contact → Data Cloud Copy Field → Sync History. Downstream skills
do not depend on the sync completing.
```

**If `sum(initiated) < 2`** (0/2 or 1/2 initiated): emit the partial/failure report defined in "Failure handling" below instead. Do NOT emit the success report above when even one field failed to reach the confirmed-dialog-click state.

**Return to the parent installer — do NOT chain from inside this skill.** After the report is emitted and the durable-state wrapper at the bottom has written its outcome:

- `sum(initiated) == 2` → return **SUCCESS** to the parent installer.
- `sum(initiated) < 2` → return **PARTIAL/FAILURE** to the parent installer (with the specific 0/2 or 1/2 count recorded in `state.warnings` per the durable-state rules).

The parent installer — NOT this skill — owns chaining. Do NOT invoke `/refresh-data-streams`, do NOT invoke any other Skill via the `Skill` tool, do NOT trigger the installer's final summary, and do NOT auto-proceed to any downstream step from inside `copy-field-sync`. The parent installer reads this skill's return value and decides what to run next (typically `/refresh-data-streams` if the operator opted in, or the installer's own summary otherwise). Handing chaining back to the parent keeps skill boundaries clean, preserves the installer's ability to skip or short-circuit, and prevents a partial run from silently kicking off the next skill.

---

## Failure handling

A field is FAILED if any of its three clicks (row → detail-page Start Sync → confirmation-dialog Start Sync) fails through the full Step 4 resolution sequence:

1. attempt 1 — the hard-coded selector;
2. attempt 2 — ONE fallback `browser_snapshot` + ONE resolved-click on the tool-native reference from that snapshot;
3. optional attempt 2b — ONE additional hydration re-check `browser_snapshot` + ONE resolved-click on its reference, permitted ONLY when the attempt-2 snapshot contains the positive Lightning-Setup-hydrating evidence defined in Step 4 (a `status "Loading"` node or an empty-content-region skeleton in the target region).

If all applicable attempts miss (attempt-2b is skipped when the positive-evidence gate does not fire), the click fails — with no further retries. Continue to the next field where safely possible (per the safe-to-continue rule in Step 4). Always close the browser cleanly in Step 5.

**Report format (0/2 or 1/2 initiated):**

```text
⚠️ Copy Field Sync — <N> of 2 fields initiated

Org: <org_alias>
Instance: {instanceUrl}

Initiated:
  ✅ <field label(s) that reached the confirmation-dialog click>

Failed:
  ❌ <field label> — <which of: row click | detail-page Start Sync click | dialog Start Sync click>
     Hard-coded selector: <exact selector attempted at attempt 1>
     Accessibility-tree resolution: <either the resolved selector that still failed, or "no matching Start Sync control found in snapshot" — plus the list of candidate accessible names observed, if any>
     Underlying tool error: <verbatim error string from the failing browser_click / browser_snapshot call>

Suggested fix: open Setup → Object Manager → Contact → Data Cloud Copy Field
manually, verify the field label matches exactly, and inspect the current
"Start Sync" control's accessible name. Update Step 4's variant list if
Salesforce has renamed the button. Then re-run /copy-field-sync.
```

Do NOT auto-retry within the skill beyond the bounded budget specified in Step 4 — the total retry budget per control lookup is: attempt 1 (hard-coded selector), attempt 2 (one fallback snapshot + resolved click), and — only on positive Lightning-Setup-hydrating evidence — attempt 2b (one hydration re-check snapshot + resolved click). After those, fail with diagnostics. Do NOT re-issue the same selector, do NOT loop attempts, and do NOT snapshot a third time.

**Durable state on 0/2 or 1/2:** the durable-state wrapper at the bottom of this skill MUST NOT append `"copy-field-sync"` to `state.completedSkills`. Instead, append a warning to `state.warnings` capturing which field(s) failed and at which click, so the next installer run treats this skill as re-runnable and the summary report shows the gap honestly.

---

## What this skill INTENTIONALLY does NOT do

- ❌ **Does not check Sync History** — this was the original 30-minute time waster. Salesforce processes the sync in the background; the skill doesn't need to babysit it.
- ❌ **Does not poll for "Complete" / "Success" status** — same reason.
- ❌ **Does not screenshot** — screenshots add ~1s each and provide no information the agent uses.
- ❌ **Does not `wait_for(time: N)` between actions** — Playwright auto-waits for elements to be actionable. Explicit time-based waits are anti-patterns.
- ❌ **Does not navigate back to the list after the FINAL sync click** — the next call is `browser_close`; the navigate would just be wasted. (Between fields, one navigate back to the list is required so the next field row is clickable.)

No downstream installer skill depends on copy-field syncs being complete. `/refresh-data-cloud-components` runs BEFORE this skill in the installer chain and operates against IR/CIs/Segments, not the copy fields. The only skill that can run after `/copy-field-sync` is `/refresh-data-streams` (opt-in only), which also does not depend on copy-field sync state. The Customer Affinities related list — formerly a downstream concern — is created much earlier at Step 8 (`/data-cloud-related-list`). So fire-and-forget remains correct here.

---

## Important Rules

- 🚨 **ALWAYS run BOTH copy field syncs** (Pacemaker Patient Health Summary + Unified Individual prod default) — do not skip either
- 🚨 **NEVER check Sync History** — this is the rule that keeps the wall-clock tight
- 🚨 **NEVER add `wait_for(time: N)`** between Playwright actions — auto-wait handles it
- 🚨 **NEVER take screenshots on success paths** — only on failure for debugging
- ✅ Use direct URL navigation (no Object Manager search clicks)
- ✅ Return SUCCESS to the parent installer on 2/2 initiated; return PARTIAL/FAILURE on 0/2 or 1/2. The parent installer owns chaining — this skill NEVER invokes `/refresh-data-streams`, another Skill, or the final summary itself.

---

## Cleanup temp artifacts (MANDATORY before next skill)

```bash
cmd.exe //c "rmdir /S /Q .playwright-mcp" 2>/dev/null || rm -rf .playwright-mcp
```

Verify:

```bash
ls -d .playwright-mcp 2>&1 | grep -v "cannot access"
```

**Failure handling rule:** if any sync failed (selector mismatch, dialog stuck), do NOT clean up — leave `.playwright-mcp/` traces so the user can inspect them. Cleanup only fires on full success (2 of 2 syncs initiated).

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"copy-field-sync"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.copy-field-sync` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Copy-field-sync specific rule:** the intended outcome is `sum(initiated) == 2` from Step 4 — BOTH fields reached the confirmation-dialog Start Sync click successfully. 0/2 or 1/2 initiated is a partial and MUST NOT set `copy-field-sync` complete. Append the exact selector/UI failure(s) (which field, which click, which selectors, the underlying tool error) to `state.warnings` so the next re-run and the final summary can surface the gap.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
