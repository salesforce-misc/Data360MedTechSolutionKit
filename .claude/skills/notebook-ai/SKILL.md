---
name: notebook-create-and-upload
description: Create a Notebook AI notebook (or reuse an existing one with the same label) and upload local files into its Personal Library via the salesforce-headless-360 MCP server. Handles find-or-create, presigned-URL upload flow, and indexing. Uses the Salesforce Connect API (/ssot/knowledge-space) through MCP dispatch — NOT curl, NOT sf apex. Use when the user says "create notebook X and upload these files" or "set up a notebook with these docs".
user-invocable: true
version: "0.6.1"
---

# Create a Notebook AI notebook and upload files into its Personal Library

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"notebook-ai"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: notebook-ai already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

End-to-end skill that combines what used to be `notebook-create` +
`add-files-to-library`. Single invocation does the whole pipeline:

1. **Find-or-create the notebook** by label.
2. **Resolve the notebook's Personal Library** (it auto-exists at creation).
3. **Upload local files** to the library via the 3-step presigned-URL flow.

**Transport:** all Salesforce Connect API calls go through the
`salesforce-headless-360` MCP server (`mcp__salesforce-headless-360__dispatch`
for writes, `mcp__salesforce-headless-360__dispatch_readonly` for GETs). 
The only non-MCP HTTP call is the AWS S3 PUT for the file bytes — S3 is an
external service that MCP does not proxy. **No `curl` against Salesforce
endpoints. No `sf apex run`. No Bash-shelled auth token extraction.**

Notebook AI beta feature enablement is handled by Step 0 (idempotent) —
no separate prerequisite.

## When to use

- "Create a notebook called Diagnosis and upload these PDFs to it"
- "Set up a notebook for [project] with the docs in [folder]"
- "If notebook X exists, just add these files; otherwise create it first"

## When NOT to use

- Just creating an empty notebook → too much skill for that, but it still
  works (omit `sourceDir` / `files`).
- Just uploading to an existing library when you already have its ID →
  this skill resolves IDs from labels, which is more work than needed.
- Working with Agentforce Data Libraries (`1JD...` IDs) — that's a
  different surface, use `/einstein/data-libraries` instead.

## Prerequisites

1. The `salesforce-headless-360` MCP server is registered and authenticated
   for the target org (verify with `claude mcp list`). If it is not, tell the
   user to run `/mcp-setup` first — this skill does NOT authenticate.
2. `sf` (Salesforce CLI) installed and on PATH — used ONLY by the Step 0
   Notebook-AI-beta wrapper script (`scripts/enable-notebook-ai.sh`), never
   for Connect API calls.
3. Target org authenticated for `sf` CLI as well. The caller MUST pass an
   `orgAlias` — this skill takes no default alias. The Data360 installer
   agent passes the operator's chosen `<org_alias>` forward the same way
   every other skill in this installer receives it.
4. Data Cloud is provisioned in the target org. Step 0A creates,
   configures, and assigns the Notebook AI custom permission set
   required by this skill.
5. Files exist on local disk. Supported types: **PDF, TXT, HTML**.

## Inputs — DO NOT ASK THE USER

This skill is fully parameterized with sensible defaults. Run it without
asking the user any questions. Defaults below are correct for the
Data360MedTechSolutionKit repo.

| Input | Default | When to override |
|---|---|---|
| **orgAlias** | **REQUIRED — no default.** Caller MUST supply the operator's `sf` org alias (same value used by every other skill in this installer). | N/A — always passed in. |
| **label** | `Diagnosis` | Only override if the user explicitly names a different notebook in their request. |
| **sourceDir** | `<repo-root>/MedTechDocuments/` — i.e. `MedTechDocuments/` under the current working directory (the repo root) | Files always live here in this kit. Don't ask. |
| **description** | `""` (empty) | Only if user provided one. |
| **developerName** | derived from label: replace spaces with `_`, strip non-alphanumeric, keep letters/digits/underscores | Only if user provided one. |
| **dataSpace** | `"default"` | Never override unless user explicitly asks. |

**Notebook reuse semantics:** if a notebook with `label="Diagnosis"`
already exists in the org, reuse it (find-or-create). Do not create
duplicates. Do not prompt.

**Files to upload — STRICT ALLOWLIST.** Only these 7 files from the
source dir get uploaded. Match by basename (case-insensitive),
extension `.pdf`. Anything else in `MedTechDocuments/` is silently
skipped (no error, no prompt):

1. `Pre_Implant_Report.pdf`
2. `Implant_Report.pdf`
3. `Call_Transcript.pdf`
4. `Post_Implant_Report.pdf`
5. `ClinicianNote_DischargeSummary.pdf`
6. `Initial_Interrogation.pdf`
7. `Last_Interrogation.pdf`

If a file from the allowlist is missing from the source dir, log a
single-line warning at the end and continue with the rest — don't fail
the run.

## Steps

### 0. Enable Notebook AI beta feature (idempotent, best-effort)

Notebook AI is a Data Cloud Beta Feature. On new orgs it must be toggled ON before any of the `/ssot/knowledge-space` REST calls will succeed. The toggle is served by an internal Aura descriptor and is not exposed via public API — the wrapper script handles auth, cookie priming, and the POST.

🚨 **STRICT: Never use Playwright / `mcp__plugin_playwright_playwright__*` / any UI or browser automation for this step.** The wrapper script is the ONLY sanctioned toggle path. Do NOT open `/lightning/setup/BetaFeaturesSetup/home` in a browser under any circumstance — not as a fallback, not as a "safer" path, not to verify the flag. If the wrapper appears to fail, Step 2's `POST /ssot/knowledge-space` is the authoritative gate: it will return `HTTP 201` when the beta is on and `HTTP 400 "No Knowledge Space Config Found For the DataSpace"` when it is off. Trust that gate, not the wrapper's exit code and not the Setup UI.

**Always run the wrapper — it is idempotent.** Salesforce returns `state: SUCCESS` whether the flag was already set or just flipped. Do NOT try to short-circuit via `GET /ssot/knowledge-space` — that endpoint returns `HTTP 200 {"knowledgeSpaces":[]}` for both enabled AND disabled orgs, so it is NOT a diagnostic for the beta flag (verified 2026-08-31).

```
bash scripts/enable-notebook-ai.sh {orgAlias}
```

Outcomes:

- **Exit 0 + log line `✅ Notebook AI enabled (or already enabled)`** → proceed to Step 1.
- **Non-zero exit (including the new `STALE_DESCRIPTOR` state)** → log the wrapper's stderr, append a warning to `state.warnings`, and proceed to Step 1 anyway. The wrapper's exit code is advisory; Step 2's `POST /ssot/knowledge-space` is the authoritative gate for whether the beta feature is actually on.
- **If Step 2 later returns `HTTP 400 "No Knowledge Space Config Found For the DataSpace"`** → the wrapper genuinely failed to flip the flag. STOP. Do NOT retry the wrapper in a loop, do NOT open the Setup UI. Surface both the wrapper's stderr AND Step 2's error to the operator with instructions to enable Notebook AI manually via Setup → Feature Manager → Notebook AI → Enable, then re-invoke this skill.

**Descriptor drift warning.** The wrapper POSTs to an undocumented internal Aura descriptor (`serviceComponent://ui.cdp.components.setup.controllers.CdpSetupController/ACTION$enableBetaFeature`). Salesforce has renamed this descriptor before (previously `enableBetaFeatureWithoutCascade`, renamed 2026-08-31). If Salesforce renames it again, the wrapper will return `aura_state=STALE_DESCRIPTOR` (empty `actions[]` in the response) and exit non-zero — that is the failure signature to look for. The fix is to capture the new descriptor from the Setup page's network trace and update [scripts/enable-notebook-ai.sh](../../../scripts/enable-notebook-ai.sh), NOT to fall back to browser automation.

