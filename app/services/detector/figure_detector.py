"""Figure extraction for the text (Tier 1) detector.

Exam questions routinely embed a diagram between the stem and the options — a
circuit, a cone, a free-body sketch, a velocity-time graph. The text detector
only measures *words*, so a question's crop bounds (built from text extents)
either clip a figure that is wider than the text or drop one that sits below the
last text line entirely.

This module recovers the figures from the PDF's own structure (no OCR needed for
searchable papers):

  * **Embedded raster images** — ``page.get_image_info()`` gives each image's
    bounding box. These are almost always part of a question.
  * **Vector drawings** — ``page.get_drawings()`` gives every stroke/fill. A
    real diagram is a *cluster* of strokes spanning a 2-D area; a column rule or
    an answer underline is a single thin line. We cluster nearby drawings and
    keep only clusters that form a genuine 2-D region, discarding thin rules.

The result is a list of :class:`FigureRegion` extents that the region builder
folds into whichever question vertically surrounds (or immediately precedes)
each figure.
"""

from __future__ import annotations

import logging

import fitz

from .base import FigureRegion
from .furniture import branding_link_bands, detect_content_boxes, is_branding_text
from .table_detector import detect_tables

logger = logging.getLogger(__name__)


# An embedded image smaller than this fraction of the page area is treated as an
# inline glyph / bullet / tiny logo, not a question figure.
_MIN_IMAGE_AREA_FRAC = 0.0008

# A vector-drawing cluster must span at least this fraction of the page in BOTH
# dimensions to count as a diagram. A column divider or an underline is thin in
# one dimension, so this excludes rules while keeping real 2-D figures.
_MIN_FIGURE_WIDTH_FRAC = 0.04
_MIN_FIGURE_HEIGHT_FRAC = 0.03

# A vector cluster that fills almost the whole page in both axes is a page or
# card *border*, not a question figure. Folding it into a crop would balloon the
# crop to the full card, so anything this large is ignored.
_MAX_FIGURE_WIDTH_FRAC = 0.96
_MAX_FIGURE_HEIGHT_FRAC = 0.92

# Two drawing rects are part of the same figure when their bounding boxes are no
# further apart than this fraction of the page height (diagram strokes sit close
# together; separate figures are spaced further apart).
_CLUSTER_GAP_FRAC = 0.03

# Figures living entirely inside the top/bottom margin band are page furniture
# (a header logo, a footer brand mark), never question content.
_MARGIN_TOP_FRAC = 0.07
_MARGIN_BOTTOM_FRAC = 0.93

# A figure that appears at the *same position* on many pages is a background
# watermark (a faint brand logo printed behind the text on every page), not a
# question diagram. Two figures count as "the same" when each edge, expressed as
# a fraction of the page, is within this tolerance.
_WATERMARK_POS_TOL_FRAC = 0.02

# A repeated-position figure is a watermark when it recurs on at least this
# share of the document (and at least ``_WATERMARK_MIN_PAGES`` pages). A genuine
# diagram never lands at the identical spot across half the pages.
_WATERMARK_PAGE_FRACTION = 0.5
_WATERMARK_MIN_PAGES = 3

# A *vector* cluster is only a real diagram when it sits in whitespace. Exam
# papers draw a lot of non-diagram vector graphics — column dividers, the box
# borders around an "Extra Edge" note, answer underlines — and our greedy
# clustering merges those scattered thin strokes into one big rectangle that
# happens to enclose a whole block of body text. Folding such a phantom figure
# into a question balloons its crop across the column gutter and slices the real
# text (the reported "sentences getting cut" bug).
#
# A genuine figure (a circuit, a graph, a cone) contains essentially no body
# text inside its bounding box, whereas a phantom rule-merge is full of it. So a
# vector cluster is rejected when too many text lines fall inside it, or text
# covers too much of its area.
_FIGURE_MAX_TEXT_AREA_FRAC = 0.18
_FIGURE_MAX_TEXT_LINES = 3

