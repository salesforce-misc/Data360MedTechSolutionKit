# Claude Code Skills: Data360 Healthcare (MedTech / Pulse Sync) Solution Kit — Fully Automated Installation

**End-to-end automated installation** of the Salesforce **Data 360 Healthcare (MedTech / Pulse Sync) Solution Kit** into any Salesforce org that has Data Cloud, Health Cloud, and Agentforce licensing. Orchestrated by the `data360-healthcare-installer` sub-agent, which drives 21 specialized skills (Mode 2 full install) — or 15 (Mode 1 Data-Cloud-only) — to completion in a strict, mode-locked sequence.

The kit installs the **Pulse Sync** experience — a pacemaker/medical-device patient application that unifies patient records, IoT telemetry, clinical notes, and unstructured documents in Data Cloud, then powers Agentforce agents (Clinician Copilot + PulseSync Assistant Service Agent) on top of that unified profile. Prompt Builder, Document AI, Notebook AI, Agentforce Data Libraries, and (optionally) an Experience Cloud storefront + external-website messaging channel all get provisioned end-to-end.

**Total installation time:** ~2.5–3 hours for Mode 2 (full install). Mode 1 (Data Cloud only) is ~90 minutes. The installer runs unattended after mode selection and org credentials; you may need to approve a permission prompt occasionally depending on your Claude Code permission settings.

---

## Authoritative install spec

The **canonical order of operations** for the installer lives in [.claude/agents/data360-healthcare-installer/AGENT.md](agents/data360-healthcare-installer/AGENT.md), in the "🔒 LOCKED SKILL SEQUENCE" section. That file is the source of truth. This README is a summary aimed at first-time users; if the two ever disagree, AGENT.md wins.

**2026-08-13 change:** the previously separate `/data-cloud-related-list` skill (Playwright — creating the Pacemaker IOT related list on Contact) has been retired. That related list now ships as part of the Data Kit metadata itself and lands automatically at Step 5 (`/datakit-install`) of the sequences shown in this README. (Note: the AGENT.md LOCKED SKILL SEQUENCE keeps a documented "position 9 no-op" slot to preserve its own internal cross-references; the reader-facing numbering in this README omits that slot for clarity.)

---

## ⚙️ One-time machine prep (the installer auto-runs this for you)

The Data360 installer drives Salesforce UI through the **Playwright Claude Code plugin** (from the `claude-plugins-official` marketplace) for the handful of steps that don't have a public API (feature-enablement toggles, file-upload data streams, copy-field sync, Search Auto Updates toggle, ESA publish). It must be installed on your laptop **before** the installer can run.

