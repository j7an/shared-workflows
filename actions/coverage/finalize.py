from __future__ import annotations

import os
from pathlib import Path
import sys


ERROR = 2
VALID_STATUS = {"0\n": 0, "1\n": 1, "2\n": 2}
REPORTING_ERROR = "\n\n## Coverage reporting error\nDiagnostic publication did not complete. Inspect this job's logs.\n"


def append_reporting_error() -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if not summary:
        raise OSError("missing GITHUB_STEP_SUMMARY")
    with Path(summary).open("a", encoding="utf-8") as handle:
        handle.write(REPORTING_ERROR)


def stored_status() -> int | None:
    directory = os.environ.get("COVERAGE_OUTPUT_DIRECTORY", "")
    if not directory:
        return None
    try:
        return VALID_STATUS.get((Path(directory) / "status").read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        return None


def main() -> int:
    status = stored_status()
    upload_succeeded = os.environ.get("COVERAGE_UPLOAD_OUTCOME") == "success"
    if status is not None and upload_succeeded:
        return status
    try:
        append_reporting_error()
    except OSError:
        return ERROR
    return ERROR


if __name__ == "__main__":
    sys.exit(main())
