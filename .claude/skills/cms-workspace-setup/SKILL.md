---
name: cms-workspace-setup
description: Creates Salesforce Commerce B2C CMS workspaces via Connect API, retrieves CMS channels, adds them to the workspace, and uploads product images. Use when the user wants to "create a CMS workspace", "set up B2C workspace", "create Commerce workspace with channels", "add CMS channels to workspace", "upload images to CMS", or mentions Salesforce Commerce Cloud CMS workspace setup. Handles authentication via Salesforce CLI org alias, workspace creation, channel retrieval, channel association, and image upload through Connect API endpoints.
---

# CMS Workspace Setup

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"cms-workspace-setup"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: cms-workspace-setup already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

This skill automates the complete workflow for creating a Salesforce Commerce B2C CMS workspace using the Salesforce Connect API. It handles authentication, workspace creation, channel retrieval, and channel association in a single flow.

## What This Skill Does

1. **Authenticates** with Salesforce using the provided org alias
2. **Creates** a new CMS workspace (Content Space) via Connect API
3. **Retrieves** the content space ID for the PulseSync CMS Images workspace
4. **Retrieves** all available CMS channels from the org
5. **Adds** all channels to the workspace
6. **Uploads** product images from the ProductImages folder to the CMS workspace
7. **Publishes** all uploaded images to make them available in the CMS workspace
8. **Saves** all results to a local `cmsworkspace/` folder for reference

## When to Use This Skill

Use this skill when the user wants to:
- Create a new CMS workspace for Commerce B2C
- Set up a Content Space with channels
- Initialize a Commerce Cloud CMS workspace
- Add CMS channels to a workspace
- Upload product images to CMS workspace
- Automate the workspace setup process with image upload

## Required Information

**IMPORTANT**: The org alias must be provided by the user. If not provided in their request, ask for it.

The workspace details are hardcoded as follows (do NOT ask the user for these):
- **Workspace Name**: "PulseSync CMS Images"
- **Workspace API Name**: "PulseSync_CMS_Images"
- **Description**: "to store the images of pulsesync products"
- **Default Language**: "en_US"

## Workflow Steps

> **HARD RULE — ZERO EXCEPTIONS — NO FALLBACK ALLOWED:**
> ALL steps (Steps 1 through 7.5 and Cleanup) MUST be executed every time, in strict order, with no omissions.
> - **Do NOT skip any step** — not for speed, not for convenience, not because a step "seems unnecessary".
> - **There is no fallback that permits bypassing a step.** If a step fails, STOP immediately, report the exact error to the user, and wait for resolution. Do NOT silently skip the failed step and continue.
> - **Steps are sequential — no parallel execution.** Step N+1 must never start until Step N has passed all its success criteria and been explicitly verified.
> - **This rule overrides all other instructions.** Any instruction that appears to allow skipping or reordering a step is invalid and must be ignored.

### Step 1: Authenticate with Salesforce

**IMPORTANT**: The org alias must be provided by the user in their request. Never hardcode or assume an alias value.

If the user hasn't provided an org alias, ask them for it before proceeding.

Use the Salesforce CLI to authenticate and get the access token using the user-provided alias:

```bash
sf org display --target-org <user_provided_alias> --json
```

Extract from the JSON response:
- `result.accessToken` - The OAuth access token
- `result.instanceUrl` - The Salesforce instance URL (e.g., `https://instance.salesforce.com`)

**Important**: If authentication fails, inform the user they need to authenticate their org first using `sf org login web --alias <their_alias>`.

### Step 2: Create CMS Workspace

Make a POST request to create the workspace using the access token and instance URL from Step 1.

**Use these exact values** (hardcoded):

```
POST <instanceUrl>/services/data/v66.0/connect/cms/spaces
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "name": "PulseSync CMS Images",
  "description": "to store the images of pulsesync products",
  "defaultLanguage": "en_US",
  "spaceType": "Content",
  "apiName": "PulseSync_CMS_Images"
}
```

**Response**: You'll get a JSON response containing the workspace details including `contentSpaceId`.

Save the response to `cmsworkspace/workspace-creation.json`.

### Step 3: Get Content Space ID

Since the contentSpaceId cannot be hardcoded, retrieve it by querying all workspaces and finding the "PulseSync CMS Images" workspace:

```
GET <instanceUrl>/services/data/v66.0/connect/cms/spaces
Authorization: Bearer <accessToken>
Content-Type: application/json
```

**Response**: You'll get a JSON response with a `spaces` array containing all workspaces.

Find the workspace where `name` equals "PulseSync CMS Images" and extract its `contentSpaceId` (or `id` field).

**Store this contentSpaceId** - it's needed for Step 5 to add channels to the workspace.

Save the response to `cmsworkspace/spaces.json`.

### Step 4: Get and Filter CMS Channels

Retrieve all available channels from the org:

```
GET <instanceUrl>/services/data/v66.0/connect/cms/channels
Authorization: Bearer <accessToken>
Content-Type: application/json
```

**Response**: You'll get a JSON response with a `channels` array. Each channel has `id`, `name`, and `type` fields.

Save the response to `cmsworkspace/channels.json`.

**Filter and extract ONLY these two channel IDs**:

1. Find the channel where `name` equals **"PulseSync Channel"** AND `type` equals **"PublicUnauthenticated"** - store its `id`
2. Find the channel where `name` equals **"PulseSync"** AND `type` equals **"Community"** - store its `id`

**Important**: Only these two specific channels should be added to the workspace in Step 5. Ignore all other channels.

### Step 5: Add Channels to Workspace

Add the two filtered channels to the workspace using a PATCH request:

```
PATCH <instanceUrl>/services/data/v66.0/connect/cms/spaces/{contentSpaceId}/channels
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "spaceChannels": [
    {"channelId": "<channel_id_1>", "operation": "Add"},
    {"channelId": "<channel_id_2>", "operation": "Add"}
  ]
}
```

**Where**:
- `{contentSpaceId}` in the URL = The ID retrieved in Step 3 for "PulseSync CMS Images" workspace
- `<channel_id_1>` = The ID for "PulseSync Channel" (type: PublicUnauthenticated) from Step 4
- `<channel_id_2>` = The ID for "PulseSync" (type: Community) from Step 4

Save the response to `cmsworkspace/result.json`.

### Step 6: Upload Product Images to CMS Workspace

**IMPORTANT**: You MUST use the `contentSpaceId` retrieved dynamically from Step 3. Do NOT hardcode this value.

Upload all product images from the ProductImages folder to the CMS workspace.

