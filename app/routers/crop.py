"""Crop-related API endpoints."""

from __future__ import annotations

import asyncio
import json
import logging
import re
from pathlib import Path
from typing import Any, Optional

import anthropic
import fitz
from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, UploadFile, status
from fastapi.responses import FileResponse, Response

from ..config import Settings
from ..dependencies import (
    build_ai_detector,
    build_local_ml_detector,
    build_paddle_ocr_detector,
    get_anthropic_client_optional,
    get_settings,
)
from ..models.schemas import (
    AnalyzeResponse,
    AnalyzedItem,
    CropPreviewRequest,
    CropResponse,
    FinalizeRequest,
    HealthResponse,
    PageInfo,
    SnapRequest,
    SnapResponse,
    MLConfigRequest,
    MLConfigResponse,
    RegexTestRequest,
    RegexMatchResult,
    RegexTestResponse,
    AlignOffsetsRequest,
    AlignOffsetsResponse,
)
from ..models.schemas import DetectedQuestion
from ..services.crop_service import crop_and_stitch_hires, save_question_image
from ..utils.image_utils import ensure_rgb
from ..services.answer_sheet import count_answered, write_answer_sheet
from ..services.detector.ai_answer_key import read_answer_key_with_ai
from ..services.detector.answer_key import (
    expected_question_numbers,
    extract_answer_key_from_text,
    extract_answers_from_solution_section,
)
from ..services.detector.furniture import collect_document_furniture
from ..services.detector.ocr_detector import OCRDetector
from ..services.detector.google_ocr_detector import GoogleOCRDetector
from ..services.detector.base import has_bilingual_items
from ..services.detector.pipeline import DetectionPipeline
from ..services.detector.training_data import write_training_example
from ..services.page_filter import PageRangeError, apply_page_ranges, parse_page_ranges
from ..services.pdf_service import LazyPageImages, validate_pdf
from ..services.review_service import build_analyzed_items, build_review_notes, drop_phantom_numbers
from ..services.snap_service import snap_region
from ..services.zip_service import COMBINED_ZIP, QUESTIONS_ZIP, SOLUTIONS_ZIP, create_zip_set
from ..utils.file_utils import create_job_dir, generate_job_id, get_job_dir, safe_cleanup_job

router = APIRouter(tags=["crop"])


def _parse_layout_columns(layout: Optional[str]) -> Optional[int]:
    """Parse layout_columns query parameter into Optional[int] (1, 2, 3, or None)."""
    clean = (layout or "auto").strip().lower()
    if clean == "1":
        return 1
    elif clean == "2":
        return 2
    elif clean == "3":
        return 3
    return None

logger = logging.getLogger(__name__)

ERR_INVALID_FILE_TYPE = "Invalid file type. PDF required."
ERR_INVALID_PDF = "Invalid PDF file"


# Two crops whose regions overlap by at least this fraction (intersection over
# union) are treated as the same physical question and collapsed. Distinct
# stacked questions only touch at an edge (IoU ~0), so this threshold safely
# merges only genuine redraws-over-an-existing-box without dropping a real
# question. Kept in step with the frontend's overlap check.
_OVERLAP_IOU = 0.6


def _item_extent(q: Any) -> float:
    """Total vertical coverage of an item across all its segments (% of a page)."""

    return sum(max(0.0, s.y_end_pct - s.y_start_pct) for s in q.segments)


def _seg_iou(a: Any, b: Any) -> float:
    """Intersection-over-union of two segments' boxes (0 when on different pages)."""

    if a.page != b.page:
        return 0.0
    ix0 = max(a.x_start_pct, b.x_start_pct)
    iy0 = max(a.y_start_pct, b.y_start_pct)
    ix1 = min(a.x_end_pct, b.x_end_pct)
    iy1 = min(a.y_end_pct, b.y_end_pct)
    inter = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
    if inter <= 0.0:
        return 0.0
    area_a = max(0.0, a.x_end_pct - a.x_start_pct) * max(0.0, a.y_end_pct - a.y_start_pct)
    area_b = max(0.0, b.x_end_pct - b.x_start_pct) * max(0.0, b.y_end_pct - b.y_start_pct)
    union = area_a + area_b - inter
    return inter / union if union > 0.0 else 0.0


def _items_overlap(a: Any, b: Any) -> bool:
    """True if two items (same side) occupy substantially the same region."""

    if bool(a.is_solution) != bool(b.is_solution):
        return False
    return any(_seg_iou(sa, sb) >= _OVERLAP_IOU for sa in a.segments for sb in b.segments)


def _dedupe_by_output_file(detected: list[Any], bilingual_mode: Optional[str] = None) -> list[Any]:
    """Collapse items that would be written to the same output file.

    The output filename is derived only from (is_solution, number), so a paper
    that lists the same answer twice — a compact "Answer Key" grid cell *and* a
    full "Hints & Solutions" write-up — produces two items that map to the same
    ``S###.png``. Saving both silently overwrote one with the other and inflated
    the reported count. Here we keep a single item per output file, preferring
    the one with the largest vertical extent (the detailed write-up over the
    one-line grid cell).

    When bilingual mode is active, we expect up to two items (English and Hindi)
    for each question/solution number. In this case, we allow up to 2 items (first
    two sorted left-to-right) per key, rather than discarding down to one.
    """

    def _key(q: Any) -> tuple[bool, int]:
        digits = re.findall(r"\d+", q.q_num)
        return (bool(q.is_solution), int(digits[0]) if digits else 0)

    if not bilingual_mode or bilingual_mode == "none":
        best: dict[tuple[bool, int], Any] = {}
        order: list[tuple[bool, int]] = []
        for q in detected:
            k = _key(q)
            if k not in best:
                best[k] = q
                order.append(k)
            elif _item_extent(q) > _item_extent(best[k]):
                best[k] = q
        return [best[k] for k in order]
    else:
        grouped: dict[tuple[bool, int], list[Any]] = {}
        order: list[tuple[bool, int]] = []
        for q in detected:
            k = _key(q)
            if k not in grouped:
                grouped[k] = []
                order.append(k)
            grouped[k].append(q)

        filtered = []
        for k in order:
            items = grouped[k]
            if len(items) == 1:
                filtered.append(items[0])
            else:
                import functools

                def compare_items(it1, it2):
                    h1 = getattr(it1, "is_hindi", None)
                    h2 = getattr(it2, "is_hindi", None)
                    if h1 is not None and h2 is not None and h1 != h2:
                        return -1 if (not h1 and h2) else 1

                    p1 = it1.segments[0].page if it1.segments else 0
                    p2 = it2.segments[0].page if it2.segments else 0
                    if p1 != p2:
                        return -1 if p1 < p2 else 1

                    s1 = it1.segments[0] if it1.segments else None
                    s2 = it2.segments[0] if it2.segments else None
                    if not s1 or not s2:
                        return 0

                    c1 = (s1.x_start_pct + s1.x_end_pct) / 2.0
                    c2 = (s2.x_start_pct + s2.x_end_pct) / 2.0
                    is_side_by_side = (abs(s1.x_start_pct - s2.x_start_pct) > 15.0) or (abs(c1 - c2) > 15.0)

                    if is_side_by_side:
                        return -1 if s1.x_start_pct < s2.x_start_pct else (1 if s1.x_start_pct > s2.x_start_pct else 0)
                    else:
                        return -1 if s1.y_start_pct < s2.y_start_pct else (1 if s1.y_start_pct > s2.y_start_pct else 0)

                items.sort(key=functools.cmp_to_key(compare_items))
                # Keep up to 2 items (English/left and Hindi/right)
                filtered.append(items[0])
                filtered.append(items[1])
        return filtered


def _dedupe_by_overlap(detected: list[Any]) -> list[Any]:
    """Collapse near-identical crops that map to *different* output files.

    Number-based de-duplication misses the common review-flow case where the
    same physical question is present twice under different numbers — e.g. an
    auto-detected ``Q3`` plus a hand-drawn box over the same spot that got
    auto-numbered ``Q23``. Those two boxes overlap almost entirely, so we keep
    just one (the larger-extent / more complete crop) instead of shipping two
    copies of the same question and inflating the count.
    """

    kept: list[Any] = []
    for q in detected:
        dup_idx = -1
        for i, k in enumerate(kept):
            if _items_overlap(q, k):
                dup_idx = i
                break
        if dup_idx < 0:
            kept.append(q)
        elif _item_extent(q) > _item_extent(kept[dup_idx]):
            kept[dup_idx] = q
    return kept
ERR_NO_QUESTIONS = "No questions detected in this PDF"
ERR_JOB_NOT_FOUND = "Job ID not found"


def _should_align_parts(question: Any) -> bool:
    """Decide whether a question's stitched parts get left-aligned.

    Honours an explicit ``align`` override when the item carries one (the review
    "Align parts" toggle); otherwise falls back to the legacy default of aligning
    only hand-drawn ("manual") items so the fully-automatic ``/crop`` path is
    unchanged. Single-segment items are unaffected — alignment only matters when
    stitching multiple parts.
    """

    override = getattr(question, "align", None)
    if override is not None:
        return bool(override)
    return getattr(question, "source", "auto") == "manual"
ERR_QUESTION_PAGES_REQUIRED = (
    "Question pages are required when the PDF has questions, e.g. '1-5' or '1 to 5, 8'. "
    "Turn off the questions toggle if this PDF has none."
)
ERR_ANSWER_PAGES_REQUIRED = (
    "Answer/solution pages are required when the PDF has solutions. "
    "Turn off the solutions toggle if this PDF has none."
)
ERR_NOTHING_SELECTED = (
    "Nothing to crop. Turn on the questions toggle, the solutions toggle, or both, "
    "and enter the matching page ranges."
)


def _get_temp_root(request: Request, settings: Settings) -> str:
    """Resolve the temp root directory path."""

    return str(getattr(request.app.state, "temp_root", settings.TEMP_DIR))


def _answer_key_from_pdf_text(pdf_source: bytes | str | Path, in_scope_pages: "set[int] | None") -> dict[int, str]:
    """Parse the paper's answer key from the PDF text layer (free, no AI).

    Tries two formats, in order:
      1. A compact ``number → A-D`` grid ("1-B 2-A 3-D …").
      2. Answers stated inside each solution write-up ("1. … Ans (B)  2. …
         Answer: C"), for papers that have no grid but a Solutions section.

    ``in_scope_pages`` of None scans the **whole document** — the answer key (or
    solutions) usually lives at the end, outside the question-page range, so
    restricting the scan to question pages would miss it.

    Returns ``{}`` for scanned papers (empty text layer) so the caller can fall
    back to the AI vision reader.
    """

    try:
        if isinstance(pdf_source, bytes):
            doc = fitz.open(stream=pdf_source, filetype="pdf")
        else:
            doc = fitz.open(str(pdf_source))
        with doc:
            parts: list[str] = []
            for idx in range(doc.page_count):
                page_no = idx + 1
                if in_scope_pages and page_no not in in_scope_pages:
                    continue
                parts.append(doc.load_page(idx).get_text("text") or "")
        full_text = "\n".join(parts)

        # 1. Compact grid (most reliable when present).
        key = extract_answer_key_from_text(full_text)
        if key:
            return key

        # 2. Answers embedded in solution write-ups.
        return extract_answers_from_solution_section(full_text)
    except Exception:
        return {}


