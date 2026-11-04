"""Builds assets/fonts/brands/DbBrands.ttf: one monochrome glyph per DBMS
logo, used through AppIcons like the Phosphor glyphs and tinted with the
brand color.

Sources (download them first, see README.md):
  * Simple Icons (CC0)  - <simple-icons>/icons/<name>.svg, 24x24 single path
  * Devicon (MIT)       - <devicon>/icons/<name>/<name>-plain.svg (or
                          -<variant>.svg with "dev:<name>@<variant>"), 128x128

Usage:
  python3 -m venv .venv && .venv/bin/pip install fonttools
  .venv/bin/python tool/brand_font/build_brand_font.py <simple-icons dir> <devicon dir>
"""

import re
import sys
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path

# Codepoint, glyph name, source ("si:<name>", "dev:<name>" or "path:<d>@<size>").
GLYPHS = [
    (0xF000, 'postgresql', 'dev:postgresql'),
    # Simple Icons' MySQL is the wordmark: Devicon's original is the dolphin.
    (0xF001, 'mysql', 'dev:mysql@original'),
    (0xF002, 'mariadb', 'si:mariadb'),
    (0xF003, 'sqlite', 'si:sqlite'),
    (0xF004, 'mongodb', 'si:mongodb'),
    (0xF005, 'redis', 'si:redis'),
    (0xF006, 'cassandra', 'si:apachecassandra'),
    (0xF007, 'bigquery', 'si:googlebigquery'),
    (0xF008, 'snowflake', 'si:snowflake'),
    (0xF009, 'clickhouse', 'si:clickhouse'),
    (0xF00A, 'trino', 'si:trino'),
    (0xF00B, 'duckdb', 'si:duckdb'),
    (0xF00C, 'databricks', 'si:databricks'),
    (0xF00D, 'sqlserver', 'dev:microsoftsqlserver'),
    (0xF00E, 'firebird', 'dev:firebird'),
    (0xF00F, 'aws', 'dev:amazonwebservices'),
    # Oracle's mark is its red capsule ring.
    (0xF010, 'oracle', 'path:M7 5h10a7 7 0 0 1 0 14H7A7 7 0 0 1 7 5zm0 2.6a4.4 4.4 0 0 0 0 8.8h10a4.4 4.4 0 0 0 0-8.8z@24'),
]

UPM = 1024
ASCENT = 960
DESCENT = -64
# Logos fill edge to edge; Phosphor glyphs keep about 1/8 of air around them.
BOX = 880


def svg_paths(file: Path) -> tuple[list[str], float, float]:
    text = file.read_text()
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', text).group(1).split()]
    return re.findall(r'<path[^>]*\sd="([^"]+)"', text), vb[2], vb[3]


def source(spec: str, si: Path, dev: Path) -> tuple[list[str], float, float]:
    kind, name = spec.split(':', 1)
    if kind == 'si':
        return svg_paths(si / 'icons' / f'{name}.svg')
    if kind == 'dev':
        name, _, variant = name.partition('@')
        return svg_paths(dev / 'icons' / name / f'{name}-{variant or "plain"}.svg')
    d, size = name.rsplit('@', 1)
    return [d], float(size), float(size)


def draw(paths: list[str], pen) -> None:
    for d in paths:
        parse_path(d, pen)


def main() -> None:
    si, dev = Path(sys.argv[1]), Path(sys.argv[2])
    out = Path(__file__).resolve().parents[2] / 'assets' / 'fonts' / 'brands' / 'DbBrands.ttf'
    names = ['.notdef'] + [n for _, n, _ in GLYPHS]
    glyphs = {'.notdef': TTGlyphPen(None).glyph()}
    metrics = {'.notdef': (UPM, 0)}
    for _, name, spec in GLYPHS:
        paths, w, h = source(spec, si, dev)
        rec = RecordingPen()
        draw(paths, rec)
        bounds = BoundsPen(None)
        rec.replay(bounds)
        x0, y0, x1, y1 = bounds.bounds
        scale = BOX / max(x1 - x0, y1 - y0)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        mid_y = (ASCENT + DESCENT) / 2
        # SVG y grows downwards: flip it, then center in the em box.
        transform = (scale, 0, 0, -scale, UPM / 2 - cx * scale, mid_y + cy * scale)
        tt = TTGlyphPen(None)
        rec.replay(TransformPen(Cu2QuPen(tt, max_err=1, reverse_direction=True), transform))
        glyphs[name] = tt.glyph()
        metrics[name] = (UPM, 0)
    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({cp: name for cp, name, _ in GLYPHS})
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupNameTable({'familyName': 'DbBrands', 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=ASCENT, sTypoDescender=DESCENT, usWinAscent=ASCENT, usWinDescent=-DESCENT)
    fb.setupPost()
    out.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(out))
    for cp, name, _ in GLYPHS:
        print(f'  static const IconData {name} = IconData(0x{cp:x}, fontFamily: \'DbBrands\');')
    print(f'wrote {out}')


if __name__ == '__main__':
    main()
