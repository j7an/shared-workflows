from __future__ import annotations

from dataclasses import asdict, dataclass
from decimal import Decimal, InvalidOperation
from html import escape
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
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


@dataclass(frozen=True)
class Comparison:
    base_sha: str
    merge_base_sha: str
    tested_sha: str


@dataclass(frozen=True)
class Evaluation:
    outcome: str
    status: int
    total_num_lines: int | None
    total_num_violations: int | None
    total_percent_covered: int | None
    num_changed_lines: int | None


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


def git(checkout: Path, *args: str, check: bool = True,
        environment: Mapping[str, str] | None = None) -> bytes:
    try:
        result = subprocess.run(["git", "-c", "core.quotepath=false", *args], cwd=checkout,
                                check=False, shell=False, capture_output=True, env=environment)
    except OSError:
        fail("git-unavailable: install Git and ensure it is available on PATH")
    if check and result.returncode != 0:
        fail("git-command-failed")
    return result.stdout


def git_text(checkout: Path, *args: str, category: str) -> str:
    try:
        return git(checkout, *args).decode("utf-8").strip()
    except GateError as error:
        if str(error).startswith("git-unavailable"):
            raise
        fail(category)
    except UnicodeError:
        fail(category)


def git_object_type(checkout: Path, object_name: str) -> str | None:
    try:
        object_type = git(checkout, "cat-file", "-t", object_name, check=False).decode("ascii").strip()
    except UnicodeError:
        return None
    return object_type or None


def pathspec_list(value: str, category: str) -> tuple[str, ...]:
    items = tuple(item for item in value.split("\n") if item)
    if not items or any(CONTROL.search(item) or negative_pathspec(item) for item in items):
        fail(category)
    return items


def negative_pathspec(value: str) -> bool:
    if value.startswith((":!", ":^")):
        return True
    if not value.startswith(":("):
        return False
    close = value.find(")")
    if close < 0:
        return False
    return "exclude" in value[2:close].split(",")


def output_directory(env: Mapping[str, str]) -> Path:
    return Path(no_controls(required(env, "COVERAGE_OUTPUT_DIRECTORY"),
                            "invalid-output-directory")).resolve()


def parse_inputs(env: Mapping[str, str]) -> GateInputs:
    output = output_directory(env)
    if env.get("COVERAGE_RUNNER_OS") != "Linux":
        fail("unsupported-runner")
    workspace = Path(no_controls(required(env, "GITHUB_WORKSPACE"),
                                 "invalid-working-directory")).resolve()
    working = Path(no_controls(env.get("COVERAGE_WORKING_DIRECTORY", "."),
                               "invalid-working-directory"))
    checkout = (workspace / working).resolve() if not working.is_absolute() else working.resolve()
    if workspace not in (checkout, *checkout.parents):
        fail("invalid-working-directory")
    top = git_text(checkout, "rev-parse", "--show-toplevel", category="invalid-working-directory")
    if Path(top).resolve() != checkout:
        fail("invalid-working-directory")

    base = required(env, "COVERAGE_BASE_SHA")
    if not SHA.fullmatch(base):
        fail("invalid-base-sha")
    if base == "0" * 40:
        fail("invalid-base-sha")
    if git_object_type(checkout, base + "^{commit}") != "commit":
        if git_object_type(checkout, base) is not None:
            fail("invalid-base-sha")
        fail("base-history-unavailable: fetch sufficient history containing the base commit")

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
    excludes = pathspec_list(excludes_text, "invalid-exclude-pathspecs") if excludes_text else ()
    step_summary = Path(no_controls(required(env, "GITHUB_STEP_SUMMARY"),
                                    "invalid-step-summary")).resolve()
    return GateInputs(report, diff, base, minimum_text, minimum, sources, excludes,
                      checkout, output, step_summary)