def _pdf_has_text(pdf_source: bytes | str | Path) -> bool:
    """True if the PDF has a meaningful selectable-text layer (not a pure scan)."""

    try:
        if isinstance(pdf_source, bytes):
            doc = fitz.open(stream=pdf_source, filetype="pdf")
        else:
            doc = fitz.open(str(pdf_source))
        with doc:
            total = 0
            for idx in range(min(5, doc.page_count)):
                total += len((doc.load_page(idx).get_text("text") or "").strip())
                if total > 100:
                    return True
        return total > 100
    except Exception:
        return False


async def _resolve_answer_key(
    *,
    settings: Settings,
    pdf_source: bytes | str | Path,
    page_images: Any,
    in_scope_pages: "set[int] | None",
    use_ai: bool,
    anthropic_client: Optional[anthropic.AsyncAnthropic],
) -> dict[int, str]:
    """Best-effort answer key for the answer sheet: text first, then AI vision.

    The text layer is read for free. Only when it yields nothing (a scanned
    paper) and the user has Online mode on do we spend an AI call to read the key
    from the page images. Any failure degrades to ``{}`` so the crop/download
    flow is never blocked.
    """

    if not settings.ANSWER_SHEET_ENABLED:
        logger.info("answer_key skipped reason=ANSWER_SHEET_ENABLED=false")
        return {}

    key = await asyncio.to_thread(_answer_key_from_pdf_text, pdf_source, in_scope_pages)
    if key:
        logger.info("answer_key source=text pairs=%s", len(key))
        return key

    # Distinguish "searchable PDF but no key grid found" from "scanned PDF (no
    # text at all)" so the logs say *why* nothing came back.
    has_text = await asyncio.to_thread(_pdf_has_text, pdf_source)
    if use_ai and settings.ai_is_configured():
        logger.info("answer_key source=ai_vision attempt has_text_layer=%s", has_text)
        key = await read_answer_key_with_ai(
            settings, page_images, anthropic_client=anthropic_client
        )
        logger.info("answer_key source=ai_vision pairs=%s", len(key))
        return key

    logger.info(
        "answer_key empty has_text_layer=%s use_ai=%s ai_configured=%s "
        "(scanned PDF needs Online mode + an AI key)",
        has_text,
        use_ai,
        settings.ai_is_configured(),
    )
    return {}

@router.get("/health", response_model=HealthResponse)
async def health(settings: Settings = Depends(get_settings)) -> HealthResponse:
    """Basic health check."""

    tesseract_available = OCRDetector()._is_available()
    google_ocr_available = GoogleOCRDetector().is_available()
    ai_available = settings.ai_is_configured()
    provider = settings.resolved_ai_provider()
    local_ml_detector = build_local_ml_detector(settings)
    local_ml_available = (
        local_ml_detector is not None and local_ml_detector.is_available()
    )
    ai_model = None
    if provider == "openrouter":
        ai_model = settings.OPENROUTER_MODEL
    elif provider == "anthropic":
        ai_model = settings.CLAUDE_MODEL
    return HealthResponse(
        status="ok",
        tesseract_available=tesseract_available,
        google_ocr_available=google_ocr_available,
        ai_available=ai_available,
        version="2.0.0",
        ai_provider=provider,
        ai_model=ai_model,
        local_ml_available=local_ml_available,
        local_ml_model=settings.LOCAL_ML_MODEL_NAME if local_ml_available else None,
    )


@router.post("/debug/answer-key")
async def debug_answer_key(
    file: UploadFile = File(...),
    use_ai: bool = Query(False, description="Also try the AI vision reader."),
    settings: Settings = Depends(get_settings),
    client: Optional[anthropic.AsyncAnthropic] = Depends(get_anthropic_client_optional),
) -> dict:
    """Diagnose answer-sheet extraction for a specific PDF.

    Upload a PDF and see exactly what the answer-key reader finds: whether the
    PDF has a text layer, what the text parser extracted, and (optionally) what
    the AI vision reader returns. Use this to pin down why an answer sheet is or
    isn't produced for a given paper — it never crops or writes anything.
    """

    if file.content_type != "application/pdf":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_FILE_TYPE)

    file_bytes = await file.read()
    if not file_bytes.startswith(b"%PDF"):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF)

    has_text = await asyncio.to_thread(_pdf_has_text, file_bytes)
    text_key = await asyncio.to_thread(_answer_key_from_pdf_text, file_bytes, None)

    # A short text sample so you can eyeball how the key is laid out in the PDF.
    def _sample() -> str:
        try:
            with fitz.open(stream=file_bytes, filetype="pdf") as doc:
                last = doc.load_page(doc.page_count - 1).get_text("text") or ""
            return last[-800:]
        except Exception:
            return ""

    sample = await asyncio.to_thread(_sample)

    ai_key: dict[int, str] = {}
    ai_attempted = False
    if use_ai and settings.ai_is_configured() and not text_key:
        ai_attempted = True
        page_images = await asyncio.to_thread(LazyPageImages, file_bytes, settings.PDF_RENDER_DPI)
        try:
            ai_key = await read_answer_key_with_ai(settings, page_images, anthropic_client=client)
        finally:
            await asyncio.to_thread(page_images.close)

    return {
        "answer_sheet_enabled": settings.ANSWER_SHEET_ENABLED,
        "pdf_has_text_layer": has_text,
        "ai_configured": settings.ai_is_configured(),
        "ai_provider": settings.resolved_ai_provider(),
        "text_parser": {"count": len(text_key), "answers": text_key},
        "ai_reader": {"attempted": ai_attempted, "count": len(ai_key), "answers": ai_key},
        "last_page_text_sample": sample,
        "verdict": _answer_key_verdict(has_text, text_key, settings, use_ai),
    }


def _answer_key_verdict(
    has_text: bool, text_key: dict, settings: Settings, use_ai: bool
) -> str:
    if not settings.ANSWER_SHEET_ENABLED:
        return "Answer sheet is disabled (ANSWER_SHEET_ENABLED=false)."
    if text_key:
        return f"OK — text parser found {len(text_key)} answers. Sheet will be produced."
    if not has_text:
        if use_ai and settings.ai_is_configured():
            return "Scanned PDF — relying on AI vision (see ai_reader above)."
        return (
            "Scanned PDF (no text layer) and AI is off/unconfigured. "
            "Turn on Online mode and configure an AI key to read the key."
        )
    return (
        "PDF has text but no answer-key grid was recognised. The key may be "
        "formatted unusually — check last_page_text_sample and share it."
    )


