from pathlib import Path
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("source_audit", ROOT / "tools/audit_public_source.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class PublicBoundaryTests(unittest.TestCase):
    def test_force_added_original_data_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            p = root / "core/original/GAME/MAIN.EXE"
            p.parent.mkdir(parents=True)
            p.write_bytes(b"MZsynthetic")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            self.assertFalse(audit.audit(root)["passed"])

    def test_force_added_save_or_unknown_image_is_rejected(self):
        for name in ("saves/test.json", "screenshot.png"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b"synthetic")
                self.assertFalse(audit.audit(root)["passed"])

    def test_ipad_generation_excludes_data_by_default_and_locates_shared_core(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "ipad/ios"
            scripts.mkdir(parents=True)
            shutil.copy2(ROOT / "ipad/ios/make_project.py", scripts)
            env = dict(os.environ)
            for key in ("PORTOLAN_TEAM", "PORTOLAN_BUNDLE", "PORTOLAN_BUNDLE_PRIVATE_ASSETS"):
                env.pop(key, None)
            import sys
            subprocess.run([sys.executable, str(scripts / "make_project.py")], env=env, check=True, capture_output=True)
            p = scripts / "PortolanPad.xcodeproj/project.pbxproj"
            default = p.read_text()
            self.assertNotIn("path = ../../core/assets", default)
            self.assertNotIn("assets in Resources", default)
            self.assertIn('relativePath = "../../core"', default)
            subprocess.run([sys.executable, str(scripts / "make_project.py")], env={**env, "PORTOLAN_BUNDLE_PRIVATE_ASSETS": "1"}, check=True, capture_output=True)
            self.assertIn("path = ../../core/assets", p.read_text())


if __name__ == "__main__":
    unittest.main()
