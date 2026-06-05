"""Standalone batch-rename API endpoints.

The Rename Batch tool is independent of the cropper: a user uploads images,
chooses a naming pattern (with a ``#`` number token), start value and zero
padding, then downloads a ZIP of the renamed files. Image bytes are copied
verbatim, so each file keeps its exact original format.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import FileResponse

from ..config import Settings
from ..dependencies import get_settings
from ..models.schemas import (
    PdfImageItem,
    PdfPageItem,
    PdfToImagesResponse,
    PdfToSessionResponse,
    PdfFinalizeRequest,
    RenameFinalizeResponse,
    RenamePlanItem,
    RenamePreviewResponse,
    RenameSessionResponse,
    RenameUploadResponse,
)
from ..services.pdf_service import pdf_to_images, parallel_render_pdf_to_files, validate_pdf
from ..services.rename_service import (
    ALLOWED_EXTENSIONS,
    OUTPUT_FORMATS,
    plan_renames,
    plan_output_names,
    split_extension,
    write_rename_zip,
    write_rename_zip_from_paths,
    write_rename_excel,
)
from ..utils.file_utils import create_job_dir, generate_job_id, get_job_dir, safe_cleanup_job
from ..utils.image_utils import ensure_rgb

router = APIRouter(tags=["rename"])
logger = logging.getLogger(__name__)

RENAME_ZIP = "qpic_renamed_{job_id}.zip"

# Files are streamed to disk in this many bytes at a time, so even a multi-GB
# upload never fully sits in memory.
_UPLOAD_CHUNK = 1024 * 1024  # 1 MiB

# Per-session staging layout under a job dir:
#   <job>/uploads/<NNNNNN><ext>   the raw staged files, in arrival order
#   <job>/manifest.jsonl          one JSON line per file: {stored, original, stem}
#   <job>/qpic_renamed_<job>.zip  the packed result (after finalize)
_UPLOADS_SUBDIR = "uploads"
_MANIFEST_NAME = "manifest.jsonl"


def _get_temp_root(request: Request, settings: Settings) -> str:
    return str(getattr(request.app.state, "temp_root", settings.TEMP_DIR))


def _is_allowed(filename: str) -> bool:
    _, ext = split_extension(filename)
    return ext in ALLOWED_EXTENSIONS


def _session_dir(session_id: str, temp_root: str) -> Path:
    return get_job_dir(session_id, temp_root)


def _uploads_dir(session_id: str, temp_root: str) -> Path:
    return _session_dir(session_id, temp_root) / _UPLOADS_SUBDIR


def _manifest_path(session_id: str, temp_root: str) -> Path:
    return _session_dir(session_id, temp_root) / _MANIFEST_NAME


def _count_manifest(manifest: Path) -> int:
    if not manifest.exists():
        return 0
    with manifest.open("r", encoding="utf-8") as fh:
        return sum(1 for line in fh if line.strip())


def _stage_one_file(
    upload: UploadFile,
    *,
    index: int,
    uploads_dir: Path,
    max_total_bytes: int,
    bytes_so_far: int,
) -> tuple[int, dict]:
    """Stream one upload to disk in chunks. Returns (bytes_written, manifest row).

    Runs in a worker thread (called via ``asyncio.to_thread``) so the chunked
    disk writes don't block the event loop. Raises HTTPException(413) if the
    running total crosses the batch ceiling.
    """

    original = upload.filename or "unnamed"
    _, ext = split_extension(original)
    stored_name = f"{index:06d}.{ext}" if ext else f"{index:06d}"
    dest = uploads_dir / stored_name

    written = 0
    with dest.open("wb") as out:
        while True:
            chunk = upload.file.read(_UPLOAD_CHUNK)
            if not chunk:
                break
            written += len(chunk)
            if bytes_so_far + written > max_total_bytes:
                out.close()
                dest.unlink(missing_ok=True)
                raise HTTPException(
                    status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    detail="Batch is larger than the configured limit.",
                )
            out.write(chunk)

    return written, {"stored": stored_name, "original": original}


@router.post("/rename/session", response_model=RenameSessionResponse)
async def create_rename_session(
    request: Request,
    settings: Settings = Depends(get_settings),
) -> RenameSessionResponse:
    """Open a streamed rename session for a large batch.

    Files are uploaded in small chunks to ``/rename/session/{id}/files`` (which
    sidesteps the multipart 1000-file cap and keeps each request small), staged
    to disk, then packed by ``/finalize`` and streamed back by ``/download`` —
    so a multi-gigabyte batch is handled with a flat memory footprint.
    """

    session_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)
    uploads = _uploads_dir(session_id, temp_root)
    await asyncio.to_thread(uploads.mkdir, parents=True, exist_ok=True)
    logger.info("rename_session_created session_id=%s", session_id)
    return RenameSessionResponse(session_id=session_id)


@router.post("/rename/session/{session_id}/files", response_model=RenameUploadResponse)
async def upload_rename_files(
    session_id: str,
    request: Request,
    files: list[UploadFile] = File(..., description="A chunk of images for the batch."),
    settings: Settings = Depends(get_settings),
) -> RenameUploadResponse:
    """Append a chunk of files to a session, streaming each to disk.

    The client sends the batch in groups (e.g. 200 files per request) so no
    single request hits the multipart file-count limit and nothing large sits
    in memory. Each file is validated, then written to disk in 1 MiB chunks.
    """

    temp_root = _get_temp_root(request, settings)
    session = _session_dir(session_id, temp_root)
    uploads = _uploads_dir(session_id, temp_root)
    if not session.exists() or not uploads.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown or expired session.")

    if not files:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No files in this chunk.")

    manifest = _manifest_path(session_id, temp_root)
    start_index = _count_manifest(manifest)
    max_total = settings.MAX_RENAME_BATCH_MB * 1024 * 1024

    # Existing on-disk size, so the ceiling is enforced across all chunks.
    bytes_so_far = await asyncio.to_thread(
        lambda: sum(f.stat().st_size for f in uploads.iterdir() if f.is_file())
    )

    rows: list[dict] = []
    received = 0
    for offset, upload in enumerate(files):
        name = upload.filename or ""
        if not _is_allowed(name):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unsupported file type: {name or 'unnamed'}. Images only.",
            )
        written, row = await asyncio.to_thread(
            _stage_one_file,
            upload,
            index=start_index + offset,
            uploads_dir=uploads,
            max_total_bytes=max_total,
            bytes_so_far=bytes_so_far,
        )
        bytes_so_far += written
        rows.append(row)
        received += 1

    # Append manifest rows in one go (preserves arrival order across chunks).
    def _append_rows() -> None:
        with manifest.open("a", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row) + "\n")

    await asyncio.to_thread(_append_rows)

    total = start_index + received
    logger.info(
        "rename_session_upload session_id=%s received=%s total=%s",
        session_id,
        received,
        total,
    )
    return RenameUploadResponse(session_id=session_id, received=received, total=total)


@router.post("/rename/session/{session_id}/finalize", response_model=RenameFinalizeResponse)
async def finalize_rename_session(
    session_id: str,
    request: Request,
    pattern: str = Form("#"),
    start: int = Form(1, ge=0, le=1_000_000),
    padding: int = Form(0, ge=0, le=12),
    names: str = Form(
        "",
        description="Optional JSON array of explicit output stems, one per staged "
        "file in upload order (this is how the UI's variable tokens arrive).",
    ),
    output_format: str = Form("original"),
    jpg_quality: int = Form(90, ge=1, le=100),
    settings: Settings = Depends(get_settings),
) -> RenameFinalizeResponse:
    """Pack a session's staged files into a ZIP, reading from disk.

    The ZIP is built straight from the staged files (verbatim copy, or one
    image decoded at a time when a format is forced), so memory stays flat
    regardless of batch size. The result is left on disk for ``/download``.
    """

    temp_root = _get_temp_root(request, settings)
    session = _session_dir(session_id, temp_root)
    uploads = _uploads_dir(session_id, temp_root)
    manifest = _manifest_path(session_id, temp_root)
    if not session.exists() or not manifest.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown or expired session.")

    fmt = (output_format or "original").strip().lower()
    if fmt not in OUTPUT_FORMATS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported output format: {output_format}.",
        )

    # Read the manifest (arrival order) → list of (original_name, source_path).
    def _read_manifest() -> list[tuple[str, Path]]:
        out: list[tuple[str, Path]] = []
        with manifest.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                out.append((row["original"], uploads / row["stored"]))
        return out

    entries = await asyncio.to_thread(_read_manifest)
    if not entries:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No files staged in this session.")

    explicit_stems: Optional[list[str]] = None
    if names.strip():
        try:
            parsed = json.loads(names)
        except json.JSONDecodeError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="names must be a JSON array of strings.",
            ) from exc
        if not isinstance(parsed, list) or len(parsed) != len(entries):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Name count does not match the number of staged files.",
            )
        explicit_stems = [str(s) for s in parsed]

    zip_path = session / RENAME_ZIP.format(job_id=session_id)
    excel_path = session / f"qpic_renamed_{session_id}.xlsx"
    request_id = getattr(request.state, "request_id", None)
    try:
        # Generate final filenames to ensure exact name alignment with the ZIP.
        new_names = plan_output_names(
            [name for name, _ in entries],
            pattern=pattern,
            start=start,
            padding=padding,
            explicit_stems=explicit_stems,
            output_format=fmt,
        )

        count = await asyncio.to_thread(
            write_rename_zip_from_paths,
            zip_path,
            entries,
            pattern=pattern,
            start=start,
            padding=padding,
            explicit_stems=explicit_stems,
            output_format=fmt,
            jpg_quality=jpg_quality,
        )

        # Generate companion Excel sheet
        await asyncio.to_thread(
            write_rename_excel,
            excel_path,
            new_names,
        )
    except Exception as exc:
        logger.exception(
            "request_id=%s session_id=%s stage=rename_finalize_error error=%s",
            request_id,
            session_id,
            str(exc),
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Couldn't pack the renamed images.",
        ) from exc

    logger.info(
        "request_id=%s session_id=%s stage=rename_finalize_done files=%s format=%s",
        request_id,
        session_id,
        count,
        fmt,
    )
    return RenameFinalizeResponse(
        session_id=session_id,
        count=count,
        download_url=f"/api/rename/session/{session_id}/download",
        excel_download_url=f"/api/rename/session/{session_id}/download-excel",
    )


@router.get("/rename/session/{session_id}/download")
async def download_rename_session(
    session_id: str,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    """Stream the packed ZIP for a finalized session to the client.

    ``FileResponse`` streams the file from disk in chunks, so the server never
    loads the whole archive into memory even for a multi-gigabyte download.
    """

    temp_root = _get_temp_root(request, settings)
    session = _session_dir(session_id, temp_root)
    zip_path = session / RENAME_ZIP.format(job_id=session_id)
    if not zip_path.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Nothing to download for this session.")
    return FileResponse(
        str(zip_path),
        media_type="application/zip",
        filename="renamed_images.zip",
    )


@router.get("/rename/session/{session_id}/download-excel")
async def download_rename_session_excel(
    session_id: str,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    """Stream the companion Excel sheet for a finalized session to the client."""

    temp_root = _get_temp_root(request, settings)
    session = _session_dir(session_id, temp_root)
    excel_path = session / f"qpic_renamed_{session_id}.xlsx"
    if not excel_path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Nothing to download for this session.",
        )
    return FileResponse(
        str(excel_path),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        filename="renamed_images.xlsx",
    )


@router.delete("/rename/session/{session_id}")
async def delete_rename_session(
    session_id: str,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> dict:
    """Drop a session and all its staged files (called after a download)."""

    temp_root = _get_temp_root(request, settings)
    await asyncio.to_thread(safe_cleanup_job, session_id, temp_root)
    return {"ok": True}


@router.post("/rename/preview", response_model=RenamePreviewResponse)
async def rename_preview(
    names: list[str] = Form(
        ...,
        description="Original filenames, in the order they should be numbered.",
    ),
    pattern: str = Form("#", description="Naming pattern; '#' is replaced by the running number."),
    start: int = Form(1, ge=0, le=1_000_000),
    padding: int = Form(0, ge=0, le=12),
) -> RenamePreviewResponse:
    """Preview the new names for a list of originals — no files uploaded.

    Lets the UI show a live before/after list as the user tweaks the pattern,
    start number and padding, without shipping the (potentially large) image
    bytes on every keystroke.
    """

    clean = [n for n in names if n and n.strip()]
    if not clean:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No filenames supplied.")

    new_names = plan_renames(clean, pattern=pattern, start=start, padding=padding)
    items = [
        RenamePlanItem(original=o, renamed=n) for o, n in zip(clean, new_names)
    ]
    return RenamePreviewResponse(count=len(items), items=items)


def _render_pdf_to_items(pdf_source: bytes | str | Path, dpi: int, stem: str) -> list[PdfImageItem]:
    """Rasterise every PDF page to a PNG data-URL item (runs off the loop)."""

    images = pdf_to_images(pdf_source, dpi)
    items: list[PdfImageItem] = []
    pad = max(2, len(str(len(images))))
    for idx, img in enumerate(images, start=1):
        buff = io.BytesIO()
        ensure_rgb(img).save(buff, format="PNG")
        raw = buff.getvalue()
        b64 = base64.b64encode(raw).decode("ascii")
        items.append(
            PdfImageItem(
                name=f"{stem}_p{str(idx).zfill(pad)}.png",
                data_url=f"data:image/png;base64,{b64}",
                width=img.width,
                height=img.height,
                size=len(raw),
            )
        )
    return items


@router.post("/rename/pdf-to-images", response_model=PdfToImagesResponse)
async def pdf_to_images_endpoint(
    request: Request,
    file: UploadFile = File(..., description="A PDF to convert into page images."),
    dpi: Optional[int] = Form(None, description="Optional rasterization DPI."),
    settings: Settings = Depends(get_settings),
) -> PdfToImagesResponse:
    """Convert an uploaded PDF into one PNG image per page.

    Each page is rendered at ``PDF_RENDER_DPI`` and returned as an inline
    ``data:`` URL, so the Rename Batch UI can drop the pages straight into its
    image list (preview, view one-by-one, remove, then rename) without a
    separate download step.
    """

    name = file.filename or "document.pdf"
    _, ext = split_extension(name)
    if ext != "pdf":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Not a PDF: {name}. Upload a .pdf file.",
        )

    job_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)
    job_dir = None
    try:
        job_dir = await asyncio.to_thread(create_job_dir, job_id, temp_root)
        source_pdf_path = job_dir / "source.pdf"

        # Stream upload directly to disk
        max_bytes = settings.MAX_PDF_SIZE_MB * 1024 * 1024
        from ..utils.file_utils import stream_upload_to_file
        await stream_upload_to_file(file, source_pdf_path, max_bytes)

        # Validate PDF on disk
        validate_pdf(source_pdf_path, settings)

        stem, _ = split_extension(name)
        stem = (stem or "page").strip() or "page"
        render_dpi = dpi if dpi is not None else settings.PDF_RENDER_DPI
        
        items = await asyncio.to_thread(
            _render_pdf_to_items, source_pdf_path, render_dpi, stem
        )
    except HTTPException:
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
    except Exception as exc:
        logger.exception("pdf_to_images_failed error=%s", str(exc))
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Couldn't convert that PDF to images.",
        ) from exc
    finally:
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)

    return PdfToImagesResponse(count=len(items), images=items)


@router.post("/rename/pdf-to-session", response_model=PdfToSessionResponse)
async def pdf_to_session(
    request: Request,
    file: UploadFile = File(..., description="A PDF to convert into page images."),
    dpi: Optional[int] = Form(None, description="Optional rasterization DPI."),
    quality: Optional[int] = Form(None, description="Optional JPEG quality (1-100)."),
    settings: Settings = Depends(get_settings),
) -> PdfToSessionResponse:
    """Convert an uploaded PDF to per-page JPEG files using parallel rendering.

    Much faster than ``pdf-to-images`` for large PDFs: pages are rendered
    in parallel threads, saved as JPEG (faster than PNG, smaller files),
    and served via individual download URLs instead of inline base64.
    """

    name = file.filename or "document.pdf"
    _, ext = split_extension(name)
    if ext != "pdf":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Not a PDF: {name}. Upload a .pdf file.",
        )

    job_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)
    job_dir = None
    try:
        job_dir = await asyncio.to_thread(create_job_dir, job_id, temp_root)
        source_pdf_path = job_dir / "source.pdf"

        max_bytes = settings.MAX_PDF_SIZE_MB * 1024 * 1024
        from ..utils.file_utils import stream_upload_to_file
        await stream_upload_to_file(file, source_pdf_path, max_bytes)

        validate_pdf(source_pdf_path, settings)

        stem, _ = split_extension(name)
        stem = (stem or "page").strip() or "page"
        render_dpi = dpi if dpi is not None else settings.PDF_RENDER_DPI
        render_quality = quality if quality is not None else 75

        pages_dir = job_dir / "pages"
        await asyncio.to_thread(pages_dir.mkdir, exist_ok=True)

        results = await asyncio.to_thread(
            parallel_render_pdf_to_files,
            source_pdf_path,
            render_dpi,
            pages_dir,
            stem,
            6,
            render_quality,
        )
    except HTTPException:
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
    except Exception as exc:
        logger.exception("pdf_to_session_failed error=%s", str(exc))
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Couldn't convert that PDF to images.",
        ) from exc

    import urllib.parse
    pages = [
        PdfPageItem(
            name=fname,
            page_url=f"/api/rename/pdf-page/{job_id}/{urllib.parse.quote(fname)}",
            width=w,
            height=h,
            size=sz,
        )
        for fname, w, h, sz in results
    ]
    return PdfToSessionResponse(job_id=job_id, count=len(pages), pages=pages)


@router.get("/rename/pdf-page/{job_id}/{page_name}")
async def serve_pdf_page(
    job_id: str,
    page_name: str,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    """Serve a single rendered PDF page image from disk."""

    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(job_id, temp_root)
    if job_dir is None or not job_dir.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown job.")
    page_path = job_dir / "pages" / page_name
    if not page_path.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Page not found.")
    return FileResponse(str(page_path), media_type="image/jpeg")


@router.post("/rename/pdf-session/{job_id}/finalize", response_model=RenameFinalizeResponse)
async def finalize_pdf_session(
    job_id: str,
    payload: PdfFinalizeRequest,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> RenameFinalizeResponse:
    """Finalize a PDF session directly by selecting, renaming, and packing pages already on disk.

    Avoids downloading and re-uploading pages from the client.
    """
    temp_root = _get_temp_root(request, settings)
    job_dir = get_job_dir(job_id, temp_root)
    if job_dir is None or not job_dir.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Unknown or expired PDF session.",
        )

    pages_dir = job_dir / "pages"
    if not pages_dir.exists():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No rendered pages found in this session.",
        )

    # Build the entries list: (original_name, source_path)
    entries: list[tuple[str, Path]] = []
    explicit_stems: list[str] = []
    for item in payload.items:
        p_path = pages_dir / item.original
        if not p_path.exists():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Page not found in session: {item.original}",
            )
        entries.append((item.original, p_path))
        explicit_stems.append(item.new_stem)

    if not entries:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No files selected for finalize.",
        )

    fmt = (payload.output_format or "original").strip().lower()
    if fmt not in OUTPUT_FORMATS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported output format: {payload.output_format}.",
        )

    zip_path = job_dir / RENAME_ZIP.format(job_id=job_id)
    excel_path = job_dir / f"qpic_renamed_{job_id}.xlsx"
    try:
        # Generate final filenames to ensure exact name alignment with the ZIP.
        new_names = plan_output_names(
            [name for name, _ in entries],
            pattern="#",
            start=1,
            padding=0,
            explicit_stems=explicit_stems,
            output_format=fmt,
        )

        count = await asyncio.to_thread(
            write_rename_zip_from_paths,
            zip_path,
            entries,
            pattern="#",
            start=1,
            padding=0,
            explicit_stems=explicit_stems,
            output_format=fmt,
            jpg_quality=payload.jpg_quality or 90,
        )

        # Generate companion Excel sheet
        await asyncio.to_thread(
            write_rename_excel,
            excel_path,
            new_names,
        )
    except Exception as exc:
        logger.exception("finalize_pdf_session failed job_id=%s error=%s", job_id, str(exc))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create rename archive: {exc}",
        ) from exc

    return RenameFinalizeResponse(
        session_id=job_id,
        count=count,
        download_url=f"/api/rename/session/{job_id}/download",
        excel_download_url=f"/api/rename/session/{job_id}/download-excel",
    )


@router.delete("/rename/pdf-session/{job_id}")
async def delete_pdf_session(
    job_id: str,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> dict:
    """Clean up a PDF-to-session job's files after the client is done."""

    temp_root = _get_temp_root(request, settings)
    await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
    return {"ok": True}