@router.post("/crop", response_model=CropResponse)
async def crop_pdf(
    request: Request,
    file: UploadFile = File(...),
    dpi: int = Query(200, ge=72, le=600),
    padding: int = Query(20, ge=0, le=200),
    marker_style: str = Query(
        "auto",
        description="Which numbering counts as a question: 'auto', 'q' (only Q1/Question 1), or 'numbered' (only 1./2)).",
    ),
    has_questions: bool = Query(
        True,
        description="Set false when the PDF has no question section; question_pages is then ignored.",
    ),
    question_pages: Optional[str] = Query(
        None,
        description="Pages that contain questions, e.g. '1-5' or '1 to 5, 8'. Required when has_questions is true.",
    ),
    has_answers: bool = Query(
        True,
        description="Set false when the PDF has no solutions section; answer_pages is then ignored.",
    ),
    answer_pages: Optional[str] = Query(
        None,
        description="Pages that contain answers/solutions, e.g. '7-10'. Required when has_answers is true.",
    ),
    skip_pages: Optional[str] = Query(
        None,
        description="Pages to skip during crop, e.g. '3, 5'.",
    ),
    question_prefix: str = Query(
        "Q",
        max_length=10,
        description="Filename prefix for question crops (e.g. 'Q' -> Q001.png).",
    ),
    solution_prefix: str = Query(
        "S",
        max_length=10,
        description="Filename prefix for solution crops (e.g. 'S' -> S001.png).",
    ),
    start_number: int = Query(
        1,
        ge=1,
        le=100000,
        description="Number the first cropped item starts at (e.g. 5 -> Q005.png).",
    ),
    image_format: str = Query(
        "png",
        description="Output image format: 'png' (lossless) or 'jpg' (lossy, smaller files).",
    ),
    jpg_quality: int = Query(
        90,
        ge=1,
        le=100,
        description="JPG compression quality 1-100 (higher = better quality, larger file). Ignored for PNG.",
    ),
    use_ai: bool = Query(
        False,
        description="Online mode: allow the AI vision tier when a key is configured. "
        "Defaults to off (fully offline text/OCR run); set true to opt into AI.",
    ),
    use_google_ocr: bool = Query(
        False,
        description="Use Google Cloud Vision OCR instead of Tesseract.",
    ),
    use_paddle_ocr: bool = Query(
        False,
        description="Use PaddleOCR instead of Tesseract.",
    ),
    answer_sheet: bool = Query(
        True,
        description="Bundle an answer sheet (answers.csv + answers.json mapping each "
        "question image to its correct option) when the paper has an answer key.",
    ),
    layout_columns: str = Query(
        "auto",
        description="Force page layout columns: 'auto', '1', '2', or '3'.",
    ),
    binarize: bool = Query(False, description="Binarize/monochrome pages."),
    contrast: float = Query(1.0, description="Contrast scaling factor."),
    brightness: float = Query(1.0, description="Brightness scaling factor."),
    watermark_threshold: int = Query(255, ge=0, le=255, description="Watermark background filter."),
    deskew: bool = Query(False, description="Straighten skew scan tilt."),
    custom_regex: Optional[str] = Query(None, description="Custom marker matching regular expression."),
    confidence: Optional[float] = Query(None, description="YOLO score confidence threshold."),
    settings: Settings = Depends(get_settings),
    client: Optional[anthropic.AsyncAnthropic] = Depends(get_anthropic_client_optional),
) -> CropResponse:
    """Run the full pipeline: validate PDF -> render -> detect -> crop -> zip.

    Page ranges are mandatory: only the pages listed in ``question_pages`` (and,
    when ``has_answers`` is on, ``answer_pages``) are cropped — nothing else.
    """

    if file.content_type != "application/pdf":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_FILE_TYPE)

    # At least one of questions / solutions must be requested.
    if not has_questions and not has_answers:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_NOTHING_SELECTED)

    # Question pages are required only when the PDF is said to contain questions.
    if has_questions and (not question_pages or not question_pages.strip()):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_QUESTION_PAGES_REQUIRED)

    # Answer pages are required only when the PDF is said to contain solutions.
    if has_answers and (not answer_pages or not answer_pages.strip()):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_ANSWER_PAGES_REQUIRED)

    # Normalize prefixes (strip stray whitespace; fall back to defaults).
    q_prefix = (question_prefix or "Q").strip() or "Q"
    s_prefix = (solution_prefix or "S").strip() or "S"

    # Normalize output format (accept png/jpg/jpeg; default to png).
    fmt = (image_format or "png").strip().lower()
    if fmt not in ("png", "jpg", "jpeg"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid image_format. Use 'png' or 'jpg'.",
        )
    out_format = "jpg" if fmt in ("jpg", "jpeg") else "png"

    style = (marker_style or "auto").strip().lower()
    if style not in ("auto", "q", "numbered"):
        style = "auto"

    job_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)

    request_id = getattr(request.state, "request_id", None)
    logger.info("request_id=%s job_id=%s stage=start", request_id, job_id)

    job_dir: Optional[Path] = None
    try:
        job_dir = await asyncio.to_thread(create_job_dir, job_id, temp_root)
        source_pdf_path = job_dir / "source.pdf"

        # Stream upload directly to disk
        max_bytes = settings.MAX_PDF_SIZE_MB * 1024 * 1024
        from ..utils.file_utils import stream_upload_to_file
        await stream_upload_to_file(file, source_pdf_path, max_bytes)

        # Validate PDF on disk
        validate_pdf(pdf_source=source_pdf_path, settings=settings)

        # Lazy page view: pages are rasterised only when a detector asks for
        # one, and at most a single page bitmap is held in memory at a time.
        # A searchable PDF (text tier wins) renders zero pages here; the final
        # crops are re-rendered straight from the PDF vector source regardless.
        page_images = await asyncio.to_thread(
            LazyPageImages,
            source_pdf_path,
            dpi,
            binarize=binarize,
            contrast=contrast,
            brightness=brightness,
            watermark_threshold=watermark_threshold,
            deskew=deskew,
        )
        total_pages = len(page_images)
        logger.info("request_id=%s job_id=%s stage=pdf_rendered total_pages=%s", request_id, job_id, total_pages)

        try:
            # Ignore question pages entirely when the user toggled questions off.
            question_page_set = (
                parse_page_ranges(question_pages, max_page=total_pages) if has_questions else set()
            )
            # Ignore answer pages entirely when the user toggled solutions off.
            answer_page_set = (
                parse_page_ranges(answer_pages, max_page=total_pages) if has_answers else set()
            )
            if has_questions and not question_page_set and not has_answers:
                question_page_set = set(range(1, total_pages + 1))
            if has_answers and not answer_page_set and not has_questions:
                answer_page_set = set(range(1, total_pages + 1))
            skip_page_set = (
                parse_page_ranges(skip_pages, max_page=total_pages) if skip_pages else set()
            )
            if skip_page_set:
                question_page_set -= skip_page_set
                answer_page_set -= skip_page_set
        except PageRangeError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

        if has_questions and not question_page_set:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"No valid question pages within this {total_pages}-page PDF.",
            )
        if has_answers and not answer_page_set:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"No valid answer/solution pages within this {total_pages}-page PDF.",
            )

        pipeline = DetectionPipeline(
            ai_detector=build_ai_detector(settings, use_ai=use_ai, anthropic_client=client),
            local_ml_detector=build_local_ml_detector(settings),
            paddle_ocr_detector=build_paddle_ocr_detector(settings),
        )
        layout_val = _parse_layout_columns(layout_columns)
        detected, method_used = await pipeline.detect(
            pdf_source=source_pdf_path,
            page_images=page_images,
            settings=settings,
            render_dpi=dpi,
            prefer_ai=use_ai,
            use_google_ocr=use_google_ocr,
            use_paddle_ocr=use_paddle_ocr,
            marker_style=style,
            layout_columns=layout_val,
            confidence=confidence,
            custom_regex=custom_regex,
        )

        # Resolve the paper's answer key for the answer-sheet export while the
        # page images are still live (the AI vision fallback needs them). Text
        # layer is read for free; AI is used only on a scanned paper in Online
        # mode. Scanned across the WHOLE document — the key usually sits in the
        # answer/solution section, outside the question-page range. Skipped
        # entirely when the user turned the sheet off.
        answer_key = await _resolve_answer_key(
            settings=settings,
            pdf_source=source_pdf_path,
            page_images=page_images,
            in_scope_pages=None,
            use_ai=use_ai,
            anthropic_client=client,
        ) if answer_sheet else {}

        # Detection is done with the page bitmaps; the crops below are rendered
        # straight from the PDF vector source, so free the lazy view (and its
        # open document) now instead of holding it for the rest of the request.
        await asyncio.to_thread(page_images.close)

        # Crop exactly the pages the user listed (strict): items on any other
        # page are dropped so the output matches the requested pages precisely.
        detected = apply_page_ranges(
            questions=detected,
            question_pages=question_page_set,
            answer_pages=answer_page_set,
            strict=True,
        )
        logger.info(
            "request_id=%s job_id=%s stage=page_filter question_pages=%s answer_pages=%s kept=%s",
            request_id,
            job_id,
            sorted(question_page_set),
            sorted(answer_page_set),
            len(detected),
        )

        # Drop lone out-of-sequence numbers an inline value produced (e.g. an
        # angle "53" inside an equation read as "Q53") so the bogus item is
        # never cropped or counted.
        detected = drop_phantom_numbers(detected)

        if not detected:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=ERR_NO_QUESTIONS)

        # Collapse items that would overwrite each other on disk (e.g. an
        # answer-key grid cell and the full solution for the same number) so the
        # zip contains one correct file per question/solution and the reported
        # count matches the files actually produced.
        detected = _dedupe_by_output_file(detected)

        def _crop_and_save_all() -> tuple[list[Path], list[Path], int]:
            question_paths: list[Path] = []
            solution_paths: list[Path] = []
            stitched = 0
            # Crop DPI is at least the detection DPI; rendering crops straight
            # from the PDF vector source at this higher DPI keeps text sharp when
            # zoomed instead of upscaling the detection raster.
            crop_dpi = max(dpi, settings.CROP_RENDER_DPI)
            with fitz.open(str(source_pdf_path)) as doc:
                # Structural page furniture (branding footers, logos, decorative
                # rules) collected once per document and painted out of any crop
                # region it intersects — including the middle of a cross-page
                # stitch, where pixel-edge trimming can't reach.
                furniture_by_page = collect_document_furniture(doc)
                for question in detected:
                    if len(question.segments) > 1:
                        stitched += 1
                    img = crop_and_stitch_hires(
                        doc,
                        question,
                        padding_px=padding,
                        detection_dpi=dpi,
                        crop_dpi=crop_dpi,
                        furniture_by_page=furniture_by_page,
                        binarize=binarize,
                        contrast=contrast,
                        brightness=brightness,
                        watermark_threshold=watermark_threshold,
                        deskew=deskew,
                    )
                    saved = save_question_image(
                        image=img,
                        q_num=question.q_num,
                        output_dir=job_dir,
                        is_solution=question.is_solution,
                        question_prefix=q_prefix,
                        solution_prefix=s_prefix,
                        start_number=start_number,
                        image_format=out_format,
                        jpg_quality=jpg_quality,
                    )
                    if question.is_solution:
                        solution_paths.append(saved)
                    else:
                        question_paths.append(saved)
            return question_paths, solution_paths, stitched

        question_paths, solution_paths, stitched_questions = await asyncio.to_thread(_crop_and_save_all)

        # Build the answer sheet (answers.csv + answers.json) keyed to the crop
        # filenames, and bundle it into the questions + combined archives. With
        # the toggle on we always write the sheet (even with no key found) so the
        # result is visible — an accompanying note explains a blank answer column.
        sheet_paths = await asyncio.to_thread(
            write_answer_sheet,
            detected,
            answer_key,
            job_dir,
            question_prefix=q_prefix,
            solution_prefix=s_prefix,
            start_number=start_number,
            image_format=out_format,
            always=answer_sheet,
            empty_reason=(
                "Scanned PDF with Online mode off — enable Online mode (AI)."
                if (not answer_key and not use_ai)
                else ""
            ),
        )
        answers_count = count_answered(detected, answer_key, start_number=start_number)

        zips = await asyncio.to_thread(
            create_zip_set, question_paths, solution_paths, job_id, job_dir, sheet_paths
        )
        zip_path = zips["combined"]

        def _file_kb(p: Path) -> int:
            return int(p.stat().st_size / 1024)

        zip_kb = await asyncio.to_thread(_file_kb, zip_path)
        total_questions = len(question_paths) + len(solution_paths)
        logger.info(
            "request_id=%s job_id=%s stage=done method_used=%s total_questions=%s stitched_questions=%s zip_kb=%s",
            request_id,
            job_id,
            method_used,
            total_questions,
            stitched_questions,
            zip_kb,
        )

        return CropResponse(
            job_id=job_id,
            total_questions=total_questions,
            stitched_questions=stitched_questions,
            method_used=method_used,  # type: ignore[arg-type]
            download_url=f"/api/crop/download/{job_id}",
            questions_download_url=(
                f"/api/crop/download/{job_id}?kind=questions" if question_paths else None
            ),
            solutions_download_url=(
                f"/api/crop/download/{job_id}?kind=solutions" if solution_paths else None
            ),
            questions_count=len(question_paths),
            solutions_count=len(solution_paths),
            answer_sheet_included=bool(sheet_paths),
            answers_count=answers_count,
        )
    except HTTPException as exc:
        logger.error("request_id=%s job_id=%s stage=error detail=%s", request_id, job_id, exc.detail)
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
    except Exception as exc:
        logger.exception("request_id=%s job_id=%s stage=error error=%s", request_id, job_id, str(exc))
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise


def _analyzed_to_detected(items: list[Any]) -> list[DetectedQuestion]:
    """Convert finalize/analyze items (Pydantic) into DetectedQuestion objects."""

    out: list[DetectedQuestion] = []
    for it in items:
        if not it.segments:
            continue
        out.append(
            DetectedQuestion(
                q_num=(it.q_num or "0").strip() or "0",
                is_solution=bool(it.is_solution),
                segments=list(it.segments),
                source=getattr(it, "source", "auto") or "auto",
                align=getattr(it, "align", None),
                is_hindi=getattr(it, "is_hindi", None),
            )
        )
    return out


