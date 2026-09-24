---
name: datastream-file-upload
description: "Upload a CSV file to a Data Cloud Data Stream File Upload connector using Playwright browser automation with an Aura-layer payload interceptor (Path A) that strips Salesforce-restricted advancedAttributes keys (isDataStreamConfigValid, delimiter) from /aura POSTs in flight. Handles the pacemaker_iot_data data stream for the Healthcare Data Kit. The interceptor is required because Salesforce rejects those keys for File-Upload data streams; without it, every Deploy click fails server-side. Uses MCP Playwright tools only. All files this skill creates are deleted on both success and failure paths. Use when user wants to upload the pacemaker IoT data file to its Data Stream, update the Data Stream file, or refresh Data Stream data."
---

# datastream-file-upload

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"datastream-file-upload"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: datastream-file-upload already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Purpose

Automate file uploads to Data Cloud Data Stream File Upload connectors using Playwright browser automation.

**✅ WORKING SOLUTION (Validated 2026-05-25)**

This skill successfully automates CSV file uploads to Data Cloud Data Streams using browser automation. The key breakthrough: clicking the visible "Upload Files" text (not the hidden input element) to trigger the file chooser.

**Critical Constraints:**
- ❌ Do NOT generate JavaScript files
- ❌ Do NOT generate Playwright scripts (.js, .mjs, .ts files)
- ✅ Use MCP Playwright browser automation tools ONLY via direct tool calls
- ✅ All automation through `mcp__plugin_playwright_playwright__*` tools
- ✅ **MUST click `text=Upload Files`** to trigger file chooser (not hidden input element)
- 📸 **Screenshot Policy**: ONLY take screenshots when errors occur. Save to `.playwright-mcp/error-[timestamp].png`. Do NOT take screenshots for successful steps

**Temporary File Policy (MANDATORY):**
- ✅ Create temp SOQL files (e.g. `query_datastreams.soql`) ONLY when needed
- ✅ DELETE the file IMMEDIATELY after the step completes (`rm <filename>`)
- ❌ NEVER leave temporary SOQL/Apex/query files in the repo working tree

This skill uploads CSV files to Data Cloud Data Streams with File Upload connection type.

---

## 🚨 PER-FILE 3-TIER ESCALATION STRATEGY (when uploads stall at 0% on AWS S3)

**Symptom:** Salesforce's UI shows the file uploading but it sits at "Progress: 0%" until timeout. This is almost always a corporate proxy / TLS-inspection / cert-chain issue between the browser and AWS S3 (where Salesforce stores the CSV before processing).

**Rule:** The single `pacemaker_iot_data.csv` upload MUST succeed. It is not allowed to be skipped. If the file fails at one tier, retry it at the next tier. Tiers escalate independently — the 3-tier escalation pattern is preserved from the Retail multi-file version so it works identically for future multi-file installs.

| Tier | Approach | When to use | What changes |
|---|---|---|---|
| **1** | **Plain Playwright UI** — no Aura interceptor, just click Update File → Full Refresh → Deploy | Default first attempt for every file. Salesforce's vanilla UI flow with no in-flight payload modification. | Nothing — just navigate the wizard normally. |
| **2** | **Aura payload interceptor (Path A)** — strip `isDataStreamConfigValid` + `delimiter` from `advancedAttributes` in `/aura` POSTs in flight | Tier 1's Deploy click fails server-side with a Salesforce validation error mentioning `advancedAttributes` (Salesforce rejects those keys on File-Upload streams). | Inject the interceptor before clicking Update File. See section below. |
| **3** | **Browser-state reset + cache-bypass retry (fully automatic)** | Tier 2 still stalls at "Progress: 0%" for >60s. Real causes the skill *can* fix: stale browser session, expired cookies mid-upload, corrupted page cache, mid-flight CDN cache poisoning. Real causes the skill *cannot* fix: corporate proxy TLS interception (system Chrome would be needed but cannot be invoked without config edit or relaunch). | See "Tier 3 automatic recovery" block below. Skill closes browser → clears all storage/cookies via `browser_evaluate` → reopens → re-injects Aura interceptor with an extra `Cache-Control: no-cache, no-store` header on every `/aura` + `/services` POST → retries the upload with extended timeout (5 min instead of 60s). |

**Escalation rules:**
- ✅ **Tier 1 → 2:** if the Deploy click returns a server error mentioning `isDataStreamConfigValid`, `delimiter`, or `advancedAttributes`. Usually a fast failure, not a 0% stall.
- ✅ **Tier 2 → 3:** if Tier 2's Deploy click succeeds (server accepts the request) but the upload sits at "Progress: 0%" for >60s — that's the AWS S3 PUT failing, which means proxy / cert-chain. Restart the file at Tier 1 logic but with the system-Chrome config now active.
- ❌ **Never skip a file.** If Tier 3 also stalls at 0%, STOP and surface to the user — at that point it's a network-team problem (allowlist `*.s3.<region>.amazonaws.com` in their proxy or disable TLS inspection for `*.amazonaws.com`).
- ✅ **Per-file independence (preserved for future multi-file variants):** each file's tier state is tracked independently. In the current Healthcare kit there is only one file (`pacemaker_iot_data.csv`), but the logic is retained verbatim so that adding more streams later is a no-op change.
- ✅ **Tier 3's in-session state reset (close → clear storage → reopen)** runs entirely inside the currently-launched Playwright MCP process and does not require a plugin reload.
- ⚠️ **BUT: any change to `browser.launchOptions` (including Chrome flags such as `--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights`) is NOT loaded automatically by a subsequent `browser_navigate`.** Playwright MCP reads `launchOptions` only when the MCP process starts. A launch-options change requires a plugin/MCP reload (`/reload-plugins`) followed by re-invocation of the skill; the skill's durable-state wrapper will resume it cleanly on the next run. See "Playwright MCP PNA preflight" (Step 3.5) for the correct lifecycle.

**Detection pseudocode (apply per-file inside the per-stream loop):**

```
attempt_tier_1(file)
if click_deploy_returned_error_mentioning(['advancedAttributes','isDataStreamConfigValid','delimiter']):
    attempt_tier_2(file)  # inject Aura interceptor, retry
elif progress_stuck_at_0_for_60s:
    diagnostics = capture_console_and_network_diagnostics()
    if pna_signals_present(diagnostics):
        # RFC 6598 100.64/10 or net::ERR_BLOCKED_BY_PRIVATE_NETWORK_ACCESS_CHECKS.
        # Route to Step 3.5 — this is NOT a Tier 3 state reset.
        ensure_pna_launch_config_installed()             # idempotent write, no rewrites
        persist_state('pnaReloadRequested', True)
        print_reload_prompt_verbatim()                    # /reload-plugins handoff
        STOP                                              # exit cleanly; resume on next invocation
    else:
        attempt_tier_3(file)  # in-session state reset (close → clear storage → reopen)
        if still_stuck_at_0_for_60s:
            STOP and surface network-team requirement
elif success: continue

# Final guard
if any_file_still_failing_after_tier_3:
    STOP and surface "AWS S3 PUT blocked by network. Network team must allowlist *.s3.<region>.amazonaws.com or disable TLS inspection for *.amazonaws.com"
```

### Tier 3 automatic recovery (fully in-skill, no manual user step, no config edit)

When Tier 2 stalls at "Progress: 0%" for >60s, run these steps in order. **All four phases run automatically inside the skill — the user is not asked to relaunch anything.**

**Phase 1 — Capture diagnostic before the reset:**

```
mcp__plugin_playwright_playwright__browser_console_messages(level: "error")
mcp__plugin_playwright_playwright__browser_network_requests()
```

Save the output for the final-failure surface. If errors mention `net::ERR_CERT_AUTHORITY_INVALID`, `net::ERR_PROXY_CONNECTION_FAILED`, or `net::ERR_TUNNEL_CONNECTION_FAILED`, the cause is corporate proxy / TLS interception — Tier 3 cannot fix this; skip to "Final failure surface" below.

**Phase 2 — Hard reset browser state (clears stale session / cookie / cache issues):**

```
mcp__plugin_playwright_playwright__browser_evaluate
  function: "() => { try { localStorage.clear(); sessionStorage.clear(); } catch(e){} ; document.cookie.split(';').forEach(c => { const eq = c.indexOf('='); const name = eq > -1 ? c.substr(0, eq).trim() : c.trim(); document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/'; }); return 'state-cleared'; }"

mcp__plugin_playwright_playwright__browser_close
```

**Phase 3 — Reopen, re-authenticate via frontdoor, and re-inject the Aura interceptor with cache-bypass headers:**

Re-fetch a fresh access token (the cleared session means the old one is gone), then navigate via `frontdoor.jsp?sid=<fresh-token>` to the same Data Stream record page.

After the page loads, install an enhanced Aura interceptor that does what the existing Path A does PLUS adds `Cache-Control: no-cache, no-store, must-revalidate` to every outbound `/aura` and `/services` POST:

```
mcp__plugin_playwright_playwright__browser_evaluate
  function: "() => { const orig = window.XMLHttpRequest.prototype.send; window.XMLHttpRequest.prototype.send = function(body) { try { if (this.__url && (this.__url.includes('/aura') || this.__url.includes('/services'))) { this.setRequestHeader('Cache-Control', 'no-cache, no-store, must-revalidate'); this.setRequestHeader('Pragma', 'no-cache'); if (typeof body === 'string' && body.includes('isDataStreamConfigValid')) { try { const params = new URLSearchParams(body); const msg = params.get('message'); if (msg) { const parsed = JSON.parse(msg); if (parsed.actions) { parsed.actions.forEach(a => { if (a.params && a.params.advancedAttributes) { delete a.params.advancedAttributes.isDataStreamConfigValid; delete a.params.advancedAttributes.delimiter; } }); params.set('message', JSON.stringify(parsed)); body = params.toString(); } } } catch(e){} } } catch(e){} return orig.apply(this, [body]); }; const origOpen = window.XMLHttpRequest.prototype.open; window.XMLHttpRequest.prototype.open = function(method, url) { this.__url = url; return origOpen.apply(this, arguments); }; return 'tier3-interceptor-installed'; }"
```

**Phase 4 — Retry the upload with extended timeout:**

Run the same Update File → Full Refresh → Deploy flow as Tier 1. After clicking Deploy, instead of the normal 60-second wait, poll for completion every 10 seconds for up to **5 minutes** (300 seconds). Stale-session and cache-corruption uploads typically resume around minute 1–2 once the request hits S3 with fresh cookies + no-cache.

**Final failure surface (when Phase 1 detected proxy/cert errors, OR Phase 4 stalls past 5 minutes):**

The skill stops the chain and surfaces verbatim:

```
❌ Data Stream <filename> failed all 3 tiers.

Tier 1 (plain UI):     stalled at 0% / failed
Tier 2 (Aura strip):   stalled at 0%
Tier 3 (state reset):  stalled at 0% / proxy error detected

Diagnostic captured:
  - Console errors: <list from Phase 1>
  - Failed network requests to: <list of S3 hosts>

Root cause: Corporate proxy is blocking or TLS-intercepting AWS S3
(*.s3.<region>.amazonaws.com). The bundled Chromium browser cannot trust
the proxy's re-signed certificate. The skill has exhausted every
in-process workaround.

ONLY remaining fixes (require network-team / IT action):
  1. Allowlist *.s3.<region>.amazonaws.com + *.amazonaws.com in the
     corporate proxy
  2. Disable TLS inspection for *.amazonaws.com
  3. Run the install from a non-corporate network (home WiFi, mobile
     hotspot, AWS Cloud Workstation, etc.)

After IT fix is in place, re-run the install — the skill will pick up
from this Data Stream automatically.
```

**Per-file independence still applies** — successful files at Tier 1 or 2 stay successful; only the failing file goes through Tier 3 and (if needed) the surface above. The skill never asks the user to relaunch anything.

---

### Chrome PNA bypass — FALLBACK when the launch-time flag fix isn't available

**Preferred path is now Step 3.5.** When Playwright MCP is launched with `--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights` the LWC's S3 PUT proceeds normally and none of the fake-PUT / out-of-band-PUT machinery below is needed. Use this section ONLY when the launch flags cannot be applied (e.g. operator declined the plugin reload, or the flags are configured but the current MCP process was started before them) and PNA is still blocking the S3 PUT specifically.

**Testing history (org-neutral):**
- A trial-signup Salesforce org's `my.salesforce.com` and Lightning hosts resolved to RFC 6598 shared address space (`100.64.0.0/10`), and the Data Cloud presigned S3 host for the file-upload connector resolved into the same range. Chrome's Private Network Access policy classified the destination IPs as "private" while treating the parent Lightning origin as "public", so LWC cross-origin resource loads for the Update File modal AND the browser-side S3 PUT were silently blocked at the network layer. Symptoms observed: `"Sorry to interrupt — CSS Error"` (auraErrorBox) on the Update File click, and `Upload failed` at `Progress: 0%` after the file chooser.
- Launching Playwright MCP with `--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights` resolved the Salesforce-side (Lightning → my.salesforce.com) PNA classification failure. The launch flags cannot be applied without a plugin/MCP reload; `browser_navigate` alone does not re-read `launchOptions`.
- The S3-PUT fake-out interceptor (Hook 4) only fired for the LWC's ArrayBuffer/Blob-bodied PUT once it was lifted OUTSIDE the `typeof body === "string"` guard used by the Aura payload sanitization hooks. With Hook 4 body-type-independent, the LWC observed a synthetic 200 and Deploy proceeded; the CSV bytes were pushed to S3 out-of-band via the manifest-driven `scripts/notebook-ai-s3-put.py` helper.
- Final outcome after both fixes: Data Stream became ACTIVE, `ImportRunStatus` polled to `SUCCESS`, and the DLO's formula-field projection came back clean without needing the Upsert fallback.

