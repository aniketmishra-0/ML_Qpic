from PIL import Image

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
