"""Optional offline/local ML question detector.

This tier is intentionally adapter-shaped. Qpic's cropper needs whole
question/solution boxes, while general document parsers often emit lower-level
text/table/formula blocks. A future fine-tuned Qpic model can therefore be
plugged in either as:

* an ONNX object detector whose labels include ``question`` / ``solution``; or
* a local command that runs any bundled model stack and returns the same JSON.

No network calls are made here. If no local model/command is available, the
detector reports unavailable and the existing text/OCR/AI flow is unchanged.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shlex
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional

from PIL import Image

from ...config import Settings
from ...models.schemas import DetectedQuestion, QuestionSegment

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parents[3]

QUESTION_LABELS = {
    "q",
    "question",
    "questions",
    "mcq",
    "mcq_question",
    "question_box",
    "question_block",
    "questionanswerblock",
    "question_answer_block",
    "question-answer-block",
    "question answer block",
}
SOLUTION_LABELS = {
    "s",
    "solution",
    "solutions",
    "answer_block",
    "answer-block",
    "answer block",
    "answer_solution",
    "explanation",
    "solution_box",
    "description",
    "solution_block",
    "answer_explanation",
}


@dataclass(frozen=True)
class _Box:
    page: int
    x1: float
    y1: float
    x2: float
    y2: float
    score: float
    label: str
    q_num: Optional[str] = None


class LocalMLDetector:
    """Offline detector for whole MCQ regions."""

    def __init__(
        self,
        *,
        enabled: bool,
        model_name: str,
        model_path: Optional[str],
        labels_path: Optional[str],
        command: Optional[str],
        confidence: float,
        input_size: int,
        timeout_seconds: int,
    ) -> None:
        self.enabled = enabled
        self.model_name = model_name.strip() or "local-ml"
        self.model_path = self._resolve_path(model_path)
        self.labels_path = self._resolve_path(labels_path)
        self.command = (command or "").strip()
        self.confidence = max(0.0, min(1.0, float(confidence)))
        self.input_size = max(320, int(input_size or 1024))
        self.timeout_seconds = max(10, int(timeout_seconds or 120))
        self._session: Any = None
        self._labels: Optional[dict[int, str]] = None
        self._status: Optional[str] = None

    @classmethod
    def from_settings(cls, settings: Settings) -> "LocalMLDetector":
        return cls(
            enabled=bool(settings.LOCAL_ML_ENABLED),
            model_name=settings.LOCAL_ML_MODEL_NAME,
            model_path=settings.LOCAL_ML_MODEL_PATH,
            labels_path=settings.LOCAL_ML_LABELS_PATH,
            command=settings.LOCAL_ML_COMMAND,
            confidence=settings.LOCAL_ML_CONFIDENCE,
            input_size=settings.LOCAL_ML_INPUT_SIZE,
            timeout_seconds=settings.API_TIMEOUT_SECONDS,
        )

    @staticmethod
    def _resolve_path(value: Optional[str]) -> Optional[Path]:
        if not value:
            return None
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = PROJECT_ROOT / path
        return path.resolve()

    def is_available(self) -> bool:
        """True when a local detector can run without downloading anything."""

        if not self.enabled:
            self._status = "disabled"
            return False
        if self.command:
            self._status = "command"
            return True
        if not self.model_path or not self.model_path.exists():
            self._status = "model_missing"
            return False
        if self.model_path.suffix.lower() == ".pt":
            try:
                import ultralytics  # noqa: F401
            except Exception as exc:
                self._status = f"ultralytics_missing: {exc}"
                return False
            self._status = "ultralytics"
            return True
        try:
            import onnxruntime  # noqa: F401
        except Exception as exc:
            self._status = f"onnxruntime_missing: {exc}"
            return False
        self._status = "onnx"
        return True

    @property
    def status(self) -> str:
        if self._status is None:
            self.is_available()
        return self._status or "unknown"

    async def detect(
        self,
        page_images: list[Image.Image],
        settings: Settings,
        *,
        marker_style: str = "auto",
        confidence: Optional[float] = None,
        layout_columns: Optional[int] = None,
    ) -> list[DetectedQuestion]:
        """Run the local detector and return whole question/solution regions."""

        if not page_images or not self.is_available():
            return []

        old_confidence = self.confidence
        if confidence is not None:
            self.confidence = max(0.0, min(1.0, float(confidence)))

        try:
            if self.command:
                return await asyncio.to_thread(
                    self._detect_with_command, page_images, marker_style, layout_columns
                )
            if self.model_path and self.model_path.suffix.lower() == ".pt":
                return await asyncio.to_thread(self._detect_with_ultralytics, page_images, layout_columns)
            return await asyncio.to_thread(self._detect_with_onnx, page_images, layout_columns)
        finally:
            self.confidence = old_confidence

    def _detect_with_ultralytics(
        self, page_images: list[Image.Image], layout_columns: Optional[int] = None
    ) -> list[DetectedQuestion]:
        """Run an Ultralytics YOLO detector trained on question-paper regions."""

        if not self.model_path:
            return []
        try:
            from ultralytics import YOLO
        except Exception as exc:
            logger.warning("local_ml_ultralytics_import_failed error=%s", str(exc))
            return []

        try:
            model = YOLO(str(self.model_path))
        except Exception as exc:
            logger.warning(
                "local_ml_ultralytics_load_failed model=%s error=%s",
                self.model_path,
                str(exc),
            )
            return []

        boxes: list[_Box] = []
        try:
            results = model.predict(
                [img.convert("RGB") for img in page_images],
                imgsz=self.input_size,
                conf=self.confidence,
                verbose=False,
                device="cpu",
            )
        except Exception as exc:
            logger.warning("local_ml_ultralytics_infer_failed error=%s", str(exc))
            return []

        names_raw = getattr(model, "names", {}) or {}
        names = {
            int(k): str(v).strip().lower()
            for k, v in (names_raw.items() if isinstance(names_raw, dict) else enumerate(names_raw))
        }

        for page_no, result in enumerate(results, start=1):
            result_boxes = getattr(result, "boxes", None)
            if result_boxes is None:
                continue
            xyxy = getattr(result_boxes, "xyxy", None)
            conf = getattr(result_boxes, "conf", None)
            cls = getattr(result_boxes, "cls", None)
            if xyxy is None or conf is None or cls is None:
                continue
            try:
                rows = xyxy.cpu().tolist()
                scores = conf.cpu().tolist()
                classes = cls.cpu().tolist()
            except Exception:
                continue
            for coords, score, class_id in zip(rows, scores, classes):
                label = names.get(int(class_id), str(int(class_id))).strip().lower()
                if label not in QUESTION_LABELS and label not in SOLUTION_LABELS:
                    continue
                if len(coords) < 4:
                    continue
                x1, y1, x2, y2 = [float(v) for v in coords[:4]]
                if x2 <= x1 or y2 <= y1:
                    continue
                boxes.append(
                    _Box(
                        page=page_no,
                        x1=x1,
                        y1=y1,
                        x2=x2,
                        y2=y2,
                        score=float(score),
                        label=label,
                    )
                )

        kept = self._nms(boxes)
        return self._questions_from_boxes(kept, page_images=page_images, layout_columns=layout_columns)

    def _detect_with_command(
        self, page_images: list[Image.Image], marker_style: str, layout_columns: Optional[int] = None
    ) -> list[DetectedQuestion]:
        """Run an external local adapter command.

        The command receives a single JSON file path as the final argument.
        Input shape:

        ``{"pages": [{"page": 1, "image_path": "...", "width": 1000, ...}],
        "output_path": "...", "marker_style": "auto"}``

        It may either print JSON to stdout or write JSON to ``output_path``.
        Accepted output is ``{"questions": [...]}`` or ``{"boxes": [...]}``.
        """

        with tempfile.TemporaryDirectory(prefix="qpic-local-ml-") as tmp:
            tmp_path = Path(tmp)
            pages: list[dict[str, Any]] = []
            for idx, img in enumerate(page_images, start=1):
                rgb = img.convert("RGB")
                image_path = tmp_path / f"page_{idx:04d}.png"
                rgb.save(image_path)
                pages.append(
                    {
                        "page": idx,
                        "image_path": str(image_path),
                        "width": rgb.width,
                        "height": rgb.height,
                    }
                )

            output_path = tmp_path / "output.json"
            input_path = tmp_path / "input.json"
            input_path.write_text(
                json.dumps(
                    {
                        "pages": pages,
                        "output_path": str(output_path),
                        "marker_style": marker_style,
                    }
                ),
                encoding="utf-8",
            )

            cmd = shlex.split(self.command) + [str(input_path)]
            try:
                proc = subprocess.run(
                    cmd,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=self.timeout_seconds,
                )
            except Exception as exc:
                logger.warning("local_ml_command_failed error=%s", str(exc))
                return []

            if proc.returncode != 0:
                logger.warning(
                    "local_ml_command_nonzero code=%s stderr=%s",
                    proc.returncode,
                    proc.stderr[:500],
                )
                return []

            raw = proc.stdout.strip()
            if not raw and output_path.exists():
                raw = output_path.read_text(encoding="utf-8")
            if not raw:
                return []
            try:
                data = json.loads(raw)
            except json.JSONDecodeError as exc:
                logger.warning("local_ml_command_bad_json error=%s", str(exc))
                return []

        return self._coerce_output(data, page_count=len(page_images), page_images=page_images, layout_columns=layout_columns)

    def _detect_with_onnx(self, page_images: list[Image.Image], layout_columns: Optional[int] = None) -> list[DetectedQuestion]:
        """Run a simple ONNX object detector with question/solution labels."""

        if not self.model_path:
            return []
        try:
            import numpy as np
            import onnxruntime as ort
        except Exception as exc:
            logger.warning("local_ml_onnx_import_failed error=%s", str(exc))
            return []

        try:
            if self._session is None:
                self._session = ort.InferenceSession(
                    str(self.model_path), providers=["CPUExecutionProvider"]
                )
            session = self._session
            input_name = session.get_inputs()[0].name
        except Exception as exc:
            logger.warning("local_ml_onnx_load_failed model=%s error=%s", self.model_path, str(exc))
            return []

        boxes: list[_Box] = []
        for page_no, img in enumerate(page_images, start=1):
            rgb = img.convert("RGB")
            original_w, original_h = rgb.size
            tensor_img, scale, pad_x, pad_y = self._letterbox(rgb)
            arr = np.asarray(tensor_img, dtype=np.float32) / 255.0
            arr = np.transpose(arr, (2, 0, 1))[None, ...]
            try:
                outputs = session.run(None, {input_name: arr})
            except Exception as exc:
                logger.warning("local_ml_onnx_infer_failed page=%s error=%s", page_no, str(exc))
                continue
            boxes.extend(
                self._decode_onnx_outputs(
                    outputs,
                    page_no=page_no,
                    original_w=original_w,
                    original_h=original_h,
                    scale=scale,
                    pad_x=pad_x,
                    pad_y=pad_y,
                )
            )

        kept = self._nms(boxes)
        return self._questions_from_boxes(kept, page_images=page_images, layout_columns=layout_columns)

    def _letterbox(self, image: Image.Image) -> tuple[Image.Image, float, float, float]:
        """Resize like YOLO training: preserve aspect ratio and pad to a square."""

        original_w, original_h = image.size
        scale = min(self.input_size / original_w, self.input_size / original_h)
        new_w = max(1, int(round(original_w * scale)))
        new_h = max(1, int(round(original_h * scale)))
        try:
            resized = image.resize((new_w, new_h), Image.Resampling.BILINEAR)
        except AttributeError:  # Pillow < 9
            resized = image.resize((new_w, new_h), Image.BILINEAR)
        canvas = Image.new("RGB", (self.input_size, self.input_size), (114, 114, 114))
        pad_x = (self.input_size - new_w) / 2.0
        pad_y = (self.input_size - new_h) / 2.0
        canvas.paste(resized, (int(round(pad_x)), int(round(pad_y))))
        return canvas, scale, pad_x, pad_y

    def _load_labels(self) -> dict[int, str]:
        if self._labels is not None:
            return self._labels

        labels: dict[int, str] = {0: "question", 1: "solution"}
        if self.labels_path and self.labels_path.exists():
            try:
                raw = json.loads(self.labels_path.read_text(encoding="utf-8"))
                if isinstance(raw, list):
                    labels = {idx: str(value) for idx, value in enumerate(raw)}
                elif isinstance(raw, dict):
                    labels = {int(k): str(v) for k, v in raw.items()}
            except Exception as exc:
                logger.warning("local_ml_labels_load_failed path=%s error=%s", self.labels_path, str(exc))
        self._labels = labels
        return labels

    def _decode_onnx_outputs(
        self,
        outputs: Iterable[Any],
        *,
        page_no: int,
        original_w: int,
        original_h: int,
        scale: float,
        pad_x: float,
        pad_y: float,
    ) -> list[_Box]:
        import numpy as np

        labels = self._load_labels()
        out: list[_Box] = []
        for output in outputs:
            arr = np.asarray(output)
            if arr.size == 0:
                continue
            if arr.ndim == 3 and arr.shape[0] == 1:
                arr = arr[0]
            if arr.ndim != 2:
                continue
            # YOLO exports often use (channels, anchors); DETR-style models use
            # (anchors, channels). Normalize both to row-major detections.
            if arr.shape[0] < arr.shape[1] and arr.shape[0] >= 6:
                arr = arr.T
            if arr.shape[1] < 6:
                continue

            for row in arr:
                parsed = self._parse_detection_row(
                    row,
                    labels=labels,
                    original_w=original_w,
                    original_h=original_h,
                    scale=scale,
                    pad_x=pad_x,
                    pad_y=pad_y,
                )
                if parsed is not None:
                    out.append(parsed.__class__(
                        page=page_no,
                        x1=parsed.x1,
                        y1=parsed.y1,
                        x2=parsed.x2,
                        y2=parsed.y2,
                        score=parsed.score,
                        label=parsed.label,
                    ))
        return out

    def _parse_detection_row(
        self,
        row: Any,
        *,
        labels: dict[int, str],
        original_w: int,
        original_h: int,
        scale: float = 1.0,
        pad_x: float = 0.0,
        pad_y: float = 0.0,
    ) -> Optional[_Box]:
        import numpy as np

        vals = np.asarray(row, dtype=float).ravel()
        if vals.size < 6:
            return None

        coords = vals[:4]
        class_id: int
        score: float
        if vals.size == 6:
            score = float(vals[4])
            class_id = int(round(float(vals[5])))
        else:
            # Support both YOLOv8 [xywh + class scores] and YOLOv5
            # [xywh + objectness + class scores] layouts.
            cls_scores = vals[4:]
            cls_id_v8 = int(np.argmax(cls_scores))
            score_v8 = float(cls_scores[cls_id_v8])

            obj = float(vals[4])
            tail = vals[5:]
            cls_id_v5 = int(np.argmax(tail)) if tail.size else cls_id_v8
            prob_v5 = float(tail[cls_id_v5]) if tail.size else score_v8
            score_v5 = obj * prob_v5 if 0.0 <= obj <= 1.0 else score_v8

            if score_v5 > score_v8:
                score = score_v5
                class_id = cls_id_v5
            else:
                score = score_v8
                class_id = cls_id_v8

        if score < self.confidence:
            return None

        label = labels.get(class_id, str(class_id)).strip().lower()
        if label not in QUESTION_LABELS and label not in SOLUTION_LABELS:
            return None

        x1, y1, x2, y2 = self._coords_to_xyxy(coords)
        safe_scale = scale if scale > 0 else 1.0
        x1 = (x1 - pad_x) / safe_scale
        x2 = (x2 - pad_x) / safe_scale
        y1 = (y1 - pad_y) / safe_scale
        y2 = (y2 - pad_y) / safe_scale

        x1 = max(0.0, min(float(original_w), x1))
        x2 = max(0.0, min(float(original_w), x2))
        y1 = max(0.0, min(float(original_h), y1))
        y2 = max(0.0, min(float(original_h), y2))
        if x2 <= x1 or y2 <= y1:
            return None

        return _Box(
            page=0,
            x1=x1,
            y1=y1,
            x2=x2,
            y2=y2,
            score=score,
            label=label,
        )

    def _coords_to_xyxy(self, coords: Any) -> tuple[float, float, float, float]:
        values = [float(v) for v in coords[:4]]
        normalized = max(abs(v) for v in values) <= 1.5
        if normalized:
            values = [v * self.input_size for v in values]
        cx, cy, w, h = values
        return cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0

    def _coerce_output(
        self,
        data: Any,
        *,
        page_count: int,
        page_images: list[Image.Image],
        layout_columns: Optional[int] = None,
    ) -> list[DetectedQuestion]:
        if isinstance(data, dict) and isinstance(data.get("boxes"), list):
            boxes = []
            for raw in data.get("boxes") or []:
                box = self._coerce_box(raw, page_images=page_images)
                if box is not None:
                    boxes.append(box)
            return self._questions_from_boxes(self._nms(boxes), page_images=page_images, layout_columns=layout_columns)

        if isinstance(data, list):
            raw_questions = data
        elif isinstance(data, dict):
            raw_questions = data.get("questions")
            if raw_questions is None and "segments" in data:
                raw_questions = [data]
        else:
            raw_questions = None
        if not isinstance(raw_questions, list):
            return []

        questions: list[DetectedQuestion] = []
        for idx, raw_q in enumerate(raw_questions, start=1):
            if not isinstance(raw_q, dict):
                continue
            q_num = str(raw_q.get("q_num") or idx).strip()
            segments_in = raw_q.get("segments")
            if not q_num or not isinstance(segments_in, list):
                continue
            segments: list[QuestionSegment] = []
            for raw_seg in segments_in:
                if not isinstance(raw_seg, dict):
                    continue
                try:
                    page = int(raw_seg.get("page"))
                    if page < 1 or page > page_count:
                        continue
                    y0 = float(raw_seg.get("y_start_pct"))
                    y1 = float(raw_seg.get("y_end_pct"))
                    x0 = float(raw_seg.get("x_start_pct", 0.0))
                    x1 = float(raw_seg.get("x_end_pct", 100.0))
                except (TypeError, ValueError):
                    continue
                if y1 <= y0 or x1 <= x0:
                    continue
                segments.append(
                    QuestionSegment(
                        page=page,
                        y_start_pct=self._clamp_pct(y0),
                        y_end_pct=self._clamp_pct(y1),
                        x_start_pct=self._clamp_pct(x0),
                        x_end_pct=self._clamp_pct(x1),
                    )
                )
            if segments:
                questions.append(
                    DetectedQuestion(
                        q_num=q_num,
                        is_solution=bool(raw_q.get("is_solution", False)),
                        segments=segments,
                    )
                )
        return questions

    def _coerce_box(
        self, raw: Any, *, page_images: list[Image.Image]
    ) -> Optional[_Box]:
        if not isinstance(raw, dict):
            return None
        try:
            page = int(raw.get("page", 1))
            if page < 1 or page > len(page_images):
                return None
            img = page_images[page - 1]
            w, h = img.size
            label = str(raw.get("label") or raw.get("class") or "question").strip().lower()
            score = float(raw.get("score", 1.0))
            if score < self.confidence:
                return None
            if {"x1", "y1", "x2", "y2"} <= set(raw):
                x1 = float(raw["x1"])
                y1 = float(raw["y1"])
                x2 = float(raw["x2"])
                y2 = float(raw["y2"])
            else:
                x1 = float(raw.get("x_start_pct", 0.0)) * w / 100.0
                x2 = float(raw.get("x_end_pct", 100.0)) * w / 100.0
                y1 = float(raw.get("y_start_pct", 0.0)) * h / 100.0
                y2 = float(raw.get("y_end_pct", 100.0)) * h / 100.0
        except (TypeError, ValueError):
            return None
        if label not in QUESTION_LABELS and label not in SOLUTION_LABELS:
            return None
        if x2 <= x1 or y2 <= y1:
            return None
        return _Box(page, x1, y1, x2, y2, score, label, str(raw.get("q_num") or "").strip() or None)

    def _questions_from_boxes(
        self, boxes: list[_Box], *, page_images: list[Image.Image], layout_columns: Optional[int] = None
    ) -> list[DetectedQuestion]:
        from collections import defaultdict
        from .base import detect_columns, _column_index

        page_to_boxes = defaultdict(list)
        for box in boxes:
            page_to_boxes[box.page].append(box)

        questions: list[DetectedQuestion] = []
        q_count = 0
        s_count = 0

        pages = sorted(page_to_boxes.keys())
        for page in pages:
            page_boxes = page_to_boxes[page]
            img = page_images[page - 1]
            w, h = img.size

            intervals = [(b.x1, b.x2) for b in page_boxes]
            if layout_columns is not None:
                if layout_columns == 1:
                    cols = [(0.0, w)]
                elif layout_columns == 2:
                    cols = [(0.0, w * 0.5), (w * 0.5, w)]
                else:
                    cols = [(0.0, w / 3.0), (w / 3.0, 2.0 * w / 3.0), (2.0 * w / 3.0, w)]
            else:
                cols = detect_columns(intervals, w)
                if len(cols) != 2 and page_boxes:
                    has_left = any((b.x1 + b.x2) / 2.0 < w * 0.48 for b in page_boxes)
                    has_right = any((b.x1 + b.x2) / 2.0 > w * 0.52 for b in page_boxes)
                    if has_left and has_right:
                        cols = [(0.0, w * 0.5), (w * 0.5, w)]

            is_bilingual = False
            left_by_type = {False: [], True: []}
            right_by_type = {False: [], True: []}

            if len(cols) == 2:
                for b in page_boxes:
                    is_sol = b.label in SOLUTION_LABELS
                    col_idx = _column_index(cols, b.x1, b.x2)
                    if col_idx == 0:
                        left_by_type[is_sol].append(b)
                    else:
                        right_by_type[is_sol].append(b)

                total_pairs = 0
                for is_sol in (False, True):
                    left_sorted = sorted(left_by_type[is_sol], key=lambda b: b.y1)
                    right_sorted = sorted(right_by_type[is_sol], key=lambda b: b.y1)
                    
                    paired_right = set()
                    for l in left_sorted:
                        l_cy = (l.y1 + l.y2) / 2.0
                        for r in right_sorted:
                            if r in paired_right:
                                continue
                            r_cy = (r.y1 + r.y2) / 2.0
                            if abs(l_cy - r_cy) < h * 0.10:
                                total_pairs += 1
                                paired_right.add(r)
                                break
                
                if total_pairs >= 2 or (total_pairs >= 1 and len(page_boxes) <= 4):
                    is_bilingual = True

            if is_bilingual:
                for is_sol in (False, True):
                    left_sorted = sorted(left_by_type[is_sol], key=lambda b: b.y1)
                    right_sorted = sorted(right_by_type[is_sol], key=lambda b: b.y1)

                    paired_r_to_l = {}
                    paired_right = set()
                    for l in left_sorted:
                        l_cy = (l.y1 + l.y2) / 2.0
                        for r in right_sorted:
                            if r in paired_right:
                                continue
                            r_cy = (r.y1 + r.y2) / 2.0
                            if abs(l_cy - r_cy) < h * 0.10:
                                paired_r_to_l[r] = l
                                paired_right.add(r)
                                break

                    box_to_num = {}

                    for l in left_sorted:
                        if is_sol:
                            s_count += 1
                            box_to_num[l] = l.q_num or str(s_count)
                        else:
                            q_count += 1
                            box_to_num[l] = l.q_num or str(q_count)

                    for r in right_sorted:
                        if r in paired_r_to_l:
                            box_to_num[r] = paired_r_to_l[r].q_num or box_to_num[paired_r_to_l[r]]
                        else:
                            if is_sol:
                                s_count += 1
                                box_to_num[r] = r.q_num or str(s_count)
                            else:
                                q_count += 1
                                box_to_num[r] = r.q_num or str(q_count)

                    for b in left_sorted + right_sorted:
                        questions.append(
                            DetectedQuestion(
                                q_num=box_to_num[b],
                                is_solution=is_sol,
                                segments=[
                                    QuestionSegment(
                                        page=b.page,
                                        x_start_pct=self._clamp_pct((b.x1 / w) * 100.0),
                                        x_end_pct=self._clamp_pct((b.x2 / w) * 100.0),
                                        y_start_pct=self._clamp_pct((b.y1 / h) * 100.0),
                                        y_end_pct=self._clamp_pct((b.y2 / h) * 100.0),
                                    )
                                ],
                            )
                        )
            else:
                page_boxes_sorted = sorted(
                    page_boxes,
                    key=lambda b: (_column_index(cols, b.x1, b.x2), b.y1, b.x1)
                )

                for b in page_boxes_sorted:
                    is_sol = b.label in SOLUTION_LABELS
                    if is_sol:
                        s_count += 1
                        q_num = b.q_num or str(s_count)
                    else:
                        q_count += 1
                        q_num = b.q_num or str(q_count)

                    questions.append(
                        DetectedQuestion(
                            q_num=q_num,
                            is_solution=is_sol,
                            segments=[
                                QuestionSegment(
                                    page=b.page,
                                    x_start_pct=self._clamp_pct((b.x1 / w) * 100.0),
                                    x_end_pct=self._clamp_pct((b.x2 / w) * 100.0),
                                    y_start_pct=self._clamp_pct((b.y1 / h) * 100.0),
                                    y_end_pct=self._clamp_pct((b.y2 / h) * 100.0),
                                )
                            ],
                        )
                    )

        return questions


    def _nms(self, boxes: list[_Box], threshold: float = 0.5) -> list[_Box]:
        kept: list[_Box] = []
        for box in sorted(boxes, key=lambda b: b.score, reverse=True):
            if any(
                box.page == other.page
                and box.label == other.label
                and self._iou(box, other) >= threshold
                for other in kept
            ):
                continue
            kept.append(box)
        return sorted(kept, key=lambda b: (b.page, b.y1, b.x1))

    @staticmethod
    def _iou(a: _Box, b: _Box) -> float:
        x1 = max(a.x1, b.x1)
        y1 = max(a.y1, b.y1)
        x2 = min(a.x2, b.x2)
        y2 = min(a.y2, b.y2)
        inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
        if inter <= 0:
            return 0.0
        area_a = max(0.0, a.x2 - a.x1) * max(0.0, a.y2 - a.y1)
        area_b = max(0.0, b.x2 - b.x1) * max(0.0, b.y2 - b.y1)
        union = area_a + area_b - inter
        return inter / union if union > 0 else 0.0

    @staticmethod
    def _clamp_pct(value: float) -> float:
        return max(0.0, min(100.0, float(value)))