**Symptom:** The "Update Data Stream from a File" modal shows `"Unexpected Error, Please try again: Upload failed"` after ~60–90s at `Progress: 0%`. Deploy button never enables. The console reveals the actual cause:

```
Access to XMLHttpRequest at 'https://aws-prodN-<region>-cdp2-lakehouse-*.s3.<region>.amazonaws.com/...'
from origin 'https://<myDomain>.lightning.force.com' has been blocked
```

DNS resolution on the presigned S3 host returns an IP in `100.64.0.0/10` (RFC 6598 shared address space, also called CG-NAT range). Chrome's **Private Network Access (PNA)** policy classifies that as "private" and blocks any XHR from a public origin (Lightning) to it. **The PUT never leaves the browser** — there is no HTTP status, no server-side error, just a silent policy-layer rejection.

Neither Tier 2 (Aura payload strip) nor Tier 3 (state reset + cache-bypass) fixes this. Tier 2 addresses server-side rejections that never happen here; Tier 3 assumes the request eventually reaches S3, which it doesn't. The block is enforced by Chrome itself and no in-browser workaround can override it.

**Detection signals (any one is sufficient):**
- Console contains `net::ERR_BLOCKED_BY_PRIVATE_NETWORK_ACCESS_CHECKS`, OR
- Console contains `has been blocked` + `s3.<region>.amazonaws.com` from the Lightning origin, OR
- `nslookup` / `dig` on the presigned S3 host resolves to `100.64.x.y`.

**Workaround — split the upload in two.** Fake the browser-side PUT so Lightning believes the upload succeeded, then push the real bytes to S3 out-of-band from the installer's own environment (which has no PNA policy).

1. **Extend the Step 4.5 interceptor** with an S3-PUT hook. Install alongside the existing Path A hooks — same `browser_evaluate` call, add the block below after Hook 3.

   **🚨 STRUCTURAL RULE — Hook 4 MUST be independent of body type.** The LWC sends the CSV bytes to S3 as an `ArrayBuffer`/`Blob`, NOT as a string. The S3 URL/method match MUST be evaluated BEFORE any `typeof body === "string"` check. The string-body guard belongs to the Aura payload sanitization hooks only (Hooks 2 and 3); it MUST NOT wrap Hook 4. If Hook 4 is nested inside a string-body branch it silently no-ops for the real LWC PUT.

   ```javascript
   // ---- Hook 4: fake S3 PUT + capture presigned URL (Chrome PNA bypass) ----
   // MUST run for ANY body type — Blob, ArrayBuffer, ArrayBufferView, or string.
   // Do NOT wrap this in a `typeof body === 'string'` guard; the LWC sends the
   // CSV to S3 as ArrayBuffer/Blob and the guard would silently skip the real PUT.
   window.__capturedS3Url = null;
   (function(){
     const _origSend2 = XMLHttpRequest.prototype.send;
     XMLHttpRequest.prototype.send = function(body) {
       try {
         // Match ONLY on method + URL — independent of body shape.
         if (this.__dsMethod && this.__dsMethod.toUpperCase() === 'PUT'
             && this.__dsUrl && this.__dsUrl.includes('amazonaws.com')) {
           window.__capturedS3Url = this.__dsUrl;
           const xhr = this;
           setTimeout(function(){
             try { Object.defineProperty(xhr, 'readyState', { get: () => 4 }); } catch(e){}
             try { Object.defineProperty(xhr, 'status',     { get: () => 200 }); } catch(e){}
             try { Object.defineProperty(xhr, 'response',   { get: () => '' }); } catch(e){}
             xhr.dispatchEvent(new ProgressEvent('load',    { lengthComputable: true, loaded: 1, total: 1 }));
             xhr.dispatchEvent(new ProgressEvent('loadend', { lengthComputable: true, loaded: 1, total: 1 }));
           }, 50);
           return; // skip real network — Chrome would PNA-block it anyway
         }
       } catch(e){}
       return _origSend2.call(this, body);
     };
   })();
   ```

   **Placement inside the Step 4.5 interceptor `evaluate()` body.** Hook 4 sits AFTER Hook 3 (Aura XHR sanitization) but the two hooks share the same wrapped `XMLHttpRequest.prototype.send`. Because Hook 3's outer guard is `if (typeof body === 'string')`, the string-only sanitization path must fall through to `_origSend.call(this, body)` when `body` is NOT a string — otherwise ArrayBuffer/Blob bodies short-circuit before Hook 4's send wrapper runs. Verify the fall-through in Hook 3 is `return _origSend.call(this, body);` at the tail of the wrapper regardless of body type. Do NOT place any Hook 4 logic inside Hook 3's `typeof body === 'string'` block.

2. **Run the Playwright flow normally** — Update File → Full Refresh → Upload Files → `browser_file_upload`. The interceptor fires as the LWC tries the S3 PUT, Lightning sees a synthetic `200 OK`, progress bar completes, Deploy button enables.

3. **Read the captured presigned URL out of the page:**

   ```
   mcp__plugin_playwright_playwright__browser_evaluate
     function: "() => window.__capturedS3Url"
   ```

4. **Do the real PUT out-of-band from the installer's shell** — no browser, no PNA policy.

   **🚨 SECURITY — presigned URLs are ephemeral credentials.** A presigned S3 URL grants time-boxed write access to the bucket. It MUST NOT appear in:
   - `Bash` command strings, heredocs, or `python -c` / `python3 -c` inline scripts;
   - environment-variable command strings;
   - logs or user-visible output;
   - any file under the repo working tree;
   - `.claude/state/install-state.json` or any durable artifact.

   Its only permitted locations for the lifetime of this out-of-band PUT are:
   - the transient `browser_evaluate` return value that captured it;
   - a single manifest file under the OS temp path (`$TMPDIR` / `%TEMP%` / `tempfile`);
   - the uploader helper's in-process memory when it reads that manifest.

   **Uploader helper — reuse `scripts/notebook-ai-s3-put.py`.** The same permanent helper that the notebook-ai skill uses for S3 PUTs applies verbatim here. Its contract:
   - reads the manifest path from `argv[1]` (no hardcoded paths, no env vars);
   - PUTs raw file bytes with NO extra headers (no `Content-Type`, no `Content-Length` — the presigned URL is signed with `X-Amz-SignedHeaders=host` only, and any extra signed-header equivalent returns `403 SignatureDoesNotMatch`);
   - emits one status line per file: `<http_status>\t<name>\t<error-or-blank>`;
   - exits `0` iff every PUT returned HTTP 200.

   **Step-by-step:**

   a. Write a per-invocation manifest to an OS-temp path — never inside the repo. Manifest schema is identical to notebook-ai's:

      ```json
      {
        "libraryId": "datastream-file-upload",
        "sourceDir": "MedTechDocuments",
        "files": [
          { "name": "pacemaker_iot_data.csv", "url": "<presigned url — leave &amp; escaped>" }
        ]
      }
      ```

      Use the agent's file-writing tool (Write) to persist the manifest at `<tmpdir>/ds-presigns.json`. Do NOT construct the manifest by echoing the URL into a shell heredoc — that puts the URL on a command line.

   b. Invoke the helper with a fixed-shape `Bash` call — the manifest path is the ONLY argument:

      ```bash
      python3 scripts/notebook-ai-s3-put.py "<tmpdir>/ds-presigns.json"
      ```

      No presigned URL, no filename list, no other flags may appear on this command line.

   c. Verify the helper printed `200\tpacemaker_iot_data.csv\t` (empty error column) and exited `0`. If not, STOP and surface the failing status.

   d. **Delete the manifest and its tmpdir immediately** on ANY outcome (success or non-zero exit). Presigned URLs MUST NOT survive on disk once results are known.

   Do NOT log the complete URL at any point. If a diagnostic snippet is needed, redact everything after the host+path (e.g. `https://aws-prodN-<region>-cdp2-lakehouse-*.s3.<region>.amazonaws.com/... [signed]`).

5. **Return to the browser and click Deploy** normally. Salesforce's Deploy action tells Data Cloud to ingest the file at the S3 key — the bytes are already there from step 4, so ingestion proceeds. Modal shows "File Upload Complete", closes, record page reports `Status = Active, Last Run Status = Pending`.

**Presigned URL freshness:** URLs expire 900s (15 min) after issue. Run the Python PUT immediately after step 3 — waiting past the window returns `403 Request has expired` and requires re-running from step 2 to capture a fresh URL.

**Aura strip interplay:** The existing Path A `advancedAttributes` interceptor still installs and remains armed. In practice it may not observe any keys to strip on this path (`window.__dsAuraCaptured` returns `[]`) because Lightning's Deploy POST after a "successful" upload doesn't always carry those keys — but leave the Aura strip installed anyway; it's cheap and covers the non-PNA server-side rejection path.

**When to apply this vs the 3 tiers above:**
- If Deploy click returns a server-side "advancedAttributes cannot be patched" error → **Tier 2** (Aura strip).
- If upload stalls at 0% AND console shows PNA / `100.64.x.y` DNS → **this bypass**. Do NOT waste time on Tier 3 — state reset changes nothing.
- If upload stalls at 0% AND console shows `net::ERR_CERT_*` / `net::ERR_PROXY_*` / `net::ERR_TUNNEL_*` → corporate proxy / TLS interception. Cannot be fixed in-skill; surface the final-failure block.
- If upload stalls at 0% with no console error signal → **Tier 3** state reset.

---

### Inline error router (handles everything else automatically — no manual fallback)

Beyond the 3 tiers above, several other errors can surface during DataStream upload. The skill detects each one, applies the matching auto-fix in-flight, retries the failing operation **once** with the fix applied, and escalates to Tier 3 only if the auto-fix doesn't recover. **No error in this table requires user intervention.**

Run these checks at every Playwright step (after every `browser_click`, `browser_navigate`, `browser_file_upload`, `browser_wait_for`):