**Precondition:** Data Cloud must be provisioned. If `/services/data/v66.0/ssot/data-spaces` doesn't return an Active `default` space, run `/feature-enablement {orgAlias}` first — Data Cloud enablement + provisioning happens there, not here.

### 0B. Ensure the "Notebook AI Agent" is Active (idempotent, best-effort)

Once Notebook AI is enabled (Step 0), Salesforce auto-provisions a system Agentforce agent named `Notebook AI Agent` (BotDefinition.Type observed live as `InternalCopilot`; the Setup list view displays it under Agentforce Agents). Its `BotDefinition` row is created at auto-provision time and the Setup list view shows it as Active — but the runtime `BotVersion` can still be `Inactive` (i.e. the Agentforce Builder's "Activate" button has never been clicked). Step 0B's job is to detect that case and activate it via MCP; if it's already runtime-active, do nothing.

**Do NOT trust `BotDefinition.IsActive` as evidence of runtime activation** — that field only reports the definition-level enablement flag. The authoritative signal is the latest `BotVersion`'s Connect-API activation state (via `GET /connect/bot-versions/{id}/activation`, which returns `{ isActivated: true|false }`).

Transport: `salesforce-headless-360` MCP only — `dispatch_readonly` for the probe, `dispatch` for the activation call. No `sf apex`, no `PATCH BotVersion.Status` (that field-level write does NOT run the validators the Builder's Activate button runs and can result in a definition that reports Active but a version that isn't actually published). No browser automation.

#### 0B.1 Probe current activation state

Resolve the BotDefinition through the Data API (Tooling API returns `INVALID_TYPE` for `BotDefinition` on Data Cloud orgs — matches the 0A.3(c) note):

    dispatch_readonly(
      url="/services/data/v67.0/query",
      queryParams={ "q":
        "SELECT Id, DeveloperName, MasterLabel, Type, IsDeleted FROM BotDefinition
         WHERE DeveloperName = 'NotebookAIAgent'
            OR MasterLabel = 'Notebook AI Agent'
         LIMIT 1" })

- **0 rows** → the agent has not been auto-provisioned yet. Log a warning `Notebook AI Agent BotDefinition not found — Step 0 (feature enablement) may not have fully propagated; skipping activation, downstream 0A.3(c) will surface the same issue if it persists` and proceed to Step 1. Do NOT block.
- **1 row** → capture `<botDefinitionId>` and read the latest BotVersion:

        dispatch_readonly(
          url="/services/data/v67.0/query",
          queryParams={ "q":
            "SELECT Id, VersionNumber FROM BotVersion
             WHERE BotDefinitionId = '<botDefinitionId>'
             ORDER BY VersionNumber DESC LIMIT 1" })

  If 0 rows → log a warning and proceed to Step 1; 0A.3(c) will surface any residual issue.

  Otherwise capture `<botVersionId>` and probe its Connect-API activation state — this is the authoritative signal, NOT `BotVersion.Status` and NOT `BotDefinition.IsActive`:

        dispatch_readonly(
          url="/services/data/v67.0/connect/bot-versions/<botVersionId>/activation",
          method="GET")

  Response schema: `{ isActivated: bool, messages: [string], success: bool }`.

  - If `isActivated == true` → the agent is already runtime-active. Log `Notebook AI Agent already active (versionId=<botVersionId>)` and proceed to Step 1. Do NOT re-activate.
  - If `isActivated == false` → continue to 0B.2.
  - If the GET returns an error or `success == false` → log a warning (include `messages[]`) and proceed to Step 1. Do NOT block.

#### 0B.2 Activate the agent (only when not runtime-active)

Publish the latest `BotVersion` via the same Connect API surface the Builder's "Activate" button uses:

    dispatch(
      url="/services/data/v67.0/connect/bot-versions/<botVersionId>/activation",
      method="POST",
      body={ "status": "Active" })

Expected: an HTTP 2xx response (observed live as `HTTP 201`; `HTTP 200` is also a valid success shape per the OpenAPI spec) with body `{ "isActivated": true, "success": true, "messages": [] }`. This is the SOR-canonical activation route (`postBotVersionActivation` in the `einstein-bot-connect-api` SOR); it runs the same validators the UI runs, so if activation fails for a real reason (missing config, license, downstream setup gap) the response's `messages[]` will explain why. The success check is `status_code in [200, 201] && isActivated == true && success == true` — never gate on `status_code == 200` alone.

Read back to confirm:

    dispatch_readonly(
      url="/services/data/v67.0/connect/bot-versions/<botVersionId>/activation",
      method="GET")

- `isActivated == true && success == true` → log `Notebook AI Agent activated (versionId=<botVersionId>)` and proceed to Step 1.
- `isActivated == false` OR `success == false` OR the POST returned a non-2xx → log a warning that includes the response `messages[]` (e.g. `Notebook AI Agent activation via /connect/bot-versions/.../activation did not succeed: <messages>; leaving as-is, operator can activate manually via Setup → Agentforce Agents → Notebook AI Agent → Activate`) and proceed to Step 1. Do NOT block — the notebook workflow itself does not require the agent to be runtime-active; this activation is a post-enablement convenience aligned with the operator's request.

**MCP ambiguity handling.** If the POST returns an MCP transport error (`operation timed out`, disconnected socket, no HTTP status), wait 2 seconds and re-GET the activation state; if `isActivated == true`, treat the POST as success. Do NOT retry the POST — activation is idempotent at the endpoint but re-issuing on a successful publish can produce misleading `success=false, isActivated=true` responses.

Capture the outcome under `state.artifacts.notebook-ai.step0B` at the end of the skill: `{ botDefinitionId, botVersionId, activated: <true|false>, alreadyActive: <bool>, notFound: <bool>, activationMessages: [<string>] }`.

### 1. Verify MCP session (NO login here)

`{orgAlias}` MUST have been supplied by the caller (see Prerequisites #3 and
the Inputs table). Do NOT assume any hardcoded default alias — this skill is
invoked against arbitrary operator orgs and must accept whatever alias the
installer passes through.

The `salesforce-headless-360` MCP server is expected to be pre-registered and
authenticated for that org via `/mcp-setup`. **This skill does NOT authenticate
and does NOT need an access token — the MCP server holds the OAuth session
server-side and injects the bearer token transparently.**

Diagnostic: ping a benign endpoint via MCP to confirm the session is live:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v66.0/limits",
  method="GET"
)
```

- HTTP 200 with a `limits` payload → session valid, proceed to Step 0A.
- HTTP 401 / "invalid_grant" / server-error → **STOP**. Report:
  `"salesforce-headless-360 MCP session invalid for {orgAlias}. Run /mcp-setup before invoking notebook-ai."` Do not attempt any workaround.

**API version:** use `v66.0` in every Connect API path below. All
`/ssot/knowledge-space*` endpoints are available at v66.0.

**Note on `sf` CLI:** the CLI is still needed for Step 0's beta-feature wrapper
script (`scripts/enable-notebook-ai.sh`) — that script pokes an internal Aura
endpoint that isn't part of the Connect API and therefore isn't reachable via
MCP `dispatch`. Every other API call in this skill goes through MCP.

### 0A. Provision the `Notebook_AI_User_Access` permission set (idempotent)

Provisions the custom permission set the running user needs before the
`/ssot/knowledge-space` endpoints can be exercised. Expected path: new org,
permset does not exist, Step 0A creates it end-to-end. Retry path: if a prior
partial run already created it, reuse the row and reconcile only the missing
configuration — do NOT fail on duplicate-name.

Transport: every operation below goes through `salesforce-headless-360` MCP
(`dispatch` for writes, `dispatch_readonly` for GETs). No `sf apex run`, no
direct curl, no browser automation, no manually extracted access tokens. No
new `sf` CLI usage — the MCP surface covers Step 0A end-to-end.

Discovery-first: before wiring the three sub-surfaces below (System
Permissions, Object Settings, Agent Access) each call MUST be resolved
against the live `PermSets` SOR via `mcp__salesforce-headless-360__describe`
/ `discover`. Do NOT invent field or route names.

#### 0A.1 Resolve the Data Cloud PermissionSetLicense Id (mandatory precondition)

`LicenseId` on `PermissionSet` is immutable after create, so it must be set at
insert time. Resolve the target org's Data Cloud PSL row dynamically — do NOT
hardcode a `0PL...` Id.

    dispatch_readonly(
      url="/services/data/v67.0/query",
      queryParams={ "q":
        "SELECT Id, DeveloperName, MasterLabel FROM PermissionSetLicense
         WHERE MasterLabel = 'Data Cloud'
            OR DeveloperName = 'GenieDataPlatformStarterPsl'
         LIMIT 1" })

If 0 rows, STOP and report — Data Cloud is not provisioned on this org.
Capture the returned `Id` as `<dataCloudPslId>` for 0A.2 / 0A.3 reuse.

#### 0A.2 Existence probe (idempotent gate)

The Tooling probe is used ONLY to answer "does this PermissionSet already
exist, and if so, what is its Id?" It MUST NOT read `LicenseId` — Tooling
API silently omits `LicenseId` from `PermissionSet` result rows on some
orgs (documented in 0A.2c), so a null / missing `LicenseId` from Tooling
is a Tooling artefact, NOT evidence of a license mismatch. `LicenseId`
must always be verified through the normal Data API.

    dispatch_readonly(
      url="/services/data/v67.0/tooling/query",
      queryParams={ "q":
        "SELECT Id, Label FROM PermissionSet
         WHERE Name = 'Notebook_AI_User_Access'" })

- **0 rows** → new install; go to 0A.2b to create it via sObject REST.
- **1 row** → prior partial run. Adopt its Id as `<permSetId>` and
  immediately confirm `LicenseId` through the Data API (never trust the
  Tooling row for this field):

        dispatch_readonly(
          url="/services/data/v67.0/query",
          queryParams={ "q":
            "SELECT Id, LicenseId FROM PermissionSet
             WHERE Id = '<permSetId>' LIMIT 1" })

  Compare ONLY the Data API `LicenseId` value against `<dataCloudPslId>`
  from 0A.1:

  - If the Data API `LicenseId == <dataCloudPslId>`, reuse the row and
    skip 0A.2b — continue at 0A.3 to reconcile the missing configuration.
  - If the Data API `LicenseId` is genuinely `null` or a different
    `0PL...` Id, STOP and report — `LicenseId` is immutable per the
    `PermSets` SOR, so the stale row must be removed manually before
    this skill can proceed.
  - A missing / null `LicenseId` from the *Tooling* probe alone is
    NEVER a mismatch. Only the Data API answer counts.

#### 0A.2b Create the permission set (MCP sObject REST)

Create via the standard sObject REST surface (`POST /sobjects/PermissionSet`)
with `LicenseId` set inline at insert time. `<license>` on the Metadata API
path is NOT used here — the `/headless/metadata` route is not universally
registered on the `salesforce-headless-360` MCP router, and sObject REST
accepts `LicenseId` at create even though the SOR's `agent_guidance`
canonicalises the Metadata API path. This has been verified live: sObject
REST POST honours `LicenseId` at insert and persists it as an immutable
value, exactly like the Metadata API path would.

    dispatch(
      url="/services/data/v67.0/sobjects/PermissionSet",
      method="POST",
      body={
        "Name": "Notebook_AI_User_Access",
        "Label": "Notebook AI User Access",
        "LicenseId": "<dataCloudPslId>",
        "HasActivationRequired": false
      })

Expected response: `201 {"id":"0PS...","success":true,"errors":[]}`. Capture
the returned `id` — it keys 0A.3 onward. `DUPLICATE_VALUE` here means 0A.2
raced with another run: fall back to the 0A.2 reuse branch instead of failing.

#### 0A.2c Read-back verification (mandatory before 0A.3)

Read the newly-created row back through MCP in TWO separate queries. Both
are mandatory. Splitting the reads is required because Tooling API silently
omits `LicenseId` from PermissionSet result rows on some orgs (observed
during validation — the column simply does not appear in the returned record
even though it is present on disk), so `LicenseId` must always be verified via
the normal Data API `/services/data/v67.0/query` route instead.

**Query 1 — Tooling API** (identity + custom/owned-by-profile flags):

    dispatch_readonly(
      url="/services/data/v67.0/tooling/query",
      queryParams={ "q":
        "SELECT Id, Name, Label, IsCustom, IsOwnedByProfile
         FROM PermissionSet WHERE Id = '<created-id>'" })

Must satisfy:
- `Name == 'Notebook_AI_User_Access'`
- `Label == 'Notebook AI User Access'`
- `IsCustom == true`
- `IsOwnedByProfile == false`

**Query 2 — Data API** (LicenseId only, since Tooling drops it):

    dispatch_readonly(
      url="/services/data/v67.0/query",
      queryParams={ "q":
        "SELECT Id, LicenseId
         FROM PermissionSet WHERE Id = '<created-id>'" })

Must satisfy:
- `LicenseId == <dataCloudPslId>` (from 0A.1)

If any check in either query fails, STOP and report the exact mismatch. Do
NOT proceed to 0A.3.

#### 0A.3 Configure the permset (skip already-satisfied pieces on reuse)

Each sub-step reads the current org state first and only writes deltas.

**(a) System Permissions.** Required labels:
  - `Grant users permission to sfDrive`
  - `Create, edit, and delete knowledge spaces`

Resolve each label to its actual `Permissions*` API field name from the live
org by GETting `/services/data/v67.0/sobjects/PermissionSet/describe` via
`dispatch_readonly` and locating the boolean field whose `label` matches
exactly. If MCP does not expose a route that can enable a given System
Permission on the permset (i.e. the resolved `Permissions*` field is not
patchable via a `PermSets` SOR step reachable through MCP), leave that
System Permission unset for this run, record the label in
`state.artifacts.notebook-ai.step0A.systemPermissionsSkipped`, and continue.
Do NOT introduce a new transport (curl / apex / CLI) just to enable it.

Where MCP does support the write, PATCH
`/services/data/v67.0/sobjects/PermissionSet/{Id}` with the resolved
`Permissions*` field(s) set to `true` (the `edit-user-permissions` step in
the `PermSets` SOR).

**(b) Object Settings.** For each of these 14 objects, ensure an
`ObjectPermissions` row exists on the permset with the exact flags listed.
The Setup-UI label on the left and the `ObjectPermissions.SobjectType`
picklist value on the right are the canonical mapping — verified during
validation against the `ObjectPermissions.SobjectType` restricted-picklist
values:

    Setup label                                   SobjectType (picklist value)         Flags
    -------------------------------------------  -----------------------------------  --------------------------------
    Data Knowledge Dataspace Scopes               DataKnowledgeDataspcScope            R, C, E, D, VA, MA
    Data Knowledge Libraries                      DataKnowledgeLibrary                 R, C, E, D
    Data Knowledge Library Source Relationships   DataKnowledgeLibrarySrcRel           R, C, E, D, VA, MA
    Data Knowledge Sources                        DataKnowledgeSource                  R, C, E, D, VA, MA
    Data Knowledge Space Definitions              DataKnowledgeSpaceDef                R, C, E, D
    Data Knowledge Space Library Relationships    DataKnowledgeSpcLibRel               R, C, E, D, VA, MA
    Data Model Domain Capability Usage            DataModelDomainCapUsage              R, VA
    Data Model Fields                             MktDataModelField                    R, VA
    Data Model Objects                            MktDataModelObject                   R, VA
    Data Model Taxonomies                         DataModelTaxonomy                    R, VA
    Data Object Categories                        DataObjectCategory                   R, VA
    Data Semantic Search Definitions              DataSemanticSearchDef                R, VA
    Data Space Definitions                        DataSpaceDefinition                  R
    Data Spaces                                   DataSpace                            R

Portability rule — DO NOT guess `SobjectType` names and DO NOT probe candidate
names by POSTing rows to see which one is accepted. Before writing any
`ObjectPermissions` row, fetch the live picklist through MCP:

    dispatch_readonly(
      url="/services/data/v67.0/sobjects/ObjectPermissions/describe",
      method="GET")

Locate the `SobjectType` field's `picklistValues` array and build the set of
active values (`active == true`). For every mapping above:
- if the expected `SobjectType` is present in the active picklist, use it;
- if absent, STOP and report that exact mapping as unsupported on the target
  org — do NOT try alternate names.

**Mandatory write order — dependency-safe (do NOT reorder).** Salesforce
enforces object-permission dependency chains at write time and rejects a
POST whose declared permissions depend on another SobjectType that has not
yet been granted on the same permset. The documentation table above is
alphabetized for readability and IS NOT a valid write order — verified during
validation, where writing in table order fails with `FIELD_INTEGRITY_EXCEPTION`
on `DataModelDomainCapUsage`, `MktDataModelObject`, and `DataObjectCategory`.

The required dependency chain is:

    DataModelTaxonomy
      → DataObjectCategory
        → MktDataModelObject
          → DataModelDomainCapUsage

and `DataModelDomainCapUsage` additionally requires at least one supported
sibling such as `DataSemanticSearchDef`, so `DataSemanticSearchDef` must be
configured before it.

Process rows in this exact order. Do NOT discover dependency order by
intentionally causing failed POSTs — this order is the canonical fix.

1. `DataModelTaxonomy`
2. `DataObjectCategory`
3. `MktDataModelObject`
4. `MktDataModelField`
5. `DataSemanticSearchDef`
6. `DataSpace`
7. `DataSpaceDefinition`
8. `DataModelDomainCapUsage`

Then process the remaining independent Data Knowledge objects (no ordering
constraint between them):

9. `DataKnowledgeDataspcScope`
10. `DataKnowledgeLibrary`
11. `DataKnowledgeLibrarySrcRel`
12. `DataKnowledgeSource`
13. `DataKnowledgeSpaceDef`
14. `DataKnowledgeSpcLibRel`

Use the `PermSets` SOR's `list-object-permissions` /
`add-object-permission` / `change-object-permission` steps through MCP
`dispatch_readonly` (SOQL on `ObjectPermissions` WHERE `ParentId={Id}`) and
`dispatch` (POST/PATCH on
`/services/data/v67.0/sobjects/ObjectPermissions[/{rowId}]`). Read each
object's current row first; POST if missing, PATCH by row Id if flags differ,
leave alone if already correct. Flags per row are taken from the mapping
table above.

**(c) Agent Access → `Notebook AI Agent`.** Resolve the Notebook AI Agent
BotDefinition Id from the target org via the Data API (Tooling API returns
`INVALID_TYPE` for `BotDefinition` on Data Cloud orgs — verified during
validation):

    dispatch_readonly(
      url="/services/data/v67.0/query",
      queryParams={ "q":
        "SELECT Id, DeveloperName, MasterLabel, Type FROM BotDefinition
         WHERE DeveloperName = 'NotebookAIAgent'
            OR MasterLabel = 'Notebook AI Agent'
         LIMIT 1" })

If 0 rows, STOP and report — the Notebook AI Agent has not been provisioned
on this org yet.

Grant access via the `PermSets` SOR's `enable-setup-entity-access` step —
`SetupEntityAccess` is boolean-by-existence (row present = access granted).
`SetupEntityType` is auto-derived from the `0Xx` key prefix per the SOR; do
NOT send it.

    dispatch(
      url="/services/data/v67.0/sobjects/SetupEntityAccess",
      method="POST",
      body={
        "ParentId": "<permSetId>",
        "SetupEntityId": "<botDefinitionId>"
      })

Read current `SetupEntityAccess` WHERE `ParentId={permSetId}` AND
`SetupEntityId={botDefinitionId}` first; if a row already exists, skip
the POST (idempotent reuse).

**MCP timeout handling (mandatory — MCP-only).** If the `dispatch` POST
returns an ambiguous MCP transport error such as `operation timed out`,
`API_ERROR`, or a 5xx with no body — the server may or may not have created
the row. This scenario was observed during validation. Handle it strictly
through the `salesforce-headless-360` MCP server, without switching
transports:

1. Wait 2–3 seconds.
2. Query the exact row via `dispatch_readonly` against
   `/services/data/v67.0/query` with:
       SELECT Id FROM SetupEntityAccess
       WHERE ParentId = '<permSetId>' AND SetupEntityId = '<botDefinitionId>'
3. If the query itself also fails / times out, back off and retry the
   verification query up to 3 times total (2s, 4s, 8s pauses).
4. If any verification query returns 1 row → treat the original POST as
   success; capture the row Id.
5. If a verification query returns 0 rows → retry the idempotent POST
   exactly ONCE. Then run one final verification query.
6. If MCP is still ambiguous or the row cannot be confirmed after the
   bounded retries above, STOP and report the timeout. Do NOT switch
   transports (no `sf data query`, no direct curl against Salesforce, no
   Apex, no `sf org display` token extraction) — Step 0A remains MCP-only
   by design.

**(d) Assign to `{runningUserId}`.** Query current
`PermissionSetAssignment` WHERE `PermissionSetId={Id}` AND
`AssigneeId={runningUserId}` via Tooling. If 0 rows, POST to
`/services/data/v67.0/tooling/sobjects/PermissionSetAssignment` with
`{AssigneeId, PermissionSetId}` (the `PermSets` SOR's `assign-users` step).
`DUPLICATE_VALUE` on retry is a no-op — treat as success.

#### 0A.4 Verification gate (STOP on any failure — do NOT proceed to Step 2)

Re-read the org state via `dispatch_readonly` and confirm all of:

1. `PermissionSet` with `Name='Notebook_AI_User_Access'` exists.
2. Its `LicenseId == <dataCloudPslId>` (from 0A.1).
3. Both required System Permissions read back as `true` OR were recorded
   in `state.artifacts.notebook-ai.step0A.systemPermissionsSkipped` because
   MCP did not expose a supported write for them.
4. Every `ObjectPermissions` row from the 14-object spec above matches
   the required flags exactly.
5. `SetupEntityAccess` row exists linking the permset to the Notebook AI
   Agent BotDefinition Id resolved in 0A.3(c).
6. `PermissionSetAssignment` row exists linking `{runningUserId}` to the
   permset.

If any of 1, 2, 4, 5, or 6 fails, STOP and report the exact blocker
(which check failed, current vs expected). Do NOT fall back to notebook
creation. If item 3 could not be enabled through MCP, that alone is not
a blocker — proceed with the skipped-permissions list captured in
durable-state artifacts.

On success, proceed to Step 2.

### 2. Find-or-create the notebook (idempotent)

First, list existing notebooks via MCP:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v66.0/ssot/knowledge-space",
  method="GET"
)
```

Response contains `knowledgeSpaces[]` — each entry has `label`,
`developerName`, `knowledgeSpaceId`. Match the requested `label` against
existing `label` values (case-insensitive). If found:

- Use the existing `knowledgeSpaceId`. Skip creation. Report: `Reusing
  existing notebook "{label}" (id={knowledgeSpaceId})`.

If not found, create it via MCP:

```
mcp__salesforce-headless-360__dispatch(
  url="/services/data/v66.0/ssot/knowledge-space",
  method="POST",
  body={
    "label": "{label}",
    "developerName": "{developerName}",
    "description": "{description}",
    "dataSpace": "default"
  }
)
```

Endpoint is `/ssot/knowledge-space` (NOT `/connect/ssot/knowledge-space`).
Success (HTTP 200) returns the new `knowledgeSpaceId`. MCP injects the bearer
token and `Content-Type: application/json` — do not set them yourself.

### 3. Resolve the Personal Library ID

Personal Library auto-exists when the notebook is created. Fetch the
notebook's details via MCP:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v66.0/ssot/knowledge-space/{knowledgeSpaceId}/details",
  method="GET"
)
```

In the response, find the library where `knowledgeCategory == "PERSONAL"`.
Use its `knowledgeLibraryId` (the `1aQ...` ID) for the upload steps.

### 4. Upload files — 3-step presigned-URL flow

#### Step 4 recovery contract (mandatory — read before executing anything in Step 4)

Step 4 is designed to be crash- and re-entry-safe. A client/tool timeout,
MCP transport error, or interrupted turn may still terminate the current
invocation — but it MUST NOT cause loss of Notebook AI progress, duplicate
indexing jobs, or a restart from Step 2.

**On any retry, resume, interrupted turn, MCP timeout, or ambiguous
client/tool failure, ALWAYS re-enter through Step 4b. Do not restart the
workflow from scratch. Query `/details`, classify the 7 allowlisted files,
and execute only the remaining delta.**

The Step 4b classification is authoritative:

- `INDEXED` → skip.
- `IN_PROGRESS` / `PROCESSING` → do not upload; do not re-issue
  `index-files`; poll.
- missing from `/details` → **needs-upload.**
- `FAILED` → STOP and report the exact filename and its `fileStatus`.

Note: `/details` becomes authoritative for a given file **only once
indexing has begun** for it. Do NOT assume `/details` can prove whether a
raw S3 PUT already landed for a file that indexing has not yet been
asked to process — Salesforce may not expose the uploaded object until
`index-files` is called for it. That is why the recovery flow discards
stale presigned URLs and requests fresh ones for anything still
classified as "missing"; re-PUTting a file that already made it to S3 is
harmless (idempotent overwrite by the same object key).

Parent installer / orchestrator note: a hard client/tool timeout can
still terminate the current invocation of this skill. The parent should
retry or resume `/notebook-ai` independently on its next turn — Step 4b
will reconcile against org state and continue from the remaining delta.
It should NOT cancel unrelated parallel skills solely because
`/notebook-ai` needs recovery.

#### 4a. Filter to supported types

Only `.pdf`, `.txt`, `.html` are accepted. Skip everything else
(`.csv`, `.docx`, etc.) with a warning rather than failing the run.

#### 4b. Pre-upload idempotency check (STOP-and-skip when the org already has the files)

Before requesting any presigned URLs, GET the notebook's `/details` for
the target library:

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v66.0/ssot/knowledge-space/{knowledgeSpaceId}/details",
  method="GET"
)
```

Match each allowlisted filename (basename, case-insensitive) against
`libraries[].sources[].files[]` for `knowledgeLibraryId`, then classify
each file by its current `fileStatus`:

- **`INDEXED`** → **already-indexed / skip.** Do NOT re-upload, do NOT
  re-index.
- **`IN_PROGRESS` or `PROCESSING`** → **in-flight / poll.** Do NOT upload
  and do NOT re-issue `index-files`. Carry into 4e's polling set.
- **missing from `/details`** → **needs-upload.** Carry into 4c/4d/4e.
- **`FAILED`** → **STOP.** Report the exact filename and its
  `fileStatus`. Do NOT auto-reupload. Retrying a FAILED file is not part
  of this skill's automatic behavior — an operator must investigate the
  underlying cause (bad bytes, wrong `filePath`, S3 PUT never landed,
  etc.) before re-running the skill.

Short-circuit rules for the non-FAILED cases:

- If both `needs-upload` and `in-flight` are empty → every allowlisted
  file is already `INDEXED`. Step 4 is complete. Skip 4c, 4d, and 4e's
  POST; go straight to Step 5 (verification read).
- If `needs-upload` is empty but `in-flight` is not → skip 4c and 4d.
  Enter 4e's polling loop directly, keyed on the in-flight files.
- Otherwise → continue at 4c with only the `needs-upload` subset.

This step makes resume-after-interrupt safe and keeps repeat invocations
cheap. It does not introduce a retry policy for genuinely failed
indexing — that remains a hard stop.

#### 4c. Batch-get presigned URLs (max 5 files per call)

Request presigned URLs only for the `needs-upload` files from 4b.

For each chunk of up to 5 files, request presigned URLs via MCP:

```
mcp__salesforce-headless-360__dispatch(
  url="/services/data/v66.0/ssot/knowledge-space/presigned-urls",
  method="POST",
  body={
    "libraryId": "{knowledgeLibraryId}",
    "fileNames": ["doc1.pdf", "doc2.pdf"]
  }
)
```

Returns `{"presignedUrls": [<url>, <url>]}` in the same order.

**Hard limit:** `Files uploaded cannot be more than: 5` per call. Batch.

**Transient 500 handling (bounded, endpoint-specific).** The
`/ssot/knowledge-space/presigned-urls` endpoint occasionally returns
`HTTP 500 INTERNAL_ERROR` transiently — observed during validation, where
the immediate retry succeeded. On this specific error for THIS endpoint
only:

- wait 2 seconds;
- retry that batch exactly once;
- if the retry also fails, STOP and surface the error;
- do NOT convert this into an unbounded retry loop;
- do NOT apply this retry pattern to other endpoints.

**Presigned URLs are ephemeral credentials, not durable state.**
Presigned URLs MUST NEVER appear in:

- `Bash` command strings;
- heredocs;
- generated Python or shell source (they must be read from a file at
  runtime, never baked into a script);
- environment-variable command strings;
- logs or user-visible output;
- `.claude/state/install-state.json` or any artifact persisted for other
  skills;
- `.claude/state/` at all;
- any tracked repository path.

Their only permitted locations are the transient MCP response body, the
temporary manifest file described in 4d, and the uploader's in-process
memory. They exist only for the lifetime of Step 4d.

After each successful presigned-url batch, write that batch's
`filename → URL` mapping as opaque JSON into the temporary manifest
described in 4d. Do NOT concatenate URLs into `Bash` text — even for
"just this once" inline construction. Superseded URL files (e.g. from a
prior interrupted attempt) MUST be deleted before writing the fresh
manifest.

#### 4d. PUT each file via a temporary manifest + small uploader loop

**S3 is not a Salesforce endpoint — MCP does not proxy it.** The S3 PUT
is the ONE and ONLY non-MCP HTTP call in this skill.

**Manifest file — OS/process temporary, outside the repo.**

Create a fresh per-invocation temporary location for the manifest using
the OS's temp facility (e.g. `$TMPDIR` / `%TEMP%` on Windows). Write the
manifest via the same file-writing tool the agent uses for other JSON
scratch data — do NOT construct it by echoing URLs into a shell heredoc.
Manifest path: `<tmpdir>/presigns.json`. Schema:

```
{
  "libraryId": "{knowledgeLibraryId}",
  "sourceDir": "MedTechDocuments",
  "files": [
    { "name": "doc1.pdf", "url": "<presigned url — leave &amp; escaped>" },
    ...
  ]
}
```

Constraints on the manifest and its temp directory:

- MUST live under the OS temp path (`$TMPDIR` / `%TEMP%` / `tempfile`).
- MUST NOT live under `.claude/state/`.
- MUST NOT live under any tracked repository path.
- MUST NOT be written into `install-state.json` or any other durable
  artifact.
- MUST be deleted immediately once the uploader has returned known
  results and every PUT is confirmed HTTP 200 (see "Manifest lifecycle
  & uploader-timeout recovery" below for the crash-safe case).
- No `.gitignore` change is required — the file is not inside the repo.
- Presigned URLs are NOT durable state — see 4c.

**Permanent uploader helper — [scripts/notebook-ai-s3-put.py](../../../scripts/notebook-ai-s3-put.py).**

The uploader is a permanent, checked-in helper. The invocation MUST stay
small and fixed-shape:

    python3 scripts/notebook-ai-s3-put.py "<manifest-path>"

Only the manifest path may appear in the `Bash` command. No presigned
URLs, no filename lists, no other flags. This keeps every tool-call
argument small (a fixed ~80 bytes regardless of batch size), which
avoids the payload-shape failure modes observed during validation:

1. Very large tool-use arguments dominated by URL-encoded text can
   trigger `API Error: The operation timed out.` mid-stream — a
   symptom, not a fully-proven root cause, but reproducible enough that
   we structurally avoid it.
2. Signed S3 URLs sometimes contain `'`, `` ` ``, `$`, `\` in their
   query strings, which break `Bash` heredocs (`unexpected EOF while
   looking for matching '`). Keeping URLs off the shell command line
   removes this class of failure entirely.

Helper contract (implemented in
[scripts/notebook-ai-s3-put.py](../../../scripts/notebook-ai-s3-put.py)):

1. Reads the manifest path from `argv[1]`. No hardcoded paths, no env
   vars.
2. For each entry:
   - `.replace("&amp;", "&")` on the URL — **Gotcha A** (unchanged). Not
     doing this returns S3 `403 AccessDenied: No AWSAccessKey was presented`.
   - Reads bytes from `<sourceDir>/<name>`.
   - PUTs with the raw file bytes and **no extra headers** — **Gotcha B**
     (unchanged). Any extra header (including `Content-Type`) breaks the
     signature and returns `403 SignatureDoesNotMatch`.
   - Uses a bounded per-file network timeout (default 60s).
3. Emits one status line per file: `<http_status>\t<name>\t<error-or-blank>`.
4. Exits `0` iff every PUT returned HTTP 200; exits non-zero otherwise.
5. Internal parallelism (small thread pool) is fine — the allowlist is
   only 7 files. The outer invocation is synchronous.

**Execution model — foreground and synchronous.**

Invoke the uploader through a foreground `Bash` call. Do NOT set
`run_in_background`. The skill must know whether every PUT completed
before advancing to 4e or writing durable state — background execution
would defeat that guarantee.

If the `Bash` tool supports a configurable per-call timeout, set a
reasonable bounded timeout for this uploader call (e.g. large enough to
cover all 7 file PUTs plus a margin). Resilience in Step 4 does not
depend on this timeout; it comes from idempotent recovery via Step 4b.
Do NOT document or rely on an MCP-side timeout parameter — the
`salesforce-headless-360` tool schema does not expose one.

**Manifest lifecycle & uploader-timeout recovery.**

*Normal path.*

1. Create the manifest under the OS temp path.
2. Run the uploader (foreground).
3. If the uploader returns a complete result set AND every PUT status is
   HTTP 200, delete the entire `<tmpdir>` immediately.
4. Continue to 4e (`index-files`).

*Uploader tool call itself times out (client/tool ambiguous timeout).*

Do NOT treat Step 4 as permanently failed. Do NOT append `"notebook-ai"`
to `completedSkills`. Specifically:

- Do NOT mark Step 4 failed.
- Do NOT re-issue the uploader on the same manifest inside the same
  turn — that turn is over.
- Any recovery context that still exists on disk from the interrupted
  attempt (temp manifest, partial results) MAY be left in place for the
  next invocation to inspect, but it MUST NOT be relied upon: it is
  advisory only.

On the **next** invocation of this skill, the durable-state wrapper at
the top will notice that `notebook-ai` is not in `completedSkills` and
re-enter the workflow. The Step 4 recovery contract at the top of Step 4
then applies verbatim:

- ALWAYS begin at Step 4b.
- Classify each of the 7 allowlisted files against `/details`.
- If a file is already `IN_PROGRESS`/`PROCESSING`/`INDEXED`, server-side
  progress exists — do NOT re-upload it.
- If a file is still missing, discard ANY stale/old presigned URLs on
  disk (delete the old temp manifest first) and request FRESH presigned
  URLs for exactly that missing subset, then re-run the uploader on
  that fresh subset.
- Do NOT attempt to reuse a presigned URL based on manually calculated
  expiry — always mint fresh URLs for the missing subset.

*Non-zero uploader exit with a complete result set.*

Delete the manifest (no presigned URLs may survive on disk once results
are known), STOP Step 4, surface the failing filename(s) and their HTTP
status, and return failure. Do NOT proceed to 4e; do NOT append
`"notebook-ai"` to `completedSkills`. The next invocation will re-enter
via Step 4b and reconcile against `/details`.

**Cleanup on known outcomes.** Once the uploader has returned a
complete result set (success OR non-zero exit), delete the entire
`<tmpdir>` before returning. Only the ambiguous client/tool timeout
case may leave the tmpdir behind — and even then, only as advisory
recovery context; the next invocation is not required to consume it and
will re-mint URLs for anything still missing.

#### 4e. Trigger indexing — with hardened ambiguous-error handling

```
mcp__salesforce-headless-360__dispatch(
  url="/services/data/v66.0/ssot/knowledge-space/index-files",
  method="POST",
  body={
    "knowledgeArtifactId": "{knowledgeLibraryId}",
    "knowledgeArtifactSource": "FILE_UPLOAD",
    "knowledgeSourceFilesList": [
      {
        "fileName": "doc1.pdf",
        "filePath": "collections/{knowledgeLibraryId}/doc1.pdf",
        "fileType": "PDF"
      }
    ]
  }
)
```

Send ONLY the `needs-upload` files from 4b — never files already
`INDEXED`, never files already `IN_PROGRESS`/`PROCESSING`, and never
files in `FAILED` (which already stopped the skill in 4b).

`filePath` MUST be `collections/{knowledgeLibraryId}/{fileName}` —
NOT `knowledge_space/collections/...`, NOT a ContentDocumentId.

Small files come back `fileStatus: INDEXED` immediately. Larger files
may go through `PROCESSING` first.

**⚠️ Slow response — this call can take 60–180 seconds to return.** A
clean slow response is normal. Do NOT assume that increasing any
client-side timeout would eliminate ambiguous failures — resilience in
Step 4 comes from idempotent recovery via Step 4b, not from longer
timeouts. The fallback below handles the two ambiguous cases where the
client never gets a clean HTTP 2xx.

**Ambiguous-error handling (mandatory).**

Treat BOTH of the following as ambiguous — the server may already have
started indexing even though the client never saw a clean response:

- **MCP transport error / timeout** — `operation timed out`, `API_ERROR`,
  disconnected socket, or any MCP-layer error where no HTTP status is
  returned.
- **HTTP 5xx / Salesforce `INTERNAL_ERROR`** — any response with
  `status_code >= 500` (500, 502, 503, 504, or an `INTERNAL_ERROR` body).
  Observed: `POST /index-files` returns HTTP 500 while indexing has in
  fact already begun on the server.

On EITHER case, do NOT immediately retry `index-files`. Instead:

1. Wait ~5 seconds.
2. GET `/services/data/v66.0/ssot/knowledge-space/{knowledgeSpaceId}/details`.
3. Locate the target files (the `needs-upload` set from 4b) in
   `libraries[].sources[].files[]`.
4. Inspect `fileStatus`:
   - Any target file is `IN_PROGRESS` or `PROCESSING` → indexing has
     started server-side. Do NOT retry `index-files`. Enter the polling
     loop below.
   - All target files are `INDEXED` → success. Skip polling; go to Step 5.
   - Any target file is `FAILED` → STOP Step 4. Report the exact
     filename(s) and their `fileStatus`. Do NOT retry `index-files`, and
     do NOT re-upload — same policy as 4b.
   - NONE of the target files appear in `/details` at all → indexing
     never started. In this narrow case only, re-issue `index-files`
     EXACTLY ONCE. Apply the same ambiguous-error handling to the retry.
     Never loop the re-issue.

**Polling loop (bounded, ~5 minutes).**

When one or more files are `IN_PROGRESS` / `PROCESSING`, poll `/details`
until every target file reaches a terminal state (`INDEXED` or `FAILED`).

- Poll interval: 10 seconds.
- Poll budget: 30 polls (~5 minutes).
- **Terminal-success:** every target file has `fileStatus == INDEXED`.
  Step 4 succeeds; proceed to Step 5.
- **Terminal-failure:** any target file has `fileStatus == FAILED`.
  STOP and report the exact filename(s). Do NOT retry.
- **Budget-exceeded:** after ~5 minutes with at least one file still
  non-terminal, STOP and report the stuck filename(s). Do NOT re-issue
  `index-files` — the server still owns the job and a re-issue can spawn
  a duplicate.

The successful path — HTTP 500 (or transport timeout) on `index-files`
but `/details` shows indexing already in flight, then every file
reaching `INDEXED` on poll — has been observed on real runs and is
treated as Step 4 success.

Do NOT append `"notebook-ai"` to `completedSkills` (in the Step N-final
durable-state wrapper) unless every required target file — the union of
`already-indexed`, `in-flight` (poll-resolved), and `needs-upload`
(uploaded and index-resolved) — has `fileStatus == INDEXED`.

### 5. Verify (optional but recommended)

```
mcp__salesforce-headless-360__dispatch_readonly(
  url="/services/data/v66.0/ssot/knowledge-space/{knowledgeSpaceId}/details",
  method="GET"
)
```

Each file should appear in `libraries[].sources[].files[]` with
`fileStatus: INDEXED`.

### 6. Display the result

```
✓ Notebook "{label}" ready
  Notebook ID:  {knowledgeSpaceId}
  Library ID:   {knowledgeLibraryId} (Personal Library)
  Files indexed: N/M (skipped K unsupported)

  - doc1.pdf                INDEXED
  - doc2.pdf                INDEXED
  - data.csv                SKIPPED (unsupported type)
```

## Reference implementation

This skill is executed by the agent step-by-step, invoking
`mcp__salesforce-headless-360__dispatch` / `dispatch_readonly` for the
Connect API calls in Steps 1–5, and the permanent uploader helper
[scripts/notebook-ai-s3-put.py](../../../scripts/notebook-ai-s3-put.py)
for the S3 PUT loop inside Step 4d. Presigned URLs are read from a
temporary manifest file — never inlined into a `Bash` command or a
generated script. The pattern is:

```pseudo
def setup_notebook(org_alias, label, src_dir, description="", developer_name=None):
    verify_mcp_session()                                          # Step 1
    provision_notebook_ai_user_access_permset_via_mcp(            # Step 0A
        running_user_id)
    ksid  = find_or_create_notebook_via_mcp(                      # Step 2
        label, developer_name, description)
    libid = resolve_personal_library_via_mcp(ksid)                # Step 3
    upload_files_via_mcp_and_s3(libid, src_dir)                   # Step 4
    return ksid, libid
```

Every Salesforce Connect API call goes through the `salesforce-headless-360`
MCP server. To deploy to multiple orgs, re-run `/mcp-setup` for each org
alias so the MCP session is pinned to the correct org, then invoke this
skill. Each run is independent — nothing about the notebook or library
carries across orgs (the IDs are always org-scoped).

## Error handling

Step 0A (permission set provisioning):
- **`DUPLICATE_VALUE` on create-permission-set** — the row already exists.
  Re-run the 0A.2 existence probe and fall through to the reuse branch;
  do NOT surface as a failure.
- **Existing `Notebook_AI_User_Access` row has `LicenseId != <dataCloudPslId>`
  or `LicenseId == null`** — `LicenseId` is immutable per the `PermSets` SOR.
  STOP and report the mismatch; the operator must delete the stale row before
  this skill can proceed.
- **Missing sObject on Object Settings resolution** — one of the 14
  documented objects did not describe against the target org. STOP and
  report the missing sObject; do NOT skip it.
- **System Permission label unresolved OR no MCP write route** — record
  the label in `state.artifacts.notebook-ai.step0A.systemPermissionsSkipped`
  and continue. Do NOT introduce a new transport (curl / apex / CLI) to
  work around it.
- **Notebook AI Agent BotDefinition not found** — SOQL on `BotDefinition`
  returned 0 rows for `DeveloperName='NotebookAIAgent'`. STOP and report;
  the Notebook AI Agent has not been provisioned on this org yet.
- **Verification gate failure (0A.4 items 1, 2, 4, 5, 6)** — STOP and
  report exactly which check failed and its current vs expected state.
  Do NOT proceed to Step 2.

Notebook step:
- **401 Unauthorized** — MCP session invalid. STOP the skill and report:
  `"salesforce-headless-360 MCP session invalid for {orgAlias}. Run /mcp-setup before invoking notebook-ai."` Do NOT attempt `sf org login web` as a workaround — the MCP OAuth session is separate from the CLI login.
- **403 Forbidden** — ask admin about Data Cloud + Notebook AI permsets.
- **400 `INVALID_INPUT: No Knowledge Space Config Found For the DataSpace`** —
  Notebook AI is not provisioned in the target org's data space. This is an
  org-admin step (Setup → Notebook AI → Enable, or the equivalent feature-
  provisioning flow). The skill CANNOT create the knowledge-space config;
  the operator must enable Notebook AI on the org first. **Do NOT retry** —
  the error will persist until the org admin acts. Verified 2026-07-03
  against `targetOrg1July` (Data Cloud was enabled but Notebook AI was not).
- **400 on POST /knowledge-space (other messages)** — check label (1–255
  chars) and developerName (alphanumeric + underscore only). Salesforce
  auto-suffixes the developerName with a unique ID on creation (e.g.
  `Diagnosis` → `Diagnosis_005d200000QTTqr`); do not treat that as a
  duplicate/error.

Upload step:
- **`Files uploaded cannot be more than: 5`** — batch smaller. The
  skill handles this for you when batching is implemented in code.
- **S3 `403 AccessDenied: No AWSAccessKey was presented`** — you forgot
  to unescape `&amp;`. See Gotcha A.
- **S3 `403 SignatureDoesNotMatch`** — you sent a Content-Type header.
  See Gotcha B.
- **`index-files` returns `fileStatus: FAILED`** — the file was never
  PUT to S3, or the `filePath` doesn't match
  `collections/{libraryId}/{fileName}`.
- **`Unsupported file type 'csv'`** — Notebook AI only accepts PDF,
  TXT, HTML. The skill should pre-filter and skip with a warning.

## Transport rules (CRITICAL)

- 🚨 **ALWAYS use `salesforce-headless-360` MCP** for Salesforce Connect
  API calls — `mcp__salesforce-headless-360__dispatch` for writes,
  `mcp__salesforce-headless-360__dispatch_readonly` for GETs.
- 🚨 **NEVER shell out to `curl` for Salesforce endpoints.** The one
  exception to "no non-MCP HTTP" is the S3 PUT in Step 4d — S3 is an
  external service that MCP does not proxy — and even that PUT is
  driven from [scripts/notebook-ai-s3-put.py](../../../scripts/notebook-ai-s3-put.py),
  not from ad-hoc `curl`.
- 🚨 **NEVER call `sf apex run` or use Apex to hit these APIs.**
- 🚨 **NEVER extract an access token via `sf org display` and inject an
  `Authorization: Bearer` header yourself.** MCP holds the OAuth session
  server-side and injects the token transparently. Doing token
  extraction defeats the OAuth refresh guarantee and re-introduces the
  bugs this rewrite was meant to fix.
- 🚨 **NEVER use Playwright / `mcp__plugin_playwright_playwright__*` /
  `browser_navigate` / any browser or UI automation anywhere in this
  skill — not for Step 0, not for the beta toggle, not as a fallback if
  the wrapper fails, not to verify the flag from the Setup UI.** The
  wrapper `scripts/enable-notebook-ai.sh` is the ONLY sanctioned toggle
  path for Step 0. If it fails, Step 2's `POST /ssot/knowledge-space` is
  the authoritative correctness gate: `HTTP 201` = beta is on, `HTTP 400
  "No Knowledge Space Config Found For the DataSpace"` = beta is off,
  STOP and hand off to the operator with the manual-fix instructions in
  the Error handling section. Do NOT open
  `/lightning/setup/BetaFeaturesSetup/home` in a browser under any
  circumstance.
- `sf` CLI usage is limited to Step 0's `scripts/enable-notebook-ai.sh`
  wrapper (internal Aura endpoint not reachable via Connect API).

## Source of truth

The 3-step upload flow was confirmed by Arsheen Chugh (Notebook AI
team) in Slack on 2026-06-24:

> Get Presigned URL → Upload file to S3 → Index the file

The find-or-create pattern for notebooks is standard idempotent
behavior — useful for multi-org rollouts where the same notebook label
is reused across orgs.

**Transport rewrite (2026-07-28):** the API layer was migrated from
`curl` + `sf org display` bearer-token injection to the
`salesforce-headless-360` MCP server (`dispatch` / `dispatch_readonly`).
Endpoints and payloads are unchanged — only the transport moved. The S3
PUT in Step 4d remains the sole non-MCP HTTP call because S3 is outside
Salesforce's proxy surface.

## Testing history

- **2026-06-24 — source-org validation.** The 3-step upload flow was
  confirmed end-to-end in one internal org: knowledge-space ID
  `1aMd200000039wP` (label `Diagnosis`), Personal Library
  `1aQd20000003EWH`. All uploaded PDFs finished with
  `fileStatus: INDEXED`. **These IDs are org-scoped** — every org this
  skill runs against will mint fresh IDs. The line is kept here for
  historical trace only; it is NOT a value any operator should copy or
  match against.

- **2026-08-31 — Step 0 descriptor rename observed during validation.**
  Salesforce renamed the Aura action from `enableBetaFeatureWithoutCascade`
  to `enableBetaFeature`. The old descriptor returned `HTTP 200` with an
  empty `actions[]` array — a silent no-op that a prior subagent
  misinterpreted as "already enabled" and then reached for Playwright as
  a fallback (the exact failure mode the 🚨 ban in Step 0 now blocks).
  Wrapper descriptor updated in [scripts/enable-notebook-ai.sh](../../../scripts/enable-notebook-ai.sh);
  a new `STALE_DESCRIPTOR` parser branch now fails loudly instead of
  reporting `UNKNOWN_SHAPE` when Salesforce next renames the endpoint.

- **2026-08-31 — Step 0 idempotency validated during a full run.** Wrapper
  reported `aura_state=SUCCESS` and Step 2's `POST /ssot/knowledge-space`
  returned `HTTP 201` (successful notebook creation) — end-to-end proof
  the toggle path works CLI-only, no browser. Also confirmed the
  original probe-first idea (using `GET /ssot/knowledge-space` to
  short-circuit) is unreliable: that endpoint returns
  `HTTP 200 {"knowledgeSpaces":[]}` on both enabled and disabled orgs,
  so Step 0 must ALWAYS run the wrapper and rely on Step 2 as the
  authoritative gate.

**File count note:** the earlier validation run uploaded a larger set of
PDFs. The current allowlist under "Files to upload — STRICT ALLOWLIST"
is the authoritative list (7 files) — the earlier "all N PDFs" phrasing
referred to whatever the source directory contained at that time. If the
allowlist in this SKILL and the files on disk agree, ignore any older
numeric claims elsewhere.

- **Step 4 uploader-timeout recovery — observed during validation.** A
  live run terminated with `API Error: The operation timed out.` at the
  moment the agent was about to write a temp manifest and launch the S3
  uploader. On next invocation, Step 4b was re-entered, `/details`
  showed `sources: []` (indexing had not started, so `/details` could
  not confirm S3 state), all 7 files were re-classified as
  **needs-upload**, stale presigned URLs were discarded, fresh URLs
  were minted per the max-5 batching rule (batch 2 hit the documented
  transient `HTTP 500` on `/presigned-urls`; the bounded 2-second retry
  succeeded), all 7 S3 PUTs returned HTTP 200, `POST /index-files`
  returned `HTTP 500` (ambiguous) but the ambiguous-error path saw all
  7 files as `IN_PROGRESS` on the next `/details` and polling resolved
  them to `INDEXED` on the first 10-second poll. Zero duplicate index
  jobs; zero restart from Step 2. That end-to-end resilience is exactly
  what the Step 4 recovery contract at the top of Step 4 encodes.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"notebook-ai"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.notebook-ai` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them. Step 0A outputs should land under `state.artifacts.notebook-ai.step0A` and include at minimum: `permSetId`, `permSetName` (`"Notebook_AI_User_Access"`), `dataCloudPslId` (resolved in 0A.1), `botDefinitionId` (Notebook AI Agent), `setupEntityAccessId` (agent-access grant record), `permissionSetAssignmentId`, `reused` boolean (true when the 0A.2 probe found an existing row), and `systemPermissionsSkipped[]` (any required System Permission labels that could not be enabled through MCP). Step 0B outputs should land under `state.artifacts.notebook-ai.step0B` and include at minimum: `botDefinitionId`, `botVersionId`, `activated` (bool — true only when this run flipped runtime state to Active via `POST /connect/bot-versions/{id}/activation`), `alreadyActive` (bool — true when `GET .../activation` already returned `isActivated=true`), `notFound` (bool — true when the BotDefinition row did not yet exist), and `activationMessages` (array of strings — the `messages[]` field from the last activation response, empty on success).
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
