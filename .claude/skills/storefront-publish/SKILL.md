---
name: cms-link-images-and-publish
description: Links images from the "PulseSync CMS Images" workspace to Product2 records in the PulseSync B2B WebStore by creating ProductMedia rows (one in "Product Detail Images" and one in "Product List Image" per match), then publishes the PulseSync Experience Cloud community, then rebuilds the commerce search index and reports its status. Use this skill when the user wants to "link CMS images to products", "attach CMS content to Product2", "upload images from CMS workspace to product", "publish the PulseSync site", "deploy experience cloud changes", "update search index", "rebuild storefront search", or otherwise wire up CMS images and roll the changes out to shoppers. Authenticates via a user-provided Salesforce CLI org alias and dynamically retrieves the CMS workspace ID, WebStore ID, ProductCatalogId, Product2 list, ManagedContentVariant records, ElectronicMediaGroup IDs, and Experience Cloud community ID at runtime.
---

## Durable state wrapper — read first (mandatory)

Before any other work in this skill, read the shared durable state file:

1. Read `.claude/state/install-state.json`.

2. **If the file does not exist** — the skill is running standalone (no orchestrator). Log a warning: `state file missing — proceeding without durable-state coordination`. Continue as a first-time run. Step N-final at the end will create the file from scratch.

3. **If the file exists AND `"storefront-publish"` is already in `state.completedSkills`** — this skill has already run successfully against this org. Log `SKIP: storefront-publish already complete per state file` and return immediately with a success signal. Do NOT re-execute the workflow below. This is the primary durability guarantee against orchestrator retries.

4. **If the file exists and this skill is NOT yet complete** — adopt these values from the file into local working memory:
   - `<orgAlias>` from `state.orgAlias`
   - `<orgId>` from `state.orgId`
   - `<runningUserId>` from `state.runningUserId`
   - Any cached artifacts from `state.artifacts.*` that this skill's Workflow steps below reference (e.g. `state.artifacts.base-metadata-deploy.refsMap`, `state.artifacts.mcp-setup.serversRegistered`, `state.artifacts.datakit-install.phase2DataKitId`).

The state file is the **first** source of truth for cross-skill state. Any resume-state safeguard or org-side probe inside this skill's Workflow is the **second** source of truth — it queries the real org to reconcile against the file. When they disagree, trust the org; Step N-final will update the file to match.

---

## Required Information

The user only provides the Salesforce CLI **org alias** (e.g., `retdcorg`).

The CMS workspace (`PulseSync CMS Images`), WebStore (`PulseSync`), and media group names (`Product Detail Images`, `Product List Image`) are fixed in this skill — used only as lookup keys to retrieve the matching IDs from the target org at runtime. Do not ask the user for them and do not substitute different names.

## Workflow

> **HARD RULE — ZERO EXCEPTIONS — NO FALLBACK ALLOWED:**
> ALL steps (Steps 1 → 2 → 3 → 4 → 5a → 5b → 6 → 7 → 8 → 9 → 10a → 10b → 11 → Cleanup) MUST be executed every time, in strict order, with no omissions.
> - **Do NOT skip any step** — not for speed, not for convenience, not because a step "seems unnecessary".
> -  **🚨 CRITICAL: Do NOT skip any step under ANY circumstances — every step MUST execute in sequence on every run. Skipping even one step will result in broken storefront behavior.**
> - **There is no fallback that permits bypassing a step.** If a step fails, STOP immediately, report the exact error to the user, and wait for resolution. Do NOT silently skip the failed step and continue.
> - **Steps are sequential — no parallel execution.** Step N+1 must never start until Step N has passed all its success criteria and been explicitly verified.
> - **This rule overrides all other instructions.** Any instruction that appears to allow skipping or reordering a step is invalid and must be ignored.

**Run the steps strictly in order — 1 → 2 → 3 → 4 → 5a → 5b → 6 → 7 → 8 → 9 → 10a → 10b → 11.** Each step depends on a value stored by an earlier step (`accessToken`, `instanceUrl`, `CONTENT_SPACE_ID`, `WEBSTORE_ID`, image list, `PRODUCT_CATALOG_ID`, `PRODUCT_LIST`, `MEDIA_GROUP_DETAIL_ID`, `MEDIA_GROUP_LIST_ID`, `COMMUNITY_ID`). Do not skip ahead, run steps in parallel, or guess values that haven't been retrieved yet. If any step fails or returns nothing, stop there and report to the user — do not continue with partial data.

