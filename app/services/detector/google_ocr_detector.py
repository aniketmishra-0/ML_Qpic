"""Tier 2.3 detector: Google Cloud Vision OCR.

Used as an alternative high-precision OCR tier when enabled.
"""

from __future__ import annotations

import io
import logging
from typing import Any, Optional

from PIL import Image

from ...config import Settings
from ...models.schemas import DetectedQuestion
from .base import (
    ContentLine,
    QuestionStart,
    match_question_start_ex,
    match_solution_header,
    is_answer_key_header,
    starts_to_questions,
)
from .furniture import is_branding_text

logger = logging.getLogger(__name__)


class GoogleOCRDetector:
    """Uses Google Cloud Vision API to perform dense layout-aware OCR."""

    def __init__(self) -> None:
        self._client = None
        self._initialized = False

    def _init_client(self) -> bool:
        if self._initialized:
            return self._client is not None
        try:
            from google.cloud import vision
            self._client = vision.ImageAnnotatorClient()
            self._initialized = True
            return True
        except Exception as exc:
            logger.warning("google_cloud_vision_init_failed error=%s", str(exc))
            self._initialized = True
            return False

    def is_available(self) -> bool:
        """Return True if the Google Cloud Vision library is installed and credentials exist."""
        # Check environment variable
        import os
        if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
            return False
        return self._init_client()

    def detect(
        self,
        page_images: list[Image.Image],
        settings: Settings,
        render_dpi: Optional[int] = None,
        marker_style: str = "auto",
        layout_columns: Optional[int] = None,
        custom_regex: Optional[str] = None,
    ) -> list[DetectedQuestion]:
        """Detect questions using Google Cloud Vision OCR."""
        if not page_images:
            return []

        if not self.is_available():
            logger.warning("google_ocr_not_available or credentials missing")
            return []

        from google.cloud import vision

        starts: list[QuestionStart] = []
        content_lines: list[ContentLine] = []
        page_heights: dict[int, float] = {}
        page_widths: dict[int, float] = {}
        page_lines_pct: dict[int, list[tuple[float, float, float, float]]] = {}

        in_solutions = False

        for page_index, img in enumerate(page_images, start=1):
            in_answer_key = False
            page_heights[page_index] = float(img.height)
            page_widths[page_index] = float(img.width)

            # Convert PIL Image to bytes
            buf = io.BytesIO()
            img.convert("RGB").save(buf, format="JPEG", quality=95)
            content = buf.getvalue()

            try:
                image = vision.Image(content=content)
                response = self._client.document_text_detection(image=image)
                if response.error.message:
                    logger.warning("google_ocr_api_error page=%s error=%s", page_index, response.error.message)
                    continue
                document = response.full_text_annotation
            except Exception as exc:
                logger.warning("google_ocr_page_failed page=%s error=%s", page_index, str(exc))
                continue

            page_starts, page_lines, in_solutions, in_answer_key = self._parse_google_document(
                document=document,
                page_num=page_index,
                in_solutions=in_solutions,
                in_answer_key=in_answer_key,
                marker_style=marker_style,
                custom_regex=custom_regex,
            )

            starts.extend(page_starts)
            content_lines.extend(page_lines)

        # Expose page_lines_pct for smart mode heuristics
        for ln in content_lines:
            ph = page_heights.get(ln.page_num) or 0.0
            pw = page_widths.get(ln.page_num) or 0.0
            if ph <= 0 or pw <= 0:
                continue
            page_lines_pct.setdefault(ln.page_num, []).append(
                (
                    (ln.y_top / ph) * 100.0,
                    (ln.y_bottom / ph) * 100.0,
                    (ln.x_left / pw) * 100.0,
                    (ln.x_right / pw) * 100.0,
                )
            )
        self.page_lines_pct = page_lines_pct

        return starts_to_questions(
            starts=starts,
            page_heights=page_heights,
            total_pages=len(page_images),
            content_lines=content_lines,
            page_widths=page_widths,
            layout_columns=layout_columns,
        )

    def _parse_google_document(
        self,
        document: Any,
        page_num: int,
        in_solutions: bool,
        in_answer_key: bool,
        marker_style: str,
        custom_regex: Optional[str] = None,
    ) -> tuple[list[QuestionStart], list[ContentLine], bool, bool]:
        """Convert Google Vision full_text_annotation into lines and starts."""
        starts: list[QuestionStart] = []
        content_lines: list[ContentLine] = []

        if not document or not document.pages:
            return starts, content_lines, in_solutions, in_answer_key

        # Reconstruct lines within each paragraph
        raw_lines = []
        for block in document.pages[0].blocks:
            for paragraph in block.paragraphs:
                paragraph_words = []
                for word in paragraph.words:
                    word_text = "".join([symbol.text for symbol in word.symbols])
                    if not word_text.strip():
                        continue
                    
                    # Compute word bbox coordinates
                    vertices = word.bounding_box.vertices
                    if not vertices or len(vertices) < 4:
                        continue
                    xs = [v.x for v in vertices if v.x is not None]
                    ys = [v.y for v in vertices if v.y is not None]
                    if not xs or not ys:
                        continue

                    paragraph_words.append({
                        "text": word_text,
                        "x0": min(xs),
                        "x1": max(xs),
                        "y0": min(ys),
                        "y1": max(ys),
                    })

                # Group words into lines
                if paragraph_words:
                    grouped_lines = self._group_words_into_lines(paragraph_words)
                    raw_lines.extend(grouped_lines)

        # Sort raw lines vertically top-to-bottom
        raw_lines.sort(key=lambda l: l["y0"])

        for line in raw_lines:
            line_text = line["text"]
            line_top = line["y0"]
            line_bottom = line["y1"]
            line_left = line["x0"]
            line_right = line["x1"]

            if match_solution_header(line_text):
                if is_answer_key_header(line_text):
                    in_answer_key = True
                    in_solutions = False
                else:
                    in_solutions = True
                    in_answer_key = False
                continue

            if is_branding_text(line_text):
                continue

            content_lines.append(
                ContentLine(
                    page_num=page_num,
                    y_top=float(line_top),
                    y_bottom=float(line_bottom),
                    x_left=float(line_left),
                    x_right=float(line_right),
                    text=line_text,
                )
            )

            q_info = None if in_answer_key else match_question_start_ex(
                line_text,
                marker_style,
                custom_regex=custom_regex,
            )
            if q_info is not None:
                q_num, is_strong = q_info
                starts.append(
                    QuestionStart(
                        page_num=page_num,
                        y_top=float(line_top),
                        q_num=q_num,
                        is_solution=in_solutions,
                        x_left=float(line_left),
                        x_right=float(line_right),
                        is_strong=is_strong,
                    )
                )

        return starts, content_lines, in_solutions, in_answer_key

    @staticmethod
    def _group_words_into_lines(words: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Group words in a paragraph that share the same horizontal baseline."""
        words = sorted(words, key=lambda w: (w["y0"] + w["y1"]) / 2.0)
        lines = []
        for w in words:
            placed = False
            w_center_y = (w["y0"] + w["y1"]) / 2.0
            w_h = w["y1"] - w["y0"]
            for line in lines:
                line_center_y = (line["y0"] + line["y1"]) / 2.0
                line_h = line["y1"] - line["y0"]
                max_h = max(w_h, line_h)
                if abs(w_center_y - line_center_y) < max_h * 0.45:
                    line["words"].append(w)
                    line["y0"] = min(line["y0"], w["y0"])
                    line["y1"] = max(line["y1"], w["y1"])
                    placed = True
                    break
            if not placed:
                lines.append({
                    "y0": w["y0"],
                    "y1": w["y1"],
                    "words": [w]
                })

        result_lines = []
        for line in lines:
            line["words"].sort(key=lambda w: w["x0"])
            result_lines.append({
                "y0": line["y0"],
                "y1": line["y1"],
                "x0": min(w["x0"] for w in line["words"]),
                "x1": max(w["x1"] for w in line["words"]),
                "text": " ".join(w["text"] for w in line["words"]),
            })
        return result_lines
