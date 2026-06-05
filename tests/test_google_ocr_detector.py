from __future__ import annotations

from typing import Any
import pytest
from PIL import Image

from app.config import Settings
from app.services.detector.google_ocr_detector import GoogleOCRDetector


def test_google_ocr_is_available_checks_env(monkeypatch: pytest.MonkeyPatch) -> None:
    detector = GoogleOCRDetector()

    # When credentials env var is missing, it should be false
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)
    assert not detector.is_available()

    # When credentials exist, it should try to initialize
    monkeypatch.setenv("GOOGLE_APPLICATION_CREDENTIALS", "fake-key.json")
    # Mock _init_client to return True
    monkeypatch.setattr(detector, "_init_client", lambda: True)
    assert detector.is_available()


def test_google_ocr_group_words_into_lines() -> None:
    words = [
        {"text": "1.", "x0": 10, "x1": 30, "y0": 10, "y1": 25},
        {"text": "Question", "x0": 40, "x1": 100, "y0": 12, "y1": 26},
        {"text": "Option", "x0": 40, "x1": 90, "y0": 40, "y1": 55},
    ]
    grouped = GoogleOCRDetector._group_words_into_lines(words)

    # We expect 2 lines because Option is vertically separated from the first line
    assert len(grouped) == 2
    assert grouped[0]["text"] == "1. Question"
    assert grouped[1]["text"] == "Option"


def test_google_ocr_detects_questions(monkeypatch: pytest.MonkeyPatch) -> None:
    detector = GoogleOCRDetector()

    # Stub availability
    monkeypatch.setattr(detector, "is_available", lambda: True)

    class FakeVertex:
        def __init__(self, x, y):
            self.x = x
            self.y = y

    class FakeBoundingBox:
        def __init__(self, vertices):
            self.bounding_box = self
            self.vertices = vertices

    class FakeSymbol:
        def __init__(self, text):
            self.text = text

    class FakeWord:
        def __init__(self, text, vertices):
            self.symbols = [FakeSymbol(t) for t in text]
            self.bounding_box = FakeBoundingBox(vertices)

    class FakeParagraph:
        def __init__(self, words):
            self.words = words

    class FakeBlock:
        def __init__(self, paragraphs):
            self.paragraphs = paragraphs

    class FakePage:
        def __init__(self, blocks):
            self.blocks = blocks

    class FakeAnnotation:
        def __init__(self, pages):
            self.pages = pages

    class FakeResponse:
        def __init__(self, annotation):
            self.full_text_annotation = annotation
            self.error = type("Error", (), {"message": None})()

    # Reconstruct text: "1. Question" on first paragraph
    word1 = FakeWord("1.", [FakeVertex(10, 10), FakeVertex(30, 10), FakeVertex(30, 25), FakeVertex(10, 25)])
    word2 = FakeWord("Question", [FakeVertex(40, 10), FakeVertex(100, 10), FakeVertex(100, 25), FakeVertex(40, 25)])
    par1 = FakeParagraph([word1, word2])
    block1 = FakeBlock([par1])
    page1 = FakePage([block1])
    fake_annotation = FakeAnnotation([page1])
    fake_response = FakeResponse(fake_annotation)

    class FakeClient:
        def document_text_detection(self, *args, **kwargs):
            return fake_response

    detector._client = FakeClient()

    img = Image.new("RGB", (800, 600), (255, 255, 255))
    settings = Settings()
    questions = detector.detect([img], settings)

    assert len(questions) == 1
    assert questions[0].q_num == "1"
    assert len(questions[0].segments) == 1


def test_lowercase_q_and_filtering() -> None:
    from app.services.detector.base import match_question_start_ex, QuestionStart, starts_to_questions

    # Test match_question_start_ex returns None for lowercase 'q' immediately followed by a digit
    assert match_question_start_ex("q2") is None
    assert match_question_start_ex("q12") is None
    
    # Test uppercase Q and lowercase 'q' with space/dot still works
    assert match_question_start_ex("Q2") == ("2", True)
    assert match_question_start_ex("q. 2") == ("2", True)
    assert match_question_start_ex("q 12") == ("12", True)

    # Test that a single strong marker does not filter out other weak markers
    starts = [
        QuestionStart(page_num=1, y_top=100.0, q_num="1", is_strong=False),
        QuestionStart(page_num=1, y_top=200.0, q_num="2", is_strong=True),  # single strong marker
        QuestionStart(page_num=1, y_top=300.0, q_num="3", is_strong=False),
    ]
    
    # Check that when we convert starts to questions, all three are kept
    page_heights = {1: 1000.0}
    # (using empty content_lines is fine, it will fall back to using starts)
    questions = starts_to_questions(starts, page_heights, total_pages=1, page_widths={1: 800.0})
    
    assert len(questions) == 3
    q_nums = [q.q_num for q in questions]
    assert "1" in q_nums
    assert "2" in q_nums
    assert "3" in q_nums