# A vector cluster that the text-overlap guard would otherwise reject can still
# be a genuine diagram/formula/chemical structure: a benzene ring, a reaction
# scheme with bond lines and arrows, or a display equation with fraction bars,
# radicals and brackets. What separates such a figure from a phantom rule-merge
# (a few long column dividers / underlines that happen to wrap a paragraph) is
# the *stroke population*: a real structure is built from MANY SHORT strokes,
# while a phantom merge is a HANDFUL OF LONG rules. A cluster carrying at least
# this many strokes, of which a clear majority are short, is treated as a
# figure even though text falls inside it — so a chemistry/maths block grows the
# crop instead of being sliced.
_DENSE_FIGURE_MIN_STROKES = 8
_DENSE_FIGURE_SHORT_FRAC = 0.6

# A stroke is "short" (a bond / arrow / bracket / fraction bar, not a page rule)
# when neither side exceeds this fraction of the page in its own axis.
_SHORT_STROKE_MAX_FRAC = 0.33


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


def _text_line_rects(page: "fitz.Page") -> list[tuple[float, float, float, float]]:
    """Return every text line's bbox on the page, in PDF points.

    Used to reject vector clusters that merely enclose body text (decorative
    rules / box borders drawn around a paragraph) rather than a real diagram.
    """

    rects: list[tuple[float, float, float, float]] = []
    try:
        text_dict = page.get_text("dict")
    except Exception:  # pragma: no cover - defensive
        return rects
    for block in text_dict.get("blocks", []) or []:
        if not isinstance(block, dict) or block.get("type") not in (None, 0):
            continue
        for line in block.get("lines", []) or []:
            if not isinstance(line, dict):
                continue
            spans = line.get("spans", []) or []
            txt = "".join(str(s.get("text", "")) for s in spans).strip()
            bbox = line.get("bbox")
            if not txt or not bbox or len(bbox) != 4:
                continue
            rects.append((float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])))
    return rects


def _encloses_body_text(
    cluster: "fitz.Rect",
    text_rects: list[tuple[float, float, float, float]],
) -> bool:
    """True if a vector cluster mostly wraps body text (so it is NOT a figure).

    A real diagram sits in whitespace and contains little or no text. A phantom
    cluster — scattered column rules, underlines and note-box borders merged
    together — encloses many text lines. We flag the cluster when either more
    than ``_FIGURE_MAX_TEXT_LINES`` text lines fall inside it or text covers more
    than ``_FIGURE_MAX_TEXT_AREA_FRAC`` of its area.
    """

    if cluster.width <= 0 or cluster.height <= 0:
        return False

    area = cluster.width * cluster.height
    covered = 0.0
    lines_inside = 0
    for tx0, ty0, tx1, ty1 in text_rects:
        ix0 = max(tx0, cluster.x0)
        iy0 = max(ty0, cluster.y0)
        ix1 = min(tx1, cluster.x1)
        iy1 = min(ty1, cluster.y1)
        if ix1 <= ix0 or iy1 <= iy0:
            continue
        lines_inside += 1
        covered += (ix1 - ix0) * (iy1 - iy0)
        if lines_inside > _FIGURE_MAX_TEXT_LINES:
            return True

    return (covered / area) > _FIGURE_MAX_TEXT_AREA_FRAC


