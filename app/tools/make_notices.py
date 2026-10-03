"""Write THIRD_PARTY_NOTICES.txt: every third-party component the app ships, with its licence text.

    python tools/make_notices.py <runtime dir> <python-build-standalone licenses dir> <Peekaboo checkout> <out file>

Collected, not hand-written, so a new dependency cannot be shipped without its notice:
  - CPython and the libraries python-build-standalone links into it (OpenSSL, SQLite, zlib, ...): the licence files
    of the matching "full" release, which the install-only build the runtime is copied from leaves out;
  - every Python distribution in the runtime's site/, site-brain/ and site-eyes/ (from its .dist-info);
  - Peekaboo and the Swift packages statically linked into its binary (its submodules and SwiftPM checkouts);
  - the base models the release models are fine-tuned from.
A component with no licence file stops the build: shipping it without one is the mistake this exists to prevent.
"""
import email
import sys
from pathlib import Path

runtime, pbs, peekaboo, out = (Path(a) for a in sys.argv[1:5])
LICENSE_NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE")
sections: list[tuple[str, str, list[Path]]] = []   # (title, licence summary, files)
missing: list[str] = []


def licence_files(d: Path) -> list[Path]:
    found = [p for p in sorted(d.rglob("*")) if p.is_file() and p.name.upper().startswith(LICENSE_NAMES)]
    return found


# 1. CPython and what is linked into it.
py_files = sorted(pbs.glob("LICENSE.*.txt"))
if not py_files:
    missing.append("python-build-standalone licenses")
sections.append(("CPython 3.12 (python-build-standalone) and the libraries built into it",
                 "Python-2.0 (PSF) for CPython; each bundled library under its own licence, below",
                 py_files))

# 2. Python distributions.
seen: set[tuple[str, str]] = set()
for site in ("site", "site-brain", "site-eyes"):
    for di in sorted((runtime / site).glob("*.dist-info")):
        meta = email.message_from_string((di / "METADATA").read_text(errors="replace"))
        name, version = meta["Name"], meta["Version"]
        if (name.lower(), version) in seen:
            continue   # installed in more than one site dir (Pillow, numpy, ...)
        seen.add((name.lower(), version))
        if name.lower().startswith("deskmind"):
            continue   # our own code, under the app's own licence
        lic = meta.get("License-Expression") or meta.get("License") or ""
        if not lic or len(lic) > 80:
            lic = "; ".join(c.split(" :: ")[-1] for c in meta.get_all("Classifier") or [] if c.startswith("License"))
        files = licence_files(di)
        if not files:
            # A few wheels ship without their licence file; the upstream text is kept in tools/licenses-extra/<name>.
            extra = Path(__file__).parent / "licenses-extra" / name.lower()
            files = licence_files(extra) if extra.is_dir() else []
        if not files:
            missing.append(f"{name} {version}")
        sections.append((f"{name} {version} (Python package)", lic or "see licence text", files))

# 3. Peekaboo and its Swift dependencies.
pk_files = [peekaboo / "LICENSE"]
sections.append(("Peekaboo (macOS automation CLI)", "MIT", pk_files))
for sub in ("AXorcist", "Commander", "Swiftdansi", "Tachikoma", "TauTUI"):
    files = licence_files(peekaboo / sub) if (peekaboo / sub).is_dir() else []
    files = [f for f in files if f.parent == peekaboo / sub]
    if not files:
        missing.append(f"Peekaboo/{sub}")
    sections.append((f"{sub} (part of Peekaboo)", "see licence text", files))
checkouts = peekaboo / "Apps" / "CLI" / ".build" / "checkouts"
for d in sorted(p for p in checkouts.iterdir() if p.is_dir()):
    files = [f for f in sorted(d.iterdir()) if f.is_file() and f.name.upper().startswith(LICENSE_NAMES)]
    if not files:
        missing.append(f"Swift package {d.name}")
    sections.append((f"{d.name} (Swift package, linked into Peekaboo)", "see licence text", files))

# 4. The Swift back-deployment library shipped next to Peekaboo when its binary needs it (see runtime.sh).
if (runtime / "bin" / "libswiftCompatibilitySpan.dylib").exists():
    sections.append(("libswiftCompatibilitySpan.dylib (Swift runtime back-deployment library, Apple)",
                     "Apache-2.0 with Runtime Library Exception; attribution not required, listed for completeness",
                     []))

if missing:
    sys.exit("no licence file for: " + ", ".join(missing))

lines = [
    "DeskMind for Mac -- third-party notices",
    "",
    "DeskMind ships the components below. Each is used under its own licence, reproduced in full.",
    "",
    "Models: DeskMind Brain (deskmind/brain-0.8b, deskmind/brain-4b, downloaded on first use) are fine-tuned from",
    "Qwen3.5-0.8B and Qwen3.5-4B by the Qwen team, Alibaba Cloud, released under the Apache License 2.0.",
    "DeskMind Eyes (deskmind/eyes-4b, the vision model, downloaded only when a task needs it) is fine-tuned from",
    "GUI-Owl-1.5-4B by the X-PLUG team, Alibaba (MIT License), itself built on Qwen3-VL by the Qwen team, Alibaba",
    "Cloud (Apache License 2.0).",
    "",
    "Contents:",
]
lines += [f"  - {t} -- {s}" for t, s, _ in sections]
for title, summary, files in sections:
    lines += ["", "=" * 100, title, f"Licence: {summary}", "=" * 100]
    for f in files:
        lines += ["", f"--- {f.name} ---", f.read_text(errors="replace").rstrip()]
out.write_text("\n".join(lines) + "\n")
print(f"{out}: {len(sections)} components, {out.stat().st_size // 1024} KB")
