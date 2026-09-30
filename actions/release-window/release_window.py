"""Recent-minor release window, ported from pi-kit/scripts/pi-window.mjs."""

import re

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