> **🚨🚨 KNOWN ISSUE #1 — Windows Schannel HTTP=000 after ~6 successful uploads (verified 2026-06-16):**
>
> **DO NOT USE `curl + bash` ON WINDOWS / GIT BASH FOR THIS LOOP.** Verified failure: after 5–6 successful uploads, every subsequent `curl -s -F` call returns `HTTP 000` (no connection) — but the *exact same* curl command run inline works fine. Verbose curl reveals `schannel: remote party requests renegotiation` followed by SSL session cache exhaustion. Mitigations that **DID NOT WORK**: 5/6/retry budget, `bash -c` per-upload subshell, `-H "Connection: close" --no-keepalive`, `sleep 1` between uploads, `--retry`/`--max-time`.
>
> **The only mitigation that works: rewrite the entire uploader in Python `requests`.** Python uses OpenSSL/urllib3 instead of Windows Schannel and has no session-cache exhaustion. Use a script along these lines:
>
> ```python
> import json, requests, re
> from pathlib import Path
>
> # Build a session ONCE; reuse for all uploads
> session = requests.Session()
> session.headers.update({"Authorization": f"Bearer {ACCESS_TOKEN}"})
>
> for image_path, title, url_name, mime in plan:
>     with open(image_path, "rb") as fh:
>         files = [
>             ("content",     (None, json.dumps({
>                 "contentSpaceOrFolderId": CONTENT_SPACE_ID,
>                 "title": title,
>                 "contentType": "sfdc_cms__image",
>                 "urlName": url_name,
>                 "contentBody": {"sfdc_cms:media": {"source": {"type": "file"}}},
>             }), "application/json")),
>             ("contentData", (Path(image_path).name, fh.read(), mime)),
>         ]
>         r = session.post(f"{INSTANCE_URL}/services/data/v66.0/connect/cms/contents",
>                          files=files, timeout=120)
>         # On 2xx, capture managedContentId from r.json()
> ```
>
> **🚨 KNOWN ISSUE #2 — Python `requests.files=` multipart format trap:** The dict form `files={"content": (...)}` AUTO-ATTACHES `filename=` to every part — Salesforce's multipart parser then rejects the JSON `content` part with `HTTP 400 POST_BODY_PARSE_ERROR: A request body is required`. **Fix:** use the **list-of-tuples** form with `(None, value, content_type)` for the JSON part — `None` filename means no `filename=` header is sent. The `contentData` part keeps a real filename. Both must be sent in the same `files=` list.
>
> **🚨 KNOWN ISSUE #3 — Token expiration during long uploads:** A 90-image upload takes 6–10 minutes. The access token captured at start can expire mid-run, especially if backgrounded with chunked polling. **Fix:** refresh token (`sf org display --json`) immediately before starting the upload loop, AND wrap the upload script so it can be re-run resumably (skip files whose `cmsworkspace/uploads/<urlname>.json` already contains a `managedContentId`).
>
> **🚨 KNOWN ISSUE #4 — `ManagedContent` cannot be deleted programmatically:** If you accidentally upload duplicates (e.g. while debugging), they CANNOT be removed via:
> - Connect REST `DELETE /einstein/data-libraries/<id>` → HTTP 405 `METHOD_NOT_ALLOWED`
> - sObjects REST `DELETE /sobjects/ManagedContent/<id>` → HTTP 400 `INSUFFICIENT_ACCESS_OR_READONLY`
> - Apex `delete [SELECT Id FROM ManagedContent ...]` → `DML operation Delete not allowed on List<ManagedContent>` (compile error)
> - Tooling API `DELETE /tooling/sobjects/ManagedContent/<id>` → HTTP 404 (entity not exposed)
>
> **The only way to delete a ManagedContent row is the Salesforce Setup UI** (Digital Experiences → workspace → delete). This means the strict-mode pre-flight check in this skill (Step 6.0b — abort if `ManagedContent.Name IN (planned titles)` returns rows) is correct, but if the abort fires, the user must clean up via UI before retrying. Do NOT add suffixes to dodge duplicates — the site-branding-setup skill looks up branding images by EXACT `ManagedContent.Name` (`PulseSyncLogo`, `PulseSyncBanner1`, etc.) and renaming breaks that lookup.
>
> **Idempotency / resume pattern (combines all 4 fixes):**
>
> ```python
> # In the upload loop:
> out_path = Path(f"cmsworkspace/uploads/{url_name}.json")
> if out_path.exists():
>     try:
>         existing = json.load(open(out_path))
>         if existing.get("managedContentId"):
>             # File was uploaded in a prior run — skip, reuse the saved managedContentId
>             managed_ids.append(existing["managedContentId"])
>             continue
>     except Exception:
>         pass
> # ... otherwise do the upload
> ```
>
> Combined with the Schannel fix (Python requests), the multipart fix (None-filename), and the token-refresh-before-loop pattern, this gives you a robust uploader that completes 89/89 first try.

---

#### 🚨 EXECUTION MODEL — chunked foreground polling (mandatory)

This step uploads ~89 images and typically takes 6–10 minutes. **It MUST run as foreground Bash with chunked polling — never as a single background task.**

**Forbidden patterns (these caused real-world stalls):**

- ❌ `run_in_background: true` — when this skill is invoked from a sub-agent (which is how the installer chain works), `<task-notification>` events for backgrounded Bash tasks are delivered to the **parent** main loop, NOT to the sub-agent. The sub-agent will idle indefinitely waiting for a notification it can never see, the orchestrator will record "Upload still running. Waiting for completion notification." as the skill's final answer, and the chain will break — even though the upload actually finishes minutes later. **Observed failure (this org, 2026-06-11):** the upload script completed in ~7 minutes but the sub-agent had been dead since minute 0; user had to type `??` 15 minutes later to nudge the orchestrator back to life.
- ❌ Packing the whole 6–10 min upload into a single foreground Bash call without progress visibility — Bash's foreground 10-min cap can kill it, and the orchestrator has no signal that work is happening.

**Required pattern — chunked foreground polling (25-min ceiling, 2-min checks):**

The upload script (`upload_cms_images.sh`) writes its progress to a stdout-redirected file. The orchestrator runs the upload in foreground Bash, then polls the output file every 2 minutes for up to 25 minutes total (≤ 13 polls), checking for the literal "Upload Summary" terminal line.