| Detected condition | Auto-fix | Retry strategy |
|---|---|---|
| **Auth / 401 / "Session expired" / page redirect to `/login`** | Re-fetch fresh access token via `sf org display --target-org <alias> --json`. Re-navigate via `<instanceUrl>/secur/frontdoor.jsp?sid=<freshToken>&retURL=<encoded data-stream URL>`. | Resume from the step that was failing — do NOT restart from file 1. |
| **`net::ERR_CERT_*` / `net::ERR_PROXY_*` / `net::ERR_TUNNEL_*`** in console messages | This is corporate proxy / TLS interception. **No skill workaround possible** — surface the final-failure block from Tier 3 immediately and STOP. Don't waste time on Tier 3 reset. | Skip directly to "Final failure surface". |
| **"File chooser already open" / orphan dialog blocking clicks** | Call `browser_handle_dialog(action: "dismiss")`. If still blocked, take a snapshot, find any visible `[role=dialog]` Cancel/Close button, click it. | Retry the original click once. |
| **Selector mismatch — `text=Update File` (or any documented selector) returns "no element"** | Re-take `browser_snapshot`. Search for the button by role + accessible name regex (e.g. `role=button name=/update.*file/i`). If still nothing, scroll the page (`browser_evaluate: window.scrollTo(0, 200)`), re-snapshot, retry. | Retry click with the fresh selector. If still missing after scroll, escalate to Tier 3 reset. |
| **Lightning page-load race — click fired before LWC mounted (button click is silent no-op, no `/aura` POST in network log)** | Insert `browser_wait_for(text: "<known stable text on the loaded page>", time: 10)` before re-clicking. For Data Stream record pages, wait for the stream Status badge ("Active", "UnderConstruction", etc.) to be visible. | Retry click once after the wait completes. |
| **Network blip / single 5xx from `/aura`** detected via `browser_network_requests` | Capture the failed request URL + response code for diagnostics. Wait 15 seconds (server-side 5xx usually clears on retry). | Retry the same `browser_click` that triggered the failed POST exactly once. Two consecutive 5xx → escalate to Tier 3. |
| **Aura interceptor never installed — `browser_evaluate` to check `typeof window.XMLHttpRequest.prototype.send.__intercepted` returns `"undefined"`** | The page navigated after the inject ran (SPA route change, or interceptor lost). Re-run the Tier 2 `browser_evaluate` injection block before the next Deploy click. | Retry Deploy click after re-injection. |
| **Deploy click timed out — 30s passed and `browser_network_requests` shows zero `/aura` POSTs since the click** | Click fired but didn't register. Re-snapshot DOM. The Deploy button may have moved (SPA re-render). Find it by accessible name regex `role=button name=/deploy/i`, click again. | Retry once with fresh selector. |
| **`browser_file_upload` fails with "no file chooser available"** | The file chooser dialog closed before upload registered (race condition with `browser_click` on the Upload Files label). Re-click the label, then *immediately* call `browser_file_upload` in the next tool call (no `browser_wait_for` between them). | Retry once. |
| **`Progress: 0%` for >60s but no console/network errors** (the canonical Tier 3 trigger) | Run Tier 3 automatic recovery (already documented above). | Standard Tier 3 flow. |
| **`Progress: 0%` >60s WITH `net::ERR_*` in console** | Skip Tier 3 (state reset won't help cert issues) and go straight to the final-failure block. | Surface and STOP. |
| **`Progress: 0%` >60s WITH `net::ERR_BLOCKED_BY_PRIVATE_NETWORK_ACCESS_CHECKS` in console, OR DNS on the presigned S3 host resolves to `100.64.x.y` (RFC 6598)** | **Preferred path — Step 3.5 launch-time flags.** If `browser.launchOptions.args` does not already include `--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights`, route to Step 3.5: persist `pnaReloadRequested=true`, print the reload prompt, STOP. **Fallback — Chrome PNA bypass** (documented above the router table): only use this when the launch flags cannot be applied. Install Hook 4 (independent of body type per the structural rule) to fake the browser PUT + capture the presigned URL, then push the CSV bytes to S3 via the `scripts/notebook-ai-s3-put.py` manifest-driven helper, then click Deploy. | Retry the current Data Stream with the bypass active. Do NOT escalate to Tier 3 — state reset doesn't change Chrome's PNA policy. |
| **Any other unexpected exception from a Playwright tool** | Capture via `browser_console_messages(level: "error")` and `browser_network_requests`, save both into the diagnostic. Close the browser, re-open via frontdoor (handles auth recovery from #1 above too), retry the failing step once. | One retry. If the same exception fires twice, escalate to Tier 3. |

**Routing logic (per file, per step):**

```
on every Playwright tool call:
    if call_failed OR detected_condition_matches_table_above:
        log diagnostic
        apply_auto_fix_for(condition)
        retry_call_once
        if still_failing:
            if condition was 5xx, selector mismatch, race, dialog, file-chooser-race:
                escalate to Tier 3 (full state reset)
            elif condition was net::ERR_CERT/PROXY/TUNNEL:
                skip Tier 3, surface final-failure-block, STOP
            else:
                surface final-failure-block with full diagnostic, STOP

after every successful step: continue to next step in the same file
after every successful file: move to next file (per-file independence)
after the file completes: skill done
```

**Final-failure surface diagnostic must always include** (so the user has everything for IT or self-debug):
- Which file failed
- Which step inside that file (auth / nav / click / upload / deploy)
- Console errors captured (last 20 entries)
- Network requests captured (last 30 entries, especially any 4xx/5xx)
- Screenshot saved to `.playwright-mcp/error-<file>-<timestamp>.png`
- The auto-fix attempts the skill made (so support knows what was already tried)

**Hard rule:** user interaction is prohibited except in exactly two intentional cases:

  (a) **Step 3.5 `/reload-plugins` handoff** — a one-time request when Playwright MCP `launchOptions` must be applied (PNA bypass flags installed but not yet active in the running MCP process). The skill persists `pnaReloadRequested=true`, prints the reload prompt verbatim, and STOPs cleanly. On the next invocation post-reload, the durable-state wrapper resumes the skill with no further prompting.

  (b) **Final-failure surface** — an unrecoverable network/IT blocker (e.g. corporate proxy TLS interception, S3 host allowlist missing) where the only ask is "tell IT to allowlist `*.s3.<region>.amazonaws.com` / disable TLS inspection for `*.amazonaws.com`".

Every other condition in the table above is detected and auto-handled in-flight.

**Key Workflow Rules:**
1. 🔄 **Execute ALL uploads sequentially (series)** - Never run steps in parallel
2. 📁 **Verify file exists locally** before attempting upload
3. ✅ **Wait for processing confirmation** after each upload
4. 🔑 **Auto-fill credentials** - Get from `sf org display`, ask user if not available
5. 🚀 **Fast execution** - Minimize browser automation time

---

## Arguments

- `org_alias` (required): Target Salesforce org alias or username
- `files_directory` (optional): Directory containing CSV files. Defaults to "MedTechDocuments"

---

## Preconditions

Before running:

- Salesforce CLI authenticated with target org
- User has System Administrator profile or equivalent permissions
- Data Cloud must be enabled and provisioned
- CSV file must exist in the specified directory:
  - pacemaker_iot_data.csv
- Data Stream with File Upload connection type must already exist:
  - pacemaker_iot_data
- MCP Playwright tools must be available (check deferred tools list)
- **IMPORTANT:** For fast, uninterrupted execution, configure auto-approval in `.claude/settings.json`:
  ```json
  {
    "permissions": {
      "allow": [
        "mcp__plugin_playwright_playwright__*",
        "bash:sf *",
        "bash:test *",
        "bash:ls *"
      ]
    }
  }
  ```
  Without this, each Playwright action will prompt for user approval, slowing down the process.

---

## Workflow

**CRITICAL EXECUTION RULES:**

1. ✅ **ALWAYS execute ALL uploads in SERIES (sequential order) - NEVER in parallel**
2. ✅ **Complete one Data Stream upload entirely before moving to the next**
3. ✅ **Wait for "Deploy" to complete before moving to next upload**
4. ✅ **Verify file exists before attempting upload**
5. ✅ **If Data Stream not found → Skip and continue with next**
6. ✅ **NEVER fail entire workflow if one upload fails → Report and continue**
7. 🚨 **BLANK-PAGE CHECK (CRITICAL): Immediately after navigating to a Data Stream record, snapshot the page. If the "Update File" button is NOT visible → Refresh the page IMMEDIATELY (do not wait, do not retry chain). Salesforce sometimes renders a blank/incomplete record page on first navigation.**
8. 🔄 **RETRY LOGIC: If any element not found (Upload Files button, Deploy button) → Refresh page/modal and retry once before skipping**

**Step Execution Order:**
```
Step 0: Load Playwright tools
   ↓
Step 1: Verify CSV files exist locally
   ↓
Step 2: Query Data Stream Record IDs using SOQL
   ↓
Step 3: Get credentials from sf org display
   ↓
Step 3.5: 🌐 Playwright MCP PNA preflight — verify launch flags for
          --disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights
          are installed in the MCP config. If missing → write config,
          persist pnaReloadRequested=true, print /reload-plugins prompt,
          STOP. Do NOT proceed to browser launch without the flags.
   ↓
Step 4: Launch browser and authenticate
   ↓
Step 4.5: 🛠️ Install Aura-layer payload interceptor (REQUIRED — strips
          isDataStreamConfigValid + delimiter from /aura POSTs in flight)
          Without this, the Deploy click in Step 5 fails server-side.
   ↓
Step 5: pacemaker_iot_data → Update File → Upload CSV → Deploy (interceptor active, Full Refresh kept as default — DO NOT touch the mode toggle)
   ↓
Step 5.8: 🚦 BLOCKING GATE — Poll Data Stream last-run status every 30s
          until it reaches Success (or terminal failure). Max wait 20 min.
          Do NOT invoke refresh-data-cloud-components while status is
          Pending / Running / Scheduled — the downstream IR/CI refresh
          would compute against an empty DLO and finish with zero
          unified profiles.
   ↓
Step 5.9: 🔍 FORMULA-FIELD PROJECTION CHECK — After 5.8 confirms Success,
          run a Data Cloud SQL query against pacemaker_iot_data__dll to
          verify Party_Identification_Name__c and Party_Identification_Type__c
          returned clean string values (no wrapping double-quotes). If the
          Full-Refresh projection bug fired (values wrapped in "..."), loop
          back to Step 5.1, take Step 5.3's SECOND-ATTEMPT branch (click
          Upsert), re-upload, re-verify. One fallback attempt maximum.
   ↓
Step 9: Close browser → Run mandatory cleanup of EVERY file/folder this run created → Generate report
```

**Per-Data-Stream sub-steps (current):**
- ✅ **Refresh Mode — DO NOT click anything.** Salesforce ships this modal with **Full Refresh preselected** (`aria-checked="true"`); we keep that default. **Skip mode selection entirely.** Right after `Update File` opens the modal, go directly to clicking `Upload Files`. (Earlier skill versions instructed clicking Upsert before upload — that path is retired. Operator preference is Full Refresh; less ceremony, fewer clicks, no race condition between the mode toggle and the file chooser.)
- ✅ **Update File button not found → REFRESH the page → re-check.** Lightning sometimes renders the record page with the highlights-panel actions missing on first navigation. If `Update File` is not in the snapshot after `wait_for(time:5)`, re-`browser_navigate` to the same URL and snapshot again. Do not retry-click into a missing element.
- ⚠️ **Select Existing Model** — Only applicable if the modal explicitly offers a "New Model vs Existing Model" choice after upload. In current orgs the existing model is auto-selected because the Data Stream is already mapped to its DLO; skip unless the modal renders the choice.

---

## Data Stream Direct Navigation

**✅ BEST PRACTICE: Use SOQL query + direct URL navigation**

Instead of searching for Data Streams in the UI (slow and error-prone), use SOQL to get Record IDs and navigate directly:

**Step A: Query Data Stream IDs:**
```bash
sf data query --target-org <org_alias> --query "SELECT Id, Name FROM DataStream WHERE Name LIKE 'pacemaker_iot_data%' OR Name = 'pacemaker_iot_data'" --json
```

**Why both LIKE and equality clauses?** Salesforce sometimes ships the data kit's Data Stream `Name` field with a version suffix (e.g. `pacemaker_iot_data_v2`) after a re-deploy. The `LIKE 'pacemaker_iot_data%'` covers any version suffix; the equality covers the canonical name. Single round-trip handles both shapes.

**Important: expect exactly 1 result row.** If the query returns more (e.g. duplicate streams from a re-deploy) or fewer (e.g. Data Kit metadata didn't finish creating the stream), STOP and surface the row list to the user before proceeding — Step 5 hardcodes one ID.

**Step B: Navigate directly to Data Stream record page:**
```
{instanceUrl}/lightning/r/DataStream/{DataStreamRecordId}/view
```

**Benefits:**
- ✅ No UI search required - instant navigation
- ✅ Reliable - direct URL always works
- ✅ Fast - skip list view loading
- ✅ No search timing issues

---

## Error Handling & Retry Strategy

**🚨 Blank-Page Handling (Update File button not visible on record page)**

Salesforce frequently renders a blank/incomplete Data Stream record page on first navigation. The "Update File" button does not appear because the page never finished loading.

**Required behavior — Refresh Immediately:**
1. After every `browser_navigate` to a Data Stream record, take a snapshot
2. Check if "Update File" button is present in the snapshot
3. **If NOT present → Refresh the page IMMEDIATELY (no waiting, no element retry chain)**
4. Wait 5 seconds for refreshed page to load fully
5. Take new snapshot and recheck
6. Maximum 2 refresh attempts per Data Stream
7. If button still missing after 2 refreshes → Skip this Data Stream and continue

**🔄 General Retry Logic for Other Missing Elements**

For elements other than "Update File" button (e.g., Upload Files button, Deploy button):

**For Page-Level Elements:**
1. Take snapshot to verify page state
2. Refresh the current page using `browser_navigate` with current URL
3. Wait 5 seconds for page to fully reload
4. Take another snapshot to confirm page loaded correctly
5. Retry finding and clicking the element
6. If still not found → Skip this Data Stream and continue with next

**For Modal Elements (Upload Files button, Deploy button):**
1. Take snapshot to verify modal state
2. If button not found in modal:
   - Option A: Close modal and reopen by clicking Update File again
   - Option B: Wait 3-5 seconds and retry (element may still be loading)
3. Retry finding and clicking the element
4. If still not found → Skip this Data Stream and continue with next

**Maximum Retries:**
- Each element: 1 retry (total 2 attempts)
- Each Data Stream upload: Continue even if one step fails
- Overall workflow: Never fail completely - report all successes/failures at end

**When to Skip vs. Retry:**
- **Retry:** Element timing issues, page loading delays, modal animation delays
- **Skip:** Element truly doesn't exist, Data Stream not configured correctly, permissions issue

---

### Step 0 — Load Playwright tools

**CRITICAL: Load Playwright tool schemas before using them**

Use ToolSearch to load MCP Playwright tools:

```
ToolSearch(
  query: "select:mcp__plugin_playwright_playwright__browser_navigate,mcp__plugin_playwright_playwright__browser_click,mcp__plugin_playwright_playwright__browser_snapshot,mcp__plugin_playwright_playwright__browser_take_screenshot,mcp__plugin_playwright_playwright__browser_type,mcp__plugin_playwright_playwright__browser_wait_for,mcp__plugin_playwright_playwright__browser_file_upload",
  max_results: 10
)
```

This loads all necessary Playwright tools for browser automation.

---

### Step 0.5 — Capability gate: verify `browser_file_upload` is exposed (Mac auto-install fallback)

**Why this step exists:** the file upload to Salesforce's hidden `<input type="file">` element requires the Playwright MCP `browser_file_upload` tool. Anthropic's standard `@playwright/mcp` exposes it. Some Salesforce-internal Playwright MCP mirrors (Falcon-distributed AISuite browser MCP, etc.) do not. Without it, every Step 5–8 upload will fail.

This gate fires automatically and behaves differently per platform:

| Platform | `browser_file_upload` exposed? | Behavior |
|---|---|---|
| **Windows** | ✅ Yes (standard case) | Skip silently, run Step 1 |
| **Windows** | ❌ No (rare — non-standard MCP) | Print one-line note, continue. Skill may fail later at Step 5 — user installs manually if so. **Do NOT auto-install on Windows.** |
| **macOS** | ✅ Yes (standard case) | Skip silently, run Step 1 |
| **macOS** | ❌ No (Falcon-distributed MCP) | Auto-install `@playwright/mcp` via `npx`, auto-merge config into Claude Code MCP config (preserves existing MCPs), STOP with restart instructions |
| **Linux** | ✅ Yes / ❌ No | Same as Windows — note only, no auto-install |

The Mac-only auto-install matches the agent-level check in [AGENT.md](../../agents/data360-retail-installer/AGENT.md) (Playwright MCP capability check block). When the agent runs the install end-to-end, the agent's check fires first; this skill-level check is a defense-in-depth fallback for cases where the skill is invoked directly without going through the agent.

**Detection (cross-platform, runs unconditionally):**

```
ToolSearch(query: "select:mcp__plugin_playwright_playwright__browser_file_upload", max_results: 1)
```

If the result includes the tool definition → continue to Step 1.
If the result is empty / "No matching deferred tools found" → run the platform-aware fallback below.

**Platform-aware fallback (only fires when the tool is missing):**

```bash
# Detect OS — uname -s returns Darwin on macOS, MINGW*/MSYS_NT*/CYGWIN* on Windows Git Bash, Linux on Linux.
OS_KIND="$(uname -s 2>/dev/null || echo unknown)"

case "$OS_KIND" in
  Darwin)
    # macOS — auto-install + auto-config + restart prompt
    echo "🍎 macOS detected, and your active Playwright MCP doesn't expose browser_file_upload."
    echo "   Auto-installing @playwright/mcp@latest — no manual command needed."
    echo ""

    # Verify Node.js is present
    if ! command -v node >/dev/null 2>&1; then
      echo "❌ Node.js is not installed. Install via:  brew install node"
      echo "   (or download from https://nodejs.org/ — LTS version)"
      echo "   Then re-run this skill."
      exit 1
    fi

    # Pre-cache via npx (no global install, no sudo)
    echo "📦 Pre-caching @playwright/mcp@latest..."
    npx -y @playwright/mcp@latest --version >/tmp/playwright_mcp_install.log 2>&1
    PRECACHE_RC=$?
    if [ "$PRECACHE_RC" -ne 0 ]; then
      echo "❌ npx pre-cache failed (exit $PRECACHE_RC). Log:"
      tail -20 /tmp/playwright_mcp_install.log
      echo ""
      echo "   Try manually: npm cache clean --force && npx -y @playwright/mcp@latest --version"
      exit 1
    fi
    echo "✅ Pre-cache complete."

    # Merge into Claude Code MCP config — preserves any existing MCPs (Falcon, AISuite, etc.)
    CLAUDE_CFG_DESKTOP="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    CLAUDE_CFG_CLI="$HOME/.claude/claude_desktop_config.json"

    merge_mcp_config() {
      local CFG_PATH="$1"
      mkdir -p "$(dirname "$CFG_PATH")"
      $PYTHON_CMD - "$CFG_PATH" <<'PYEOF'
import json, os, sys
cfg_path = sys.argv[1]
existing = {}
if os.path.isfile(cfg_path):
    try:
        with open(cfg_path, 'r') as f:
            existing = json.load(f)
    except Exception:
        os.rename(cfg_path, cfg_path + '.bak')
        existing = {}
existing.setdefault('mcpServers', {})
if 'playwright' in existing['mcpServers']:
    print(f"  ℹ️  playwright MCP already in {cfg_path}")
else:
    existing['mcpServers']['playwright'] = {
        'command': 'npx',
        'args': ['-y', '@playwright/mcp@latest']
    }
    with open(cfg_path, 'w') as f:
        json.dump(existing, f, indent=2)
    print(f"  ✅ Added playwright MCP to {cfg_path}")
PYEOF
    }

    merge_mcp_config "$CLAUDE_CFG_DESKTOP"
    merge_mcp_config "$CLAUDE_CFG_CLI"

    # Surface the one-time restart instruction (cannot be automated — MCP loads at Claude startup)
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  🎉  All set! Just one quick restart and you're back on track."
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  I installed and configured the Playwright MCP for you. Claude"
    echo "  Code only loads MCP servers at startup, so it needs to reload"
    echo "  once to pick up the new tool. After that, you'll never see this"
    echo "  message again."
    echo ""
    echo "  ▸ EASIEST WAY (VS Code):"
    echo ""
    echo "      1.  Press  Cmd + Shift + P"
    echo "      2.  Type:  Developer: Reload Window"
    echo "      3.  Press  Enter"
    echo ""
    echo "  Other ways, in case VS Code isn't how you launch Claude:"
    echo ""
    echo "    • Claude CLI in Terminal:  type 'exit' (or Ctrl+D), then re-run 'claude'"
    echo "    • Claude Desktop app:      Cmd+Q to fully quit, then re-launch from Applications"
    echo ""
    echo "  Once Claude is back up, just re-run:"
    echo "      /datastream-file-upload <org_alias>"
    echo ""
    echo "  This skill will detect the new tool, skip this gate silently,"
    echo "  and pick up the upload exactly where it left off — nothing lost."
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    exit 0
    ;;

  MINGW*|MSYS_NT*|CYGWIN*)
    # Windows: NO auto-install. Note only.
    echo "ℹ️  Windows: browser_file_upload not exposed by active Playwright MCP."
    echo "   Skill will try to proceed — if Step 5 fails with 'tool not available',"
    echo "   install manually:  npx -y @playwright/mcp@latest --version"
    echo "   Add to %APPDATA%\\Claude\\claude_desktop_config.json and restart Claude."
    ;;

  Linux)
    echo "ℹ️  Linux: browser_file_upload not exposed. Same guidance as Windows above."
    ;;

  *)
    echo "ℹ️  Unknown OS ($OS_KIND). Skipping auto-install."
    ;;
esac
```

**Net effect:**
- Windows users with the standard Playwright MCP: zero output, zero behavior change.
- Mac users with Falcon MCP: auto-installs in background, asks for one Claude Code restart, resumes cleanly.
- Mac users with the standard Playwright MCP: zero output, zero behavior change.
- All other failure modes: non-blocking warning, skill continues.

**No existing functionality is changed.** Steps 1–9 below run byte-identical to before. This step only adds a pre-flight detection that prevents the most common Mac-side failure.

---

### Step 1 — Verify CSV file exists locally

Check if the required CSV file exists in the files directory:

Default directory: `MedTechDocuments`

Required file:
1. `pacemaker_iot_data.csv`

Run bash command to verify:

```bash
test -f "MedTechDocuments/pacemaker_iot_data.csv"
```

List file to confirm:

```bash
ls -lh "MedTechDocuments/pacemaker_iot_data.csv"
```

**If the file is missing:**
- Report that the file is missing
- Ask user to place `pacemaker_iot_data.csv` in the `MedTechDocuments/` folder at the repo root
- Cannot proceed without the file

---

### Step 2 — Query Data Stream Record IDs using SOQL

**✅ NEW APPROACH: Query Data Stream IDs directly instead of searching in UI**

**Step 2.1: Create temporary SOQL query file**

```bash
cat > query_datastreams.soql << 'EOF'
SELECT Id, Name FROM DataStream WHERE Name LIKE 'pacemaker_iot_data%' OR Name = 'pacemaker_iot_data'
EOF
```

**Why both LIKE and equality clauses?** Salesforce sometimes ships the data kit's Data Stream `Name` field with a version suffix (e.g. `pacemaker_iot_data_v2`) after a re-deploy. The `LIKE` pattern covers any version suffix; the equality covers the canonical name. Single round-trip handles both shapes.

**Step 2.2: Run SOQL query using the file**

```bash
sf data query --target-org <org_alias> --file query_datastreams.soql --json
```

**Why use --file instead of --query?**
- ✅ Avoids Windows command-line escaping issues with quotes
- ✅ More reliable across different shell environments
- ✅ Cleaner syntax for complex queries

**Parse JSON response to extract:**

| Data Stream Name | Field to Extract | Store As |
|---|---|---|
| pacemaker_iot_data | `result.records[].Id` | `PACEMAKER_IOT_DATA_ID` |

**Example response:**
```json
{
  "status": 0,
  "result": {
    "records": [
      {"Id": "1dsHu000000HmluIAC", "Name": "pacemaker_iot_data"}
    ]
  }
}
```

**If query fails or returns no records:**
- Report error: "Data Stream not found in org"
- Check if Data Kit metadata deployment completed
- Check if Data Kit API deployment completed
- Cannot proceed without the Data Stream ID

**Store this ID for Step 5 navigation.**

---

### Step 3 — Get org credentials

**CRITICAL: Get instance URL and access token from Salesforce CLI**

Run command:

```bash
sf org display --target-org <org_alias> --json
```

Extract from JSON response:

| Field | Description | Usage |
|---|---|---|
| `result.instanceUrl` | Org URL | Base URL for navigation |
| `result.accessToken` | Session access token | Used for `frontdoor.jsp?sid=` auto-login |

**Authentication is web-based via Salesforce CLI — no username/password is ever collected by this skill.**

**If sf org display fails:**
- Report error: "Org not authenticated"
- Guide user: `sf org login web -a <org_alias>`
- Stop execution

---

### Step 3.5 — Playwright MCP PNA preflight (RUN BEFORE STEP 4)

**Why this step exists.** Salesforce Lightning hosts (`*.my.salesforce.com`, `*.lightning.force.com`) and Data Cloud S3 presigned hosts sometimes resolve into RFC 6598 shared address space (`100.64.0.0/10`). Chrome's Private Network Access (PNA) policy classifies those IPs as "private" while the parent origin (Lightning) is "public" — so the browser silently blocks cross-origin resource loads and the S3 PUT. Symptoms include the `"Sorry to interrupt — CSS Error"` (auraErrorBox) on the Update File modal AND `Upload failed` at Progress: 0% for the browser-side S3 PUT. Neither Tier 2's Aura strip nor Tier 3's state reset resolves it — the block is enforced by Chrome and must be disabled at browser launch.

**Validated launch flags** (the ONLY sanctioned PNA bypass at the browser level):

```
browser.launchOptions.args:
[
  "--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights"
]
```

**Config lifecycle (mandatory — read in full).** These flags are read by Playwright MCP **only at process start**. Changing `launchOptions` on an already-running MCP does NOT take effect on the next `browser_navigate`. Applying the flags requires:

1. Write the Playwright MCP config file with the flags above. Recommended location: `~/.claude/playwright-mcp-pna-fix.json`. Schema (minimal):
   ```json
   {
     "browser": {
       "launchOptions": {
         "args": [
           "--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights"
         ]
       }
     }
   }
   ```
2. Update the active `.mcp.json` entries for `plugin_playwright_playwright` to load that config via `--config <path>`.
3. Invoke `/reload-plugins` in Claude Code so the MCP process restarts and picks up the new `launchOptions`.
4. Re-invoke `/datastream-file-upload`. The durable-state wrapper at the top of this skill resumes cleanly — no work is lost.

**⚠️ Cannot be applied mid-run.** If this skill discovers at Step 4 or later that the launch flags are not active AND PNA is blocking work (see detection below), it MUST:
- persist any recovery hints into `state.artifacts.datastream-file-upload.pnaReloadRequested = true`,
- print the reload instructions verbatim (see "Reload prompt" below),
- STOP cleanly (do NOT retry, do NOT rewrite the config on a loop, do NOT relaunch the browser hoping the flag is now active).

On the next invocation post-reload, this skill resumes normally.

**Preflight — run BEFORE Step 4 (browser launch):**

1. Check whether the config file at `~/.claude/playwright-mcp-pna-fix.json` exists AND contains both `--disable-features=BlockInsecurePrivateNetworkRequests` and `PrivateNetworkAccessSendPreflights` substrings.
   - If yes → assume the flags will be active in the launched browser; continue to Step 4.
   - If no → write the config file (idempotent — same schema every time), update `.mcp.json` to reference it, print the reload prompt below, persist `state.artifacts.datastream-file-upload.pnaReloadRequested = true`, and STOP.

2. **Do NOT rewrite** the config file on every invocation. The check above must be an idempotent read-and-only-write-if-missing operation. Repeated rewrites of an unchanged config are wasted work and produce noisy diffs in the operator's `~/.claude/` tree.

**Reload prompt (verbatim, use only when persisting `pnaReloadRequested`):**

```text
🔧 Playwright MCP PNA-bypass config installed at ~/.claude/playwright-mcp-pna-fix.json.

Salesforce Lightning and/or the Data Cloud S3 presigned host resolved
into RFC 6598 shared address space (100.64.x.y). Chrome's Private
Network Access policy blocks cross-origin loads to those addresses.

Playwright MCP reads its launchOptions only at process start, so this
skill cannot activate the fix inside the current MCP process. Please:

  1. Type  /reload-plugins  in Claude Code
  2. Wait for the window to come back
  3. Re-run  /datastream-file-upload <org_alias>

The skill's durable-state wrapper will resume it exactly where it
left off. No files or Data Stream progress are lost.
```

**Detection signals that trigger the STOP-and-request-reload path if reached mid-run (defence in depth — Step 4 onward):**

- `browser_console_messages` contains `net::ERR_BLOCKED_BY_PRIVATE_NETWORK_ACCESS_CHECKS`.
- An `auraErrorBox` / `"Sorry to interrupt — CSS Error"` dialog appears AND `browser_network_requests` shows a blocked request from `lightning.force.com` to `*.my.salesforce.com` OR to `*.s3.<region>.amazonaws.com`.
- `nslookup` / `dig` on the current org's `my.salesforce.com` host OR the presigned S3 host resolves to `100.64.x.y`.

**If any of the above fires and the preflight above says the flags are already installed** — the flags are on disk but the current MCP process was started before they were installed, or `.mcp.json` was not updated to reference the config. Persist `pnaReloadRequested=true`, print the reload prompt, and STOP.

---

### Step 4 — Launch browser and authenticate

**Use Playwright to open browser and navigate to org with the CLI access token**

Navigate via the frontdoor URL (auto-logs in using the existing CLI web session — no password prompt):

```
mcp__plugin_playwright_playwright__browser_navigate(
  url: "{instanceUrl}/secur/frontdoor.jsp?sid={accessToken}"
)
```

If the page redirects to a login form, the CLI session has expired. Stop and ask the user to run `sf org login web -a <org_alias>` again.

(No explicit wait — Step 4.5's `evaluate()` call auto-waits for the page to be in a state where `window.$A` is defined. That's the real gate; an arbitrary 3-5s sleep is just a guess.)

**✅ No need to navigate to Data Streams list - we'll use direct URLs with Record IDs from Step 2**

---

### Step 4.5 — Install Aura-layer payload interceptor (REQUIRED — fixes Salesforce restriction)

**🛠️ This step is what makes the Deploy click actually work.**

#### Why this step exists

When the user clicks **Deploy** inside the "Update Data Stream from a File" modal, the Lightning Web Component POSTs to `/aura?...aura.CdpDataStreams.patchUpdateDatastream=1`. The body is form-urlencoded — `message=<URL-encoded JSON>` — and the JSON contains an `advancedAttributes` block with two keys Salesforce now rejects for File-Upload data streams:

- `isDataStreamConfigValid`
- `delimiter`

The server returns:
```
Unable to update the data-stream - Advanced Attribute key
isDataStreamConfigValid cannot be patched for data streams
created using Uploaded Files connection
```

Salesforce's official workaround is "open DevTools and `delete e.input.advancedAttributes.isDataStreamConfigValid` before clicking Deploy." This step does that **programmatically** — wraps `XMLHttpRequest.send` and `window.fetch` so any outgoing request body that contains those keys gets sanitized in flight, regardless of how the LWC sends it.

#### Why other approaches DON'T work (validated against this org)

| Approach tried | Status flag | Data ingested? | Verdict |
|---|---|---|---|
| **Path A — Aura-layer interceptor (this step)** | ✅ Active | ✅ Yes | **Use this.** Lets the real Aura controller run end-to-end. |
| Path B — capture failed Aura POST + replay sanitized | ✅ Active | ❌ No | The replay flips the cosmetic status flag but skips the ingestion-job-submission code path inside the Aura controller |
| Path D — Playwright file upload + Connect REST PATCH `/services/data/v66.0/ssot/data-streams/{id}` | ✅ Active | ❌ No | Same problem as Path B — the public REST PATCH endpoint flips the flag but doesn't trigger the lakehouse ingestion job |

The pattern is unambiguous: **only Path A actually ingests the data**. Paths B and D pass the "status shows Active" smoke test but leave the DLO empty.

#### Install the interceptor — ONE evaluate() call before any modal interaction

Run this **once after Step 4 (home page)** AND **once after the `browser_navigate` to the Data Stream record page in Step 5**. The interceptor is idempotent — re-installing it is a no-op.

**🚨 OBSERVED FAILURE (2026-06-11, originally validated against the Retail installer's Customer Affinities stream; the same fix applies verbatim to the Healthcare kit's `pacemaker_iot_data` stream because the underlying `/aura?...patchUpdateDatastream=1` LWC path is identical) — interceptor MUST be reinstalled per record page.** The previous claim that "the interceptor lives in the page's window object and survives navigations within the same tab" is **wrong** for Lightning Experience. Each `browser_navigate` to `/lightning/r/DataStream/{id}/view` swaps the active iframe / page-window context, and `window.__dsAuraInterceptorInstalled` is `false` again on the new page. The XHR wrapper installed on the previous page does NOT cover the LWC that issues the `/aura?...patchUpdateDatastream=1` request from the new record page.

**Real-world consequence:** The first Deploy click fired with the interceptor installed only on the home page (the post-frontdoor landing). The DataStream record page had a fresh, unwrapped `XMLHttpRequest`. Salesforce rejected the request with `"Unable to update the data-stream - Advanced Attribute key delimiter cannot be patched for data streams created using Uploaded Files connection"`. After reinstalling the interceptor on the DataStream record page itself, the retry Deploy succeeded with `capturedCount: 1, kind: "xhr.aura-message", stripped: true`.

**Required pattern:**

1. After Step 4 (frontdoor → home page) → run the interceptor `evaluate()` once. Treat this as a sanity install only; do NOT rely on it covering downstream Deploy clicks.
2. **At the START of Step 5.1 — immediately after `browser_navigate` to the pacemaker_iot_data record page and `wait_for(time:5)`** — re-run the interceptor `evaluate()`. Use this short reinstall snippet (the long version with all 3 hooks is overkill; only the `XMLHttpRequest.send` hook is load-bearing because the LWC's POST goes through XHR):

   ```javascript
   () => {
     // Force-reinstall — Lightning SPA navigation swaps page context, so the
     // previous record's interceptor doesn't cover this one.
     delete window.__dsAuraInterceptorInstalled;
     window.__dsAuraCaptured = [];
     function sanitizeObj(node) {
       if (!node || typeof node !== 'object') return false;
       let changed = false;
       if (Array.isArray(node)) { for (let i=0;i<node.length;i++) if (sanitizeObj(node[i])) changed=true; return changed; }
       if (node.advancedAttributes && typeof node.advancedAttributes === 'object') {
         if ('isDataStreamConfigValid' in node.advancedAttributes) { delete node.advancedAttributes.isDataStreamConfigValid; changed=true; }
         if ('delimiter' in node.advancedAttributes) { delete node.advancedAttributes.delimiter; changed=true; }
       }
       for (const k of Object.keys(node)) if (sanitizeObj(node[k])) changed=true;
       return changed;
     }
     const _origSend = XMLHttpRequest.prototype.send;
     const _origOpen = XMLHttpRequest.prototype.open;
     XMLHttpRequest.prototype.open = function(method,url){ this.__dsMethod=method; this.__dsUrl=url; return _origOpen.apply(this, arguments); };
     XMLHttpRequest.prototype.send = function(body) {
       try {
         if (typeof body === 'string' && (body.includes('isDataStreamConfigValid') || body.includes('delimiter'))) {
           if (body.startsWith('message=')) {
             const m = body.match(/^message=([^&]*)/);
             if (m) {
               const decoded = decodeURIComponent(m[1]);
               const obj = JSON.parse(decoded);
               if (sanitizeObj(obj)) {
                 body = 'message=' + encodeURIComponent(JSON.stringify(obj)) + body.slice(m[0].length);
                 window.__dsAuraCaptured.push({ kind: 'xhr.aura-message', stripped: true });
               }
             }
           }
         }
       } catch (e) {}
       return _origSend.call(this, body);
     };
     window.__dsAuraInterceptorInstalled = true;
     return { reinstalled: true };
   }
   ```

3. **After EVERY Deploy click**, verify with the read-only check (`capturedCount > 0`, `kind: "xhr.aura-message"`, `stripped: true`). If `capturedCount === 0`, the interceptor was missing — STOP, do NOT navigate to the next stream, and surface the failure: data did not strip and the server-side rejection will appear shortly after with the "delimiter cannot be patched" error.

**Do NOT close the browser between Data Streams** — that part is still correct. The reinstall is fast (<50 ms) and runs entirely client-side; reusing the same browser session keeps your CLI auth + frontdoor login intact.

```
mcp__plugin_playwright_playwright__browser_evaluate
  function: "() => { /* Aura interceptor — see code below */ }"
  element: "install Aura-layer interceptor that strips isDataStreamConfigValid + delimiter from advancedAttributes"
```

**Interceptor code (paste verbatim into the `function` argument):**

```javascript
() => {
  if (window.__dsAuraInterceptorInstalled) {
    return { alreadyInstalled: true, captured: window.__dsAuraCaptured || [] };
  }
  window.__dsAuraCaptured = [];

  function sanitizeObj(node) {
    if (!node || typeof node !== 'object') return false;
    let changed = false;
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) {
        if (sanitizeObj(node[i])) changed = true;
      }
      return changed;
    }
    if (node.advancedAttributes && typeof node.advancedAttributes === 'object') {
      if ('isDataStreamConfigValid' in node.advancedAttributes) {
        delete node.advancedAttributes.isDataStreamConfigValid;
        changed = true;
      }
      if ('delimiter' in node.advancedAttributes) {
        delete node.advancedAttributes.delimiter;
        changed = true;
      }
    }
    for (const k of Object.keys(node)) {
      if (sanitizeObj(node[k])) changed = true;
    }
    return changed;
  }

  // ---- Hook 1: $A.enqueueAction (top-level Aura action queue) ----
  if (window.$A && typeof window.$A.enqueueAction === 'function') {
    const _origEnqueue = window.$A.enqueueAction.bind(window.$A);
    window.$A.enqueueAction = function(action) {
      try {
        if (action && typeof action.getParams === 'function') {
          const params = action.getParams();
          if (params && sanitizeObj(params)) {
            window.__dsAuraCaptured.push({ kind: 'aura.enqueueAction', stripped: true });
          }
        }
      } catch (e) {}
      return _origEnqueue(action);
    };
  }

  // ---- Hook 2: window.fetch ----
  const _origFetch = window.fetch.bind(window);
  window.fetch = async function(input, init) {
    try {
      if (init && typeof init.body === 'string') {
        const url = (typeof input === 'string' ? input : (input && input.url) || '');
        if (init.body.includes('isDataStreamConfigValid') || init.body.includes('delimiter')) {
          // Plain JSON body
          try {
            const obj = JSON.parse(init.body);
            if (sanitizeObj(obj)) {
              init = { ...init, body: JSON.stringify(obj) };
              window.__dsAuraCaptured.push({ kind: 'fetch', url: url.split('?')[0], stripped: true });
            }
          } catch (e) {}
          // Aura form-urlencoded `message=<encoded JSON>`
          if (init.body.startsWith('message=')) {
            try {
              const m = init.body.match(/^message=([^&]*)/);
              if (m) {
                const decoded = decodeURIComponent(m[1]);
                if (decoded.includes('isDataStreamConfigValid') || decoded.includes('delimiter')) {
                  const msgObj = JSON.parse(decoded);
                  if (sanitizeObj(msgObj)) {
                    const newBody = 'message=' + encodeURIComponent(JSON.stringify(msgObj)) + init.body.slice(m[0].length);
                    init = { ...init, body: newBody };
                    window.__dsAuraCaptured.push({ kind: 'fetch.aura-message', url: url.split('?')[0], stripped: true });
                  }
                }
              }
            } catch (e) {}
          }
        }
      }
    } catch (e) {}
    return _origFetch(input, init);
  };

  // ---- Hook 3: XMLHttpRequest.send (the actual transport the LWC uses) ----
  const _origSend = XMLHttpRequest.prototype.send;
  const _origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__dsMethod = method;
    this.__dsUrl = url;
    return _origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(body) {
    try {
      if (typeof body === 'string') {
        if (body.includes('isDataStreamConfigValid') || body.includes('delimiter')) {
          if (body.startsWith('message=')) {
            try {
              const m = body.match(/^message=([^&]*)/);
              if (m) {
                const decoded = decodeURIComponent(m[1]);
                const msgObj = JSON.parse(decoded);
                if (sanitizeObj(msgObj)) {
                  body = 'message=' + encodeURIComponent(JSON.stringify(msgObj)) + body.slice(m[0].length);
                  window.__dsAuraCaptured.push({
                    kind: 'xhr.aura-message',
                    url: (this.__dsUrl || '').split('?')[0],
                    stripped: true,
                  });
                }
              }
            } catch (e) {}
          } else {
            try {
              const obj = JSON.parse(body);
              if (sanitizeObj(obj)) {
                body = JSON.stringify(obj);
                window.__dsAuraCaptured.push({ kind: 'xhr', url: (this.__dsUrl || '').split('?')[0], stripped: true });
              }
            } catch (e) {}
          }
        }
      }
    } catch (e) {}
    return _origSend.call(this, body);
  };

  window.__dsAuraInterceptorInstalled = true;
  return { installed: true };
}
```

#### Verify the interceptor installed correctly

After the `evaluate()` call returns, the result must be `{ "installed": true }` (first run) or `{ "alreadyInstalled": true, ... }` (re-runs). If it's anything else, ABORT and surface the error to the user — proceeding without a working interceptor will cause every Deploy click to fail.

#### Verify the interceptor actually fired (after each Deploy click)

After each Data Stream's Deploy click in Steps 5–8, optionally run this read-only `evaluate()` to confirm a request was stripped:

```javascript
() => ({
  capturedCount: (window.__dsAuraCaptured || []).length,
  lastEntry: (window.__dsAuraCaptured || []).slice(-1)[0],
})
```

For a successful Deploy you should see `kind: "xhr.aura-message"` and `url: "/aura"` in the most recent entry. If `capturedCount` is 0 after a Deploy click, the interceptor missed the request — surface the error and STOP (the upload won't actually ingest data).

---

### Step 5 — Upload pacemaker_iot_data.csv

#### 5.0 — First-attempt recovery envelope (applies to every substep 5.2–5.6)

**Trigger (narrow):** if any substep 5.2–5.6 fails with one of the following signatures, run the recovery below BEFORE escalating to Tier 2 (Aura interceptor) or Tier 3 (state reset):

- An `auraErrorBox` / `"Sorry to interrupt — CSS Error"` dialog appears in the DOM (`document.querySelector('[role="dialog"].auraErrorBox')`).
- The Upload Files modal crashed after the file chooser dismissed but before the Deploy button rendered (`browser_evaluate` shows the modal still open but with 0 buttons matching `button:has-text("Deploy")` and no visible filename).
- A Deploy click appeared to fire but the modal did not close within 30 s and no `/aura?...patchUpdateDatastream=1` POST was recorded in `browser_network_requests`.

**🚨 PNA diagnostic gate — run BEFORE the refresh recovery below.** When an `auraErrorBox` / "CSS Error" signature fires, do NOT immediately refresh the record page. First inspect diagnostics:

1. `mcp__plugin_playwright_playwright__browser_console_messages(level: "error")`
2. `mcp__plugin_playwright_playwright__browser_network_requests()`

If either of the following is true:
- Console contains `net::ERR_BLOCKED_BY_PRIVATE_NETWORK_ACCESS_CHECKS`, OR
- A blocked request from the Lightning origin to `*.my.salesforce.com` or `*.s3.<region>.amazonaws.com` is present, OR
- `nslookup` on the current `my.salesforce.com` host or the S3 presigned host resolves to `100.64.x.y` (RFC 6598),

then this is a PNA-classification failure — **route to Step 3.5's PNA path immediately**. Repeatedly refreshing the LWC will not help; the browser was launched without `--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights`. Persist `state.artifacts.datastream-file-upload.pnaReloadRequested = true`, print Step 3.5's reload prompt verbatim, and STOP.

If none of the PNA signals are present → the CSS Error is a transient LWC render fault; proceed with the existing one-refresh recovery envelope below (unchanged).

**Recovery (ONE refresh + full re-run of 5.1–5.6):**

1. `browser_navigate` back to the DataStream record page URL (`{instanceUrl}/lightning/r/DataStream/{PACEMAKER_IOT_DATA_ID}/view`).
2. `browser_wait_for(time: 5)` for the record page to settle.
3. Re-install the Aura interceptor per Step 4.5 — the interceptor does not survive `browser_navigate`; without this step the retry's Deploy click will hit the same "delimiter cannot be patched" server-side rejection the interceptor is designed to prevent.
4. Re-run substeps 5.1.1 (blank-page check) → 5.2 (Update File) → 5.3 (leave Refresh Mode at its default — skill guidance is to not click the mode toggle; empirically the default mode's payload does not trigger the auraErrorBox we're recovering from) → 5.4 (Upload Files + `browser_file_upload`) → 5.6 (Deploy).

**Escalation after recovery:**
- ✅ Retry succeeds → proceed to Step 5.7 (verify deployment) → Step 9 (cleanup).
- ❌ Retry fails with the SAME signature → escalate to the Tier 1 → 2 → 3 rules at the top of this document. The refresh has proven the fault is not a transient LWC render.
- ❌ Retry fails with a DIFFERENT signature → apply the matching entry from the "Inline error router" table and retry the specific failing step, NOT the whole flow.

**⛔ ONE recovery attempt per upload run.** If the refresh + retry also fails, do NOT loop. Repeated refreshes on the same fault waste wall-clock and mask the real cause behind escalation-worthy errors.

**Reporting:**

```text
🔄 Upload attempt hit <signature> at step 5.<N> — applying recovery:
   1. Refreshing DataStream record page
   2. Re-installing Aura interceptor
   3. Re-running 5.1 → 5.6
```

---

**5.1 Navigate directly to pacemaker_iot_data Data Stream using Record ID**

**✅ NEW APPROACH: Direct URL navigation using SOQL query result from Step 2**

Navigate directly to the Data Stream record page:

```
mcp__plugin_playwright_playwright__browser_navigate(
  url: "{instanceUrl}/lightning/r/DataStream/{PACEMAKER_IOT_DATA_ID}/view"
)
```

Example:
```
https://storm-bf19b84cbeeb48.lightning.force.com/lightning/r/DataStream/1dsHu000000HmluIAC/view
```

Wait for Data Stream detail page to load (3 seconds):

```
mcp__plugin_playwright_playwright__browser_wait_for(
  time: 3
)
```

**Benefits of direct navigation:**
- ✅ No UI search required
- ✅ Instant page load
- ✅ No timing issues with search results
- ✅ Reliable and fast

**5.1.1 — IMMEDIATE BLANK-PAGE CHECK: Verify Update File button is visible (auto-refresh if missing)**

🚨 **CRITICAL:** Salesforce occasionally renders a blank/incomplete page on first navigation. Verify the "Update File" button is present BEFORE proceeding. If it is not, IMMEDIATELY refresh the page once (no waiting, no retry chain — refresh first, then check again).

Take snapshot to check if "Update File" button is rendered:

```
mcp__plugin_playwright_playwright__browser_snapshot()
```

**If "Update File" button NOT visible in snapshot (blank page detected):**

```
🔄 Blank page detected - Update File button not found. Refreshing page immediately...
```

Refresh the page IMMEDIATELY:

```
mcp__plugin_playwright_playwright__browser_navigate(
  url: "{instanceUrl}/lightning/r/DataStream/{PACEMAKER_IOT_DATA_ID}/view"
)
```

Wait 5 seconds for the refreshed page to fully load:

```
mcp__plugin_playwright_playwright__browser_wait_for(
  time: 5
)
```

Take another snapshot to confirm "Update File" button is now visible:

```
mcp__plugin_playwright_playwright__browser_snapshot()
```

**If still not visible after immediate refresh:**
- Refresh ONE more time (max 2 refresh attempts)
- Wait 5 seconds
- If still not visible → Report error and skip this Data Stream

**If "Update File" button IS visible:**
- ✅ Page rendered correctly, proceed to Step 5.2

**5.2 Click Update File button**

Click the now-visible Update File button:

```
mcp__plugin_playwright_playwright__browser_click(
  selector: "button:has-text('Update File')"
)
```

**If click fails (rare — button was visible but click intercepted):**
- Refresh page immediately
- Wait 5 seconds
- Retry click once
- If still fails → Skip this Data Stream and continue with next upload

Wait for file selection dialog to appear:

```
mcp__plugin_playwright_playwright__browser_wait_for(
  selector: "input[type='file']",
  timeout: 5000
)
```

**5.3 Refresh Mode — first pass leaves Full Refresh default; second pass (only if 5.9 detects the double-quote artifact) clicks Upsert**

Salesforce ships this modal with **Full Refresh preselected** (FULL_REFRESH card carries `aria-checked="true"`; the UPSERT card carries `aria-checked="false"`).

**On the FIRST attempt at this step in a given skill run:** leave the default alone — **skip mode selection entirely** and go directly to step 5.4 (Upload Files). This matches the operator preference (faster ingestion, one fewer click, no race condition against the file chooser).

**On the SECOND attempt** — reached only if Step 5.9 below detected that the formula fields `Party_Identification_Name__c` / `Party_Identification_Type__c` came out of ingestion wrapped in extra double quotes — the flow re-enters Step 5.2, and at this point Step 5.3 MUST click Upsert:
- Snapshot the modal, find `[data-tid="UPSERT"]` on the `<runtime_cdp-data-stream-extended-data-source>` host element
- Click it
- Re-snapshot and verify `aria-checked="true"` on `[data-tid="UPSERT"]` AND `aria-checked="false"` on `[data-tid="FULL_REFRESH"]`
- If verification fails, retry the click once; if it still fails, STOP and surface (the mode toggle silently reverting is a real Salesforce bug — better to fail loudly than deploy in the wrong mode)
- Only after verified `aria-checked` state → click Upload Files

**Why the two-pass pattern:** Full Refresh completes faster but has a known bug (validated 2026-08-05 in HCMetdTechEPICV4thAugust2026) where the DLO's formula-field projection leaves string constants wrapped in double quotes — e.g. `Party_Identification_Type__c` returns `'Device Identifier'` with the wrapping quotes intact instead of `Device Identifier`. That breaks Identity Resolution's downstream match rule on `ssot__IdentificationNumber__c`: `matchedSourceProfiles` stays at 0 and `consolidationRate` at 0%. Upsert triggers a DLO field-projection rebuild that emits the formula output cleanly. So we try Full Refresh first (fast happy path), verify the projection came out clean in Step 5.9, and only fall back to Upsert if the artifact is present.

**5.4 Upload pacemaker_iot_data.csv**

**✅ WORKING SOLUTION (Validated 2026-05-25):**

**CRITICAL: Click on the visible "Upload Files" text to trigger file chooser**

**🔄 RETRY LOGIC: Try multiple selectors, if all fail, refresh modal and retry**

Try multiple fallback selectors in order:

**Attempt 1 - Label selector (most reliable):**
```
mcp__plugin_playwright_playwright__browser_click(
  target: "label:has-text('Upload Files')",
  element: "Upload Files label"
)
```

**If that fails, try Attempt 2 - Text selector:**
```
mcp__plugin_playwright_playwright__browser_click(
  target: "text=Upload Files",
  element: "Upload Files button"
)
```

**If both fail:**
1. Take snapshot to debug the modal state
2. Close the modal by clicking Cancel/Close button
3. Wait 2 seconds
4. Re-click "Update File" button to reopen modal
5. Wait 2 seconds for modal to load
6. Retry clicking "Upload Files" using label selector

**If still fails after modal refresh:**
- Report error: "Unable to click Upload Files button"
- Skip this Data Stream and continue with next upload
- Mark as failed in final summary

**Important:** Do NOT try to click the hidden `input[type="file"]` element directly - it will timeout due to label overlay intercepting pointer events. Always click on the visible "Upload Files" text or label element.

The file chooser will now open and be ready for file upload.

Upload the CSV file using relative path:

```
mcp__plugin_playwright_playwright__browser_file_upload(
  paths: ["MedTechDocuments/pacemaker_iot_data.csv"]
)
```

**Note:** Use relative paths from the project root. Absolute paths outside the project directory will be rejected by MCP security policies.

**🚨 CRITICAL: Handle File Access Denied Errors**

If the file upload fails with "access denied" or permission errors:

1. **Close the browser immediately:**
   ```
   mcp__plugin_playwright_playwright__browser_close()
   ```

2. **Wait 5 seconds for cleanup:**
   ```
   bash: sleep 5
   ```

3. **Restart from Step 3 (Launch browser):**
   - Re-launch browser
   - Re-authenticate
   - Navigate back to Data Streams
   - Retry the upload from the beginning

This resolves file permission locks that can occur during browser automation.

(No explicit wait — the next click on the existing-model dropdown auto-waits for the model UI to appear. That UI only renders once upload is fully complete, so it's a meaningful gate. No success-path screenshot — only screenshot on failure.)

**Technical Notes:**

**Why Data Streams don't have REST API (Investigation Results):**
- ❌ Standard REST API: `/services/data/v66.0/sobjects/ssot__DataStream__c` - NOT SUPPORTED
- ❌ Connect API: `/services/data/v66.0/connect/data-cloud` - NOT FOUND
- ❌ Einstein API: `/services/data/v66.0/einstein/data-streams` - NOT FOUND

**Key Difference from Agentforce Data Library:**
- **Data Libraries**: Have REST API endpoint → Can use curl with presigned S3 URLs
- **Data Streams**: NO REST API → Must use browser automation via Playwright MCP

**How Browser Automation Works:**
- Lightning Web Components hide `<input type="file">` elements behind label overlays
- **Solution:** Click the visible "Upload Files" text (not the hidden input)
- Playwright can then interact with the opened file chooser
- File upload completes successfully via `browser_file_upload` tool

**5.5 Select Existing Model**

🆕 **NEW STEP:** After the file upload completes (and BEFORE clicking Deploy), select the existing model that matches the Data Stream.

For **pacemaker_iot_data** Data Stream → select existing model whose name matches the Data Stream name pattern (e.g., `pacemaker_iot_data`).

Take a snapshot to locate the model selection UI:

```
mcp__plugin_playwright_playwright__browser_snapshot()
```

Click the "Select Existing Model" radio/option (if a choice between New/Existing model is shown):

```
mcp__plugin_playwright_playwright__browser_click(
  target: "label:has-text('Select Existing Model'), input[type='radio'][value='existing'], lightning-radio-group label:has-text('Existing')",
  element: "Select Existing Model option"
)
```

Wait for the existing-model dropdown to populate:

```
mcp__plugin_playwright_playwright__browser_wait_for(
  time: 2
)
```

Open the existing-model combobox:

```
mcp__plugin_playwright_playwright__browser_click(
  target: "combobox[aria-label*='Existing Model' i], combobox[aria-label*='Model' i], lightning-combobox button",
  element: "Existing Model dropdown"
)
```

Pick the model whose name matches the Data Stream name pattern (`pacemaker_iot_data` for the pacemaker_iot_data Data Stream). Try matching by closest name:

```
mcp__plugin_playwright_playwright__browser_click(
  target: "lightning-base-combobox-item:has-text('pacemaker_iot_data'), [role='option']:has-text('pacemaker_iot_data')",
  element: "pacemaker_iot_data existing model option"
)
```

**Naming pattern reference:**

| Data Stream | Existing Model Name Pattern |
|---|---|
| pacemaker_iot_data | `pacemaker_iot_data` |

Wait 1 second for the selection to register:

```
mcp__plugin_playwright_playwright__browser_wait_for(
  time: 1
)
```

**Retry logic:**
- If matching model not found in dropdown → snapshot, log available options, pick the closest fuzzy match (case-insensitive, ignore spaces/underscores)
- If no existing model option exists at all → log warning and proceed with default
- Max 1 retry per element

**5.6 Click Deploy button**

**🛠️ INTERCEPTOR PRECONDITION:** The Aura-layer interceptor from **Step 4.5** MUST be **(re)installed on THIS Data Stream's record page** before this click. The home-page install does NOT survive `browser_navigate` to `/lightning/r/DataStream/{id}/view` — Lightning swaps the page-window context. If `window.__dsAuraInterceptorInstalled === false` at this point, the Deploy click will fail server-side with `"Advanced Attribute key delimiter cannot be patched for data streams created using Uploaded Files connection"`. Per Step 4.5's required pattern, run the short reinstall `evaluate()` immediately after navigating to this record page (Step 5.1) — well before reaching this click. After clicking Deploy, verify with `window.__dsAuraCaptured.length > 0` and `lastEntry.kind === 'xhr.aura-message'`. If `capturedCount === 0`, the interceptor was missing — STOP and re-run the reinstall + Deploy retry. (See Step 4.5 for the full rationale and code.)

**🔄 RETRY LOGIC: If Deploy button not found or disabled, wait and retry**

Click the Deploy button to start file processing:

```
mcp__plugin_playwright_playwright__browser_click(
  target: "button:has-text('Deploy')",
  element: "Deploy button"
)
```

**If button click fails (timeout or not found):**
1. Take snapshot to check button state
2. Check if button is disabled (file upload may not have completed)
3. Wait 5 seconds for file upload to complete
4. Try clicking Deploy button again
5. If still fails, report error and skip this Data Stream

(No explicit wait — Playwright auto-waits before the next `browser_navigate` to Step 9. Salesforce processes the data ingestion server-side after Deploy returns; the skill does not need to babysit it.)

**5.7 Verify deployment initiated**

The modal will close and you'll return to the Data Stream page. Confirm the Deploy click was accepted (modal closed, no error dialog). At this point ingestion is running server-side.

Report:
```text
✅ pacemaker_iot_data.csv uploaded successfully
   Data Stream: pacemaker_iot_data
   File: pacemaker_iot_data.csv
   Status: Deploy accepted — waiting for ingestion to complete
```

**Proceed to Step 5.8 (poll until Success) before moving on.**

---

**5.8 Poll Data Stream ingestion status until Success (BLOCKING gate before Step 9 / next skill)**

🚨 **Hard rule:** the skill MUST NOT return control to the workflow (Step 9 cleanup + `refresh-data-cloud-components` invocation in Step 9.4) until the pacemaker_iot_data Data Stream's last-run status is **Success**. If it is `Pending`, `Running`, `Scheduled`, or `In Progress`, wait and re-check. Only `Success` (or a terminal failure) exits this loop.

**Why this gate exists:** the downstream skill (`refresh-data-cloud-components`) refreshes Identity Resolution + Calculated Insights against the pacemaker_iot_data DLO. If IR/CI runs while ingestion is still `Pending`, they compute against an empty or partial DLO and finish with `sourceProfiles: 0`. The previous run in HCMetdTechEPICV4thAugust2026 only got 144 unified profiles because ingestion happened to finish before IR ran — that timing was luck, not correctness. Making the wait explicit removes the race.

**Preferred check — salesforce-data360 MCP (clean, no browser, matches how refresh-data-streams polls):**

Load the tool once:
```
ToolSearch(query: "select:mcp__salesforce-data360__execute", max_results: 1)
```

Then poll every 30 seconds, up to a maximum of 20 minutes (40 polls):

```
mcp__salesforce-data360__execute(
  tool: "d360_datastream_get",
  args: { "dataStreamName": "<PACEMAKER_IOT_DATA_INTERNAL_NAME>" }
)
```

`<PACEMAKER_IOT_DATA_INTERNAL_NAME>` is the `Name` field from Step 2's SOQL query — it is the versioned internal name (e.g. `pacemaker_iot_data_1777421200382`), NOT the human-readable `Label`. Use whatever the Step 2 query returned.

Read `lastRunStatus` (or the equivalent status field in the response — response schemas vary slightly across releases; look for the most-recent-run status). Match on the following:

| Value | Meaning | Action |
|---|---|---|
| `Success` / `SUCCESS` / `Completed` | Ingestion finished, DLO populated | ✅ Exit loop, proceed to Step 9 |
| `Pending` / `Scheduled` / `Queued` | Job accepted but not started | ⏳ Wait 30s, re-poll |
| `Running` / `In Progress` / `Executing` | Job actively ingesting | ⏳ Wait 30s, re-poll |
| `Failed` / `Error` / `Aborted` | Terminal failure | ❌ Surface error (per Step 10), do NOT invoke `refresh-data-cloud-components` |
| Anything else | Unknown state | ⏳ Log the value, wait 30s, re-poll (up to the 20-min cap) |

**Fallback check — SOQL (recommended; use if the MCP tool is unavailable OR simply preferred):**

Write the query to a file to avoid Windows shell quoting issues, then run it:

```bash
cat > query_ds_status.soql << 'EOF'
SELECT Id, Name, DataStreamStatus, ImportRunStatus FROM DataStream WHERE Id = '<DATASTREAM_ID>'
EOF
sf data query --target-org <org_alias> --file query_ds_status.soql --json
rm -f query_ds_status.soql
```

`<DATASTREAM_ID>` is the record ID from Step 2's SOQL query (e.g. `1dsgK000001CPK9QAO`).

Read `result.records[0].ImportRunStatus` — this is the authoritative field for the most-recent-run terminal status on a File-Upload Data Stream. Apply the same status table above. (`DataStreamStatus` in the same row is the stream-level state — `ACTIVE` / `UnderConstruction` — not per-run; keep it in the query for a quick sanity read but gate on `ImportRunStatus`.)

Validated 2026-08-05 against `1dsgK000001CPK9QAO` in `HCMetdTechEPICV4thAugust2026`: returned `DataStreamStatus=ACTIVE, ImportRunStatus=SUCCESS` immediately after the Deploy click landed.

**Timeout policy (20-min cap):**
- Typical ingestion for a ~40 KB CSV completes in under 3 minutes.
- If the poll is still `Pending` / `Running` at the 20-minute mark → surface a warning, do NOT auto-continue to `refresh-data-cloud-components`, and ask the user whether to keep waiting or abort. Silent auto-continuation past 20 minutes is not allowed — it usually indicates a stuck job that a human should look at.

**Report during polling (optional, every 3rd poll to keep output tight):**
```text
⏳ Waiting for pacemaker_iot_data ingestion:
   Last observed status: <status>
   Elapsed: <mm:ss>
   Next poll in: 30s
```

**On success — proceed to Step 9:**
```text
✅ pacemaker_iot_data ingestion complete
   Final status: Success
   Elapsed: <mm:ss>
   Safe to proceed with refresh-data-cloud-components
```

**Do NOT skip this step even if you "think" ingestion is fast.** The 30-second first poll is cheap; if the status is already `Success` the loop exits immediately and total added time is <1 second. The gate is designed to be a no-op on the happy path and a save on the slow path.

---

**5.9 Formula-field projection check (Full-Refresh double-quote artifact) — MANDATORY after 5.8 confirms Success**

🚨 **THIS IS A MANDATORY, ORDERED SEQUENCE OF MCP CALLS — NOT PSEUDOCODE, NOT DOCUMENTATION.**
🚨 **The check below MUST execute every single run after Step 5.8 returns `SUCCESS`. There is no "skip if you think it's clean" path.**
🚨 **The skill MUST NOT proceed to Step 9 (or to `/refresh-data-cloud-components`) until the MANDATORY success report block at the bottom of this step has been printed verbatim.** If that block is absent from the run log, Step 5.9 did not execute and the skill must be re-invoked.

**Purpose:** verify the ingested DLO returned clean formula-field values. If Full Refresh (the mandatory first-pass mode in Step 5.3) triggered the known Salesforce projection bug, the formula fields on `pacemaker_iot_data__dll` come back wrapped in extra double quotes. If left uncorrected, this silently breaks the downstream Identity Resolution match rule (0 matched profiles, 0% consolidation rate — validated 2026-08-05 in HCMetdTechEPICV4thAugust2026, and observed silently proceeding without check on 2026-08-17 in hcInstall). This step detects the artifact and, if present, loops back to Step 5.2 for a second-pass Upsert deploy.

**🚨 First-pass mode is FIXED to Full Refresh — no exceptions.** Step 5.3's first attempt MUST leave Full Refresh as the selected mode (Salesforce ships the modal with FULL_REFRESH preselected — don't touch the toggle). Upsert is ONLY reached via this step's second-pass fallback below, and only if the double-quote artifact is detected. Never start a fresh run in Upsert mode.

---

**MANDATORY MCP call sequence — run every time Step 5.8 returns `SUCCESS`:**

**MCP Call 1 — Load the tool schema:**
```
ToolSearch(query: "select:mcp__salesforce-data-cloud-queries__post_dc_query_sql", max_results: 1)
```

**MCP Call 2 — Query the DLO's formula fields:**
```
mcp__salesforce-data-cloud-queries__post_dc_query_sql(
  sql: "SELECT \"Party_Identification_Name__c\",\"Party_Identification_Type__c\" FROM \"pacemaker_iot_data__dll\" LIMIT 5"
)
```

**MCP Call 3 — Classify the returned values (in-memory, no tool call):**

For EACH row in `data[]`, inspect both string values. The two fields are formula-computed string constants — the CORRECT values are `Pacemaker Serial Number` and `Device Identifier` respectively, as bare strings with NO surrounding quote characters.

Decision rule (applied to every returned row):

| Row value observed | Classification | Action |
|---|---|---|
| Bare string `Pacemaker Serial Number` (starts with `P`, no `"` or `'` as first/last char) | ✅ Clean | Continue |
| Wrapped `"Pacemaker Serial Number"` (literal `"` as first AND last char of the string) | ❌ Double-quote artifact | Trigger second-pass fallback |
| Wrapped `'Pacemaker Serial Number'` (literal `'` as first AND last char of the string) | ❌ Single-quote artifact | Trigger second-pass fallback |
| Anything else (empty, null, different text) | ❌ Unexpected | Trigger second-pass fallback |

If ANY row of the 5 returned trips the artifact rule, the whole check fails and the second-pass fallback fires. Do NOT declare success based on "most rows look clean" — one bad row is enough to fail Identity Resolution downstream.

---

**IF ALL ROWS ARE CLEAN → MANDATORY success report (see block at the bottom of this step). Do NOT proceed to Step 9 without printing it.**

**IF ANY ROW IS WRAPPED → one-shot second-pass fallback (Upsert):**

1. Log the diagnostic to the user:
   ```text
   ⚠  Full Refresh projection bug detected — formula fields returned wrapped in quotes:
      Party_Identification_Name__c: "Pacemaker Serial Number" (expected: Pacemaker Serial Number)
      Party_Identification_Type__c: "Device Identifier"       (expected: Device Identifier)

   Re-running the file upload in Upsert mode to rebuild the DLO field projection.
   This is a known Salesforce bug; the second-pass Upsert clears it.
   ```
2. Return to Step 5.1 (navigate to record page + reinstall interceptor).
3. Run Step 5.2 (click Update File) normally.
4. **In Step 5.3, take the SECOND-ATTEMPT branch** — click Upsert and verify `aria-checked="true"` on `[data-tid="UPSERT"]` per Step 5.3's second-pass instructions.
5. Run Step 5.4 (Upload Files + `browser_file_upload`) — same CSV, same PNA bypass, same Deploy click.
6. Run Step 5.8 again — poll `ImportRunStatus` until `SUCCESS`.
7. **Re-run MCP Calls 1–3 above.** Re-classify every returned row.
   - If EVERY row now comes back clean → print the MANDATORY success report below with `Refresh mode used: Upsert (fallback)` and proceed to Step 9.
   - If ANY row is STILL wrapped → STOP. Do NOT print the success report. Exit the skill non-zero and surface the diagnostic — the platform did not self-heal on the second attempt and downstream skills MUST NOT run.

**⛔ ONE fallback attempt maximum.** The pattern is Full Refresh → check → Upsert if needed → check → done-or-surface. Do NOT loop three times. If the second attempt still shows wrapped values, the third would just repeat the same failure — surface and stop.

---

**🚨 MANDATORY success report — MUST be printed verbatim before Step 9 can run:**

```text
✅ pacemaker_iot_data formula-field projection verified clean
   Party_Identification_Name__c sample: Pacemaker Serial Number
   Party_Identification_Type__c sample: Device Identifier
   Refresh mode used: <Full Refresh | Upsert (fallback)>
   Rows verified: 5
   Safe to proceed to Step 9 (cleanup + next skill).
```

**If this block is absent from the run log, Step 5.9 did not execute.** The Preconditions gate on `/refresh-data-cloud-components` (see Step 9.4 handoff) checks for it — a missing report line is treated as a hard failure of Step 5.9 and blocks the downstream skill chain.

**Rationale for keeping Full Refresh as the first-pass default:** Full Refresh completes faster than Upsert and is the operator preference on the happy path. The projection bug does not fire every time (Salesforce release/tenant variance), so paying the Upsert cost on every install would be overkill. The check-then-fallback pattern gets us the fast path when it works and self-heals when it doesn't — one skill, both modes, no user intervention needed. The mandatory report line ensures the check can never be silently skipped: a run that omits it is provably incomplete.

---
### Step 9 — Close browser and cleanup

**Step 9.1: Close the browser**

```
mcp__plugin_playwright_playwright__browser_close()
```

**Step 9.2: Delete temporary SOQL query file**

**IMPORTANT: Clean up the temporary file created in Step 2**

```bash
rm query_datastreams.soql
```

This removes the temporary SOQL query file to keep the workspace clean.

**Step 9.3: Generate final report**

```text
📤 Data Stream File Upload Complete!

Org: <org_alias>
Instance: {instanceUrl}

═══════════════════════════════════════════════════

📁 File Uploaded:

1. ✅ pacemaker_iot_data
   File: pacemaker_iot_data.csv
   Data Stream: pacemaker_iot_data
   Status: Deployed

═══════════════════════════════════════════════════

✅ File uploaded successfully!

Next Step: Proceeding to Refresh Data Cloud Components...
```

**Step 9.4: Auto-invoke next skill**

⚠️ **Preconditions — BOTH gates must have passed:**
- **Step 5.8** (Data Stream ingestion `ImportRunStatus = SUCCESS`). Timeout / terminal failure → do NOT invoke `refresh-data-cloud-components`.
- **Step 5.9** (formula-field projection check returned clean string values on the first-pass Full Refresh OR the one-shot Upsert fallback). Second-attempt-still-wrapped → do NOT invoke `refresh-data-cloud-components`; surface the diagnostic and stop.

🚨 **Step 5.9 report-line check — MANDATORY.** Before invoking `refresh-data-cloud-components`, confirm the run log contains the verbatim line `✅ pacemaker_iot_data formula-field projection verified clean` (emitted by Step 5.9's mandatory success block). If that line is absent, Step 5.9 did not execute this run — treat as hard failure, do NOT hand off to the next skill, and surface: "Step 5.9 formula-field projection check did not run — re-invoke /datastream-file-upload to complete it."

If either gate did not exit clean, halt the skill and report — do NOT hand off to the next skill. The downstream IR/CI refresh would compute against the projection-broken DLO and produce 0 matched profiles / 0% consolidation.

After the file is uploaded successfully AND both gates are clean, automatically invoke the next skill in the installation workflow:

```
Skill(
  skill: "refresh-data-cloud-components",
  args: "org_alias: <org_alias>"
)
```

The downstream skill authenticates via the Salesforce CLI web session (`sf org login web`) — no credentials are passed between skills.

This ensures seamless continuation of the Data360 Retail installation workflow.

---

### Step 10 — Handle errors gracefully

If any upload fails, provide clear error message:

```text
❌ Data Stream File Upload Failed

Org: <org_alias>

Data Stream Failed: <data_stream_name>
File: <file_name>
Error: <error_message>

Possible Causes:
• Data Stream not found in org
• File format incorrect (not CSV)
• File path incorrect
• Data Cloud not enabled
• Missing permissions

Suggested Fixes:
✅ Verify Data Stream exists: Setup → Data Cloud → Data Streams
✅ Check file format: Must be CSV with headers
✅ Check file path: MedTechDocuments/[filename]
✅ Verify Data Cloud enabled: Setup → Data Cloud → Settings
✅ Check permissions: Setup → Users → Permission Sets → Data Cloud Admin

Already Uploaded:
<list of successfully uploaded files>

Remaining:
<list of files not yet uploaded>

Would you like me to retry the failed upload?
```

Common errors:

| Error | Suggested Fix | Retry Strategy |
|---|---|---|
| Update File button not found (blank page) | Salesforce rendered blank record page | ✅ **Refresh page IMMEDIATELY** (no waiting), max 2 refreshes |
| "Upsert" mode button not found | Modal not fully loaded — Refresh Mode is a button group, not a picklist | ✅ Wait 2s, snapshot, try fallback selectors (label, role=radio, text=). If still missing, proceed (Upsert may be default) |
| Clicked Refresh Mode but state didn't change | Wrong selector matched a different element | ✅ Snapshot, verify aria-pressed/aria-checked on the Upsert button, try next fallback selector |
| Upload Files button not found | Modal not fully loaded or label overlay issue | ✅ Close/reopen modal, use label selector |
| Existing Model option not found | Model UI may not render until upload completes | ✅ Wait 3s after upload, retry once. If missing, proceed with default |
| Specific model name not in list | Model name pattern mismatch | ✅ Fuzzy-match (case-insensitive, ignore _/spaces). If still none, log and proceed |
| Deploy button not found/disabled | File upload or model selection incomplete | ✅ Wait 5s, retry once |
| Data Stream not found | Verify Data Stream exists and Connection Type is "File Upload" | ❌ Skip and continue with next |
| File not found | Check file path and ensure file exists locally | ❌ Stop workflow (cannot upload) |
| Browser timeout | Increase wait timeout and refresh page | ✅ Refresh and retry once |
| File access denied / Permission error | Close browser, wait 5 seconds, restart from Step 3 (Launch browser), retry upload | ✅ Full browser restart |

---

## Important Rules

**CRITICAL - Execution Sequence:**
- 🚨 **ALWAYS upload files in SERIES (sequential order) - NEVER in parallel**
- 🚨 **Complete one Data Stream upload entirely before starting next**
- 🚨 **Wait for Deploy to complete before moving to next upload**
- 🚨 **Do NOT close browser between uploads - reuse same session**

**CRITICAL - File Handling:**
- ✅ **Verify file exists before attempting upload**
- ✅ **Use exact file names as specified**
- ✅ **Check file size is reasonable (< 150MB)**
- ✅ **Ensure file is CSV format with headers**

**CRITICAL - Browser Automation:**
- ✅ **ONLY use MCP Playwright tools** - Never generate JavaScript
- ✅ **Click visible "Upload Files" text** - NOT the hidden input element
- ✅ **Take screenshots at key steps** for verification
- ✅ **Wait for elements to appear** before clicking
- ✅ **Use time-based waits** (2-3 seconds) for modal/page loads instead of element-based selectors

**CRITICAL - Error Handling:**
- ✅ **If one upload fails, continue with remaining uploads**
- ✅ **Report all successes and failures at the end**
- ✅ **Automatic retry logic enabled:** Refresh page/modal once when elements not found
- ✅ **Maximum 1 retry per element** (2 total attempts)
- ✅ **Provide actionable error messages with fix suggestions**
- 🔄 **Element not found → Refresh → Retry → Skip if still fails**

**General Rules:**
- NEVER hardcode org names — always use provided org_alias parameter
- NEVER suggest manual completion - automate everything
- ALWAYS verify files exist before starting browser automation
- ALWAYS take screenshots at critical steps
- ALWAYS close browser when done
- ALWAYS provide comprehensive summary report
- Estimated upload time: 2-5 minutes per Data Stream
- Total estimated time: 10-20 minutes for all 4 uploads
- **🚨 If file upload encounters "access denied" errors:** Close browser, wait 5 seconds, restart from Step 3 (Launch browser) and retry

---

## Example Usage

### Example 1: User provides org name

**User:** "Upload Data Stream files to MyRetailOrg"

**Skill:**
1. Verifies pacemaker_iot_data.csv exists in "MedTechDocuments/"
2. Gets org credentials: `sf org display`
3. Launches browser and navigates to Data Cloud
4. Uploads pacemaker_iot_data.csv → Deploys → Verifies
5. Closes browser
6. Reports summary with upload status

---

### Example 2: Error handling - File not found

**User:** "Upload Data Stream files to TestOrg"

**Skill:** [Verifies files]

**Error:** `File not found: MedTechDocuments/pacemaker_iot_data.csv`

**Skill:**
```text
❌ File Verification Failed

Org: TestOrg

Missing File:
• pacemaker_iot_data.csv

Location Checked:
MedTechDocuments/

Suggested Fix:
1. Ensure `pacemaker_iot_data.csv` exists in the `MedTechDocuments/` folder at the repo root
2. Retry upload

Cannot proceed without the required CSV file.
```

---

### Example 3: Error handling - Data Stream not found

**User:** "Upload Data Stream files to MyOrg"

**Skill:** [Opens pacemaker_iot_data Data Stream]

**Error:** `Data Stream "pacemaker_iot_data" not found`

**Skill:**
```text
⚠️ Data Stream Not Found

Org: MyOrg

Data Stream: pacemaker_iot_data
Connection Type Expected: File Upload

This Data Stream must exist before uploading files.

Suggested Fix:
1. Navigate to Setup → Data Cloud → Data Streams
2. Verify "pacemaker_iot_data" Data Stream exists
3. Check Connection Type is "File Upload"
4. If missing, create Data Stream or deploy Data Kit metadata first

Cannot proceed — the pacemaker_iot_data stream is the only file upload target in the Healthcare kit.
```

---

## Success Criteria

Upload is successful when:

✅ `pacemaker_iot_data.csv` exists locally in `MedTechDocuments/`
✅ Org authentication validated via `sf org display`
✅ Browser launched successfully
✅ pacemaker_iot_data Data Stream record page loaded via direct URL navigation
✅ "Update File" button clicked
✅ Refresh Mode left at Full Refresh default (no click needed)
✅ "Upload Files" text clicked successfully (triggers file chooser)
✅ pacemaker_iot_data.csv uploaded (100% progress shown)
✅ Existing model `pacemaker_iot_data` selected
✅ "Deploy" button clicked successfully
✅ Modal closes after deployment (indicating deployment started)
✅ **Step 5.8 gate passed — Data Stream `ImportRunStatus` polled to `SUCCESS` (not `PENDING` / `RUNNING` / `SCHEDULED`)**
✅ **Step 5.9 gate passed — Data Cloud SQL against `pacemaker_iot_data__dll` returned formula-field values (`Party_Identification_Name__c`, `Party_Identification_Type__c`) as clean bare strings, not wrapped in double quotes. If the first-pass Full Refresh returned wrapped values, the one-shot Upsert fallback ran and its own 5.8/5.9 gates passed**
✅ Both gates must have exited clean before the browser closed and before `refresh-data-cloud-components` was invoked
✅ Browser closed cleanly
✅ Summary report provided
✅ User can verify processing status in Refresh History tab of the Data Stream

---

## Files to Upload

| # | Data Stream Name | CSV File Name | File Location |
|---|-----------------|---------------|---------------|
| 1 | pacemaker_iot_data | pacemaker_iot_data.csv | MedTechDocuments/ |

**File Requirements:**
- Format: CSV
- Headers: Must include (first row)
- Size: < 150MB per file
- Encoding: UTF-8
- Line endings: LF or CRLF

---

## Notes

After skill completes, the next skill in the workflow (refresh-data-cloud-components) automatically triggers Identity Resolution, Calculated Insight, and Segment refreshes. `/copy-field-sync` runs after that, and the Data Stream refresh step (refresh-data-streams) runs last (opt-in only). No verification action is required from the user.

**Gating rule (see Step 5.8):** the skill only hands off to `refresh-data-cloud-components` once the pacemaker_iot_data Data Stream's last-run status has reached `Success`. This is intentional — IR and CI computed against a still-`Pending` DLO produce empty or partial unified profiles, which is not a failure the downstream skill can detect. Waiting is the fix.

---

## Cleanup temp artifacts (MANDATORY before skill returns)

**🚨 HARD RULE — read this in full before invoking any cleanup command:**

> Every file or folder THIS run created in the working tree MUST be deleted before the skill returns successfully. The only exceptions are token-bearing files, which are deleted on **both success and failure paths** (security: never leave a live OAuth token on disk).

This applies regardless of which step created the file — if any prior run, debug session, or interceptor `evaluate()` call wrote something to the working tree under the names listed below, it gets removed at the end of this skill.

### Files this skill is known to create

```bash
# Step 2 — SOQL query input + JSON response
rm -f query_datastreams.soql
rm -f datastream_ids.json

# Step 2 — derived ID map (DS_ID per Data Stream)
rm -f ds_ids.env

# Step 3 — credentials JSON (SECURITY: contains a live OAuth access token)
rm -f org_creds.json

# Step 4 — frontdoor URL holder (also contains the access token in the query string)
rm -f frontdoor_url.txt

# Step 4.5 — Aura interceptor capture log (if you used `filename:` arg on the
# `evaluate()` call to dump window.__dsAuraCaptured to disk for debugging,
# OR if a request-capture diagnostic was written here during investigation)
# This file may contain Aura JWTs and AWS S3 pre-signed URLs. ALWAYS delete.
rm -f capture_log.json

# Step 8/9 — sample CLI / curl debug artifacts that older skill versions
# sometimes leave behind. Forward-compatible cleanup.
rm -f tree_import_log.txt tree_import_result.json
```

### Folders this skill creates via Playwright (Steps 4-9) and must delete

```bash
# Cross-platform: Windows + WSL/Git Bash both work via Python rmtree.
# rm -rf can prompt for permission on Windows; this avoids that.
python3 -c "import shutil, pathlib; p=pathlib.Path('.playwright-mcp'); shutil.rmtree(p) if p.exists() else None"
```

### Verification (must show no leftovers)

```bash
ls query_datastreams.soql datastream_ids.json ds_ids.env \
   org_creds.json frontdoor_url.txt capture_log.json \
   tree_import_log.txt tree_import_result.json 2>&1 | grep -v "cannot access"
ls -d .playwright-mcp 2>&1 | grep -v "cannot access"
```

If any of those lines print a path (i.e. the file/folder still exists), the cleanup failed — STOP and surface it to the user. The skill MUST NOT return success until the verification grep prints nothing.

### What to keep (do NOT delete)

- ✅ The `pacemaker_iot_data.csv` file in `MedTechDocuments/` — repo source, never touched
- ✅ `.claude/` — the skill's own definition lives here
- ✅ Anything in `data/`, `diy-base/`, `diy-datacloud/`, `scripts/` — repo source

### Cleanup-on-failure policy (per-Workspace-Hygiene rule)

| Artifact | On clean success | On any-step failure |
|---|---|---|
| `org_creds.json` | ✅ Delete | ✅ **DELETE** (token leakage risk — never leave on disk) |
| `frontdoor_url.txt` | ✅ Delete | ✅ **DELETE** (URL contains the token in the query string) |
| `capture_log.json` | ✅ Delete | ✅ **DELETE** (may contain Aura JWT + S3 pre-signed URL) |
| `query_datastreams.soql` | ✅ Delete | ❌ Keep — surfaces which DS IDs the run was targeting |
| `datastream_ids.json` | ✅ Delete | ❌ Keep — same reason |
| `ds_ids.env` | ✅ Delete | ❌ Keep — same reason |
| `.playwright-mcp/` | ✅ Delete | ❌ Keep — snapshots are the failure evidence |

**SECURITY: token-bearing files are NEVER kept.** Even if the skill failed mid-Data-Stream, the cleanup MUST delete `org_creds.json`, `frontdoor_url.txt`, and `capture_log.json`. Print a short message confirming each deletion so the user has a paper trail.

### Per-Data-Stream "did the interceptor fire?" log (optional cleanup)

If during Step 4.5 you set up a verification call that dumps `window.__dsAuraCaptured` to disk (e.g. for skills-debugging in CI), include that file in the cleanup list above. The current skill text does NOT write that log to disk — the verification call only reads `window.__dsAuraCaptured` and returns the count inline — so no extra cleanup is needed by default.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"datastream-file-upload"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.datastream-file-upload` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
