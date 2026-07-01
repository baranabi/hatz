#!/usr/bin/env python3
"""Generate a coverage step summary from kcov's index.html and write to GITHUB_STEP_SUMMARY.

kcov natively generates both index.html and cobertura.xml in its output directory.
This script only handles the step summary (markdown table for GitHub Actions UI).
The native cobertura.xml is used for Codecov upload.

ponytail: We used to generate a synthetic Cobertura XML here, but it had incorrect
per-line entries (first N lines blindly assigned as covered). kcov's native output
is correct, so we now rely on it exclusively."""

import os
import re
import sys


def parse_coverage_html(index_path: str):
    """Parse kcov index.html, return list of (name, lines, covered, missed, pct)."""
    with open(index_path) as f:
        html = f.read()

    rows = re.findall(r"<tr[^>]*>.*?</tr>", html, re.DOTALL)
    files = []
    for row in rows:
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.DOTALL)
        if len(cells) >= 6 and "src/engine" in row:
            name = re.sub(r"<[^>]+>", "", cells[0]).strip()
            l = int(re.sub(r"<[^>]+>", "", cells[1]).strip())
            c = int(re.sub(r"<[^>]+>", "", cells[2]).strip())
            m = int(re.sub(r"<[^>]+>", "", cells[3]).strip())
            pct = re.sub(r"<[^>]+>", "", cells[4]).strip()
            files.append((name, l, c, m, pct))
    return files


def write_step_summary(files: list, summary_file: str):
    """Write markdown coverage table to GITHUB_STEP_SUMMARY."""
    md_lines = [
        "## Coverage Report",
        "",
        "| File | Lines | Covered | Missed | Coverage |",
        "|------|-------|---------|--------|----------|",
    ]
    total_lines = total_covered = total_missed = 0
    for name, l, c, m, pct in files:
        md_lines.append(f"| {name} | {l} | {c} | {m} | {pct} |")
        total_lines += l
        total_covered += c
        total_missed += m

    if total_lines > 0:
        total_pct = f"{100.0 * total_covered / total_lines:.1f}%"
        md_lines.append(
            f"| **Total** | **{total_lines}** | **{total_covered}** | **{total_missed}** | **{total_pct}** |"
        )
    else:
        md_lines.append("| **No coverage data found** | | | | |")

    with open(summary_file, "a") as f:
        f.write("\n".join(md_lines) + "\n")
    print(f"Wrote {len(files)} file rows to {summary_file}")


# ponytail: kcov generates its own native cobertura.xml with correct per-line coverage data.
# Our synthetic version was overwriting it with fake per-line entries (first N lines assigned
# as covered), causing Codecov to reject the data. We now rely on kcov's native output.


def main() -> None:
    index_path = "coverage/index.html"
    files: list = []

    if os.path.exists(index_path):
        try:
            files = parse_coverage_html(index_path)
        except Exception as e:
            print(f"coverage-summary.py: error parsing {index_path}: {e}", file=sys.stderr)
    else:
        print(f"coverage-summary.py: {index_path} not found -- using empty coverage", file=sys.stderr)

    # Write GitHub step summary (may be empty if no coverage data)
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        write_step_summary(files, summary_file)
    else:
        print("coverage-summary.py: GITHUB_STEP_SUMMARY not set -- skipping step summary", file=sys.stderr)

    # ponytail: kcov generates its own native cobertura.xml — we rely on that for Codecov.
    # Only write step summary here. kcov's native XML has correct per-line coverage data
    # which our synthetic version lacked, causing 0% on Codecov.


if __name__ == "__main__":
    main()
