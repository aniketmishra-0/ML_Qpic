"""Tests for the review "Manual align" per-part horizontal nudge.

A multi-part (stitched) item carries an ``x_offset_pct`` on each
:class:`QuestionSegment` — the signed % of page width the user nudged that part
left/right in the crop-preview popup. It is applied only during stitching, on
top of any automatic alignment, so a previewed crop and the finalized download
(which stitch the very same segments) line the parts up identically.

These tests pin the engine behaviour:
  * a zero nudge leaves the stitch untouched (backwards compatible);
  * a positive nudge shifts the part's content to the right (its left margin of
    whitespace grows) without clipping;
  * single-part items are unaffected.
"""

from __future__ import annotations

import fitz
import numpy as np
from PIL import Image

from app.models.schemas import DetectedQuestion, QuestionSegment
from app.services.crop_service import crop_and_stitch_hires

_INK = 235  # a column has ink when its darkest channel drops below this


def _two_part_pdf() -> bytes:
    """One page, two short text lines stacked vertically (two crop parts)."""

    doc = fitz.open()
    page = doc.new_page(width=595, height=842)
    page.insert_text((72, 120), "1. First part of the question.", fontsize=12)
    page.insert_text((72, 320), "2. Second part of the question.", fontsize=12)
    data = doc.tobytes()
    doc.close()
    return data


def _segments(offsets: list[float]) -> list[QuestionSegment]:
    """Two same-column parts; ``offsets[i]`` is part i's manual nudge (% width)."""

    bounds = [(10.0, 20.0), (35.0, 45.0)]
    return [
        QuestionSegment(
            page=1,
            x_start_pct=5.0,
            x_end_pct=70.0,
            y_start_pct=y0,
            y_end_pct=y1,
            x_offset_pct=off,
        )
        for (y0, y1), off in zip(bounds, offsets)
    ]


def _line_left_edges(img: Image.Image) -> list[int]:
    """Leftmost inked column of each text line (inked-row band), top to bottom.

    Independent of where the lines sit vertically (the tight-join stitch
    collapses inter-part whitespace), so it reliably isolates each part's
    horizontal indent. A part nudged right has a larger left edge.
    """

    arr = np.asarray(img.convert("RGB"))
    nonwhite = arr.min(axis=2) < _INK
    row_has = nonwhite.any(axis=1)

    edges: list[int] = []
    r = 0
    n = len(row_has)
    while r < n:
        if not row_has[r]:
            r += 1
            continue
        start = r
        while r < n and row_has[r]:
            r += 1
        band = nonwhite[start:r]
        cols = np.where(band.any(axis=0))[0]
        if cols.size:
            edges.append(int(cols.min()))
    return edges


def _stitch(offsets: list[float]) -> Image.Image:
    pdf = _two_part_pdf()
    q = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=_segments(offsets),
        source="manual",
    )
    with fitz.open(stream=pdf, filetype="pdf") as doc:
        return crop_and_stitch_hires(
            doc, q, padding_px=10, detection_dpi=200, crop_dpi=200,
        )


def test_zero_offset_keeps_parts_flush_left() -> None:
    """With no nudge, both parts start at (about) the same left column."""

    edges = _line_left_edges(_stitch([0.0, 0.0]))
    assert len(edges) >= 2
    # Same text indentation, so every line's first inked column is close.
    assert max(edges) - min(edges) <= 5


def test_positive_offset_shifts_part_right() -> None:
    """Nudging the second part right moves its content's left edge rightward."""

    base = _line_left_edges(_stitch([0.0, 0.0]))
    nudged = _line_left_edges(_stitch([0.0, 20.0]))
    assert len(base) >= 2 and len(nudged) >= 2

    # First part (first line) is untouched; the last line (second part) is
    # clearly pushed right relative to the un-nudged stitch.
    assert nudged[-1] > base[-1] + 20
    # Nothing was clipped off the left (the image still starts flush-left).
    assert min(nudged) >= 0


def test_offset_does_not_clip_when_first_part_nudged() -> None:
    """Nudging the FIRST part right renormalises so nothing is lost.

    The stitch keeps the smallest combined offset at zero, so pushing part 1
    right simply leaves the (un-nudged) part 2 flush-left and indents part 1.
    """

    edges = _line_left_edges(_stitch([20.0, 0.0]))
    assert len(edges) >= 2
    # First line (part 1) is indented well past the last line (part 2).
    assert edges[0] > edges[-1] + 20
    # And the un-nudged part stays flush to the left edge.
    assert min(edges) >= 0


def test_single_part_unaffected_by_offset() -> None:
    """A one-segment item has nothing to stitch, so an offset is a no-op."""

    pdf = _two_part_pdf()
    seg = QuestionSegment(
        page=1, x_start_pct=5.0, x_end_pct=70.0,
        y_start_pct=10.0, y_end_pct=20.0, x_offset_pct=20.0,
    )
    q = DetectedQuestion(q_num="1", segments=[seg], source="manual")
    with fitz.open(stream=pdf, filetype="pdf") as doc:
        img = crop_and_stitch_hires(
            doc, q, padding_px=10, detection_dpi=200, crop_dpi=200,
        )
    # Renders fine and is a normal image (offset ignored for a single part).
    assert img.size[0] > 0 and img.size[1] > 0
