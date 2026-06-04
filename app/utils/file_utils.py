"""Temporary directory management helpers."""

from __future__ import annotations

import logging
import shutil
import time
import uuid
from pathlib import Path

logger = logging.getLogger(__name__)


def generate_job_id() -> str:
    """Return a UUID4 hex string (no hyphens, 32 chars)."""

    return uuid.uuid4().hex


def get_job_dir(job_id: str, temp_dir: str) -> Path:
    """Return Path: temp/{job_id}/"""

    return Path(temp_dir) / job_id


def create_job_dir(job_id: str, temp_dir: str) -> Path:
    """Create and return the job directory."""

    job_dir = get_job_dir(job_id, temp_dir)
    job_dir.mkdir(parents=True, exist_ok=True)
    return job_dir


def cleanup_old_jobs(temp_dir: str, older_than_seconds: int) -> int:
    """Delete job directories older than the given threshold."""

    root = Path(temp_dir)
    if not root.exists():
        return 0

    now = time.time()
    deleted = 0
    for path in root.iterdir():
        if not path.is_dir():
            continue
        try:
            age = now - path.stat().st_mtime
            if age > older_than_seconds:
                shutil.rmtree(path, ignore_errors=False)
                deleted += 1
                logger.info("deleted_job_dir=%s age_seconds=%s", path.name, int(age))
        except (OSError, PermissionError) as exc:
            logger.warning("failed_delete_job_dir=%s error=%s", path.name, str(exc))
    return deleted


def safe_cleanup_job(job_id: str, temp_dir: str) -> None:
    """Delete a single job directory. Swallow all errors."""

    try:
        shutil.rmtree(get_job_dir(job_id, temp_dir), ignore_errors=True)
    except Exception:
        return


def has_pending_jobs(temp_dir: str) -> bool:
    """True if the temp root currently holds any job directory.

    Used by the periodic cleanup loop to back off when the app is idle: with no
    jobs on disk there's nothing to scan, so the loop can sleep much longer and
    avoid waking the CPU every minute (battery-friendly for a desktop app left
    open all day).
    """

    root = Path(temp_dir)
    if not root.exists():
        return False
    try:
        return any(p.is_dir() for p in root.iterdir())
    except OSError:
        return False


async def stream_upload_to_file(upload: any, dest_path: Path, max_bytes: int) -> int:
    """Stream an upload to a file on disk in chunks to keep memory usage flat."""
    from fastapi import HTTPException, status

    written = 0
    chunk_size = 1024 * 1024  # 1 MiB
    try:
        with open(dest_path, "wb") as out:
            while True:
                chunk = await upload.read(chunk_size)
                if not chunk:
                    break
                written += len(chunk)
                if written > max_bytes:
                    out.close()
                    dest_path.unlink(missing_ok=True)
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail=f"Upload exceeds size limit ({written / (1024 * 1024):.2f}MB > {max_bytes / (1024 * 1024)}MB)",
                    )
                out.write(chunk)
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Failed to write uploaded file to disk")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to stream upload to disk: {str(exc)}"
        ) from exc
    return written


