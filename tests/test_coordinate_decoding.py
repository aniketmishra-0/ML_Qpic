import asyncio
from PIL import Image
from app.config import Settings
from app.models.schemas import DetectedQuestion, QuestionSegment
from app.services.detector.local_ml_detector import LocalMLDetector
from app.services.detector.pipeline import DetectionPipeline


def test_coords_to_xyxy_yolo_decoding() -> None:
    detector = LocalMLDetector(
        enabled=True,
        model_name="test-local",
        model_path=None,
        labels_path=None,
        command=None,
        confidence=0.35,
        input_size=1000,
        timeout_seconds=30,
    )

    # YOLO bounding box: [cx, cy, w, h] where cx = 100, cy = 200, w = 150, h = 300.
    # Note that w > cx, which previously triggered the buggy `if c > a and d > b:` check.
    # a, b, c, d would be 100, 200, 150, 300. Since 150 > 100 and 300 > 200, it returned
    # [100, 200, 150, 300] as xyxy instead of converting.
    coords = [100.0, 200.0, 150.0, 300.0]
    x1, y1, x2, y2 = detector._coords_to_xyxy(coords)

    # Expected converted coordinates:
    # x1 = cx - w/2 = 100 - 75 = 25
    # y1 = cy - h/2 = 200 - 150 = 50
    # x2 = cx + w/2 = 100 + 75 = 175
    # y2 = cy + h/2 = 200 + 150 = 350
    assert x1 == 25.0
    assert y1 == 50.0
    assert x2 == 175.0
    assert y2 == 350.0


def test_coords_to_xyxy_normalized() -> None:
    detector = LocalMLDetector(
        enabled=True,
        model_name="test-local",
        model_path=None,
        labels_path=None,
        command=None,
        confidence=0.35,
        input_size=1000,
        timeout_seconds=30,
    )

    # Normalized YOLO coords: [0.1, 0.2, 0.15, 0.3].
    # Max value is <= 1.5, so they should be scaled by input_size (1000).
    coords = [0.1, 0.2, 0.15, 0.3]
    x1, y1, x2, y2 = detector._coords_to_xyxy(coords)

    # After scaling:
    # cx = 100.0, cy = 200.0, w = 150.0, h = 300.0.
    # x1 = 25.0, y1 = 50.0, x2 = 175.0, y2 = 350.0
    assert x1 == 25.0
    assert y1 == 50.0
    assert x2 == 175.0
    assert y2 == 350.0


def test_pipeline_fallback_offline_prefers_better_ocr() -> None:
    class DummyOCRDetector:
        page_confidence = {}
        def detect(self, page_images, settings, render_dpi=None, marker_style="auto", layout_columns=None):
            # OCR finds 3 questions
            return [
                DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, y_start_pct=0.0, y_end_pct=10.0)]),
                DetectedQuestion(q_num="2", segments=[QuestionSegment(page=1, y_start_pct=15.0, y_end_pct=25.0)]),
                DetectedQuestion(q_num="3", segments=[QuestionSegment(page=1, y_start_pct=30.0, y_end_pct=40.0)]),
            ]

    class DummyLocalMLDetector:
        def is_available(self):
            return True
        async def detect(self, page_images, settings, marker_style="auto"):
            # Local ML only finds 1 question (worse/fewer than OCR)
            return [
                DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, y_start_pct=0.0, y_end_pct=10.0)]),
            ]

    pdf_bytes = b"dummy pdf bytes"
    page_images = [Image.new("RGB", (100, 100), (255, 255, 255))]
    settings = Settings(MIN_QUESTIONS_PER_2_PAGES=0.5)

    pipeline = DetectionPipeline(
        ocr_detector=DummyOCRDetector(),
        local_ml_detector=DummyLocalMLDetector(),
        ai_detector=None, # offline/not ai_ready
    )

    questions, method_used = asyncio.run(
        pipeline.detect(pdf_bytes, page_images, settings)
    )

    # It should NOT fall back to local_ml since local_ml has fewer detections than OCR
    assert method_used == "ocr"
    assert len(questions) == 3


