#!/usr/bin/env python3
"""
Convert docs/war-stories.md to docs/war-stories.pdf using markdown-it-py + weasyprint.

Run from repo root: python3 docs/_make_pdf.py
"""
from pathlib import Path
from markdown_it import MarkdownIt
from weasyprint import HTML, CSS

ROOT = Path(__file__).parent
md_path = ROOT / "war-stories.md"
pdf_path = ROOT / "war-stories.pdf"

md = MarkdownIt("commonmark", {"breaks": True, "html": True}).enable("table").enable("strikethrough")
body_html = md.render(md_path.read_text(encoding="utf-8"))

# Portfolio-grade typography. Compact margins, readable code blocks, table styling.
CSS_TEXT = """
@page {
    size: A4;
    margin: 18mm 18mm 22mm 18mm;
    @bottom-right {
        content: "Page " counter(page) " / " counter(pages);
        font-family: Helvetica, Arial, sans-serif;
        font-size: 8pt;
        color: #888;
    }
}
* { box-sizing: border-box; }
body {
    font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 10pt;
    line-height: 1.45;
    color: #1a1a1a;
}
h1 {
    font-size: 22pt;
    border-bottom: 2px solid #222;
    padding-bottom: 6pt;
    margin-top: 0;
    page-break-before: avoid;
}
h2 {
    font-size: 15pt;
    border-bottom: 1px solid #ccc;
    padding-bottom: 4pt;
    margin-top: 20pt;
    page-break-before: auto;
    page-break-after: avoid;
}
h3 {
    font-size: 11.5pt;
    color: #b34a00;
    margin-top: 14pt;
    margin-bottom: 4pt;
    page-break-after: avoid;
}
h3 + p, h3 + p + p, h3 + p + p + p { page-break-before: avoid; }
p { margin: 6pt 0; }
ul, ol { margin: 6pt 0; padding-left: 22pt; }
li { margin: 2pt 0; }
strong { color: #000; font-weight: 600; }
em { color: #444; }
hr { border: none; border-top: 1px solid #ccc; margin: 22pt 0; }
code {
    font-family: "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
    font-size: 9pt;
    background: #f3f3f3;
    padding: 1pt 4pt;
    border-radius: 3pt;
    color: #b34a00;
}
pre {
    background: #f8f8f8;
    border: 1px solid #e0e0e0;
    border-radius: 4pt;
    padding: 8pt 10pt;
    page-break-inside: avoid;
    overflow-x: auto;
}
pre code {
    background: transparent;
    padding: 0;
    font-size: 8.5pt;
    color: #1a1a1a;
}
blockquote {
    border-left: 3px solid #888;
    padding-left: 12pt;
    margin-left: 0;
    color: #444;
    font-style: italic;
}
table {
    border-collapse: collapse;
    margin: 10pt 0;
    width: 100%;
    page-break-inside: avoid;
}
th, td {
    border: 1px solid #d0d0d0;
    padding: 5pt 8pt;
    text-align: left;
    font-size: 9.5pt;
    vertical-align: top;
}
th { background: #f0f0f0; font-weight: 600; }
"""

doc = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>War Stories</title></head>
<body>{body_html}</body></html>"""

HTML(string=doc).write_pdf(pdf_path, stylesheets=[CSS(string=CSS_TEXT)])
print(f"\u2713 wrote {pdf_path} ({pdf_path.stat().st_size:,} bytes)")
