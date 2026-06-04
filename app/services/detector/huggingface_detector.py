"""Hugging Face online ML model question detector.

Sends page images to a Hugging Face Space or Inference endpoint for fast, cloud-based YOLO/ONNX object detection.
Supports standard Hugging Face object-detection pipeline response formats as well as Qpic's custom JSON formats.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
from typing import Any, Optional

import httpx
from PIL import Image

from ...config import Settings
from ...models.schemas import DetectedQuestion, QuestionSegment
from .ai_detector import merge_detected_questions

logger = logging.getLogger(__name__)

# Standard YOLO / QA block labels used in Qpic
QUESTION_LABELS = {
    "q", "question", "questions", "mcq", "mcq_question", "question_box",
    "question_block", "questionanswerblock", "question_answer_block",
    "question-answer-block", "question answer block"
}
SOLUTION_LABELS = {
    "s", "solution", "solutions", "answer_block", "answer-block",
    "answer block", "answer_solution", "explanation", "solution_box",
    "description", "solution_block", "answer_explanation"
}


class HuggingFaceDetector:
    """Online detector using Hugging Face Space or Inference Endpoint."""

    def __init__(
        self,
        api_url: Optional[str],
        api_token: Optional[str] = None,
        *,
        confidence: float = 0.40,
        timeout_seconds: int = 120,
        max_concurrency: int = 4,
    ) -> None:
        self.api_url = (api_url or "").strip()
        self.api_token = (api_token or "").strip()
        self.confidence = float(confidence)
        self.timeout_seconds = timeout_seconds
        self.max_concurrency = max(1, max_concurrency)
        self.available = bool(self.api_url)

    def is_available(self) -> bool:
        return self.available

    async def detect(
        self,
        page_images: list[Image.Image],
        settings: Settings,
        *,
        marker_style: str = "auto",
    ) -> list[DetectedQuestion]:
        """Send all page images to Hugging Face API for question detection."""
        if not self.is_available() or not page_images:
            return []

        total_pages = len(page_images)
        semaphore = asyncio.Semaphore(self.max_concurrency)

        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            async def _detect_page(idx: int) -> list[DetectedQuestion]:
                page_no = idx + 1
                async with semaphore:
                    # Convert PIL Image to PNG bytes
                    img = await asyncio.to_thread(lambda i=idx: page_images[i])
                    buf = io.BytesIO()
                    img.convert("RGB").save(buf, format="PNG")
                    img_bytes = buf.getvalue()

                    return await self._detect_single_page(
                        client, img_bytes, page_no, img.width, img.height, settings
                    )

            results = await asyncio.gather(
                *(_detect_page(idx) for idx in range(total_pages))
            )

        raw: list[DetectedQuestion] = [q for page in results for q in page]
        return merge_detected_questions(raw)

    async def _detect_single_page(
        self,
        client: httpx.AsyncClient,
        img_bytes: bytes,
        page_no: int,
        img_width: int,
        img_height: int,
        settings: Settings,
    ) -> list[DetectedQuestion]:
        headers = {}
        if self.api_token:
            headers["Authorization"] = f"Bearer {self.api_token}"

        # Standard HF Inference API URL can fail if it expects multipart for custom spaces.
        # We will try both payload formats.
        response = None
        for attempt in range(1, settings.AI_MAX_RETRIES + 1):
            try:
                # Try direct binary payload first (Standard HF inference)
                response = await client.post(
                    self.api_url,
                    headers=headers,
                    content=img_bytes,
                )

                # If we get 400, 415 or 422, try multipart form
                if response.status_code in (400, 415, 422):
                    response = await client.post(
                        self.api_url,
                        headers=headers,
                        files={"file": ("page.png", img_bytes, "image/png")},
                    )

                if response.status_code == 200:
                    data = response.json()
                    return self._parse_response(data, page_no, img_width, img_height)

                logger.warning(
                    "huggingface page=%s attempt=%s status=%s body=%s",
                    page_no, attempt, response.status_code, response.text[:200]
                )
            except Exception as exc:
                logger.warning("huggingface page=%s attempt=%s error=%s", page_no, attempt, str(exc))

            await asyncio.sleep(2 ** (attempt - 1))

        return []

    def _parse_response(
        self,
        data: Any,
        page_no: int,
        img_width: int,
        img_height: int,
    ) -> list[DetectedQuestion]:
        """Parse raw response from standard HF Object Detection API or custom spaces."""
        questions: list[DetectedQuestion] = []

        # 1. Handle standard Hugging Face Object Detection output (list of dicts with 'box' key)
        if isinstance(data, list):
            q_count = 0
            s_count = 0
            for item in data:
                if not isinstance(item, dict):
                    continue
                box = item.get("box")
                label = str(item.get("label", "question")).strip().lower()
                score = float(item.get("score", 1.0))

                if score < self.confidence:
                    continue

                if not isinstance(box, dict):
                    continue

                xmin = float(box.get("xmin", 0))
                ymin = float(box.get("ymin", 0))
                xmax = float(box.get("xmax", 0))
                ymax = float(box.get("ymax", 0))

                # Normalize to absolute pixels if input is 0..1 percentage scale
                if max(xmin, ymin, xmax, ymax) <= 1.001:
                    xmin_abs = xmin * img_width
                    xmax_abs = xmax * img_width
                    ymin_abs = ymin * img_height
                    ymax_abs = ymax * img_height
                else:
                    xmin_abs = xmin
                    xmax_abs = xmax
                    ymin_abs = ymin
                    ymax_abs = ymax

                x_start_pct = max(0.0, min(100.0, (xmin_abs / img_width) * 100.0))
                x_end_pct = max(0.0, min(100.0, (xmax_abs / img_width) * 100.0))
                y_start_pct = max(0.0, min(100.0, (ymin_abs / img_height) * 100.0))
                y_end_pct = max(0.0, min(100.0, (ymax_abs / img_height) * 100.0))

                # Filter out extremely small boxes (headers, page footers, stray text lines)
                if (y_end_pct - y_start_pct) < 3.0 or (x_end_pct - x_start_pct) < 5.0:
                    continue

                is_solution = label in SOLUTION_LABELS
                if is_solution:
                    s_count += 1
                    q_num = str(s_count)
                else:
                    q_count += 1
                    q_num = str(q_count)

                questions.append(
                    DetectedQuestion(
                        q_num=q_num,
                        is_solution=is_solution,
                        segments=[
                            QuestionSegment(
                                page=page_no,
                                x_start_pct=x_start_pct,
                                x_end_pct=x_end_pct,
                                y_start_pct=y_start_pct,
                                y_end_pct=y_end_pct,
                            )
                        ],
                    )
                )

        # 2. Handle Qpic's custom JSON dictionary structures
        elif isinstance(data, dict):
            # Dict containing questions list: {"questions": [...]}
            if "questions" in data and isinstance(data["questions"], list):
                for idx, q in enumerate(data["questions"], start=1):
                    if not isinstance(q, dict):
                        continue

                    score = float(q.get("score", 1.0))
                    if score < self.confidence:
                        continue

                    q_num = str(q.get("q_num") or idx).strip()
                    segments_raw = q.get("segments") or []
                    if not isinstance(segments_raw, list):
                        continue
                    segments = []
                    for seg in segments_raw:
                        if not isinstance(seg, dict):
                            continue
                        y0 = float(seg.get("y_start_pct", 0.0))
                        y1 = float(seg.get("y_end_pct", 100.0))
                        x0 = float(seg.get("x_start_pct", 0.0))
                        x1 = float(seg.get("x_end_pct", 100.0))

                        # Filter out extremely small boxes
                        if (y1 - y0) < 3.0 or (x1 - x0) < 5.0:
                            continue

                        segments.append(
                            QuestionSegment(
                                page=int(seg.get("page", page_no)),
                                x_start_pct=self._clamp_pct(x0),
                                x_end_pct=self._clamp_pct(x1),
                                y_start_pct=self._clamp_pct(y0),
                                y_end_pct=self._clamp_pct(y1),
                            )
                        )
                    if segments:
                        questions.append(
                            DetectedQuestion(
                                q_num=q_num,
                                is_solution=bool(q.get("is_solution", False)),
                                segments=segments,
                            )
                        )

            # Dict containing boxes: {"boxes": [...]}
            elif "boxes" in data and isinstance(data["boxes"], list):
                q_count = 0
                s_count = 0
                for item in data["boxes"]:
                    if not isinstance(item, dict):
                        continue
                    label = str(item.get("label", "question")).strip().lower()
                    score = float(item.get("score", 1.0))
                    if score < self.confidence:
                        continue

                    # Read coordinate styles: x1/y1/x2/y2 or percentages
                    if {"x1", "y1", "x2", "y2"} <= set(item):
                        x1 = float(item["x1"])
                        y1 = float(item["y1"])
                        x2 = float(item["x2"])
                        y2 = float(item["y2"])
                    else:
                        x1 = float(item.get("x_start_pct", 0.0)) * img_width / 100.0
                        y1 = float(item.get("y_start_pct", 0.0)) * img_height / 100.0
                        x2 = float(item.get("x_end_pct", 100.0)) * img_width / 100.0
                        y2 = float(item.get("y_end_pct", 100.0)) * img_height / 100.0

                    x_start_pct = max(0.0, min(100.0, (x1 / img_width) * 100.0))
                    x_end_pct = max(0.0, min(100.0, (x2 / img_width) * 100.0))
                    y_start_pct = max(0.0, min(100.0, (y1 / img_height) * 100.0))
                    y_end_pct = max(0.0, min(100.0, (y2 / img_height) * 100.0))

                    # Filter out extremely small boxes
                    if (y_end_pct - y_start_pct) < 3.0 or (x_end_pct - x_start_pct) < 5.0:
                        continue

                    is_solution = label in SOLUTION_LABELS
                    if is_solution:
                        s_count += 1
                        q_num = str(s_count)
                    else:
                        q_count += 1
                        q_num = str(q_count)

                    questions.append(
                        DetectedQuestion(
                            q_num=q_num,
                            is_solution=is_solution,
                            segments=[
                                QuestionSegment(
                                    page=page_no,
                                    x_start_pct=x_start_pct,
                                    x_end_pct=x_end_pct,
                                    y_start_pct=y_start_pct,
                                    y_end_pct=y_end_pct,
                                )
                            ],
                        )
                    )

        return questions

    @staticmethod
    def _clamp_pct(value: float) -> float:
        return max(0.0, min(100.0, float(value)))

    async def aclose(self) -> None:
        return
