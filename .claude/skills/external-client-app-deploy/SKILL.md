---
name: external-client-app-deploy
description: Deploy the Salesforce External Client App that backs the Data360 MCP server. Deploys 5 ECA metadata components from ps-eca/ in strict dependency order (ExternalClientApplication → ExtlClntAppOauthSettings → ExtlClntAppGlobalOauthSettings → ExtlClntAppConfigurablePolicies → ExtlClntAppOauthConfigurablePolicies) via Salesforce CLI. The 5th component enables the client_credentials OAuth flow and binds a Run-As user (auto-discovered from `sf org display`) — without it, /mcp-setup's OAuth probe fails with `no client credentials user enabled`. Verifies the app via Tooling API SOQL after deploy. CLI-only, no browser automation. Use when the user wants to deploy the External Client App, set up the MCP-backing app, or prepare the org for `claude mcp add data360`.
---

# external-client-app-deploy

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"external-client-app-deploy"` is already in `state.completedSkills`** — the state file *claims* this skill has already run successfully. The state file is authoritative for cross-skill orchestration, but Salesforce org state is authoritative for whether the ECA is actually installed (metadata may have been deleted, an org may have been reprovisioned, or the state file may have been copied from another org). Do NOT return success solely from the state file. Instead, perform a **lightweight org-side verification** of the critical ECA postconditions before returning:

   - Component 1 exists: Tooling API SOQL `SELECT Id FROM ExternalClientApplication WHERE DeveloperName='Salesforce_DC_Prod_Org' LIMIT 1` returns exactly one row.
   - Component 3's Global OAuth Settings has `isClientCredentialsFlowEnabled = true` AND `isCodeCredFlowEnabled = true` in the org.
   - Component 5's `ExtlClntAppOauthConfigurablePolicies` row exists with `DeveloperName = 'Salesforce_DC_Prod_Org_oauthPlcy'` AND its `clientCredentialsFlowUser` matches the currently-authenticated org user (proves the Run-As binding is live in the target org, not just in the state file).

   Each of the three checks MUST produce **positive evidence** — a successful SOQL query that returns the specific expected row/flag/value. Success requires the concrete match; a Tooling API error, unparseable response, missing sObject type, or any non-positive result MUST be treated as "verification failed" (drift), NOT as "verification passed". Absence of a negative result is not evidence.

   If **all three** verifications produce positive evidence, log `VERIFIED NO-OP: external-client-app-deploy already complete and reconciled against org` and return success. Do NOT re-execute the workflow.

   If **any** verification does NOT produce positive evidence — the row is missing, a flag is off, the Run-As user does not match, OR the verification query itself failed / returned an unqueryable-sObject error / returned unparseable JSON — log `DRIFT DETECTED against state file — org missing <specific-postcondition> (or verification inconclusive: <error>); re-running workflow` and fall through into the full workflow below. The workflow's per-component `component_exists_in_org` probe (Step 2) is idempotent — it will skip components that ARE present and re-deploy only what's missing. Its post-deploy verification (Step 2f) also gates strictly on `EXISTS`; `UNKNOWN` or any other sentinel there is a hard failure, not a success.

   This rule preserves the "Salesforce org state wins over stale durable state" invariant. `completedSkills` cannot bypass org verification, and an inconclusive verification never grants success.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Deploy the five External Client App (ECA) metadata components that back the Data360 MCP server. The components live in `ps-eca/main/default/` and have a strict dependency chain — they MUST be deployed one at a time in this order:

```
1. ExternalClientApplication            — the app shell
2. ExtlClntAppOauthSettings             — OAuth scopes / callback URL (depends on #1)
3. ExtlClntAppGlobalOauthSettings       — global OAuth policy incl. isClientCredentialsFlowEnabled=true (depends on #1, #2)
4. ExtlClntAppConfigurablePolicies      — IP / session / refresh policies (depends on #1, #2, #3)
5. ExtlClntAppOauthConfigurablePolicies — enables the client_credentials flow + binds a Run-As user
                                           (depends on #1, #2, #3, #4)
```

**Why 5, not 4:** `/mcp-setup` registers TWO MCPs (`data360` + `salesforce-sobject-all`), and each requires a different OAuth flow to be enabled on the ECA:

1. **`isClientCredentialsFlowEnabled: true`** on the Global OAuth Settings (component 3) — required for the `data360` MCP's headless `client_credentials` OAuth flow. Shipped `true` in the XML.
2. **`isCodeCredFlowEnabled: true`** on the Global OAuth Settings (component 3) — required for the `salesforce-sobject-all` MCP's browser OAuth authorization-code + PKCE flow. Shipped `true` in the XML. Without this flag, `salesforce-sobject-all` will register in `.claude/settings.local.json` but show as **inactive in the org** — Salesforce refuses the auth-code handshake on the first tool call.
3. **A `clientCredentialsFlowUser` binding** on `ExtlClntAppOauthConfigurablePolicies` (component 5) — the Run-As user under whose identity `client_credentials` grants execute. Without this, `/mcp-setup`'s Step 5 OAuth probe fails with **`no client credentials user enabled`** on every fresh org. The Run-As user is per-org, so the skill writes the value dynamically at deploy time by looking up `sf org display --json`'s `username` for the target alias — the XML on disk is a template with a placeholder that gets rewritten before component 5 deploys.

This skill is a hard prerequisite for `/mcp-setup` — the Consumer Key and Consumer Secret that `/mcp-setup` registers are auto-generated by Salesforce only AFTER this skill's deploys complete.

**Critical Constraints:**
- ✅ Salesforce CLI only (`sf project deploy start`)
- ✅ One CLI call per component — strict sequential ordering
- ✅ Stop immediately on first failing component (do NOT deploy later components in the chain)
- ✅ Verify ExternalClientApplication exists in the org via Tooling API SOQL after all 5 deploys succeed
- ✅ `clientCredentialsFlowUser` is dynamically rewritten from `sf org display` — never hardcoded
- ❌ No browser automation
- ❌ No manual UI clicks — the Run-As user MUST NOT be set by hand in Setup (defeats reproducibility)
- ❌ No bulk `--source-dir ps-eca` deploy (would deploy in unpredictable order — platform rejects out-of-order ECA deploys)
- ❌ No retry on failure — surface the deploy error to the user and stop

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username

---

## Preconditions

- `/base-metadata-deploy` has run successfully (ps-base must be deployed before the ECA references it)
- `sfdx-project.json` includes `ps-eca` as a `packageDirectory`
- `ps-eca/main/default/` contains all 5 ECA source files, one component each:
  - `externalClientApps/Salesforce_DC_Prod_Org.eca-meta.xml`
  - `extlClntAppOauthSettings/Salesforce_DC_Prod_Org_oauth.ecaOauth-meta.xml` MUST have `<commaSeparatedOauthScopes>` include **all four** of `RefreshToken, MCP, Api, CDP` (the Data 360 REST API — `/ssot/data-kits`, `/ssot/dataspaces`, `/ssot/data-streams`, etc. — requires the `CDP` scope; without it, `d360_datakit_*` calls return `401 INVALID_SCOPES / INVALID_AUTH_HEADER` even though the OAuth token is otherwise valid). Do NOT add every CDP sub-scope (CDPQuery, CDPIngest, CDPProfile, CDPSegment, CDPCalculatedInsight, CDPIdentityResolution) — Salesforce rejects the token endpoint with `too many scopes requested`. The single umbrella `CDP` scope covers all Data 360 operations the MCP performs.
  - `extlClntAppGlobalOauthSets/Salesforce_DC_Prod_Org_glbloauth.ecaGlblOauth-meta.xml` MUST have BOTH:
    - `<isClientCredentialsFlowEnabled>true</isClientCredentialsFlowEnabled>` — enables the headless `data360` MCP registration
    - `<isCodeCredFlowEnabled>true</isCodeCredFlowEnabled>` — enables the browser-OAuth `salesforce-sobject-all` MCP registration. Without this flag the MCP shows as **inactive** in the org even after `/mcp-setup` writes it to `.claude/settings.local.json`, because Salesforce refuses the auth-code handshake on the first tool call.
  - `extlClntAppPolicies/Salesforce_DC_Prod_Org_plcy.ecaPlcy-meta.xml`
  - `extlClntAppOauthPolicies/Salesforce_DC_Prod_Org_oauthPlcy.ecaOauthPlcy-meta.xml` (the `<clientCredentialsFlowUser>` element MUST be present, either populated or as a placeholder — Step 1a rewrites it before deploy)
- Authenticated `sf` session for `<org_alias>` (System Administrator perms)
- Org has External Client App framework enabled (default in modern Salesforce orgs)
- The user backing the `sf` session (target-org username) MUST be an active, licensed user — that same user will be assigned as the ECA's `client_credentials` Run-As user in Step 1a

---

## Deployment execution invariants (READ BEFORE THE WORKFLOW)

These invariants apply to every `sf` invocation in this skill. Violating any one of them has, historically, caused stalls of many minutes with no visible progress, or duplicate ECA deployments in the target org.

### Authority order

1. **Salesforce `DeployRequest` (Tooling API) is authoritative** for whether a metadata deployment is running, succeeded, failed, or canceled.
2. **Salesforce `deploy report --job-id <id>`** on a specific submitted Deploy Id is authoritative for that individual deployment.
3. **Local Claude background-task state is informational only.** The following signals are NOT proof that a Salesforce deployment is running, has completed, or has failed:
   - a Claude background-task ID being reported as "still running"
   - a 0-byte task output file
   - the presence of a `node.exe` or `sf` process in the process list
   - a bash timeout that moved a command to the background
   - the absence of a task-completion notification within any time window

### Hard invariants

- **INV-1 (queue gate):** NO ECA deploy start may execute while ANY relevant Salesforce `DeployRequest` is in a non-terminal state. Non-terminal = not one of `Succeeded`, `Failed`, `Canceled`, `SucceededPartial`. Every other Salesforce-returned state — `Pending`, `Queued`, `InProgress`, `Canceling`, and anything else — is treated as active.
- **INV-2 (no long `--wait`):** No `sf project deploy start` in this skill may use `--wait 10`, `--wait 30`, or any other `--wait N` value. Every deploy is submitted with `--async --json` and polled via `deploy report`. The old `--wait 10` foreground pattern is FORBIDDEN — it triggers Claude's Bash 2-minute timeout and backgrounds the CLI, leaving 0-byte output files that mask real deployment state and cause duplicate submits.
- **INV-3 (local state is not proof):** Never trigger a second `deploy start` for the same component because a local Claude background task hasn't emitted a notification, because a process is still visible, or because an output file is 0 bytes. Always reconcile against Salesforce first.
- **INV-4 (one at a time):** Never permit two ECA-component deployments to be non-terminal at the same time.
- **INV-5 (poll with a finite ceiling):** Every wait — the pre-flight queue gate AND each component's `deploy report` polling loop — has a finite ceiling (30 minutes wall clock). On ceiling breach the skill hard-fails and reports the active Deploy Id + last observed status. It does not silently wait longer.
- **INV-6 (progress cannot go silent):** The skill emits a visible progress line on EVERY successful poll — the queue gate on each Tooling API round, and `poll_deploy_to_terminal` on each `deploy report` round — regardless of whether the observed status changed. An `InProgress` status that persists for minutes MUST still produce one line per poll interval. Silence for longer than one poll interval is a bug. Progress lines go to stderr so the caller's `final_status=$(poll_deploy_to_terminal ...)` capture stays pristine.
- **INV-ORG-ONCE (target org resolved exactly once):** `$ORG` is resolved exactly once, at the very top of the skill (from the `--org_alias` argument or from `state.orgAlias` in the durable state file), before the CLI resolver runs. It MUST NOT be re-assigned anywhere later in the skill — no subsequent step, helper, or workflow block may contain a fresh `ORG=...` assignment. Every subsequent command uses the already-resolved `$ORG` as-is.
- **INV-SF-ONCE (CLI resolved exactly once):** `$SF` is resolved exactly once by the Windows CLI resolver — after `$ORG` is available and via a real `org display --target-org "$ORG" --json` validation, never via `--version` alone. Once selected, `$SF` MUST NOT be re-assigned. Every subsequent CLI invocation in the skill is written as `"$SF" ...`.
- **INV-USER-ID (verified Salesforce User.Id for correlation):** Any correlation against `DeployRequest.CreatedById` MUST use a Salesforce **User.Id** (prefix `005`) obtained via a real SOQL lookup — `SELECT Id FROM User WHERE Username = '<authenticatedUsername>' LIMIT 1` — where the authenticated username itself comes from `"$SF" org display --target-org "$ORG" --json`'s `result.username`. `sf org display`'s top-level `result.id` is an **Org Id** (prefix `00D`) and MUST NOT be substituted for a User.Id. If a User.Id cannot be verified (query fails, returns no rows, or returns a non-`005` Id), the ambiguous-submit reconciliation falls back to a strict-timestamp-only window and treats any multi-row result as `AMBIGUOUS` — it never blindly resubmits and never picks arbitrarily.
- **INV-VERIFY-POSITIVE (verification requires positive evidence):** Every claim by this skill that a component, flag, or binding is "verified in the org" MUST be backed by a successful Tooling API / SOQL response that returns the specific expected row/value/flag. The absence of a negative result is not evidence. Concretely, the `component_exists_in_org` helper returns one of `EXISTS`, `MISSING`, or `UNKNOWN` — only the literal string `EXISTS` may be interpreted as successful verification. `MISSING`, `UNKNOWN`, and any unexpected sentinel are hard failures at every call site that claims verification success (post-deploy verify in Step 2f, and the durable-state wrapper's VERIFIED NO-OP path). An unqueryable sObject, Tooling API error, or JSON parse error MUST NOT be treated as verified.

### Salesforce deployment states this skill recognizes

Terminal (queue is clear, safe to proceed): `Succeeded`, `Failed`, `Canceled`, `SucceededPartial`.

Non-terminal (block the queue): `Pending`, `Queued`, `InProgress`, `Canceling`, plus any state string returned by Salesforce that is not in the terminal set. When in doubt, treat unknown states as non-terminal.

---

## Windows CLI handling (resolve ONCE, with a real command)

Some Windows shells (Git Bash / MSYS on machines with `sf` under `C:\Program Files\sf\...`) refuse to execute the path-with-space wrapper reliably. The failure has two observed modes:

```
'C:\Program' is not recognized as an internal or external command
```

**Both modes have been observed on the same machine where `sf --version` succeeds.** `--version` does not shell out through the same code path that real subcommands take, so it can pass while `sf data query`, `sf org display`, and `sf project deploy start` all fail. Any resolver that gates candidacy on `--version` alone is therefore insufficient — a bare `sf` that passes `--version` can (and in the observed environment did) still break every actual Salesforce API call this skill makes.

To eliminate that failure mode, the resolver validates each candidate by running a **real Salesforce command against the target org** and requires the response to be parseable, successful JSON. If that check fails, the candidate is rejected and the next one is tried. Once a candidate passes, its command is stored in `$SF` and used unchanged for the rest of the skill.

```bash
# ── Step −1: Resolve the target org alias BEFORE resolving the CLI ────────────
#
# The CLI resolver validates candidates by running `org display --target-org $ORG`
# — so $ORG must be known before the resolver starts. Take it from the skill's
# --org_alias argument if provided, else from the durable state file's orgAlias,
# else hard-fail with a specific message. Do NOT default to a hardcoded alias.
if [ -z "$ORG" ]; then
    if [ -f ".claude/state/install-state.json" ]; then
        ORG=$(python3 -c "
import json
try:
    d = json.load(open('.claude/state/install-state.json', encoding='utf-8'))
except Exception:
    print('')
else:
    print(d.get('orgAlias') or '')
")
    fi
fi
if [ -z "$ORG" ]; then
    echo "❌ CLI resolver cannot start — no target org alias available."
    echo "   Pass one as --org_alias, or run this skill via the installer so it inherits state.orgAlias."
    exit 1
fi
echo "▸ CLI resolver: target org alias = $ORG"

# ── Step 0: Validate a single CLI candidate with a REAL Salesforce command ────
#
# Runs `<candidate> org display --target-org $ORG --json`. A candidate is valid
# only if:
#   1. The subprocess exits 0.
#   2. Its stdout, after stripping any CLI-update warning banner before the
#      first '{', parses as JSON.
#   3. The parsed JSON has status == 0 AND result.username / result.instanceUrl
#      populated (i.e. Salesforce actually answered for this org).
#
# `--version` is NOT sufficient — it does not shell through the same argv path
# that `data query` / `project deploy start` use, so it can succeed while every
# real command fails with the Windows "'C:\Program' is not recognized" error.
validate_sf_candidate() {
    local cand="$1"
    local resp rc
    resp=$("$cand" org display --target-org "$ORG" --json 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    printf '%s' "$resp" | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    sys.exit(2)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(2)
if d.get('status') not in (None, 0):
    sys.exit(2)
r = d.get('result') or {}
if not (r.get('username') and r.get('instanceUrl')):
    sys.exit(2)
sys.exit(0)
" >/dev/null 2>&1
}

# ── Step 1: Build the ordered candidate list ─────────────────────────────────
#
# Preference order (highest → lowest):
#   1. `sf` on PATH — the portable, POSIX-first option.
#   2. Any `sf` wrapper on PATH resolved via `command -v` — catches machines that
#      symlink `sf` to a working path other than PATH-lookup order.
#   3. A DYNAMICALLY-DISCOVERED Windows short-path form of the installed sf.cmd.
#      Discovery uses `cmd //c "for %A in (...) do @echo %~sA"` to convert the
#      known Windows install path into its 8.3 alias. If cmd is not available
#      (POSIX host) or the file does not exist, this candidate is skipped
#      silently. Nothing about `PROGRA~1` is hardcoded — the short path comes
#      from the OS at resolve time.
#   4. `sf.cmd` on PATH — some Windows installers expose the `.cmd` wrapper
#      only under this exact name.
#
# NEVER hardcode a specific user's or machine's filesystem path.
CANDIDATES=()

if command -v sf >/dev/null 2>&1; then
    CANDIDATES+=("sf")
    _resolved=$(command -v sf 2>/dev/null || true)
    if [ -n "$_resolved" ] && [ "$_resolved" != "sf" ]; then
        CANDIDATES+=("$_resolved")
    fi
fi

# Discover a Windows short-path form dynamically (do not assume PROGRA~1).
if command -v cmd >/dev/null 2>&1; then
    for _long in \
        "C:\\Program Files\\sf\\bin\\sf.cmd" \
        "C:\\Program Files\\Salesforce CLI\\bin\\sf.cmd" \
        "C:\\Program Files (x86)\\sf\\bin\\sf.cmd" \
        "C:\\Program Files (x86)\\Salesforce CLI\\bin\\sf.cmd"; do
        _short=$(cmd //c "for %A in (\"$_long\") do @echo %~sA" 2>/dev/null | tr -d '\r' | head -n1)
        if [ -n "$_short" ] && [ "$_short" != "$_long" ]; then
            # Convert the Windows-style 8.3 path to a Git-Bash friendly form.
            _short_bash=$(printf '%s' "$_short" | sed -E 's|^([A-Za-z]):\\|/\L\1/|; s|\\|/|g')
            if [ -x "$_short_bash" ]; then
                CANDIDATES+=("$_short_bash")
            fi
        fi
    done
fi

if command -v sf.cmd >/dev/null 2>&1; then
    _cmd_resolved=$(command -v sf.cmd 2>/dev/null || true)
    [ -n "$_cmd_resolved" ] && CANDIDATES+=("$_cmd_resolved")
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    echo "❌ No Salesforce CLI candidates were discovered on PATH or in the standard Windows install locations."
    echo "   Install the Salesforce CLI or add it to PATH before re-running this skill."
    exit 1
fi

# ── Step 2: Pick the first candidate that a REAL Salesforce command validates ─
SF=""
for _cand in "${CANDIDATES[@]}"; do
    echo "▸ CLI resolver: testing candidate '$_cand' against org '$ORG' with a real 'org display' call"
    if validate_sf_candidate "$_cand"; then
        SF="$_cand"
        echo "✅ CLI resolver: selected '$SF' — real 'org display' returned parseable successful JSON"
        break
    else
        echo "▸ CLI resolver: candidate '$_cand' failed the real-command validation — trying next"
    fi
done

if [ -z "$SF" ]; then
    echo "❌ CLI resolver: no candidate produced a working 'org display --target-org $ORG --json'."
    echo "   Tried: ${CANDIDATES[*]}"
    echo "   Verify the org alias is authenticated (\`sf org login web --alias $ORG\`) and that your PATH points at a working Salesforce CLI install."
    exit 1
fi
```

**Key properties of this resolver:**

- **`sf --version` alone can never select the CLI.** Candidacy is gated on a real `org display --target-org $ORG --json` call whose response must parse as successful JSON. The bare-`sf`-passes-`--version`-but-fails-`data-query` regression that motivated this correction is structurally impossible.
- **No hardcoded machine paths.** The Windows short-path candidate is derived at resolve time from `cmd //c "for %A in (...) do @echo %~sA"`. Neither `PROGRA~1` nor any specific user's directory is committed anywhere in this file — the resolver asks the OS for the current short-path alias of the known install location, and skips silently if that alias does not exist on the host.
- **Portable preference order preserved.** Bare `sf` remains the first candidate; the Windows-specific fallback runs only when it doesn't validate.
- **Single-command consistency.** Every subsequent `sf ...` invocation in the workflow is written as `"$SF" ...`. There is no branch anywhere in the skill that switches between forms mid-run.

---

## Reusable helpers used by the workflow

Both helpers below are defined at the top of the workflow and used by both the pre-flight queue gate (Step 1c) and by every per-component deploy (Step 2).

```bash
# --- Helper A: wait_for_no_active_deploys ------------------------------------
# Poll Salesforce's Tooling API for recent DeployRequest rows and block until
# none of them are in a non-terminal state. Emits one progress line per poll,
# hard-fails after WAIT_CEILING_S seconds.
#
# Uses only Salesforce state — never inspects local files or Claude tasks.
# The set of non-terminal states is deliberately broad: anything Salesforce
# returns that is not one of the four terminal states counts as active.
POLL_INTERVAL_S=20              # 15–30 s per spec
WAIT_CEILING_S=$((30 * 60))     # 30 min hard ceiling for a genuinely active Salesforce deploy
MAX_CONSECUTIVE_QUERY_FAILURES=3  # fail-fast on broken query/parser (INV-5 must not shield a broken pipe)

wait_for_no_active_deploys() {
    local label="${1:-pre-flight queue gate}"
    local start_ts=$(date +%s 2>/dev/null || echo 0)
    local last_summary=""
    local consecutive_failures=0
    while :; do
        local now_ts=$(date +%s 2>/dev/null || echo 0)
        if [ "$start_ts" != "0" ] && [ "$now_ts" != "0" ] && [ $((now_ts - start_ts)) -gt "$WAIT_CEILING_S" ]; then
            echo "❌ [$label] Timed out after ${WAIT_CEILING_S}s waiting for existing Salesforce deployments to finish." >&2
            "$SF" data query --target-org "$ORG" --use-tooling-api \
                --query "SELECT Id, Status, StartDate, NumberComponentsDeployed, NumberComponentErrors FROM DeployRequest WHERE Status NOT IN ('Succeeded','Failed','Canceled','SucceededPartial') ORDER BY CreatedDate DESC" \
                --json >&2 || true
            exit 1
        fi

        # Ask Salesforce directly for non-terminal DeployRequests — no LIMIT, no
        # client-side filtering, no reliance on "top N most recent". This is the
        # authoritative queue-clear signal. Any row Salesforce returns from this
        # query is by definition active.
        local resp
        resp=$("$SF" data query --target-org "$ORG" --use-tooling-api \
            --query "SELECT Id, Status FROM DeployRequest WHERE Status NOT IN ('Succeeded','Failed','Canceled','SucceededPartial') ORDER BY CreatedDate DESC" \
            --json 2>&1)

        local active
        active=$(printf '%s' "$resp" | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    print('QUERY_ERROR')
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    print('QUERY_ERROR')
    sys.exit(0)
# Tooling API errors either come back as top-level list, or as an object with status != 0.
if isinstance(d, list) or (d.get('status') not in (None, 0)):
    print('QUERY_ERROR')
    sys.exit(0)
recs = (d.get('result') or {}).get('records') or []
if not recs:
    print('CLEAR')
else:
    print(';'.join(f\"{r.get('Id','?')}:{r.get('Status','?')}\" for r in recs))
")

        if [ "$active" = "CLEAR" ]; then
            echo "✅ [$label] Salesforce deployment queue clear — safe to proceed" >&2
            return 0
        fi
        if [ "$active" = "QUERY_ERROR" ]; then
            consecutive_failures=$((consecutive_failures + 1))
            echo "▸ [$label] Tooling API query failed (attempt $consecutive_failures/$MAX_CONSECUTIVE_QUERY_FAILURES)" >&2
            if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_QUERY_FAILURES" ]; then
                echo "❌ [$label] $MAX_CONSECUTIVE_QUERY_FAILURES consecutive Tooling API query failures — refusing to wait further." >&2
                echo "   Last CLI response body:" >&2
                printf '%s\n' "$resp" >&2
                exit 1
            fi
            sleep "$POLL_INTERVAL_S"
            continue
        fi
        consecutive_failures=0

        if [ "$active" != "$last_summary" ]; then
            echo "▸ [$label] Waiting for active Salesforce deployments: $active" >&2
            last_summary="$active"
        else
            echo "▸ [$label] Still waiting (unchanged): $active" >&2
        fi
        sleep "$POLL_INTERVAL_S"
    done
}

# --- Helper B: poll_deploy_to_terminal ---------------------------------------
# Poll a specific Deploy Id until it reaches a terminal state.
#
# stdout contract (called via $(...) — MUST stay pristine):
#   Emits EXACTLY ONE line to stdout, exactly one of:
#     Succeeded | Failed | Canceled | SucceededPartial | TIMEOUT | ERROR
#
# stderr:
#   Emits EXACTLY ONE concise progress line to stderr per successful poll
#   (INV-6) — never conditional on status change. Format:
#     ▸ [<label>] <deployId>: <Status> — deployed=<N> errors=<M>
#   with a "failures=[...]" suffix if the poll surfaced componentFailures.
#   Parse-error attempts and hard-fail dumps also go to stderr. This channel
#   is not captured by the caller, so it never contaminates the sentinel.
#
# Fail-fast:
#   Consecutive Tooling API / parse failures fail fast after
#   MAX_CONSECUTIVE_QUERY_FAILURES attempts — the 30-minute ceiling is for a
#   genuinely InProgress deploy, not a broken CLI or JSON parser.
poll_deploy_to_terminal() {
    local deploy_id="$1"
    local label="$2"
    local start_ts=$(date +%s 2>/dev/null || echo 0)
    local consecutive_failures=0
    while :; do
        local now_ts=$(date +%s 2>/dev/null || echo 0)
        if [ "$start_ts" != "0" ] && [ "$now_ts" != "0" ] && [ $((now_ts - start_ts)) -gt "$WAIT_CEILING_S" ]; then
            echo "❌ [$label] Deploy $deploy_id did not reach a terminal state within ${WAIT_CEILING_S}s" >&2
            echo "TIMEOUT"
            return 1
        fi

        local resp
        resp=$("$SF" project deploy report --job-id "$deploy_id" --target-org "$ORG" --json 2>&1)
        local parsed
        parsed=$(printf '%s' "$resp" | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    print('PARSE_ERROR|no-json-in-response')
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception as e:
    print(f'PARSE_ERROR|{type(e).__name__}')
    sys.exit(0)
# CLI-level error path: top-level status != 0 (e.g. auth expired, bad --job-id)
if d.get('status') not in (None, 0):
    print(f\"PARSE_ERROR|cli-status={d.get('status')}:{d.get('name','')}:{d.get('message','')[:120]}\")
    sys.exit(0)
r = d.get('result') or {}
status = r.get('status') or 'Unknown'
done   = r.get('done')
dep    = r.get('numberComponentsDeployed', 0)
err    = r.get('numberComponentErrors', 0)
fails = []
for f in (r.get('details',{}).get('componentFailures') or [])[:5]:
    fails.append(f\"{f.get('fullName','?')}={f.get('problem','?')}\")
# Machine-readable line consumed by the shell: status|deployed|errors|done|failures
print(f\"{status}|{dep}|{err}|{done}|{';'.join(fails)}\")
")
        local status="${parsed%%|*}"

        if [ "$status" = "PARSE_ERROR" ]; then
            consecutive_failures=$((consecutive_failures + 1))
            echo "▸ [$label] $deploy_id: deploy report parse failed ($parsed) — attempt $consecutive_failures/$MAX_CONSECUTIVE_QUERY_FAILURES" >&2
            if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_QUERY_FAILURES" ]; then
                echo "❌ [$label] $MAX_CONSECUTIVE_QUERY_FAILURES consecutive deploy-report failures on $deploy_id — refusing to wait further." >&2
                echo "   Last CLI response body:" >&2
                printf '%s\n' "$resp" >&2
                echo "ERROR"
                return 1
            fi
            sleep "$POLL_INTERVAL_S"
            continue
        fi
        consecutive_failures=0

        # Parse the pipe-separated payload: <status>|<deployed>|<errors>|<done>|<failures>
        local _rest="${parsed#*|}"
        local dep_count="${_rest%%|*}"; _rest="${_rest#*|}"
        local err_count="${_rest%%|*}"; _rest="${_rest#*|}"
        local done_flag="${_rest%%|*}"; _rest="${_rest#*|}"
        local fail_summary="$_rest"

        # INV-6: EVERY successful poll emits ONE concise progress line to stderr —
        # not just state changes. A long InProgress phase must never make the
        # skill appear frozen. stdout stays pristine for the terminal sentinel.
        if [ -n "$fail_summary" ]; then
            echo "▸ [$label] $deploy_id: $status — deployed=$dep_count errors=$err_count failures=[$fail_summary]" >&2
        else
            echo "▸ [$label] $deploy_id: $status — deployed=$dep_count errors=$err_count" >&2
        fi

        case "$status" in
            Succeeded|Failed|Canceled|SucceededPartial)
                echo "$status"
                return 0
                ;;
        esac
        sleep "$POLL_INTERVAL_S"
    done
}
```

Both helpers rely **only** on `"$SF" data query --use-tooling-api` and `"$SF" project deploy report` — Salesforce state. Neither reads local task files, checks process presence, or waits for Claude background notifications. INV-1, INV-3, INV-5, and INV-6 are enforced structurally by these helpers.

---

## Workflow

### Step 0 — Verify ps-eca is registered as a packageDirectory

```bash
python3 -c "
import json
cfg = json.load(open('sfdx-project.json'))
paths = [d['path'] for d in cfg.get('packageDirectories', [])]
assert 'ps-eca' in paths, 'ps-eca is NOT registered in sfdx-project.json packageDirectories — add it before running this skill'
print('✅ ps-eca registered as packageDirectory')
"
```

If the assert fails, STOP and instruct the user to add `{\"path\": \"ps-eca\", \"default\": false}` to `sfdx-project.json` under `packageDirectories`.

---

### Step 1 — Verify all 5 ECA source files exist on disk

```bash
test -f ps-eca/main/default/externalClientApps/Salesforce_DC_Prod_Org.eca-meta.xml                              || { echo "❌ Missing: ExternalClientApplication source"; exit 1; }
test -f ps-eca/main/default/extlClntAppOauthSettings/Salesforce_DC_Prod_Org_oauth.ecaOauth-meta.xml             || { echo "❌ Missing: ExtlClntAppOauthSettings source"; exit 1; }
test -f ps-eca/main/default/extlClntAppGlobalOauthSets/Salesforce_DC_Prod_Org_glbloauth.ecaGlblOauth-meta.xml   || { echo "❌ Missing: ExtlClntAppGlobalOauthSettings source"; exit 1; }
test -f ps-eca/main/default/extlClntAppPolicies/Salesforce_DC_Prod_Org_plcy.ecaPlcy-meta.xml                    || { echo "❌ Missing: ExtlClntAppConfigurablePolicies source"; exit 1; }
test -f ps-eca/main/default/extlClntAppOauthPolicies/Salesforce_DC_Prod_Org_oauthPlcy.ecaOauthPlcy-meta.xml     || { echo "❌ Missing: ExtlClntAppOauthConfigurablePolicies source (5th component — Run-As user binding)"; exit 1; }

# Also verify component 3 has BOTH OAuth flows enabled — /mcp-setup registers two MCPs:
#   - data360               requires isClientCredentialsFlowEnabled=true  (headless OAuth client_credentials)
#   - salesforce-sobject-all requires isCodeCredFlowEnabled=true          (browser auth-code + PKCE flow)
# If either flag is false, that MCP shows as "inactive" in the org even after registration in Claude Code.
GLOB_XML="ps-eca/main/default/extlClntAppGlobalOauthSets/Salesforce_DC_Prod_Org_glbloauth.ecaGlblOauth-meta.xml"

grep -q "<isClientCredentialsFlowEnabled>true</isClientCredentialsFlowEnabled>" "$GLOB_XML" \
    || { echo "❌ $GLOB_XML must have <isClientCredentialsFlowEnabled>true</isClientCredentialsFlowEnabled> (needed by data360 MCP)"; exit 1; }

grep -q "<isCodeCredFlowEnabled>true</isCodeCredFlowEnabled>" "$GLOB_XML" \
    || { echo "❌ $GLOB_XML must have <isCodeCredFlowEnabled>true</isCodeCredFlowEnabled> (needed by salesforce-sobject-all MCP — browser OAuth auth-code flow)"; exit 1; }

echo "✅ All 5 ECA source files present; component 3 has BOTH client_credentials AND auth-code flows enabled"
```

---

### Step 1a — Auto-discover the Run-As user and rewrite component 5's XML

**Why this step exists:** The `<clientCredentialsFlowUser>` element on `ExtlClntAppOauthConfigurablePolicies` binds the ECA to a specific username at deploy time. Salesforce accepts this element in metadata, but it MUST reference a real, active user in the target org — hardcoding a fixed value works for one org and breaks for every other org. This step reads the target org's authenticated username via `sf org display --json`, then rewrites the `<clientCredentialsFlowUser>...</clientCredentialsFlowUser>` line in the source XML before component 5 deploys.

```bash
# $ORG was resolved exactly once by the CLI resolver at the top of the skill
# (from --org_alias or state.orgAlias) and MUST NOT be re-assigned here.
# See invariant INV-ORG-ONCE in the Windows CLI handling section.

# Discover the target org's authenticated username. Uses "$SF" — the CLI path
# resolved once at the top of the skill — so this works uniformly on Windows
# shells where the space in "C:\Program Files\sf\..." breaks a bare `sf`.
ORG_USER=$("$SF" org display --target-org "$ORG" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['username'])")

if [ -z "$ORG_USER" ]; then
    echo "❌ Failed to discover org username via '\"\$SF\" org display --target-org $ORG'"
    echo "   Verify the org alias is authenticated: \"\$SF\" org login web --alias $ORG"
    exit 1
fi
echo "✅ Discovered target-org Run-As user: $ORG_USER"

# Rewrite the XML in place — replace whatever is currently between
# <clientCredentialsFlowUser>...</clientCredentialsFlowUser> with the discovered username.
# Uses python3 so we don't depend on sed's differing regex flavors across platforms.
POLICY_XML="ps-eca/main/default/extlClntAppOauthPolicies/Salesforce_DC_Prod_Org_oauthPlcy.ecaOauthPlcy-meta.xml"

python3 - "$POLICY_XML" "$ORG_USER" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
new_user = sys.argv[2]

xml = path.read_text(encoding='utf-8')

# Case A: element exists — replace its inner text
pattern_inner = re.compile(r'(<clientCredentialsFlowUser>)([^<]*)(</clientCredentialsFlowUser>)')
if pattern_inner.search(xml):
    xml_new = pattern_inner.sub(rf'\g<1>{new_user}\g<3>', xml)
else:
    # Case B: element missing — inject it just before the closing tag of the root
    close = '</ExtlClntAppOauthConfigurablePolicies>'
    if close not in xml:
        raise SystemExit('❌ Root close tag not found in ' + str(path))
    xml_new = xml.replace(close, f'    <clientCredentialsFlowUser>{new_user}</clientCredentialsFlowUser>\n{close}')

path.write_text(xml_new, encoding='utf-8')
print(f'✅ Rewrote clientCredentialsFlowUser -> {new_user} in {path}')
PY

# Confirm the substitution took effect — grep must show the discovered user, not a placeholder
if ! grep -q "<clientCredentialsFlowUser>${ORG_USER}</clientCredentialsFlowUser>" "$POLICY_XML"; then
    echo "❌ XML rewrite did not take effect — inspect $POLICY_XML"
    exit 1
fi
echo "✅ Component 5 XML now points at Run-As user '$ORG_USER'"
```

**Local repo hygiene note:** the rewrite modifies a tracked file on disk. If the repo is used across multiple orgs, either:
- accept the diff as part of the deploy (recommit after each org install with the discovered username), or
- add a `.gitignore` entry for `ps-eca/main/default/extlClntAppOauthPolicies/*_oauthPlcy-meta.xml` and keep a template `.template.xml` version in-tree that this step reads then writes-through to the tracked path. The current shipped skill takes the first approach for simplicity.

---

### Step 1b — Substitute `<contactEmail>` in component 1's XML with the running user's real email

**Why this step exists:** The `<contactEmail>` element on `ExternalClientApplication` is a required, informational field that Salesforce uses for notifications about the app (deprecations, security advisories). Hardcoding a personal email in a public repo would leak that address into every install. The repo ships the file with a **`Logged_In_User_Email` placeholder** — this step reads the running user's email via `sf org display user --target-org <alias> --json` and substitutes the real value in place just before component 1 deploys.

This runs AFTER Step 1a (Run-As user substitution) and BEFORE Step 2 (deploy loop). Component 1 (`ExternalClientApplication:Salesforce_DC_Prod_Org`) is the first item deployed in Step 2, and it reads its email from the file we just rewrote.

```bash
ECA_XML="ps-eca/main/default/externalClientApps/Salesforce_DC_Prod_Org.eca-meta.xml"

# 1. Discover the running user's email (User.Email — NOT username, which is a login handle).
#    `"$SF" org display user` returns the User row for whoever is authenticated on the org
#    alias, with a top-level `email` field. Uses "$SF" for consistent Windows behavior.
USER_EMAIL=$("$SF" org display user --target-org "$ORG" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('result', {})
email = r.get('email') or r.get('user', {}).get('email') or ''
print(email)
")

# 2. Sanity check — must be a non-empty email-looking string. If empty, fall back to username
#    (which is email-shaped for most Salesforce users) and warn.
if [ -z "$USER_EMAIL" ]; then
    USER_EMAIL=$("$SF" org display --target-org "$ORG" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['username'])")
    echo "ℹ️  User.Email was empty on the org — falling back to username ($USER_EMAIL) as contactEmail"
fi

if [ -z "$USER_EMAIL" ]; then
    echo "❌ Could not discover a contact email from the org — both User.Email and username came back empty"
    exit 1
fi

echo "✅ Discovered contactEmail for ECA: $USER_EMAIL"

# 3. Rewrite the placeholder in place (Python — regex-safe across platforms; matches
#    both the shipping placeholder value and any prior value written by a previous install run).
python3 - "$ECA_XML" "$USER_EMAIL" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
new_email = sys.argv[2]
xml = path.read_text(encoding='utf-8')

pattern = re.compile(r'(<contactEmail>)([^<]*)(</contactEmail>)')
if not pattern.search(xml):
    raise SystemExit(f'❌ <contactEmail> element not found in {path}')

xml_new = pattern.sub(rf'\g<1>{new_email}\g<3>', xml)
path.write_text(xml_new, encoding='utf-8')
print(f'✅ Rewrote contactEmail -> {new_email} in {path}')
PY

# 4. Confirm the substitution took effect
if ! grep -q "<contactEmail>${USER_EMAIL}</contactEmail>" "$ECA_XML"; then
    echo "❌ XML rewrite did not take effect — inspect $ECA_XML"
    exit 1
fi
echo "✅ Component 1 XML now carries contactEmail = '$USER_EMAIL'"
```

**Repo default (shipped in-tree):**

```xml
<contactEmail>Logged_In_User_Email</contactEmail>
```

This literal string is the sentinel Step 1b matches against. It is intentionally NOT a valid email address — a raw `sf project deploy start` bypassing this skill would fail with a `contactEmail` validation error, forcing the operator through the skill (which substitutes correctly).

**Local repo hygiene note:** same tradeoff as Step 1a's `<clientCredentialsFlowUser>` rewrite — the substitution modifies the tracked file. Either recommit after each org install, or restore the placeholder after deploy:

```bash
# Optional: restore the placeholder so `git status` stays clean for the next re-clone / next org
python3 - "$ECA_XML" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
xml = path.read_text(encoding='utf-8')
xml = re.sub(r'(<contactEmail>)[^<]*(</contactEmail>)', r'\g<1>Logged_In_User_Email\g<2>', xml)
path.write_text(xml, encoding='utf-8')
PY
```

The current shipped skill does NOT auto-restore — it leaves the diff visible, matching Step 1a's convention.

---

### Step 1c — Pre-flight Salesforce deployment queue gate (INV-1)

Before any ECA deploy is submitted, verify the target org has no non-terminal Salesforce `DeployRequest` in flight. A previous run of this skill, another operator, or an unrelated deployment can leave the queue busy — starting a new ECA deploy on top of it produces confusing races and (historically) has triggered duplicate ECA submissions when the outer harness timed out.

```bash
wait_for_no_active_deploys "pre-flight"
```

Behavior of the gate (all implemented in `wait_for_no_active_deploys`, defined above):
- Asks Salesforce directly for non-terminal deployments via `SELECT Id, Status FROM DeployRequest WHERE Status NOT IN ('Succeeded','Failed','Canceled','SucceededPartial') ORDER BY CreatedDate DESC` — **no LIMIT, no client-side filtering**. The queue is clear if and only if this authoritative query returns zero rows.
- The `WHERE Status NOT IN (...)` filter treats `Succeeded`, `Failed`, `Canceled`, and `SucceededPartial` as terminal. Every other state (`Pending`, `Queued`, `InProgress`, `Canceling`, or any future state Salesforce introduces) is by definition returned from this query and therefore blocks. INV-1's "unknown states count as non-terminal" is enforced structurally by the query itself, not by a client-side allowlist.
- Polls every 20 seconds. Prints a progress line on every poll and on every state change (to stderr): `▸ [pre-flight] Waiting for active Salesforce deployments: 0AfgK...:InProgress`.
- Fail-fast on broken query pipeline: after 3 consecutive Tooling API query / parse failures, the gate exits with the last CLI response body — it does not spend the full 30-minute ceiling shielding a broken CLI or expired auth token.
- Hard-fails after 30 minutes wall clock on a genuinely active deployment, and prints the offending DeployRequest rows before exiting.
- **Never** consults local Claude background-task state, output-file size, or process presence — Salesforce is the sole source of truth (INV-3).

If an existing deployment ends `Failed` or `Canceled` while the gate is waiting, the gate itself proceeds (its job is only to wait for the queue to clear). The per-component logic in Step 2 will still run its own `deploy report` check on any DeployId this skill submits — a foreign failed deploy in the queue does not become this skill's problem. If the operator wants to abort on a foreign failure, they can Ctrl-C out of the gate and investigate before re-running.

---

### Step 2 — Deploy ECA components (5 async submissions, strict order, Salesforce polling)

**Each component is submitted individually via `--metadata <Type>:<Name> --async --json`. The submit call must return quickly with a Salesforce Deploy Id. That Deploy Id — and only that Deploy Id — is then polled to a terminal state via `deploy report`. No `--wait N` is used anywhere (INV-2).**

Before each submit, the skill:

1. **Reconciles queue state.** Runs `wait_for_no_active_deploys "before ECA N/5"` again so that no two ECA-component deploys are ever non-terminal at the same time (INV-4).
2. **Checks whether the component already exists in the target org.** If it does (previous run left it deployed), the skill logs `SKIP: already deployed` and moves on. This makes the loop idempotent and prevents duplicate submits (INV-3).
3. **Submits exactly once with `--async --json`.** The submit call returns in seconds with a Deploy Id. If no Deploy Id comes back, the skill treats submit as failed and stops (see the ambiguous-submit reconciliation below).
4. **Polls only that Deploy Id** with `poll_deploy_to_terminal` until Salesforce reports a terminal state.
5. Requires the terminal state to be `Succeeded` with `numberComponentErrors == 0`, then re-verifies the component in the org, before moving on to component N+1.

```bash
# $ORG was resolved exactly once by the CLI resolver at the top of the skill
# (from --org_alias or state.orgAlias) and MUST NOT be re-assigned here.
# See invariant INV-ORG-ONCE in the Windows CLI handling section.

# Component-existence probe. Different ECA metadata types live in different
# Tooling API sObjects — this map keeps the check surgical rather than doing
# a whole-org describe. If a component's sObject is not queryable (rare, and
# type-specific), the probe returns UNKNOWN and the caller falls through to
# the ambiguous-submit reconciliation.
component_exists_in_org() {
    local coord="$1"                          # "Type:DevName"
    local type="${coord%%:*}"
    local name="${coord##*:}"
    local sobj=""
    case "$type" in
        ExternalClientApplication)               sobj="ExternalClientApplication" ;;
        ExtlClntAppOauthSettings)                sobj="ExtlClntAppOauthSettings" ;;
        ExtlClntAppGlobalOauthSettings)          sobj="ExtlClntAppGlobalOauthSets" ;;
        ExtlClntAppConfigurablePolicies)         sobj="ExtlClntAppConfigurablePolicies" ;;
        ExtlClntAppOauthConfigurablePolicies)    sobj="ExtlClntAppOauthConfigurablePolicies" ;;
        *)                                       sobj="" ;;
    esac
    if [ -z "$sobj" ]; then
        echo "UNKNOWN"
        return 0
    fi

    local resp
    resp=$("$SF" data query --target-org "$ORG" --use-tooling-api \
        --query "SELECT Id FROM $sobj WHERE DeveloperName = '$name' LIMIT 1" \
        --json 2>&1)
    printf '%s' "$resp" | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    print('UNKNOWN'); sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    print('UNKNOWN'); sys.exit(0)
# Tooling API errors come back with 'name' == 'INVALID_TYPE' etc.
if d.get('status') and d.get('status') != 0:
    print('UNKNOWN'); sys.exit(0)
recs = (d.get('result') or {}).get('records') or []
print('EXISTS' if recs else 'MISSING')
"
}

# Submit exactly one ECA component and poll it to terminal. Enforces INV-2, -3, -4, -6.
deploy_one() {
    # $1 = ordinal (1-5)  $2 = metadata coordinate (Type:Name)  $3 = human label
    local N="$1" COORD="$2" LABEL="$3"

    echo "▶ ECA ${N}/5: preparing ${LABEL}"

    # (a) Queue gate — never allow two ECA deploys non-terminal at once.
    wait_for_no_active_deploys "before ECA ${N}/5"

    # (b) Idempotency check — if the component is already in the org, skip the submit.
    local exists
    exists=$(component_exists_in_org "$COORD")
    if [ "$exists" = "EXISTS" ]; then
        echo "▸ ECA ${N}/5: ${COORD} already present in org — SKIP submit (idempotent)"
        return 0
    fi

    # (c) Submit exactly once, asynchronously. --wait is FORBIDDEN here (INV-2).
    #     Snapshot a "before submit" UTC timestamp so the ambiguous-submit
    #     reconciliation below can restrict its lookup to DeployRequests that
    #     Salesforce actually created for THIS submit (not something older that
    #     happens to be top-of-list). Uses Salesforce's own date if available;
    #     falls back to a Python-generated ISO 8601 UTC timestamp — never uses
    #     shell `date` alone since GNU/BSD/Windows shells diverge.
    local submit_before_ts
    submit_before_ts=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(seconds=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    echo "▸ ECA ${N}/5: submitting async (reconciliation window: created after $submit_before_ts)"
    local submit_resp
    submit_resp=$("$SF" project deploy start \
        --metadata "$COORD" \
        --target-org "$ORG" \
        --async \
        --json 2>&1)

    local deploy_id
    deploy_id=$(printf '%s' "$submit_resp" | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    print(''); sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    print(''); sys.exit(0)
r = d.get('result') or {}
print(r.get('id') or '')
")

    if [ -z "$deploy_id" ]; then
        # (d) Ambiguous submit — the CLI returned no Deploy Id. Do NOT resubmit.
        #     Reconcile against Salesforce first (INV-3, duplicate-submission prevention).
        #
        #     The query below is intentionally NOT "top-N most recent". It restricts
        #     to DeployRequests created AFTER our pre-submit timestamp AND created by
        #     the currently-authenticated user. If Salesforce returns exactly one row
        #     matching those constraints, that row is the deploy this submit produced.
        #     Zero rows → the submit never landed. Two+ rows → we refuse to guess and
        #     abort (a human must investigate rather than us picking arbitrarily).
        echo "⚠️  ECA ${N}/5: submit returned no Deploy Id — reconciling against Salesforce" >&2

        # Resolve the authenticated User.Id via a two-step call.
        #
        # WHY TWO STEPS: `sf org display --json`'s top-level `result.id` is the
        # ORG Id (starts "00D"), NOT a User Id — using it against
        # DeployRequest.CreatedById (which requires a User.Id, starts "005") would
        # simply return zero rows and mask the reconciliation.
        #
        # Step 1: get the authenticated username (login handle) from the CLI.
        # Step 2: resolve that username to its actual User.Id with a real
        #         SOQL query against the target org. This is the only way to
        #         obtain a User.Id with verified semantics.
        local auth_username user_id
        auth_username=$("$SF" org display --target-org "$ORG" --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(''); sys.exit(0)
r = d.get('result') or {}
print(r.get('username') or '')
")

        user_id=""
        if [ -n "$auth_username" ]; then
            # Escape single-quotes for SOQL string literal safety.
            local _safe_user
            _safe_user=$(printf '%s' "$auth_username" | sed "s/'/\\\\'/g")
            user_id=$("$SF" data query --target-org "$ORG" \
                --query "SELECT Id FROM User WHERE Username = '${_safe_user}' LIMIT 1" \
                --json 2>/dev/null | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    print(''); sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    print(''); sys.exit(0)
if d.get('status') not in (None, 0):
    print(''); sys.exit(0)
recs = (d.get('result') or {}).get('records') or []
if not recs:
    print(''); sys.exit(0)
uid = recs[0].get('Id') or ''
# Salesforce User Ids start with '005'. Anything else is not a User.Id and
# must not be used for CreatedById correlation.
print(uid if uid.startswith('005') else '')
")
        fi

        local reconciled_query
        if [ -n "$user_id" ]; then
            echo "▸ ECA ${N}/5: reconciliation scope = created after $submit_before_ts by User.Id $user_id" >&2
            reconciled_query="SELECT Id, Status, CreatedDate, CreatedById FROM DeployRequest WHERE CreatedDate > ${submit_before_ts} AND CreatedById = '${user_id}' ORDER BY CreatedDate ASC"
        else
            # Could NOT verify a User.Id. Do NOT guess with the raw org-display id
            # (which is an Org Id, not a User Id). Fall back to a strict-time-only
            # window; the ONE/AMBIGUOUS/NONE sentinels downstream will refuse to
            # pick one blindly if the time window catches more than a single row.
            echo "▸ ECA ${N}/5: could not verify User.Id (username='$auth_username') — reconciling by submission timestamp alone" >&2
            reconciled_query="SELECT Id, Status, CreatedDate, CreatedById FROM DeployRequest WHERE CreatedDate > ${submit_before_ts} ORDER BY CreatedDate ASC"
        fi
        local reconciled
        reconciled=$("$SF" data query --target-org "$ORG" --use-tooling-api \
            --query "$reconciled_query" \
            --json 2>&1 | python3 -c "
import json, sys
raw = sys.stdin.read()
i = raw.find('{')
if i < 0:
    print('QUERY_ERROR'); sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    print('QUERY_ERROR'); sys.exit(0)
if isinstance(d, list) or (d.get('status') not in (None, 0)):
    print('QUERY_ERROR'); sys.exit(0)
recs = (d.get('result') or {}).get('records') or []
if not recs:
    print('NONE')
elif len(recs) > 1:
    # Refuse to guess — multiple DeployRequests match the reconciliation window.
    ids = ','.join(r.get('Id','?') for r in recs)
    print(f'AMBIGUOUS:{ids}')
else:
    r = recs[0]
    print(f\"ONE:{r.get('Id','')}:{r.get('Status','')}\")
")
        case "$reconciled" in
            QUERY_ERROR|"")
                echo "❌ ECA ${N}/5: submit returned no Deploy Id and the reconciliation Tooling API query failed. Aborting rather than guessing." >&2
                printf '%s\n' "$submit_resp" >&2
                exit 1
                ;;
            NONE)
                echo "❌ ECA ${N}/5: submit returned no Deploy Id and Salesforce shows no matching DeployRequest in the reconciliation window. The submit itself failed — see CLI response body below." >&2
                printf '%s\n' "$submit_resp" >&2
                exit 1
                ;;
            AMBIGUOUS:*)
                echo "❌ ECA ${N}/5: submit returned no Deploy Id and Salesforce shows MULTIPLE matching DeployRequests in the reconciliation window (${reconciled#AMBIGUOUS:}). Refusing to guess which one belongs to this submit." >&2
                printf '%s\n' "$submit_resp" >&2
                exit 1
                ;;
            ONE:*)
                # Exactly one candidate — safe to adopt.
                local rid="${reconciled#ONE:}"
                local rst="${rid#*:}"
                rid="${rid%%:*}"
                case "$rst" in
                    Succeeded|Failed|Canceled|SucceededPartial)
                        # The prior submit reached a terminal state before we got the response.
                        # Re-check org state; if the component now exists, treat as done.
                        exists=$(component_exists_in_org "$COORD")
                        if [ "$exists" = "EXISTS" ]; then
                            echo "▸ ECA ${N}/5: recovered — component present after DeployRequest $rid ($rst)" >&2
                            return 0
                        fi
                        echo "❌ ECA ${N}/5: submit indeterminate; matching DeployRequest is $rid ($rst) but component still missing." >&2
                        printf '%s\n' "$submit_resp" >&2
                        exit 1
                        ;;
                    *)
                        # Non-terminal (Pending / Queued / InProgress / Canceling / unknown).
                        # Adopt this Deploy Id and poll it instead of resubmitting (INV-3).
                        echo "▸ ECA ${N}/5: adopting DeployRequest $rid ($rst) from Salesforce" >&2
                        deploy_id="$rid"
                        ;;
                esac
                ;;
            *)
                echo "❌ ECA ${N}/5: unexpected reconciliation sentinel '$reconciled'. Aborting." >&2
                printf '%s\n' "$submit_resp" >&2
                exit 1
                ;;
        esac
    fi

    echo "▸ ECA ${N}/5: Deploy Id $deploy_id — polling Salesforce for terminal state"

    # (e) Poll only this Deploy Id, only via Salesforce.
    local final_status
    final_status=$(poll_deploy_to_terminal "$deploy_id" "ECA ${N}/5")

    case "$final_status" in
        Succeeded)
            ;;
        SucceededPartial)
            echo "❌ ECA ${N}/5: Salesforce returned SucceededPartial for $deploy_id — treating as failure (require full success)."
            exit 1
            ;;
        Failed|Canceled)
            echo "❌ ECA ${N}/5: Salesforce reported $final_status for $deploy_id."
            "$SF" project deploy report --job-id "$deploy_id" --target-org "$ORG" --json | tail -60
            exit 1
            ;;
        TIMEOUT)
            echo "❌ ECA ${N}/5: Deploy $deploy_id exceeded the ${WAIT_CEILING_S}s ceiling without reaching a terminal state."
            exit 1
            ;;
        ERROR)
            echo "❌ ECA ${N}/5: Deploy $deploy_id polling failed fast after $MAX_CONSECUTIVE_QUERY_FAILURES consecutive Salesforce/CLI errors (see stderr above)."
            exit 1
            ;;
        *)
            echo "❌ ECA ${N}/5: unexpected sentinel '$final_status' from poll_deploy_to_terminal for $deploy_id."
            exit 1
            ;;
    esac

    # (f) Verify component actually exists in the org after the deploy claims Succeeded.
    #     Success REQUIRES positive evidence — `component_exists_in_org` must
    #     return literal EXISTS. Anything else (MISSING / UNKNOWN / unexpected
    #     sentinel) is a hard failure. An unqueryable Tooling API object or a
    #     parse error is NOT successful verification (INV-VERIFY-POSITIVE).
    exists=$(component_exists_in_org "$COORD")
    case "$exists" in
        EXISTS)
            echo "✅ ECA ${N}/5 deployed and verified in org"
            ;;
        MISSING)
            echo "❌ ECA ${N}/5: Salesforce reported Succeeded but component $COORD is not visible via Tooling API."
            exit 1
            ;;
        UNKNOWN)
            echo "❌ ECA ${N}/5: post-deploy verification for $COORD could not be completed — the component-existence probe returned UNKNOWN (unqueryable sObject, Tooling API error, or parse error). Refusing to claim success without positive evidence."
            exit 1
            ;;
        *)
            echo "❌ ECA ${N}/5: post-deploy verification for $COORD returned unexpected sentinel '$exists'. Refusing to claim success."
            exit 1
            ;;
    esac
}

# ── One component at a time, in the required order ──────────────────────────
deploy_one 1 "ExternalClientApplication:Salesforce_DC_Prod_Org"                       "ExternalClientApplication"
deploy_one 2 "ExtlClntAppOauthSettings:Salesforce_DC_Prod_Org_oauth"                  "ExtlClntAppOauthSettings"
deploy_one 3 "ExtlClntAppGlobalOauthSettings:Salesforce_DC_Prod_Org_glbloauth"        "ExtlClntAppGlobalOauthSettings"
deploy_one 4 "ExtlClntAppConfigurablePolicies:Salesforce_DC_Prod_Org_plcy"            "ExtlClntAppConfigurablePolicies"
deploy_one 5 "ExtlClntAppOauthConfigurablePolicies:Salesforce_DC_Prod_Org_oauthPlcy"  "ExtlClntAppOauthConfigurablePolicies (Run-As user binding)"

echo "✅ All 5 ECA components deployed successfully"
```

**Why async + Salesforce-polled and never `--wait N`:** the historical `--wait 10` foreground pattern reliably exceeded Claude's Bash 2-minute timeout on real ECA deploys. When that happened the CLI process was moved to a Claude background task whose output file was frequently 0 bytes at completion, so the caller couldn't determine whether the deploy had actually succeeded, failed, or was still running. That ambiguity, in turn, produced duplicate submits on retry. The async pattern above:

- makes the submit itself short (returns as soon as Salesforce accepts the metadata bundle),
- keeps the ground-truth Deploy Id in the caller's hand from the first second,
- and turns "is it done yet?" into a boring, cheap, deterministic `deploy report` poll against Salesforce.

**Why one-at-a-time:** Salesforce evaluates ECA metadata in dependency order at apply time. A bulk deploy can attempt to apply them in arbitrary order and fail with `parent ExternalClientApplication not found` or `OAuth settings cannot be applied without global settings`. The 5 sequential `--metadata` calls force the platform to apply each component as a separate transaction in the correct order.

**Why Salesforce state and not `result.success`:** modern `sf` CLI async responses don't set `result.success` (that field only appears on the final `deploy start --wait` payload). The authoritative signals are the `status` field on the async `deploy start` response (`Queued`/`InProgress`/etc.) and, once terminal, `deploy report`'s `status`, `numberComponentsDeployed`, and `numberComponentErrors`. This skill reads those directly.

**Why we probe the component sObject before submitting:** if a prior partial run already deployed this component, resubmitting is at best pointless and at worst causes the CLI to serialize behind a queue that this skill already cleared with its pre-flight gate. The component-existence probe (`component_exists_in_org`) is a single Tooling API SOQL and skips the submit entirely on a match — the idempotency guarantee INV-3 relies on.

---

### Step 3 — Verify ExternalClientApplication exists in the org (Tooling API SOQL)

After all 5 deploys succeed, confirm the app row is queryable. This catches the rare case where the deploy reports Succeeded but the org's metadata index hasn't caught up.

**Why we curl the Tooling API directly instead of `sf data query --use-tooling-api`:**
1. **API version pinning.** `ExternalClientApplication` is only available on API v65+; `sf data query` uses whatever the CLI's default version is (often v60 for older `sf` installs), which returns `sObject type 'ExternalClientApplication' is not supported`. A direct curl to `/services/data/v67.0/tooling/query` pins the version.
2. **Windows PATH bug in `sf data query`.** On Windows shells (Git Bash / MSYS), some `sf` CLI installs choke on the space in `C:\Program Files\...` when the subcommand shells out — the exact error is `'C:\Program' is not recognized as an internal or external command`. The curl path sidesteps the CLI's argv parsing entirely.

The auth token comes from `sf org display --verbose --json`, which every authenticated org has. Nothing else in the shell environment is needed.

```bash
"$SF" org display --target-org "$ORG" --verbose --json > /tmp/eca_orgv.json

python3 <<'PY' > /tmp/eca_env.sh
import json, os
raw = open('/tmp/eca_orgv.json', encoding='utf-8', errors='ignore').read()
i = raw.find('{')
d = json.loads(raw[i:])
r = d.get('result', {})
inst = r.get('instanceUrl') or ''
tok  = r.get('accessToken') or ''
if not inst or not tok:
    raise SystemExit('❌ sf org display did not return instanceUrl+accessToken — re-auth: sf org login web --alias ' + os.environ.get('ORG',''))
print(f'export INSTANCE_URL="{inst}"')
print(f'export ACCESS_TOKEN="{tok}"')
PY
source /tmp/eca_env.sh

RESP=$(curl -sS -G "$INSTANCE_URL/services/data/v67.0/tooling/query" \
    --data-urlencode "q=SELECT Id, DeveloperName FROM ExternalClientApplication WHERE DeveloperName='Salesforce_DC_Prod_Org' LIMIT 1" \
    -H "Authorization: Bearer $ACCESS_TOKEN")

FOUND=$(echo "$RESP" | python3 -c "
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print('0'); sys.exit(0)
# Tooling API returns a top-level object with totalSize; error responses are a top-level LIST
if isinstance(d, list):
    print('0')
else:
    print(d.get('totalSize', 0))
")

if [ "$FOUND" != "1" ]; then
    echo "❌ Verification failed — ExternalClientApplication 'Salesforce_DC_Prod_Org' not queryable via Tooling API"
    echo "   Response body: $RESP"
    echo "   The deploy reported Succeeded but the row is not visible. This is unusual — investigate before"
    echo "   running /mcp-setup."
    unset ACCESS_TOKEN INSTANCE_URL
    exit 1
fi

echo "✅ ExternalClientApplication 'Salesforce_DC_Prod_Org' verified in org"
unset ACCESS_TOKEN INSTANCE_URL
```

---

### Step 4 — Cleanup temp files

```bash
rm -rf /tmp/eca_deploys /tmp/eca_verify.json /tmp/eca_orgv.json /tmp/eca_env.sh
```

---

### Step 5 — Generate completion summary

```text
✅ External Client App Deployment Complete

Target Org:      <org_alias>
Source:          ps-eca/main/default/
Run-As user:     <ORG_USER>  (auto-discovered from `sf org display --json` in Step 1a)

Deployed components (in dependency order):
  ✅ 1/5  ExternalClientApplication:Salesforce_DC_Prod_Org
  ✅ 2/5  ExtlClntAppOauthSettings:Salesforce_DC_Prod_Org_oauth
  ✅ 3/5  ExtlClntAppGlobalOauthSettings:Salesforce_DC_Prod_Org_glbloauth        (client_credentials flow enabled)
  ✅ 4/5  ExtlClntAppConfigurablePolicies:Salesforce_DC_Prod_Org_plcy
  ✅ 5/5  ExtlClntAppOauthConfigurablePolicies:Salesforce_DC_Prod_Org_oauthPlcy  (Run-As user = <ORG_USER>)

Tooling API SOQL verification: 1 row matched (DeveloperName = 'Salesforce_DC_Prod_Org')

Next step in the installer chain: /mcp-setup
  (will prompt user for the Consumer Key + Consumer Secret that Salesforce
   auto-generated from the components above, then register both MCP servers)
```

---

## Error Handling

### Component 1 fails (ExternalClientApplication)

Usually means:
- The org doesn't have External Client App framework enabled (rare; modern orgs have it by default)
- A prior deploy of the same DeveloperName exists with conflicting settings (delete it first via Setup → App Manager)
- License missing — check the org's edition supports External Client Apps

**Action:** stop, surface the deploy error, ask the user to investigate. Do NOT auto-retry.

### Component 2 / 3 / 4 fails

Most common cause: the previous component's deploy completed but Salesforce's internal metadata index hadn't caught up before component N+1 was attempted. The pre-flight queue gate (`wait_for_no_active_deploys`) that runs before each `deploy_one` should prevent this, but if it happens:

**Action:** stop, surface the deploy error verbatim. The user re-runs this skill — the loop is idempotent (already-deployed components return no-op success on the next attempt).

### Component 5 fails (ExtlClntAppOauthConfigurablePolicies)

Two common failure modes:

1. **`Element {…}clientCredentialsFlowUser invalid at this location`** — the element name is wrong. The correct spelling is `clientCredentialsFlowUser` (with **Flow** in the middle). Watch out for the near-miss `clientCredentialsUser` — it exists as a Tooling API field name but is NOT the correct metadata element and will be rejected. Verify the XML on disk with `grep clientCredentialsFlow ps-eca/main/default/extlClntAppOauthPolicies/*.xml`.

2. **`No such user: <ORG_USER>`** — Step 1a discovered a username that doesn't exist in the target org (usually happens when the org alias points at the wrong org, or the auth session belongs to a deactivated user). Fix by re-authenticating: `sf org login web --alias <org_alias>`.

**Action:** stop, surface the deploy error verbatim. Component 5 must succeed for `/mcp-setup`'s OAuth probe to pass — do NOT skip it and proceed.

### Step 1a fails to discover a username

`sf org display --target-org <alias> --json` returned no `result.username`. Usually means the alias is not authenticated. Fix: `sf org login web --alias <alias>` and re-run.

### Verification (Step 3) returns 0 rows

Indicates a platform-level apply lag. Wait 30 seconds and re-run this skill. If it still fails after a minute, escalate — the deploy succeeded but the row isn't queryable, which usually means the org has unusual metadata-index issues.

---

## Success Criteria

✅ `sfdx-project.json` lists `ps-eca` as a packageDirectory (Step 0)
✅ All 5 ECA source files present on disk, and component 3 XML has `<isClientCredentialsFlowEnabled>true</isClientCredentialsFlowEnabled>` (Step 1)
✅ `sf org display --target-org <alias> --json` returned a non-empty `result.username`, and component 5 XML's `<clientCredentialsFlowUser>` value was rewritten to that username (Step 1a)
✅ Pre-flight queue gate observed a clear Salesforce `DeployRequest` queue (no non-terminal rows) before Component 1 was submitted (Step 1c)
✅ Each of the 5 components was either found already-deployed via Tooling API probe (idempotent skip) OR was submitted exactly once via `sf project deploy start --metadata <Type>:<Name> --async --json`, adopted the returned Salesforce Deploy Id, and polled that Deploy Id to a terminal `Succeeded` with `numberComponentErrors == 0` via `sf project deploy report` (Step 2)
✅ No `sf project deploy start --wait N` calls appear in the executed workflow (INV-2)
✅ At no point were two ECA-component deployments simultaneously non-terminal (INV-4 — enforced by `wait_for_no_active_deploys` before each component)
✅ Deploys ran sequentially — Component N+1 was NOT submitted if Component N did not reach Succeeded (Step 2 stop-on-failure)
✅ Tooling API SOQL `SELECT FROM ExternalClientApplication WHERE DeveloperName = 'Salesforce_DC_Prod_Org'` — issued as a direct curl to `<instanceUrl>/services/data/v67.0/tooling/query` with the `sf` access token — returned `totalSize: 1` (Step 3)
✅ Temp files in `/tmp/eca_deploys/`, `/tmp/eca_orgv.json`, and `/tmp/eca_env.sh` deleted (Step 4)
✅ No secrets read, written, or echoed — the Consumer Key/Secret are NOT this skill's concern (they live in `/mcp-setup`)

---

## Integration with Other Skills

```
Installer chain:
  ...
  /base-metadata-deploy          (ps-base → classes, objects, permsets, sample data)
      ↓
  /external-client-app-deploy    ← THIS SKILL — deploys 5 ECA components from ps-eca/,
                                    including the Run-As user binding for client_credentials
      ↓
  /mcp-setup                     (prompts user for Key/Secret, registers data360
                                    + salesforce-sobject-all MCPs; OAuth probe succeeds
                                    because the Run-As user is already assigned by this skill)
      ↓
  /datakit-api-deploy
      ↓
  ...
```

**This skill MUST run after `/base-metadata-deploy` and BEFORE `/mcp-setup`.** The Consumer Key and Consumer Secret that `/mcp-setup` collects from the user do not exist until this skill's deploys complete, and `/mcp-setup`'s Step 5 OAuth probe will fail with `no client credentials user enabled` unless component 5 has been deployed with a valid `clientCredentialsFlowUser` (this skill's Step 1a + component 5 in Step 2 handle that).

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"external-client-app-deploy"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.external-client-app-deploy` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