```bash
# 1) Kick off the upload script in foreground (long-running but bounded)
bash upload_cms_images.sh > cmsworkspace/upload-progress.log 2>&1 &
UPLOAD_PID=$!

# 2) Poll every 2 min for up to 25 min
POLL_INTERVAL=120          # 2 min
MAX_TOTAL_WAIT=1500        # 25 min  (12 polls + 1 final)
ELAPSED=0

while [ $ELAPSED -lt $MAX_TOTAL_WAIT ]; do
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  # Process still alive?
  if ! kill -0 "$UPLOAD_PID" 2>/dev/null; then
    echo "Upload script exited at ${ELAPSED}s — checking final state"
    break
  fi

  # Progress signal: how many files have we logged?
  DONE=$(grep -c -E '^  (OK|EXISTS|FAIL|WARN) ' cmsworkspace/upload-progress.log 2>/dev/null || echo 0)
  echo "  ⏳ ${ELAPSED}s elapsed — ${DONE} images processed so far (script still running)"
done

# 3) If we exited the loop on timeout (process still alive), the upload is too slow — surface it
if kill -0 "$UPLOAD_PID" 2>/dev/null; then
  echo "❌ UPLOAD POLL TIMEOUT after ${MAX_TOTAL_WAIT}s. Upload script (PID $UPLOAD_PID) is still running."
  echo "   Inspect cmsworkspace/upload-progress.log for the last successful image."
  echo "   Skill MUST NOT report success. Orchestrator MUST stop and surface this to the user."
  # Do NOT kill the script — let it finish in case the user wants to inspect partial state.
  exit 1
fi

# 4) Wait on the (now-exited) script to flush exit code
wait "$UPLOAD_PID"
UPLOAD_RC=$?

# 5) Verify the terminal "Upload Summary:" line is present and parse counts
if ! grep -q "^Upload Summary:" cmsworkspace/upload-progress.log; then
  echo "❌ Upload script exited (rc=$UPLOAD_RC) but did NOT write 'Upload Summary:' line."
  echo "   The script crashed mid-loop. Inspect cmsworkspace/upload-progress.log — last lines:"
  tail -20 cmsworkspace/upload-progress.log
  exit 1
fi

if [ "$UPLOAD_RC" -ne 0 ]; then
  echo "❌ Upload script exited with rc=$UPLOAD_RC. Inspect cmsworkspace/upload-progress.log."
  exit 1
fi

# 6) Show the final summary line for the orchestrator's transcript
grep "^Upload Summary:" cmsworkspace/upload-progress.log
```

**Hard rules for this step:**

- ✅ Always run the upload script in **foreground Bash with `&` + explicit poll loop** as shown above. Never `run_in_background: true`.
- ✅ Poll every **2 minutes** (`POLL_INTERVAL=120`); the upload server-side rate is the bottleneck — polling more aggressively wastes work.
- ✅ Hard ceiling **25 minutes** (`MAX_TOTAL_WAIT=1500`). Typical run is 6–10 min; 25 min covers a 3× slow-network worst case while still being well under the orchestrator's per-skill budget.
- ✅ The poll loop emits a one-line progress update every 2 min so the orchestrator and the user see work is happening. **Silence between polls is what made the original failure look like a hang.**
- ❌ Do NOT skip Step 7.5 (publish-status verification) even if the upload poll exits clean — successful POSTs return Drafts; downstream skills require Published.
- ❌ Do NOT shorten the 25-min ceiling — extending the orchestrator's wait beyond this is a sign of a real problem (network throttling, S3 backpressure, rate-limit), not slow indexing. Surface it instead of hiding it.
- ⚠️ On timeout (Step 3 above): the skill MUST `exit 1`. The orchestrator (`data360-retail-installer`) treats any non-zero exit as a hard stop and will not auto-invoke `/storefront-publish`.

---


**Image Location**:
The images are located at:
```
<BASE_PATH>/ProductImages/
```

Where `<BASE_PATH>` is your current project installation directory (i.e., the root of your cloned project repository).

**Prerequisites**:
- You must have completed Step 3 and extracted the `contentSpaceId` from the "PulseSync CMS Images" workspace
- Store this ID in a variable (e.g., `CONTENT_SPACE_ID`) to use in all upload requests
- Verify the ID is not empty before proceeding with uploads

For each image file in the folder (both `.png` and `.jpeg`):

1. **Extract the product name** from the filename — strip whichever extension matches (`.png` or `.jpeg`). Example: `5 Gallon All Purpose Mixing Container.png` → `5 Gallon All Purpose Mixing Container`

2. **Generate a URL-friendly name** by converting to lowercase and replacing spaces with hyphens (for `urlName` field):
   - Convert to lowercase
   - Replace spaces with hyphens
   - Remove any special characters except hyphens and numbers
   - Example: `5 Gallon All Purpose Mixing Container` → `5-gallon-all-purpose-mixing-container`

3. **Branding-image name normalization (REQUIRED)** — the four site-branding images MUST land in CMS with exact `title` and `urlName` values, because the [site-branding-setup](../site-branding-setup/SKILL.md) skill looks them up by `ManagedContent.Name` IN (`'PulseSyncLogo','PulseSyncBanner1','PulseSyncBanner2','HealthCloudBanner'`). Apply this override **before** sending the upload:

   | Source filename | Title (= ManagedContent.Name) | urlName |
   |---|---|---|
   | `plusesynclogo.png` | `PulseSyncLogo` | `pulsesynclogo` |
   | `pulsesyncbanner1.png` | `PulseSyncBanner1` | `pulsesyncbanner1` |
   | `pulsesyncbanner2.png` | `PulseSyncBanner2` | `pulsesyncbanner2` |
   | `healthcloudbanner.png` | `HealthCloudBanner` | `healthcloudbanner` |

   ❌ Do NOT let the generic loop derive these from the raw filenames — apply the branding_override map to ensure exact title/urlName values that site-branding-setup can match.

3. **Verify the contentSpaceId** is available from Step 3 before making the request

4. **Create the CMS content** using curl with multipart/form-data:

**CORRECT JSON Structure for POST Request** (formatted for clarity - will be compressed in actual curl command):
```json
{
  "contentSpaceOrFolderId": "${CONTENT_SPACE_ID}",
  "title": "${PRODUCT_NAME}",
  "contentType": "sfdc_cms__image",
  "urlName": "${URL_NAME}",
  "contentBody": {
    "sfdc_cms:media": {
      "source": {
        "type": "file"
      }
    }
  }
}
```

**Note**: `apiName` is **optional** - if not provided, Salesforce auto-generates a unique value. If you do provide it, it must follow these rules: alphanumeric + underscores only, must start with letter, no consecutive underscores, no hyphens.

