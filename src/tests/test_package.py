"""Tests for src/tools/package.py: what ships in a release and the install check."""
# These run against the real repository, because the point is that the real
# release contains the right files: runtime Lua and notices in, tests/tools/sources
# out. Zips and fake installs go in a temporary folder, never in dist/ or the game.
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

import package


class RuntimeFileTests(unittest.TestCase):
    def test_runtime_rule(self):
        # The game loads these...
        for path in ("main.lua", "plugin.json", "CHANGELOG.md", "THIRD_PARTY_NOTICES.txt",
                     "data/methods.lua", "src/main.lua", "src/ui/browse_view.lua"):
            self.assertTrue(package.is_runtime(path), path)

        # ...and never these: tests, tools, sources, docs, nested data folders.
        for path in ("README.md", "src/tests/run.lua", "src/tools/catalogue.py",
                     "src/tools/helper.lua", "catalogue-source/methods.json",
                     "data/extra/thing.lua", "requirements-dev.txt", ".gitignore"):
            self.assertFalse(package.is_runtime(path), path)

    def test_real_release_has_every_plugin_module(self):
        files = package.runtime_files()

        # Every Lua file under src/ outside tests/tools must ship, or the plugin
        # would fail to require it in game.
        source = sorted(
            path.relative_to(package.ROOT).as_posix()
            for path in (package.ROOT / "src").rglob("*.lua")
            if not path.relative_to(package.ROOT).as_posix().startswith(package.DEV_ONLY)
        )

        for path in source:
            self.assertIn(path, files)

        self.assertFalse([path for path in files if path.startswith(package.DEV_ONLY)])
        self.assertNotIn("README.md", files)


class ReleaseProblemTests(unittest.TestCase):
    def test_development_manifest_lists_its_blockers(self):
        problems = package.release_problems({
            "version": "0.8.26-dev",
            "requiredDependencies": {"prettyui": 6398181, "gepl": "gepl"},
        })

        self.assertEqual(len(problems), 2)
        self.assertIn("development version", problems[0])
        self.assertIn("'gepl'", problems[1])

    def test_release_manifest_has_none(self):
        problems = package.release_problems({
            "version": "1.0.0",
            "requiredDependencies": {"prettyui": 6398181, "gepl": 1234},
        })

        self.assertEqual(problems, [])


class BuildAndInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.temp)

    def test_build_is_repeatable_and_holds_only_runtime_files(self):
        first = package.build(out_dir=self.temp / "a")
        second = package.build(out_dir=self.temp / "b")

        # Same files in, same bytes out, so a release's SHA-256 means something.
        self.assertEqual(first.read_bytes(), second.read_bytes())

        with zipfile.ZipFile(first) as archive:
            self.assertEqual(sorted(archive.namelist()), package.runtime_files())

    def test_install_check_finds_changed_missing_and_extra_files(self):
        install = self.temp / "install"

        # Start from a perfect copy, plus a .git folder, which isn't plugin content.
        for path in package.runtime_files():
            target = install / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(package.ROOT / path, target)

        (install / ".git").mkdir()
        (install / ".git" / "HEAD").write_text("ref: refs/heads/main\n")

        self.assertEqual(package.compare_install(install), ([], [], []))

        # Now break it three ways.
        (install / "src" / "main.lua").write_bytes(b"-- edited in the install\n")
        (install / "data" / "icons.lua").unlink()
        (install / "src" / "tests").mkdir()
        (install / "src" / "tests" / "run.lua").write_text("-- left behind\n")

        different, missing, extra = package.compare_install(install)

        self.assertEqual(different, ["src/main.lua"])
        self.assertEqual(missing, ["data/icons.lua"])
        self.assertEqual(extra, ["src/tests/run.lua"])


if __name__ == "__main__":
    unittest.main()