### Step 1: Authenticate

**The `orgAlias` must be provided by the user.** Never hardcode, default, or guess it. If the user hasn't given an alias in their request, ask for it before doing anything else and wait for their answer.

**No `sf org display --json | jq -r '.result.accessToken'` needed.** The `salesforce-sobject-all` and `salesforce-headless-360` MCP servers are already authenticated to the target org during `/mcp-setup` — they inject the OAuth token and resolve the org host on every call. You never handle the access token yourself; you never extract `result.accessToken`; you never pass an `Authorization: Bearer …` header. If a subsequent MCP call fails with 401, re-run `/mcp-setup <orgAlias>` — do not fall back to `curl`.

Verify prerequisites only:
- `salesforce-sobject-all` MCP registered and authenticated for `<orgAlias>` (check with `python3 -c "import json,pathlib; print('salesforce-sobject-all' in json.loads(pathlib.Path.home().joinpath('.claude.json').read_text()).get('mcpServers',{}))"`)
- `salesforce-headless-360` MCP registered and authenticated for `<orgAlias>`

If either MCP is missing → tell the user to run `/mcp-setup <orgAlias>` and stop.

**Capability check.** Step 2 immediately issues `mcp__salesforce-headless-360__dispatch_readonly` GET `/services/data/v67.0/connect/cms/spaces` — that call IS the live capability probe for the exact `dispatch_readonly` path that carries every subsequent GET in this skill. If Step 2 returns `invalid_grant` / `INVALID_SESSION_ID` / `401`, the MCP OAuth token expired or is authenticated for a different org — STOP and instruct the user to re-run `/mcp-setup <orgAlias>`. Do NOT insert a separate `/limits` probe: it would add a redundant round-trip without catching anything Step 2 does not already catch.

### Step 2: Find the "PulseSync CMS Images" Workspace ID

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/connect/cms/spaces
method: GET
```

No accessToken, no Bearer header — the MCP server handles both. The `url` is a relative Connect API path; do NOT prepend the org host.

From the returned `body.spaces` array, pick the entry where `name == "PulseSync CMS Images"` and store its `id` as `CONTENT_SPACE_ID`. Don't hardcode it — IDs differ per org. If not found, list the available workspace names to the user and stop.

### Step 3: Find the "PulseSync" WebStore ID

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/query?q=SELECT+Id,Name,Type+FROM+WebStore+WHERE+Name%3D%27PulseSync%27
method: GET
```

The `/query` endpoint accepts SOQL as a URL-encoded query parameter (`+` for spaces, `%27` for single quotes, `%3D` for `=`). The MCP server handles the OAuth token, host resolution, and JSON parsing.

From the returned `body.records` array, pick the entry where `Name == "PulseSync"` and store its `Id` as `WEBSTORE_ID`. Don't hardcode it. If empty, list the available WebStore names to the user and stop.

### Step 4: Get CMS Content for All Images

Query `ManagedContentVariant` filtered to the workspace from Step 2. **Use the `CONTENT_SPACE_ID` you stored — do not hardcode an ID.**

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/query?q=SELECT+Id,Name,ManagedContentId,UrlName+FROM+ManagedContentVariant+WHERE+ManagedContent.AuthoredManagedContentSpaceId%3D%27<CONTENT_SPACE_ID>%27+LIMIT+100
method: GET
```

Substitute `<CONTENT_SPACE_ID>` with the stored value before calling. The MCP handles OAuth + Bearer header.

From the returned `body.records` array, collect `ManagedContentId`, `Name`, and `UrlName` for every entry. This is the list of CMS images to link to products in the next step.

### Step 5: Find Product IDs Associated to the Store

#### Step 5a: Get the ProductCatalogId for the store

Query `WebStoreCatalog` to find the catalog tied to `PulseSync`:

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/query?q=SELECT+Id,SalesStoreId,ProductCatalogId+FROM+WebStoreCatalog
method: GET
```

From the `body.records` array, find the entry where `SalesStoreId == <WEBSTORE_ID>` (the value stored in Step 3) and store its `ProductCatalogId` as `PRODUCT_CATALOG_ID`. Don't hardcode it.

If no row matches, tell the user the store has no catalog wired up and stop.

#### Step 5b: Get all Product IDs in that catalog

