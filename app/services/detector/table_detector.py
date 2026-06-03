"""Table-region extraction for question crops.

Exam questions routinely embed a data table — a truth table, a list of
reagents, a "Column-I / Column-II" matching grid, a matrix of values, a
chemical-reaction grid. These are *grids of text*, so the generic vector-figure
path in :mod:`figure_detector` deliberately *rejects* them: its
``_encloses_body_text`` guard exists to throw away phantom clusters formed when
scattered column rules / underlines merge around a paragraph. A real table trips
that same guard (it is, by definition, full of text), so without a dedicated
path a question that contains a table has its crop clipped to the surrounding
prose and the table is sliced off.

This module recovers tables from the PDF's own structure using PyMuPDF's
``page.find_tables()`` (MuPDF's ruling/whitespace table finder). Each detected
table is returned as a plain rectangle that the figure layer wraps in a
:class:`~app.services.detector.base.FigureRegion`, so the question it belongs to
grows its crop to contain the whole grid — exactly like a diagram or an embedded
image.

Everything is expressed in PDF points so it maps onto either the detection
raster or the hi-res crop render.
"""

from __future__ import annotations

import logging

import fitz

logger = logging.getLogger(__name__)


# A real data grid spans at least this fraction of the page in each axis. A
# sliver narrower/shorter than this is a stray rule pair, not a table.
_MIN_TABLE_WIDTH_FRAC = 0.06
_MIN_TABLE_HEIGHT_FRAC = 0.02

# A "table" that fills almost the entire page in BOTH axes is the page/card
# border (or the scan frame), never a question's own grid. Folding it into a
# crop would balloon the crop to the full page, so anything this large is
# ignored.
_MAX_TABLE_WIDTH_FRAC = 0.98
_MAX_TABLE_HEIGHT_FRAC = 0.97

# A grid must have at least this many rows AND columns to count. A 1xN or Nx1
# "table" is a plain list or a single ruled line — better left to the prose /
# content-box paths than treated as a figure that grows the crop sideways.
_MIN_ROWS = 2
_MIN_COLS = 2

# Tables living entirely inside the top/bottom margin band are page furniture
# (a ruled header/footer block), not question content.
_MARGIN_TOP_FRAC = 0.05
_MARGIN_BOTTOM_FRAC = 0.95


def _rect_or_none(value: object) -> "fitz.Rect | None":
    if value is None:
        return None
    try:
        rect = fitz.Rect(value)
    except Exception:
        return None
    if rect.is_empty or rect.is_infinite:
        return None
    if rect.width <= 0 or rect.height <= 0:
        return None
    return rect


def _in_margin(rect: "fitz.Rect", page_h: float) -> bool:
    top_frac = rect.y0 / page_h
    bottom_frac = rect.y1 / page_h
    return bottom_frac <= _MARGIN_TOP_FRAC or top_frac >= _MARGIN_BOTTOM_FRAC


def detect_tables(page: "fitz.Page") -> list["fitz.Rect"]:
    """Return the bounding rectangles (PDF points) of data tables on a page.

    Uses PyMuPDF's ``find_tables`` with the default *ruled-line* strategy, which
    keys off the table's own border/grid strokes — the common case in exam
    papers (truth tables, matching grids, reagent tables, matrices, reaction
    grids are nearly always boxed). A grid is kept only when it is a genuine 2-D
    table (``>= _MIN_ROWS`` x ``>= _MIN_COLS``), is large enough to be content
    rather than a stray rule pair, is not the near-full-page card border, and is
    not stranded in a page margin.

    De-duplicated and sorted top-to-bottom. Returns an empty list on any failure
    so a page whose table finder errors degrades gracefully to the existing
    text/figure behaviour.
    """

    rect = page.rect
    page_w = float(rect.width)
    page_h = float(rect.height)
    if page_w <= 0 or page_h <= 0:
        return []

    try:
        found = page.find_tables()
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("find_tables_failed error=%s", str(exc))
        return []

    tables = getattr(found, "tables", None) or []
    min_w = _MIN_TABLE_WIDTH_FRAC * page_w
    min_h = _MIN_TABLE_HEIGHT_FRAC * page_h
    max_w = _MAX_TABLE_WIDTH_FRAC * page_w
    max_h = _MAX_TABLE_HEIGHT_FRAC * page_h

    out: list[fitz.Rect] = []
    for tbl in tables:
        r = _rect_or_none(getattr(tbl, "bbox", None))
        if r is None:
            continue

        rows = int(getattr(tbl, "row_count", 0) or 0)
        cols = int(getattr(tbl, "col_count", 0) or 0)
        if rows < _MIN_ROWS or cols < _MIN_COLS:
            continue

        if r.width < min_w or r.height < min_h:
            continue
        if r.width >= max_w and r.height >= max_h:
            continue
        if _in_margin(r, page_h):
            continue

        out.append(fitz.Rect(r))

    # De-duplicate near-identical / nested grids (the finder can report an outer
    # frame and an inner sub-grid for the same table); keep the larger frame.
    out.sort(key=lambda r: -(r.width * r.height))
    unique: list[fitz.Rect] = []
    tol = 0.01 * max(page_w, page_h)
    for r in out:
        if any(
            big.x0 - tol <= r.x0 and big.y0 - tol <= r.y0
            and big.x1 + tol >= r.x1 and big.y1 + tol >= r.y1
            for big in unique
        ):
            continue
        unique.append(r)

    unique.sort(key=lambda r: (r.y0, r.x0))
    return unique
