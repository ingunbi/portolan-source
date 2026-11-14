#!/usr/bin/env python3
"""Audit Git source candidates only; never traverse an ignored game-data folder."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ICON_HASHES = {
    "ipad/ios/Sources/Assets.xcassets/AppIcon.appiconset/icon.png": "15c8708d0e6727b5f7bed4fe87487678501a921b296a09b25a202e2a7ee9a99f",
    "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": "0aabaf9d182814013778a06803f1a69853e9468e5a2c2a9933e399d04ed9b253",
}
TEXT_SUFFIXES = {".swift", ".py", ".sh", ".md", ".kt", ".kts", ".xml", ".json", ".properties", ".yml", ".yaml", ".toml"}
TEXT_NAMES = {"LICENSE", ".gitignore", ".env.example"}
PRIVATE_PARTS = {"original", "assets", "fixtures", "saves", "private", "build", ".build", ".venv", "jniLibs", "xcuserdata", "reports"}


def audit(root=ROOT):
    output = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    paths = sorted({p.decode() for p in output.split(b"\0") if p})
    errors = []
    for name in paths:
        p = root / name
        if not p.exists() and not p.is_symlink():
            errors.append({"path": name, "reason": "tracked file missing"})
            continue
        if p.is_symlink() or any(part in PRIVATE_PARTS for part in p.relative_to(root).parts):
            errors.append({"path": name, "reason": "private path or symlink"})
            continue
        data = p.read_bytes()
        if name in ICON_HASHES:
            if hashlib.sha256(data).hexdigest() != ICON_HASHES[name]:
                errors.append({"path": name, "reason": "icon changed: review original-art provenance"})
            continue
        if p.name not in TEXT_NAMES and p.suffix not in TEXT_SUFFIXES:
            errors.append({"path": name, "reason": "outside text source allowlist"})
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            errors.append({"path": name, "reason": "non-text payload"})
            continue
        if len(data) > 512 * 1024:
            errors.append({"path": name, "reason": "large text payload needs review"})
        # Report filenames, never matched values. This complements a secret scanner.
        if re.search(r"/Users" + r"/[^/\s]+/|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}", text):
            errors.append({"path": name, "reason": "operator path or key-like material"})
    return {"passed": not errors, "files": len(paths), "errors": errors,
            "limits": "File-boundary checks cannot establish copyright provenance or original-game parity."}


if __name__ == "__main__":
    result = audit()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result["passed"] else 1)
