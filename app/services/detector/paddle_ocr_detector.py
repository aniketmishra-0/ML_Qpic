"""Optional Tier 2 detector: PaddleOCR for higher-accuracy multilingual OCR.

Significantly better than Tesseract for Devanagari (Hindi) and mixed-script
documents. Falls back gracefully to :class:`OCRDetector` when the ``paddleocr``
package is not installed.

Install: ``pip install paddleocr paddlepaddle``  (or ``paddlepaddle-gpu``)
"""

from __future__ import annotations

import logging
from typing import Any, Optional

from PIL import Image

from ...config import Settings
from ...models.schemas import DetectedQuestion
from .base import (
    ContentLine,
    QuestionStart,
    is_answer_key_header,
    match_question_start_ex,
    match_solution_header,
    starts_to_questions,
)
from .furniture import is_branding_text

logger = logging.getLogger(__name__)

# Lazy-loaded PaddleOCR instance (heavy init, ~2s first call).
_paddle_instance: Any = None


def _get_paddle(lang: str = "en") -> Any:
    """Return a cached PaddleOCR instance, or None if unavailable."""

    global _paddle_instance
    if _paddle_instance is not None:
        return _paddle_instance
    try:
        import os
        os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
        from paddleocr import PaddleOCR  # type: ignore[import-untyped]

        try:
            _paddle_instance = PaddleOCR(
                use_angle_cls=True,
                lang=lang,
                show_log=False,
                # Use the lightweight PP-OCRv4 model for speed.
                det_model_dir=None,
                rec_model_dir=None,
            )
        except (ValueError, TypeError) as exc:
            if "show_log" in str(exc) or "Unknown argument" in str(exc):
                _paddle_instance = PaddleOCR(
                    use_angle_cls=True,
                    lang=lang,
                    # Use the lightweight PP-OCRv4 model for speed.
                    det_model_dir=None,
                    rec_model_dir=None,
                )
            else:
                raise
        return _paddle_instance
    except ImportError:
        logger.debug("paddleocr not installed — PaddleOCRDetector unavailable")
        return None
    except Exception as exc:
        logger.warning("paddleocr_init_failed error=%s", str(exc))
        return None


