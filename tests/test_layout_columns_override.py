import pytest
from app.services.detector.base import starts_to_questions, QuestionStart, ContentLine


def test_layout_columns_override_1() -> None:
    # 2-column text layout, but layout_columns=1
    # Check that it produces single-column segments spanning full page width.
    starts = [
        QuestionStart(page_num=1, y_top=100, q_num="1", is_solution=False, x_left=50, x_right=80),
        QuestionStart(page_num=1, y_top=400, q_num="2", is_solution=False, x_left=50, x_right=80),
    ]
    lines = [
        ContentLine(page_num=1, y_top=100, y_bottom=120, x_left=50, x_right=200, text="Q1 stem in column 0"),
        ContentLine(page_num=1, y_top=100, y_bottom=120, x_left=550, x_right=700, text="Q1 option in column 1"),
        ContentLine(page_num=1, y_top=400, y_bottom=420, x_left=50, x_right=200, text="Q2 stem in column 0"),
    ]
    
    # 1 Column override
    qs_override_1 = starts_to_questions(
        starts=starts,
        page_heights={1: 1000.0},
        total_pages=1,
        content_lines=lines,
        page_widths={1: 1000.0},
        layout_columns=1,
    )
    
    assert len(qs_override_1) == 2
    q1 = qs_override_1[0]
    assert len(q1.segments) == 1
    seg = q1.segments[0]
    assert seg.x_start_pct == 5.0
    assert seg.x_end_pct == 70.0  # Spans across both columns (includes col 1 text!)


def test_layout_columns_override_2() -> None:
    # 2 Column override
    starts = [
        QuestionStart(page_num=1, y_top=100, q_num="1", is_solution=False, x_left=50, x_right=80),
    ]
    lines = [
        ContentLine(page_num=1, y_top=100, y_bottom=120, x_left=50, x_right=200, text="Q1 stem in column 0"),
    ]
    
    qs_override_2 = starts_to_questions(
        starts=starts,
        page_heights={1: 1000.0},
        total_pages=1,
        content_lines=lines,
        page_widths={1: 1000.0},
        layout_columns=2,
    )
    
    assert len(qs_override_2) == 1
    q1 = qs_override_2[0]
    # Q1 is in column 0, which gets constrained to [0%, 50%]
    assert len(q1.segments) == 1
    seg = q1.segments[0]
    assert seg.x_start_pct == 5.0
    assert seg.x_end_pct == 20.0
