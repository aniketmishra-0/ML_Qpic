from __future__ import annotations

import pytest
from app.models.schemas import DetectedQuestion, QuestionSegment
from app.services.detector.base import merge_bilingual_pairs


def test_bilingual_merge_exact_match() -> None:
    # Two items with the same q_num, page, but side-by-side columns
    q1 = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=5.0, x_end_pct=45.0)],
        option_labels="A B C D",
    )
    q2 = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=55.0, x_end_pct=95.0)],
    )

    merged = merge_bilingual_pairs([q1, q2])

    assert len(merged) == 1
    assert merged[0].q_num == "1"
    assert merged[0].other_segments is not None
    assert len(merged[0].other_segments) == 1
    assert merged[0].other_segments[0].x_start_pct == 55.0


def test_bilingual_merge_vertical_alignment_different_numbers() -> None:
    # Q1 exact match exists to establish page 1 is bilingual
    q1_en = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=5.0, x_end_pct=45.0)],
    )
    q1_hi = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=55.0, x_end_pct=95.0)],
    )

    # Q2 is on the left, but on the right it has a different/misread number (like Q4)
    # Their vertical starts are very close (40.0% vs 40.5%)
    q2_left = DetectedQuestion(
        q_num="2",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=40.0, y_end_pct=55.0, x_start_pct=5.0, x_end_pct=45.0)],
    )
    q4_right = DetectedQuestion(
        q_num="4",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=40.5, y_end_pct=55.0, x_start_pct=55.0, x_end_pct=95.0)],
    )

    merged = merge_bilingual_pairs([q1_en, q1_hi, q2_left, q4_right])

    # Should merge q1_en + q1_hi, and merge q2_left + q4_right
    assert len(merged) == 2
    
    # Verify Q2 merge
    q2_merged = next((q for q in merged if q.q_num == "2"), None)
    assert q2_merged is not None
    assert q2_merged.other_segments is not None
    assert len(q2_merged.other_segments) == 1
    assert q2_merged.other_segments[0].x_start_pct == 55.0

    # Verify Q4 is gone (merged into Q2)
    assert not any(q.q_num == "4" for q in merged)


def test_bilingual_no_force_expansion_unpaired() -> None:
    # Q1 establishes page 1 as bilingual
    q1_en = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=5.0, x_end_pct=45.0)],
    )
    q1_hi = DetectedQuestion(
        q_num="1",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=55.0, x_end_pct=95.0)],
    )

    # Q2 is on the left, but there is no question at all on the right
    q2_left = DetectedQuestion(
        q_num="2",
        is_solution=False,
        segments=[QuestionSegment(page=1, y_start_pct=40.0, y_end_pct=55.0, x_start_pct=5.0, x_end_pct=45.0)],
    )

    merged = merge_bilingual_pairs([q1_en, q1_hi, q2_left])

    assert len(merged) == 2
    q2_merged = next((q for q in merged if q.q_num == "2"), None)
    assert q2_merged is not None
    # Verify it was NOT expanded to full page (width should remain 5.0 to 45.0)
    assert q2_merged.segments[0].x_start_pct == 5.0
    assert q2_merged.segments[0].x_end_pct == 45.0
    assert q2_merged.other_segments is None
