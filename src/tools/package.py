"""Build the plugin's release zip and check an installed copy against it."""
# What this file does: picks out the files the game actually loads (the runtime
# files), zips them into dist/, and compares an install folder with them.
#
#   python src/tools/package.py build                 # writes dist/profit-path-<version>.zip
#   python src/tools/package.py check-install PATH    # SHA-256 compare, repo vs install
#
# Runtime files are: main.lua, plugin.json, CHANGELOG.md, THIRD_PARTY_NOTICES.txt,
# data/*.lua and every Lua file under src/ except src/tests/ and src/tools/.
# Tests, build tools, catalogue sources and README.md never ship.
#
# Nothing here contacts the network or the game, and check-install only reads the
# install folder; it never changes it.
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[2]

# These sit at the top of the plugin folder and always ship.
TOP_LEVEL = ("main.lua", "plugin.json", "CHANGELOG.md", "THIRD_PARTY_NOTICES.txt")

# Development-only folders under src/. Anything in here is for us, not the game.
DEV_ONLY = ("src/tests/", "src/tools/")

# Zip entries get a fixed date so building the same files twice gives the same
# bytes (and the same SHA-256). 1980-01-01 is the earliest date a zip can hold.
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def repo_files(root=ROOT):
    """Every file git knows about (tracked plus new, minus ignored), as posix paths.

    Asking git rather than walking the folder means stray local files (scratch
    notes, __pycache__, a half-written experiment) can never end up in a release.
    """
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    ).stdout.decode("utf-8")

    # A moved file can stay in git's list until it's staged, so keep only the
    # paths that really exist right now.
    return sorted(name for name in listed.split("\0") if name and (root / name).is_file())


def is_runtime(path):
    """True when the game loads this file (see the list at the top of this file)."""
    if path in TOP_LEVEL:
        return True

    # Generated data modules: methods, monsters, recipes, icons.
    if path.startswith("data/") and path.endswith(".lua") and path.count("/") == 1:
        return True

    # Plugin code under src/, but never the tests or the build tools.
    if path.startswith("src/") and path.endswith(".lua"):
        return not path.startswith(DEV_ONLY)

    return False


def runtime_files(root=ROOT):
    """The sorted list of files that make up the plugin the game loads."""
    files = [path for path in repo_files(root) if is_runtime(path)]

    # A release without one of the top-level files is broken, so say which one.
    missing = [name for name in TOP_LEVEL if name not in files]

    if missing:
        raise SystemExit(f"Missing runtime file(s): {', '.join(missing)}")

    return files


def release_problems(manifest):
    """Things in plugin.json that are fine for development but block a submission.

    The zip is still built either way: it's also what gets installed for testing.
    This just makes the remaining release work visible instead of easy to forget.
    """
    problems = []

    if "-dev" in str(manifest.get("version", "")):
        problems.append(f"version {manifest.get('version')} is a development version")

    # The manifest docs (developer.runescape.com/rs/structure.html) call the
    # contact address a legal requirement. A rough shape check only: it catches
    # a missing or blank field, not a mistyped address.
    email = manifest.get("contactEmailAddress")

    if not isinstance(email, str) or "@" not in email.strip(" @"):
        problems.append("contactEmailAddress is missing")

    # A dependency given as a folder name (rather than a Plugin Hub ID number)
    # only works with that plugin sitting in dev_plugins on this computer.
    for name, value in sorted(manifest.get("requiredDependencies", {}).items()):
        if not isinstance(value, int):
            problems.append(f"dependency '{name}' points at a development folder ({value!r}), not a Plugin Hub ID")

    return problems


def sha256(path):
    """SHA-256 of a file, as hex."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(root=ROOT, out_dir=None):
    """Write dist/profit-path-<version>.zip and return its path.

    Files sit at the top of the zip (main.lua, src/..., data/...), the same layout
    as the install folder, so unzipping into dev_plugins/profit-path just works.
    """
    manifest = json.loads((root / "plugin.json").read_text(encoding="utf-8"))
    out_dir = Path(out_dir) if out_dir else root / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / f"profit-path-{manifest['version']}.zip"

    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in runtime_files(root):
            # Fixed date and permissions, so the zip only changes when a file does.
            entry = zipfile.ZipInfo(path, date_time=FIXED_DATE)
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            archive.writestr(entry, (root / path).read_bytes())

    return target


def compare_install(install, root=ROOT):
    """Compare an install folder with the repo's runtime files.

    Returns (different, missing, extra): lists of posix paths. All three empty
    means the install is exactly what a release from this repo would contain.
    """
    install = Path(install)
    expected = runtime_files(root)
    different, missing = [], []

    for path in expected:
        installed = install / path

        if not installed.is_file():
            missing.append(path)
            continue

        if sha256(installed) != sha256(root / path):
            different.append(path)

    # Extra files would ship along with ours (e.g. a test left behind), so list them.
    # The install folder may be its own git checkout; its .git isn't plugin content.
    present = sorted(
        item.relative_to(install).as_posix()
        for item in install.rglob("*")
        if item.is_file() and ".git" not in item.relative_to(install).parts
    )
    extra = [path for path in present if path not in expected]

    return different, missing, extra


def main(argv):
    if len(argv) == 1 and argv[0] == "build":
        target = build()
        manifest = json.loads((ROOT / "plugin.json").read_text(encoding="utf-8"))

        print(f"Wrote {target.relative_to(ROOT)} ({len(runtime_files())} files)")
        print(f"SHA-256 {sha256(target)}")

        # Not an error: development builds are packaged too. Just don't submit one.
        for problem in release_problems(manifest):
            print(f"Not ready for submission: {problem}")

        return 0

    if len(argv) == 2 and argv[0] == "check-install":
        different, missing, extra = compare_install(argv[1])

        for label, paths in (("Different", different), ("Missing", missing), ("Extra", extra)):
            for path in paths:
                print(f"{label}: {path}")

        if different or missing or extra:
            return 1

        print(f"Install matches the repo ({len(runtime_files())} runtime files, SHA-256 checked).")
        return 0

    print(__doc__)
    print("Usage: package.py build | package.py check-install PATH")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
