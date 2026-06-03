#!/usr/bin/env python3
"""Convert Qpic's collected training data to YOLO format for training.

Reads the annotations.json + source.pdf pairs from temp/local_ml_training/
and produces a YOLO-ready dataset with page images + label .txt files.

Usage:
    python scripts/local_ml/convert_training_to_yolo.py \
        --training-dir temp/local_ml_training \
        --out-dir temp/custom_yolo \
        --dpi 640
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
from pathlib import Path

import fitz  # PyMuPDF
from PIL import Image


# HiLEx class mapping — must match prepare_hilex_yolo.py and labels.json
CLASS_NAMES = [
    "answer_block",       # 0
    "description",        # 1
    "instruction",        # 2
    "question_answer_block",  # 3
    "question_block",     # 4
    "question_paper_area",    # 5
]

# Map Qpic annotation labels → YOLO class IDs
LABEL_TO_CLASS = {
    "question": 3,   # question_answer_block (most common question type)
    "solution": 0,   # answer_block
}


def _render_page(doc: fitz.Document, page_idx: int, dpi: int) -> Image.Image:
    """Render a single PDF page to a PIL Image at the given DPI."""
    page = doc.load_page(page_idx)
    scale = dpi / 72.0
    mat = fitz.Matrix(scale, scale)
    pix = page.get_pixmap(matrix=mat, alpha=False)
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def convert_job(job_dir: Path, out_images: Path, out_labels: Path, dpi: int) -> int:
    """Convert one training job's annotations to YOLO format.

    Returns the number of page images generated.
    """
    ann_file = job_dir / "annotations.json"
    pdf_file = job_dir / "source.pdf"

    if not ann_file.exists() or not pdf_file.exists():
        return 0

    with open(ann_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    annotations = data.get("annotations", [])
    if not annotations:
        return 0

    # Group segments by page number
    page_labels: dict[int, list[str]] = {}  # page -> list of YOLO label lines
    for ann in annotations:
        label = ann.get("label", "question")
        class_id = LABEL_TO_CLASS.get(label, 3)

        for seg in ann.get("segments", []):
            page = seg.get("page", 1)

            # Convert from 0-100 percentage to 0-1 normalized (YOLO format)
            x_start = seg.get("x_start_pct", 0.0) / 100.0
            x_end = seg.get("x_end_pct", 100.0) / 100.0
            y_start = seg.get("y_start_pct", 0.0) / 100.0
            y_end = seg.get("y_end_pct", 100.0) / 100.0

            # Clamp to valid range
            x_start = max(0.0, min(1.0, x_start))
            x_end = max(0.0, min(1.0, x_end))
            y_start = max(0.0, min(1.0, y_start))
            y_end = max(0.0, min(1.0, y_end))

            # YOLO format: class_id x_center y_center width height
            x_center = (x_start + x_end) / 2.0
            y_center = (y_start + y_end) / 2.0
            width = x_end - x_start
            height = y_end - y_start

            if width <= 0 or height <= 0:
                continue

            line = f"{class_id} {x_center:.6f} {y_center:.6f} {width:.6f} {height:.6f}"
            page_labels.setdefault(page, []).append(line)

    if not page_labels:
        return 0

    # Render PDF pages and write images + labels
    job_id = data.get("job_id", job_dir.name)
    count = 0

    with fitz.open(str(pdf_file)) as doc:
        for page_num, labels in sorted(page_labels.items()):
            if page_num < 1 or page_num > doc.page_count:
                continue

            # Unique filename per job+page
            stem = f"{job_id}_p{page_num}"
            img = _render_page(doc, page_num - 1, dpi)
            img.save(out_images / f"{stem}.jpg", quality=95)

            label_text = "\n".join(labels) + "\n"
            (out_labels / f"{stem}.txt").write_text(label_text, encoding="utf-8")
            count += 1

    return count


def write_data_yaml(out_dir: Path) -> None:
    """Write the data.yaml for Ultralytics YOLO training."""
    try:
        import yaml
        data = {
            "path": str(out_dir.resolve()),
            "train": "images/train",
            "val": "images/val",
            "test": "images/test",
            "names": CLASS_NAMES,
        }
        (out_dir / "data.yaml").write_text(
            yaml.safe_dump(data, sort_keys=False), encoding="utf-8"
        )
    except ImportError:
        names = "\n".join(f"  {i}: {name}" for i, name in enumerate(CLASS_NAMES))
        (out_dir / "data.yaml").write_text(
            f"path: {out_dir.resolve()}\n"
            "train: images/train\n"
            "val: images/val\n"
            "test: images/test\n"
            f"names:\n{names}\n",
            encoding="utf-8",
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert Qpic collected training data to YOLO format"
    )
    parser.add_argument(
        "--training-dir",
        type=Path,
        default=Path("temp/local_ml_training"),
        help="Directory with collected training jobs (default: temp/local_ml_training)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("temp/custom_yolo"),
        help="Output directory for YOLO dataset (default: temp/custom_yolo)",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=640,
        help="DPI for rendering PDF pages (default: 640 for good quality)",
    )
    parser.add_argument(
        "--train-split",
        type=float,
        default=0.8,
        help="Fraction for training (default: 0.8)",
    )
    parser.add_argument(
        "--val-split",
        type=float,
        default=0.1,
        help="Fraction for validation (default: 0.1)",
    )
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    training_dir = args.training_dir.resolve()
    out_dir = args.out_dir.resolve()

    if not training_dir.exists():
        raise SystemExit(f"Training directory not found: {training_dir}")

    # Collect all job directories
    job_dirs = sorted(
        d for d in training_dir.iterdir()
        if d.is_dir() and (d / "annotations.json").exists()
    )
    if not job_dirs:
        raise SystemExit(f"No training jobs found in {training_dir}")

    print(f"Found {len(job_dirs)} training job(s)")

    # First pass: convert all jobs to a flat staging area
    staging_images = out_dir / "_staging" / "images"
    staging_labels = out_dir / "_staging" / "labels"
    staging_images.mkdir(parents=True, exist_ok=True)
    staging_labels.mkdir(parents=True, exist_ok=True)

    total = 0
    for job_dir in job_dirs:
        n = convert_job(job_dir, staging_images, staging_labels, args.dpi)
        print(f"  {job_dir.name}: {n} page(s)")
        total += n

    if total == 0:
        raise SystemExit("No valid training pages generated!")

    # Collect all image/label pairs
    pairs = []
    for img_path in sorted(staging_images.glob("*.jpg")):
        label_path = staging_labels / f"{img_path.stem}.txt"
        if label_path.exists():
            pairs.append((img_path, label_path))

    print(f"\nTotal training pairs: {len(pairs)}")

    # Split into train/val/test
    rnd = random.Random(args.seed)
    rnd.shuffle(pairs)
    train_n = int(len(pairs) * args.train_split)
    val_n = int(len(pairs) * args.val_split)
    splits = {
        "train": pairs[:train_n],
        "val": pairs[train_n:train_n + val_n],
        "test": pairs[train_n + val_n:],
    }

    for split_name, split_pairs in splits.items():
        img_dir = out_dir / "images" / split_name
        lbl_dir = out_dir / "labels" / split_name
        img_dir.mkdir(parents=True, exist_ok=True)
        lbl_dir.mkdir(parents=True, exist_ok=True)
        for img_path, label_path in split_pairs:
            shutil.copy2(img_path, img_dir / img_path.name)
            shutil.copy2(label_path, lbl_dir / label_path.name)
        print(f"  {split_name}: {len(split_pairs)} samples")

    # Cleanup staging
    shutil.rmtree(out_dir / "_staging", ignore_errors=True)

    # Write data.yaml
    write_data_yaml(out_dir)
    print(f"\n✅ YOLO dataset ready at: {out_dir}")
    print(f"   data.yaml: {out_dir / 'data.yaml'}")
    print(f"\nNext: Upload this folder to Google Drive and train on Colab!")


if __name__ == "__main__":
    main()
