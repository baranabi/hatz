#!/usr/bin/env python3
"""Generate a coverage step summary from kcov's index.html and write to GITHUB_STEP_SUMMARY."""
import os
import re
import sys


def main() -> None:
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_file:
        print("GITHUB_STEP_SUMMARY not set (not in CI) -- skipping", file=sys.stderr)
        sys.exit(0)

    index_path = "coverage/index.html"
    if not os.path.exists(index_path):
        print(f"{index_path} not found -- skipping step summary", file=sys.stderr)
        sys.exit(0)

    with open(index_path) as f:
        html = f.read()

    rows = re.findall(r"<tr[^>]*>.*?</tr>", html, re.DOTALL)
    md = [
        "## Coverage Report",
        "",
        "| File | Lines | Covered | Missed | Coverage |",
        "|------|-------|---------|--------|----------|",
    ]
    total_lines = total_covered = total_missed = 0
    for row in rows:
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.DOTALL)
        if len(cells) >= 6 and "src/engine" in row:
            name = re.sub(r"<[^>]+>", "", cells[0]).strip()
            l = int(re.sub(r"<[^>]+>", "", cells[1]).strip())
            c = int(re.sub(r"<[^>]+>", "", cells[2]).strip())
            m = int(re.sub(r"<[^>]+>", "", cells[3]).strip())
            pct = re.sub(r"<[^>]+>", "", cells[4]).strip()
            md.append(f"| {name} | {l} | {c} | {m} | {pct} |")
            total_lines += l
            total_covered += c
            total_missed += m

    if len(md) > 4:
        total_pct = (
            f"{100.0 * total_covered / total_lines:.1f}%"
            if total_lines > 0
            else "N/A"
        )
        md.append(
            f"| **Total** | **{total_lines}** | **{total_covered}** | **{total_missed}** | **{total_pct}** |"
        )
        with open(summary_file, "a") as f:
            f.write("\n".join(md) + "\n")
        print(f"Wrote {len(md) - 5} file rows + total to {summary_file}")
    else:
        print("No coverage rows found in index.html")


if __name__ == "__main__":
    main()
