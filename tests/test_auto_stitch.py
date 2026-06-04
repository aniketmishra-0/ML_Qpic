from __future__ import annotations

import fitz
from app.models.schemas import DetectedQuestion, QuestionSegment
from app.services.review_service import (
    find_undercovered_items,
    find_uncovered_head_items,
    find_missing_options_segments,
    build_review_notes,
)


def _q(q_num: str, page: int = 1, y0: float = 5.0, y1: float = 20.0, labels: str = "") -> DetectedQuestion:
    return DetectedQuestion(
        q_num=q_num,
        segments=[QuestionSegment(page=page, y_start_pct=y0, y_end_pct=y1, x_start_pct=10.0, x_end_pct=40.0)],
        option_labels=labels,
    )


def test_find_undercovered_items_suggests_segment() -> None:
    detected = [_q("1", y0=10.0, y1=20.0)]
    # A line of text right below Question 1
    page_lines = {
        1: [
            (21.0, 31.0, 12.0, 38.0),  # Top, bottom, left, right percentages
        ]
    }
    suggestions = find_undercovered_items(detected, page_lines)
    assert (False, "1") in suggestions
    segs = suggestions[(False, "1")]
    assert len(segs) == 1
    assert segs[0].page == 1
    assert segs[0].y_start_pct == 21.0
    assert segs[0].y_end_pct == 31.0
    assert segs[0].x_start_pct == 10.0
    assert segs[0].x_end_pct == 40.0


def test_find_uncovered_head_items_suggests_segment() -> None:
    detected = [_q("1", y0=20.0, y1=30.0)]
    # A line of text right above Question 1
    page_lines = {
        1: [
            (16.0, 18.0, 12.0, 38.0),
        ]
    }
    suggestions = find_uncovered_head_items(detected, page_lines)
    assert (False, "1") in suggestions
    segs = suggestions[(False, "1")]
    assert len(segs) == 1
    assert segs[0].page == 1
    assert segs[0].y_start_pct == 16.0
    assert segs[0].y_end_pct == 18.0


def test_find_missing_options_segments_suggests_option() -> None:
    # Question 1 on Page 1 is missing option D
    detected = [_q("1", page=1, y0=10.0, y1=30.0, labels="ABC")]
    
    # Create a mock PDF with Option D on Page 1 (in Column 2, say x=250..350)
    doc = fitz.open()
    page = doc.new_page(width=500, height=500)
    page.insert_text((250, 150), "(D) Neither 1 nor 2")
    pdf_bytes = doc.write()
    doc.close()
    
    suggestions = find_missing_options_segments(detected, pdf_bytes)
    assert (False, "1") in suggestions
    segs = suggestions[(False, "1")]
    assert len(segs) == 1
    assert segs[0].page == 1
    # Check that it captured Column 2 x coordinates (around 50%)
    assert 48.0 <= segs[0].x_start_pct <= 52.0
    assert 58.0 <= segs[0].x_end_pct <= 75.0


def test_build_review_notes_populates_suggested_segments() -> None:
    # Let's verify build_review_notes puts suggested segments on the notes
    detected = [
        _q("1", y0=10.0, y1=20.0, labels="ABCD"),
        _q("2", y0=30.0, y1=40.0, labels="ABCD"),
        _q("3", y0=50.0, y1=60.0, labels="ABCD"),
    ]
    # We make Question 2 undercovered
    page_lines = {
        1: [
            (41.0, 51.0, 12.0, 38.0),
        ]
    }
    notes = build_review_notes(detected, "text", page_lines=page_lines)
    
    undercovered_notes = [n for n in notes if n.q_num == "2" and n.kind == "incomplete"]
    assert len(undercovered_notes) == 1
    note = undercovered_notes[0]
    assert note.suggested_segments is not None
    assert len(note.suggested_segments) == 1
    assert note.suggested_segments[0].y_start_pct == 41.0
