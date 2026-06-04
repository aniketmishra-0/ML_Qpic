"""Pydantic request/response schemas."""

from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel

DetectionMethod = Literal["text", "ocr", "local_ml", "ai"]


class QuestionSegment(BaseModel):
    """A single question fragment on a page.

    ``x_start_pct`` / ``x_end_pct`` describe the horizontal extent of the
    column the fragment lives in. They default to the full page width so
    single-column layouts behave exactly as before.
    """

    page: int
    y_start_pct: float
    y_end_pct: float
    x_start_pct: float = 0.0
    x_end_pct: float = 100.0
    # Manual horizontal nudge for this part when stitched into a multi-part
    # crop, as a signed percentage of the page width (positive shifts the part
    # right, negative left). Set from the review "Manual align" controls and
    # applied only during stitching, so a preview and the finalized download —
    # which both stitch the same segments — line the parts up identically.
    # Defaults to 0.0 so single-column and auto-detected crops are untouched.
    x_offset_pct: float = 0.0
    # Manual vertical nudge for this part when stitched into a multi-part
    # crop, as a signed percentage of the page height (positive shifts the part
    # down, negative up). Set from the review "Manual align" controls and
    # applied only during stitching.
    # Defaults to 0.0 so single-column and auto-detected crops are untouched.
    y_offset_pct: float = 0.0


class DetectedQuestion(BaseModel):
    """A detected question (or solution) with one or more page segments.

    ``option_labels`` records which MCQ option letters (A-D) were seen inside the
    question's content during text/OCR detection, e.g. ``"ABCD"`` for a complete
    question or ``"AC"`` when only the left column of a 2-up option grid was
    captured. It is informational only (default empty) and lets the review step
    flag a crop that probably lost its right-hand options. Detectors that don't
    track options (the AI tier, manual items) leave it empty.

    ``other_segments`` carries the translation column's segments for bilingual
    PDFs (e.g. the Hindi side of a JEE Main solution). When present, the
    bilingual export modes can stitch or select between the primary (English)
    and the other (Hindi) segments without doubling the question count.
    """

    q_num: str
    segments: list[QuestionSegment]
    is_solution: bool = False
    option_labels: str = ""
    source: Literal["auto", "manual"] = "auto"
    # Explicit override for left-aligning stitched column-split parts. None keeps
    # the legacy per-source default (align manual items only); True/False force
    # the choice. Set from the review "Align parts" toggle and carried verbatim
    # so a finalized crop matches the preview the user approved.
    align: Optional[bool] = None
    # Segments from the bilingual translation column (e.g. Hindi). When set,
    # the primary ``segments`` carry the English (left) column and this field
    # carries the Hindi (right) column. The bilingual export modes use this
    # to stitch or select the language without doubling detected questions.
    other_segments: Optional[list[QuestionSegment]] = None

class CropResponse(BaseModel):
    """Response after creating a crop job.

    ``download_url`` is the combined archive (questions + solutions) and is kept
    for backward compatibility. ``questions_download_url`` /
    ``solutions_download_url`` point to the per-type archives and are present
    only when that side produced at least one crop.
    """

    job_id: str
    total_questions: int
    stitched_questions: int
    method_used: DetectionMethod
    download_url: str
    questions_download_url: Optional[str] = None
    solutions_download_url: Optional[str] = None
    questions_count: int = 0
    solutions_count: int = 0
    # True when an answer sheet (answers.csv + answers.json mapping each
    # question image to its correct option) was bundled into the download.
    answer_sheet_included: bool = False
    # Number of questions the answer sheet carries a correct option for.
    answers_count: int = 0


# --- Smart analyze / manual-review / finalize flow ---------------------------


class PageInfo(BaseModel):
    """Geometry of a single PDF page, used by the manual-crop canvas."""

    page: int  # 1-indexed
    width_pt: float
    height_pt: float
    preview_url: str


