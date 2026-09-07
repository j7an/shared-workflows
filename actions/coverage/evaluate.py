from __future__ import annotations

from dataclasses import asdict, dataclass
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Mapping, NoReturn
import xml.etree.ElementTree as ElementTree

PASS = 0
BELOW_THRESHOLD = 1
ERROR = 2


class GateError(Exception):
    """A bounded, operator-facing coverage-gate error."""


@dataclass(frozen=True)
class GateInputs:
    report_path: Path
    diff_cover_path: Path
    base_sha: str
    minimum_text: str
    minimum: Decimal
    source_pathspecs: tuple[str, ...]
    exclude_pathspecs: tuple[str, ...]
    checkout: Path
    output_directory: Path
    step_summary: Path


@dataclass(frozen=True)
class ReportInventory:
    format: str
    repository_paths: frozenset[str]


CONTROL = re.compile(r"[\x00-\x1f\x7f]")
SHA = re.compile(r"[0-9a-f]{40}\Z")
VERSION = re.compile(r"\b(\d+)\.(\d+)(?:\.\d+)?\b")


def fail(category: str) -> NoReturn:
    raise GateError(category)


def required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "")
    if not value:
        fail("required-input: " + name)
    return value


def no_controls(value: str, category: str) -> str:
    if CONTROL.search(value):
        fail(category)
    return value


def regular_readable(path: Path, category: str) -> None:
    try:
        mode = os.stat(path).st_mode
    except OSError:
        fail(category)
    if not stat.S_ISREG(mode) or not os.access(path, os.R_OK):
        fail(category)


def command(args: list[str], category: str, cwd: Path) -> str:
    try:
        result = subprocess.run(args, cwd=cwd, check=False, shell=False,
                                capture_output=True, text=True)
    except OSError:
        fail(category)
    if result.returncode != 0:
        fail(category)
    return result.stdout.strip()


def pathspec_list(value: str, category: str) -> tuple[str, ...]:
    items = tuple(item for item in value.split("\n") if item)
    if not items or any(CONTROL.search(item) for item in items):
        fail(category)
    return items


def parse_inputs(env: Mapping[str, str]) -> GateInputs:
    output = Path(no_controls(required(env, "COVERAGE_OUTPUT_DIRECTORY"),
                              "invalid-output-directory")).resolve()
    if env.get("COVERAGE_RUNNER_OS") != "Linux":
        fail("unsupported-runner")
    workspace = Path(no_controls(required(env, "GITHUB_WORKSPACE"),
                                 "invalid-working-directory")).resolve()
    working = Path(no_controls(env.get("COVERAGE_WORKING_DIRECTORY", "."),
                               "invalid-working-directory"))
    checkout = (workspace / working).resolve() if not working.is_absolute() else working.resolve()
    if workspace not in (checkout, *checkout.parents):
        fail("invalid-working-directory")
    top = command(["git", "rev-parse", "--show-toplevel"], "invalid-working-directory", checkout)
    if Path(top).resolve() != checkout:
        fail("invalid-working-directory")

    base = required(env, "COVERAGE_BASE_SHA")
    if not SHA.fullmatch(base):
        fail("invalid-base-sha")
    command(["git", "cat-file", "-e", base + "^{commit}"], "invalid-base-sha", checkout)

    minimum_text = required(env, "COVERAGE_MINIMUM")
    try:
        minimum = Decimal(minimum_text)
    except InvalidOperation:
        fail("invalid-minimum")
    if not minimum.is_finite() or minimum < 0 or minimum > 100:
        fail("invalid-minimum")

    diff_value = no_controls(required(env, "COVERAGE_DIFF_COVER_PATH"), "invalid-diff-cover")
    diff = Path(diff_value)
    diff = (checkout / diff).resolve() if not diff.is_absolute() else diff.resolve()
    regular_readable(diff, "invalid-diff-cover")
    if not os.access(diff, os.X_OK):
        fail("invalid-diff-cover")
    version = command([str(diff), "--version"], "unsupported-diff-cover", checkout)
    match = VERSION.search(version)
    if not match or int(match.group(1)) != 10 or int(match.group(2)) < 2:
        fail("unsupported-diff-cover")

    report_value = no_controls(required(env, "COVERAGE_REPORT_PATH"), "invalid-report")
    report = Path(report_value)
    report = (checkout / report).resolve() if not report.is_absolute() else report.resolve()
    regular_readable(report, "invalid-report")
    if report.stat().st_size == 0:
        fail("invalid-report")
    sources = pathspec_list(required(env, "COVERAGE_SOURCE_PATHS"), "invalid-source-pathspecs")
    excludes_text = env.get("COVERAGE_EXCLUDE_PATHS", "")
    excludes = tuple(item for item in excludes_text.split("\n") if item)
    if any(CONTROL.search(item) for item in excludes):
        fail("invalid-exclude-pathspecs")
    step_summary = Path(no_controls(required(env, "GITHUB_STEP_SUMMARY"),
                                    "invalid-step-summary")).resolve()
    return GateInputs(report, diff, base, minimum_text, minimum, sources, excludes,
                      checkout, output, step_summary)


