"""Regression test for the full-width title block on a bare-numbered paper.

A two-column MCQ paper (the PW "Arjuna Quiz" layout) prints a full-width title
block above both columns:

    [Arjuna Quiz @Vidyapeeth Test-02 | 11th | 31-05-2026]
    Mathematical Tools (Complete Chapter), Vectors, ... Vector Addition, ...

Because the paper numbers its questions with bare numbers ("1.", "5.") rather
than explicit "Q1" markers, the banner stripper — which only anchored on STRONG
"Q"-markers — never recognised this title as a header. Left in, the full-width
line:

  * inflated the RIGHT column's horizontal content bounds, so its questions'
    crops ballooned to span the whole page width, and
  * was swept into the last left-column question (whose region runs up to the
    first right-column marker), so the title sat inside that crop.

Both effects make left- and right-column crops physically overlap, which the
review step surfaces as "Overlaps another item on the page" on nearly every
item (the reported "pura auto crop gadbad" bug).

The fix recognises a gutter-crossing banner line above the first (weak) marker
on a multi-column page and strips it, while leaving ordinary single-column
cross-page continuation content untouched.
"""

from __future__ import annotations

import fitz

from app.services.detector.text_detector import TextDetector

W, H = 595, 842


def _build_two_column_titled_pdf() -> bytes:
    doc = fitz.open()
    p = doc.new_page(width=W, height=H)

    # Full-width title/header block spanning both columns.
    p.insert_textbox(
        fitz.Rect(40, 28, 555, 78),
        "[Arjuna Quiz @Vidyapeeth Test-02 | 11th | 31-05-2026]  "
        "Mathematical Tools (Complete Chapter), Vectors, Introduction of Vector "
        "and Scalar, Types of Vectors, Vector Addition, Vector Subtraction, "
        "Multiplication of a Vector by a Scalar",
        fontsize=9,
        align=1,
    )

    # Left column: bare-numbered questions 1, 2.
    left_x = 45
    y = 120
    for n in (1, 2):
        p.insert_text((left_x, y), f"{n}.", fontsize=11)
        p.insert_textbox(
            fitz.Rect(left_x + 18, y - 11, 285, y + 40),
            f"Left question {n} stem text that runs a couple of lines here.",
            fontsize=10,
        )
        y += 40
        for opt in ("(1) option a", "(2) option b", "(3) option c", "(4) option d"):
            p.insert_text((left_x + 18, y), opt, fontsize=10)
            y += 16
        y += 20

    # Right column: bare-numbered questions 5, 6.
    right_x = 320
    y = 120
    for n in (5, 6):
        p.insert_text((right_x, y), f"{n}.", fontsize=11)
        p.insert_textbox(
            fitz.Rect(right_x + 18, y - 11, 560, y + 40),
            f"Right question {n} stem text that runs a couple of lines here.",
            fontsize=10,
        )
        y += 40
        for opt in ("(1) option a", "(2) option b", "(3) option c", "(4) option d"):
            p.insert_text((right_x + 18, y), opt, fontsize=10)
            y += 16
        y += 20

    data = doc.tobytes()
    doc.close()
    return data


def _seg_x_overlap(a, b) -> float:
    return min(a.x_end_pct, b.x_end_pct) - max(a.x_start_pct, b.x_start_pct)


def test_full_width_title_not_pulled_into_crops() -> None:
    pdf = _build_two_column_titled_pdf()
    questions = TextDetector().detect(pdf, padding_px=10)

    # The title sits near the very top (y < ~10%). No crop segment may start up
    # there — that would mean the title was swept into a question.
    for q in questions:
        for s in q.segments:
            assert s.y_start_pct > 10.0, (q.q_num, s.y_start_pct)


def test_right_column_crops_stay_in_right_half() -> None:
    pdf = _build_two_column_titled_pdf()
    questions = TextDetector().detect(pdf, padding_px=10)

    # Right-column questions (5, 6) must be confined to the right half. Without
    # the fix the full-width title inflated their bounds to span the page.
    for n in ("5", "6"):
        q = next(q for q in questions if q.q_num == n)
        for s in q.segments:
            assert s.x_start_pct > 45.0, (n, s.x_start_pct)


def test_left_and_right_crops_do_not_overlap() -> None:
    pdf = _build_two_column_titled_pdf()
    questions = TextDetector().detect(pdf, padding_px=10)

    left = [q for q in questions if q.q_num in ("1", "2")]
    right = [q for q in questions if q.q_num in ("5", "6")]
    for a in left:
        for b in right:
            for sa in a.segments:
                for sb in b.segments:
                    if sa.page != sb.page:
                        continue
                    assert _seg_x_overlap(sa, sb) <= 0.0, (
                        a.q_num,
                        b.q_num,
                        sa.x_end_pct,
                        sb.x_start_pct,
                    )