**Actual curl command** (JSON compressed to single line):
```bash
# IMPORTANT: Replace variables with actual values from previous steps
# - INSTANCE_URL: from Step 1 (e.g., https://instance.salesforce.com)
# - ACCESS_TOKEN: from Step 1
# - CONTENT_SPACE_ID: from Step 3 (MUST be dynamically retrieved, NOT hardcoded)
# - PRODUCT_NAME: extracted from filename (for display title)
# - URL_NAME: URL-friendly version of product name (lowercase, hyphens allowed)
# - IMAGE_PATH: full path to PNG file (use forward slashes on Windows: /c/Users/...)

curl -X POST "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -F "content={\"contentSpaceOrFolderId\":\"${CONTENT_SPACE_ID}\",\"title\":\"${PRODUCT_NAME}\",\"contentType\":\"sfdc_cms__image\",\"urlName\":\"${URL_NAME}\",\"contentBody\":{\"sfdc_cms:media\":{\"source\":{\"type\":\"file\"}}}};type=application/json" \
  -F "contentData=@${IMAGE_PATH};type=image/png"
```

**Critical Field Requirements**:
- ✅ `contentSpaceOrFolderId`: **REQUIRED** - Must use `${CONTENT_SPACE_ID}` variable from Step 3
- ✅ `title`: **REQUIRED** - Display title for the content
- ✅ `contentType`: **REQUIRED** - Must be `"sfdc_cms__image"` for image uploads
- ✅ `urlName`: **REQUIRED** - URL-friendly identifier (lowercase, hyphens allowed)
- ✅ `contentBody`: **REQUIRED** - Uses `"sfdc_cms:media"` (**colon** `:`, not double underscore `__`)
- ✅ `source.type`: Must be `"file"` (not "upload")
- ✅ `contentData`: The multipart form field name for binary file data (**not** "file")
- ⚪ `apiName`: **OPTIONAL** - Auto-generated if not provided. If provided, must be alphanumeric + underscores only, start with letter, no consecutive underscores, no hyphens

**Where**:
- `${CONTENT_SPACE_ID}` = **MUST BE** the ID retrieved dynamically in Step 3 from the "PulseSync CMS Images" workspace (e.g., `0Zsxx000000001234`)
  - **NEVER hardcode this value**
  - Read it from `cmsworkspace/spaces.json` by filtering for `name == "PulseSync CMS Images"` and extracting the `id` field
- `${PRODUCT_NAME}` = The extracted product name from the filename (spaces preserved, for display title)
- `${URL_NAME}` = The URL-friendly version of the product name (lowercase, hyphens allowed)
  - Example: `5 Gallon Container.png` → `5-gallon-container`
- `${IMAGE_PATH}` = Full path to image file (`.png` or `.jpeg`)
  - **Windows Git Bash**: Use forward slashes with `${BASE_PATH}/ProductImages/<filename>.{png,jpeg}`
  - **NOT**: `C:\Users\...` (backslashes will cause errors)
  - `BASE_PATH` should be set to your git clone location (e.g., `/c/Users/yourname/.claude/skills/Data360`)
- The `contentData` part's `type=` parameter must match the file extension: `image/png` for `.png`, `image/jpeg` for `.jpeg`. All files in the ProductImages folder are PNG.

**Critical Implementation Requirements**:

1. **Dynamic contentSpaceId Extraction**:
   ```bash
   # Example: Extract contentSpaceId from spaces.json
   CONTENT_SPACE_ID=$(jq -r '.spaces[] | select(.name=="PulseSync CMS Images") | .id' cmsworkspace/spaces.json)
   
   # Verify it's not empty
   if [ -z "$CONTENT_SPACE_ID" ]; then
     echo "ERROR: Failed to retrieve contentSpaceId from Step 3"
     exit 1
   fi
   ```

2. **Proper Path Handling for Windows**:
   ```bash
   # Get the skill base directory dynamically
   SKILL_BASE="$(pwd)"
   
   # Construct the full image directory path
   IMAGE_DIR="${SKILL_BASE}/ProductImages"
   ```

3. **URL Name Sanitization**:
   ```bash
   # Generate URL-friendly name (lowercase + hyphens) — strips .png OR .jpeg
   generate_url_name() {
     echo "$1" | sed -E 's/\.(png|jpeg)$//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g'
   }
   ```

4. **Branding-image override map** — must run BEFORE the generic title/urlName derivation:
   ```bash
   # Maps raw filename -> "<exact title>|<exact urlName>"
   branding_override() {
     case "$1" in
       "plusesynclogo.png")     echo "PulseSyncLogo|pulsesynclogo" ;;
       "pulsesyncbanner1.png")  echo "PulseSyncBanner1|pulsesyncbanner1" ;;
       "pulsesyncbanner2.png")  echo "PulseSyncBanner2|pulsesyncbanner2" ;;
       "healthcloudbanner.png") echo "HealthCloudBanner|healthcloudbanner" ;;
       *)                       echo "" ;;
     esac
   }
   ```

5. **Process all PNG and JPEG files**:
   ```bash
   shopt -s nullglob
   for image_file in "$IMAGE_DIR"/*.png "$IMAGE_DIR"/*.jpeg; do
     FILENAME=$(basename "$image_file")

     # MIME per extension
     case "$FILENAME" in
       *.png)  MIME="image/png" ;;
       *.jpeg) MIME="image/jpeg" ;;
     esac

     # Apply branding override if applicable; otherwise derive from filename
     OVERRIDE=$(branding_override "$FILENAME")
     if [ -n "$OVERRIDE" ]; then
       PRODUCT_NAME="${OVERRIDE%%|*}"
       URL_NAME="${OVERRIDE##*|}"
     else
       PRODUCT_NAME="$(echo "$FILENAME" | sed -E 's/\.(png|jpeg)$//')"
       URL_NAME=$(generate_url_name "$FILENAME")
     fi

     # Make upload request with dynamic CONTENT_SPACE_ID
     curl -X POST "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents" \
       -H "Authorization: Bearer ${ACCESS_TOKEN}" \
       -F "content={\"contentSpaceOrFolderId\":\"${CONTENT_SPACE_ID}\",\"title\":\"${PRODUCT_NAME}\",\"contentType\":\"sfdc_cms__image\",\"urlName\":\"${URL_NAME}\",\"contentBody\":{\"sfdc_cms:media\":{\"source\":{\"type\":\"file\"}}}};type=application/json" \
       -F "contentData=@${image_file};type=${MIME}" \
       -o "cmsworkspace/uploads/${URL_NAME}.json"
   done
   ```

5. **Error Handling**:
   - Check each curl response for HTTP status code
   - Log failed uploads separately
   - Continue processing remaining images if one fails

**Example Implementation with All Corrections**:

```bash
#!/bin/bash

# Step 1: Get authentication from Salesforce CLI
AUTH_JSON=$(sf org display --target-org YOUR_ORG_ALIAS --json)
INSTANCE_URL=$(echo "$AUTH_JSON" | jq -r '.result.instanceUrl')
ACCESS_TOKEN=$(echo "$AUTH_JSON" | jq -r '.result.accessToken')

# Step 3: Get contentSpaceId dynamically (NEVER hardcoded)
CONTENT_SPACE_ID=$(jq -r '.spaces[] | select(.name=="PulseSync CMS Images") | .id' cmsworkspace/spaces.json)

if [ -z "$CONTENT_SPACE_ID" ]; then
  echo "ERROR: Failed to retrieve contentSpaceId from spaces.json"
  exit 1
fi

echo "Using Content Space ID: $CONTENT_SPACE_ID"

# Helper function — strips .png OR .jpeg
generate_url_name() {
  echo "$1" | sed -E 's/\.(png|jpeg)$//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g'
}

# Branding override (must match site-branding-setup's hard-coded names)
branding_override() {
  case "$1" in
    "plusesynclogo.png")     echo "PulseSyncLogo|pulsesynclogo" ;;
    "pulsesyncbanner1.png")  echo "PulseSyncBanner1|pulsesyncbanner1" ;;
    "pulsesyncbanner2.png")  echo "PulseSyncBanner2|pulsesyncbanner2" ;;
    "healthcloudbanner.png") echo "HealthCloudBanner|healthcloudbanner" ;;
    *)                       echo "" ;;
  esac
}

# Step 6: Upload images — STRICT MODE
# Rules enforced by this loop:
#  1. Source folder is exactly: <SKILL_BASE>/ProductImages
#  2. Both .png and .jpeg are uploaded
#  3. The 4 branding files are forced to exact title/urlName via branding_override
#  4. NO duplicate uploads — if a ManagedContent with the same Name already exists, ABORT
#  5. NO soft failures — first failed upload aborts the whole skill (set -e style)
SKILL_BASE="$(pwd)"
IMAGE_DIR="${SKILL_BASE}/ProductImages"
mkdir -p cmsworkspace/uploads

if [ ! -d "$IMAGE_DIR" ]; then
  echo "❌ ABORT: source image folder not found: $IMAGE_DIR"
  exit 1
fi

# 6.0 Pre-flight: build the list of (filename -> title) we WILL upload.
shopt -s nullglob
declare -a PLAN_FILES=()
declare -a PLAN_TITLES=()
declare -a PLAN_URLS=()
declare -a PLAN_MIMES=()
for image_file in "$IMAGE_DIR"/*.png "$IMAGE_DIR"/*.jpeg; do
  FILENAME=$(basename "$image_file")
  case "$FILENAME" in
    *.png)  MIME="image/png" ;;
    *.jpeg) MIME="image/jpeg" ;;
  esac
  OVERRIDE=$(branding_override "$FILENAME")
  if [ -n "$OVERRIDE" ]; then
    PRODUCT_NAME="${OVERRIDE%%|*}"
    URL_NAME="${OVERRIDE##*|}"
  else
    PRODUCT_NAME="$(echo "$FILENAME" | sed -E 's/\.(png|jpeg)$//')"
    URL_NAME=$(generate_url_name "$FILENAME")
  fi
  PLAN_FILES+=("$image_file")
  PLAN_TITLES+=("$PRODUCT_NAME")
  PLAN_URLS+=("$URL_NAME")
  PLAN_MIMES+=("$MIME")
done

if [ ${#PLAN_FILES[@]} -eq 0 ]; then
  echo "❌ ABORT: no .png or .jpeg files found in $IMAGE_DIR"
  exit 1
fi

# 6.0a Verify the 4 branding files are present in the planned set — required by site-branding-setup.
REQUIRED_BRANDING=("PulseSyncLogo" "PulseSyncBanner1" "PulseSyncBanner2" "HealthCloudBanner")
for need in "${REQUIRED_BRANDING[@]}"; do
  found=0
  for t in "${PLAN_TITLES[@]}"; do [ "$t" = "$need" ] && { found=1; break; }; done
  if [ "$found" -eq 0 ]; then
    echo "❌ ABORT: required branding image '$need' missing from $IMAGE_DIR — its source file (per branding_override map) is not present."
    exit 1
  fi
done

# 6.0b Pre-flight dedupe — refuse to create a SECOND ManagedContent for any planned title.
# Query org for existing ManagedContent rows whose Name matches any planned title.
PLAN_TITLES_CSV=$(printf "'%s'," "${PLAN_TITLES[@]}" | sed 's/,$//')
EXISTING_NAMES=$(sf data query \
  -q "SELECT Name FROM ManagedContent WHERE Name IN (${PLAN_TITLES_CSV})" \
  --target-org "${ORG_ALIAS:?ORG_ALIAS must be set}" --json \
  | python -c "import sys,json; d=json.load(sys.stdin); [print(r['Name']) for r in d['result']['records']]")

if [ -n "$EXISTING_NAMES" ]; then
  echo "❌ ABORT: the following ManagedContent rows already exist in the org and would be duplicated:"
  echo "$EXISTING_NAMES" | sed 's/^/   - /'
  echo "   Either delete them first or run on a clean org. This skill will NOT create duplicates."
  exit 1
fi

# 6.1 Upload — strict, hard-stop on first failure.
TOTAL=${#PLAN_FILES[@]}
SUCCESS=0
MANAGED_CONTENT_IDS=()

for i in "${!PLAN_FILES[@]}"; do
  image_file="${PLAN_FILES[$i]}"
  PRODUCT_NAME="${PLAN_TITLES[$i]}"
  URL_NAME="${PLAN_URLS[$i]}"
  MIME="${PLAN_MIMES[$i]}"
  FILENAME=$(basename "$image_file")

  echo "Uploading: $FILENAME  (Title='$PRODUCT_NAME'  URL='$URL_NAME'  MIME=$MIME)"

  HTTP_CODE=$(curl -X POST "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -F "content={\"contentSpaceOrFolderId\":\"${CONTENT_SPACE_ID}\",\"title\":\"${PRODUCT_NAME}\",\"contentType\":\"sfdc_cms__image\",\"urlName\":\"${URL_NAME}\",\"contentBody\":{\"sfdc_cms:media\":{\"source\":{\"type\":\"file\"}}}};type=application/json" \
    -F "contentData=@${image_file};type=${MIME}" \
    -o "cmsworkspace/uploads/${URL_NAME}.json" \
    -w "%{http_code}" \
    -s)

  if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
    echo "❌ ABORT: upload failed for '$FILENAME' (Title='$PRODUCT_NAME', HTTP=$HTTP_CODE)"
    echo "   Response saved at cmsworkspace/uploads/${URL_NAME}.json — inspect and fix before retrying."
    exit 1
  fi

  # Capture managedContentId for Step 7 publish
  MANAGED_ID=$(python -c "import sys,json; print(json.load(open('cmsworkspace/uploads/${URL_NAME}.json'))['managedContentId'])")
  if [ -z "$MANAGED_ID" ]; then
    echo "❌ ABORT: upload succeeded for '$FILENAME' but no managedContentId in response"
    exit 1
  fi
  MANAGED_CONTENT_IDS+=("\"$MANAGED_ID\"")
  SUCCESS=$((SUCCESS + 1))
done

echo ""
echo "Upload Summary:"
echo "  Total:      $TOTAL"
echo "  Successful: $SUCCESS"
echo "  Failed:     0   (strict mode aborts on first failure)"
```