@router.post("/analyze", response_model=AnalyzeResponse)
async def analyze_pdf(
    request: Request,
    file: UploadFile = File(...),
    dpi: int = Query(200, ge=72, le=600),
    marker_style: str = Query("auto"),
    has_questions: bool = Query(True),
    question_pages: Optional[str] = Query(None),
    has_answers: bool = Query(True),
    answer_pages: Optional[str] = Query(None),
    skip_pages: Optional[str] = Query(None),
    use_ai: bool = Query(
        False,
        description="Online mode: allow the AI vision tier when a key is configured. "
        "Defaults to off (fully offline text/OCR run); set true to opt into AI.",
    ),
    use_google_ocr: bool = Query(
        False,
        description="Use Google Cloud Vision OCR instead of Tesseract.",
    ),
    use_paddle_ocr: bool = Query(
        False,
        description="Use PaddleOCR instead of Tesseract.",
    ),
    answer_sheet: bool = Query(
        True,
        description="Read the paper's answer key during analysis and cache it so "
        "the finalized download can bundle an answer sheet.",
    ),
    layout_columns: str = Query(
        "auto",
        description="Force page layout columns: 'auto', '1', '2', or '3'.",
    ),
    binarize: bool = Query(False, description="Binarize/monochrome pages."),
    contrast: float = Query(1.0, description="Contrast scaling factor."),
    brightness: float = Query(1.0, description="Brightness scaling factor."),
    watermark_threshold: int = Query(255, ge=0, le=255, description="Watermark background filter."),
    deskew: bool = Query(False, description="Straighten skew scan tilt."),
    custom_regex: Optional[str] = Query(None, description="Custom marker matching regular expression."),
    confidence: Optional[float] = Query(None, description="YOLO score confidence threshold."),
    settings: Settings = Depends(get_settings),
    client: Optional[anthropic.AsyncAnthropic] = Depends(get_anthropic_client_optional),
) -> AnalyzeResponse:
    """Smart-detect questions/solutions and return them for on-screen review.

    Unlike ``/crop`` (which goes straight to a ZIP), this runs the pipeline in
    *smart* mode — escalating to the AI vision tier when the cheap tiers look
    incomplete — then returns the detected regions, page geometry/preview
    images, and a list of review notes (likely duplicates, numbering gaps, tiny
    crops). The frontend shows a manual-crop popup for anything flagged; the
    user's hand-drawn additions are sent back to ``/finalize`` and combined with
    the kept auto items into the final ZIP. The original PDF and page previews
    are cached in the job dir so ``/finalize`` can re-render crisp crops without
    a re-upload.
    """

    if file.content_type != "application/pdf":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_FILE_TYPE)

    job_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)
    request_id = getattr(request.state, "request_id", None)
    logger.info("request_id=%s job_id=%s stage=analyze_start", request_id, job_id)

    job_dir: Optional[Path] = None
    try:
        job_dir = await asyncio.to_thread(create_job_dir, job_id, temp_root)
        source_pdf = job_dir / "source.pdf"

        # Stream upload directly to disk
        max_bytes = settings.MAX_PDF_SIZE_MB * 1024 * 1024
        from ..utils.file_utils import stream_upload_to_file
        await stream_upload_to_file(file, source_pdf, max_bytes)

        # Validate PDF on disk
        validate_pdf(pdf_source=source_pdf, settings=settings)

        # Cache the enhancement parameters
        enhancements = {
            "binarize": binarize,
            "contrast": contrast,
            "brightness": brightness,
            "watermark_threshold": watermark_threshold,
            "deskew": deskew,
        }
        await asyncio.to_thread(
            (job_dir / "enhancements.json").write_text,
            json.dumps(enhancements),
            "utf-8",
        )

        page_images = await asyncio.to_thread(
            LazyPageImages,
            source_pdf,
            dpi,
            binarize=binarize,
            contrast=contrast,
            brightness=brightness,
            watermark_threshold=watermark_threshold,
            deskew=deskew,
        )
        total_pages = len(page_images)

        try:
            question_page_set = (
                parse_page_ranges(question_pages, max_page=total_pages) if has_questions else set()
            )
            answer_page_set = (
                parse_page_ranges(answer_pages, max_page=total_pages) if has_answers else set()
            )
            if has_questions and not question_page_set and not has_answers:
                question_page_set = set(range(1, total_pages + 1))
            if has_answers and not answer_page_set and not has_questions:
                answer_page_set = set(range(1, total_pages + 1))
            skip_page_set = (
                parse_page_ranges(skip_pages, max_page=total_pages) if skip_pages else set()
            )
            if skip_page_set:
                question_page_set -= skip_page_set
                answer_page_set -= skip_page_set
        except PageRangeError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

        pipeline = DetectionPipeline(
            ai_detector=build_ai_detector(settings, use_ai=use_ai, anthropic_client=client),
            local_ml_detector=build_local_ml_detector(settings),
            paddle_ocr_detector=build_paddle_ocr_detector(settings),
        )
        layout_val = _parse_layout_columns(layout_columns)
        detected, method_used = await pipeline.detect(
            pdf_source=source_pdf,
            page_images=page_images,
            settings=settings,
            render_dpi=dpi,
            smart=True,
            prefer_ai=use_ai,
            use_google_ocr=use_google_ocr,
            use_paddle_ocr=use_paddle_ocr,
            marker_style=(marker_style or "auto").strip().lower()
            if (marker_style or "auto").strip().lower() in ("auto", "q", "numbered")
            else "auto",
            layout_columns=layout_val,
            confidence=confidence,
            custom_regex=custom_regex,
        )

        # Resolve the paper's answer key for the answer-sheet export while the
        # page images are still live (the AI vision fallback needs them). Scope
        # to question pages; falls back to AI vision on a scanned paper in Online
        # mode. Cached to disk so /finalize can attach the sheet without a
        # re-upload or a second AI call.
        # Resolve the paper's answer key for the answer-sheet export while the
        # page images are still live (the AI vision fallback needs them).
        # Scanned across the WHOLE document — the key usually sits in the
        # answer/solution section, outside the question-page range. Falls back
        # to AI vision on a scanned paper in Online mode. Cached to disk so
        # /finalize can attach the sheet without a re-upload or a second AI call.
        in_scope_pages = question_page_set | answer_page_set
        answer_key = await _resolve_answer_key(
            settings=settings,
            pdf_source=source_pdf,
            page_images=page_images,
            in_scope_pages=None,
            use_ai=use_ai,
            anthropic_client=client,
        ) if answer_sheet else {}
        if answer_key:
            await asyncio.to_thread(
                (job_dir / "answer_key.json").write_text,
                json.dumps(answer_key),
                "utf-8",
            )

        # Page bitmaps are no longer needed: previews and text-line extents
        # below are read straight from the PDF. Release the lazy view and its
        # open document now.
        await asyncio.to_thread(page_images.close)

        # Honour page-range filtering whenever the user scoped pages. The pages
        # the user typed are authoritative: anything outside them (e.g. the
        # cover/instruction pages before the first question page) is dropped so
        # the review starts exactly where the user asked — "questions from page
        # 4" means nothing on pages 1-3 is checked or shown. ``strict=True``
        # mirrors the /crop contract instead of the old lax behaviour that kept
        # out-of-range items when only one range was supplied.
        if in_scope_pages:
            detected = apply_page_ranges(
                questions=detected,
                question_pages=question_page_set,
                answer_pages=answer_page_set,
                strict=True,
            )

        # Drop lone out-of-sequence numbers an inline value produced (e.g. an
        # angle "53" inside an equation read as "Q53") so the bogus item is
        # never shown for review or cropped.
        detected = drop_phantom_numbers(detected)

        # Render lightweight page previews for the manual-crop canvas. When the
        # user scoped pages we only render those pages, so the review pager reads
        # "Page 4 / N" (the first scoped page) instead of opening on the cover
        # at "Page 1 / 42". Filenames/PageInfo keep absolute page numbers so the
        # detected boxes (which carry absolute pages) still line up.
        preview_dpi = min(dpi, 120)
        pages_info: list[PageInfo] = []

        def _write_previews() -> list[PageInfo]:
            infos: list[PageInfo] = []
            from PIL import Image
            with fitz.open(str(source_pdf)) as doc:
                zoom = preview_dpi / 72.0
                matrix = fitz.Matrix(zoom, zoom)
                for idx in range(doc.page_count):
                    page_no = idx + 1
                    if in_scope_pages and page_no not in in_scope_pages:
                        continue
                    page = doc.load_page(idx)
                    rect = page.rect
                    pix = page.get_pixmap(matrix=matrix, colorspace=fitz.csRGB, alpha=False)
                    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)

                    if binarize or contrast != 1.0 or brightness != 1.0 or watermark_threshold < 255 or deskew:
                        from ..services.pdf_tools.enhance_service import enhance_image
                        img = enhance_image(
                            img,
                            binarize=binarize,
                            contrast=contrast,
                            brightness=brightness,
                            watermark_threshold=watermark_threshold,
                            deskew=deskew,
                        )

                    out_path = job_dir / f"page_{page_no:03d}.png"
                    img.save(str(out_path))
                    infos.append(
                        PageInfo(
                            page=page_no,
                            width_pt=float(rect.width),
                            height_pt=float(rect.height),
                            preview_url=f"/api/analyze/{job_id}/page/{page_no}",
                        )
                    )
            return infos

        pages_info = await asyncio.to_thread(_write_previews)

        # Answer-key cross-check: the answer key parsed above gives the
        # authoritative set of question numbers, so the review can flag any the
        # detector missed with high confidence.
        expected_q_nums = expected_question_numbers(answer_key)

        # Per-page text-line extents (page-percent units) for the content-
        # coverage review check: a normal-looking crop that stopped short leaves
        # its own body text uncovered below it, which shape heuristics can't see.
        # Only meaningful for searchable PDFs; scanned papers extract nothing
        # here and the check simply stays disabled.
        def _page_text_lines() -> "dict[int, list[tuple[float, float, float, float]]]":
            out: dict[int, list[tuple[float, float, float, float]]] = {}
            try:
                with fitz.open(stream=file_bytes, filetype="pdf") as doc:
                    for idx in range(doc.page_count):
                        page_no = idx + 1
                        if in_scope_pages and page_no not in in_scope_pages:
                            continue
                        page = doc.load_page(idx)
                        rect = page.rect
                        pw, ph = float(rect.width), float(rect.height)
                        if pw <= 0 or ph <= 0:
                            continue
                        lines: list[tuple[float, float, float, float]] = []
                        data = page.get_text("dict") or {}
                        for block in data.get("blocks", []):
                            for ln in block.get("lines", []):
                                spans = ln.get("spans", [])
                                if not spans:
                                    continue
                                if not any((s.get("text") or "").strip() for s in spans):
                                    continue
                                x0, y0, x1, y1 = ln.get("bbox", (0, 0, 0, 0))
                                lines.append(
                                    (
                                        (y0 / ph) * 100.0,
                                        (y1 / ph) * 100.0,
                                        (x0 / pw) * 100.0,
                                        (x1 / pw) * 100.0,
                                    )
                                )
                        if lines:
                            out[page_no] = lines
            except Exception:
                return {}
            return out

        page_lines = await asyncio.to_thread(_page_text_lines)

        # Fallback for scanned PDFs: the page text layer is empty, so the loop
        # above yields nothing and the coverage check would silently do nothing.
        # The OCR tier, however, already reconstructed every text line during
        # detection (in page-percent units), so reuse those whenever the text
        # layer gave us no lines for a page. This is what makes the cut-off /
        # under-coverage detection actually fire on image-based papers.
        ocr_lines = getattr(
            getattr(pipeline, "ocr_detector", None), "page_lines_pct", None
        )
        if ocr_lines:
            for page_no, lines in ocr_lines.items():
                if in_scope_pages and page_no not in in_scope_pages:
                    continue
                if not page_lines.get(page_no) and lines:
                    page_lines[page_no] = list(lines)

        items = build_analyzed_items(detected, page_lines or None)
        notes = build_review_notes(
            detected,
            method_used,
            expected_q_nums or None,
            page_lines or None,
            pdf_source=source_pdf,
        )
        needs_review = bool(notes) or any(it.flagged for it in items)

        logger.info(
            "request_id=%s job_id=%s stage=analyze_done method_used=%s items=%s notes=%s needs_review=%s",
            request_id,
            job_id,
            method_used,
            len(items),
            len(notes),
            needs_review,
        )

        return AnalyzeResponse(
            job_id=job_id,
            total_pages=total_pages,
            method_used=method_used,  # type: ignore[arg-type]
            pages=pages_info,
            items=items,
            notes=notes,
            needs_review=needs_review,
            answer_key_count=len(answer_key),
            bilingual_detected=has_bilingual_items(detected),
        )
    except HTTPException:
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
    except Exception as exc:
        logger.exception("request_id=%s job_id=%s stage=analyze_error error=%s", request_id, job_id, str(exc))
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise


