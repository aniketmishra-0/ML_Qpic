#!/usr/bin/env python3
"""Prepare the HiLEx question-paper dataset for Ultralytics YOLO training.

Expected HiLEx repo layout:

    HiLEx/
      images/
      HiLex_Yolo_Format/  or annotations/yolo/

The script creates a train/val/test split with images + labels and writes a
data.yaml file that Ultralytics can train from.
"""

from __future__ import annotations

import argparse
import random
import shutil
from pathlib import Path

try:
    import yaml
except Exception:  # pragma: no cover - optional training dependency
    yaml = None


CLASS_NAMES = [
    "answer_block",
    "description",
    "instruction",
    "question_answer_block",
    "question_block",
    "question_paper_area",
]

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def _find_labels_dir(root: Path) -> Path:
    candidates = [
        root / "HiLex_Yolo_Format",
        root / "HiLEx_Yolo_Format",
        root / "annotations" / "yolo",
        root / "labels",
    ]
    for path in candidates:
        if path.exists():
            return path
    raise SystemExit("Could not find HiLEx YOLO labels directory.")


def _find_images_dir(root: Path) -> Path:
    candidates = [root / "images", root / "Images"]
    for path in candidates:
        if path.exists():
            return path
    raise SystemExit("Could not find HiLEx images directory.")


def _write_yaml(path: Path, data: dict) -> None:
    if yaml is not None:
        path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
        return
    names = "\n".join(f"  {i}: {name}" for i, name in enumerate(data["names"]))
    path.write_text(
        f"path: {data['path']}\n"
        "train: images/train\n"
        "val: images/val\n"
        "test: images/test\n"
        f"names:\n{names}\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hilex-dir", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--train", type=float, default=0.8)
    parser.add_argument("--val", type=float, default=0.1)
    args = parser.parse_args()

    root = args.hilex_dir.resolve()
    out = args.out_dir.resolve()
    images_dir = _find_images_dir(root)
    labels_dir = _find_labels_dir(root)

    images = sorted(
        p for p in images_dir.rglob("*") if p.suffix.lower() in IMAGE_EXTS
    )
    pairs: list[tuple[Path, Path]] = []
    for img in images:
        label = labels_dir / f"{img.stem}.txt"
        if label.exists():
            pairs.append((img, label))
    if not pairs:
        raise SystemExit("No image/label pairs found.")

    rnd = random.Random(args.seed)
    rnd.shuffle(pairs)
    train_n = int(len(pairs) * args.train)
    val_n = int(len(pairs) * args.val)
    splits = {
        "train": pairs[:train_n],
        "val": pairs[train_n : train_n + val_n],
        "test": pairs[train_n + val_n :],
    }

    for split, rows in splits.items():
        (out / "images" / split).mkdir(parents=True, exist_ok=True)
        (out / "labels" / split).mkdir(parents=True, exist_ok=True)
        for img, label in rows:
            shutil.copy2(img, out / "images" / split / img.name)
            shutil.copy2(label, out / "labels" / split / label.name)

    _write_yaml(
        out / "data.yaml",
        {
            "path": str(out),
            "train": "images/train",
            "val": "images/val",
            "test": "images/test",
            "names": CLASS_NAMES,
        },
    )
    print(f"Prepared {len(pairs)} samples at {out}")


if __name__ == "__main__":
    main()
