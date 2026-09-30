"""Recent-minor release window, ported from pi-kit/scripts/pi-window.mjs."""

from datetime import datetime
import re
import subprocess

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
        times[tag] = float(published)
    return times