def _stroke_segments(drawings: list) -> list["fitz.Rect"]:
    """Return the bbox of every individual path segment across all drawings.

    PyMuPDF groups many strokes that share a style into ONE drawing object whose
    ``rect`` is the combined bounding box, so counting drawings under-counts a
    structure's real stroke population (a whole benzene ring + bonds can be a
    single drawing). Descending to each drawing's ``items`` recovers the true
    per-segment population — the signal that tells a dense structure/formula from
    a sparse rule-merge. Each line/curve/rect item contributes its own bbox; a
    degenerate (zero-area) line still contributes via its endpoints.
    """

    segs: list[fitz.Rect] = []
    # A perfectly axis-aligned stroke has zero extent in one dimension, and an
    # empty rect never reports an intersection (so it can't cluster). Inflate
    # each segment by a hairline so neighbouring strokes still merge.
    eps = 0.5

    def _seg(x0: float, y0: float, x1: float, y1: float) -> "fitz.Rect":
        if x1 - x0 < eps:
            mid = (x0 + x1) / 2.0
            x0, x1 = mid - eps, mid + eps
        if y1 - y0 < eps:
            mid = (y0 + y1) / 2.0
            y0, y1 = mid - eps, mid + eps
        return fitz.Rect(x0, y0, x1, y1)

    for d in drawings or []:
        if not isinstance(d, dict):
            continue
        for it in d.get("items") or []:
            if not it:
                continue
            op = it[0]
            try:
                if op == "l":  # line: (p1, p2)
                    p1, p2 = it[1], it[2]
                    x0, x1 = sorted((float(p1.x), float(p2.x)))
                    y0, y1 = sorted((float(p1.y), float(p2.y)))
                    segs.append(_seg(x0, y0, x1, y1))
                elif op == "re":  # rectangle
                    r = fitz.Rect(it[1])
                    segs.append(_seg(float(r.x0), float(r.y0), float(r.x1), float(r.y1)))
                elif op in ("c", "qu"):  # bezier / quad — use its point bbox
                    pts = [p for p in it[1:] if hasattr(p, "x")]
                    if pts:
                        xs = [float(p.x) for p in pts]
                        ys = [float(p.y) for p in pts]
                        segs.append(_seg(min(xs), min(ys), max(xs), max(ys)))
            except Exception:  # pragma: no cover - defensive
                continue
    return segs


def _stroke_rides_text(r: "fitz.Rect", text_rects: list[tuple[float, float, float, float]]) -> bool:
    """True if a stroke sits on/under a text line (an underline / strikethrough).

    Such strokes are text decoration, not structural figure strokes, so they are
    excluded from the dense-figure population — otherwise a block of bold,
    underlined labels could masquerade as a chemical structure.
    """

    rx0, ry0, rx1, ry1 = float(r.x0), float(r.y0), float(r.x1), float(r.y1)
    rmid = (ry0 + ry1) / 2.0
    rw = max(rx1 - rx0, 0.0)
    for tx0, ty0, tx1, ty1 in text_rects:
        overlap_x = min(rx1, tx1) - max(rx0, tx0)
        if overlap_x <= 0 or (rw > 0 and overlap_x < 0.3 * rw):
            continue
        line_h = ty1 - ty0
        if line_h <= 0:
            continue
        # Within the line band or just below its baseline.
        if (ty0 - 0.25 * line_h) <= rmid <= (ty1 + 0.5 * line_h):
            return True
    return False


def _is_dense_stroke_figure(
    cluster: "fitz.Rect",
    stroke_segs: list["fitz.Rect"],
    page_w: float,
    page_h: float,
    text_rects: list[tuple[float, float, float, float]],
) -> bool:
    """True if a cluster is a genuine diagram/formula/structure by stroke count.

    Used to *override* the text-overlap rejection for the figures that
    legitimately contain text: a chemical structure (benzene ring + bond lines +
    atom labels), a reaction scheme (arrows + reagents), or a display equation
    (fraction bars, radicals, brackets + symbols). These are built from MANY
    SHORT strokes sitting in whitespace, unlike a phantom rule-merge — a few LONG
    column dividers / underlines that merely happen to wrap a paragraph. We count
    the individual path segments whose centre falls inside the cluster, *ignoring
    strokes that ride on a text line* (underlines/strikethroughs are text
    decoration, not structure), and require a meaningful population dominated by
    short strokes. So a block of underlined labels is never mistaken for a
    structure, while a real diagram/formula is rescued.
    """

    short_max_w = _SHORT_STROKE_MAX_FRAC * page_w
    short_max_h = _SHORT_STROKE_MAX_FRAC * page_h

    inside = 0
    short = 0
    for r in stroke_segs:
        cx = (r.x0 + r.x1) / 2.0
        cy = (r.y0 + r.y1) / 2.0
        if not (cluster.x0 <= cx <= cluster.x1 and cluster.y0 <= cy <= cluster.y1):
            continue
        if _stroke_rides_text(r, text_rects):
            continue
        inside += 1
        if r.width <= short_max_w and r.height <= short_max_h:
            short += 1

    if inside < _DENSE_FIGURE_MIN_STROKES:
        return False
    return (short / inside) >= _DENSE_FIGURE_SHORT_FRAC