def list_tracked(checkout: Path, pathspecs: tuple[str, ...], treeish: str = "HEAD",
                 category: str = "invalid-source-pathspecs") -> frozenset[str]:
    try:
        with tempfile.TemporaryDirectory(prefix="coverage-git-index-") as temporary:
            environment = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))
            git(checkout, "read-tree", treeish, environment=environment)
            output = git(checkout, "ls-files", "-z", "--", *pathspecs, environment=environment)
        return frozenset(item.decode("utf-8", "surrogateescape") for item in output.split(b"\0") if item)
    except GateError as error:
        if str(error).startswith("git-unavailable"):
            raise
        fail(category)


def select_effective_files(inputs: GateInputs,
                           comparison: Comparison | None = None) -> frozenset[str]:
    treeish = comparison.tested_sha if comparison else "HEAD"
    included = list_tracked(inputs.checkout, inputs.source_pathspecs, treeish)
    excluded = (list_tracked(inputs.checkout, inputs.exclude_pathspecs, treeish,
                             "invalid-exclude-pathspecs")
                if inputs.exclude_pathspecs else frozenset())
    paths = included - excluded
    if not paths:
        fail("empty-production-scope")
    return paths


def capture_comparison(inputs: GateInputs) -> Comparison:
    try:
        base = git_text(inputs.checkout, "rev-parse", inputs.base_sha + "^{commit}",
                        category="invalid-comparison")
        tested = git_text(inputs.checkout, "rev-parse", "HEAD^{commit}", category="invalid-comparison")
        merge = git(inputs.checkout, "merge-base", base, tested, check=False)
        if not merge:
            fail("comparison-history-unavailable: fetch sufficient history containing the merge base")
        merge_base = merge.decode("utf-8").strip()
    except GateError as error:
        if str(error).startswith("git-unavailable") or str(error).startswith("comparison-history-unavailable"):
            raise
        fail("invalid-comparison")
    except UnicodeError:
        fail("invalid-comparison")
    if not all(SHA.fullmatch(value) for value in (base, merge_base, tested)):
        fail("invalid-comparison")
    return Comparison(base, merge_base, tested)


def name_status_records(inputs: GateInputs, comparison: Comparison) -> tuple[tuple[str, str | None, str], ...]:
    try:
        output = git(inputs.checkout, "diff", "--name-status", "-z", "--find-renames",
                     comparison.merge_base_sha, comparison.tested_sha)
        values = [value.decode("utf-8", "surrogateescape") for value in output.split(b"\0") if value]
    except GateError as error:
        if str(error).startswith("git-unavailable"):
            raise
        fail("invalid-comparison")
    except UnicodeError:
        fail("invalid-comparison")
    records: list[tuple[str, str | None, str]] = []
    index = 0
    while index < len(values):
        status = values[index]
        index += 1
        if not status:
            fail("invalid-comparison")
        if status[0] in ("R", "C"):
            if index + 1 >= len(values):
                fail("invalid-comparison")
            old, new = values[index], values[index + 1]
            index += 2
            records.append((status[0], old, new))
        else:
            if index >= len(values):
                fail("invalid-comparison")
            path = values[index]
            index += 1
            records.append((status[0], None, path))
    return tuple(records)


def select_changed_files(inputs: GateInputs, comparison: Comparison,
                         effective: frozenset[str]) -> tuple[str, ...]:
    changed = {post for status, _pre, post in name_status_records(inputs, comparison)
               if status != "D" and post in effective}
    return tuple(sorted(changed))


def literal_selector(path: str) -> str:
    return ":(literal)" + path


def write_scoped_patch(inputs: GateInputs, comparison: Comparison,
                       changed: tuple[str, ...]) -> Path:
    patch = inputs.output_directory / "scoped.diff"
    selectors = set(changed)
    for status, pre_image, post_image in name_status_records(inputs, comparison):
        if status == "R" and post_image in selectors and pre_image is not None:
            selectors.add(pre_image)
    if not changed:
        patch.write_bytes(b"")
        return patch
    try:
        output = git(inputs.checkout, "diff", "--unified=0", "--no-ext-diff", "--no-color",
                     "--find-renames", comparison.merge_base_sha, comparison.tested_sha, "--",
                     *(literal_selector(path) for path in sorted(selectors)))
    except GateError as error:
        if str(error).startswith("git-unavailable"):
            raise
        fail("invalid-comparison")
    patch.write_bytes(output)
    return patch