@router.post("/prepare-manual", response_model=AnalyzeResponse)
async def prepare_manual(
    request: Request,
    file: UploadFile = File(...),
    dpi: int = Query(200, ge=72, le=600),
    binarize: bool = Query(False),
    contrast: float = Query(1.0),
    brightness: float = Query(1.0),
    watermark_threshold: int = Query(255),
    deskew: bool = Query(False),
    settings: Settings = Depends(get_settings),
) -> AnalyzeResponse:
    """Prepare a PDF for fully-manual cropping — no auto-detection runs.

    This is the Manual Crop tool's entry point. It mirrors the cheap half of
    ``/analyze`` (cache the source PDF, render lightweight page previews) but
    deliberately skips the detection pipeline: it returns an empty item list so
    the user draws every crop by hand in the same review canvas. The auto-crop
    flow (``/crop`` and ``/analyze``) is untouched — manual mode simply never
    calls the detector.
    """

    if file.content_type != "application/pdf":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_FILE_TYPE)

    job_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)
    request_id = getattr(request.state, "request_id", None)
    logger.info("request_id=%s job_id=%s stage=prepare_manual_start", request_id, job_id)

    job_dir: Optional[Path] = None
    try:
        job_dir = await asyncio.to_thread(create_job_dir, job_id, temp_root)
        source_pdf = job_dir / "source.pdf"

        # Stream upload directly to disk
        max_bytes = settings.MAX_PDF_SIZE_MB * 1024 * 1024
        from ..utils.file_utils import stream_upload_to_file
        await stream_upload_to_file(file, source_pdf, max_bytes)

        # Validate PDF on disk
        validate_pdf(pdf_source=source_pdf, settings=settings)

        # Cache the enhancement parameters
        enhancements = {
            "binarize": binarize,
            "contrast": contrast,
            "brightness": brightness,
            "watermark_threshold": watermark_threshold,
            "deskew": deskew,
        }
        await asyncio.to_thread(
            (job_dir / "enhancements.json").write_text,
            json.dumps(enhancements),
            "utf-8",
        )

        # Render every page as a preview so the user can crop from any page.
        preview_dpi = min(dpi, 120)

        def _write_previews() -> tuple[int, list[PageInfo]]:
            infos: list[PageInfo] = []
            from PIL import Image
            with fitz.open(str(source_pdf)) as doc:
                zoom = preview_dpi / 72.0
                matrix = fitz.Matrix(zoom, zoom)
                for idx in range(doc.page_count):
                    page_no = idx + 1
                    page = doc.load_page(idx)
                    rect = page.rect
                    pix = page.get_pixmap(matrix=matrix, colorspace=fitz.csRGB, alpha=False)
                    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
                    
                    if binarize or contrast != 1.0 or brightness != 1.0 or watermark_threshold < 255 or deskew:
                        from ..services.pdf_tools.enhance_service import enhance_image
                        img = enhance_image(
                            img,
                            binarize=binarize,
                            contrast=contrast,
                            brightness=brightness,
                            watermark_threshold=watermark_threshold,
                            deskew=deskew,
                        )
                    
                    out_path = job_dir / f"page_{page_no:03d}.png"
                    img.save(str(out_path))
                    infos.append(
                        PageInfo(
                            page=page_no,
                            width_pt=float(rect.width),
                            height_pt=float(rect.height),
                            preview_url=f"/api/analyze/{job_id}/page/{page_no}",
                        )
                    )
                return doc.page_count, infos

        total_pages, pages_info = await asyncio.to_thread(_write_previews)
        logger.info(
            "request_id=%s job_id=%s stage=prepare_manual_done total_pages=%s",
            request_id,
            job_id,
            total_pages,
        )

        return AnalyzeResponse(
            job_id=job_id,
            total_pages=total_pages,
            method_used="text",  # no detection ran; placeholder for the schema
            pages=pages_info,
            items=[],
            notes=[],
            needs_review=False,
        )
    except HTTPException:
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
    except Exception as exc:
        logger.exception("request_id=%s job_id=%s stage=prepare_manual_error error=%s", request_id, job_id, str(exc))
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise


@router.post("/crop/{job_id}/auto-detect", response_model=list[AnalyzedItem])
async def auto_detect_job_page(
    request: Request,
    job_id: str,
    page: Optional[int] = Query(None, description="1-indexed page. If null, run on all pages."),
    use_ai: bool = Query(False),
    use_google_ocr: bool = Query(False),
    use_paddle_ocr: bool = Query(False),
    marker_style: str = Query("auto"),
    layout_columns: str = Query("auto", description="Force page layout columns: 'auto', '1', '2', or '3'."),
    binarize: bool = Query(False),
    contrast: float = Query(1.0),
    brightness: float = Query(1.0),
    watermark_threshold: int = Query(255),
    deskew: bool = Query(False),
    custom_regex: Optional[str] = Query(None),
    confidence: Optional[float] = Query(None),
    settings: Settings = Depends(get_settings),
    client: Optional[anthropic.AsyncAnthropic] = Depends(get_anthropic_client_optional),
) -> list[AnalyzedItem]:
    """Run detection pipeline on the cached PDF page(s) of an active job."""

    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(job_id, temp_root)
    source_pdf = job_dir / "source.pdf"

    def _exists(p: Path) -> bool:
        return p.exists()

    if not await asyncio.to_thread(_exists, source_pdf):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=ERR_JOB_NOT_FOUND)

    dpi = settings.PDF_RENDER_DPI
    page_images = await asyncio.to_thread(
        LazyPageImages,
        source_pdf,
        dpi,
        binarize=binarize,
        contrast=contrast,
        brightness=brightness,
        watermark_threshold=watermark_threshold,
        deskew=deskew,
    )
    total_pages = len(page_images)

    try:
        if page is not None:
            if page < 1 or page > total_pages:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"Page number {page} is out of bounds.")
            question_page_set = {page}
            answer_page_set = {page}
        else:
            question_page_set = set(range(1, total_pages + 1))
            answer_page_set = set(range(1, total_pages + 1))

        from PIL import Image

        class SinglePageLazyImagesWrapper:
            def __init__(self, lazy: LazyPageImages, target_page: int) -> None:
                self.lazy = lazy
                self.target_idx = target_page - 1
                self.count = len(lazy)
            def __len__(self) -> int:
                return self.count
            def __getitem__(self, idx: Any) -> Any:
                if isinstance(idx, slice):
                    indices = range(*idx.indices(self.count))
                    return [self[i] for i in indices]
                i = int(idx)
                if i == self.target_idx:
                    return self.lazy[i]
                else:
                    return Image.new("RGB", (10, 10), (255, 255, 255))
            def __iter__(self):
                for i in range(self.count):
                    yield self[i]
            def close(self) -> None:
                self.lazy.close()

        if page is not None:
            wrapped_images: Any = SinglePageLazyImagesWrapper(page_images, page)
        else:
            wrapped_images = page_images

        pipeline = DetectionPipeline(
            ai_detector=build_ai_detector(settings, use_ai=use_ai, anthropic_client=client),
            local_ml_detector=build_local_ml_detector(settings),
            paddle_ocr_detector=build_paddle_ocr_detector(settings),
        )
        style = (marker_style or "auto").strip().lower()
        if style not in ("auto", "q", "numbered"):
            style = "auto"

        layout_val = _parse_layout_columns(layout_columns)
        detected, method_used = await pipeline.detect(
            pdf_source=source_pdf,
            page_images=wrapped_images,
            settings=settings,
            render_dpi=dpi,
            smart=True,
            prefer_ai=use_ai,
            use_google_ocr=use_google_ocr,
            use_paddle_ocr=use_paddle_ocr,
            marker_style=style,
            layout_columns=layout_val,
            confidence=confidence,
            custom_regex=custom_regex,
        )

        detected = apply_page_ranges(
            questions=detected,
            question_pages=question_page_set,
            answer_pages=answer_page_set,
            strict=True,
        )
        detected = drop_phantom_numbers(detected)

        def _page_text_lines() -> dict[int, list[tuple[float, float, float, float]]]:
            out: dict[int, list[tuple[float, float, float, float]]] = {}
            try:
                with fitz.open(str(source_pdf)) as doc:
                    for p_num in question_page_set | answer_page_set:
                        page_idx = p_num - 1
                        page = doc.load_page(page_idx)
                        rect = page.rect
                        pw, ph = float(rect.width), float(rect.height)
                        if pw <= 0 or ph <= 0:
                            continue
                        lines: list[tuple[float, float, float, float]] = []
                        data = page.get_text("dict") or {}
                        for block in data.get("blocks", []):
                            for ln in block.get("lines", []):
                                spans = ln.get("spans", [])
                                if not spans:
                                    continue
                                if not any((s.get("text") or "").strip() for s in spans):
                                    continue
                                x0, y0, x1, y1 = ln.get("bbox", (0, 0, 0, 0))
                                lines.append(
                                    (
                                        (y0 / ph) * 100.0,
                                        (y1 / ph) * 100.0,
                                        (x0 / pw) * 100.0,
                                        (x1 / pw) * 100.0,
                                    )
                                )
                        if lines:
                            out[p_num] = lines
            except Exception:
                return {}
            return out

        page_lines = await asyncio.to_thread(_page_text_lines)
        ocr_lines = getattr(
            getattr(pipeline, "ocr_detector", None), "page_lines_pct", None
        )
        if ocr_lines:
            for p_num, lines in ocr_lines.items():
                if p_num not in (question_page_set | answer_page_set):
                    continue
                if not page_lines.get(p_num) and lines:
                    page_lines[p_num] = list(lines)

        items = build_analyzed_items(detected, page_lines or None)
        return items
    finally:
        await asyncio.to_thread(page_images.close)