def _cluster_rects(rects: list["fitz.Rect"], page_h: float) -> list["fitz.Rect"]:
    """Merge drawing rects that are close together into figure clusters.

    Rects are merged greedily: each new rect joins an existing cluster when it
    overlaps or sits within ``_CLUSTER_GAP_FRAC`` of the cluster's current
    bounding box, otherwise it seeds a new cluster. Diagram strokes (close
    together) collapse into one cluster; well-separated graphics stay distinct.
    """

    gap = _CLUSTER_GAP_FRAC * page_h
    clusters: list[fitz.Rect] = []

    for rect in sorted(rects, key=lambda r: (r.y0, r.x0)):
        placed = False
        for i, cluster in enumerate(clusters):
            expanded = fitz.Rect(
                cluster.x0 - gap, cluster.y0 - gap, cluster.x1 + gap, cluster.y1 + gap
            )
            if expanded.intersects(rect):
                clusters[i] = cluster | rect  # union
                placed = True
                break
        if not placed:
            clusters.append(fitz.Rect(rect))

    # A second pass merges clusters that grew into each other.
    merged = True
    while merged:
        merged = False
        out: list[fitz.Rect] = []
        for rect in clusters:
            joined = False
            for i, existing in enumerate(out):
                expanded = fitz.Rect(
                    existing.x0 - gap, existing.y0 - gap, existing.x1 + gap, existing.y1 + gap
                )
                if expanded.intersects(rect):
                    out[i] = existing | rect
                    joined = True
                    merged = True
                    break
            if not joined:
                out.append(fitz.Rect(rect))
        clusters = out

    return clusters