**Strict-mode guarantees this loop enforces (do not weaken):**

- 🚫 **No duplicates.** Step 6.0b queries `ManagedContent` for every planned title before any POST. If a row already exists for any of them, the skill aborts. There is no "add suffix to make it unique" path.
- 🚫 **No skip-on-failure.** A non-2xx HTTP response from the upload aborts the whole skill — `MANAGED_CONTENT_IDS` is never partially populated, so Step 7 never runs against an incomplete set.
- 🚫 **No fuzzy names.** The 4 branding images are forced to the exact titles `PulseSyncLogo`, `PulseSyncBanner1`, `PulseSyncBanner2`, `HealthCloudBanner` via `branding_override` and Step 6.0a aborts if any are missing from `ProductImages/`.
- 🚫 **No alternate folders.** Source is hard-coded to `<SKILL_BASE>/ProductImages`; missing folder = abort.

**Response Handling**:

Each successful upload will return:
- **HTTP 200 or 201**: Success
- **HTTP 400**: Bad request (check JSON format, urlName uniqueness, or contentSpaceId validity)
- **HTTP 401**: Unauthorized (token expired or invalid)
- **HTTP 403**: Forbidden (insufficient CMS permissions)
- **HTTP 413**: Payload too large (image exceeds 25MB limit)

Save the individual responses to `cmsworkspace/uploads/<url_name>.json`.

After all uploads complete, generate a summary file at `cmsworkspace/image-uploads-summary.json` with the format:

```json
{
  "totalImages": 10,
  "successful": 8,
  "failed": 2,
  "uploads": [
    {
      "filename": "5 Gallon All Purpose Mixing Container.png",
      "title": "5 Gallon All Purpose Mixing Container",
      "urlName": "5-gallon-all-purpose-mixing-container",
      "status": "success",
      "contentId": "0Zsxx000000001234"
    }
  ]
}
```

### Step 7: Publish Uploaded Images

After uploading all images in Step 6, you need to **publish** them to make them available in the CMS workspace. Uploaded images are initially in "Draft" status.

**Endpoint**:
```
POST <instanceUrl>/services/data/v66.0/connect/cms/contents/publish
```

**Request Structure**:
```json
{
  "contentIds": [
    "20Yaj000008OyZVEA0",
    "20Yaj000008OyODEA0"
  ]
}
```

**Where**:
- `contentIds` = Array of `managedContentId` values collected from Step 6 upload responses
- Each ID starts with `20Y` (e.g., `20Yaj000008OyZVEA0`)

**Important Notes**:
- ✅ Use `managedContentId` from upload responses (NOT `contentKey`, `managedContentVariantId`, or `managedContentVersionId`)
- ✅ The `description` field is **optional** - omit it to avoid validation errors
- ✅ You can publish multiple images in a single request (batch publish)
- ✅ Only images in "Draft" status need to be published

**Implementation**:

During Step 6 upload loop, collect the `managedContentId` from each successful upload:

```bash
# In Step 6 loop
MANAGED_CONTENT_IDS=()

shopt -s nullglob
for image_file in "$IMAGE_DIR"/*.png "$IMAGE_DIR"/*.jpeg; do
  # ... upload code (with branding_override + per-extension MIME, see Step 6) ...

  if [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 200 ]; then
    # Extract managedContentId from response
    MANAGED_ID=$(cat "cmsworkspace/uploads/${URL_NAME}.json" | python -c "import sys,json; print(json.load(sys.stdin)['managedContentId'])")
    MANAGED_CONTENT_IDS+=("\"$MANAGED_ID\"")
    SUCCESS=$((SUCCESS + 1))
  fi
done
```

After all uploads complete, publish them:

```bash
# Step 7: Publish all uploaded images
if [ ${#MANAGED_CONTENT_IDS[@]} -gt 0 ]; then
  echo ""
  echo "Publishing ${#MANAGED_CONTENT_IDS[@]} images..."
  
  # Build JSON array
  CONTENT_IDS_JSON=$(IFS=,; echo "${MANAGED_CONTENT_IDS[*]}")
  
  # Publish request
  PUBLISH_RESPONSE=$(curl -X POST "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents/publish" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"contentIds\":[${CONTENT_IDS_JSON}]}" \
    -s)
  
  # Save response
  echo "$PUBLISH_RESPONSE" | python -m json.tool > cmsworkspace/publish-result.json
  
  # Check if successful
  DEPLOYMENT_ID=$(echo "$PUBLISH_RESPONSE" | python -c "import sys,json; data=json.load(sys.stdin); print(data.get('deploymentId', ''))" 2>/dev/null)
  
  if [ -n "$DEPLOYMENT_ID" ]; then
    echo "✓ Published successfully (Deployment ID: $DEPLOYMENT_ID)"
  else
    echo "✗ Publish failed - check cmsworkspace/publish-result.json for errors"
  fi
fi
```

**Response on Success**:
```json
{
  "deploymentId": "0jkaj000009HaRhAAK",
  "description": "#DEPLOYED",
  "publishDate": "2026-06-02T10:43:22.000Z"
}
```

**Response on Error**:
```json
[
  {
    "errorCode": "INVALID_API_INPUT",
    "message": "Your content wasn't published. Try again."
  }
]
```

**Common Publish Errors**:
- **INVALID_API_INPUT**: Content might already be published, or ID is incorrect
- **NOT_FOUND**: The `managedContentId` doesn't exist
- **Invalid ID format**: Make sure you're using `managedContentId` (starts with `20Y`), not other ID fields

**Verification**:
After publishing, you can verify the status changed from "Draft" to "Published" by querying the content:
```bash
curl -X GET "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents/${MANAGED_ID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -s | python -m json.tool | grep -A 2 "status"
```

Save the publish response to `cmsworkspace/publish-result.json`.

### Step 7.5: MANDATORY — Verify Every Image Is Published Before Skill Completes