def test_resolve_vertical_overlaps() -> None:
    from app.services.detector.pipeline import resolve_vertical_overlaps

    # S8b starts at 10.0 and ends at 90.0
    # S9 starts at 20.0 and ends at 70.0
    # S10a starts at 70.0 and ends at 90.0
    # All are on page 7, column 0 (x_start=0.0, x_end=48.0)
    questions = [
        DetectedQuestion(
            q_num="8",
            is_solution=True,
            segments=[
                QuestionSegment(page=7, x_start_pct=0.0, x_end_pct=48.0, y_start_pct=10.0, y_end_pct=90.0)
            ]
        ),
        DetectedQuestion(
            q_num="9",
            is_solution=True,
            segments=[
                QuestionSegment(page=7, x_start_pct=0.0, x_end_pct=48.0, y_start_pct=20.0, y_end_pct=70.0)
            ]
        ),
        DetectedQuestion(
            q_num="10",
            is_solution=True,
            segments=[
                QuestionSegment(page=7, x_start_pct=0.0, x_end_pct=48.0, y_start_pct=70.0, y_end_pct=90.0)
            ]
        ),
    ]

    resolved = resolve_vertical_overlaps(questions)
    assert len(resolved) == 3
    # S8b (the first one) should be clipped to the start of S9 (20.0)
    assert resolved[0].segments[0].y_end_pct == 20.0
    # S9 should remain unchanged (ends at 70.0)
    assert resolved[1].segments[0].y_end_pct == 70.0
    # S10a should remain unchanged (ends at 90.0)
    assert resolved[2].segments[0].y_end_pct == 90.0


def test_clamp_padding_to_adjacent_lines() -> None:
    from app.services.crop_service import _clamp_padding_to_adjacent_lines

    # Mock page with text blocks representing adjacent lines
    class DummyPage:
        def get_text(self, format_type):
            return {
                "blocks": [
                    {
                        "lines": [
                            # S9 is below S8b: starts at by0 = 120.0
                            {
                                "spans": [{"text": "Q9 Text Solution:"}],
                                "bbox": [10.0, 120.0, 100.0, 135.0]
                            },
                            # S7 is above S8b: ends at by1 = 45.0
                            {
                                "spans": [{"text": "S7 Text Solution..."}],
                                "bbox": [10.0, 30.0, 100.0, 45.0]
                            }
                        ]
                    }
                ]
            }

    page = DummyPage()
    # S8b unpadded region: x in 0..150, y in 50..100
    x0, x1 = 0.0, 150.0
    y0, y1 = 50.0, 100.0

    # Request padding of 20 points top and bottom
    pad_top, pad_bottom = 20.0, 20.0

    clamped_top, clamped_bottom = _clamp_padding_to_adjacent_lines(
        page,
        x0_pts=x0,
        x1_pts=x1,
        y0_pts=y0,
        y1_pts=y1,
        pad_top_pts=pad_top,
        pad_bottom_pts=pad_bottom,
    )

    # Top padding: gap to previous line ending at 45 is: 50 - 45 = 5.
    # So top padding should be clamped from 20 to 5.
    assert clamped_top == 5.0

    # Bottom padding: gap to next line starting at 120 is: 120 - 100 = 20.
    # Since gap 20 >= requested 20, bottom padding remains 20.
    assert clamped_bottom == 20.0

    # If requested bottom padding is 30, it should be clamped to 20
    clamped_top, clamped_bottom2 = _clamp_padding_to_adjacent_lines(
        page,
        x0_pts=x0,
        x1_pts=x1,
        y0_pts=y0,
        y1_pts=y1,
        pad_top_pts=pad_top,
        pad_bottom_pts=30.0,
    )
    assert clamped_bottom2 == 20.0