def _build_header_over_right_column_pdf() -> bytes:
    """The title sits above the RIGHT column (not spanning the gutter).

    Mirrors the real Arjuna-quiz screenshot: a bare-numbered two-column paper
    whose title block hangs above the right column only. The last left-column
    question (here Q4, at the bottom of the column) runs in reading order up to
    the first right-column marker (Q5), so without the column-aware header strip
    it swallows that right-column title as a stray top segment — and the right
    column's questions (5,6,7,8) then overlap the left column's crops.
    """

    doc = fitz.open()
    p = doc.new_page(width=W, height=H)

    # Title above the right column only (x from ~50% to the right edge).
    p.insert_textbox(
        fitz.Rect(300, 28, 560, 70),
        "[Arjuna Quiz @Vidyapeeth Test-02 | 11th | 31-05-2026] "
        "Mathematical Tools, Vectors, Vector Addition, Vector Subtraction.",
        fontsize=8,
        align=1,
    )

    # Left column: bare-numbered 1,2,3 then a Q4 near the bottom.
    left_x = 45
    y = 95
    for n in (1, 2, 3):
        p.insert_text((left_x, y), f"{n}.", fontsize=11)
        p.insert_textbox(
            fitz.Rect(left_x + 18, y - 11, 285, y + 30),
            f"Left question {n} stem text.",
            fontsize=10,
        )
        y += 30
        for opt in ("(1) a", "(2) b", "(3) c", "(4) d"):
            p.insert_text((left_x + 18, y), opt, fontsize=10)
            y += 14
        y += 18

    p.insert_text((left_x, y), "4.", fontsize=11)
    p.insert_textbox(
        fitz.Rect(left_x + 18, y - 11, 285, y + 20),
        "If xy^2 = 1, then the value of the expression is:",
        fontsize=10,
    )
    y += 30
    for opt in ("(1) 1", "(2) 2x", "(3) -1", "(4) 2x"):
        p.insert_text((left_x + 18, y), opt, fontsize=10)
        y += 14

    # Right column: 5..8.
    right_x = 320
    y = 95
    for n in (5, 6, 7, 8):
        p.insert_text((right_x, y), f"{n}.", fontsize=11)
        p.insert_textbox(
            fitz.Rect(right_x + 18, y - 11, 560, y + 20),
            f"Right question {n} stem text.",
            fontsize=10,
        )
        y += 26
        for opt in ("(1) a", "(2) b", "(3) c", "(4) d"):
            p.insert_text((right_x + 18, y), opt, fontsize=10)
            y += 14
        y += 16

    data = doc.tobytes()
    doc.close()
    return data


def test_header_above_right_column_not_pulled_into_left_q4() -> None:
    """The right-column title must not be swept into the last left-column
    question (Q4), and Q4 must be a single clean left-column crop."""

    pdf = _build_header_over_right_column_pdf()
    questions = TextDetector().detect(pdf, padding_px=8)

    nums = sorted(q.q_num for q in questions)
    assert nums == ["1", "2", "3", "4", "5", "6", "7", "8"], nums

    q4 = next(q for q in questions if q.q_num == "4")
    # Q4 has exactly one segment, confined to the left column, and never reaches
    # up into the header band (~6-7%).
    assert len(q4.segments) == 1, [(s.x_start_pct, s.y_start_pct) for s in q4.segments]
    seg = q4.segments[0]
    assert seg.x_end_pct < 50.0, seg.x_end_pct
    assert seg.y_start_pct > 10.0, seg.y_start_pct


def test_header_above_right_column_no_cross_column_overlap() -> None:
    """Right-column questions (5-8) stay in the right half and don't overlap the
    left column's crops."""

    pdf = _build_header_over_right_column_pdf()
    questions = TextDetector().detect(pdf, padding_px=8)

    for n in ("5", "6", "7", "8"):
        q = next(q for q in questions if q.q_num == n)
        for s in q.segments:
            assert s.x_start_pct > 45.0, (n, s.x_start_pct)

    left = [q for q in questions if q.q_num in ("1", "2", "3", "4")]
    right = [q for q in questions if q.q_num in ("5", "6", "7", "8")]
    for a in left:
        for b in right:
            for sa in a.segments:
                for sb in b.segments:
                    if sa.page != sb.page:
                        continue
                    assert _seg_x_overlap(sa, sb) <= 0.0, (a.q_num, b.q_num)
