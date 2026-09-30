"""Recent-minor release window, ported from pi-kit/scripts/pi-window.mjs."""

from datetime import datetime
from http.client import HTTPException
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


class WindowError(Exception):
    pass


def window(times: dict[str, float], now: float, days: int) -> list[str]:
    minors: dict[tuple[int, int], tuple[int, str, float]] = {}
    for version, published in times.items():
        match = SEMVER.fullmatch(version)
        if not match:
            continue
        major, minor, patch = map(int, match.groups())
        key = (major, minor)
        best_patch, best, first = minors.get(key, (patch, version, published))
        if patch > best_patch or (patch == best_patch and version < best):
            best_patch, best = patch, version
        minors[key] = (best_patch, best, min(first, published))

    ordered = [minors[key] for key in sorted(minors, reverse=True)]
    versions = [
        entry[1] for index, entry in enumerate(ordered)
        if index == 0 or now - ordered[index - 1][2] <= days * 86400
    ]
    if len(versions) < 2:
        raise WindowError(
            f"release window found {versions}; expected at least 2 versions; increase window-days"
        )
    return versions


def npm_url(name: str) -> str:
    return "https://registry.npmjs.org/" + name.replace("/", "%2f")


def npm_times(doc: dict) -> dict[str, float]:
    if not isinstance(doc, dict) or not isinstance(doc.get("time"), dict):
        raise ValueError("npm metadata must contain a time object")
    times = {}
    for version, published in doc["time"].items():
        if not isinstance(published, str):
            raise ValueError(f"npm timestamp for {version} must be a string")
        if published.endswith("Z"):
            published = published[:-1] + "+00:00"
        times[version] = datetime.fromisoformat(published).timestamp()
    return times


def git_times(repo_dir: str) -> dict[str, float]:
    result = subprocess.run(
        ["git", "-C", repo_dir, "for-each-ref",
         "--format=%(refname:short) %(creatordate:unix)", "refs/tags"],
        check=True, capture_output=True, text=True,
    )
    times = {}
    for line in result.stdout.splitlines():
        tag, published = line.rsplit(" ", 1)
        if not SEMVER.fullmatch(tag):
            continue
        times[tag] = float(published)
    return times


def error(message: str) -> None:
    escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::error::" + escaped)


def main() -> int:
    package = os.environ.get("RELEASE_WINDOW_NPM_PACKAGE", "")
    url = os.environ.get("RELEASE_WINDOW_GIT_URL", "")
    days_text = os.environ.get("RELEASE_WINDOW_DAYS", "")
    try:
        if bool(package) == bool(url):
            raise ValueError("set exactly one of npm-package or git-url")
        if package and not re.fullmatch(r"(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*", package):
            raise ValueError(f"invalid npm-package: {package}")
        if url and (not url.startswith("https://") or re.search(r"\s", url)):
            raise ValueError("git-url must start with https:// and contain no whitespace")
        if not re.fullmatch(r"[1-9][0-9]*", days_text):
            raise ValueError("window-days must be a positive integer")
        days = int(days_text)

        if package:
            with urllib.request.urlopen(npm_url(package), timeout=30) as response:
                times = npm_times(json.load(response))
        else:
            repo = tempfile.mkdtemp(dir=os.environ.get("RUNNER_TEMP"))
            try:
                subprocess.run(
                    ["git", "init", "-q", "--bare", repo],
                    check=True, capture_output=True, text=True,
                )
                subprocess.run(
                    ["git", "-C", repo, "fetch", "-q", "--depth=1", "--filter=tree:0",
                     "--", url, "+refs/tags/*:refs/tags/*"],
                    check=True, capture_output=True, text=True,
                )
                times = git_times(repo)
            finally:
                shutil.rmtree(repo)

        versions = window(times, time.time(), days)
        with open(os.environ.get("GITHUB_OUTPUT", ""), "a", encoding="utf-8") as output:
            output.write("versions=" + json.dumps(versions, separators=(",", ":")) + "\n")
        print(f"release window ({days} days): {', '.join(versions)}")
        return 0
    except subprocess.CalledProcessError as exc:
        error(f"git failed for {url} with exit status {exc.returncode}")
    except (WindowError, ValueError, OSError, HTTPException) as exc:
        error(str(exc))
    return 1


if __name__ == "__main__":
    sys.exit(main())