def tracked_paths(inputs: GateInputs) -> frozenset[str]:
    included = command(["git", "ls-files", "-z", "--", *inputs.source_pathspecs],
                       "invalid-source-pathspecs", inputs.checkout)
    paths = frozenset(item for item in included.split("\0") if item)
    if inputs.exclude_pathspecs:
        excluded = frozenset(item for item in command(
            ["git", "ls-files", "-z", "--", *inputs.exclude_pathspecs],
            "invalid-exclude-pathspecs", inputs.checkout).split("\0") if item)
        paths = paths - excluded
    if not paths:
        fail("empty-production-scope")
    return paths


def report_path(value: str, roots: tuple[Path, ...], checkout: Path,
                tracked: frozenset[str]) -> str:
    no_controls(value, "invalid-report-path")
    raw = Path(value)
    candidates: set[str] = set()
    bases = (Path(""),) if raw.is_absolute() else roots
    for base in bases:
        candidate = raw.resolve() if raw.is_absolute() else (base / raw).resolve()
        if checkout not in (candidate, *candidate.parents):
            continue
        relative = candidate.relative_to(checkout).as_posix()
        if relative in tracked:
            candidates.add(relative)
    if not candidates:
        fail("invalid-report-path")
    if len(candidates) != 1:
        fail("ambiguous-report-path")
    return next(iter(candidates))


def inventory_cobertura(inputs: GateInputs, tracked: frozenset[str]) -> ReportInventory:
    try:
        root = ElementTree.parse(inputs.report_path).getroot()
    except (ElementTree.ParseError, OSError):
        fail("malformed-cobertura")
    if root.tag.rsplit("}", 1)[-1] != "coverage":
        fail("malformed-cobertura")
    source_values = [node.text or "" for node in root.findall(".//{*}source")]
    roots = tuple((inputs.checkout / no_controls(value, "invalid-report-path")).resolve()
                  if not Path(no_controls(value, "invalid-report-path")).is_absolute()
                  else Path(no_controls(value, "invalid-report-path")).resolve()
                  for value in (source_values or [""]))
    paths: set[str] = set()
    classes = root.findall(".//{*}class")
    if not classes:
        fail("malformed-cobertura")
    for entry in classes:
        filename = entry.get("filename", "")
        if not filename:
            fail("malformed-cobertura")
        lines = entry.findall(".//{*}line")
        if not lines:
            fail("malformed-cobertura")
        for line in lines:
            try:
                number = int(line.get("number", "")); hits = int(line.get("hits", ""))
            except ValueError:
                fail("malformed-cobertura")
            if number <= 0 or hits < 0:
                fail("malformed-cobertura")
        paths.add(report_path(filename, roots, inputs.checkout, tracked))
    return ReportInventory("cobertura", frozenset(paths))