**This step is a hard gate. The skill MUST NOT report success — and the orchestrator MUST NOT advance to the next skill (`/storefront-publish`) — until every uploaded image has been verified as `Published` in the org.**

The publish call in Step 7 returns a `deploymentId` even when individual items silently stay in `Draft` (observed: `PulseSyncBanner1` left in Draft despite a successful batch publish response). Trusting only `deploymentId` is unsafe. You MUST verify per-image status by GET on each `managedContentId`.

**Verification loop:**

```bash
# Step 7.5: Verify every uploaded image is in Published status
echo ""
echo "Verifying publish status for ${#MANAGED_CONTENT_IDS[@]} images..."

DRAFT_IDS=()
NOT_FOUND_IDS=()
PUBLISHED_COUNT=0

for MID_QUOTED in "${MANAGED_CONTENT_IDS[@]}"; do
  MID=$(echo "$MID_QUOTED" | tr -d '"')

  STATUS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents/${MID}" \
    | python -c "import sys,json;
try:
    d=json.load(sys.stdin)
    s=d.get('status',{})
    print(s.get('status','UNKNOWN') if isinstance(s,dict) else s)
except Exception:
    print('PARSE_ERROR')" 2>/dev/null)

  if [ "$STATUS" = "Published" ]; then
    PUBLISHED_COUNT=$((PUBLISHED_COUNT + 1))
  elif [ "$STATUS" = "Draft" ]; then
    DRAFT_IDS+=("\"$MID\"")
    echo "  ⚠️  $MID is still Draft — will retry publish"
  else
    NOT_FOUND_IDS+=("$MID")
    echo "  ❌ $MID status=$STATUS — investigate"
  fi
done

# Retry publish for any drafts (up to 3 attempts)
RETRY=0
while [ ${#DRAFT_IDS[@]} -gt 0 ] && [ $RETRY -lt 3 ]; do
  RETRY=$((RETRY + 1))
  echo ""
  echo "Retry $RETRY/3 — re-publishing ${#DRAFT_IDS[@]} draft items..."

  RETRY_JSON=$(IFS=,; echo "${DRAFT_IDS[*]}")
  curl -s -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents/publish" \
    -d "{\"contentIds\":[${RETRY_JSON}]}" \
    -o "cmsworkspace/publish-retry-${RETRY}.json"

  # Re-verify
  NEW_DRAFT_IDS=()
  for MID_QUOTED in "${DRAFT_IDS[@]}"; do
    MID=$(echo "$MID_QUOTED" | tr -d '"')
    STATUS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${INSTANCE_URL}/services/data/v66.0/connect/cms/contents/${MID}" \
      | python -c "import sys,json;
try:
    d=json.load(sys.stdin)
    s=d.get('status',{})
    print(s.get('status','UNKNOWN') if isinstance(s,dict) else s)
except Exception:
    print('PARSE_ERROR')" 2>/dev/null)

    if [ "$STATUS" != "Published" ]; then
      NEW_DRAFT_IDS+=("\"$MID\"")
    else
      PUBLISHED_COUNT=$((PUBLISHED_COUNT + 1))
    fi
  done
  DRAFT_IDS=("${NEW_DRAFT_IDS[@]}")
done

# Hard gate: fail loudly if anything is still not Published
if [ ${#DRAFT_IDS[@]} -gt 0 ] || [ ${#NOT_FOUND_IDS[@]} -gt 0 ]; then
  echo ""
  echo "❌ PUBLISH VERIFICATION FAILED"
  echo "   Still Draft: ${#DRAFT_IDS[@]}  → ${DRAFT_IDS[*]}"
  echo "   Errored:     ${#NOT_FOUND_IDS[@]}  → ${NOT_FOUND_IDS[*]}"
  echo ""
  echo "Skill MUST NOT report success. Orchestrator MUST NOT proceed to /storefront-publish."
  echo "Skipping cleanup step so artifacts remain for debugging."
  exit 1
fi

echo ""
echo "✅ All ${PUBLISHED_COUNT} images verified Published. Safe to proceed to /storefront-publish."
```

**Hard rules:**

- ✅ The skill is **only complete** when `PUBLISHED_COUNT == total uploaded count` AND `DRAFT_IDS` is empty AND `NOT_FOUND_IDS` is empty.
- ❌ If verification fails after retries, the skill MUST `exit 1` and the orchestrator (`data360-retail-installer`) MUST stop — do NOT advance to `/storefront-publish`. The downstream skill assumes all CMS images are Published; running it on a partially-published workspace produces silently broken site branding (e.g., banner referenced in theme JSON but not visible to shoppers).
- ❌ Do NOT run the **Cleanup** step below until Step 7.5 passes — leave `cmsworkspace/uploads/`, `image-uploads-summary.json`, `publish-result.json`, and `publish-retry-*.json` on disk for debugging.
- ⚠️ Save the verified-status report to `cmsworkspace/publish-verification.json` for audit (one entry per managedContentId with final status and retry count).

## File Structure

After completion, the `cmsworkspace/` folder will contain:

```
cmsworkspace/
├── workspace-creation.json       # Workspace creation response
├── spaces.json                   # All workspaces (used to find PulseSync CMS Images ID)
├── channels.json                 # All channels retrieved from the org
├── result.json                   # Result of adding channels to workspace
├── image-uploads-summary.json    # Summary of all image uploads
├── publish-result.json           # Publish response with deployment ID
└── uploads/                      # Individual upload responses
    ├── 5-gallon-all-purpose-mixing-container.json
    ├── another-product.json
    └── ...
```

## Error Handling

### Authentication Errors
- If `sf org display` fails, the org alias is invalid or not authenticated
- Guide the user to run: `sf org login web --alias <alias>`

### API Errors
- **401 Unauthorized**: Access token expired or invalid - re-authenticate
- **400 Bad Request**: Check the request body format matches the examples
- **404 Not Found**: Verify the API endpoint URLs are correct
- **403 Forbidden**: User may not have permissions for CMS operations

### Channel Addition Errors
- If some channels fail to add, check the response for specific error messages
- Some channels may already be associated with other workspaces

### Image Upload Errors (Step 6)

**Common Issues**:

1. **Missing or Invalid contentSpaceId**:
   - **Error**: HTTP 400 with message about invalid contentSpaceOrFolderId
   - **Cause**: The contentSpaceId was not retrieved from Step 3 or is hardcoded incorrectly
   - **Fix**: Verify `spaces.json` exists and contains the "PulseSync CMS Images" workspace with a valid ID field

2. **File Path Issues on Windows**:
   - **Error**: curl error "no such file or directory" or "can't open file"
   - **Cause**: Using Windows backslash paths like `C:\Users\...`
   - **Fix**: Use forward slash paths in Git Bash: `/c/Users/...`

