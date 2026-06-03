#!/usr/bin/env python3
"""Install trained Local ML weights into Qpic's vendor model folder."""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path


LABELS = {
    0: "answer_block",
    1: "description",
    2: "instruction",
    3: "question_answer_block",
    4: "question_block",
    5: "question_paper_area",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--opset", type=int, default=20)
    parser.add_argument("--keep-pt", action="store_true")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("vendor/models/qpic-question-detector"),
    )
    args = parser.parse_args()

    weights = args.weights.expanduser().resolve()
    if not weights.exists():
        raise SystemExit(f"Weights not found: {weights}")

    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    target = out / "model.onnx"
    source_format = weights.suffix.lower().lstrip(".")
    if weights.suffix.lower() == ".onnx":
        shutil.copy2(weights, target)
    elif weights.suffix.lower() == ".pt":
        from ultralytics import YOLO

        model = YOLO(str(weights))
        exported = Path(
            model.export(
                format="onnx",
                imgsz=args.imgsz,
                dynamic=False,
                simplify=False,
                opset=args.opset,
            )
        ).resolve()
        shutil.copy2(exported, target)
        if args.keep_pt:
            shutil.copy2(weights, out / "model.pt")
    else:
        raise SystemExit(f"Unsupported weight format: {weights.suffix}")

    (out / "labels.json").write_text(json.dumps(LABELS, indent=2), encoding="utf-8")
    manifest = {
        "name": "qpic-hilex-question-detector",
        "format": "onnx-yolo",
        "model_file": "model.onnx",
        "labels_file": "labels.json",
        "installed_at": datetime.now(timezone.utc).isoformat(),
        "source_weights": str(weights),
        "source_format": source_format,
        "input_size": args.imgsz,
        "opset": args.opset,
    }
    (out / "manifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )
    print(f"Installed Local ML model to {out}")


if __name__ == "__main__":
    main()
