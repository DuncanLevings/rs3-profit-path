"""Run the isolated Lua 5.4 tests and check repository file policy."""
# One command to check everything: `python tools/test.py`. It stops at the first
# failure. In order:
#   1. repo policy: only README.md and CHANGELOG.md are allowed as Markdown
#   2. the manifest still asks for no permissions or URLs
#   3. every Lua file parses, then the Lua behavior tests run (tests/run.lua)
#   4. generated data matches its sources, then the Python tests run
# The Lua tests use fake client/PrettyUI objects. They don't replace in-game testing.
from pathlib import Path
import json
import os
import subprocess
import sys
import unittest

from lupa.lua54 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

# Ask git which files belong to the repo (tracked plus new, minus ignored), so local
# scratch files don't trip the policy checks.
listed = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode("utf-8")

files = [Path(name) for name in listed.split("\0") if name]

for relative in files:
    if relative.suffix.lower() == ".md" and relative.as_posix() not in {"README.md", "CHANGELOG.md"}:
        raise SystemExit(f"Disallowed Markdown file: {relative}")

# Requesting a permission or URL is a big deal for review, so make adding one a
# deliberate change that also means updating this check.
manifest = json.loads((ROOT / "plugin.json").read_text(encoding="utf-8"))

assert manifest["requiredPermissions"] == []
assert manifest["optionalPermissions"] == []
assert manifest["urls"] == {}

# The client runs Lua 5.4, so make sure the embedded runtime is 5.4 as well.
lua = LuaRuntime(unpack_returned_tuples=True)
assert lua.eval("_VERSION") == "Lua 5.4"

for relative in files:
    if relative.suffix == ".lua":
        lua.execute("assert(load(...))", (ROOT / relative).read_text(encoding="utf-8"))

lua.execute((ROOT / "tests" / "run.lua").read_text(encoding="utf-8"))

print("Lua 5.4 syntax, manifest, and repository Markdown policy passed.")

sys.path.insert(0, str(ROOT / "tools"))
import catalogue

# monsters.json is about 12 MB, so read it once and share it between both checks.
monsters = json.loads(catalogue.SOURCE.read_text(encoding="utf-8"))

catalogue.verify(monsters)
catalogue.verify_methods(monsters)

suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), pattern="test_*.py")

if not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful():
    raise SystemExit(1)