@router.get("/analyze/{job_id}/page/{page_no}")
async def analyze_page_preview(
    request: Request,
    job_id: str,
    page_no: int,
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    """Serve a cached page-preview PNG for the manual-crop canvas."""

    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(job_id, temp_root)
    preview = job_dir / f"page_{page_no:03d}.png"

    def _exists(p: Path) -> bool:
        return p.exists()

    if not await asyncio.to_thread(_exists, preview):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Preview not found")

    return FileResponse(str(preview), media_type="image/png")


@router.post("/snap", response_model=SnapResponse)
async def snap_box(
    request: Request,
    payload: SnapRequest,
    settings: Settings = Depends(get_settings),
) -> SnapResponse:
    """Tighten a roughly drawn box to the actual content inside it.

    Uses the source PDF cached by ``/analyze``. Returns the original box
    unchanged if the job/PDF is gone or the region is blank, so the manual
    selection is never made worse.
    """

    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(payload.job_id, temp_root)
    source_pdf = job_dir / "source.pdf"

    def _exists(p: Path) -> bool:
        return p.exists()

    if not await asyncio.to_thread(_exists, source_pdf):
        # No cached PDF — just echo the drawn box back.
        return SnapResponse(
            x_start_pct=payload.x_start_pct,
            x_end_pct=payload.x_end_pct,
            y_start_pct=payload.y_start_pct,
            y_end_pct=payload.y_end_pct,
        )

    file_bytes = await asyncio.to_thread(source_pdf.read_bytes)
    snapped = await asyncio.to_thread(
        snap_region,
        file_bytes,
        payload.page - 1,
        x_start_pct=payload.x_start_pct,
        x_end_pct=payload.x_end_pct,
        y_start_pct=payload.y_start_pct,
        y_end_pct=payload.y_end_pct,
        margin_pct=payload.margin_pct,
    )
    return SnapResponse(**snapped)


def _load_cached_enhancements(job_dir: Path) -> dict:
    path = job_dir / "enhancements.json"
    if path.exists():
        try:
            return json.loads(path.read_text("utf-8"))
        except Exception:
            pass
    return {
        "binarize": False,
        "contrast": 1.0,
        "brightness": 1.0,
        "watermark_threshold": 255,
        "deskew": False,
    }


@router.post("/crop/preview")
async def crop_preview(
    request: Request,
    payload: CropPreviewRequest,
    settings: Settings = Depends(get_settings),
) -> Response:
    """Render ONE reviewed item as a standalone preview image (no ZIP).

    Reuses the exact crop/stitch pipeline the finalized download runs
    (:func:`crop_and_stitch_hires` with the same furniture removal, padding and
    optional part-alignment), so the returned PNG/JPG is a faithful "what you
    see is what you get" preview of how that single question/solution will look
    after cropping. Nothing is written to disk and the answer sheet / ZIP are
    untouched — this is a read-only render off the PDF the matching ``/analyze``
    or ``/prepare-manual`` call cached under the job dir.
    """

    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(payload.job_id, temp_root)
    source_pdf = job_dir / "source.pdf"

    def _exists(p: Path) -> bool:
        return p.exists()

    if not await asyncio.to_thread(_exists, source_pdf):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=ERR_JOB_NOT_FOUND)

    if not payload.segments:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No region to preview. Draw or select a box first.",
        )

    fmt = (payload.image_format or "png").strip().lower()
    out_format = "jpg" if fmt in ("jpg", "jpeg") else "png"
    dpi = max(72, min(600, int(payload.dpi or 200)))
    padding = max(0, min(200, int(payload.padding or 0)))
    jpg_quality = max(1, min(100, int(payload.jpg_quality or 90)))

    question = DetectedQuestion(
        q_num=(payload.q_num or "0").strip() or "0",
        is_solution=bool(payload.is_solution),
        segments=list(payload.segments),
        source=payload.source or "auto",
        align=payload.align,
        is_hindi=payload.is_hindi,
    )

    file_bytes = await asyncio.to_thread(source_pdf.read_bytes)

    enh = _load_cached_enhancements(job_dir)

    def _render() -> bytes:
        import io
        from PIL import Image

        crop_dpi = max(dpi, settings.CROP_RENDER_DPI)
        with fitz.open(stream=file_bytes, filetype="pdf") as doc:
            furniture_by_page = collect_document_furniture(doc)
            img = crop_and_stitch_hires(
                doc,
                question,
                padding_px=padding,
                detection_dpi=dpi,
                crop_dpi=crop_dpi,
                furniture_by_page=furniture_by_page,
                align_parts=_should_align_parts(question),
                binarize=enh.get("binarize", False),
                contrast=enh.get("contrast", 1.0),
                brightness=enh.get("brightness", 1.0),
                watermark_threshold=enh.get("watermark_threshold", 255),
                deskew=enh.get("deskew", False),
            )

            if payload.bilingual_mode in ("bilingual_horizontal", "bilingual_vertical", "bilingual_separate") and payload.other_segments:
                other_q = DetectedQuestion(
                    q_num=question.q_num,
                    is_solution=question.is_solution,
                    segments=list(payload.other_segments),
                    source=payload.source or "auto",
                    align=payload.align,
                )
                other_img = crop_and_stitch_hires(
                    doc,
                    other_q,
                    padding_px=padding,
                    detection_dpi=dpi,
                    crop_dpi=crop_dpi,
                    furniture_by_page=furniture_by_page,
                    align_parts=_should_align_parts(other_q),
                    binarize=enh.get("binarize", False),
                    contrast=enh.get("contrast", 1.0),
                    brightness=enh.get("brightness", 1.0),
                    watermark_threshold=enh.get("watermark_threshold", 255),
                    deskew=enh.get("deskew", False),
                )

                gap = 20
                if payload.bilingual_mode in ("bilingual_horizontal", "bilingual_separate"):
                    w = img.width + other_img.width + gap
                    h = max(img.height, other_img.height)
                    bilingual_img = Image.new("RGB", (w, h), (255, 255, 255))
                    bilingual_img.paste(img, (0, 0))
                    bilingual_img.paste(other_img, (img.width + gap, 0))
                    img = bilingual_img
                else: # bilingual_vertical
                    w = max(img.width, other_img.width)
                    h = img.height + other_img.height + gap
                    bilingual_img = Image.new("RGB", (w, h), (255, 255, 255))
                    bilingual_img.paste(img, (0, 0))
                    bilingual_img.paste(other_img, (0, img.height + gap))
                    img = bilingual_img

        buf = io.BytesIO()
        if out_format == "jpg":
            ensure_rgb(img).save(buf, format="JPEG", quality=jpg_quality, optimize=True)
        else:
            ensure_rgb(img).save(buf, format="PNG")
        return buf.getvalue()

    try:
        image_bytes = await asyncio.to_thread(_render)
    except Exception as exc:
        logger.exception("job_id=%s stage=preview_error error=%s", payload.job_id, str(exc))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Could not render this preview.",
        ) from exc

    media_type = "image/jpeg" if out_format == "jpg" else "image/png"
    # Previews change as the user re-selects / toggles align, so never cache.
    return Response(
        content=image_bytes,
        media_type=media_type,
        headers={"Cache-Control": "no-store"},
    )