def assert_tested_head(inputs: GateInputs, comparison: Comparison) -> None:
    current = git_text(inputs.checkout, "rev-parse", "HEAD^{commit}", category="tested-head-changed")
    if current != comparison.tested_sha:
        fail("tested-head-changed")


def write_bounded(path: Path, value: str) -> None:
    path.write_text(value[:16384], encoding="utf-8")


def invoke_diff_cover(inputs: GateInputs, comparison: Comparison,
                      patch: Path) -> tuple[int, Path, Path]:
    json_report = inputs.output_directory / "diff-cover.json"
    markdown_report = inputs.output_directory / "diff-cover.md"
    argv = [
        str(inputs.diff_cover_path),
        str(inputs.report_path),
        "--diff-file",
        str(patch),
        "--compare-branch",
        comparison.merge_base_sha,
        "--fail-under",
        inputs.minimum_text,
        "--format",
        f"json:{json_report},markdown:{markdown_report}",
        "--quiet",
    ]
    try:
        result = subprocess.run(
            argv, cwd=inputs.checkout, check=False, shell=False, capture_output=True,
            text=True, encoding="utf-8", errors="replace",
        )
    except OSError:
        write_bounded(inputs.output_directory / "stdout.txt", "")
        write_bounded(inputs.output_directory / "stderr.txt", "tool-launch-failed\n")
        return -1, json_report, markdown_report
    write_bounded(inputs.output_directory / "stdout.txt", result.stdout)
    write_bounded(inputs.output_directory / "stderr.txt", result.stderr)
    return result.returncode, json_report, markdown_report


def plain_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def reject_json_constant(value: str) -> NoReturn:
    del value
    raise ValueError("nonfinite-json-number")


