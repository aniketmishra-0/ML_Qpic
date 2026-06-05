from PIL import Image
import pytest

from app.services.detector.local_ml_detector import LocalMLDetector


def _detector() -> LocalMLDetector:
    return LocalMLDetector(
        enabled=True,
        model_name="test-local",
        model_path=None,
        labels_path=None,
        command=None,
        confidence=0.35,
        input_size=1024,
        timeout_seconds=30,
    )


def test_coerce_boxes_to_detected_questions() -> None:
    images = [Image.new("RGB", (200, 400), (255, 255, 255))]
    out = _detector()._coerce_output(
        {
            "boxes": [
                {
                    "page": 1,
                    "label": "question",
                    "score": 0.9,
                    "x1": 20,
                    "y1": 40,
                    "x2": 180,
                    "y2": 200,
                }
            ]
        },
        page_count=1,
        page_images=images,
    )

    assert len(out) == 1
    assert out[0].q_num == "1"
    assert out[0].is_solution is False
    seg = out[0].segments[0]
    assert seg.page == 1
    assert seg.x_start_pct == 10.0
    assert seg.x_end_pct == 90.0
    assert seg.y_start_pct == 10.0
    assert seg.y_end_pct == 50.0


def test_hilex_question_answer_block_label_is_question() -> None:
    images = [Image.new("RGB", (100, 100), (255, 255, 255))]
    out = _detector()._coerce_output(
        {
            "boxes": [
                {
                    "page": 1,
                    "label": "question_answer_block",
                    "score": 0.95,
                    "x_start_pct": 0,
                    "x_end_pct": 100,
                    "y_start_pct": 10,
                    "y_end_pct": 40,
                }
            ]
        },
        page_count=1,
        page_images=images,
    )

    assert len(out) == 1
    assert out[0].is_solution is False


def test_missing_local_model_is_unavailable() -> None:
    det = LocalMLDetector(
        enabled=True,
        model_name="missing",
        model_path="vendor/models/nope/model.onnx",
        labels_path=None,
        command=None,
        confidence=0.35,
        input_size=1024,
        timeout_seconds=30,
    )

    assert det.is_available() is False
    assert det.status == "model_missing"


def test_local_ml_detector_two_columns_sorting() -> None:
    # A standard two-column page (non-bilingual) should sort the left column
    # top-to-bottom first, and then the right column.
    images = [Image.new("RGB", (200, 400), (255, 255, 255))]
    out = _detector()._coerce_output(
        {
            "boxes": [
                # Left column (x1 < 100)
                {"page": 1, "label": "question", "score": 0.9, "x1": 10, "y1": 50, "x2": 90, "y2": 150},
                {"page": 1, "label": "question", "score": 0.9, "x1": 10, "y1": 200, "x2": 90, "y2": 300},
                # Right column (x1 >= 100) - vertically offset so they aren't marked as bilingual
                {"page": 1, "label": "question", "score": 0.9, "x1": 110, "y1": 120, "x2": 190, "y2": 180},
                {"page": 1, "label": "question", "score": 0.9, "x1": 110, "y1": 280, "x2": 190, "y2": 350},
            ]
        },
        page_count=1,
        page_images=images,
    )

    # With non-bilingual two-column sorting, they should be numbered:
    # Left column: Q1 (y=50), Q2 (y=200)
    # Right column: Q3 (y=120), Q4 (y=280)
    # Total questions = 4.
    assert len(out) == 4
    
    # Sort them by their q_num (which are strings "1", "2", "3", "4") to check segments
    out_sorted = sorted(out, key=lambda q: int(q.q_num))
    
    assert out_sorted[0].q_num == "1"
    assert out_sorted[0].segments[0].x_start_pct == pytest.approx(5.0) # (10/200)*100
    assert out_sorted[0].segments[0].y_start_pct == pytest.approx(12.5) # (50/400)*100
    
    assert out_sorted[1].q_num == "2"
    assert out_sorted[1].segments[0].x_start_pct == pytest.approx(5.0)
    assert out_sorted[1].segments[0].y_start_pct == pytest.approx(50.0) # (200/400)*100
    
    assert out_sorted[2].q_num == "3"
    assert out_sorted[2].segments[0].x_start_pct == pytest.approx(55.0) # (110/200)*100
    assert out_sorted[2].segments[0].y_start_pct == pytest.approx(30.0) # (120/400)*100
    
    assert out_sorted[3].q_num == "4"
    assert out_sorted[3].segments[0].x_start_pct == pytest.approx(55.0)
    assert out_sorted[3].segments[0].y_start_pct == pytest.approx(70.0) # (280/400)*100


def test_local_ml_detector_bilingual_pairing() -> None:
    # A bilingual two-column page should pair matching left and right column
    # boxes vertically, giving them the same number.
    images = [Image.new("RGB", (200, 400), (255, 255, 255))]
    out = _detector()._coerce_output(
        {
            "boxes": [
                # Left column (English)
                {"page": 1, "label": "question", "score": 0.9, "x1": 10, "y1": 50, "x2": 90, "y2": 150},
                {"page": 1, "label": "question", "score": 0.9, "x1": 10, "y1": 200, "x2": 90, "y2": 300},
                # Right column (Hindi) - matching vertically
                {"page": 1, "label": "question", "score": 0.9, "x1": 110, "y1": 50, "x2": 190, "y2": 150},
                {"page": 1, "label": "question", "score": 0.9, "x1": 110, "y1": 200, "x2": 190, "y2": 300},
            ]
        },
        page_count=1,
        page_images=images,
    )

    # In bilingual layout:
    # - E1 (left, y=50) pairs with H1 (right, y=50) -> both get Q1
    # - E2 (left, y=200) pairs with H2 (right, y=200) -> both get Q2
    # So we get two Q1s and two Q2s in the list.
    assert len(out) == 4
    
    q1_items = [q for q in out if q.q_num == "1"]
    q2_items = [q for q in out if q.q_num == "2"]
    
    assert len(q1_items) == 2
    assert len(q2_items) == 2
    
    # Check that they represent left and right columns respectively
    q1_x_starts = sorted([q.segments[0].x_start_pct for q in q1_items])
    assert q1_x_starts == pytest.approx([5.0, 55.0])
    
    q2_x_starts = sorted([q.segments[0].x_start_pct for q in q2_items])
    assert q2_x_starts == pytest.approx([5.0, 55.0])

