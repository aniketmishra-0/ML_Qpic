from __future__ import annotations

from typing import Any
import pytest
from PIL import Image

from app.config import Settings
from app.services.detector.pipeline import DetectionPipeline
from app.services.detector.paddle_ocr_detector import PaddleOCRDetector, _get_paddle


def test_paddle_is_available_returns_bool() -> None:
    detector = PaddleOCRDetector()
    available = detector.is_available()
    assert isinstance(available, bool)


def test_paddle_detector_mocked(monkeypatch: pytest.MonkeyPatch) -> None:
    detector = PaddleOCRDetector()

    class FakePaddle:
        def ocr(self, arr: Any, cls: bool = True) -> list[Any]:
            return [[
                [
                    [[10, 10], [100, 10], [100, 20], [10, 20]],
                    ("1. Question body here", 0.95)
                ]
            ]]

    monkeypatch.setattr(detector, "is_available", lambda: True)
    
    global _paddle_instance
    monkeypatch.setattr("app.services.detector.paddle_ocr_detector._paddle_instance", FakePaddle())

    img = Image.new("RGB", (800, 600), (255, 255, 255))
    settings = Settings()
    questions = detector.detect([img], settings)

    assert len(questions) == 1
    assert questions[0].q_num == "1"


def test_pipeline_uses_paddle_ocr(monkeypatch: pytest.MonkeyPatch) -> None:
    detector = PaddleOCRDetector()

    called = False

    def mock_detect(*args: Any, **kwargs: Any) -> list[Any]:
        nonlocal called
        called = True
        from app.models.schemas import DetectedQuestion, QuestionSegment
        return [DetectedQuestion(q_num="1", is_solution=False, segments=[QuestionSegment(page=1, y_start_pct=10.0, y_end_pct=20.0, x_start_pct=10.0, x_end_pct=90.0)])]

    monkeypatch.setattr(detector, "is_available", lambda: True)
    monkeypatch.setattr(detector, "detect", mock_detect)

    pipeline = DetectionPipeline(paddle_ocr_detector=detector)
    settings = Settings()

    img = Image.new("RGB", (800, 600), (255, 255, 255))
    
    # Enable via use_paddle_ocr flag
    # Since detect is async, we can run it with asyncio
    import asyncio
    questions, method = asyncio.run(pipeline.detect(
        pdf_source=b"%PDF-1.4",
        page_images=[img],
        settings=settings,
        use_paddle_ocr=True,
    ))

    assert called
    assert method == "ocr"
    assert len(questions) == 1
