#!/usr/bin/env python3
"""Generate Cobertura XML from kcov's index.js JSON data.

kcov writes per-binary coverage data as index.js (JSON-like).
This script parses that file and generates valid Cobertura XML.

The index.js format is:
  var data = {files:[{name:"...", lines:N, covered:M, ...}, ...]};

We handle both the merged (root coverage/index.js) and per-binary formats.
"""

import os
import re
import sys
import xml.sax.saxutils as saxutils


def find_index_js(base_dir: str = "coverage") -> str | None:
    """Find index.js in coverage dir, preferring the deepest (per-binary) one."""
    candidates = []
    for root, _dirs, files in os.walk(base_dir):
        if "index.js" in files:
            candidates.append(os.path.join(root, "index.js"))
    # Prefer the deepest path (most specific binary coverage data)
    if candidates:
        candidates.sort(key=len, reverse=True)
        return candidates[0]
    return None


def parse_index_js(js_path: str) -> list:
    """Parse kcov's index.js and extract file coverage data."""
    with open(js_path) as f:
        content = f.read()

    # Extract the files array from var data = {files:[...], merged_files:[...]};
    # Using a relaxed regex that handles JavaScript object notation
    files_match = re.search(r"files:\s*\[(.*?)\]\s*[,\]]", content, re.DOTALL)
    if not files_match:
        print(f"  No files array found in {js_path}", file=sys.stderr)
        return []

    files_json = "[" + files_match.group(1) + "]"
    
    # Clean up JavaScript to make it valid JSON:
    # 1. Remove trailing commas before ]
    files_json = re.sub(r",\s*\]", "]", files_json)
    # 2. Quote unquoted keys
    files_json = re.sub(r"(\{|,)\s*(\w+)\s*:", r'\1"\2":', files_json)
    # 3. Remove trailing commas before }
    files_json = re.sub(r",\s*\}", "}", files_json)

    import json
    try:
        file_list = json.loads(files_json)
    except json.JSONDecodeError as e:
        print(f"  JSON parse error: {e}", file=sys.stderr)
        print(f"  First 500 chars: {files_json[:500]}", file=sys.stderr)
        return []

    result = []
    for entry in file_list:
        name = entry.get("name", "")
        if not name or "src/engine" not in name:
            continue
        lines = entry.get("lines", 0) or 0
        covered = entry.get("covered", 0) or 0
        result.append((name, lines, covered, lines - covered))

    return result


def write_cobertura_xml(files: list, output_path: str) -> str:
    """Generate Cobertura XML from parsed coverage data."""
    total_lines = sum(f[1] for f in files)
    total_covered = sum(f[2] for f in files)

    line_rate = total_covered / total_lines if total_lines > 0 else 0

    import time
    lines = []
    lines.append('<?xml version="1.0" ?>')
    lines.append('<!DOCTYPE coverage SYSTEM "http://cobertura.sourceforge.net/xml/coverage-04.dtd">')
    lines.append(f'<coverage lines-valid="{total_lines}" lines-covered="{total_covered}" line-rate="{line_rate:.6f}" branches-valid="0" branches-covered="0" branch-rate="0" complexity="0" timestamp="{int(time.time())}">')
    lines.append('\t<sources>')
    lines.append('\t\t<source>.</source>')
    lines.append('\t</sources>')
    lines.append('\t<packages>')
    lines.append(f'\t\t<package name="src.engine" line-rate="{line_rate:.6f}" branch-rate="0">')
    lines.append('\t\t\t<classes>')

    for name, _lines, covered, missed in files:
        class_name = re.sub(r"[^a-zA-Z0-9_.]", "_", name)
        class_line_rate = covered / _lines if _lines > 0 else 0

        lines.append(f'\t\t\t\t<class name="{saxutils.escape(class_name)}" filename="{saxutils.escape(name)}" line-rate="{class_line_rate:.6f}" branch-rate="0">')
        lines.append('\t\t\t\t\t<methods/>')
        lines.append('\t\t\t\t\t<lines>')
        # Generate per-line entries from totals (best we can do without per-line data)
        line_hits = [1] * covered + [0] * missed
        for lineno, hits in enumerate(line_hits, 1):
            lines.append(f'\t\t\t\t\t\t<line number="{lineno}" hits="{hits}" branch="false"/>')
        lines.append('\t\t\t\t\t</lines>')
        lines.append('\t\t\t\t</class>')

    lines.append('\t\t\t</classes>')
    lines.append('\t\t</package>')
    lines.append('\t</packages>')
    lines.append('</coverage>')

    xml_content = "\n".join(lines) + "\n"
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        f.write(xml_content)
    print(f"Generated Cobertura XML: {output_path} ({len(xml_content)} bytes, {len(files)} files, {total_covered}/{total_lines} lines covered)")
    return xml_content


def main() -> None:
    output_path = os.environ.get("COBERTURA_OUTPUT", "coverage/cobertura.xml")

    js_path = find_index_js()
    if not js_path:
        print("Cobertura-gen: no index.js found under coverage/", file=sys.stderr)
        # Write minimal valid XML so downstream steps don't choke
        write_cobertura_xml([], output_path)
        return

    print(f"Cobertura-gen: using {js_path}", file=sys.stderr)
    files = parse_index_js(js_path)

    if not files:
        print(f"Cobertura-gen: no src/engine files found in {js_path}", file=sys.stderr)
        print("Cobertura-gen: writing minimal Cobertura XML with 0 coverage", file=sys.stderr)
        write_cobertura_xml([], output_path)
        return

    write_cobertura_xml(files, output_path)
    print(f"Cobertura-gen: success — {len(files)} files, {sum(f[2] for f in files)}/{sum(f[1] for f in files)} lines")


if __name__ == "__main__":
    main()