def inventory_lcov(inputs: GateInputs, tracked: frozenset[str]) -> ReportInventory:
    try:
        lines = inputs.report_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        fail("malformed-lcov")
    records: list[list[str]] = []; record: list[str] = []
    for line in lines:
        record.append(line)
        if line == "end_of_record":
            records.append(record); record = []
    if record or not records:
        fail("malformed-lcov")
    paths: set[str] = set()
    for rows in records:
        source = [row[3:] for row in rows if row.startswith("SF:")]
        data = [row for row in rows if row.startswith("DA:") or row.startswith("BRDA:")]
        if len(source) != 1 or not source[0] or not data:
            fail("malformed-lcov")
        for row in data:
            fields = row.split(":", 1)[1].split(",")
            if len(fields) < 2 or not fields[0].isdigit() or int(fields[0]) <= 0:
                fail("malformed-lcov")
            if row.startswith("DA:") and (len(fields) != 2 or not fields[1].isdigit()):
                fail("malformed-lcov")
            if row.startswith("BRDA:") and (
                len(fields) != 4 or not fields[1].isdigit() or not fields[2].isdigit()
                or (fields[3] != "-" and not fields[3].isdigit())
            ):
                fail("malformed-lcov")
        paths.add(report_path(source[0], (inputs.checkout,), inputs.checkout, tracked))
    return ReportInventory("lcov", frozenset(paths))


def inventory_report(inputs: GateInputs, tracked_files: frozenset[str]) -> ReportInventory:
    suffix = inputs.report_path.suffix.lower()
    if suffix == ".xml":
        return inventory_cobertura(inputs, tracked_files)
    if suffix in (".info", ".lcov"):
        return inventory_lcov(inputs, tracked_files)
    fail("unsupported-report")


def write_outputs(output: Path, status: int, message: str, metadata: object) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "status").write_text(str(status) + "\n", encoding="utf-8")
    (output / "diagnostics.txt").write_text(message[:1024] + "\n", encoding="utf-8")
    (output / "summary.md").write_text("Coverage gate: " + message[:1024] + "\n", encoding="utf-8")
    (output / "metadata.json").write_text(
        json.dumps(bounded_metadata(metadata), default=str, sort_keys=True) + "\n",
        encoding="utf-8")


def bounded_metadata(value: object) -> object:
    if isinstance(value, dict):
        return {str(key)[:128]: bounded_metadata(item)
                for key, item in list(value.items())[:32]}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [bounded_metadata(item) for item in list(value)[:32]]
    if isinstance(value, str):
        return value[:512]
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return str(value)[:512]


def finish_error(inputs: GateInputs | None, message: str) -> NoReturn:
    output = inputs.output_directory if inputs else Path(os.environ.get("COVERAGE_OUTPUT_DIRECTORY", "."))
    write_outputs(output, ERROR, message, {"status": ERROR, "error": message})
    raise SystemExit(ERROR)


def main(env: Mapping[str, str]) -> int:
    inputs: GateInputs | None = None
    try:
        output = env.get("COVERAGE_OUTPUT_DIRECTORY")
        if output:
            Path(output).resolve().mkdir(parents=True, exist_ok=True)
        inputs = parse_inputs(env)
        inventory = inventory_report(inputs, tracked_paths(inputs))
        write_outputs(inputs.output_directory, PASS, "validated", {
            "inputs": asdict(inputs), "inventory": {"format": inventory.format,
            "repository_paths": sorted(inventory.repository_paths)}})
        return PASS
    except GateError as error:
        finish_error(inputs, str(error))
    except SystemExit:
        raise
    except Exception:
        finish_error(inputs, "internal-error")
    return ERROR


if __name__ == "__main__":
    raise SystemExit(main(os.environ))
