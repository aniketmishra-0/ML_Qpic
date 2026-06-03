#!/usr/bin/env python3
"""Train a HiLEx question-paper detector with Ultralytics YOLO."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True, type=Path, help="Prepared data.yaml")
    parser.add_argument("--model", default="yolov8s.pt")
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--project", default="runs/detect")
    parser.add_argument("--name", default="qpic_hilex")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--amp", dest="amp", action="store_true", default=None)
    parser.add_argument("--no-amp", dest="amp", action="store_false")
    parser.add_argument("--val", dest="val", action="store_true", default=True)
    parser.add_argument("--no-val", dest="val", action="store_false")
    args = parser.parse_args()

    from ultralytics import YOLO

    model = YOLO(args.model)
    project = Path(args.project).expanduser().resolve()
    train_args = {
        "data": str(args.data),
        "epochs": args.epochs,
        "imgsz": args.imgsz,
        "batch": args.batch,
        "project": str(project),
        "name": args.name,
        "device": args.device,
        "workers": args.workers,
        "val": args.val,
    }
    if args.amp is not None:
        train_args["amp"] = args.amp
    model.train(**train_args)
    best = project / args.name / "weights" / "best.pt"
    print(f"Best weights: {best}")


if __name__ == "__main__":
    main()