def result_payload(result_path: Path, markdown_path: Path) -> dict[str, object] | None:
    try:
        if (not result_path.is_file() or not markdown_path.is_file()
                or result_path.stat().st_size == 0 or markdown_path.stat().st_size == 0):
            return None
        payload = json.loads(result_path.read_text(encoding="utf-8"),
                             parse_constant=reject_json_constant)
    except (OSError, UnicodeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    required_keys = {
        "report_name", "diff_name", "src_stats", "total_num_lines",
        "total_num_violations", "total_percent_covered", "num_changed_lines",
    }
    if not required_keys.issubset(payload):
        return None
    if (not isinstance(payload["report_name"], str)
            or not isinstance(payload["diff_name"], str)
            or not isinstance(payload["src_stats"], dict)):
        return None
    totals = [payload[name] for name in (
        "total_num_lines", "total_num_violations", "total_percent_covered",
        "num_changed_lines",
    )]
    if not all(plain_int(value) for value in totals):
        return None
    total_lines, total_violations, percent, changed_lines = totals
    if (total_lines < 0 or total_violations < 0 or changed_lines < 0
            or total_violations > total_lines or total_lines > changed_lines
            or percent < 0 or percent > 100):
        return None

    measured = 0
    violations = 0
    for source, stats in payload["src_stats"].items():
        if not isinstance(source, str) or not isinstance(stats, dict):
            return None
        if not {"percent_covered", "violation_lines", "covered_lines", "violations"}.issubset(stats):
            return None
        source_percent = stats["percent_covered"]
        if (not isinstance(source_percent, (int, float)) or isinstance(source_percent, bool)
                or not math.isfinite(source_percent)
                or source_percent < 0 or source_percent > 100):
            return None
        line_groups = [stats[name] for name in ("violation_lines", "covered_lines")]
        if any(not isinstance(lines, list) for lines in line_groups):
            return None
        if any(not plain_int(line) or line <= 0 for lines in line_groups for line in lines):
            return None
        reported_violations = stats["violations"]
        if (not isinstance(reported_violations, list)
                or any(not isinstance(item, list) or len(item) != 2
                       or not plain_int(item[0]) or item[0] <= 0
                       or (item[1] is not None and not isinstance(item[1], str))
                       for item in reported_violations)):
            return None
        violation_lines = stats["violation_lines"]
        covered_lines = stats["covered_lines"]
        if (len(set(violation_lines)) != len(violation_lines)
                or len(set(covered_lines)) != len(covered_lines)
                or set(violation_lines) & set(covered_lines)
                or [item[0] for item in reported_violations] != violation_lines):
            return None
        source_lines = len(violation_lines) + len(covered_lines)
        if source_lines == 0:
            return None
        expected_source_percent = 100 - float(len(violation_lines)) / source_lines * 100
        if source_percent != expected_source_percent:
            return None
        measured += source_lines
        violations += len(violation_lines)
    expected_percent = (int(float(total_lines - total_violations) / total_lines * 100)
                        if total_lines else 100)
    if measured != total_lines or violations != total_violations or percent != expected_percent:
        return None
    return payload


def classify_result(tool_status: int, result_path: Path, markdown_path: Path,
                    minimum: Decimal) -> Evaluation:
    payload = result_payload(result_path, markdown_path)
    if payload is None:
        return Evaluation("error", ERROR, None, None, None, None)
    total_lines = int(payload["total_num_lines"])
    total_violations = int(payload["total_num_violations"])
    percent = int(payload["total_percent_covered"])
    changed_lines = int(payload["num_changed_lines"])
    if total_lines == 0 and tool_status == 0:
        return Evaluation("not-applicable", PASS, 0, 0, None, changed_lines)
    if total_lines > 0 and tool_status == 0 and Decimal(percent) >= minimum:
        return Evaluation("pass", PASS, total_lines, total_violations, percent, changed_lines)
    if total_lines > 0 and tool_status == 1 and Decimal(percent) < minimum:
        return Evaluation("below-threshold", BELOW_THRESHOLD, total_lines,
                          total_violations, percent, changed_lines)
    return Evaluation("error", ERROR, total_lines, total_violations, percent, changed_lines)


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
        if len(source) != 1 or not source[0]:
            fail("malformed-lcov")
        for row in data:
            fields = row.split(":", 1)[1].split(",")
            if len(fields) < 2 or not fields[0].isdigit() or int(fields[0]) <= 0:
                fail("malformed-lcov")
            if row.startswith("DA:") and (len(fields) not in (2, 3) or not fields[1].isdigit()):
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


def atomic_status(output: Path, status: int) -> None:
    temporary = output / ".status.tmp"
    temporary.write_text(str(status) + "\n", encoding="utf-8")
    os.replace(temporary, output / "status")


def write_outputs(output: Path, status: int, message: str, metadata: object,
                  *, summary: str | None = None, step_summary: Path | None = None) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "diagnostics.txt").write_text(message[:1024] + "\n", encoding="utf-8")
    rendered_summary = summary if summary is not None else "Coverage gate: " + message[:1024] + "\n"
    (output / "summary.md").write_text(rendered_summary[:16384], encoding="utf-8")
    (output / "metadata.json").write_text(metadata_json(metadata, status) + "\n", encoding="utf-8")
    if step_summary is not None:
        try:
            with step_summary.open("a", encoding="utf-8") as summary_output:
                summary_output.write(rendered_summary[:16384])
        except OSError:
            with (output / "diagnostics.txt").open("a", encoding="utf-8") as diagnostic:
                diagnostic.write("diagnostic-publication-failed\n")
            if isinstance(metadata, dict):
                metadata = dict(metadata, publication_error="diagnostic-publication-failed")
                (output / "metadata.json").write_text(
                    metadata_json(metadata, status) + "\n", encoding="utf-8")
    atomic_status(output, status)


