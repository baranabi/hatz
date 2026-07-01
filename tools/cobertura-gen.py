#!/usr/bin/env python3
"""Generate Cobertura XML from kcov's index.js JSON data.

kcov writes per-binary coverage data as index.js (JavaScript object notation).
This script parses that data and generates valid Cobertura XML for Codecov.

The index.js format from kcov's getIndexHeader():
  {"link":"file.html","title":"file.zig","summary_name":"src/engine/file.zig",
   "covered_class":"lineCov","covered":"75.0","covered_lines":"60",
   "uncovered_lines":"20","total_lines":"80"},
"""

import json
import os
import re
import sys
import xml.sax.saxutils as saxutils


def find_index_js(base_dir: str = "coverage") -> str | None:
    """Find index.js in coverage dir, preferring the merged (root) one."""
    # Prefer root-level index.js (merged data from all binaries)
    root_js = os.path.join(base_dir, "index.js")
    if os.path.exists(root_js):
        return root_js
    # Fall back to per-binary index.js
    candidates = []
    for root, _dirs, files in os.walk(base_dir):
        if "index.js" in files and root != base_dir:
            candidates.append(os.path.join(root, "index.js"))
    if candidates:
        candidates.sort(key=len, reverse=True)
        return candidates[0]
    return None


def extract_json_array(content: str, array_name: str = "files") -> list:
    """Extract a JavaScript array as JSON from kcov's index.js.

    The file format is: var data = {files:[...], merged_files:[...]};
    We extract the 'files' array and convert JS object notation to valid JSON.
    """
    # Try: {"files":[...]} (quoted) and {files:[...]} (unquoted)
    for quote_style in ['\\"%s\\"', '%s']:
        key_pattern = quote_style % array_name
        # Match: { ... "files":[ ... ] , ... }
        pattern = r'\{[^}]*?' + key_pattern + r'\s*:\s*\[(.*?)\]\s*[,\]]'
        match = re.search(pattern, content, re.DOTALL)
        if match:
            js_array = match.group(1)
            break
    else:
        return []

    js_array = match.group(1)

    # Convert JavaScript object notation to JSON:
    # 1. Unquote keys that are already quoted (these are fine)
    # 2. Quote unquoted keys
    js_array = re.sub(r'(\{|,)\s*(\w+)\s*:', r'\1"\2":', js_array)
    # 3. Remove trailing commas
    js_array = re.sub(r',\s*\]', ']', js_array)
    js_array = re.sub(r',\s*\}', '}', js_array)

    # Wrap as JSON array
    json_str = f'[{js_array}]'

    try:
        return json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"  JSON parse error: {e}", file=sys.stderr)
        print(f"  First 300 chars: {json_str[:300]}", file=sys.stderr)
        return []


def parse_index_js(js_path: str) -> list:
    """Parse kcov's index.js and extract file coverage data."""
    with open(js_path) as f:
        content = f.read()

    print(f"  index.js size: {len(content)} bytes", file=sys.stderr)

    file_list = extract_json_array(content, "files")
    if not file_list:
        print(f"  No files array found, trying merged_files", file=sys.stderr)
        file_list = extract_json_array(content, "merged_files")

    print(f"  Parsed {len(file_list)} entries from index.js", file=sys.stderr)
    if file_list:
        print(f"  First entry keys: {list(file_list[0].keys())}", file=sys.stderr)
        print(f"  First entry: {file_list[0]}", file=sys.stderr)

    result = []
    for entry in file_list:
        # kcov index.js uses "summary_name" for the file path display name
        name = entry.get("summary_name") or entry.get("name") or ""
        if not name or "src/engine" not in name:
            continue
        # Strip "[...]/" prefix that kcov adds for path abbreviation
        if name.startswith("[...]/"):
            name = name[6:]

        # kcov index.js JSON fields (from getIndexHeader):
        #   total_lines, covered_lines, uncovered_lines, covered (pct string)
        total = entry.get("total_lines") or entry.get("lines") or 0
        covered = entry.get("covered_lines") or entry.get("covered") or 0

        # Handle string values (kcov sometimes uses strings for numbers)
        try:
            total = int(float(str(total)))
            covered = int(float(str(covered)))
        except (ValueError, TypeError):
            continue

        result.append((name, total, covered, total - covered))

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
    print(f"Generated: {output_path} ({len(xml_content)} bytes, {len(files)} files)")
    if files:
        total_pct = 100.0 * total_covered / total_lines if total_lines > 0 else 0
        print(f"Coverage: {total_covered}/{total_lines} lines ({total_pct:.1f}%)")
    return xml_content


def main() -> None:
    output_path = os.environ.get("COBERTURA_OUTPUT", "coverage/cobertura.xml")

    js_path = find_index_js()
    if not js_path:
        print("Cobertura-gen: no index.js found under coverage/", file=sys.stderr)
        write_cobertura_xml([], output_path)
        return

    print(f"Cobertura-gen: using {js_path}", file=sys.stderr)
    files = parse_index_js(js_path)

    if not files:
        print(f"Cobertura-gen: no src/engine files found or parse failed", file=sys.stderr)
        print(f"Cobertura-gen: writing minimal Cobertura XML with 0 coverage", file=sys.stderr)
        write_cobertura_xml([], output_path)
        return

    write_cobertura_xml(files, output_path)


if __name__ == "__main__":
    main()