def extract_figures_for_page(page: "fitz.Page", page_num: int) -> list[FigureRegion]:
    """Return the figure regions on a single PDF page.

    Combines embedded images and clustered vector drawings, filtering out tiny
    inline marks, thin rules, and margin furniture.
    """

    rect = page.rect
    page_w = float(rect.width)
    page_h = float(rect.height)
    if page_w <= 0 or page_h <= 0:
        return []

    page_area = page_w * page_h
    figures: list[FigureRegion] = []

    # Vertical bands occupied by app/website branding (hyperlinks + branding
    # text lines). A logo or icon riding in one of these rows is furniture, not
    # a question figure, so figures overlapping a band are dropped.
    branding_bands: list[tuple[float, float]] = list(branding_link_bands(page))
    try:
        text_dict = page.get_text("dict")
        for block in text_dict.get("blocks", []) or []:
            if not isinstance(block, dict) or block.get("type") not in (None, 0):
                continue
            for line in block.get("lines", []) or []:
                spans = line.get("spans", []) or []
                txt = "".join(str(s.get("text", "")) for s in spans).strip()
                if not txt or not is_branding_text(txt):
                    continue
                bbox = line.get("bbox")
                if bbox and len(bbox) == 4:
                    branding_bands.append((float(bbox[1]), float(bbox[3])))
    except Exception:  # pragma: no cover - defensive
        pass

    band_pad = 0.02 * page_h

    def _in_branding_band(y0: float, y1: float) -> bool:
        return any(
            y0 < b1 + band_pad and y1 > b0 - band_pad for b0, b1 in branding_bands
        )

    # --- Embedded raster images -------------------------------------------
    try:
        image_infos = page.get_image_info()
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("get_image_info_failed page=%s error=%s", page_num, str(exc))
        image_infos = []

    for info in image_infos or []:
        r = _rect_or_none(info.get("bbox") if isinstance(info, dict) else None)
        if r is None:
            continue
        if (r.width * r.height) / page_area < _MIN_IMAGE_AREA_FRAC:
            continue
        if _in_margin(r, page_h):
            continue
        if _in_branding_band(float(r.y0), float(r.y1)):
            continue
        figures.append(
            FigureRegion(
                page_num=page_num,
                y_top=float(r.y0),
                y_bottom=float(r.y1),
                x_left=float(r.x0),
                x_right=float(r.x1),
            )
        )

    # --- Vector drawings ---------------------------------------------------
    try:
        drawings = page.get_drawings()
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("get_drawings_failed page=%s error=%s", page_num, str(exc))
        drawings = []

    draw_rects: list[fitz.Rect] = []
    for d in drawings or []:
        r = _rect_or_none(d.get("rect") if isinstance(d, dict) else None)
        if r is None:
            continue
        draw_rects.append(r)

    # Per-segment stroke bboxes (descending into each drawing's path items), used
    # to recognise a dense structure/formula/reaction that legitimately contains
    # text and would otherwise be rejected by the text-overlap guard.
    stroke_segs = _stroke_segments(drawings)

    # Cluster over both the drawing bounding boxes AND the individual stroke
    # segments. Line-art figures (chemical structures, reaction schemes, display
    # equations) are built from perfectly axis-aligned strokes whose bounding box
    # is zero in one dimension, so ``_rect_or_none`` drops them from
    # ``draw_rects`` and the cluster never forms. The stroke segments preserve
    # each line's single-axis extent, so adding them lets those figures cluster.
    cluster_input = draw_rects + stroke_segs

    min_w = _MIN_FIGURE_WIDTH_FRAC * page_w
    min_h = _MIN_FIGURE_HEIGHT_FRAC * page_h
    max_w = _MAX_FIGURE_WIDTH_FRAC * page_w
    max_h = _MAX_FIGURE_HEIGHT_FRAC * page_h

    # Body-text line boxes, used to reject vector clusters that merely wrap text
    # (decorative rules / note-box borders) instead of being a real diagram.
    text_rects = _text_line_rects(page)

    for cluster in _cluster_rects(cluster_input, page_h):
        # A diagram has real 2-D extent; a rule/underline is thin in one axis.
        if cluster.width < min_w or cluster.height < min_h:
            continue
        # A near-full-page cluster is a page/card border, not a figure.
        if cluster.width >= max_w and cluster.height >= max_h:
            continue
        if _in_margin(cluster, page_h):
            continue
        # A cluster that encloses body text is decorative ruling around a
        # paragraph (or several merged rules), not a diagram. Folding it into a
        # crop would balloon the crop across columns and slice the text, so skip
        # — UNLESS the cluster is a dense population of short strokes, which is
        # the signature of a real chemical structure / reaction scheme / display
        # equation. Those legitimately contain text (atom labels, reagents,
        # symbols) yet must grow the crop, so they override the text guard.
        if _encloses_body_text(cluster, text_rects) and not _is_dense_stroke_figure(
            cluster, stroke_segs, page_w, page_h, text_rects
        ):
            continue
        figures.append(
            FigureRegion(
                page_num=page_num,
                y_top=float(cluster.y0),
                y_bottom=float(cluster.y1),
                x_left=float(cluster.x0),
                x_right=float(cluster.x1),
            )
        )

    # --- Bordered content note-boxes --------------------------------------
    # Asides framed in a thin rectangle ("Additional Information", "PW ONLYIAS
    # SUPER HINT", "Extra Edge") enclose real body text, so the generic vector
    # path above rejects them as text-wrapping rules. They ARE part of the
    # solution, though, and their bottom border sits just below the last text
    # line — so unless the crop grows to the frame, the box is sliced and its
    # final line is cut. We emit each frame as a region so the owning question
    # grows its crop to contain the whole box.
    try:
        for box in detect_content_boxes(page):
            if _in_margin(box, page_h):
                continue
            if box.width >= _MAX_FIGURE_WIDTH_FRAC * page_w and box.height >= _MAX_FIGURE_HEIGHT_FRAC * page_h:
                continue
            figures.append(
                FigureRegion(
                    page_num=page_num,
                    y_top=float(box.y0),
                    y_bottom=float(box.y1),
                    x_left=float(box.x0),
                    x_right=float(box.x1),
                )
            )
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("content_box_extract_failed page=%s error=%s", page_num, str(exc))

    # --- Data tables ------------------------------------------------------
    # A question's table (truth table, "Column-I / Column-II" matching grid,
    # reagent list, value matrix, chemical-reaction grid) is a *grid of text*,
    # so the generic vector path above rejects it via ``_encloses_body_text``.
    # PyMuPDF's table finder recovers it from the grid's own ruling, and we emit
    # the whole grid as a region so the owning question grows its crop to contain
    # the entire table instead of slicing it at the surrounding prose.
    try:
        for tbl in detect_tables(page):
            if _in_margin(tbl, page_h):
                continue
            if (
                tbl.width >= _MAX_FIGURE_WIDTH_FRAC * page_w
                and tbl.height >= _MAX_FIGURE_HEIGHT_FRAC * page_h
            ):
                continue
            if _in_branding_band(float(tbl.y0), float(tbl.y1)):
                continue
            figures.append(
                FigureRegion(
                    page_num=page_num,
                    y_top=float(tbl.y0),
                    y_bottom=float(tbl.y1),
                    x_left=float(tbl.x0),
                    x_right=float(tbl.x1),
                )
            )
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("table_extract_failed page=%s error=%s", page_num, str(exc))

    return figures