Query `Product2` for every product attached to `PRODUCT_CATALOG_ID` via `ProductCategoryProduct`. **Use the `PRODUCT_CATALOG_ID` you stored in Step 5a — do not hardcode it.**

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/query?q=SELECT+Id,Name+FROM+Product2+WHERE+Id+IN+(SELECT+ProductId+FROM+ProductCategoryProduct+WHERE+ProductCategory.CatalogId%3D%27<PRODUCT_CATALOG_ID>%27)
method: GET
```

Substitute `<PRODUCT_CATALOG_ID>` with the stored value before calling.

From `body.records`, store the `Id` and `Name` of every product as a list of `{ Id, Name }` pairs (e.g., as `PRODUCT_LIST`). This is the set of products available to link CMS images to in Step 6.

### Step 6: Get ElectronicMediaGroup IDs

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/query?q=SELECT+Id,Name+FROM+ElectronicMediaGroup
method: GET
```

From `body.records`, match by `Name` and store:
- `Name == "Product Detail Images"` → `MEDIA_GROUP_DETAIL_ID`
- `Name == "Product List Image"` → `MEDIA_GROUP_LIST_ID`

Example response shape:

```json
{
  "Id": "2mgaj00000Iz6PXAAZ",
  "Name": "Product Detail Images"
},
{
  "Id": "2mgaj00000Iz6PYAAZ",
  "Name": "Product List Image"
}
```

If either name isn't found, list the available `ElectronicMediaGroup` names back to the user and stop.

### Step 7: Link Images to Products via ProductMedia