@router.post("/finalize", response_model=CropResponse)
async def finalize_crop(
    request: Request,
    payload: FinalizeRequest,
    settings: Settings = Depends(get_settings),
) -> CropResponse:
    """Crop a reviewed item list (auto + manual) into the downloadable ZIP.

    The original PDF was cached by ``/analyze`` under the job dir, so finalize
    re-renders crisp, high-DPI crops straight from the vector source. Items here
    can be the pipeline's own detections that the user kept, manually drawn
    regions for missed questions, or both — they are treated identically.
    """

    job_id = payload.job_id
    temp_root = _get_temp_root(request, settings)
    request_id = getattr(request.state, "request_id", None)

    job_dir = get_job_dir(job_id, temp_root)
    source_pdf = job_dir / "source.pdf"

    def _exists(p: Path) -> bool:
        return p.exists()

    if not await asyncio.to_thread(_exists, source_pdf):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=ERR_JOB_NOT_FOUND)

    if not payload.items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_NO_QUESTIONS)

    fmt = (payload.image_format or "png").strip().lower()
    out_format = "jpg" if fmt in ("jpg", "jpeg") else "png"
    q_prefix = (payload.question_prefix or "Q").strip() or "Q"
    s_prefix = (payload.solution_prefix or "S").strip() or "S"
    eq_prefix = (payload.english_question_prefix or "EQ").strip() or "EQ"
    es_prefix = (payload.english_solution_prefix or "ES").strip() or "ES"
    hq_prefix = (payload.hindi_question_prefix or "HQ").strip() or "HQ"
    hs_prefix = (payload.hindi_solution_prefix or "HS").strip() or "HS"
    dpi = max(72, min(600, int(payload.dpi or 200)))
    padding = max(0, min(200, int(payload.padding or 0)))
    start_number = max(1, int(payload.start_number or 1))
    jpg_quality = max(1, min(100, int(payload.jpg_quality or 90)))

    # Drop near-identical regions first (e.g. an auto box and a hand-drawn box
    # over the same question that got different numbers), then collapse anything
    # that still maps to the same output filename. Without the overlap pass two
    # boxes for one question survive — that's the "22 questions show as 25 with
    # duplicates" case from the review flow.
    detected = _analyzed_to_detected(payload.items)
    detected = _dedupe_by_overlap(detected)
    detected = _dedupe_by_output_file(detected, payload.bilingual_mode)
    if not detected:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_NO_QUESTIONS)

    if settings.LOCAL_ML_COLLECT_TRAINING_DATA:
        training_root = Path(settings.LOCAL_ML_TRAINING_DIR).expanduser()
        if not training_root.is_absolute():
            training_root = Path.cwd() / training_root
        await asyncio.to_thread(
            write_training_example,
            job_id=job_id,
            source_pdf=source_pdf,
            questions=detected,
            output_root=training_root,
        )

    file_bytes = await asyncio.to_thread(source_pdf.read_bytes)
    enh = _load_cached_enhancements(job_dir)

    def _crop_and_save_all() -> tuple[list[Path], list[Path], int]:
        question_paths: list[Path] = []
        solution_paths: list[Path] = []
        stitched = 0
        crop_dpi = max(dpi, settings.CROP_RENDER_DPI)

        # Partition questions for bilingual export if requested
        if payload.bilingual_mode in ("english", "hindi", "bilingual_horizontal", "bilingual_vertical", "bilingual_separate"):
            grouped = {}
            for item in detected:
                key = (item.is_solution, item.q_num)
                grouped.setdefault(key, []).append(item)

            filtered_items = []
            for (is_sol, q_num), items in grouped.items():
                # New path: the bilingual merge pass already paired the English
                # and Hindi segments into a single item with other_segments.
                if len(items) == 1 and getattr(items[0], "other_segments", None):
                    en_item = items[0]
                    if payload.bilingual_mode == "english":
                        setattr(en_item, "_bilingual_lang", "english")
                        filtered_items.append(en_item)
                    elif payload.bilingual_mode == "hindi":
                        # Build a DetectedQuestion using the other_segments as
                        # its primary segments (the Hindi column).
                        hi_item = DetectedQuestion(
                            q_num=en_item.q_num,
                            is_solution=en_item.is_solution,
                            segments=en_item.other_segments,
                        )
                        setattr(hi_item, "_bilingual_lang", "hindi")
                        filtered_items.append(hi_item)
                    elif payload.bilingual_mode == "bilingual_separate":
                        hi_item = DetectedQuestion(
                            q_num=en_item.q_num,
                            is_solution=en_item.is_solution,
                            segments=en_item.other_segments,
                        )
                        setattr(en_item, "_bilingual_lang", "english")
                        setattr(hi_item, "_bilingual_lang", "hindi")
                        filtered_items.append(en_item)
                        filtered_items.append(hi_item)
                    else:  # bilingual_horizontal or bilingual_vertical
                        hi_item = DetectedQuestion(
                            q_num=en_item.q_num,
                            is_solution=en_item.is_solution,
                            segments=en_item.other_segments,
                        )
                        setattr(en_item, "_bilingual_other", hi_item)
                        filtered_items.append(en_item)
                elif len(items) >= 2:
                    # Legacy path: duplicate q_nums from two columns (e.g. when
                    # the bilingual merge didn't run, or manual items).
                    import functools

                    en_candidates = [it for it in items if getattr(it, "is_hindi", None) is False]
                    hi_candidates = [it for it in items if getattr(it, "is_hindi", None) is True]

                    if len(en_candidates) == 1 and len(hi_candidates) == 1:
                        en_item = en_candidates[0]
                        hi_item = hi_candidates[0]
                    else:
                        def compare_items(it1, it2):
                            p1 = it1.segments[0].page if it1.segments else 0
                            p2 = it2.segments[0].page if it2.segments else 0
                            if p1 != p2:
                                return -1 if p1 < p2 else 1

                            s1 = it1.segments[0] if it1.segments else None
                            s2 = it2.segments[0] if it2.segments else None
                            if not s1 or not s2:
                                return 0

                            c1 = (s1.x_start_pct + s1.x_end_pct) / 2.0
                            c2 = (s2.x_start_pct + s2.x_end_pct) / 2.0
                            is_side_by_side = (abs(s1.x_start_pct - s2.x_start_pct) > 15.0) or (abs(c1 - c2) > 15.0)

                            if is_side_by_side:
                                return -1 if s1.x_start_pct < s2.x_start_pct else (1 if s1.x_start_pct > s2.x_start_pct else 0)
                            else:
                                return -1 if s1.y_start_pct < s2.y_start_pct else (1 if s1.y_start_pct > s2.y_start_pct else 0)

                        items.sort(key=functools.cmp_to_key(compare_items))
                        en_item = items[0]
                        hi_item = items[1]

                    if payload.bilingual_mode == "english":
                        setattr(en_item, "_bilingual_lang", "english")
                        filtered_items.append(en_item)
                    elif payload.bilingual_mode == "hindi":
                        setattr(hi_item, "_bilingual_lang", "hindi")
                        filtered_items.append(hi_item)
                    elif payload.bilingual_mode == "bilingual_separate":
                        setattr(en_item, "_bilingual_lang", "english")
                        setattr(hi_item, "_bilingual_lang", "hindi")
                        filtered_items.append(en_item)
                        filtered_items.append(hi_item)
                    else: # bilingual_horizontal or bilingual_vertical
                        setattr(en_item, "_bilingual_other", hi_item)
                        filtered_items.append(en_item)
                else:
                    item = items[0]
                    if getattr(item, "is_hindi", None) is not None:
                        setattr(item, "_bilingual_lang", "hindi" if item.is_hindi else "english")
                    elif payload.bilingual_mode == "english":
                        setattr(item, "_bilingual_lang", "english")
                    elif payload.bilingual_mode == "hindi":
                        setattr(item, "_bilingual_lang", "hindi")
                    else: # bilingual_horizontal, bilingual_vertical, bilingual_separate
                        s = item.segments[0] if item.segments else None
                        if s and s.x_start_pct > 50.0:
                            setattr(item, "_bilingual_lang", "hindi")
                        else:
                            setattr(item, "_bilingual_lang", "english")
                    filtered_items.append(item)
            items_to_crop = filtered_items
        else:
            items_to_crop = detected

        with fitz.open(stream=file_bytes, filetype="pdf") as doc:
            furniture_by_page = collect_document_furniture(doc)
            from PIL import Image
            for question in items_to_crop:
                if len(question.segments) > 1:
                    stitched += 1
                img = crop_and_stitch_hires(
                    doc,
                    question,
                    padding_px=padding,
                    detection_dpi=dpi,
                    crop_dpi=crop_dpi,
                    furniture_by_page=furniture_by_page,
                    # Left-align column-split parts when the item asks for it.
                    # Defaults to manual-only so the auto path's output is
                    # untouched; an explicit `align` override (the review "Align
                    # parts" toggle) wins so the file matches the preview.
                    align_parts=_should_align_parts(question),
                    binarize=enh.get("binarize", False),
                    contrast=enh.get("contrast", 1.0),
                    brightness=enh.get("brightness", 1.0),
                    watermark_threshold=enh.get("watermark_threshold", 255),
                    deskew=enh.get("deskew", False),
                )

                other = getattr(question, "_bilingual_other", None)
                if other is not None:
                    other_img = crop_and_stitch_hires(
                        doc,
                        other,
                        padding_px=padding,
                        detection_dpi=dpi,
                        crop_dpi=crop_dpi,
                        furniture_by_page=furniture_by_page,
                        align_parts=_should_align_parts(other),
                        binarize=enh.get("binarize", False),
                        contrast=enh.get("contrast", 1.0),
                        brightness=enh.get("brightness", 1.0),
                        watermark_threshold=enh.get("watermark_threshold", 255),
                        deskew=enh.get("deskew", False),
                    )

                    gap = 20
                    if payload.bilingual_mode == "bilingual_horizontal":
                        w = img.width + other_img.width + gap
                        h = max(img.height, other_img.height)
                        bilingual_img = Image.new("RGB", (w, h), (255, 255, 255))
                        bilingual_img.paste(img, (0, 0))
                        bilingual_img.paste(other_img, (img.width + gap, 0))
                        img = bilingual_img
                    else: # bilingual_vertical
                        w = max(img.width, other_img.width)
                        h = img.height + other_img.height + gap
                        bilingual_img = Image.new("RGB", (w, h), (255, 255, 255))
                        bilingual_img.paste(img, (0, 0))
                        bilingual_img.paste(other_img, (0, img.height + gap))
                        img = bilingual_img

                lang = getattr(question, "_bilingual_lang", None)
                if payload.bilingual_mode in ("english", "hindi", "bilingual_horizontal", "bilingual_vertical", "bilingual_separate"):
                    curr_q_prefix = eq_prefix if (lang == "english" or lang is None) else hq_prefix
                    curr_s_prefix = es_prefix if (lang == "english" or lang is None) else hs_prefix
                else:
                    curr_q_prefix = q_prefix
                    curr_s_prefix = s_prefix

                saved = save_question_image(
                    image=img,
                    q_num=question.q_num,
                    output_dir=job_dir,
                    is_solution=question.is_solution,
                    question_prefix=curr_q_prefix,
                    solution_prefix=curr_s_prefix,
                    start_number=start_number,
                    image_format=out_format,
                    jpg_quality=jpg_quality,
                )
                if question.is_solution:
                    solution_paths.append(saved)
                else:
                    question_paths.append(saved)
        return question_paths, solution_paths, stitched

    try:
        question_paths, solution_paths, stitched_questions = await asyncio.to_thread(_crop_and_save_all)

        # Attach the answer sheet using the key cached by /analyze (no re-parse,
        # no extra AI call). Missing/empty key simply writes no sheet.
        def _load_cached_key() -> dict[int, str]:
            key_path = job_dir / "answer_key.json"
            if not key_path.exists():
                return {}
            try:
                raw = json.loads(key_path.read_text(encoding="utf-8"))
                return {int(k): str(v) for k, v in (raw or {}).items()}
            except Exception:
                return {}

        answer_key = await asyncio.to_thread(_load_cached_key)
        if not payload.answer_sheet:
            answer_key = {}
        sheet_paths = await asyncio.to_thread(
            write_answer_sheet,
            detected,
            answer_key,
            job_dir,
            question_prefix=q_prefix,
            solution_prefix=s_prefix,
            start_number=start_number,
            image_format=out_format,
            always=payload.answer_sheet,
        )
        answers_count = count_answered(detected, answer_key, start_number=start_number)

        await asyncio.to_thread(
            create_zip_set, question_paths, solution_paths, job_id, job_dir, sheet_paths
        )
    except Exception as exc:
        logger.exception("request_id=%s job_id=%s stage=finalize_error error=%s", request_id, job_id, str(exc))
        raise

    total_questions = len(question_paths) + len(solution_paths)
    logger.info(
        "request_id=%s job_id=%s stage=finalize_done total_questions=%s stitched_questions=%s",
        request_id,
        job_id,
        total_questions,
        stitched_questions,
    )

    return CropResponse(
        job_id=job_id,
        total_questions=total_questions,
        stitched_questions=stitched_questions,
        method_used="text",  # finalize is post-review crop only; no detection runs here
        download_url=f"/api/crop/download/{job_id}",
        questions_download_url=(
            f"/api/crop/download/{job_id}?kind=questions" if question_paths else None
        ),
        solutions_download_url=(
            f"/api/crop/download/{job_id}?kind=solutions" if solution_paths else None
        ),
        questions_count=len(question_paths),
        solutions_count=len(solution_paths),
        answer_sheet_included=bool(sheet_paths),
        answers_count=answers_count,
    )


