"""PDF validation and rendering helpers."""

from __future__ import annotations

import logging
import threading
from typing import Iterator, List, Union

import fitz
from fastapi import HTTPException, status
from PIL import Image, ImageDraw

from ..config import Settings

logger = logging.getLogger(__name__)

ERR_INVALID_PDF = "Invalid PDF file"


from pathlib import Path

def validate_pdf(
    pdf_source: bytes | str | Path,
    settings: Settings,
    *,
    max_size_mb: int | None = None,
    max_pages: int | None = None,
) -> None:
    """Validate PDF bytes or file path and enforce size/page limits.

    By default the cropper limits (``MAX_PDF_SIZE_MB`` / ``MAX_PAGES``) apply.
    Callers that do cheap, non-AI work (the Compress/Edit/Preflight tools) pass
    their own, much larger ceilings via ``max_size_mb`` / ``max_pages``.

    Raises HTTPException if:
    - File is not a valid PDF
    - File exceeds the effective size limit
    - Page count exceeds the effective page limit
    """

    size_limit = max_size_mb if max_size_mb is not None else settings.MAX_PDF_SIZE_MB
    page_limit = max_pages if max_pages is not None else settings.MAX_PAGES

    if isinstance(pdf_source, bytes):
        size_mb = len(pdf_source) / (1024 * 1024)
        if size_mb > size_limit:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"PDF exceeds size limit ({size_mb:.2f}MB > {size_limit}MB)",
            )

        if not pdf_source.startswith(b"%PDF"):
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF)

        try:
            with fitz.open(stream=pdf_source, filetype="pdf") as doc:
                page_count = doc.page_count
        except Exception as exc:
            logger.error("pdf_open_failed error=%s", str(exc))
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF) from exc
    else:
        pdf_path = Path(pdf_source)
        if not pdf_path.exists():
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF)

        size_mb = pdf_path.stat().st_size / (1024 * 1024)
        if size_mb > size_limit:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"PDF exceeds size limit ({size_mb:.2f}MB > {size_limit}MB)",
            )

        try:
            with open(pdf_path, "rb") as f:
                start_bytes = f.read(4)
            if start_bytes != b"%PDF":
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF)
        except Exception as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF) from exc

        try:
            with fitz.open(str(pdf_path)) as doc:
                page_count = doc.page_count
        except Exception as exc:
            logger.error("pdf_open_failed error=%s", str(exc))
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERR_INVALID_PDF) from exc

    if page_count > page_limit:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"PDF exceeds page limit ({page_count} > {page_limit})",
        )



def render_page_image(doc: "fitz.Document", page_index: int, dpi: int) -> Image.Image:
    """Rasterize a single page of an open PDF to a PIL Image (RGB)."""

    zoom = dpi / 72.0
    matrix = fitz.Matrix(zoom, zoom)
    page = doc.load_page(page_index)
    pix = page.get_pixmap(matrix=matrix, colorspace=fitz.csRGB, alpha=False)
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def pdf_to_images(pdf_source: bytes | str | Path, dpi: int) -> list[Image.Image]:
    """Convert PDF bytes or file path to a list of PIL Images.

    Eager renderer kept for callers (and tests) that genuinely want every page
    materialised at once. The detection path uses :class:`LazyPageImages`
    instead so a searchable PDF renders zero pages and a scanned one holds at
    most a single page in memory.
    """

    if isinstance(pdf_source, bytes):
        doc = fitz.open(stream=pdf_source, filetype="pdf")
    else:
        doc = fitz.open(str(pdf_source))
    with doc:
        return [render_page_image(doc, i, dpi) for i in range(doc.page_count)]


