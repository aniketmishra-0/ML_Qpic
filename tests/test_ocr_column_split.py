"""Regression test for the OCR two-column cross-gutter line merge.

On a two-column scanned/photographed MCQ paper (the PW "Arjuna Quiz" layout in
the bug report), Tesseract's page-segmentation mode 6 frequently reads STRAIGHT
ACROSS the column gutter, packing the left and right columns' words into a
single structural line:

    "1. Left question 1 stem ...      5. Right question 5 stem ..."

That one merged row, spanning the full page width, breaks detection three ways:

  * the downstream (line-based) column detector sees only full-width lines, so
    the page looks single-column;
  * every left-column question marker inherits a full-page x-extent, so its
    crop balloons across the page and physically overlaps the right column —
    the "Overlaps another item on the page" warning the user saw on every item;
  * the right column's markers ("5." sitting mid-line) never match a
    question-start pattern, so those questions are silently dropped.

The fix detects the column gutter from the individual WORD boxes (where the
gutter is still empty) and groups words into lines PER COLUMN, so a merged row
is split back into one line per column. Each line then keeps its own narrow
x-extent and surfaces its own marker.

The Tesseract data is synthesised (as in ``test_ocr_detector``) so the test is
deterministic and needs no OCR binary, fonts, or rendering.
"""

from __future__ import annotations

from typing import Any

from app.services.detector.ocr_detector import OCRDetector

# Synthetic "page" geometry: a 1000px-wide page with two columns. The left
# column lives at x≈[40, 430] and the right at x≈[520, 940]; the gutter is the
# empty band around x=475.
PAGE_W = 1000
LEFT_X = 40
RIGHT_X = 520
ROW_H = 24


def _two_column_merged_data() -> dict[str, Any]:
    """Tesseract output where every text row spans BOTH columns (the bug).

    Each visual row contributes its left- and right-column words under the SAME
    (block, par, line) keys — exactly what psm-6 produces when it reads across
    the gutter — so without the column-aware split they merge into one line.
    """

    text: list[str] = []
    top: list[int] = []
    left: list[int] = []
    width: list[int] = []
    height: list[int] = []
    conf: list[str] = []
    block_num: list[int] = []
    par_num: list[int] = []
    line_num: list[int] = []
    word_num: list[int] = []

    def add(word: str, x: int, y: int, w: int, line_idx: int, wnum: int) -> None:
        text.append(word)
        left.append(x)
        top.append(y)
        width.append(w)
        height.append(18)
        conf.append("95")
        block_num.append(1)
        par_num.append(1)
        line_num.append(line_idx)
        word_num.append(wnum)

    # Four rows; each row holds a left-column question and a right-column
    # question, merged into the same Tesseract line.
    pairs = [("1.", "5."), ("2.", "6."), ("3.", "7."), ("4.", "8.")]
    for row, (lmark, rmark) in enumerate(pairs):
        y = 100 + row * ROW_H * 3
        # Left column: marker + a couple of stem words.
        add(lmark, LEFT_X, y, 30, row, 0)
        add("left", LEFT_X + 50, y, 60, row, 1)
        add("stem", LEFT_X + 120, y, 60, row, 2)
        # Right column: marker + a couple of stem words, SAME line_num as left.
        add(rmark, RIGHT_X, y, 30, row, 3)
        add("right", RIGHT_X + 50, y, 70, row, 4)
        add("stem", RIGHT_X + 130, y, 60, row, 5)

    return {
        "text": text,
        "top": top,
        "left": left,
        "width": width,
        "height": height,
        "conf": conf,
        "block_num": block_num,
        "par_num": par_num,
        "line_num": line_num,
        "word_num": word_num,
    }


def test_cross_gutter_lines_split_per_column() -> None:
    """A merged left+right row is split into two lines, one per column."""

    detector = OCRDetector()
    starts, lines, _ = detector._ocr_data_to_starts(
        data=_two_column_merged_data(), page_num=1
    )

    # Every reconstructed line must stay within a single column — none may span
    # the gutter (a line whose right edge crosses well past the page middle from
    # a left-column start is the merged-row bug).
    mid = PAGE_W / 2.0
    for ln in lines:
        spans_gutter = ln.x_left < mid - 50 and ln.x_right > mid + 50
        assert not spans_gutter, (ln.text, ln.x_left, ln.x_right)


def test_all_eight_markers_recovered() -> None:
    """Both columns' markers survive — none are buried mid-merged-line."""

    detector = OCRDetector()
    starts, _, _ = detector._ocr_data_to_starts(
        data=_two_column_merged_data(), page_num=1
    )
    nums = sorted(s.q_num for s in starts)
    assert nums == ["1", "2", "3", "4", "5", "6", "7", "8"], nums


def test_left_markers_keep_left_column_extent() -> None:
    """Left-column markers must not inherit a full-page width (the overlap
    cause). Their x-extent stays in the left half."""

    detector = OCRDetector()
    starts, _, _ = detector._ocr_data_to_starts(
        data=_two_column_merged_data(), page_num=1
    )
    mid = PAGE_W / 2.0
    for s in starts:
        if s.q_num in ("1", "2", "3", "4"):
            assert s.x_right < mid, (s.q_num, s.x_right)
        else:
            assert s.x_left > mid - 60, (s.q_num, s.x_left)


def test_single_column_grouping_unchanged() -> None:
    """A genuine single-column page (no gutter) groups exactly as before: each
    row stays one line, so this change is a no-op off the two-column path."""

    text = ["1.", "Question", "one", "stem"]
    data = {
        "text": text,
        "top": [10, 10, 10, 10],
        "left": [40, 90, 200, 270],
        "width": [30, 90, 60, 60],
        "height": [18, 18, 18, 18],
        "conf": ["95", "95", "95", "95"],
        "block_num": [1, 1, 1, 1],
        "par_num": [1, 1, 1, 1],
        "line_num": [0, 0, 0, 0],
        "word_num": [0, 1, 2, 3],
    }
    detector = OCRDetector()
    starts, lines, _ = detector._ocr_data_to_starts(data=data, page_num=1)

    assert len(lines) == 1
    assert lines[0].text == "1. Question one stem"
    assert [s.q_num for s in starts] == ["1"]
