from __future__ import annotations

from app.services.detector.base import drop_numbered_options, QuestionStart


def test_drop_numbered_options_fallback_and_jitter() -> None:
    # Page 1 has questions 1-5 (no anchors >= 6).
    # Page 2 has questions 6-7 (anchors at 50.0).
    # Since page 1 has no anchors, it should fall back to global margins (from page 2) and adjust for its local jitter.
    
    # In this test, page 1 is shifted to the left by 2px (margin at 48.0 instead of 50.0).
    starts = [
        # Page 1: Questions at 48.0, options at 68.0
        QuestionStart(page_num=1, y_top=10.0, q_num="1", is_strong=False, x_left=48.0),
        QuestionStart(page_num=1, y_top=15.0, q_num="1", is_strong=False, x_left=68.0),  # Option (1)
        QuestionStart(page_num=1, y_top=20.0, q_num="2", is_strong=False, x_left=48.0),
        QuestionStart(page_num=1, y_top=25.0, q_num="2", is_strong=False, x_left=68.0),  # Option (2)
        
        # Page 2: Q6 is at 50.0 (serves as anchor >= 6)
        QuestionStart(page_num=2, y_top=10.0, q_num="6", is_strong=False, x_left=50.0),
        QuestionStart(page_num=2, y_top=15.0, q_num="1", is_strong=False, x_left=70.0),  # Option (1) of Q6
    ]
    
    kept = drop_numbered_options(starts)
    
    # We expect:
    # Page 1: Questions "1" (48.0) and "2" (48.0) should be kept.
    # Page 1: Options at 68.0 should be dropped.
    # Page 2: Question "6" (50.0) should be kept.
    # Page 2: Option at 70.0 should be dropped.
    
    kept_page_1 = [s for s in kept if s.page_num == 1]
    assert len(kept_page_1) == 2
    assert all(s.x_left == 48.0 for s in kept_page_1)
    
    kept_page_2 = [s for s in kept if s.page_num == 2]
    assert len(kept_page_2) == 1
    assert kept_page_2[0].q_num == "6" and kept_page_2[0].x_left == 50.0