def deskew_image(img: Image.Image) -> Image.Image:
    """Detect text lines tilt angle and rotate to make them horizontal."""
    try:
        import cv2
        import numpy as np
    except ImportError:
        return img

    try:
        # Convert PIL Image to grayscale array to estimate tilt
        gray = img.convert("L")
        arr_gray = np.array(gray)

        inv = cv2.bitwise_not(arr_gray)
        _, mask = cv2.threshold(inv, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        coords = cv2.findNonZero(mask)
        if coords is None or len(coords) < 50:
            return img

        angle = cv2.minAreaRect(coords)[-1]
        if angle < -45:
            angle = 90.0 + angle
        if abs(angle) < 0.3 or abs(angle) > 10.0:
            return img

        # Warp the original image (supports RGB/RGBA shape)
        arr_img = np.array(img)
        h, w = arr_img.shape[:2]
        center = (w / 2.0, h / 2.0)
        matrix = cv2.getRotationMatrix2D(center, angle, 1.0)
        
        warped = cv2.warpAffine(
            arr_img,
            matrix,
            (w, h),
            flags=cv2.INTER_CUBIC,
            borderMode=cv2.BORDER_REPLICATE,
        )
        return Image.fromarray(warped)
    except Exception:
        return img


class LazyPageImages:
    """A list-like view of a PDF's pages that renders each page on demand.

    The detection pipeline only needs page *bitmaps* for the OCR and AI tiers;
    the text tier (which wins on every searchable/digital PDF) never touches
    them. Eagerly rasterising the whole document up front therefore burns CPU
    and holds hundreds of megabytes of bitmaps in RAM that are usually thrown
    away unused — wasteful on battery and memory both.

    This view behaves like ``list[Image.Image]`` for the access patterns the
    detectors use (``len()``, ``for img in pages``, ``pages[i]``, ``pages[a:b]``,
    ``enumerate(pages, start=1)``) but renders a page only when it is actually
    requested. By default each rendered page is released as soon as the next one
    is fetched during iteration, so a 100-page scan peaks at ~one page of
    bitmap instead of all 100. Slices (used by the AI tier's batching) and
    explicit indexing render just the pages asked for.

    Thread-safe: rendering is guarded by a lock because detectors run inside
    ``asyncio.to_thread`` worker threads.
    """

    def __init__(
        self,
        pdf_source: bytes | str | Path,
        dpi: int,
        *,
        cache: bool = False,
        binarize: bool = False,
        contrast: float = 1.0,
        brightness: float = 1.0,
        watermark_threshold: int = 255,
        deskew: bool = False,
    ) -> None:
        if isinstance(pdf_source, bytes):
            self._doc = fitz.open(stream=pdf_source, filetype="pdf")
        else:
            self._doc = fitz.open(str(pdf_source))
        self._dpi = dpi
        self._count = self._doc.page_count
        self._lock = threading.Lock()
        # When cache=False (default) we keep at most the most-recently rendered

        # page, so iteration never accumulates bitmaps. cache=True keeps every
        # page (used only where a caller really needs random repeat access).
        self._cache = cache
        self._binarize = binarize
        self._contrast = contrast
        self._brightness = brightness
        self._watermark_threshold = watermark_threshold
        self._deskew = deskew
        self._store: dict[int, Image.Image] = {}

    def __len__(self) -> int:
        return self._count

    def _render(self, index: int) -> Image.Image:
        if index < 0:
            index += self._count
        if index < 0 or index >= self._count:
            raise IndexError(index)
        with self._lock:
            cached = self._store.get(index)
            if cached is not None:
                return cached
            img = render_page_image(self._doc, index, self._dpi)
            
            # Apply binarize/contrast/brightness/watermark thresholding if non-default
            if (
                self._binarize
                or self._contrast != 1.0
                or self._brightness != 1.0
                or self._watermark_threshold < 255
            ):
                from ..services.pdf_tools.enhance_service import enhance_image
                img = enhance_image(
                    img,
                    binarize=self._binarize,
                    contrast=self._contrast,
                    brightness=self._brightness,
                    watermark_threshold=self._watermark_threshold,
                )

            # Apply deskewing if requested
            if self._deskew:
                img = deskew_image(img)

            if self._cache:
                self._store[index] = img
            else:
                # Keep only this page so sequential iteration stays flat in RAM.
                self._store = {index: img}
            return img

    def __getitem__(
        self, key: Union[int, slice]
    ) -> Union[Image.Image, List[Image.Image]]:
        if isinstance(key, slice):
            return [self._render(i) for i in range(*key.indices(self._count))]
        return self._render(int(key))

    def __iter__(self) -> Iterator[Image.Image]:
        for i in range(self._count):
            yield self._render(i)

    def close(self) -> None:
        with self._lock:
            self._store.clear()
            try:
                self._doc.close()
            except Exception:
                pass

    def __enter__(self) -> "LazyPageImages":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


def render_page_region(
    doc: "fitz.Document",
    page_index: int,
    *,
    x_start_pct: float,
    x_end_pct: float,
    y_start_pct: float,
    y_end_pct: float,
    dpi: int,
    furniture_rects: "list | None" = None,
) -> Image.Image:
    """Render a sub-region of a PDF page straight from the vector source.

    The region is given as percentages of the page size so it can be derived
    from the same detection coordinates used everywhere else. Rendering from the
    PDF (rather than cropping an already-rasterized page image) means the output
    is sharp at whatever ``dpi`` we choose, so zooming into a question/solution
    crop never shows the soft, upscaled pixels of the detection render.

    ``furniture_rects`` is an optional list of ``(x0, y0, x1, y1)`` rectangles in
    PDF points marking page furniture (branding footers, logos, decorative
    rules). Any part of them that lands inside the rendered region is painted
    white, so furniture that sits *inside* a crop — e.g. a footer in the middle
    of a cross-page solution — is physically removed from the output.
    """

    page = doc.load_page(page_index)
    rect = page.rect
    page_w = float(rect.width)
    page_h = float(rect.height)

    x0 = rect.x0 + (x_start_pct / 100.0) * page_w
    x1 = rect.x0 + (x_end_pct / 100.0) * page_w
    y0 = rect.y0 + (y_start_pct / 100.0) * page_h
    y1 = rect.y0 + (y_end_pct / 100.0) * page_h

    # Guard against inverted / empty clips.
    if x1 <= x0:
        x0, x1 = rect.x0, rect.x1
    if y1 <= y0:
        y0, y1 = rect.y0, rect.y1

    clip = fitz.Rect(x0, y0, x1, y1)
    zoom = dpi / 72.0
    matrix = fitz.Matrix(zoom, zoom)
    pix = page.get_pixmap(matrix=matrix, clip=clip, colorspace=fitz.csRGB, alpha=False)
    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)

    if furniture_rects:
        img = _paint_out_furniture(
            img,
            furniture_rects,
            clip_x0=x0,
            clip_y0=y0,
            zoom=zoom,
        )

    return img


