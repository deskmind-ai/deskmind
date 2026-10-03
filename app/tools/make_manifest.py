"""Write Resources/models.json: every file of the release models, with its pinned download URL, size and SHA-256.

    python tools/make_manifest.py --name "deskmind-brain g14-q8" \
        --model fast deskmind/brain-0.8b 37695b26... <local dir> <local dir>.sha256 \
        --model strong deskmind/brain-4b eb08726e... <local dir> <local dir>.sha256

    python tools/make_manifest.py --keep --model eyes deskmind/eyes-4b de8e13bc... <local dir> <list>.sha256

    --mirror fast "https://www.modelscope.cn/models/gxcsoccer/brain-0.8b/resolve/g18b-q8/{path}"  (per role)
    --threshold 0.96

--keep leaves the models of the roles not given as they are in the existing manifest (and its name, unless --name
is given): a new Eyes release is added without the Brain models' local copies at hand, and the other way round.
Roles: fast and strong (DeskMind Brain, needed before anything runs) and eyes (the vision model, optional, fetched
only when a task needs it -- see ModelRole).
Sizes come from the local copy of the release; hashes from the release's .sha256 list (as published with the
upload). URLs are pinned to the HF revision, so a later push to the repo cannot change what the app installs.
"""
import argparse
import json
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--name")
ap.add_argument("--keep", action="store_true", help="keep the existing manifest's models of the roles not given")
ap.add_argument("--model", nargs=5, action="append", metavar=("ROLE", "REPO", "REV", "DIR", "SHA256_LIST"),
                required=True)
ap.add_argument("--mirror", nargs=2, action="append", default=[], metavar=("ROLE", "URL_TEMPLATE"),
                help="a second source for a role's files, \"{path}\" standing for the file's path: ModelScope, where "
                     "huggingface.co is slow or unreachable. The same bytes: the same SHA-256 checks them")
ap.add_argument("--threshold", type=float, help="the routing threshold the Brain pair was gated at")
ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "Resources" / "models.json"))
a = ap.parse_args()
old = json.loads(Path(a.out).read_text()) if a.keep and Path(a.out).exists() else {"models": []}
title = a.name or old.get("name")
if not title:
    ap.error("--name is required for a new manifest")

mirrors = dict(a.mirror)
models = []
for role, repo, rev, d, lst in a.model:
    hashes = dict(reversed(line.split(None, 1)) for line in Path(lst).read_text().splitlines() if line.strip())
    hashes = {k.strip(): v for k, v in hashes.items()}
    files = []
    for name, sha in sorted(hashes.items()):
        p = Path(d) / name
        files.append({"path": name, "url": f"https://huggingface.co/{repo}/resolve/{rev}/{name}",
                      **({"mirror": mirrors[role].replace("{path}", name)} if role in mirrors else {}),
                      "size": p.stat().st_size, "sha256": sha})
    models.append({"role": role, "name": f"{repo}@{rev[:12]}", "files": files})
given = {m["role"] for m in models}
order = {"fast": 0, "strong": 1, "eyes": 2}
models = sorted([m for m in old["models"] if m["role"] not in given] + models, key=lambda m: order.get(m["role"], 9))
out = {"name": title, "version": "-".join(m["name"].split("@")[1] for m in models), "models": models}
threshold = a.threshold if a.threshold is not None else old.get("threshold")
if threshold is not None:
    out["threshold"] = threshold
Path(a.out).write_text(json.dumps(out, indent=2) + "\n")
print(f"{a.out}: {sum(len(m['files']) for m in models)} files, "
      f"{sum(f['size'] for m in models for f in m['files']) / 1e9:.2f} GB")