@router.get("/crop/download/{job_id}")
async def download_zip(
    request: Request,
    job_id: str,
    kind: str = Query(
        "combined",
        description="Which archive to download: 'combined' (questions + solutions), "
        "'questions' (questions only), or 'solutions' (solutions only).",
    ),
    question_prefix: str = Query("Q", max_length=10),
    solution_prefix: str = Query("S", max_length=10),
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    """Download a generated ZIP for a completed job.

    ``kind`` selects the combined archive (default) or one of the per-type
    archives. The user-facing filename follows the configured prefixes, e.g.
    ``Q.zip`` for questions, ``S.zip`` for solutions, and ``QScombined.zip`` for
    the combined archive.
    """

    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(job_id, temp_root)

    requested = (kind or "combined").strip().lower()
    if requested not in ("combined", "questions", "solutions"):
        requested = "combined"

    q_prefix = (question_prefix or "Q").strip() or "Q"
    s_prefix = (solution_prefix or "S").strip() or "S"

    if requested == "questions":
        zip_path = job_dir / QUESTIONS_ZIP.format(job_id=job_id)
        download_name = f"{q_prefix}.zip"
    elif requested == "solutions":
        zip_path = job_dir / SOLUTIONS_ZIP.format(job_id=job_id)
        download_name = f"{s_prefix}.zip"
    else:
        zip_path = job_dir / COMBINED_ZIP.format(job_id=job_id)
        download_name = f"{q_prefix}{s_prefix}combined.zip"

    def _exists(p: Path) -> bool:
        return p.exists()

    exists = await asyncio.to_thread(_exists, zip_path)
    if not exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=ERR_JOB_NOT_FOUND)

    return FileResponse(
        str(zip_path),
        media_type="application/zip",
        filename=download_name,
    )


@router.get("/config/ml-model", response_model=MLConfigResponse)
async def get_ml_config(settings: Settings = Depends(get_settings)) -> MLConfigResponse:
    """Get the current local ML configuration and availability status."""
    local_ml_detector = build_local_ml_detector(settings)
    local_ml_available = (
        local_ml_detector is not None and local_ml_detector.is_available()
    )
    return MLConfigResponse(
        model_path=settings.LOCAL_ML_MODEL_PATH,
        labels_path=settings.LOCAL_ML_LABELS_PATH,
        model_name=settings.LOCAL_ML_MODEL_NAME,
        confidence=settings.LOCAL_ML_CONFIDENCE,
        input_size=settings.LOCAL_ML_INPUT_SIZE,
        local_ml_available=local_ml_available,
    )


@router.post("/config/ml-model", response_model=MLConfigResponse)
async def update_ml_config(
    req: MLConfigRequest,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> MLConfigResponse:
    """Update the local ML configuration parameters at runtime."""
    if req.model_path is not None:
        settings.LOCAL_ML_MODEL_PATH = req.model_path
    if req.labels_path is not None:
        settings.LOCAL_ML_LABELS_PATH = req.labels_path
    if req.model_name is not None:
        settings.LOCAL_ML_MODEL_NAME = req.model_name
    if req.confidence is not None:
        settings.LOCAL_ML_CONFIDENCE = req.confidence
    if req.input_size is not None:
        settings.LOCAL_ML_INPUT_SIZE = req.input_size

    local_ml_detector = build_local_ml_detector(settings)
    local_ml_available = (
        local_ml_detector is not None and local_ml_detector.is_available()
    )
    return MLConfigResponse(
        model_path=settings.LOCAL_ML_MODEL_PATH,
        labels_path=settings.LOCAL_ML_LABELS_PATH,
        model_name=settings.LOCAL_ML_MODEL_NAME,
        confidence=settings.LOCAL_ML_CONFIDENCE,
        input_size=settings.LOCAL_ML_INPUT_SIZE,
        local_ml_available=local_ml_available,
    )


@router.post("/tools/regex-test", response_model=RegexTestResponse)
async def test_regex(req: RegexTestRequest) -> RegexTestResponse:
    """Test a custom regex pattern against sample text lines."""
    results = []
    from ..services.detector.base import match_question_start_ex
    import re

    for line in req.sample_lines:
        match_res = match_question_start_ex(line, custom_regex=req.pattern)
        if match_res is not None:
            q_num, is_strong = match_res
            groups = []
            try:
                pat = re.compile(req.pattern, re.IGNORECASE)
                match = pat.match(line.strip())
                if match:
                    groups = [str(g) if g is not None else "" for g in match.groups()]
            except Exception:
                pass
            results.append(
                RegexMatchResult(
                    line=line,
                    matched=True,
                    q_num=q_num,
                    groups=groups,
                )
            )
        else:
            results.append(
                RegexMatchResult(
                    line=line,
                    matched=False,
                    q_num=None,
                    groups=[],
                )
            )

    return RegexTestResponse(pattern=req.pattern, results=results)


@router.post("/tools/align-offsets", response_model=AlignOffsetsResponse)
async def calculate_align_offsets(
    request: Request,
    payload: AlignOffsetsRequest,
    settings: Settings = Depends(get_settings),
) -> AlignOffsetsResponse:
    """Calculate horizontal alignment offsets to align subsequent segment crop boundaries to Segment #1."""
    temp_root = settings.TEMP_DIR
    job_dir = get_job_dir(payload.job_id, temp_root)
    source_pdf = job_dir / "source.pdf"
    if not source_pdf.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=ERR_JOB_NOT_FOUND
        )

    if not payload.segments:
        return AlignOffsetsResponse(offsets=[])

    # Try to calculate alignment using dynamic PDF column margins
    doc = None
    try:
        import fitz
        import numpy as np
        doc = fitz.open(source_pdf)
    except Exception as exc:
        logger.error("Failed to import fitz/numpy or open PDF in calculate_align_offsets: %s", exc)
        doc = None

    if doc is not None:
        try:
            def find_standard_column_margins(page: fitz.Page) -> list[float]:
                rect = page.rect
                pw = float(rect.width)
                try:
                    data = page.get_text("dict") or {}
                except Exception:
                    return [0.10 * pw]
                x_coords = []
                for block in data.get("blocks", []):
                    for ln in block.get("lines", []):
                        spans = ln.get("spans", [])
                        if not spans:
                            continue
                        text = "".join(s.get("text", "") for s in spans).strip()
                        if not text:
                            continue
                        x0, y0, x1, y1 = ln.get("bbox", (0, 0, 0, 0))
                        if x0 < 5.0 or x1 > pw - 5.0:
                            continue
                        x_coords.append(x0)
                        
                if not x_coords:
                    return [0.10 * pw]
                    
                x_coords.sort()
                clusters = []
                current_cluster = [x_coords[0]]
                for x in x_coords[1:]:
                    if x - current_cluster[-1] <= 15.0:
                        current_cluster.append(x)
                    else:
                        clusters.append(current_cluster)
                        current_cluster = [x]
                clusters.append(current_cluster)
                
                # Separate clusters into Left Column (< 45% of page width) and Right Column (>= 45%)
                left_clusters = [c for c in clusters if np.median(c) < 0.45 * pw]
                right_clusters = [c for c in clusters if np.median(c) >= 0.45 * pw]
                
                std_margins = []
                if left_clusters:
                    best_left = max(left_clusters, key=len)
                    std_margins.append(float(np.median(best_left)))
                else:
                    std_margins.append(0.10 * pw)
                    
                if right_clusters:
                    best_right = max(right_clusters, key=len)
                    std_margins.append(float(np.median(best_right)))
                    
                return std_margins

            seg1 = payload.segments[0]
            page1 = doc.load_page(seg1.page - 1)
            pw1 = float(page1.rect.width)
            margins1 = find_standard_column_margins(page1)
            
            seg1_x = (seg1.x_start_pct / 100.0) * pw1
            ref_margin = min(margins1, key=lambda m: abs(m - seg1_x)) if margins1 else seg1_x
            ref_margin_pct = (ref_margin / pw1) * 100.0
            
            offsets = []
            for i, seg in enumerate(payload.segments):
                if i == 0:
                    offsets.append(0.0)
                    logger.info("segment_index=0 page=%s x_start_pct=%s offset_pct=0.0 (reference)", seg.page, seg.x_start_pct)
                    continue
                
                page = doc.load_page(seg.page - 1)
                pw = float(page.rect.width)
                margins = find_standard_column_margins(page)
                
                seg_x = (seg.x_start_pct / 100.0) * pw
                seg_margin = min(margins, key=lambda m: abs(m - seg_x)) if margins else seg_x
                seg_margin_pct = (seg_margin / pw) * 100.0
                
                # Formula to align column margins
                offset_pct = (seg.x_start_pct - seg_margin_pct) - (seg1.x_start_pct - ref_margin_pct)
                
                # Clamp offset to [-15.0, 15.0] to prevent extreme shifts
                offset_pct = max(-15.0, min(15.0, offset_pct))
                offset_pct = round(offset_pct, 2)
                
                offsets.append(offset_pct)
                logger.info(
                    "segment_index=%s page=%s x_start_pct=%s seg_margin_pct=%s offset_pct=%s",
                    i, seg.page, seg.x_start_pct, seg_margin_pct, offset_pct
                )
            
            doc.close()
            logger.info("calculate_align_offsets fitz-based result_offsets=%s", offsets)
            return AlignOffsetsResponse(offsets=offsets)
        except Exception as exc:
            logger.error("Error executing fitz-based alignment in calculate_align_offsets: %s", exc)
            if doc is not None:
                doc.close()

    # Simple/Fallback alignment logic
    current_ref = payload.segments[0].x_start_pct
    offsets = []
    logger.info("calculate_align_offsets (fallback) payload_job_id=%s initial_ref=%s", payload.job_id, current_ref)
    for i, seg in enumerate(payload.segments):
        if i == 0:
            offsets.append(0.0)
            logger.info("segment_index=0 page=%s x_start_pct=%s offset_pct=0.0 (reference)", seg.page, seg.x_start_pct)
            continue

        offset_pct = seg.x_start_pct - current_ref
        if abs(offset_pct) > 15.0:
            offset_pct = 0.0
            current_ref = seg.x_start_pct
            logger.info("segment_index=%s page=%s x_start_pct=%s offset_pct=0.0 (column cross, new_ref=%s)", i, seg.page, seg.x_start_pct, current_ref)
        else:
            offset_pct = max(-10.0, min(10.0, offset_pct))
            logger.info("segment_index=%s page=%s x_start_pct=%s offset_pct=%s (aligned to current_ref=%s)", i, seg.page, seg.x_start_pct, offset_pct, current_ref)
        offsets.append(offset_pct)

    logger.info("calculate_align_offsets (fallback) result_offsets=%s", offsets)
    return AlignOffsetsResponse(offsets=offsets)