@router.post("/rename")
async def rename_batch(
    request: Request,
    files: list[UploadFile] = File(..., description="Images to rename."),
    pattern: str = Form("#"),
    start: int = Form(1, ge=0, le=1_000_000),
    padding: int = Form(0, ge=0, le=12),
    names: list[str] = Form(
        default=[],
        description="Optional explicit output stems (no extension), one per file, in order. "
        "When supplied these win over the pattern — this is how the UI's variable tokens arrive.",
    ),
    output_format: str = Form(
        "original",
        description="Output format: original, png, jpg/jpeg, or webp.",
    ),
    jpg_quality: int = Form(90, ge=1, le=100),
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    """Rename uploaded images and return them as a downloadable ZIP.

    The number token ``#`` in ``pattern`` is replaced by a running number from
    ``start``, zero-padded to ``padding`` digits — unless ``names`` is supplied,
    in which case each file uses its given stem (the UI expands variable tokens
    like ``(name)``/``(width)``/``(date)`` client-side). ``output_format``
    decides the extension: ``original`` copies bytes verbatim, otherwise every
    image is re-encoded to PNG/JPG/WEBP.
    """

    if not files:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No files uploaded.")

    fmt = (output_format or "original").strip().lower()
    if fmt not in OUTPUT_FORMATS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported output format: {output_format}.",
        )

    # Explicit names are optional, but when present must line up 1:1 with files.
    explicit_stems: Optional[list[str]] = None
    clean_names = [n for n in names if n is not None]
    if clean_names:
        if len(clean_names) != len(files):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Name count does not match the number of files.",
            )
        explicit_stems = clean_names

    max_bytes = settings.MAX_PDF_SIZE_MB * 1024 * 1024
    payload: list[tuple[str, bytes]] = []
    total = 0
    for upload in files:
        name = upload.filename or ""
        if not _is_allowed(name):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unsupported file type: {name or 'unnamed'}. Images only.",
            )
        raw = await upload.read()
        total += len(raw)
        if total > max_bytes * 4:
            # Generous combined cap (4x the single-PDF limit) so a big batch is
            # allowed without letting an unbounded upload exhaust disk/memory.
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail="Total upload is too large. Try fewer images at a time.",
            )
        payload.append((name, raw))

    job_id = generate_job_id()
    temp_root = _get_temp_root(request, settings)
    request_id = getattr(request.state, "request_id", None)

    job_dir: Optional[Path] = None
    try:
        job_dir = await asyncio.to_thread(create_job_dir, job_id, temp_root)
        zip_path = job_dir / RENAME_ZIP.format(job_id=job_id)
        count = await asyncio.to_thread(
            write_rename_zip,
            zip_path,
            payload,
            pattern=pattern,
            start=start,
            padding=padding,
            explicit_stems=explicit_stems,
            output_format=fmt,
            jpg_quality=jpg_quality,
        )
        logger.info(
            "request_id=%s job_id=%s stage=rename_done files=%s format=%s",
            request_id,
            job_id,
            count,
            fmt,
        )
        return FileResponse(
            str(zip_path),
            media_type="application/zip",
            filename="renamed_images.zip",
        )
    except HTTPException:
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
    except Exception as exc:
        logger.exception("request_id=%s job_id=%s stage=rename_error error=%s", request_id, job_id, str(exc))
        if job_dir is not None:
            await asyncio.to_thread(safe_cleanup_job, job_id, temp_root)
        raise