class AnalyzedItem(BaseModel):
    """A detected (or user-added) item returned for on-screen review.

    ``source`` distinguishes the pipeline's own detections ("auto") from items
    the user draws in the review popup ("manual"). ``flagged`` marks an item the
    review heuristics are unsure about (a likely duplicate or a suspiciously
    tiny crop) so the UI can highlight it.
    """

    q_num: str
    is_solution: bool = False
    segments: list[QuestionSegment]
    source: Literal["auto", "manual"] = "auto"
    flagged: bool = False
    flag_reason: Optional[str] = None
    # Bilingual translation segments (e.g. Hindi column). Set when the
    # detector merged a bilingual pair, so the frontend can render
    # bilingual previews without needing duplicate items.
    other_segments: Optional[list[QuestionSegment]] = None


class ReviewNote(BaseModel):
    """A single human-readable thing to check in the review popup."""

    kind: Literal["duplicate", "gap", "tiny", "incomplete", "low_confidence"]
    message: str
    q_num: Optional[str] = None
    page: Optional[int] = None
    is_solution: bool = False
    suggested_segments: Optional[list[QuestionSegment]] = None


class AnalyzeResponse(BaseModel):
    """Result of the smart analyze pass, before final ZIP generation."""

    job_id: str
    total_pages: int
    method_used: DetectionMethod
    pages: list[PageInfo]
    items: list[AnalyzedItem]
    notes: list[ReviewNote]
    needs_review: bool
    # Number of answers parsed from the paper's answer key (0 when no key was
    # found). Lets the review UI tell the user up front whether the finalized
    # download will include an answer sheet.
    answer_key_count: int = 0
    # True when the detector found a bilingual side-by-side layout (e.g.
    # English left / Hindi right on the same page). The frontend can
    # auto-enable bilingual mode when this is set.
    bilingual_detected: bool = False


class SnapRequest(BaseModel):
    """A roughly drawn box to tighten to the content inside it."""

    job_id: str
    page: int
    x_start_pct: float
    x_end_pct: float
    y_start_pct: float
    y_end_pct: float
    margin_pct: float = 0.8


class SnapResponse(BaseModel):
    """The content-tightened region (page percentages)."""

    x_start_pct: float
    x_end_pct: float
    y_start_pct: float
    y_end_pct: float


class FinalizeItem(BaseModel):
    """One item to crop in the finalize step (auto-kept or manually drawn).

    ``source`` mirrors the review item's origin: ``"manual"`` for boxes the user
    drew/re-selected by hand, ``"auto"`` for kept pipeline detections. Finalize
    uses it to apply manual-only post-processing (content left-alignment of
    stitched column-split parts) without touching auto crops.

    ``align`` is an explicit override for that left-alignment of stitched parts
    (the "Align parts" toggle in the review preview). ``None`` keeps the legacy
    default (align only manual items); ``True``/``False`` force the choice for
    this item regardless of its source, so the user can straighten an
    auto-detected multi-part question (or turn alignment off) and have the
    finalized crop match exactly what the preview showed.
    """

    q_num: str
    is_solution: bool = False
    segments: list[QuestionSegment]
    source: Literal["auto", "manual"] = "auto"
    align: Optional[bool] = None


class CropPreviewRequest(BaseModel):
    """A single item to render as a standalone preview crop.

    Used by ``POST /api/crop/preview`` to show the user exactly how one question
    (or solution) will look once cropped — reusing the same crop/stitch pipeline
    the finalized download runs, so the preview is "what you see is what you
    get". ``align`` mirrors :class:`FinalizeItem.align` (``None`` = legacy
    per-source default); the other fields mirror the relevant finalize output
    config so the preview honours the same DPI / padding / format.
    """

    job_id: str
    q_num: str = "0"
    is_solution: bool = False
    segments: list[QuestionSegment]
    source: Literal["auto", "manual"] = "auto"
    align: Optional[bool] = None
    dpi: int = 200
    padding: int = 20
    image_format: Literal["png", "jpg", "jpeg"] = "png"
    jpg_quality: int = 90
    bilingual_mode: Optional[Literal["english", "hindi", "bilingual_horizontal", "bilingual_vertical"]] = None
    other_segments: Optional[list[QuestionSegment]] = None