class PaddleOCRDetector:
    """Detect questions using PaddleOCR word/line boxes.

    API-compatible with :class:`OCRDetector` so the pipeline can swap them
    transparently.  Supports ``eng`` and ``hi`` (Hindi/Devanagari) via
    PaddlePaddle's PP-OCRv4 models.
    """

    def __init__(self) -> None:
        # Per-page confidence exposed for the pipeline's selective-escalation.
        self.page_confidence: dict[int, float] = {}
        self.page_lines_pct: dict[int, list[tuple[float, float, float, float]]] = {}

    def is_available(self) -> bool:
        """Return True if PaddleOCR is installed and importable."""

        try:
            import paddleocr  # type: ignore[import-untyped]  # noqa: F401

            return True
        except ImportError:
            return False

    def detect(
        self,
        page_images: list[Image.Image],
        settings: Settings,
        render_dpi: Optional[int] = None,
        marker_style: str = "auto",
        layout_columns: Optional[int] = None,
        custom_regex: Optional[str] = None,
    ) -> list[DetectedQuestion]:
        """Detect questions using PaddleOCR line boxes.

        ``marker_style`` restricts which numbering counts as a question:
        ``"auto"`` (default), ``"q"`` (only "Q1"/"Question 1"), or ``"numbered"``
        (only bare "1."/"2)").
        """

        if not page_images:
            return []

        # Map OCR language config to PaddleOCR language codes.
        ocr_lang_cfg = getattr(settings, "OCR_LANGUAGES", "eng") or "eng"
        paddle_lang = self._resolve_paddle_lang(ocr_lang_cfg)

        paddle = _get_paddle(lang=paddle_lang)
        if paddle is None:
            logger.warning("paddleocr_not_available — falling back")
            return []

        self._marker_style = marker_style
        self._custom_regex = custom_regex

        starts: list[QuestionStart] = []
        content_lines: list[ContentLine] = []
        page_heights: dict[int, float] = {}
        page_widths: dict[int, float] = {}
        page_confidence: dict[int, float] = {}

        in_solutions = False

        for page_index, img in enumerate(page_images, start=1):
            in_answer_key = False
            import numpy as np

            # PaddleOCR expects an ndarray (BGR or grayscale).
            arr = np.array(img.convert("RGB"))
            page_heights[page_index] = float(arr.shape[0])
            page_widths[page_index] = float(arr.shape[1])

            try:
                result = paddle.ocr(arr)
            except Exception as exc:
                logger.warning(
                    "paddle_ocr_page_failed page=%s error=%s",
                    page_index,
                    str(exc),
                )
                page_confidence[page_index] = 0.0
                continue

            # PaddleOCR returns [page_result] where page_result is a list of
            # (box, (text, confidence)) tuples, or a list of dictionaries in some versions.
            if result and isinstance(result[0], dict):
                # PaddleX style dict format
                page_dict = result[0]
                rec_texts = page_dict.get('rec_texts', [])
                rec_scores = page_dict.get('rec_scores', [])
                rec_polys = page_dict.get('rec_polys', [])
                page_result = []
                for i in range(len(rec_texts)):
                    text = rec_texts[i]
                    conf = rec_scores[i] if i < len(rec_scores) else 1.0
                    box = rec_polys[i] if i < len(rec_polys) else []
                    page_result.append((box, (text, conf)))
            else:
                # Traditional list of tuples format
                page_result = result[0] if result else []

            if not page_result:
                page_confidence[page_index] = 0.0
                continue

            # Collect confidence for this page.
            confs: list[float] = []
            lines_data: list[dict[str, Any]] = []

            for item in page_result:
                if not item or len(item) < 2:
                    continue
                box = item[0]
                text_conf = item[1]
                if isinstance(text_conf, (tuple, list)):
                    text = text_conf[0]
                    conf = text_conf[1] if len(text_conf) > 1 else 1.0
                else:
                    text = text_conf
                    conf = 1.0
                text = str(text or "").strip()
                if not text:
                    continue

                confs.append(float(conf))

                # box is [[x1,y1],[x2,y2],[x3,y3],[x4,y4]] (quadrilateral).
                xs = [pt[0] for pt in box]
                ys = [pt[1] for pt in box]
                x_left = float(min(xs))
                x_right = float(max(xs))
                y_top = float(min(ys))
                y_bottom = float(max(ys))

                lines_data.append(
                    {
                        "text": text,
                        "y_top": y_top,
                        "y_bottom": y_bottom,
                        "x_left": x_left,
                        "x_right": x_right,
                        "confidence": float(conf),
                    }
                )

            page_confidence[page_index] = (
                (sum(confs) / len(confs) * 100.0) if confs else 0.0
            )

            # Sort lines top-to-bottom, then left-to-right.
            lines_data.sort(key=lambda d: (d["y_top"], d["x_left"]))

            for ld in lines_data:
                text = ld["text"]
                y_top = ld["y_top"]
                y_bottom = ld["y_bottom"]
                x_left = ld["x_left"]
                x_right = ld["x_right"]

                if is_branding_text(text):
                    continue

                if match_solution_header(text):
                    if is_answer_key_header(text):
                        in_answer_key = True
                        in_solutions = False
                    else:
                        in_solutions = True
                        in_answer_key = False
                    continue

                content_lines.append(
                    ContentLine(
                        page_num=page_index,
                        y_top=y_top,
                        y_bottom=y_bottom,
                        x_left=x_left,
                        x_right=x_right,
                        text=text,
                    )
                )

                q_info = (
                    None
                    if in_answer_key
                    else match_question_start_ex(
                        text,
                        self._marker_style,
                        custom_regex=self._custom_regex,
                    )
                )
                if q_info is not None:
                    q_num, is_strong = q_info
                    starts.append(
                        QuestionStart(
                            page_num=page_index,
                            y_top=y_top,
                            q_num=q_num,
                            is_solution=in_solutions,
                            x_left=x_left,
                            x_right=x_right,
                            is_strong=is_strong,
                        )
                    )

        self.page_confidence = page_confidence

        # Build page_lines_pct for review service compatibility.
        page_lines_pct: dict[int, list[tuple[float, float, float, float]]] = {}
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

    @staticmethod
    def _resolve_paddle_lang(ocr_lang_cfg: str) -> str:
        """Map Tesseract-style lang codes to PaddleOCR lang codes.

        PaddleOCR uses ``"en"`` for English, ``"hi"`` for Hindi (Devanagari),
        ``"ch"`` for Chinese, etc.  When multiple languages are configured
        (``"eng+hin"``), prefer Hindi since PP-OCRv4's Hindi model reads
        Latin (English) text well enough — the reverse is not true.
        """

        parts = [p.strip().lower() for p in ocr_lang_cfg.split("+")]
        # Map Tesseract codes → PaddleOCR codes.
        mapping = {
            "eng": "en",
            "hin": "hi",
            "chi_sim": "ch",
            "chi_tra": "chinese_cht",
            "jpn": "japan",
            "kor": "korean",
            "deu": "german",
            "fra": "fr",
            "spa": "es",
        }
        paddle_langs = [mapping.get(p, p) for p in parts]
        # Prefer Hindi model for mixed eng+hin — it handles Latin well.
        if "hi" in paddle_langs:
            return "hi"
        return paddle_langs[0] if paddle_langs else "en"