def _paint_out_furniture(
    img: Image.Image,
    furniture_rects: list,
    *,
    clip_x0: float,
    clip_y0: float,
    zoom: float,
) -> Image.Image:
    """Paint white over furniture rectangles intersecting the rendered region.

    ``furniture_rects`` are ``(x0, y0, x1, y1)`` tuples in PDF points; the clip
    origin and ``zoom`` map them onto the rendered pixel grid.
    """

    from ..services.detector.furniture import paint_pad_pts

    pad = paint_pad_pts()
    draw = ImageDraw.Draw(img)
    w, h = img.size
    for fr in furniture_rects:
        fx0, fy0, fx1, fy1 = float(fr[0]), float(fr[1]), float(fr[2]), float(fr[3])
        # Grow slightly to cover anti-aliased edges, then map points -> pixels.
        px0 = int((fx0 - pad - clip_x0) * zoom)
        py0 = int((fy0 - pad - clip_y0) * zoom)
        px1 = int((fx1 + pad - clip_x0) * zoom)
        py1 = int((fy1 + pad - clip_y0) * zoom)
        # Clamp to image bounds; skip if no overlap.
        px0 = max(0, min(w, px0))
        px1 = max(0, min(w, px1))
        py0 = max(0, min(h, py0))
        py1 = max(0, min(h, py1))
        if px1 <= px0 or py1 <= py0:
            continue
        draw.rectangle([px0, py0, px1 - 1, py1 - 1], fill=(255, 255, 255))

    return img