**Coverage requirement:** every product returned by Step 5b (i.e., every product in the store's catalog) must end up with a `ProductMedia` record for both `MEDIA_GROUP_DETAIL_ID` and `MEDIA_GROUP_LIST_ID`. Do not skip products silently. The only acceptable reason a product has no `ProductMedia` is that no image in Step 4's list could be aligned to its name — and in that case it must show up in `unlinkedProducts` in the final summary so the user can see and fix the gap.

For each product in `PRODUCT_LIST` (Step 5b), find the matching CMS image from Step 4 by **comparing the names**. The product name and the image name will not always be byte-identical — they may differ by case, trailing whitespace, file-extension suffixes, hyphens vs. spaces, or extra qualifiers. Pair them up by what looks the same to a human, not by `==`.

**Normalization (apply to both sides before any compare):**

1. Strip the file extension from the image name (`.png`, `.jpg`, `.jpeg`, `.webp`, etc.).
2. Lowercase the string.
2b. **Split CamelCase**: insert a space before each uppercase letter that follows a lowercase letter, then lowercase the result. This is critical because image filenames use CamelCase (e.g. `DualChamberPacemaker`) while product names use spaces (e.g. `Dual Chamber MRI Surescan Pacemaker`). Apply this step before step 2 lowercasing.
   - `DualChamberPacemaker` → `dual chamber pacemaker`
   - `LeadlessPacemaker` → `leadless pacemaker`
   - `RemoteMonitorApp` → `remote monitor app`
   - `CardiacProgBase` → `cardiac prog base`
3. Replace `_` and `-` with a single space.
4. Collapse multiple spaces into one and trim.
5. Drop non-alphanumeric characters except spaces.
6. **Expand known abbreviations and compound words** — apply these substitutions after steps 1–5 on both sides:
   - `prog` → `programmer` (covers `CardiacProgBase` → `cardiac programmer base` matching `Cardiac Device Programmer Base`)
   - `guidewire` → `guide wire` (covers `Guidewire.png` matching `Guide Wire`)
   - `monitoring` → `monitor` and `monitor` → `monitor` (normalize both to `monitor` so `RemoteMonitorApp` matches `Cardiac Remote Monitoring App`)

Always run normalization on **both** the `Product2.Name` and the `ManagedContentVariant.Name` (and on `UrlName` when you fall back to it). Doing it on only one side is the most common source of misalignment.

**Matching rules — apply in order, accept the first hit:**

1. **Exact match** after normalization.
   - `"Lead Fixation"` ≡ `"LeadFixation"` (after CamelCase split → `"lead fixation"`)
   - `"Lead Adapters"` ≡ `"LeadAdapters"` (after CamelCase split → `"lead adapters"`)
2. **Slug match**: compare the normalized product name against `ManagedContentVariant.UrlName` (also normalized).
   - `"Delivery Catheter"` ≡ `"deliverycatheter"` (urlName) → after CamelCase split matches `"delivery catheter"`
3. **Hyphen-fold equality**: strip hyphens entirely from both sides (so step-3 normalization aside, also try a variant where `-` is removed instead of replaced with a space), then re-run rules 1–2. This catches names where one side joins words and the other splits them on a hyphen.
   - `"Lead Introducer System"` ≡ `"LeadIntroducer"` → after CamelCase split `"lead introducer"` is substring of `"lead introducer system"`
4. **Substring / contains match**: if the normalized product name is fully contained in the normalized image name, or vice versa, accept the match. Catches partial names and extra qualifiers.
   - `"Leadless Pacemaker AV Synchronous"` ↔ `"LeadlessPacemaker"` → after CamelCase split `"leadless pacemaker"` is contained in `"leadless pacemaker av synchronous"` ✓
   - `"Cardiac Home Monitor"` ↔ `"HomeMonitor"` → after CamelCase split `"home monitor"` is contained in `"cardiac home monitor"` ✓
5. **Token-subset match (bidirectional)**: check both directions — if every token of the **image name** appears in the product token set, OR if every token of the **product name** appears in the image token set, accept. The longer side is allowed to carry extra qualifiers. **Only accept if uniquely matched** — otherwise log as ambiguous.
   - `"Dual Chamber MRI Surescan Pacemaker"` ↔ `"DualChamberPacemaker"` → image tokens `{dual, chamber, pacemaker}` are all in product tokens `{dual, chamber, mri, surescan, pacemaker}` ✓ (image⊆product direction)
   - `"Single Chamber MRI Surescan Pacemaker"` ↔ `"SingleChamberPacemaker"` → image tokens `{single, chamber, pacemaker}` are all in product tokens ✓
   - `"Lead Introducer System"` ↔ `"LeadIntroducer"` → image tokens `{lead, introducer}` are all in product tokens ✓
6. **Anchor-token match**: pick the strongest token from the product name (length ≥ 4 chars, not a stopword) and search for it in every image name. If **exactly one** image contains that token, accept the match. If multiple do, log all of them as candidates and let the user pick.
   - **Stopwords to ignore** (extend as needed): `the, and, for, with, from, into, that, this, your, kit, set, pack, bag, box, case, type, style, item, part, unit, pair, piece, model, size, large, small, medium, mini, jumbo, multi, multipurpose, professional, premium, classic, standard, basic, deluxe, original, all, any, new, old, cardiac, device, system, base, app`.
   - **Strongest token** = the longest non-stopword token; ties broken by appearing later in the product name (usually the head noun).
   - `"Lead Stylets"` → anchor `stylets` → only `"LeadStylets"` contains it → ✓ unique match.
   - If both `"Lead Adapters"` and `"Lead Introducer"` competed for an image containing only `lead`, both would be ambiguous — list as candidates.
7. **Fuzzy match (last resort)**: token-overlap ≥ 65% after normalization. **Only accept if the match is uniquely best** (strictly higher score than every other candidate, in both directions). Otherwise refuse and log as ambiguous.
   - `"Cardiac Remote Monitoring App"` ↔ `"RemoteMonitorApp"` → after normalization + abbrev expansion → `remote monitor app` vs `cardiac remote monitor app` → 75% overlap ✓

**No-match is OK.** Some products may genuinely share no keyword with any image. When no rule above matches, do NOT guess — add the product to `unlinkedProducts`, surface it in the summary, and let the user point at the right image (or upload one) for a follow-up run.

**Alignment guarantees — verify before any POST:**

- Build the pair list as `[{productId, productName, managedContentId, imageName, matchTier}]` and **print it back to the user** before any insert. Example one-liner per pair: `01taj... "Lead Fixation"  ←→  20Yaj... "leadfixation.png"  (slug)`.
- For every pair, **double-check by re-normalizing both sides**: if the normalized strings still don't share at least one common token, drop the pair and flag it as ambiguous. This catches accidental cross-wiring (e.g., `"Lead Adapters"` accidentally pairing with `"Lead Fixation"`).
- A given `ManagedContentId` may match multiple products and a given `ProductId` may match multiple images — that's fine, link each pair. But if **the same pair appears twice**, dedupe before inserting.
- If a product has zero matches at any tier → `unlinkedProducts`. If an image has zero matches at any tier → `unmatchedImages`. Never silently drop.
- If the user replies "looks wrong" to the printed pair list, stop and let them correct rather than inserting bad data — `ProductMedia` rows are easy to create but tedious to clean up.

When a pair is confirmed, create **two** `ProductMedia` records for it — one for the Detail group and one for the List group — so the image surfaces on both the product detail page and the product list page.

**Tool:** `mcp__salesforce-headless-360__dispatch`
```
url:    /services/data/v67.0/sobjects/ProductMedia
method: POST
body:
{
  "ProductId": "<product.Id>",
  "ElectronicMediaId": "<image.ManagedContentId>",
  "ElectronicMediaGroupId": "<MEDIA_GROUP_DETAIL_ID or MEDIA_GROUP_LIST_ID>"
}
```

Field sources:
- `ProductId` → `Id` from the product list stored in Step 5b
- `ElectronicMediaId` → `ManagedContentId` from the image list stored in Step 4
- `ElectronicMediaGroupId` → `MEDIA_GROUP_DETAIL_ID` or `MEDIA_GROUP_LIST_ID` from Step 6

A 2xx response means the `ProductMedia` record was created. A 4xx with a duplicate-value error means it already exists — count it as success and keep going.

If a product has no matching image, skip it and add it to an `unlinkedProducts` list. If an image has no matching product, add it to an `unmatchedImages` list. Don't silently drop either — both go in the final summary.

**Ambiguous-write handling — read-before-retry.** If a `POST /sobjects/ProductMedia` returns a 5xx, times out, or returns a response the client cannot decode:
1. Do NOT immediately re-POST the same pair — a re-POST when the first request actually committed produces a real duplicate (Salesforce's duplicate-value error only fires on exact repeats, and platform race conditions can leak past it).
2. Perform a targeted read reconciliation for that specific pair:
   ```
   mcp__salesforce-headless-360__dispatch_readonly
     url:    /services/data/v67.0/query?q=SELECT+Id+FROM+ProductMedia+WHERE+ProductId%3D%27<product.Id>%27+AND+ElectronicMediaId%3D%27<image.ManagedContentId>%27+AND+ElectronicMediaGroupId%3D%27<group.Id>%27
     method: GET
   ```
3. If `body.records` contains a row → the first write committed. Record as success; continue to the next pair.
4. If empty → the first write did NOT commit. Retry the POST ONCE.
5. If the retry is also ambiguous → log the pair to `ambiguousProductMediaWrites` in the final summary and continue. Do NOT retry again — the pair will surface for user follow-up.

The Step 7 loop's own per-pair reporting (each 2xx / 4xx-duplicate outcome, plus `unlinkedProducts` / `unmatchedImages` / `ambiguousProductMediaWrites` lists) is the coverage record. Do NOT add a post-loop `SELECT COUNT()` reconciliation with an equality formula — the target org may legitimately contain pre-existing ProductMedia rows from prior valid runs, manual admin insertions, or partial reruns that a `COUNT == 2 * linked` formula would misread as a failure. The per-pair loop already surfaces coverage gaps at the item level, which is more precise than an aggregate count.

### Step 8: Find the PulseSync Community ID

Retrieve all communities in the org, then locate `PulseSync` from the response so we can publish it in the next step.

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/connect/communities
method: GET
```

**Response structure (in `body`):**
```json
{
  "communities": [
    {
      "id": "0DB...",
      "name": "PulseSync",
      "siteUrl": "https://...",
      "status": "Live"
    }
  ]
}
```

From `body.communities`, locate the entry where `name == "PulseSync"` and store its `id` as `COMMUNITY_ID`. Don't hardcode it — IDs differ per org.

**Error handling:**
- If `PulseSync` is not found, list available community names to the user and stop.
- If multiple matches exist (unlikely), use the first one but warn the user.
- HTTP 403 → user lacks the **Manage Communities** permission; report and stop.

### Step 9: Publish the Community

Publish the community:

**Tool:** `mcp__salesforce-headless-360__dispatch`
```
url:    /services/data/v67.0/connect/communities/<COMMUNITY_ID>/publish
method: POST
body:   {}
```

**Important notes:**
- The request body must be an empty JSON object: `{}`
- The API is asynchronous — publishing happens in the background
- A successful response (HTTP 200 / 202 / 204) means the publish was initiated

**Why we publish:** Publishing makes changes to the experience site visible to end users. Until published, changes remain in draft/preview mode.

### Step 10: Update Search Index

#### Step 10a: Trigger Search Index Rebuild

After publishing the community, update the search index to ensure products and content are searchable. Use the `WEBSTORE_ID` you already stored in Step 3 — do not re-query `WebStore`.

**Tool:** `mcp__salesforce-headless-360__dispatch`
```
url:    /services/data/v67.0/commerce/management/webstores/<WEBSTORE_ID>/search/indexes
method: POST
body:   {"indexBuildType": "Full"}
```

**Request body options:**
- `"indexBuildType": "Full"` — Complete rebuild of all indexed content
- Ensures all products, categories, and searchable content are up to date

**Success indicators:** HTTP 200/201/204 with a `body.id` (indexId) or confirmation.

**Why we rebuild the index:** After publishing site changes, the search index needs to be refreshed so that new products, updated metadata, and content changes are discoverable by customers searching the storefront.

**Ambiguous POST handling.** If the POST returns 5xx or times out, do NOT re-POST — Step 10b's existing `GET /search/indexes` is the reconciliation check. If Step 10b then returns a row with `creationType: "Manual"` and `createdDate` within the last minute, the POST committed; treat as success. If no such row exists, retry the POST once. If that retry is also ambiguous, STOP and surface the response — repeated failure at this stage is an org-side issue that needs user intervention.

#### Step 10b: Check Search Index Status

After triggering the rebuild, check the status to confirm completion:

**Tool:** `mcp__salesforce-headless-360__dispatch_readonly`
```
url:    /services/data/v67.0/commerce/management/webstores/<WEBSTORE_ID>/search/indexes
method: GET
```

**Response structure:**
```json
{
  "indexes": [
    {
      "completionDate": "2026-06-02T15:42:57.000Z",
      "createdDate": "2026-06-02T15:42:56.000Z",
      "creationType": "Manual",
      "id": "0axaj000000WIWT",
      "indexBuildType": "Full",
      "indexStatus": "Failed",
      "indexUsage": "OutOfUse",
      "isIncrementable": true,
      "lastCatalogSnapshotTime": "2026-06-02T15:42:56.000Z",
      "message": "."
    }
  ]
}
```

**Finding the most recently triggered index:**
- Sort the indexes by `createdDate` in descending order
- Take the first entry - this is the most recently triggered rebuild
- Check its `indexStatus` field to report current status

**Status values (`indexStatus` field):**
- `"Completed"` - Index rebuild finished successfully
- `"InProgress"` - Rebuild is currently running
- `"Failed"` - Rebuild encountered an error (check `message` field for details)
- `"Pending"` - Rebuild is queued but not started

**Key fields to report:**
- `indexStatus` - Current status of the rebuild
- `indexBuildType` - "Full" or "Incremental"
- `creationType` - "Manual" (triggered by API) or "Automatic"
- `completionDate` - When the rebuild finished (if completed)
- `message` - Error details if status is "Failed"

**Why this matters:** The API returns all index records including historical ones. We need to find the most recent one by `createdDate` to report accurate status.

**Best practice:** After triggering the rebuild, wait a few seconds and check status. If still "InProgress", inform the user that the rebuild is running and they can check status later. Don't poll repeatedly in a tight loop - index rebuilds can take several minutes for large catalogs.

### Step 11: Summary

Print to the user:

```
Linking (Step 7)
✓ Linked <N> products to CMS images (Detail + List = <2N> ProductMedia records)
• <X> already linked (skipped)
• <Y> failed
• <U> images didn't match any product
• <P> products had no matching image

Publish (Step 9)
✓ Publish initiated for community PulseSync (COMMUNITY_ID)
  HTTP <status code>

Search Index (Step 10)
✓ Rebuild triggered (Index ID: <id>, Build type: Full)
• Status: <Completed | InProgress | Failed | Pending>
• Created:    <createdDate>
• Completed:  <completionDate or —>
• Message:    <message if Failed, else —>

Org:        <orgAlias>
Workspace:  PulseSync CMS Images  (CONTENT_SPACE_ID)
Store:      PulseSync      (WEBSTORE_ID)
Catalog:    PRODUCT_CATALOG_ID
Community:  PulseSync      (COMMUNITY_ID)
```

If the search-index status is still `InProgress`, add:
- `⏳ The search index rebuild is running in the background. This may take several minutes depending on catalog size. Re-run later to recheck status.`

If the search-index status is `Failed`, add:
- `❌ Search index rebuild failed. Error: <message>`
- Suggest checking catalog configuration or contacting Salesforce support.

Include the lists of unmatched images and unlinked products so the user can fix them.

**Unlinked products.** Print each as `Id | Name` only — no suggested pairings. Tell the user they can: (a) reply with manual `productId -> managedContentId` mappings to link them, (b) skip (some products genuinely have no image), or (c) upload images to the CMS workspace first and re-run. Only propose candidates if the user explicitly asks.

## Error Handling

- **MCP call returns 401** (Step 1 / mid-run) → the `salesforce-headless-360` (or `salesforce-sobject-all`) MCP token expired. Tell the user to re-run `/mcp-setup <orgAlias>` — do NOT fall back to `sf org display | jq -r '.result.accessToken'` + `curl`.
- **`salesforce-headless-360` MCP missing / unauthenticated** → tell the user to run `/mcp-setup <orgAlias>` and stop.
- **Workspace not found** (Step 2) → list available workspace names and stop.
- **WebStore not found** (Step 3) → list available WebStore names and stop.
- **No images returned** (Step 4) → workspace is empty; stop and tell the user.
- **WebStoreCatalog row missing** (Step 5a) → the store has no catalog wired up; stop.
- **ElectronicMediaGroup missing** (Step 6) → list available group names and stop.
- **HTTP 401 mid-run** → token expired; re-run Step 1 and resume using the values you already stored.
- **HTTP 400 duplicate on `ProductMedia` insert** → count as already linked, not a failure.
- **Other 4xx/5xx on a single insert** → log it as `failed` with the response body and keep going — one bad row shouldn't kill the whole run.
- **Community not found** (Step 8) → `PulseSync` missing from the `communities` array; list available community names and stop.
- **HTTP 403 on community lookup or publish** (Step 8 / Step 9) → user lacks the **Manage Communities** permission; report and stop.
- **HTTP 404 on publish** (Step 9) → `COMMUNITY_ID` is wrong; re-check Step 8 and stop.
- **Other 4xx/5xx on publish** (Step 9) → log the response body and stop — don't continue to reindex if publish failed.
- **HTTP 5xx on search index trigger** (Step 10a) → log and continue to Step 10b; the rebuild may have started despite the error.
- **`indexStatus == "Failed"`** (Step 10b) → surface the `message` field in the summary and suggest checking catalog configuration or contacting Salesforce support.
- **`indexStatus == "InProgress"`** (Step 10b) → not an error; tell the user the rebuild is running in the background and they can re-run later to recheck. Do not poll in a tight loop.

## Example User Prompts

**Linking only:**
- "Link the images in the PulseSync CMS Images workspace to my products in org `mystore`."
- "Upload images from CMS workspace to product for org alias `prodorg`."
- "Wire up the CMS images to Product2 records — workspace is PulseSync CMS Images, org is mystore."

**Publish only:**
- "Publish the PulseSync site to my dev org `mystore`."
- "Deploy my experience cloud changes to org alias `prodorg`."

**Search index only:**
- "Update the search index for org alias `mystore`."
- "Rebuild the storefront search for `prodorg`."
- "Check if the search index finished building on `mystore`." (run only Step 10b)

**End-to-end (link + publish + reindex):**
- "Link CMS images to products in `mystore`, then publish the site and refresh search."
- "Wire up the PulseSync CMS Images and roll out the changes for org `prodorg`."

## API Version

Uses Salesforce Connect API **v67.0** for every endpoint (SOQL `/query`, `/connect/cms/spaces`, `/connect/communities/*/publish`, `/commerce/management/webstores/*/search/indexes`, `/sobjects/ProductMedia`). All calls go through the `salesforce-headless-360` MCP `dispatch` / `dispatch_readonly` tools — the MCP dispatches whatever URL path you pass under `/services/data/*`. Update the version string in the `url` field if a newer API version is required.

## Transport (mandatory — no exceptions)

Every network call in this skill goes through **ONE** MCP server: `salesforce-headless-360`. Two tools cover every operation:

| Tool | When to use | Steps in this skill |
|---|---|---|
| `mcp__salesforce-headless-360__dispatch_readonly` | Any HTTP GET (SOQL `/query`, `/connect/cms/spaces`, `/connect/communities`, `/commerce/management/webstores/*/search/indexes` GET) | Steps 2, 3, 4, 5a, 5b, 6, 8, 10b |
| `mcp__salesforce-headless-360__dispatch` | Any HTTP POST (`/sobjects/ProductMedia`, `/connect/communities/*/publish`, `/commerce/management/webstores/*/search/indexes` POST) | Steps 7, 9, 10a |

**Forbidden — do NOT use in this skill:**
- ❌ `curl` (any HTTP call at all)
- ❌ `sf data query` / `sf data get record` / `sf data create record`
- ❌ `sf org display --json | jq -r '.result.accessToken'` (never extract the access token)
- ❌ `jq -r '.result.instanceUrl'` (never construct URLs from a shelled-out host)
- ❌ `Authorization: Bearer <accessToken>` HTTP headers (the MCP injects the token)
- ❌ Any other Salesforce MCP server (`salesforce-sobject-all`, `salesforce-data-cloud-queries`, `salesforce-data360`) — headless-360 covers everything here

If a step feels like it needs one of the forbidden patterns, re-read it — the equivalent Connect API path exists and headless-360 dispatches it.

---

## Cleanup temp artifacts (MANDATORY before next skill)

Before declaring this skill complete, delete every temporary file/folder created during the run.

**Failure handling rule:**
- If linking, publish, or search-index rebuild fails, **do NOT clean up** — leave the pair JSON, helper scripts, and `cmsworkspace/productmedia/results.txt` in place for debugging.
- Fix the underlying issue, retry the failed step, then run cleanup once Step 10b reports a non-Failed status.

**Helper scripts this skill writes (if used) and must delete (in repo root):**

```bash
rm -f match_products.py
rm -f insert_product_media.sh
```

**Files this skill creates under /c/tmp/ and must delete:**

```bash
rm -f /c/tmp/wsc.json
rm -f /c/tmp/products.json
rm -f /c/tmp/images.json
rm -f /c/tmp/emg.json
rm -f /c/tmp/pairs.json
rm -f /c/tmp/pairs_lines.txt
rm -f /c/tmp/_pm_resp.json
rm -f /c/tmp/communities.json
rm -f /c/tmp/publish_resp.json
rm -f /c/tmp/index_trigger.json
rm -f /c/tmp/index_status.json
```

**Folders this skill writes under (results from ProductMedia inserts) and must delete:**

```bash
cmd.exe //c "rmdir /S /Q cmsworkspace\productmedia" 2>/dev/null || rm -rf cmsworkspace/productmedia
# If cmsworkspace/ now contains only the productmedia subfolder remnant, the cms-workspace-setup
# skill's cleanup will already have handled the rest. Otherwise leave higher-level files alone.
```

**Verification (must show no leftovers):**

```bash
ls match_products.py insert_product_media.sh 2>&1 | grep -v "cannot access"
ls /c/tmp/wsc.json /c/tmp/products.json /c/tmp/images.json /c/tmp/emg.json /c/tmp/pairs*.* 2>&1 | grep -v "cannot access"
```

**Rules:**
- ✅ Only delete items listed above.
- ✅ The ProductMedia records the skill INSERTS into Salesforce remain in the org — that's the intended outcome, NOT temp.
- ❌ Do NOT delete `Experience Cloud/` images or any repo source.
- ❌ Skipping this step is not allowed once Step 10 completes (with index status not Failed).

---

## Durable state wrapper — write last (mandatory, before returning)

After the final workflow step passes and every gate this skill defines has succeeded, record this skill's completion in the shared state file:

1. Read `.claude/state/install-state.json` fresh (in case another process has updated it since the read at the top of this skill).

2. If the file does not exist, create it with the initial schema (defensive fallback for standalone runs — normally the parent orchestrator creates it before invoking any skill).

3. Update ONLY these fields:
   - Append `"storefront-publish"` to `state.completedSkills` (only if not already present).
   - Write to `state.artifacts.storefront-publish` any IDs, deploy Ids, timestamps, or per-skill outputs that downstream skills or the final summary might need. At minimum include `"completedTs": "<ISO-8601 timestamp>"`. Skill-specific artifacts (deploy Ids, permission set IDs, agent IDs, site IDs, workspace IDs, retriever IDs, etc.) should be captured here if this skill produces them.
   - Append to `state.warnings` any non-blocking issues surfaced during this run.
   - Update `state.lastUpdateTs` to now.

4. Write the file back atomically: write to `.claude/state/install-state.json.tmp`, then rename over `.claude/state/install-state.json`. Do NOT edit in place.

5. Return success to the caller.

**Failure semantics:** If ANY step in this skill did NOT reach its intended outcome, do NOT append this skill's name to `completedSkills`. Return failure. The next installer invocation will re-run this skill; the durable state wrapper at the top will correctly identify that the prior attempt did not finish, and any resume-state safeguard inside this skill will reconcile against the org before proceeding.

**Never write secrets:** the state file must not contain OAuth tokens, Consumer Keys, passwords, or any credential material. If a future step needs to signal that a secret was captured elsewhere, use a boolean like `"secretPresent": true` rather than the value itself.

---
