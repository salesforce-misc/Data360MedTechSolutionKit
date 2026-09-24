#!/usr/bin/env python3
"""Permanent S3 uploader helper for the notebook-ai skill (see Step 4d).

Fixed-shape invocation — the manifest path is the ONLY argument:

    python3 scripts/notebook-ai-s3-put.py "<manifest-path>"

Manifest schema (JSON at <manifest-path>):

    {
      "libraryId": "1aQ...",
      "sourceDir": "MedTechDocuments",
      "files": [
        { "name": "doc.pdf", "url": "https://... (may contain &amp;)" }
      ]
    }

Per-file behavior:
- `.replace("&amp;", "&")` on the URL (Gotcha A: without this S3 returns
  `403 AccessDenied: No AWSAccessKey was presented`).
- Read raw bytes from `<sourceDir>/<name>`.
- PUT with NO extra headers, including no Content-Type (Gotcha B: any
  extra header breaks the S3 v4 signature — `403 SignatureDoesNotMatch`).
- Bounded per-file network timeout (60s).
- Emit one line per file: `<http_status>\\t<name>\\t<error-or-blank>`.

Exit code: `0` iff every PUT returned HTTP 200; non-zero otherwise.

Presigned URLs must NEVER be embedded in `Bash` command strings, heredocs,
or generated source — see SKILL.md Step 4c and the "Manifest lifecycle"
section of Step 4d. The manifest and its tmpdir are the caller's to
clean up according to the manifest-lifecycle rules in Step 4d.
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


def put_one(name: str, url: str, sd: str, timeout: int):
    path = os.path.join(sd, name)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return (0, name, f"read-error: {e}")

    url_clean = url.replace("&amp;", "&")
    req = urllib.request.Request(url_clean, data=data, method="PUT")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return (resp.status, name, "")
    except urllib.error.HTTPError as e:
        body_snippet = ""
        try:
            body_snippet = e.read()[:200].decode("utf-8", "replace")
        except Exception:
            pass
        return (e.code, name, f"HTTPError: {body_snippet}")
    except Exception as e:
        return (0, name, f"exception: {type(e).__name__}: {e}")


def main(manifest_path: str) -> int:
    with open(manifest_path, "r", encoding="utf-8") as f:
        m = json.load(f)

    sd = m["sourceDir"]
    files = m["files"]

    results = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        futs = {pool.submit(put_one, e["name"], e["url"], sd, 60): e["name"] for e in files}
        for fut in as_completed(futs):
            results.append(fut.result())

    results.sort(key=lambda r: r[1])
    ok = True
    for status, name, err in results:
        print(f"{status}\t{name}\t{err}")
        if status != 200:
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: notebook-ai-s3-put.py <manifest.json>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
