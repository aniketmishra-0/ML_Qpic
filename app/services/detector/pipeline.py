"""Auto-detection orchestrator for the 3-tier pipeline."""

from __future__ import annotations

import asyncio
import inspect
import logging
import re
from pathlib import Path
from typing import Any, Optional

import fitz
from PIL import Image

from ...config import Settings
from ...models.schemas import DetectedQuestion
from .base import merge_bilingual_pairs
from .ai_detector import AIDetector
from .ocr_detector import OCRDetector
from .google_ocr_detector import GoogleOCRDetector
from .paddle_ocr_detector import PaddleOCRDetector
from .text_detector import TextDetector

logger = logging.getLogger(__name__)


class DetectionPipeline:
    """Tries detection methods in order and falls back when results are insufficient."""

    def __init__(
        self,
        *,
        text_detector: Optional[TextDetector] = None,
        ocr_detector: Optional[OCRDetector] = None,
        google_ocr_detector: Optional[GoogleOCRDetector] = None,
        paddle_ocr_detector: Optional[PaddleOCRDetector] = None,
        ai_detector: Optional[AIDetector] = None,
        local_ml_detector: Optional[Any] = None,
    ) -> None:
        self.text_detector = text_detector or TextDetector()
        self.ocr_detector = ocr_detector or OCRDetector()
        self.google_ocr_detector = google_ocr_detector or GoogleOCRDetector()
        self.paddle_ocr_detector = paddle_ocr_detector or PaddleOCRDetector()
        self.local_ml_detector = local_ml_detector
        self.ai_detector = ai_detector

    async def detect(
        self,
        pdf_source: bytes | str | Path,
        page_images: list[Image.Image],
        settings: Settings,
        *,
        render_dpi: Optional[int] = None,
        smart: bool = False,
        prefer_ai: bool = False,
        use_google_ocr: bool = False,
        use_paddle_ocr: bool = False,
        marker_style: str = "auto",
        layout_columns: Optional[int] = None,
        confidence: Optional[float] = None,
        custom_regex: Optional[str] = None,
    ) -> tuple[list[DetectedQuestion], str]:
        questions, method = await self._detect_raw(
            pdf_source,
            page_images,
            settings,
            render_dpi=render_dpi,
            smart=smart,
            prefer_ai=prefer_ai,
            use_google_ocr=use_google_ocr,
            use_paddle_ocr=use_paddle_ocr,
            marker_style=marker_style,
            layout_columns=layout_columns,
            confidence=confidence,
            custom_regex=custom_regex,
        )
        questions = resolve_vertical_overlaps(questions)
        # Merge bilingual duplicate pairs (e.g. English left + Hindi right)
        # into single items with other_segments. This runs as a post-processing
        # step on every detector's output so local_ml, AI, OCR all benefit.
        questions = merge_bilingual_pairs(questions)
        return questions, method

    async def _detect_raw(
        self,
        pdf_source: bytes | str | Path,
        page_images: list[Image.Image],
        settings: Settings,
        *,
        render_dpi: Optional[int] = None,
        smart: bool = False,
        prefer_ai: bool = False,
        use_google_ocr: bool = False,
        use_paddle_ocr: bool = False,
        marker_style: str = "auto",
        layout_columns: Optional[int] = None,
        confidence: Optional[float] = None,
        custom_regex: Optional[str] = None,
    ) -> tuple[list[DetectedQuestion], str]:
        """Return (questions, method_used).

        method_used: "text" | "ocr" | "local_ml" | "ai"

        When ``prefer_ai`` is True (the user explicitly turned the online/AI
        toggle on) and a vision detector is configured, the AI tier runs *first*
        as the primary detector. Its result is returned whenever it finds
        anything; only when AI yields nothing (rate-limited, unparseable, no
        key) does the pipeline fall back to the cheap text/OCR tiers. This is
        what makes the toggle actually change the output — otherwise the cheap
        tiers satisfy the "sufficient" gate on a normal paper and short-circuit
        before AI is ever called.

        When ``smart`` is True the pipeline runs the cheap tiers first but only
        accepts their result if it looks *confident* (see
        :meth:`_result_is_confident`). Otherwise — odd layouts, broken
        numbering, sparse hits — it escalates to the AI vision tier whenever one
        is configured, so genuinely "any PDF" is handled instead of returning a
        thin regex result. With ``smart`` off the original cheap-first,
        sufficient-enough behaviour is preserved exactly.

        ``marker_style`` (``"auto"`` | ``"q"`` | ``"numbered"``) restricts which
        numbering counts as a question across every tier, so a paper whose real
        markers are all one style doesn't pick up sub-statements / option labels
        / equation numbers as extra questions.
        """

        total_pages = len(page_images)
        if total_pages <= 0:
            return ([], "text")

        best_questions: list[DetectedQuestion] = []
        best_method: str = "text"

        searchable = self._is_searchable_pdf(pdf_source)
        ai_ready = self.ai_detector is not None and self.ai_detector.is_available()
        local_ml_ready = (
            self.local_ml_detector is not None
            and self.local_ml_detector.is_available()
        )

        # AI-first: when the user opted into the AI tier, use vision as the
        # PRIMARY detector instead of a last-resort fallback. Run it up front and
        # return its result whenever it found anything. If it comes back empty
        # (transient API failure / unparseable response) we degrade gracefully to
        # the cheap tiers below, and disable the duplicate tier-3 AI call so we
        # don't pay for a second round-trip that already failed.
        if prefer_ai and ai_ready:
            logger.info("ai_primary tier_start=ai pages=%s", total_pages)
            ai_questions = await self.ai_detector.detect(
                page_images, settings, marker_style=marker_style
            )
            if ai_questions:
                return ai_questions, "ai"
            logger.info("ai_primary empty_result falling_back=text/ocr")
            # Treat AI as unavailable for the remainder so the cheap-tier gates
            # use the lenient "sufficient" check and tier 2.5/3 don't re-call it.
            ai_ready = False

        if searchable:
            def _detect_text():
                sig = inspect.signature(self.text_detector.detect)
                kwargs = {}
                if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    kwargs["custom_regex"] = custom_regex
                return self.text_detector.detect(
                    pdf_source,
                    settings.QUESTION_PADDING_PX,
                    marker_style,
                    layout_columns,
                    **kwargs
                )

            text_questions = await asyncio.to_thread(_detect_text)
            if len(text_questions) > len(best_questions):
                best_questions, best_method = text_questions, "text"
            # In smart mode, only short-circuit on a *confident* text result; a
            # thin or ragged one falls through so AI can do better.
            accept = (
                self._result_is_confident(text_questions, total_pages, settings)
                if (smart and ai_ready)
                else self._result_is_sufficient(text_questions, total_pages, settings)
            )
            if accept:
                # Page-level hybrid routing
                final_questions = []
                ocr_run_pages = []
                
                accumulated_ocr_lines = {}
                accumulated_ocr_conf = {}
                
                for page_num in range(1, total_pages + 1):
                    page_class = self._page_classes.get(page_num, "text")
                    text_q = [q for q in text_questions if any(seg.page == page_num for seg in q.segments)]
                    
                    if self._should_run_ocr_for_page(page_num, page_class, text_q):
                        logger.info("hybrid_pdf: running OCR fallback for page %s (class: %s)", page_num, page_class)
                        page_img = page_images[page_num - 1]
                        ocr_q = await self._detect_ocr_single_page(
                            page_img,
                            page_num,
                            settings,
                            render_dpi=render_dpi,
                            use_google_ocr=use_google_ocr,
                            use_paddle_ocr=use_paddle_ocr,
                            marker_style=marker_style,
                            layout_columns=layout_columns,
                            custom_regex=custom_regex,
                        )
                        
                        # Accumulate OCR page lines and confidence
                        active_detector = self.ocr_detector
                        google_ocr_ready = self.google_ocr_detector is not None and self.google_ocr_detector.is_available()
                        if use_google_ocr and google_ocr_ready:
                            active_detector = self.google_ocr_detector
                        elif (use_paddle_ocr or getattr(settings, "USE_PADDLE_OCR", False)) and self.paddle_ocr_detector.is_available():
                            active_detector = self.paddle_ocr_detector
                            
                        conf = getattr(active_detector, "page_confidence", None)
                        if conf and 1 in conf:
                            accumulated_ocr_conf[page_num] = conf[1]
                        lines = getattr(active_detector, "page_lines_pct", None)
                        if lines and 1 in lines:
                            accumulated_ocr_lines[page_num] = lines[1]
                        
                        # Decide whether to use OCR or text result for this page
                        use_ocr = False
                        if page_class == "ocr":
                            use_ocr = True
                        elif len(ocr_q) > len(text_q):
                            use_ocr = True
                            logger.info("Page %s: Using OCR result because len(ocr) %d > len(text) %d", page_num, len(ocr_q), len(text_q))
                        else:
                            text_cols = self._check_column_spread(text_q)
                            ocr_cols = self._check_column_spread(ocr_q)
                            if len(ocr_cols) > len(text_cols):
                                use_ocr = True
                                logger.info("Page %s: Using OCR result because OCR spans more columns: %s vs %s", page_num, ocr_cols, text_cols)
                                
                        if use_ocr:
                            final_questions.extend(ocr_q)
                            ocr_run_pages.append(page_num)
                        else:
                            final_questions.extend(text_q)
                    else:
                        final_questions.extend(text_q)
                
                # Deduplicate final_questions by object reference ID to avoid duplicates of multi-page questions
                seen_ids = set()
                deduped_final = []
                for q in final_questions:
                    if id(q) not in seen_ids:
                        seen_ids.add(id(q))
                        deduped_final.append(q)
                final_questions = deduped_final

                # Expose accumulated OCR data on the ocr_detector object so downstream review can use it
                self.ocr_detector.page_confidence = accumulated_ocr_conf
                self.ocr_detector.page_lines_pct = accumulated_ocr_lines
                
                if ocr_run_pages:
                    logger.info(
                        "hybrid_pdf text_accepted but_ocr_pages=%s (used OCR fallback on pages %s)",
                        [p for p, cls in self._page_classes.items() if cls == 'ocr'],
                        ocr_run_pages,
                    )
                    # Return the combined questions, mapped to "text" method so the pipeline accepts it
                    return final_questions, "text"
                else:
                    return text_questions, "text"
        else:
            logger.info("pdf_not_searchable tier_start=ocr")

        # Tier 2: OCR
        google_ocr_ready = self.google_ocr_detector is not None and self.google_ocr_detector.is_available()
        if use_google_ocr and google_ocr_ready:
            logger.info("google_ocr_primary tier_start=google_ocr pages=%s", total_pages)
            def _detect_google_ocr():
                return self.google_ocr_detector.detect(
                    page_images,
                    settings,
                    render_dpi,
                    marker_style,
                    layout_columns,
                    custom_regex=custom_regex,
                )
            ocr_questions = await asyncio.to_thread(_detect_google_ocr)
            # Map page_lines_pct to ocr_detector for smart mode/review notes compatibility
            if hasattr(self.google_ocr_detector, "page_lines_pct"):
                self.ocr_detector.page_lines_pct = self.google_ocr_detector.page_lines_pct
        elif (use_paddle_ocr or getattr(settings, "USE_PADDLE_OCR", False)) and self.paddle_ocr_detector.is_available():
            logger.info("paddle_ocr_primary tier_start=paddle_ocr pages=%s", total_pages)
            def _detect_paddle_ocr():
                sig = inspect.signature(self.paddle_ocr_detector.detect)
                kwargs = {}
                if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    kwargs["custom_regex"] = custom_regex
                return self.paddle_ocr_detector.detect(
                    page_images,
                    settings,
                    render_dpi,
                    marker_style,
                    layout_columns,
                    **kwargs
                )
            ocr_questions = await asyncio.to_thread(_detect_paddle_ocr)
            if not ocr_questions:
                logger.info("paddle_ocr returned empty, falling back to Tesseract OCR")
                def _detect_ocr():
                    sig = inspect.signature(self.ocr_detector.detect)
                    kwargs = {}
                    if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                        kwargs["custom_regex"] = custom_regex
                    return self.ocr_detector.detect(
                        page_images,
                        settings,
                        render_dpi,
                        marker_style,
                        layout_columns,
                        **kwargs
                    )
                ocr_questions = await asyncio.to_thread(_detect_ocr)
            else:
                # Map page_lines_pct and page_confidence to self.ocr_detector for smart mode/review notes compatibility
                if hasattr(self.paddle_ocr_detector, "page_lines_pct"):
                    self.ocr_detector.page_lines_pct = self.paddle_ocr_detector.page_lines_pct
                if hasattr(self.paddle_ocr_detector, "page_confidence"):
                    self.ocr_detector.page_confidence = self.paddle_ocr_detector.page_confidence
        else:
            def _detect_ocr():
                sig = inspect.signature(self.ocr_detector.detect)
                kwargs = {}
                if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    kwargs["custom_regex"] = custom_regex
                return self.ocr_detector.detect(
                    page_images,
                    settings,
                    render_dpi,
                    marker_style,
                    layout_columns,
                    **kwargs
                )
            ocr_questions = await asyncio.to_thread(_detect_ocr)

        if len(ocr_questions) > len(best_questions):
            best_questions, best_method = ocr_questions, "ocr"
        accept_ocr = (
            self._result_is_confident(ocr_questions, total_pages, settings)
            if (smart and ai_ready)
            else self._result_is_sufficient(ocr_questions, total_pages, settings)
        )
        if accept_ocr:
            return ocr_questions, "ocr"

        # Tier 2.5: Local ML (fully offline).
        #
        # This tier is meant for a bundled/fine-tuned Qpic detector that emits
        # whole question/solution boxes. It sits before any online vision model
        # so hard scanned PDFs can still improve when the user is offline.
        if local_ml_ready:
            sig = inspect.signature(self.local_ml_detector.detect)
            kwargs = {}
            if "confidence" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                kwargs["confidence"] = confidence
            if "layout_columns" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                kwargs["layout_columns"] = layout_columns
            local_questions = await self.local_ml_detector.detect(
                page_images, settings, marker_style=marker_style, **kwargs
            )
            if len(local_questions) > len(best_questions):
                best_questions, best_method = local_questions, "local_ml"
            if local_questions and (
                self._result_is_sufficient(local_questions, total_pages, settings)
                or (not ai_ready and len(local_questions) >= len(best_questions))
            ):
                return local_questions, "local_ml"

        # Tier 2.75: Selective AI repair of weak OCR pages.
        # When OCR produced a usable result but some pages scored low confidence
        # (a few blurry/greyish scans in an otherwise clean document), it's
        # wasteful to re-run the whole document through the AI tier. Instead we
        # send only the low-confidence pages to AI and merge their questions with
        # OCR's, keeping the AI version for any page it covers. This recovers the
        # questions OCR garbled on those pages at a fraction of the AI cost.
        if smart and ai_ready and ocr_questions:
            weak_pages = self._low_confidence_pages(settings)
            if weak_pages and len(weak_pages) < total_pages:
                merged = await self._repair_pages_with_ai(
                    page_images=page_images,
                    ocr_questions=ocr_questions,
                    weak_pages=weak_pages,
                    settings=settings,
                    marker_style=marker_style,
                )
                if merged is not None:
                    if len(merged) > len(best_questions):
                        best_questions, best_method = merged, "ocr"
                    if self._result_is_sufficient(merged, total_pages, settings):
                        return merged, "ocr"

        # Tier 3: AI
        if ai_ready:
            ai_questions = await self.ai_detector.detect(
                page_images, settings, marker_style=marker_style
            )
            if len(ai_questions) > len(best_questions):
                best_questions, best_method = ai_questions, "ai"
            if ai_questions:
                # Even if not "sufficient" by heuristic, return AI output if it produced anything.
                return ai_questions, "ai"

        return best_questions, best_method

    def _low_confidence_pages(self, settings: Settings) -> list[int]:
        """1-indexed pages whose mean OCR confidence fell below the threshold.

        Reads the per-page confidence the OCR detector recorded on its last
        ``detect`` call. Pages that produced no words (confidence 0) are excluded
        — a genuinely blank page has nothing for AI to recover and would only
        waste a call.
        """

        conf = getattr(self.ocr_detector, "page_confidence", None)
        if not conf:
            return []
        threshold = float(getattr(settings, "OCR_MIN_CONFIDENCE", 75.0))
        return [
            page
            for page, value in sorted(conf.items())
            if 0.0 < value < threshold
        ]

    async def _repair_pages_with_ai(
        self,
        *,
        page_images: list[Image.Image],
        ocr_questions: list[DetectedQuestion],
        weak_pages: list[int],
        settings: Settings,
        marker_style: str,
    ) -> Optional[list[DetectedQuestion]]:
        """Re-detect only the weak pages with AI and merge with the OCR result.

        Questions whose segments all lie on weak pages are replaced by the AI
        detections for those pages; questions touching only strong pages are kept
        from OCR untouched. Returns None on any AI failure so the caller falls
        back to the normal flow.
        """

        if self.ai_detector is None or not weak_pages:
            return None

        weak_set = set(weak_pages)
        try:
            # Render a single-page AI request per weak page so coordinates stay
            # in that page's own frame; AIDetector numbers pages from 1, so we
            # remap each returned segment back to the real page number.
            repaired: list[DetectedQuestion] = []
            for page in weak_pages:
                if page < 1 or page > len(page_images):
                    continue
                # Render off the event loop (lazy view rasterises on access).
                page_img = await asyncio.to_thread(lambda p=page: page_images[p - 1])
                single = await self.ai_detector.detect(
                    [page_img], settings, marker_style=marker_style
                )
                for q in single:
                    remapped = [
                        seg.model_copy(update={"page": page}) for seg in q.segments
                    ]
                    if remapped:
                        repaired.append(
                            DetectedQuestion(
                                q_num=q.q_num,
                                is_solution=q.is_solution,
                                segments=remapped,
                            )
                        )
        except Exception as exc:  # pragma: no cover - network/parse failures
            logger.warning("selective_ai_repair_failed pages=%s error=%s", weak_pages, str(exc))
            return None

        if not repaired:
            return None

        # Keep OCR questions that don't touch a weak page; drop those that do
        # (the AI versions replace them), then add the AI detections.
        kept = [
            q for q in ocr_questions
            if not any(seg.page in weak_set for seg in q.segments)
        ]
        merged = kept + repaired
        logger.info(
            "selective_ai_repair weak_pages=%s ocr_kept=%s ai_added=%s",
            weak_pages,
            len(kept),
            len(repaired),
        )
        return merged

    def _classify_pages(
        self, pdf_source: bytes | str | Path
    ) -> dict[int, str]:
        """Classify each page as 'text', 'ocr', or 'text_then_ocr'.

        'text'          — rich native text layer; use PyMuPDF extraction.
        'ocr'           — single full-page image, no text; must OCR.
        'text_then_ocr' — sparse text + images; try text, fall back to OCR.

        Returns a 1-indexed page number → classification mapping. An empty
        dict means the PDF couldn't be opened (fall back to old behaviour).
        """

        try:
            if isinstance(pdf_source, bytes):
                doc = fitz.open(stream=pdf_source, filetype="pdf")
            else:
                doc = fitz.open(str(pdf_source))
            with doc:
                result: dict[int, str] = {}
                for page_idx in range(doc.page_count):
                    page = doc.load_page(page_idx)
                    text = (page.get_text("text") or "").strip()
                    images = page.get_images(full=True)

                    # Filter for large images (exclude small icons/logos)
                    large_images = []
                    try:
                        img_info = page.get_image_info(xrefs=True)
                        page_area = page.rect.width * page.rect.height
                        for img in img_info:
                            bbox = img.get("bbox", (0, 0, 0, 0))
                            w = bbox[2] - bbox[0]
                            h = bbox[3] - bbox[1]
                            if (w * h) > 0.05 * page_area or w > 0.3 * page.rect.width:
                                large_images.append(img)
                    except Exception:
                        large_images = images

                    text_len = len(text)
                    if text_len > 50 and len(large_images) == 0:
                        result[page_idx + 1] = "text"
                    elif len(large_images) >= 1 and text_len < 10:
                        result[page_idx + 1] = "ocr"
                    else:
                        result[page_idx + 1] = "text_then_ocr"
                return result
        except Exception:
            return {}

    def _is_searchable_pdf(self, pdf_source: bytes | str | Path) -> bool:
        """Return True if the majority of pages contain meaningful extractable text.

        Uses :meth:`_classify_pages` internally and caches the result so the
        per-page classification is available to :meth:`_detect_raw` without
        re-scanning.
        """

        page_classes = self._classify_pages(pdf_source)
        # Cache for later use by _detect_raw.
        self._page_classes = page_classes
        if not page_classes:
            return False
        text_pages = sum(1 for v in page_classes.values() if v in ("text", "text_then_ocr"))
        return text_pages >= len(page_classes) * 0.5


    def _result_is_sufficient(self, questions: list[DetectedQuestion], total_pages: int, settings: Settings) -> bool:
        """Return True if we got at least 1 question per 2 pages."""

        if total_pages <= 0:
            return False
        return (len(questions) / float(total_pages)) >= float(settings.MIN_QUESTIONS_PER_2_PAGES)

    def _result_is_confident(
        self, questions: list[DetectedQuestion], total_pages: int, settings: Settings
    ) -> bool:
        """Stricter gate used in smart mode before skipping the AI tier.

        A cheap-tier result is trusted (and AI is skipped) only when it is both
        *dense enough* and *internally consistent*. Two cheap signals catch the
        layouts where regex detection silently under-performs:

          1. **Density** — clearly more than the bare ``_result_is_sufficient``
             floor, so a paper that yielded only one or two stray matches always
             escalates to vision.
          2. **Numbering continuity** — detected question numbers should run as
             a mostly-unbroken sequence (1,2,3,…). Large gaps mean markers were
             missed (a question Claude would catch), so we escalate.

        Returning False here never drops the cheap result; it only lets the AI
        tier try to do better, and the caller keeps whichever found more.
        """

        if total_pages <= 0 or not questions:
            return False

        # 1. Density well above the minimum floor.
        floor = float(settings.MIN_QUESTIONS_PER_2_PAGES)
        density = len(questions) / float(total_pages)
        if density < max(floor, 0.75):
            return False

        # 2. Numbering continuity among the *question* items (ignore solutions,
        # which are renumbered/relabelled independently).
        nums: list[int] = []
        for q in questions:
            if q.is_solution:
                continue
            digits = re.findall(r"\d+", q.q_num)
            if digits:
                nums.append(int(digits[0]))
        if len(nums) >= 3:
            nums.sort()
            span = nums[-1] - nums[0] + 1
            # Coverage = how much of the implied 1..N run we actually found.
            coverage = len(set(nums)) / float(span) if span > 0 else 1.0
            if coverage < 0.8:
                return False

        return True

    def _should_run_ocr_for_page(self, page_num: int, page_class: str, text_q: list[DetectedQuestion]) -> bool:
        """Return True if we should run OCR fallback for page_num."""
        if page_class == "ocr":
            return True
        if page_class == "text_then_ocr":
            if not text_q:
                return True
            q_nums = [q.q_num for q in text_q if not q.is_solution]
            if len(q_nums) != len(set(q_nums)):
                return False
            cols = set()
            for q in text_q:
                for seg in q.segments:
                    cx = (seg.x_start_pct + seg.x_end_pct) / 2.0
                    if cx < 48.0:
                        cols.add(0)
                    elif cx > 52.0:
                        cols.add(1)
            if 0 in cols and 1 in cols:
                return False
            return True
        return False

    def _check_column_spread(self, qs: list[DetectedQuestion]) -> set[int]:
        """Return the set of columns containing question segments."""
        cols = set()
        for q in qs:
            for seg in q.segments:
                cx = (seg.x_start_pct + seg.x_end_pct) / 2.0
                if cx < 48.0:
                    cols.add(0)
                elif cx > 52.0:
                    cols.add(1)
                else:
                    cols.add(2)
        return cols

    async def _detect_ocr_single_page(
        self,
        page_img: Image.Image,
        page_num: int,
        settings: Settings,
        *,
        render_dpi: Optional[int] = None,
        use_google_ocr: bool = False,
        use_paddle_ocr: bool = False,
        marker_style: str = "auto",
        layout_columns: Optional[int] = None,
        custom_regex: Optional[str] = None,
    ) -> list[DetectedQuestion]:
        """Run OCR on a single page and map the returned page numbers back to page_num."""
        google_ocr_ready = self.google_ocr_detector is not None and self.google_ocr_detector.is_available()
        
        if use_google_ocr and google_ocr_ready:
            def _run():
                return self.google_ocr_detector.detect(
                    [page_img], settings, render_dpi, marker_style, layout_columns, custom_regex=custom_regex
                )
            ocr_q = await asyncio.to_thread(_run)
        elif (use_paddle_ocr or getattr(settings, "USE_PADDLE_OCR", False)) and self.paddle_ocr_detector.is_available():
            def _run():
                sig = inspect.signature(self.paddle_ocr_detector.detect)
                kwargs = {}
                if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    kwargs["custom_regex"] = custom_regex
                return self.paddle_ocr_detector.detect(
                    [page_img], settings, render_dpi, marker_style, layout_columns, **kwargs
                )
            ocr_q = await asyncio.to_thread(_run)
            if not ocr_q:
                # Fallback to Tesseract
                def _run_tess():
                    sig = inspect.signature(self.ocr_detector.detect)
                    kwargs = {}
                    if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                        kwargs["custom_regex"] = custom_regex
                    return self.ocr_detector.detect(
                        [page_img], settings, render_dpi, marker_style, layout_columns, **kwargs
                    )
                ocr_q = await asyncio.to_thread(_run_tess)
        else:
            def _run():
                sig = inspect.signature(self.ocr_detector.detect)
                kwargs = {}
                if "custom_regex" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    kwargs["custom_regex"] = custom_regex
                return self.ocr_detector.detect(
                    [page_img], settings, render_dpi, marker_style, layout_columns, **kwargs
                )
            ocr_q = await asyncio.to_thread(_run)
            
        remapped = []
        for q in ocr_q:
            segs = [seg.model_copy(update={"page": page_num}) for seg in q.segments]
            if segs:
                remapped.append(
                    DetectedQuestion(
                        q_num=q.q_num,
                        is_solution=q.is_solution,
                        segments=segs,
                        option_labels=q.option_labels,
                    )
                )
        return remapped


