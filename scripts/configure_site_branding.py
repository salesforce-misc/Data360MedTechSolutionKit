#!/usr/bin/env python3
"""
Configure ALL site branding (Site Logo + Banners + Embedded Messaging chat icon)
in ONE retrieve + ONE deploy + ONE publish + ONE verify cycle.

This replaces three separate publish cycles (Set-ExperienceSiteLogo.ps1,
Set-ExperienceSiteBanners.ps1, place_embedded_messaging_footer.py) that were
unstable in some orgs because each retrieve-deploy-publish round had its own
cache-propagation window. With a single publish at the very end, every change
lands together and there's no partial-state intermediate.

Cross-platform (Windows / macOS / Linux). Auto-detects sf vs sf.cmd.

Phases (deterministic, in this order):
  1. Resolve org session (instanceUrl, accessToken).
  2. Query CMS ContentKeys for plusesynclogo, healthcloudbanner, pulsesyncbanner2,
     pulsesyncbanner1 (one SOQL).
  3. (chat icon only) Verify ESA prerequisites and derive scrtUrl + siteEndpoint.
  4. Retrieve LIVE DigitalExperienceBundle ONCE into a scratch dir.
  5. Edit the retrieved files in place:
       - commerceLayout/content.json:
           - Logo header (storeLogo region) -> plusesynclogo
           - Logo footer (footer/col1 region) -> plusesynclogo
           - Add chat icon to footer region (idempotent)
       - sfdc_cms__view/home/content.json:
           - 3 banners (banner[0]=healthcloudbanner, banner[1]=pulsesyncbanner2 (Left),
             banner[2]=pulsesyncbanner1 (Right))
       - Every other content.json:
           - Strip any stale chat-icon component placements
  6. ONE deploy of every modified file.
  7. ONE sf community publish.
  8. Verify:
       - logo contentKey present in commerceLayout (>=2 occurrences)
       - 3 banner contentKeys present in home view (>=1 each)
       - chat icon present in commerceLayout footer
       - no chat icon in any other content.json
     On any miss: retry deploy + publish ONCE, then re-verify.
  9. Cleanup scratch on success; preserve on failure.

Usage:
  python configure_site_branding.py \
      --org-alias <alias> \
      --site-name PulseSync

  # Run only the chat-icon refresh (skip logo + banners):
  python configure_site_branding.py \
      --org-alias <alias> \
      --site-name PulseSync \
      --image-type chat_icon

  # Run only logo + banners (skip chat icon, e.g. before ESA is provisioned):
  python configure_site_branding.py \
      --org-alias <alias> \
      --site-name PulseSync \
      --image-type logo_banners

Exit codes:
  0  - Success.
  1  - Generic failure (deploy / publish / verify failed after retry).
  2  - ESA prerequisites missing (only relevant when chat_icon is in scope).
  3  - CMS image not found / not Published in workspace.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from pathlib import Path
from typing import Any, Optional


# ---------------------------------------------------------------------------
# CLI binary resolution
# ---------------------------------------------------------------------------

def find_sf_binary() -> str:
    override = os.environ.get("SF_CLI_PATH")
    if override and Path(override).exists():
        return override
    for name in ("sf", "sf.cmd"):
        found = shutil.which(name)
        if found:
            return found
    candidates = []
    if os.name == "nt":
        appdata = os.environ.get("APPDATA")
        local = os.environ.get("LOCALAPPDATA")
        userprofile = os.environ.get("USERPROFILE")
        if appdata:
            candidates.append(Path(appdata) / "npm" / "sf.cmd")
        if local:
            candidates.append(Path(local) / "sfdx" / "client" / "bin" / "sf.cmd")
        candidates.append(Path("C:/Program Files/sf/bin/sf.cmd"))
        candidates.append(Path("C:/Program Files (x86)/sf/bin/sf.cmd"))
        if userprofile:
            candidates.append(Path(userprofile) / "AppData/Roaming/npm/sf.cmd")
    for c in candidates:
        if c.exists():
            return str(c)
    raise SystemExit(
        "ERROR: Salesforce CLI (sf or sf.cmd) not found.\n"
        "Set SF_CLI_PATH or install via: npm install -g @salesforce/cli"
    )


SF_CLI = find_sf_binary()


def run_sf(args: list[str], capture: bool = True, check: bool = False) -> subprocess.CompletedProcess:
    cmd = [SF_CLI] + args
    print(f"  $ {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, capture_output=capture, text=True, check=check)


def sf_json(args: list[str]) -> dict:
    full = args if "--json" in args else args + ["--json"]
    proc = run_sf(full, capture=True, check=False)
    if proc.returncode != 0 and not proc.stdout.strip():
        raise RuntimeError(f"sf failed (rc={proc.returncode}): {proc.stderr}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"sf returned non-JSON: {proc.stdout[:500]}") from e


# ---------------------------------------------------------------------------
# Org session + SOQL
# ---------------------------------------------------------------------------

def get_org_session(org_alias: str) -> tuple[str, str]:
    print(f"[1] Resolving org session for alias '{org_alias}'...", flush=True)
    # Warmup so sf refreshes the token if it's stale.
    run_sf(["data", "query", "--target-org", org_alias, "--query",
            "SELECT Id FROM Organization LIMIT 1", "--json"], capture=True, check=False)
    data = sf_json(["org", "display", "--target-org", org_alias])
    if data.get("status") != 0:
        raise RuntimeError(f"sf org display failed: {data}")
    result = data["result"]
    instance = result["instanceUrl"].rstrip("/")
    token = result["accessToken"]
    print(f"      instanceUrl: {instance}")
    return instance, token


def soql(instance: str, token: str, q: str, *, tooling: bool = False, org_alias: str = "") -> list[dict]:
    base = f"{instance}/services/data/v62.0"
    base = f"{base}/tooling/query" if tooling else f"{base}/query"
    url = f"{base}?q={urllib.parse.quote(q)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode("utf-8")).get("records", [])
    except urllib.error.HTTPError as e:
        if e.code != 401 or not org_alias:
            raise
        print(f"      (REST 401; falling back to 'sf data query')")
        sf_args = ["data", "query", "--target-org", org_alias, "--query", q]
        if tooling:
            sf_args.append("--use-tooling-api")
        data = sf_json(sf_args)
        return (data.get("result") or {}).get("records", [])


# Canonical -> [acceptable name variants] map. The cms-workspace-setup skill
# normalizes uploaded filenames to the canonical key (no spaces, no extension),
# but some orgs have CMS rows that kept the original extension or a spaced
# variant from manual/legacy uploads. Try every variant in order so the script
# works regardless of which name pattern landed in this org's ManagedContent
# table.
#
# NOTE: `plusesynclogo` retains the spelling that appears on disk at
# ProductImages/plusesynclogo.png (the `s` and `l` are transposed relative to
# `PulseSync`). Do not silently correct this — the CMS row will carry the same
# spelling as the file that was uploaded.
CMS_NAME_VARIANTS: dict[str, list[str]] = {
    "plusesynclogo":     ["plusesynclogo",     "plusesynclogo.png",     "PulseSync Logo",       "PulseSyncLogo",     "pulsesynclogo"],
    "healthcloudbanner": ["healthcloudbanner", "healthcloudbanner.png", "HealthCloud Banner",   "HealthCloudBanner"],
    "pulsesyncbanner2":  ["pulsesyncbanner2",  "pulsesyncbanner2.png",  "PulseSync Banner2",    "PulseSyncBanner2"],
    "pulsesyncbanner1":  ["pulsesyncbanner1",  "pulsesyncbanner1.png",  "PulseSync Banner1",    "PulseSyncBanner1"],
}


def fetch_content_keys(instance: str, token: str, org_alias: str, canonical_names: list[str]) -> dict[str, str]:
    """Look up CMS contentKeys with name-variant tolerance.

    For each canonical name (e.g. 'plusesynclogo'), tries every variant in
    CMS_NAME_VARIANTS until one matches in ManagedContent. This handles orgs
    where the upload skipped title normalization and the CMS row kept the raw
    filename ('plusesynclogo.png' with the extension, 'PulseSync Logo' with a
    space, etc.) - the symptom is a SOQL hit of zero rows for the canonical
    name even though the image is visible in the CMS workspace UI.
    """
    print(f"[2] Fetching CMS ContentKeys for {len(canonical_names)} image(s) (variant-tolerant)...", flush=True)

    # Build a single SOQL with every variant we accept, then bucket the rows
    # back into canonical names client-side. One round trip beats N.
    all_variants: list[str] = []
    for canonical in canonical_names:
        all_variants.extend(CMS_NAME_VARIANTS[canonical])
    # SOQL string-literals: escape single quotes via doubling
    name_list = ",".join("'" + v.replace("'", "\\'") + "'" for v in all_variants)
    q = f"SELECT Name, ContentKey FROM ManagedContent WHERE Name IN ({name_list})"
    rows = soql(instance, token, q, org_alias=org_alias)
    by_name = {r["Name"]: r.get("ContentKey", "") for r in rows}

    keys: dict[str, str] = {}
    missing: list[str] = []
    for canonical in canonical_names:
        match_name = ""
        match_key = ""
        for variant in CMS_NAME_VARIANTS[canonical]:
            if by_name.get(variant):
                match_name = variant
                match_key = by_name[variant]
                break
        if match_key:
            keys[canonical] = match_key
            extra = f" (matched on '{match_name}')" if match_name != canonical else ""
            print(f"      {canonical}: {match_key}{extra}")
        else:
            missing.append(canonical)
            tried = ", ".join(repr(v) for v in CMS_NAME_VARIANTS[canonical])
            print(f"      {canonical}: NOT FOUND (tried: {tried})")

    if missing:
        print(f"      ERROR: {len(missing)} image(s) not found / not published in CMS: {missing}")
        print(f"             Run cms-workspace-setup to upload + publish, then retry.")
        print(f"             If the images appear in the CMS Workspace UI under different names,")
        print(f"             rename them to the canonical names above (or extend CMS_NAME_VARIANTS).")
        sys.exit(3)
    return keys


def verify_esa_prerequisites(instance: str, token: str, org_alias: str) -> tuple[str, str, str]:
    print(f"[3] Verifying Embedded Service prerequisites...", flush=True)
    esa = soql(instance, token,
               "SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='ESA_Web_Deployment' LIMIT 1",
               tooling=True, org_alias=org_alias)
    esa_id = esa[0]["Id"] if esa else ""
    sites = soql(instance, token,
                 "SELECT Name, UrlPathPrefix FROM Site WHERE Name LIKE 'ESW_ESA_Web_Deployment_%' "
                 "AND Status='Active' ORDER BY Name", org_alias=org_alias)
    runtime = next((r for r in sites
                    if not (r.get("UrlPathPrefix") or "").endswith("vforcesi")
                    and (r.get("UrlPathPrefix") or "").startswith("ESWESAWebDeployment")), None)
    if not esa_id or runtime is None:
        print(f"      MISSING:")
        print(f"        EmbeddedServiceConfig 'ESA_Web_Deployment': {esa_id or 'NOT FOUND'}")
        print(f"        Runtime ESW Site: {(runtime or {}).get('Name') or 'NOT FOUND'}")
        print(f"      Run embed-service-agent-on-experience-site Steps 1-5 first.")
        sys.exit(2)
    host = instance.replace("https://", "").replace("http://", "")
    prefix = host.split(".")[0]
    scrt_url = f"https://{prefix}.my.salesforce-scrt.com"
    site_endpoint = f"https://{prefix}.my.site.com/{runtime['UrlPathPrefix']}"
    print(f"      scrtUrl:      {scrt_url}")
    print(f"      siteEndpoint: {site_endpoint}")
    return esa_id, scrt_url, site_endpoint


# ---------------------------------------------------------------------------
# Bundle retrieve / deploy / publish
# ---------------------------------------------------------------------------

def scratch_root() -> Path:
    override = os.environ.get("PS_SCRATCH_DIR")
    if override:
        return Path(override)
    return Path(tempfile.gettempdir()) / "ps-site-branding"


def retrieve_bundle(org_alias: str, site_name: str, output_dir: Path) -> Path:
    print(f"[retrieve] DigitalExperienceBundle:site/{site_name}1 -> {output_dir}", flush=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    data = sf_json([
        "project", "retrieve", "start",
        "--target-org", org_alias,
        "--metadata", f"DigitalExperienceBundle:site/{site_name}1",
        "--target-metadata-dir", str(output_dir),
        "--unzip",
    ])
    if data.get("status") != 0:
        raise RuntimeError(f"Retrieve failed: {json.dumps(data)[:500]}")
    candidates = [
        output_dir / "unpackaged" / "unpackaged",
        output_dir / "unpackaged",
    ]
    for root in candidates:
        layout = (root / "digitalExperiences" / "site" / f"{site_name}1"
                  / "sfdc_cms__themeLayout" / "commerceLayout" / "content.json")
        if layout.exists():
            return layout
    # Self-extract fallback
    zip_path = output_dir / "unpackaged.zip"
    if zip_path.exists():
        extracted = output_dir / "extracted"
        extracted.mkdir(exist_ok=True)
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(extracted)
        layout = (extracted / "unpackaged" / "digitalExperiences" / "site" / f"{site_name}1"
                  / "sfdc_cms__themeLayout" / "commerceLayout" / "content.json")
        if layout.exists():
            return layout
    raise RuntimeError(f"Retrieve produced no commerceLayout/content.json under {output_dir}")


def find_bundle_root(layout_file: Path) -> Path:
    return layout_file.parents[2]


def find_home_view(bundle_root: Path) -> Optional[Path]:
    candidate = bundle_root / "sfdc_cms__view" / "home" / "content.json"
    return candidate if candidate.exists() else None


# ---------------------------------------------------------------------------
# JSON walking helpers
# ---------------------------------------------------------------------------

def has_embedded_messaging(node: Any) -> bool:
    if isinstance(node, dict):
        if node.get("definition") == "experience_messaging:embeddedMessaging":
            return True
        for v in node.values():
            if has_embedded_messaging(v):
                return True
    elif isinstance(node, list):
        for item in node:
            if has_embedded_messaging(item):
                return True
    return False


def find_top_footer_region(node: Any) -> Optional[dict]:
    if isinstance(node, dict):
        if node.get("type") == "region" and node.get("name") == "footer":
            return node
        for v in node.values():
            r = find_top_footer_region(v)
            if r is not None:
                return r
    elif isinstance(node, list):
        for item in node:
            r = find_top_footer_region(item)
            if r is not None:
                return r
    return None


def find_footer_logo_section_parent(node: Any, parent_list: Optional[list] = None) -> Optional[list]:
    if isinstance(node, dict):
        if (node.get("definition") == "community_layout:section"
                and node.get("scopedBrandingSetId") == "B2B_Footer"
                and parent_list is not None):
            return parent_list
        for v in node.values():
            r = find_footer_logo_section_parent(v, parent_list=None)
            if r is not None:
                return r
    elif isinstance(node, list):
        for item in node:
            r = find_footer_logo_section_parent(item, parent_list=node)
            if r is not None:
                return r
    return None


def strip_messaging_components_only(node: Any) -> int:
    """Remove ONLY component nodes whose definition is
    experience_messaging:embeddedMessaging. Never removes regions or sections."""
    removed = 0
    if isinstance(node, dict):
        for key, val in list(node.items()):
            if isinstance(val, list):
                before = len(val)
                val[:] = [item for item in val
                          if not (isinstance(item, dict)
                                  and item.get("type") == "component"
                                  and item.get("definition") == "experience_messaging:embeddedMessaging")]
                removed += before - len(val)
                for item in val:
                    removed += strip_messaging_components_only(item)
            elif isinstance(val, dict):
                removed += strip_messaging_components_only(val)
    elif isinstance(node, list):
        for item in node:
            removed += strip_messaging_components_only(item)
    return removed


def remove_messaging_sections_from_footer(footer: dict) -> int:
    """Strip experience_messaging:embeddedMessaging components from footer sections
    WITHOUT removing the entire section. Other components in the same section
    (e.g. c:defaultPrechatValuesComponent) are preserved.
    Only removes an entire section if it becomes completely empty after stripping."""
    children = footer.get("children")
    if not isinstance(children, list):
        return 0
    removed = 0
    new_children = []
    for child in children:
        if has_embedded_messaging(child):
            # Strip only the embeddedMessaging component(s), preserve everything else
            stripped = strip_messaging_components_only(child)
            removed += stripped
            # Only drop the section entirely if it is now empty (no children left)
            child_children = child.get("children", [])
            if child_children:
                new_children.append(child)
            # else: section is empty after stripping — drop it
        else:
            new_children.append(child)
    footer["children"] = new_children
    return removed


# ---------------------------------------------------------------------------
# Edit operations - logo, banners, chat icon
# ---------------------------------------------------------------------------

def make_imageinfo(content_key: str, alt_text: str = "") -> str:
    """Build the JSON-stringified blob expected by attributes.imageInfo."""
    return json.dumps({"imageInfoV1": {
        "url": f"/sfsites/c/cms/delivery/media/{content_key}",
        "imageId": "",
        "key": content_key,
        "type": "cms_image",
        "title": "",
        "altText": alt_text,
        "fileName": "",
    }}, separators=(",", ":"))


def update_logo_components(layout_doc: dict, logo_content_key: str) -> int:
    """Walk the commerceLayout doc and update every dxp_content_layout:siteLogo
    component's attributes.imageInfo + attributes.imageInfoMobile to point at
    the new contentKey. Returns count of components updated.

    Raises RuntimeError if no logo components are found - the retrieve produced
    a bundle that doesn't match what this skill expects, and a silent zero-update
    would publish stale logo state on the live site."""
    updated = 0
    info = make_imageinfo(logo_content_key, alt_text="plusesynclogo")

    def walk(node: Any) -> None:
        nonlocal updated
        if isinstance(node, dict):
            if (node.get("type") == "component"
                    and node.get("definition") == "dxp_content_layout:siteLogo"):
                attrs = node.setdefault("attributes", {})
                attrs["imageInfo"] = info
                if "imageInfoMobile" in attrs:
                    attrs["imageInfoMobile"] = info
                updated += 1
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(layout_doc)
    if updated < 2:
        raise RuntimeError(
            f"Logo update found {updated} dxp_content_layout:siteLogo component(s) "
            f"in commerceLayout/content.json (expected >=2: header storeLogo region + "
            f"footer col1 region). The retrieved bundle does not match the expected "
            f"theme layout - the site may have been customized in Experience Builder, "
            f"or the wrong site_name was passed. Inspect the retrieved bundle in the "
            f"scratch dir before retrying."
        )
    return updated


def update_banner_components(home_doc: dict, banner_keys: list[str]) -> int:
    """Walk the home view doc and update the first 3 dxp_content_layout:banner
    components' imageInfo, in document order, with the supplied keys.

    Order in home view (verified):
      banner[0] = healthcloudbanner (main hero)
      banner[1] = pulsesyncbanner2  (left col)
      banner[2] = pulsesyncbanner1  (right col)

    The caller passes the keys in that intended order.

    Raises RuntimeError if the home view doesn't contain at least 3 banner
    components - the retrieved bundle's home view doesn't match what this skill
    expects, and a silent zero-update would publish stale banner state.
    """
    found: list[dict] = []

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            if (node.get("type") == "component"
                    and node.get("definition") == "dxp_content_layout:banner"):
                found.append(node)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(home_doc)

    if len(found) < len(banner_keys):
        raise RuntimeError(
            f"Banner update found {len(found)} dxp_content_layout:banner component(s) "
            f"in sfdc_cms__view/home/content.json (expected >={len(banner_keys)}). "
            f"The home view does not match the expected layout - the site may have "
            f"been customized in Experience Builder, or the experience package was "
            f"not deployed. Inspect the retrieved bundle in the scratch dir before "
            f"retrying."
        )

    updated = 0
    for i, key in enumerate(banner_keys):
        attrs = found[i].setdefault("attributes", {})
        attrs["imageInfo"] = make_imageinfo(key, alt_text=f"Banner{i + 1}")
        if "imageInfoMobile" in attrs:
            attrs["imageInfoMobile"] = make_imageinfo(key, alt_text=f"Banner{i + 1}")
        updated += 1
    return updated


def build_chat_icon_section(scrt_url: str, site_endpoint: str) -> dict:
    section_uuid = str(uuid.uuid4())
    col_uuid = str(uuid.uuid4())
    section_config = json.dumps({
        "UUID": section_uuid,
        "columns": [{
            "UUID": col_uuid,
            "columnName": "Column 1",
            "columnKey": "col1",
            "columnWidth": "12",
            "seedComponents": None,
        }],
    }, separators=(",", ":"))
    return {
        "attributes": {
            "backgroundImageConfig": "",
            "backgroundImageOverlay": "rgba(0,0,0,0)",
            "componentSpacerSize": "",
            "dxpStyle": {},
            "layoutDirectionDesktop": "row",
            "layoutDirectionMobile": "column",
            "layoutDirectionTablet": "column",
            "maxContentWidth": "",
            "sectionColumnGutterWidth": "",
            "sectionConfig": section_config,
            "sectionMinHeight": "",
            "sectionVerticalAlign": "flex-start",
        },
        "children": [{
            "children": [{
                "attributes": {
                    "clientVersion": "WebV1",
                    "deploymentName": "ESA_Web_Deployment",
                    "hideChatButtonOnLoad": "Default",
                    "isExpSiteAuthMode": False,
                    "scrtUrl": scrt_url,
                    "siteEndpoint": site_endpoint,
                },
                "definition": "experience_messaging:embeddedMessaging",
                "id": str(uuid.uuid4()),
                "type": "component",
            }],
            "id": str(uuid.uuid4()),
            "name": "col1",
            "title": "Column 1",
            "type": "region",
        }],
        "definition": "community_layout:section",
        "id": section_uuid,
        "type": "component",
    }


def find_messaging_components(node: Any, found: Optional[list] = None) -> list[dict]:
    """Collect every experience_messaging:embeddedMessaging component dict in the subtree."""
    if found is None:
        found = []
    if isinstance(node, dict):
        if (node.get("type") == "component"
                and node.get("definition") == "experience_messaging:embeddedMessaging"):
            found.append(node)
        for v in node.values():
            find_messaging_components(v, found)
    elif isinstance(node, list):
        for item in node:
            find_messaging_components(item, found)
    return found


def insert_chat_icon_into_layout(layout_doc: dict, scrt_url: str, site_endpoint: str,
                                 force_reinsert: bool = False) -> str:
    """ALWAYS remove every existing chat icon from the commerceLayout, then
    insert a single fresh one in the footer pointing at the current org's
    ESA Web Deployment (scrtUrl + siteEndpoint derived at runtime, deploymentName
    fixed to 'ESA_Web_Deployment').

    Returns one of:
      'Refreshed'      - footer had existing chat-icon section(s); stripped them
                         and inserted a fresh one with runtime values.
      'Inserted'       - footer had no chat icon; inserted a fresh one.
      'AnchorFallback' - no top-level footer region; stripped any chat icon
                         elsewhere in the doc and inserted alongside the
                         footer-logo section as the schema fallback.

    The --force-reinsert flag is retained for explicit invocation but the
    default behavior is now ALWAYS strip-then-add. The user explicitly asked
    for this: "make sure you are removing the existing embedded messaging icon
    and adding new embedded messaging icon on the footer with current org ESA
    Web deployment one." A stale chat icon from a source-org retrieve would
    render but never connect (foreign scrtUrl), so re-inserting unconditionally
    is the only safe behavior even when the existing attrs look correct.
    """
    _ = force_reinsert  # behavior is unconditional now; flag kept for CLI compat

    footer = find_top_footer_region(layout_doc)
    if footer is not None:
        existing_components = find_messaging_components(footer)
        if existing_components:
            removed = remove_messaging_sections_from_footer(footer)
            print(f"      Removed {removed} existing chat-icon section(s) from footer "
                  f"(unconditional strip-then-add).")
        new_section = build_chat_icon_section(scrt_url, site_endpoint)
        footer.setdefault("children", []).append(new_section)
        action = "Refreshed" if existing_components else "Inserted"
        print(f"      {action} chat icon in commerceLayout footer "
              f"pointing at deploymentName='ESA_Web_Deployment', siteEndpoint={site_endpoint}.")
        return action

    # Anchor fallback: no top-level footer region in the doc.
    # Strip any chat icon anywhere in the doc, then insert next to the
    # footer-logo section.
    existing_components = find_messaging_components(layout_doc)
    if existing_components:
        stripped = strip_messaging_components_only(layout_doc)
        print(f"      Anchor fallback: stripped {stripped} existing chat-icon component(s) from layout.")
    sibling_list = find_footer_logo_section_parent(layout_doc)
    if sibling_list is None:
        raise RuntimeError("Anchor fallback failed: no community_layout:section with "
                           "scopedBrandingSetId='B2B_Footer'. Logo step must run first.")
    sibling_list.append(build_chat_icon_section(scrt_url, site_endpoint))
    print(f"      Inserted chat icon (anchor fallback) "
          f"pointing at deploymentName='ESA_Web_Deployment', siteEndpoint={site_endpoint}.")
    return "AnchorFallback"


def strip_stale_chat_icons_from_views(bundle_root: Path) -> list[Path]:
    """Walk every content.json under the bundle EXCEPT commerceLayout, strip
    any chat-icon component nodes, return list of modified paths."""
    modified: list[Path] = []
    for content_file in bundle_root.rglob("content.json"):
        rel_parts = content_file.relative_to(bundle_root).parts
        if (len(rel_parts) >= 2
                and rel_parts[0] == "sfdc_cms__themeLayout"
                and rel_parts[1] == "commerceLayout"):
            continue
        try:
            doc = json.loads(content_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if not has_embedded_messaging(doc):
            continue
        if strip_messaging_components_only(doc) > 0:
            content_file.write_text(json.dumps(doc, indent=2), encoding="utf-8")
            modified.append(content_file)
    return modified


# ---------------------------------------------------------------------------
# Deploy + publish (single round trip)
# ---------------------------------------------------------------------------

def stage_deploy_project(bundle_root: Path, modified_files: list[Path], scratch: Path) -> tuple[Path, list[Path]]:
    """Build a self-contained SFDX project containing all modified files and
    their sibling _meta.json + mobile/ + tablet/ companions. Returns
    (deploy_root, list_of_source_dirs_to_pass_via_--source-dir)."""
    deploy_root = scratch / f"sfdx-deploy-{uuid.uuid4().hex[:8]}"
    bundle_name = bundle_root.name
    pkg_root = deploy_root / "force-app" / "main" / "default"
    target_site_dir = pkg_root / "digitalExperiences" / "site" / bundle_name
    target_site_dir.mkdir(parents=True, exist_ok=True)
    (deploy_root / "sfdx-project.json").write_text(json.dumps({
        "packageDirectories": [{"path": "force-app", "default": True}],
        "name": "site-branding-deploy",
        "namespace": "",
        "sfdcLoginUrl": "https://login.salesforce.com",
        "sourceApiVersion": "62.0",
    }, indent=2), encoding="utf-8")

    for src_name in (f"{bundle_name}.digitalExperience-meta.xml", f"{bundle_name}.digitalExperience"):
        src_bundle = bundle_root / src_name
        if src_bundle.exists():
            shutil.copy2(src_bundle, target_site_dir / f"{bundle_name}.digitalExperience-meta.xml")
            break
    src_bundle_meta = bundle_root / "_meta.json"
    if src_bundle_meta.exists():
        shutil.copy2(src_bundle_meta, target_site_dir / "_meta.json")

    deploy_targets: list[Path] = []
    seen_components: set[Path] = set()
    for content_file in modified_files:
        component_dir = content_file.parent
        if component_dir in seen_components:
            continue
        seen_components.add(component_dir)
        rel = content_file.relative_to(bundle_root)
        target_component_dir = target_site_dir / rel.parent
        target_component_dir.mkdir(parents=True, exist_ok=True)
        for child in component_dir.iterdir():
            dest = target_component_dir / child.name
            if child.is_dir():
                if dest.exists():
                    shutil.rmtree(dest)
                shutil.copytree(child, dest)
            else:
                shutil.copy2(child, dest)
        deploy_targets.append(target_component_dir)

    return deploy_root, deploy_targets


def deploy_and_publish(org_alias: str, site_name: str, deploy_root: Path,
                       deploy_targets: list[Path]) -> tuple[str, str]:
    print(f"[6] Deploying {len(deploy_targets)} component folder(s)...", flush=True)
    cmd = [
        SF_CLI, "project", "deploy", "start",
        "--target-org", org_alias,
        "--ignore-conflicts",
        "--wait", "30",
        "--json",
    ]
    for t in deploy_targets:
        cmd.extend(["--source-dir", str(t)])
    print(f"  $ {' '.join(cmd)} (cwd={deploy_root})", flush=True)
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(deploy_root))
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Deploy returned non-JSON: {proc.stdout[:500]} | stderr: {proc.stderr[:500]}")
    result = data.get("result") or {}
    deploy_id = result.get("id", "n/a")
    status = result.get("status", "Unknown")
    print(f"      Deploy id: {deploy_id} | status: {status}")
    failures = (result.get("details") or {}).get("componentFailures") or []
    for f in failures:
        print(f"        FAIL: {f.get('componentType')} | {f.get('fullName')} | {f.get('problem')}")
    if status != "Succeeded":
        raise RuntimeError(f"Deploy failed: {data.get('message') or status}")

    print(f"[7] Publishing community '{site_name}'...", flush=True)
    pub = sf_json(["community", "publish", "--target-org", org_alias, "--name", site_name])
    pub_result = pub.get("result") or {}
    publish_id = pub_result.get("id") or pub_result.get("jobId") or "n/a"
    print(f"      Publish job id: {publish_id}")
    return deploy_id, publish_id


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def verify_all(org_alias: str, site_name: str, verify_dir: Path,
               expected_logo_key: str, expected_banner_keys: list[str],
               expect_chat_icon: bool,
               expected_scrt_url: str = "",
               expected_site_endpoint: str = "") -> tuple[bool, list[str]]:
    """Re-retrieve the bundle and confirm every requested change landed.
    Returns (all_ok, list_of_problems)."""
    print(f"[8] Verifying live state by re-retrieving the bundle...", flush=True)
    if verify_dir.exists():
        shutil.rmtree(verify_dir, ignore_errors=True)
    layout_file = retrieve_bundle(org_alias, site_name, verify_dir)
    bundle_root = find_bundle_root(layout_file)
    layout_text = layout_file.read_text(encoding="utf-8")

    problems: list[str] = []

    if expected_logo_key:
        # Logo appears in header storeLogo region + footer col1 region = >=2 occurrences
        count = layout_text.count(expected_logo_key)
        print(f"      Logo contentKey '{expected_logo_key}' in commerceLayout: {count} occurrence(s) (expect >=2)")
        if count < 2:
            problems.append(f"logo contentKey appears {count} time(s), expected >=2")

    if expected_banner_keys:
        home = find_home_view(bundle_root)
        if not home:
            problems.append("home view content.json not present in bundle")
        else:
            home_text = home.read_text(encoding="utf-8")
            for i, key in enumerate(expected_banner_keys):
                count = home_text.count(key)
                print(f"      Banner[{i}] contentKey '{key}' in home view: {count} occurrence(s) (expect >=1)")
                if count < 1:
                    problems.append(f"banner[{i}] contentKey '{key}' missing from home view")

    if expect_chat_icon:
        if '"experience_messaging:embeddedMessaging"' not in layout_text:
            problems.append("chat icon missing from commerceLayout")
        else:
            print(f"      Chat icon present in commerceLayout footer: YES")

        # Verify the icon's attributes match the runtime values - a foreign-org
        # icon is worse than no icon (renders but won't connect).
        if expected_scrt_url and expected_site_endpoint:
            try:
                layout_doc = json.loads(layout_text)
            except json.JSONDecodeError:
                problems.append("commerceLayout content.json is not valid JSON in verify retrieve")
            else:
                comps = find_messaging_components(layout_doc)
                bad: list[str] = []
                for comp in comps:
                    attrs = comp.get("attributes") or {}
                    if attrs.get("scrtUrl") != expected_scrt_url:
                        bad.append(f"scrtUrl='{attrs.get('scrtUrl')}'")
                    if attrs.get("siteEndpoint") != expected_site_endpoint:
                        bad.append(f"siteEndpoint='{attrs.get('siteEndpoint')}'")
                    if attrs.get("deploymentName") != "ESA_Web_Deployment":
                        bad.append(f"deploymentName='{attrs.get('deploymentName')}'")
                if bad:
                    problems.append(f"chat icon attrs do NOT match runtime ESA Web Deployment: {bad}")
                else:
                    print(f"      Chat icon attrs match runtime ESA Web Deployment: YES")

        # Ensure no stragglers anywhere else
        stragglers: list[str] = []
        for content_file in bundle_root.rglob("content.json"):
            rel_parts = content_file.relative_to(bundle_root).parts
            if (len(rel_parts) >= 2
                    and rel_parts[0] == "sfdc_cms__themeLayout"
                    and rel_parts[1] == "commerceLayout"):
                continue
            try:
                t = content_file.read_text(encoding="utf-8")
            except OSError:
                continue
            if '"experience_messaging:embeddedMessaging"' in t:
                stragglers.append(str(content_file.relative_to(bundle_root)))
        print(f"      Chat-icon stragglers outside footer: {len(stragglers)}"
              + (f" -> {stragglers}" if stragglers else ""))
        if stragglers:
            problems.append(f"chat icon found in {len(stragglers)} non-footer file(s): {stragglers}")

    return (not problems), problems


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def edit_bundle(bundle_root: Path, layout_file: Path, scope: dict) -> tuple[list[Path], dict]:
    """Apply all in-scope edits in memory to retrieved files. Writes back to
    disk for any file modified. Returns (modified_files, edit_summary)."""
    modified_files: list[Path] = []
    summary = {"logo": 0, "banners": 0, "chat_icon_state": "Skipped",
               "stale_views_stripped": 0}

    layout_doc = json.loads(layout_file.read_text(encoding="utf-8"))
    layout_changed = False

    if scope.get("logo_key"):
        n = update_logo_components(layout_doc, scope["logo_key"])
        summary["logo"] = n
        if n > 0:
            layout_changed = True
        print(f"      Logo: updated {n} dxp_content_layout:siteLogo component(s)")

    if scope.get("with_chat_icon"):
        # Strip stale chat icons from non-layout files first
        stripped = strip_stale_chat_icons_from_views(bundle_root)
        for f in stripped:
            modified_files.append(f)
        summary["stale_views_stripped"] = len(stripped)
        print(f"      Chat icon: stripped {len(stripped)} stale non-footer placement(s)")
        # Insert / refresh in commerceLayout footer
        state = insert_chat_icon_into_layout(layout_doc, scope["scrt_url"],
                                             scope["site_endpoint"],
                                             force_reinsert=scope.get("force_reinsert", False))
        summary["chat_icon_state"] = state
        if state != "NoChange":
            layout_changed = True
        print(f"      Chat icon: footer state = {state}")

    if layout_changed:
        layout_file.write_text(json.dumps(layout_doc, indent=2), encoding="utf-8")
        modified_files.append(layout_file)

    if scope.get("banner_keys"):
        home = find_home_view(bundle_root)
        if home:
            home_doc = json.loads(home.read_text(encoding="utf-8"))
            n = update_banner_components(home_doc, scope["banner_keys"])
            summary["banners"] = n
            if n > 0:
                home.write_text(json.dumps(home_doc, indent=2), encoding="utf-8")
                if home not in modified_files:
                    modified_files.append(home)
            print(f"      Banners: updated {n} dxp_content_layout:banner component(s) on home view")
        else:
            print(f"      WARN: home view content.json not present - skipping banners")

    return modified_files, summary


def run_pipeline(args) -> int:
    instance, token = get_org_session(args.org_alias)

    image_type = args.image_type
    do_logo = image_type in ("all", "logo", "logo_banners", "logo_only")
    do_banners = image_type in ("all", "banners", "logo_banners", "banners_only")
    do_chat_icon = image_type in ("all", "chat_icon")

    keys: dict[str, str] = {}
    if do_logo or do_banners:
        names = []
        if do_logo:
            names.append("plusesynclogo")
        if do_banners:
            names.extend(["healthcloudbanner", "pulsesyncbanner2", "pulsesyncbanner1"])
        keys = fetch_content_keys(instance, token, args.org_alias, names)

    scrt_url = ""
    site_endpoint = ""
    esa_id = ""
    if do_chat_icon:
        esa_id, scrt_url, site_endpoint = verify_esa_prerequisites(instance, token, args.org_alias)

    scratch = scratch_root()
    if scratch.exists():
        shutil.rmtree(scratch, ignore_errors=True)
    work_dir = scratch / "work"
    print(f"[4] Scratch root: {scratch}", flush=True)

    layout_file = retrieve_bundle(args.org_alias, args.site_name, work_dir)
    bundle_root = find_bundle_root(layout_file)
    print(f"      Bundle root: {bundle_root}", flush=True)

    scope = {
        "logo_key": keys.get("plusesynclogo") if do_logo else "",
        # Order: [banner_main (banner[0]), banner_left (banner[1]), banner_right (banner[2])]
        "banner_keys": ([keys["healthcloudbanner"], keys["pulsesyncbanner2"], keys["pulsesyncbanner1"]]
                        if do_banners else []),
        "with_chat_icon": do_chat_icon,
        "scrt_url": scrt_url,
        "site_endpoint": site_endpoint,
        "force_reinsert": args.force_reinsert,
    }

    print(f"[5] Editing retrieved bundle in place...", flush=True)
    modified_files, summary = edit_bundle(bundle_root, layout_file, scope)

    if not modified_files:
        print(f"[5] No changes needed - live state already matches desired state.", flush=True)
        print(f"      Skipping deploy + publish (idempotent no-op).")
        deploy_id = "skipped (NoChange)"
        publish_id = "skipped (NoChange)"
    else:
        print(f"      {len(modified_files)} file(s) modified - staging deploy", flush=True)
        deploy_root, deploy_targets = stage_deploy_project(bundle_root, modified_files, scratch)
        deploy_id, publish_id = deploy_and_publish(args.org_alias, args.site_name,
                                                   deploy_root, deploy_targets)

    # Verify - retry once on partial failure
    verify_dir = scratch / "verify"
    expected_logo = keys.get("plusesynclogo", "") if do_logo else ""
    expected_banners = ([keys["healthcloudbanner"], keys["pulsesyncbanner2"], keys["pulsesyncbanner1"]]
                        if do_banners else [])
    ok, problems = verify_all(args.org_alias, args.site_name, verify_dir,
                              expected_logo, expected_banners, do_chat_icon,
                              expected_scrt_url=scrt_url, expected_site_endpoint=site_endpoint)

    if not ok and modified_files:
        print(f"[8b] Verification reported {len(problems)} problem(s); retrying deploy + publish once...", flush=True)
        for p in problems:
            print(f"      - {p}")
        # Re-stage from the same edited working copy and redeploy
        retry_root, retry_targets = stage_deploy_project(bundle_root, modified_files, scratch)
        deploy_id_retry, publish_id_retry = deploy_and_publish(args.org_alias, args.site_name,
                                                               retry_root, retry_targets)
        deploy_id = f"{deploy_id} -> retry {deploy_id_retry}"
        publish_id = f"{publish_id} -> retry {publish_id_retry}"
        verify_dir = scratch / "verify-retry"
        ok, problems = verify_all(args.org_alias, args.site_name, verify_dir,
                                  expected_logo, expected_banners, do_chat_icon,
                                  expected_scrt_url=scrt_url, expected_site_endpoint=site_endpoint)

    if not ok:
        print(f"\nFAIL: {len(problems)} verification issue(s) remain after retry. "
              f"Scratch preserved at {scratch}", flush=True)
        for p in problems:
            print(f"  - {p}")
        return 1

    if not args.keep_scratch:
        shutil.rmtree(scratch, ignore_errors=True)

    print()
    print("=" * 78)
    print("SUCCESS - site branding configured (one retrieve + one deploy + one publish).")
    print(f"  Org:                       {args.org_alias}")
    print(f"  Site:                      {args.site_name}")
    print(f"  Image type:                {image_type}")
    if do_logo:
        print(f"  Logo components updated:   {summary['logo']}")
    if do_banners:
        print(f"  Banner components updated: {summary['banners']}")
    if do_chat_icon:
        print(f"  Chat icon state:           {summary['chat_icon_state']}")
        print(f"  Stale views stripped:      {summary['stale_views_stripped']}")
        print(f"  EmbeddedServiceConfig Id:  {esa_id}")
        print(f"  scrtUrl:                   {scrt_url}")
        print(f"  siteEndpoint:              {site_endpoint}")
    print(f"  Deploy id:                 {deploy_id}")
    print(f"  Publish job id:            {publish_id}")
    print("=" * 78)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Configure all site branding (logo + banners + chat icon) "
                    "in one retrieve + one deploy + one publish."
    )
    parser.add_argument("--org-alias", required=True)
    parser.add_argument("--site-name", default="PulseSync")
    parser.add_argument("--image-type", default="all",
                        choices=["all", "logo", "banners", "logo_banners", "chat_icon"],
                        help="Scope of changes (default: all)")
    parser.add_argument("--force-reinsert", action="store_true",
                        help="When updating chat icon, strip existing footer placement "
                             "and re-insert with current runtime URLs")
    parser.add_argument("--keep-scratch", action="store_true")
    args = parser.parse_args()

    print("=" * 78)
    print(f"Site Branding Configuration (consolidated)")
    print(f"  Org alias: {args.org_alias}")
    print(f"  Site:      {args.site_name}")
    print(f"  Scope:     {args.image_type}")
    print(f"  SF CLI:    {SF_CLI}")
    print("=" * 78)

    try:
        return run_pipeline(args)
    except subprocess.CalledProcessError as e:
        print(f"\nFATAL: subprocess failed (rc={e.returncode}): {e.stderr or e.stdout}", file=sys.stderr)
        return 1
    except RuntimeError as e:
        print(f"\nFATAL: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