**Officially supported on macOS, Windows, and Linux** (per Claude Code's [system requirements](https://code.claude.com/docs/en/setup#system-requirements)).

### How it works — zero touches in the happy path

When you say `install Data 360 Healthcare`, the installer's Step 0.0 preflight does this in the first second:

```
1. Is the Playwright plugin installed?
   ├─ YES → continue silently to mode selection ✅
   └─ NO  → auto-run setup script
            (setup.sh on macOS / Linux, setup.bat on Windows)
            │
            ├─ Script SUCCESS → "Plugin installed. Run
            │                    /reload-plugins inside Claude Code,
            │                    then re-run install Data 360 Healthcare." ✅
            │                    User runs /reload-plugins → installer resumes
            │
            └─ Script FAILS  → show the manual /plugin steps below
                               so the user can install it themselves
```

The auto-run path covers the vast majority of users — no terminal opening, no commands to copy, no decisions. Just one slash command + one retype.

### What the setup script does

```bash
1. Verify `claude` CLI is on PATH (exit with install link if missing)
2. Verify Node.js 18+ is installed (Microsoft Playwright MCP requirement)
3. Register claude-plugins-official marketplace if not already added
4. claude plugin install playwright@claude-plugins-official
5. Print "Run /reload-plugins inside Claude Code" reminder
```

---

## Installation Modes

The installer offers two mode-locked sequences. Both start with the same infrastructure block (Steps 1–11) and diverge at Step 12.

### Mode 1 — Data Cloud Solution (15 skills)

Runs everything needed for the **Data Cloud + Agentforce (Clinician Copilot + PulseSync Assistant on an internal Salesforce record page)** experience. Skips the Commerce Store / Experience Cloud site / external-website messaging block entirely.

```
1.  /feature-enablement
2.  /external-client-app-deploy
3.  /mcp-setup
4.  /base-metadata-deploy
5.  /datakit-install                     ⏳ Phase 1 ~5–10 min + Phase 2 30–45 min
                                            (ships the Pacemaker IOT Data Cloud Related List)
6.  /agentforce-data-library
7.  /notebook-ai
8.  /document-ai                         (Document AI config + Search Index + Retriever)
9.  /agent-setup-configuration
10. /prompt-template-add-retriever
11. /assign-permission-to-app
                                            🔀 Mode 1 SKIPS Mode-2-only steps here
12. /datastream-file-upload
13. /refresh-data-cloud-components
14. /copy-field-sync
15. /refresh-data-streams                (OPTIONAL — only when user explicitly opts in)
```

**Wall-clock:** ~90 minutes end-to-end (excluding the optional final step).

### Mode 2 — Data Cloud + Commerce + Experience Solution (21 skills)

Mode 1 **plus** Commerce Store, CMS workspace, Experience Cloud site, external-website Embedded Service Agent, and site branding. Recommended for the full Pulse Sync product experience.

```
1.  /feature-enablement
2.  /external-client-app-deploy
3.  /mcp-setup
4.  /base-metadata-deploy
5.  /datakit-install                     ⏳ Phase 1 ~5–10 min + Phase 2 30–45 min
                                            (ships the Pacemaker IOT Data Cloud Related List)
6.  /agentforce-data-library
7.  /notebook-ai
8.  /document-ai                         (Document AI config + Search Index + Retriever)
9.  /agent-setup-configuration
10. /prompt-template-add-retriever
11. /assign-permission-to-app
12. /experience-cloud-setup              ← Mode 2 only
13. /commerce-store-enablement           ← Mode 2 only
14. /cms-workspace-setup                 ← Mode 2 only
15. /storefront-publish                  ← Mode 2 only
16. /embed-service-agent-on-experience-site  ← Mode 2 only
17. /site-branding-setup                 ← Mode 2 only
18. /datastream-file-upload
19. /refresh-data-cloud-components
20. /copy-field-sync
21. /refresh-data-streams                (OPTIONAL — only when user explicitly opts in)
```

**Wall-clock:** ~2.5–3 hours end-to-end (excluding the optional final step).

**Rules that apply to both modes:**
- No skipping any step, no reordering. Every skill runs in its listed position. Each skill's own idempotency handles the "already provisioned" cases; the orchestrator never short-circuits.
- Mode is locked at Step 0 (before any skill is invoked). You cannot switch modes mid-run — a Mode 1 install must complete or be aborted before starting Mode 2 (and vice versa).
- The optional trailing `/refresh-data-streams` step runs ONLY if the user explicitly asks for it in their initial request (or opts in after the mandatory steps complete).

> **Note on numbering vs. AGENT.md:** the authoritative install spec at [.claude/agents/data360-healthcare-installer/AGENT.md](agents/data360-healthcare-installer/AGENT.md) retains a **retired position 9** slot as a documented no-op (`⏭️ Step 9 skipped — /data-cloud-related-list retired 2026-08-13`), so its Mode 1/Mode 2 counts read as 16/22 positions. That's a stability contract inside AGENT.md — every existing cross-reference in that file (verification table, troubleshoot rows, inline step headings, auto-chain flow diagram) still resolves. The README above shows the same sequence with the retired slot removed for readability. Both describe the same runtime behavior; the reader-facing numbering just differs.

---

## Skill details

Every skill in both modes below. In Mode 1, skills marked *(Mode 2 only)* are skipped.

| Skill | What it does | Technology |
|-------|--------------|------------|
| `feature-enablement` | Provisions Data Cloud, Einstein, Agentforce, Person Accounts; enables OAuth User-Agent + PKCE; sets Data Cloud Architect permset default data space | Metadata API + Playwright (one permset row) |
| `external-client-app-deploy` | Deploys 5 ECA components (ExternalClientApplication + 4 policy siblings) so the org can back the Data360 MCP server | Salesforce CLI |
| `mcp-setup` | Registers 4 hosted Standard MCP servers (`salesforce-sobject-all`, `salesforce-data-cloud-queries`, `salesforce-data360`, `salesforce-headless-360`) in this Claude Code session and mints OAuth tokens via PKCE. Prompts VSCode reload. | Bash + curl |
| `base-metadata-deploy` | Deploys `ps-base` (~35 components); assigns Health Cloud PSLs + permsets; activates Standard Pricebook; loads sample data (Mark Smith + Accounts / Contacts / Assets / Cases / PricebookEntries / Tasks / ServiceAppointments + Health Cloud clinical objects); enables Data Cloud copy-field permissions | Salesforce CLI + `salesforce-sobject-all` MCP |
| `datakit-install` | **Merged**: Phase 1 deploys 612 `ps-datacloud` components (KeyQualifier cleanup + managed-DLO filter + Tooling API gate); Phase 2 triggers Data Kit install/activate via `d360_datakit_deploy` (30–45 min, polls `d360_datakit_deploy_status` every 5 min). **Ships the Pacemaker IOT Data Cloud Related List on Contact.** | CLI + `salesforce-data360` MCP |
| `agentforce-data-library` | Creates 3 Agentforce Data Libraries (Pacemaker Implant Guide, Patient Clinician Discharge And Interrogation Note, Patient OP); presigned-URL S3 upload of PDFs from `MedTechDocuments/`; waits for `status=READY` | Einstein Connect API via `salesforce-headless-360` MCP + Python `requests` |
| `notebook-ai` | Enables Notebook AI beta; find-or-create knowledge space; batched file upload (Personal Library); indexes and waits `fileStatus=INDEXED` | `salesforce-headless-360` MCP + one curl S3 PUT |
| `document-ai` | Creates and activates the DAI Patient OP Document AI extraction model + Search Index + Retriever (35 output fields, active) | Bash/curl (config) + `salesforce-data360` MCP (index + retriever) |
| `agent-setup-configuration` | Creates Agent User via Apex; updates `Agentforce_Service_Agent.bot-meta.xml`; deploys `ps-post-pack`; activates `Clinician_Copilot` + `Agentforce_Service_Agent`; seeds the Clinical Care Coordinator user (Profile + UserRole ship in ps-post-pack) | Salesforce CLI + `salesforce-sobject-all` MCP |
| `prompt-template-add-retriever` | Adds retrievers to 9 prompt templates (`Monitor_Troubleshoot_Support`, `Post_Implant_Care`, `PacemakerDetailsForGuest`, `DeviceRegulatoryInfo`, `HomeMonitorSetupGuide`, `WarrantyDurationDetails`, `Patient_Implant_Op_Prompt`, `PatientSummary60Days`, `Patient30DaysSummary`); bumps version; rolls back templates to placeholders on success | `salesforce-headless-360` MCP + Salesforce CLI |
| `assign-permission-to-app` | Assigns `Pulse_Sync_App` to current user (Apex); activates `Patient_Account_Page` FlexiPage as the org-default View for Account | Salesforce CLI + Metadata API |
| `experience-cloud-setup` *(Mode 2 only)* | Creates PulseSync Commerce Store (LWR); activates site; iframe whitelist; Network deploy; deploys `ps-pd-experience-optional` (90 components); Home page Public + guest access; storePricebook; createSiteUser; CORS + CSP + TrustedURL | Salesforce CLI + `salesforce-sobject-all` MCP |
| `commerce-store-enablement` *(Mode 2 only)* | Search Automatic Updates (Playwright); enables Guest Buyer + Account-as-Buyer; runs createCommerceData + storePricebookCreation | Salesforce CLI + Playwright (one toggle) |
| `cms-workspace-setup` *(Mode 2 only)* | Creates PulseSync CMS Workspace via Connect API; attaches PulseSync + PulseSync Channel; uploads all product images via Python `requests`; publishes all; verifies every image is Published | `salesforce-headless-360` MCP + Python |
| `storefront-publish` *(Mode 2 only)* | Fuzzy-matches product ↔ CMS image (7-tier rules); inserts 24 ProductMedia rows (12 Detail + 12 List); publishes the PulseSync community; full-rebuilds the commerce search index | `salesforce-headless-360` MCP |
| `embed-service-agent-on-experience-site` *(Mode 2 only)* | Enables LiveMessage; registers Site domain; deploys `ps-embeddedservice`; whitelists Experience Cloud Sites Domain for inline frames; publishes ESA Web Deployment; refreshes Omni-Channel flow with current org IDs | Salesforce CLI + Metadata API + `salesforce-headless-360` MCP + Playwright (publish click) |
| `site-branding-setup` *(Mode 2 only)* | Configures site logo, background + left/right banner images, embedded-messaging chat icon in storefront footer — ALL in one retrieve + one deploy + one publish | Metadata API |
| `datastream-file-upload` | Uploads `pacemaker_iot_data.csv` to the Data Stream File Upload connector via Playwright with an Aura-layer payload interceptor that strips restricted `advancedAttributes` keys | Playwright + Aura interceptor |
| `refresh-data-cloud-components` | Refreshes Identity Resolution (Unify Patient IOT Data), 2 Calculated Insights (Pacemaker Latest Transmission, Pacemaker Patient Health Summary), and 1 Segment (Anomalous Pacemaker Battery) sequentially; polls each to SUCCESS | `salesforce-data360` MCP |
| `copy-field-sync` | Starts Pacemaker Patient Health Summary + Unified Individual copy-field syncs on Contact (fire-and-forget; no polling) | Playwright |
| `refresh-data-streams` *(OPTIONAL — user opt-in)* | Fires refresh for 17 SalesforceDotCom-transported Data Streams (10 core CRM + 7 Health Cloud) via `scripts/refresh-datastreams.sh`; polls each via `d360_datastream_get` | Bash + `salesforce-data360` MCP |

---

## Prerequisites

### Required Software
- **Salesforce CLI** (`sf` command) — v2.56.7 or higher (`sf -v` to verify)
- **Node.js 18+** — required by the Playwright Claude Code plugin
- **Git** — for repo clone
- **Python 3** — used by a handful of skills for JSON parsing and S3 uploads (e.g. `cms-workspace-setup`, `agentforce-data-library`)
- **Claude Code** (VS Code extension or CLI) with the [`playwright`](https://github.com/anthropics/claude-plugins-official) plugin registered

### Required Salesforce licenses / features
- **Data Cloud**
- **Health Cloud** + **Health Cloud Platform** (PSLs)
- **Sales Cloud**, **Service Cloud**
- **Einstein / Agentforce** (Agent, Copilot, Prompt Builder, Agentforce Data Library, Agentforce Studio)
- **Document AI**, **Notebook AI**
- **Person Accounts** enabled
- **Experience Cloud + Commerce** (Mode 2 only)

### Required user permissions
- **System Administrator** profile (or equivalent — Manage Data Cloud, Customize Application, Modify All Data, Author Apex, Manage Profiles and Permission Sets)
- **Org authentication** via `sf org login web -a <alias>` (or the installer will walk you through it)

### Repository fingerprint (the installer detects these)
```
MedTechClaudeDeployment/            # (or any folder name — installer detects by contents, not name)
├── .claude/
│   ├── agents/data360-healthcare-installer/AGENT.md   # authoritative install spec
│   ├── skills/                    # 21 skill folders (one per active skill in Mode 2)
│   └── README.md                  # this file
├── ps-base/                       # base app metadata (~35 components)
├── ps-datacloud/                  # 612 Data Kit components
├── ps-eca/                        # External Client App (5 components)
├── ps-post-pack/                  # Agent package + Care Coordinator profile/role
├── ps-embeddedservice/            # Mode 2 — Embedded Service Agent bits
├── ps-pd-experience-optional/     # Mode 2 — Experience Cloud additions (90 components)
├── MedTechDocuments/              # PDFs + pacemaker_iot_data.csv
├── scripts/                       # Apex + shell utilities
└── sfdx-project.json
```

---

## Quick Start

### One-command installation (recommended)

From the repository root inside VS Code with Claude Code open:

```
Install Data 360 Healthcare Installer into Alias: <YOUR_ALIAS> Username: <YOUR_USERNAME> Password: <YOUR_PASSWORD>
```

The `data360-healthcare-installer` sub-agent picks up the request, runs its Step 0 mode-selection prompt (Mode 1 = Data Cloud only / Mode 2 = full install with Commerce + Experience), and then auto-chains through all 22 skills without asking for confirmation between steps. It will stop and surface any hard error; otherwise it will run to completion.

**Recommended:** Mode 2 for the complete Pulse Sync experience (Data Cloud + Agents + Commerce Store + Experience Cloud site + external-website messaging agent).

**Watch-points during a run:** the parent orchestrator may ask you to reload the VSCode window once after Step 3 (`mcp-setup`) so the MCP tool schemas materialize in the running session. Reply `reloaded` when done. Everything else is unattended.

### Step-by-step execution (advanced — for debugging or partial re-runs)

Each skill can be invoked directly as a slash command:

```
/feature-enablement            <alias>
/external-client-app-deploy    <alias>
/mcp-setup                     <alias>
/base-metadata-deploy          <alias>
/datakit-install               <alias>
/agentforce-data-library       <alias>
/notebook-ai                   <alias>
/document-ai                   <alias>
/agent-setup-configuration     <alias>
/prompt-template-add-retriever <alias>
/assign-permission-to-app      <alias>
/experience-cloud-setup        <alias>    # Mode 2 only
/commerce-store-enablement     <alias>    # Mode 2 only
/cms-workspace-setup           <alias>    # Mode 2 only
/storefront-publish            <alias>    # Mode 2 only
/embed-service-agent-on-experience-site <alias>  # Mode 2 only
/site-branding-setup           <alias>    # Mode 2 only
/datastream-file-upload        <alias>
/refresh-data-cloud-components <alias>
/copy-field-sync               <alias>
/refresh-data-streams          <alias>    # OPTIONAL — user opt-in only
```

Each skill's SKILL.md file (under [.claude/skills/](skills/)) documents its own prerequisites, workflow, and success criteria.

---

## Automation Technology Stack

| Technology | Purpose | Skills using it |
|------------|---------|-----------------|
| **Salesforce CLI (`sf`)** | Metadata deploy, permset assignment, Apex run, org display | 1, 2, 3, 4, 5 (Phase 1), 10, 11, 12, 13, 14, 17 |
| **`salesforce-sobject-all` MCP** | SObject CRUD + SOQL + schema introspection (user seed, permset assignment, sample data load, FLS/CRUD grants, verification queries) | 4, 10, 12, 13, and verification passes |
| **`salesforce-data-cloud-queries` MCP** | Data Cloud SQL against DLOs/DMOs | verification queries |
| **`salesforce-data360` MCP** | Data Kit install, Data Stream get, Identity Resolution, Calculated Insights, Segment publish, Search Index + Retriever, Document AI | 5 (Phase 2), 8, 19, 20, 22 |
| **`salesforce-headless-360` MCP** | Connect API dispatch (Data Libraries, Notebook AI, prompt-template retrievers, CMS, storefront publish, ESA publish) | 6, 7, 11, 15, 16, 17 |
| **Playwright (MCP)** | UI for the handful of features with no public API — Data Cloud Architect permset default data space, Search Auto Updates toggle, file-upload data stream, ESA Web Deployment publish, copy-field sync | 1, 14, 17, 19, 21 |
| **Python `requests`** | S3 presigned-URL uploads (Node's Windows Schannel has issues past ~6 files) | 6, 15 |
| **Bash + curl** | Document AI config; one S3 PUT for Notebook AI file upload | 7, 8 |

### Key benefits
- ✅ MCP-first — every write/read that CAN go through an MCP server DOES; Playwright is used only where there is no public API
- ✅ No JavaScript file generation; no ad-hoc scripts left behind in the repo (every skill has a Workspace-Hygiene cleanup rule)
- ✅ Idempotent — every skill checks org state before writing; re-runs are safe
- ✅ Secrets live only in `.claude/settings.local.json` (gitignored), never in tracked files

---

## Runtime expectations

| Phase | Wall-clock |
|-------|-----------|
| Feature enablement + ECA deploy + MCP setup (Steps 1–3) | ~10–15 min |
| Base metadata deploy + sample data load (Step 4) | ~5–10 min |
| Data Kit install (Step 5 — Phase 1 metadata + Phase 2 Data Kit activate) | ~35–55 min |
| Agentforce Data Library + Notebook AI + Document AI (Steps 6–8) | ~10–20 min |
| Agent setup + prompt templates + app permission (Steps 10–12) | ~10–15 min |
| Experience Cloud + Commerce + CMS + Storefront + ESA + Site Branding (Steps 13–18, Mode 2 only) | ~30–45 min |
| Data Stream file upload + Data Cloud component refresh + Copy-field sync (Steps 19–21) | ~20–35 min |
| Optional Data Stream refresh (Step 22) | ~15–20 min |

Full Mode 2 install: **~2.5–3 hours end-to-end.**

---

## Troubleshooting

If a skill fails, the orchestrator stops the chain and surfaces the error verbatim. Common patterns:

- **`invalid_client` on `/mcp-setup`** — Consumer Key/Secret entered wrong, or `ps-eca` didn't fully deploy. Re-run `/external-client-app-deploy` then `/mcp-setup`.
- **`Could not find related list <pacemaker>__pr` on agent package deploy** — the Pacemaker IOT related list ships with the Data Kit installed at Step 5. Verify `/datakit-install` exited `jobStatus=Complete` and that the related list is visible on Contact in Setup → Object Manager → Contact → Data Cloud Related List. Re-run `/datakit-install` if missing.
- **Data Kit install stalls** — Phase 2 is genuinely slow (30–45 min is normal). Only intervene if it's still `PENDING` past 60 min or returns `FAILED`.
- **`pacemaker_iot_data.csv not found`** on Step 19 — verify the file is in `MedTechDocuments/` at the repo root.
- **Playwright plugin missing** — Step 0.0 preflight will auto-run the setup script and prompt for `/reload-plugins`. If the auto-run fails, follow the manual `/plugin` steps.

For every skill, the SKILL.md file has its own **Error Handling** section with copy-paste-ready fixes.

---

## Handling long installs and interruptions

The installer chain is long — Mode 1 covers 15 skills, Mode 2 covers 21, and total wall-clock is 90 min to 3 hours. Because that runtime exceeds a single Claude subagent's practical context budget, the installer uses two coordinated durability mechanisms:

1. **A durable state file on disk** (`.claude/state/install-state.json`) that survives session ends, VS Code reloads, and subagent context boundaries.
2. **Fresh-subagent-per-skill orchestration** — the parent orchestrator invokes each of the 21 skills as its own separate `Agent` tool call, so each skill runs with a clean ~200K context ceiling. The parent's own context stays small because its per-skill work is just "read state, decide next skill, invoke one subagent, re-read state, advance or halt".

Together these mean an interruption at any point — mid-skill, between skills, or during a subagent context handoff — cannot lose track of what's already done.

### Where the state file lives

```
.claude/state/install-state.json          # machine-read checkpoint (structured JSON)
.claude/state/install-progress.log        # human-read timestamped substep timeline
.claude/state/INSTALL_STATUS.md           # ← OPEN THIS FIRST if the install ever halts.
                                            Auto-generated live-status dashboard —
                                            shows every skill's success/failure detail
                                            and step-by-step recovery instructions
                                            without needing to read JSON or scroll chat.
```

The `.claude/state/` folder ships with the repo (via `.gitkeep`) so a fresh `git clone` has it ready. A folder-level `.gitignore` blocks any state files inside it from being committed — they are runtime-only, per-checkout artifacts, and never enter version control.

**On first invocation of the installer**, all three files are auto-created. You don't need to run any setup command.

**If the install halts unexpectedly:** open `.claude/state/INSTALL_STATUS.md` first. It's a plain markdown dashboard that shows which skills succeeded (with their substeps and artifact IDs), which one failed (with the exact substep + error headline + timestamp), and copy-paste-ready recovery instructions. You do not need to know Claude Code, MCPs, or JSON to use it — the file is meant for the operator who did NOT run the install.

### What the file records

- Target org identity (alias, org Id, username, instance URL)
- Selected mode (Mode 1 or Mode 2)
- List of skills already completed
- Per-skill artifacts (deploy Ids, permission set IDs, refs maps, timestamps)
- Non-blocking warnings surfaced during any skill
- Reconciliation failures (records that hit MCP timeouts and couldn't be verified)

**Never holds secrets** — Consumer Keys, OAuth tokens, and passwords live elsewhere (`~/.claude/.credentials.json` and `.claude/settings.local.json`, both gitignored). The state file only holds IDs, counts, and flags.

### What happens if the install is interrupted

Re-invoke the installer agent (same command as the initial run). The parent orchestrator reads `.claude/state/install-state.json` and:

1. If the file's `orgAlias` matches your current target org and `mode` matches your selected mode → resumes from the first skill not yet in `completedSkills`. Skills already complete are skipped without re-executing DML.
2. If the file's `orgAlias` or `mode` mismatches your current selection → surfaces a prompt asking whether to archive the old state file and start fresh, or abort.
3. If the file doesn't exist → treated as a fresh run.

This means you can:
- Close VS Code mid-install and resume the next day
- Recover from a Salesforce API timeout by simply re-running
- Hand off an in-progress install to a colleague on the same repo checkout
- Kill and restart the installer as many times as needed without producing duplicate records

Each skill's Step 0 wrapper reads the state file first; if the skill is already complete, it returns immediately without re-running its Workflow. This is the primary durability guarantee.

### What happens on successful completion

When every skill in the selected mode is in `state.completedSkills`, the parent orchestrator:

1. Prints a final summary drawn from `state.artifacts` + `state.warnings` (this is the authoritative install report — not any subagent's in-memory recollection).
2. Renames `install-state.json` → `install-state-<orgAlias>-<YYYYMMDD-HHMMSS>-complete.json` in the same folder.
3. Leaves the working file slot empty for the next install run.

The archive files stay in `.claude/state/` as an audit trail. You can delete them anytime with `rm .claude/state/install-state-*-complete.json`; they're gitignored so they never affect the repo.

### When to intervene manually

Rare. If a run gets stuck in a way the resume logic can't recover from (a skill keeps failing on the same step across multiple retries, for example), you have three options:

- **Force a re-run of a specific skill:** open `.claude/state/install-state.json`, remove that skill's name from the `completedSkills` array, save, re-invoke the installer. It will re-execute that skill from Step 0.
- **Wipe the state and start fresh against the same org:** delete `.claude/state/install-state.json` and re-invoke. The org's dedup guards (Step 6.1a in `/base-metadata-deploy`, etc.) will handle pre-existing records.
- **Investigate what the previous run actually did:** the state file itself is the audit trail. Open it and look at `artifacts` + `warnings` to see exactly which IDs got created and what non-blocking issues surfaced.

### Multi-session behavior

- **Sequential sessions, same repo, same org** — the common case. State file survives across sessions; resume works cleanly.
- **Different orgs from the same repo checkout** — the orchestrator detects the mismatch via `orgAlias` and asks before overwriting.
- **Different repos on different machines** — no cross-machine sharing; each checkout has its own state file.
- **Parallel sessions against the same repo and same org** — not supported. The orchestrator halts with a warning if it detects concurrent modification via `lastUpdateTs` drift between read and write.

---

## The Pulse Sync product at a glance

Once the installer finishes, log in to Sales Cloud and search for **Mark Smith** — the featured unified patient profile.

- **Sales Cloud / Pulse Sync app** — Mark Smith's Person Account renders on the `Patient_Account_Page` FlexiPage with unified pacemaker telemetry, allergies, procedures, medications, health conditions, and service appointments.
- **Employee Agent (Clinician Copilot)** — available on the contact record page. Handles utterances like *"Summarize this patient's last 30 days and flag anything abnormal"* and *"Extract lead model/serial and implant site"* via Prompt Builder + Document AI + Agentforce Data Library retrievers.
- **Service Agent (PulseSync Assistant)** on the Experience Cloud site — handles guest utterances like *"What are the pacemaker options?"*, *"How long is the warranty?"*, *"How do I set up my remote monitor?"*, and logged-in-user utterances like *"Book an appointment with my cardiologist"*, *"Can you schedule a remote device check?"*, *"Summarize my last 6 months for my primary care doctor"*.
- **Same Service Agent embedded on an external website** — if Steps 17 (`/embed-service-agent-on-experience-site`) and the main [README.md](../README.md) Section 5 optional steps are used.

Full utterance-to-implementation matrix is in the main [README.md](../README.md) under "Behind the Scenes — how is the agent powered?".

---

## Related documentation

- **[.claude/agents/data360-healthcare-installer/AGENT.md](agents/data360-healthcare-installer/AGENT.md)** — the authoritative install spec (LOCKED SKILL SEQUENCE, hard rules, per-skill verification, resume protocol, workspace hygiene)
- **[.claude/skills/*/SKILL.md](skills/)** — individual skill documentation (workflow, preconditions, success criteria, error handling, cleanup)
- **[../README.md](../README.md)** — the product-level README with product demo, manual installation instructions, and the utterance-to-implementation matrix