def resolve_vertical_overlaps(questions: list[DetectedQuestion]) -> list[DetectedQuestion]:
    """Resolve vertical overlaps of questions/solutions in the same column on the same page.

    If segment A starts above segment B, and ends below segment B's start, A is clipped to end at B's start.
    """
    if not questions:
        return questions

    # Group segments by (page, is_solution)
    groups: dict[tuple[int, bool], list[dict]] = {}
    for q_idx, q in enumerate(questions):
        for s_idx, seg in enumerate(q.segments):
            key = (seg.page, q.is_solution)
            groups.setdefault(key, []).append({
                "question": q,
                "segment": seg,
                "q_idx": q_idx,
                "s_idx": s_idx,
            })

    for (page, is_solution), seg_list in groups.items():
        if len(seg_list) <= 1:
            continue

        # Sort segments by their starting y coordinate
        seg_list.sort(key=lambda x: x["segment"].y_start_pct)

        for i in range(len(seg_list)):
            for j in range(i + 1, len(seg_list)):
                seg_a = seg_list[i]["segment"]
                seg_b = seg_list[j]["segment"]

                # Check horizontal overlap to see if they are in the same column
                x0_a = getattr(seg_a, "x_start_pct", 0.0)
                x1_a = getattr(seg_a, "x_end_pct", 100.0)
                x0_b = getattr(seg_b, "x_start_pct", 0.0)
                x1_b = getattr(seg_b, "x_end_pct", 100.0)

                horizontal_overlap = min(x1_a, x1_b) - max(x0_a, x0_b)
                # If they are in the same column (at least 5% width overlap)
                if horizontal_overlap > 5.0:
                    # seg_a starts above seg_b (since we sorted by y_start_pct).
                    # If seg_a ends below seg_b's start:
                    if seg_a.y_end_pct > seg_b.y_start_pct:
                        # Clip seg_a to end at seg_b's start
                        new_y_end = max(seg_a.y_start_pct, seg_b.y_start_pct)
                        seg_a.y_end_pct = new_y_end

    return questions