def _page_dims(page: "fitz.Page") -> tuple[float, float]:
    rect = page.rect
    return float(rect.width), float(rect.height)


def filter_watermark_figures(
    figures: list[FigureRegion],
    page_dims: dict[int, tuple[float, float]],
) -> list[FigureRegion]:
    """Drop background-watermark figures from a document-wide figure list.

    A watermark (a faint brand logo printed behind the text on every page) is
    extracted as a large embedded image, so without this it would be folded into
    whatever question vertically surrounds it — ballooning that crop to the
    watermark's full height and dragging in unrelated page furniture below it.

    A figure is classed as a watermark when an equivalent figure (same
    page-relative position within :data:`_WATERMARK_POS_TOL_FRAC`) appears on at
    least half the document's pages. Genuine diagrams never repeat at the exact
    same spot across the paper, so position-stable repetition is a reliable
    signal that is independent of the figure's size or content.
    """

    if not figures:
        return figures

    total_pages = len(page_dims) or 1

    def _norm_box(fig: FigureRegion) -> "tuple[float, float, float, float] | None":
        dims = page_dims.get(fig.page_num)
        if not dims:
            return None
        w, h = dims
        if w <= 0 or h <= 0:
            return None
        return (fig.x_left / w, fig.y_top / h, fig.x_right / w, fig.y_bottom / h)

    normed = [(_norm_box(f), f) for f in figures]

    def _same(a: tuple, b: tuple) -> bool:
        return all(abs(a[i] - b[i]) <= _WATERMARK_POS_TOL_FRAC for i in range(4))

    threshold = max(_WATERMARK_MIN_PAGES, round(total_pages * _WATERMARK_PAGE_FRACTION))

    kept: list[FigureRegion] = []
    for box, fig in normed:
        if box is None:
            kept.append(fig)
            continue
        pages_with_match = {
            other.page_num
            for other_box, other in normed
            if other_box is not None and _same(box, other_box)
        }
        if len(pages_with_match) >= threshold:
            # Repeats at the same spot across the document → watermark, drop it.
            continue
        kept.append(fig)

    return kept


def extract_figures(doc: "fitz.Document") -> list[FigureRegion]:
    """Return figure regions for every page of a document.

    Background watermarks (a logo repeated at the same position on every page)
    are filtered out so they are never folded into a question crop.
    """

    figures: list[FigureRegion] = []
    page_dims: dict[int, tuple[float, float]] = {}
    for page_idx in range(doc.page_count):
        page = doc.load_page(page_idx)
        page_num = page_idx + 1
        page_dims[page_num] = _page_dims(page)
        figures.extend(extract_figures_for_page(page, page_num))
    return filter_watermark_figures(figures, page_dims)
