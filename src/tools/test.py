"""Run the isolated Lua 5.4 tests and check repository file policy."""
# One command to check everything: `python src/tools/test.py`. It stops at the first
# failure. In order:
#   1. repo policy: only README.md and CHANGELOG.md are allowed as Markdown
#   2. the manifest still asks for no permissions or URLs
#   3. every Lua file parses, then the Lua behavior tests run (src/tests/run.lua)
#   4. generated data matches its sources, then the Python tests run
# The Lua tests use fake client/PrettyUI objects. They don't replace in-game testing.
from pathlib import Path
import json
import os
import subprocess
import sys
import unittest

from lupa.lua54 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)

# Ask git which files belong to the repo (tracked plus new, minus ignored), so local
# scratch files don't trip the policy checks.
listed = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode("utf-8")

# A moved tracked file stays in git's list until staging. Check files present in
# this working tree, including their new untracked paths, rather than old paths.
files = [Path(name) for name in listed.split("\0") if name and (ROOT / name).is_file()]

for relative in files:
    if relative.suffix.lower() == ".md" and relative.as_posix() not in {"README.md", "CHANGELOG.md"}:
        raise SystemExit(f"Disallowed Markdown file: {relative}")

# Requesting a permission or URL is a big deal for review, so make adding one a
# deliberate change that also means updating this check.
manifest = json.loads((ROOT / "plugin.json").read_text(encoding="utf-8"))

assert manifest["requiredPermissions"] == []
assert manifest["optionalPermissions"] == []
assert manifest["urls"] == {}
assert manifest["requiredDependencies"]["rsprite"] == "rsprite"

# The client runs Lua 5.4, so make sure the embedded runtime is 5.4 as well.
lua = LuaRuntime(unpack_returned_tuples=True)
assert lua.eval("_VERSION") == "Lua 5.4"

# Confirmed in the beta client: the standard utf8 global is not exposed. Keep
# behavior tests in that environment so ordinary desktop Lua can't mask its use.
lua.globals().utf8 = None

for relative in files:
    if relative.suffix == ".lua":
        lua.execute("assert(load(...))", (ROOT / relative).read_text(encoding="utf-8"))

sys.path.insert(0, str(ROOT / "src" / "tools"))
import catalogue

# The behaviour tests check what the plugin does with our 4 curated methods, whose
# numbers they know by heart. So they get a catalogue of just those, packed exactly
# like the shipped one. At the end, run.lua reloads everything with the real
# data/methods.lua for the full-catalogue tests (src/tests/catalogue_scale.lua).
curated = catalogue.pack_methods(catalogue.expand_methods(catalogue.load_method_source()))
lua.execute("package.loaded['data/methods'] = ...", lua.execute(curated))

lua.execute((ROOT / "src" / "tests" / "run.lua").read_text(encoding="utf-8"))

print("Lua 5.4 syntax, manifest, and repository Markdown policy passed.")

# monsters.json is about 12 MB, so read it once and share it between both checks.
monsters = json.loads(catalogue.SOURCE.read_text(encoding="utf-8"))

catalogue.verify(monsters)

# Recipes (creation costs for untradeable supplies) feed the method checks, so
# verify them first.
recipes = catalogue.load_recipes()

if recipes is not None:
    catalogue.verify_recipes(recipes)

catalogue.verify_methods(monsters, recipes)

# The Wiki guide snapshot (catalogue-source/wiki) isn't used by the plugin yet, but
# it must stay a clean, consistent import until it is.
import wiki_methods

print(f"Verified {wiki_methods.verify_snapshot()} Wiki guides in the snapshot.")

# Merged with our research, every imported guide must pass the same checks as a
# curated method. (The plugin still loads only the curated ones until step 4.)
import merge_methods

print(f"Verified {merge_methods.verify_merge(monsters, recipes)} merged methods (curated + Wiki).")

suite = unittest.defaultTestLoader.discover(str(ROOT / "src" / "tests"), pattern="test_*.py")

if not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful():
    raise SystemExit(1)
