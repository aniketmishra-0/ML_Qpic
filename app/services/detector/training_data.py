"""Training-data capture for future Qpic local ML fine-tuning."""

from __future__ import annotations

import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

import fitz

from ...models.schemas import DetectedQuestion


def write_training_example(
    *,
    job_id: str,
    source_pdf: Path,
    questions: list[DetectedQuestion],
    output_root: Path,
) -> Path:
    """Store reviewed boxes as a compact training example.

    The source PDF is copied once and annotations are stored in page-percentage
    coordinates. A future training script can rasterize at whatever DPI it
    needs without losing precision or ballooning the app's temp directory with
    page PNGs on every finalize.
    """

    run_dir = output_root / job_id
    run_dir.mkdir(parents=True, exist_ok=True)

    pdf_target = run_dir / "source.pdf"
    if not pdf_target.exists():
        shutil.copyfile(source_pdf, pdf_target)

    page_sizes: dict[int, dict[str, float]] = {}
    with fitz.open(str(source_pdf)) as doc:
        for idx, page in enumerate(doc, start=1):
            page_sizes[idx] = {
                "width_pt": float(page.rect.width),
                "height_pt": float(page.rect.height),
            }

    payload = {
        "job_id": job_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "format": "qpic-local-ml-training-v1",
        "source_pdf": "source.pdf",
        "page_sizes": page_sizes,
        "annotations": [
            {
                "q_num": q.q_num,
                "label": "solution" if q.is_solution else "question",
                "source": q.source,
                "segments": [seg.model_dump() for seg in q.segments],
            }
            for q in questions
        ],
    }
    (run_dir / "annotations.json").write_text(
        json.dumps(payload, indent=2), encoding="utf-8"
    )
    return run_dir