class FinalizeRequest(BaseModel):
    """Payload that turns a reviewed item list into the downloadable ZIP."""

    job_id: str
    items: list[FinalizeItem]
    dpi: int = 200
    padding: int = 20
    question_prefix: str = "Q"
    solution_prefix: str = "S"
    start_number: int = 1
    image_format: Literal["png", "jpg", "jpeg"] = "png"
    jpg_quality: int = 90
    # When False, skip the answer-sheet (answers.csv/json) even if a key was
    # found at analyze time. Defaults True so the sheet ships by default.
    answer_sheet: bool = True
    bilingual_mode: Optional[Literal["english", "hindi", "bilingual_horizontal", "bilingual_vertical"]] = None


class HealthResponse(BaseModel):
    status: str
    tesseract_available: bool
    ai_available: bool
    version: str
    ai_provider: Optional[str] = None
    ai_model: Optional[str] = None
    local_ml_available: bool = False
    local_ml_model: Optional[str] = None


# --- Batch rename tool -------------------------------------------------------


class RenamePlanItem(BaseModel):
    """A single before/after pair in a rename preview."""

    original: str
    renamed: str


class RenamePreviewResponse(BaseModel):
    """Preview of how a batch of files will be renamed."""

    count: int
    items: list[RenamePlanItem]


class PdfImageItem(BaseModel):
    """One PDF page rendered to a PNG, returned as an inline data URL.

    ``data_url`` is a ready-to-use ``data:image/png;base64,…`` string so the
    browser can show a thumbnail and turn it back into a File for the rename
    batch — no extra round-trip to fetch the bytes.
    """

    name: str
    data_url: str
    width: int
    height: int
    size: int


class PdfToImagesResponse(BaseModel):
    """All pages of an uploaded PDF, rasterised to PNG images."""

    count: int
    images: list[PdfImageItem]


class RenameSessionResponse(BaseModel):
    """A freshly created upload session for a large rename batch."""

    session_id: str


class RenameUploadResponse(BaseModel):
    """Acknowledges a chunk of files appended to a rename session."""

    session_id: str
    received: int  # files accepted in this request
    total: int  # files staged in the session so far


class RenameFinalizeResponse(BaseModel):
    """The packed ZIP is ready; ``download_url`` streams it to the client."""

    session_id: str
    count: int
    download_url: str


# --- PDF power tools: Compress / Edit / Preflight ----------------------------


class EditPageModel(BaseModel):
    """Geometry + preview for one page in the editor."""

    page: int
    width: float
    height: float
    preview_url: str


class CompressResponse(BaseModel):
    """Result of a PDF compression job."""

    job_id: str
    original_size: int
    compressed_size: int
    ratio: float  # fraction of original size removed (0.0-1.0)
    level: str
    target_met: Optional[bool] = None
    note: str = ""
    download_url: str
    pages: list[EditPageModel] = []


class EditableSpanModel(BaseModel):
    """One editable text run on a page, with its geometry and style."""

    id: str
    page: int
    text: str
    bbox: list[float]  # [x0, y0, x1, y1] in PDF points
    font: str
    size: float
    color: int
    bold: bool = False
    italic: bool = False


class VectorObjectModel(BaseModel):
    """One selectable vector graphic or image object on a page."""

    id: str
    page: int
    type: str  # "image" or "vector"
    bbox: list[float]  # [x0, y0, x1, y1] in PDF points




class EditExtractResponse(BaseModel):
    """All editable text spans for a PDF opened in the editor."""

    job_id: str
    has_text: bool
    pages: list[EditPageModel]
    spans: list[EditableSpanModel]
    vector_objects: list[VectorObjectModel] = []


class EditOpModel(BaseModel):
    """A single span edit submitted from the editor."""

    page: int
    bbox: list[float]
    new_text: str
    font: Optional[str] = None
    size: Optional[float] = None
    color: Optional[int] = None


