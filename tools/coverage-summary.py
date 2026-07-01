#!/usr/bin/env python3
"""Generate a coverage step summary from kcov's index.html and write to GITHUB_STEP_SUMMARY.
Also generate cobertura.xml for Codecov upload."""

import os
import re
import sys
import xml.etree.ElementTree as ET
from xml.dom import minidom


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

    with open(summary_file, "a") as f:
        f.write("\n".join(md_lines) + "\n")
    print(f"Wrote {len(files)} file rows + total to {summary_file}")


def write_cobertura_xml(files: list, output_path: str, source_dir: str = "."):
    """Generate a Cobertura XML from parsed coverage data."""
    total_lines = sum(f[1] for f in files)
    total_covered = sum(f[2] for f in files)
    # Group files by package (directory)
    packages: dict[str, list] = {}
    for name, l, c, m, pct in files:
        pkg = os.path.dirname(name).replace("/", ".")
        if pkg == "":
            pkg = "root"
        if pkg not in packages:
            packages[pkg] = []
        packages[pkg].append((name, l, c, m, pct))

    coverage_elem = ET.Element("coverage")
    coverage_elem.set("line-rate", str(total_covered / total_lines) if total_lines > 0 else "0")
    coverage_elem.set("branch-rate", "0")
    coverage_elem.set("lines-covered", str(total_covered))
    coverage_elem.set("lines-valid", str(total_lines))
    coverage_elem.set("branches-covered", "0")
    coverage_elem.set("branches-valid", "0")
    coverage_elem.set("complexity", "0")
    coverage_elem.set("version", "1.0")
    coverage_elem.set("timestamp", "0")

    sources_elem = ET.SubElement(coverage_elem, "sources")
    source_elem = ET.SubElement(sources_elem, "source")
    source_elem.text = source_dir

    packages_elem = ET.SubElement(coverage_elem, "packages")

    for pkg_name, pkg_files in sorted(packages.items()):
        pkg_total = sum(f[1] for f in pkg_files)
        pkg_covered = sum(f[2] for f in pkg_files)
        pkg_elem = ET.SubElement(packages_elem, "package")
        pkg_elem.set("name", pkg_name)
        pkg_elem.set("line-rate", str(pkg_covered / pkg_total) if pkg_total > 0 else "0")
        pkg_elem.set("branch-rate", "0")
        pkg_elem.set("complexity", "0")

        classes_elem = ET.SubElement(pkg_elem, "classes")
        for name, l, c, m, pct in pkg_files:
            cls_elem = ET.SubElement(classes_elem, "class")
            cls_elem.set("name", os.path.basename(name))
            cls_elem.set("filename", name)
            cls_elem.set("line-rate", str(c / l) if l > 0 else "0")
            cls_elem.set("branch-rate", "0")
            cls_elem.set("complexity", "0")
            methods_elem = ET.SubElement(cls_elem, "methods")
            lines_elem = ET.SubElement(cls_elem, "lines")
            # Add a summary line for the whole file (no per-line data from kcov HTML)
            line_elem = ET.SubElement(lines_elem, "line")
            line_elem.set("number", "1")
            line_elem.set("hits", str(c))
            line_elem.set("branch", "false")

    # Pretty-print
    rough = ET.tostring(coverage_elem, encoding="unicode")
    dom = minidom.parseString(rough)
    pretty = dom.toprettyxml(indent="  ")
    with open(output_path, "w") as f:
        f.write(pretty)
    print(f"Wrote Cobertura XML ({len(files)} files) to {output_path}")


def main() -> None:
    index_path = "coverage/index.html"
    if not os.path.exists(index_path):
        print(f"{index_path} not found -- skipping coverage output", file=sys.stderr)
        sys.exit(0)

    files = parse_coverage_html(index_path)
    if not files:
        print("No coverage rows found in index.html", file=sys.stderr)
        sys.exit(1)

    # Write GitHub step summary
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        write_step_summary(files, summary_file)
    else:
        print("GITHUB_STEP_SUMMARY not set (not in CI) -- skipping step summary", file=sys.stderr)

    # Write Cobertura XML for Codecov
    cobertura_path = "coverage/cobertura.xml"
    write_cobertura_xml(files, cobertura_path)


if __name__ == "__main__":
    main()