def write_diagnostics(inputs: GateInputs, comparison: Comparison,
                      inventory: ReportInventory, evaluation: Evaluation) -> None:
    copied_report = inputs.output_directory / ("coverage-report" + inputs.report_path.suffix.lower())
    shutil.copyfile(inputs.report_path, copied_report)
    effective = select_effective_files(inputs, comparison)
    changed = select_changed_files(inputs, comparison, effective)
    metadata = {
        "inputs": asdict(inputs),
        "inventory": {
            "format": inventory.format,
            "repository_paths": sorted(inventory.repository_paths),
        },
        "comparison": asdict(comparison),
        "effective_paths": sorted(effective),
        "changed_paths": list(changed),
        "evaluation": asdict(evaluation),
    }
    (inputs.output_directory / "metadata.json").write_text(
        metadata_json(metadata, evaluation.status) + "\n", encoding="utf-8")

    diagnostic = ("evaluator-failed: verify diff-cover completed and inspect retained "
                  "JSON, Markdown, stdout, and stderr"
                  if evaluation.outcome == "error" else evaluation.outcome)
    (inputs.output_directory / "diagnostics.txt").write_text(diagnostic + "\n", encoding="utf-8")
    stdout = (inputs.output_directory / "stdout.txt").read_text(
        encoding="utf-8", errors="replace")[:16384]
    stderr = (inputs.output_directory / "stderr.txt").read_text(
        encoding="utf-8", errors="replace")[:16384]
    rows = [
        "<h2>Changed-line coverage</h2>",
        "<ul>",
        f"<li>Outcome: <code>{escape(evaluation.outcome)}</code></li>",
        f"<li>Report: <code>{escape(inputs.report_path.name)}</code></li>",
        f"<li>Base commit: <code>{escape(comparison.base_sha)}</code></li>",
        f"<li>Tested commit: <code>{escape(comparison.tested_sha)}</code></li>",
        f"<li>Merge base: <code>{escape(comparison.merge_base_sha)}</code></li>",
        f"<li>Minimum: <code>{escape(inputs.minimum_text)}</code></li>",
    ]
    if evaluation.total_num_lines is not None:
        rows.extend([
            f"<li>Measured changed lines: {evaluation.total_num_lines}</li>",
            f"<li>Uncovered changed lines: {evaluation.total_num_violations}</li>",
        ])
    if evaluation.total_percent_covered is not None:
        rows.append(f"<li>Changed-line coverage: {evaluation.total_percent_covered}%</li>")
    rows.append("</ul>")
    if evaluation.outcome == "error":
        rows.extend([
            "<h3>Evaluator error</h3>",
            "<p>Evaluator failed or returned incomplete or inconsistent output. "
            "Inspect diff-cover.json, diff-cover.md, stdout.txt, and stderr.txt; "
            "then verify the supplied tool and report.</p>",
        ])
    payload = result_payload(inputs.output_directory / "diff-cover.json",
                             inputs.output_directory / "diff-cover.md")
    if payload is not None:
        uncovered = []
        for source, stats in sorted(payload["src_stats"].items()):
            lines = stats["violation_lines"]
            if lines:
                uncovered.append(f"<li><code>{escape(source)}</code>: {', '.join(map(str, lines))}</li>")
        if uncovered:
            rows.extend(["<h3>Uncovered changed lines</h3>", "<ul>", *uncovered, "</ul>"])
    if stdout:
        rows.extend(["<h3>Evaluator stdout</h3>", f"<pre>{escape(stdout)}</pre>"])
    if stderr:
        rows.extend(["<h3>Evaluator stderr</h3>", f"<pre>{escape(stderr)}</pre>"])
    summary = "\n".join(rows) + "\n"
    (inputs.output_directory / "summary.md").write_text(summary, encoding="utf-8")
    with inputs.step_summary.open("a", encoding="utf-8") as step_summary:
        step_summary.write(summary)
    atomic_status(inputs.output_directory, evaluation.status)


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