class OperationModel(BaseModel):
    """A single Acrobat-style edit operation submitted from the editor.

    ``type`` is one of: ``edit_text``, ``add_text``, ``add_image``,
    ``add_link``, ``erase``.
    """

    type: str
    page: int
    bbox: list[float]
    text: str = ""
    font: Optional[str] = None
    size: Optional[float] = None
    color: Optional[int] = None
    bold: bool = False
    italic: bool = False
    align: int = 0
    image_b64: Optional[str] = None
    url: Optional[str] = None
    fill: Optional[int] = None


class EditApplyRequest(BaseModel):
    """Payload that applies a set of in-place text edits to a job's PDF.

    Either ``edits`` (legacy text-only) or ``operations`` (full Acrobat-style
    set) may be supplied; ``operations`` wins when both are present.
    """

    job_id: str
    edits: list[EditOpModel] = []
    operations: list[OperationModel] = []


class EditApplyResponse(BaseModel):
    """The edited PDF is ready for download."""

    job_id: str
    edits_applied: int
    download_url: str


class OcrResponse(BaseModel):
    """Result of adding a searchable OCR text layer to a PDF."""

    job_id: str
    pages_ocred: int
    languages: str
    note: str
    download_url: str


class PreflightCheckModel(BaseModel):
    id: str
    title: str
    status: str  # ok | warn | fail | info
    detail: str


class PreflightFontModel(BaseModel):
    name: str
    type: str
    embedded: bool
    subset: bool


class PreflightImageModel(BaseModel):
    page: int
    width: int
    height: int
    dpi: float
    colorspace: str
    bpc: int


class PreflightPageDetail(BaseModel):
    """Per-page geometry detail for the Preflight Check table."""

    page: int
    w_mm: float
    h_mm: float
    w_pt: float
    h_pt: float
    w_px: int
    h_px: int
    format: str  # "A4" | "A3" | "Letter" | "Legal" | "A5" | "Custom"
    orientation: str  # "Portrait" | "Landscape"


class PreflightResponse(BaseModel):
    """Full read-only preflight report for a PDF."""

    verdict: str  # pass | warn | fail
    page_count: int
    page_sizes: list[str]
    file_size: int
    is_encrypted: bool
    has_text_layer: bool
    checks: list[PreflightCheckModel]
    fonts: list[PreflightFontModel]
    images: list[PreflightImageModel]
    metadata: dict[str, str]
    # All distinct page-size labels + a flag so the UI can offer the one-click
    # "Fix page sizes" action when the document mixes geometries.
    distinct_page_sizes: list[str] = []
    mixed_page_sizes: bool = False
    # Per-page detailed geometry for the Preflight Check modal table.
    page_details: list[PreflightPageDetail] = []
    job_id: Optional[str] = None
    pages: list[EditPageModel] = []


class PreflightFixResponse(BaseModel):
    """Result of normalizing a PDF's pages to one uniform size."""

    job_id: str
    target_label: str
    target_width: float   # PDF points
    target_height: float  # PDF points
    pages_total: int
    pages_changed: int
    note: str
    download_url: str
    pages: list[EditPageModel] = []


class EnhanceResponse(BaseModel):
    """Result of a PDF enhancement job."""

    job_id: str
    pages_total: int
    note: str = ""
    download_url: str


class MLConfigRequest(BaseModel):
    model_path: Optional[str] = None
    labels_path: Optional[str] = None
    model_name: Optional[str] = None
    confidence: Optional[float] = None
    input_size: Optional[int] = None


class MLConfigResponse(BaseModel):
    model_path: Optional[str]
    labels_path: Optional[str]
    model_name: str
    confidence: float
    input_size: int
    local_ml_available: bool


class RegexTestRequest(BaseModel):
    pattern: str
    sample_lines: list[str]


class RegexMatchResult(BaseModel):
    line: str
    matched: bool
    q_num: Optional[str] = None
    groups: list[str] = []


class RegexTestResponse(BaseModel):
    pattern: str
    results: list[RegexMatchResult]


class AlignOffsetsRequest(BaseModel):
    job_id: str
    segments: list[QuestionSegment]


class AlignOffsetsResponse(BaseModel):
    offsets: list[float]