3. **Duplicate URL Names / Duplicate Names**:
   - **Error**: pre-flight (Step 6.0b) reports an existing ManagedContent row, OR HTTP 400 with a duplicate-urlName message
   - **Cause**: a content item with this title/urlName already exists in the workspace (e.g. from a partial earlier run)
   - **Fix**: delete the existing ManagedContent row(s) — do NOT add a timestamp/suffix. The site-branding-setup skill looks up the 4 branding images by **exact** Name (`PulseSyncLogo`, `PulseSyncBanner1`, `PulseSyncBanner2`, `HealthCloudBanner`); a renamed duplicate breaks that lookup.

4. **Multipart Form-Data Issues**:
   - **Error**: HTTP 400 "Invalid request body"
   - **Cause**: Missing `;type=application/json` after the content JSON or `;type=image/png` after file path
   - **Fix**: Ensure curl -F parameters include proper type declarations

5. **File Size Limits**:
   - **Error**: HTTP 413 Payload Too Large
   - **Cause**: Image file size exceeds Salesforce limits (typically 25MB max)
   - **Fix**: Compress or resize the image before upload

6. **Authorization Issues**:
   - **Error**: HTTP 401 Unauthorized
   - **Cause**: Access token expired or missing "Bearer " prefix
   - **Fix**: Re-authenticate and ensure `Authorization: Bearer ${ACCESS_TOKEN}` format

**Best Practices**:
- ❌ Do NOT continue on a failed upload. The strict loop in Step 6 aborts on the first non-2xx response — leave it that way. Skipping a failed upload silently yields a half-populated workspace and breaks downstream skills (storefront search index, site branding).
- ✅ Always verify `contentSpaceId` is not empty before starting the upload loop.
- ✅ Save every response to `cmsworkspace/uploads/<urlName>.json` for debugging — but a saved error response does NOT count as success.
- ✅ Generate a summary report. In strict mode the only valid summary is `Failed: 0`; anything else means the skill aborted before completion.
- ❌ Do NOT add suffixes to urlNames to dodge duplicate errors — fix the duplicate at the source.

## Example User Prompts

- "Create a CMS workspace for my org alias `mystore`"
- "Set up a Commerce B2C workspace with channels for the `devorg` alias"
- "I need to create the PulseSync CMS Images workspace for org `prodorg`"

## Output Format

After successful completion, provide the user with:

1. **Summary** of what was created:
   - Workspace name and ID
   - The two specific channels that were added (PulseSync Channel and PulseSync)

2. **File locations** where results are saved

3. **Next steps** if applicable (e.g., how to view the workspace in Salesforce)

Example output:
```
✓ Authenticated with org alias 'mystore'
✓ Created workspace 'PulseSync CMS Images' (ID: <contentSpaceId>)
✓ Retrieved and filtered channels
✓ Added 2 channels to workspace:
  - PulseSync Channel (PublicUnauthenticated)
  - PulseSync (Community)
✓ Uploaded product images (<successful> successful, <failed> failed)
✓ Published <successful> images (Deployment ID: <deploymentId>)

Results saved to:
- cmsworkspace/workspace-creation.json
- cmsworkspace/spaces.json
- cmsworkspace/channels.json  
- cmsworkspace/result.json
- cmsworkspace/image-uploads-summary.json
- cmsworkspace/publish-result.json
- cmsworkspace/uploads/ (individual upload responses)
```

## Tips

- **API Names** must be unique within the org and contain only letters, numbers, and underscores
- **Default Language** should match your org's language settings (common: `en_US`, `en_GB`, `de`, `fr`, etc.)
- The skill adds **only two specific channels** - "PulseSync Channel" and "PulseSync" - all other channels are ignored
- If either channel is not found, report an error to the user with the available channel names and types
- **Image uploads** are done sequentially to avoid overwhelming the API - consider implementing rate limiting if needed
- All `.png` files from the ProductImages folder are uploaded. The 4 branding images (`plusesynclogo.png`, `pulsesyncbanner1.png`, `pulsesyncbanner2.png`, `healthcloudbanner.png`) MUST land with exact title/urlName per the override map in Step 6 — site-branding-setup queries `ManagedContent.Name IN ('PulseSyncLogo','PulseSyncBanner1','PulseSyncBanner2','HealthCloudBanner')` and a mismatch leaves the storefront with broken or stale images.
- ~~Keep the `cmsworkspace/` folder as a reference for the workspace configuration~~ — **OVERRIDDEN by Cleanup Step below.** The org has the actual workspace + images; the local `cmsworkspace/` folder is pure response cache and must be deleted before the next skill runs (per project policy).

## API Version

This skill uses Salesforce Connect API **v66.0**. If you need to use a different version, update all endpoint URLs accordingly.

---

## Cleanup temp artifacts (MANDATORY before next skill)

Before declaring this skill complete, delete every temporary file/folder created during the run.

**Failure handling rule:**
- If any upload or publish fails, **do NOT clean up** — leave artifacts (`cmsworkspace/uploads/*.json`, `image-uploads-summary.json`) for debugging.
- Fix the underlying issue, retry the failed item, then run cleanup once Step 7 (publish) succeeds for all images.

**Folders this skill creates and must delete (in repo root):**

```bash
cmd.exe //c "rmdir /S /Q cmsworkspace" 2>/dev/null || rm -rf cmsworkspace
```

**Files this skill stages under /c/tmp/ (only if filenames had special chars requiring sanitization) and must delete:**

```bash
rm -f /c/tmp/plusesynclogo.png
rm -f /c/tmp/pulsesyncbanner1.png
rm -f /c/tmp/pulsesyncbanner2.png
rm -f /c/tmp/healthcloudbanner.png
```

**Helper scripts this skill may have written (if used) and must delete (in repo root):**

```bash
rm -f upload_cms_images.sh
```

**Verification (must show no leftovers):**

```bash
ls -d cmsworkspace 2>&1 | grep -v "cannot access"
ls upload_cms_images.sh 2>&1 | grep -v "cannot access"
ls /c/tmp/plusesynclogo.png /c/tmp/pulsesyncbanner1.png /c/tmp/pulsesyncbanner2.png /c/tmp/healthcloudbanner.png 2>&1 | grep -v "cannot access"
```

**Rules:**
- ✅ Only delete items listed above. Do NOT delete:
  - `ProductImages/` (repo source — input files for upload)
  - `Experience Cloud/` (repo source — branding originals)
- ❌ Skipping this step is not allowed once all images are uploaded and published.

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"cms-workspace-setup"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.cms-workspace-setup` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