def metadata_json(metadata: object, status: int) -> str:
    encoded = json.dumps(bounded_metadata(metadata), default=str, sort_keys=True)
    if len(encoded.encode("utf-8")) < 4095:
        return encoded
    essential: dict[str, object] = {"status": status, "truncated": True}
    if isinstance(metadata, dict) and isinstance(metadata.get("error"), str):
        essential["error"] = metadata["error"][:512]
    return json.dumps(essential, sort_keys=True)


def finish_error(inputs: GateInputs | None, output: Path | None, message: str,
                 env: Mapping[str, str]) -> NoReturn:
    destination = inputs.output_directory if inputs else output
    if destination is not None:
        try:
            bounded_message = message[:1024]
            summary = ("<h2>Changed-line coverage</h2>\n"
                       f"<p>Validation error: <code>{escape(bounded_message)}</code></p>\n"
                       "<p>Correct the action inputs or checkout prerequisites, then rerun the job.</p>\n")
            metadata = {"status": ERROR, "error": bounded_message}
            step_summary = inputs.step_summary if inputs else None
            if step_summary is None:
                raw_summary = env.get("GITHUB_STEP_SUMMARY", "")
                if raw_summary and not CONTROL.search(raw_summary):
                    step_summary = Path(raw_summary).resolve()
            write_outputs(destination, ERROR, bounded_message, metadata,
                          summary=summary, step_summary=step_summary)
        except OSError:
            pass
    sys.stderr.write(message[:1024] + "\n")
    raise SystemExit(ERROR)


def finish_publication_error(inputs: GateInputs, evaluation: Evaluation) -> NoReturn:
    message = "diagnostic-publication-failed"
    try:
        with (inputs.output_directory / "diagnostics.txt").open("a", encoding="utf-8") as output:
            output.write(message + "\n")
    except OSError:
        pass
    try:
        with (inputs.output_directory / "summary.md").open("a", encoding="utf-8") as output:
            output.write(f"<p>Reporting error: <code>{message}</code></p>\n")
    except OSError:
        pass
    try:
        metadata_path = inputs.output_directory / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if not isinstance(metadata, dict):
            metadata = {"evaluation": asdict(evaluation)}
        metadata["publication_error"] = message
        metadata["status"] = ERROR
        metadata_path.write_text(metadata_json(metadata, ERROR) + "\n", encoding="utf-8")
    except (OSError, UnicodeError, ValueError):
        pass
    try:
        atomic_status(inputs.output_directory, ERROR)
    except OSError:
        pass
    sys.stderr.write(message + ": original-outcome=" + evaluation.outcome + "\n")
    raise SystemExit(ERROR)


def main(env: Mapping[str, str]) -> int:
    inputs: GateInputs | None = None
    output: Path | None = None
    try:
        output = output_directory(env)
        output.mkdir(parents=True, exist_ok=True)
        inputs = parse_inputs(env)
        comparison = capture_comparison(inputs)
        effective = select_effective_files(inputs, comparison)
        tracked = list_tracked(inputs.checkout, (".",), comparison.tested_sha,
                               "invalid-comparison")
        inventory = inventory_report(inputs, tracked)
        if not inventory.repository_paths & effective:
            fail("missing-in-scope-report-path")
        changed = select_changed_files(inputs, comparison, effective)
        missing = sorted(set(changed) - inventory.repository_paths)
        if missing:
            fail("missing-changed-report-path")
        patch = write_scoped_patch(inputs, comparison, changed)
        assert_tested_head(inputs, comparison)
        tool_status, result_path, markdown_path = invoke_diff_cover(inputs, comparison, patch)
        assert_tested_head(inputs, comparison)
        evaluation = classify_result(tool_status, result_path, markdown_path, inputs.minimum)
        try:
            write_diagnostics(inputs, comparison, inventory, evaluation)
        except OSError:
            finish_publication_error(inputs, evaluation)
        return evaluation.status
    except GateError as error:
        finish_error(inputs, output, str(error), env)
    except SystemExit:
        raise
    except Exception:
        finish_error(inputs, output, "internal-error", env)
    return ERROR


if __name__ == "__main__":
    raise SystemExit(main(os.environ))
