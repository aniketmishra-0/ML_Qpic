# Qpic Local ML Training

This folder contains the offline model route for Qpic's Local ML tier.

Recommended target:

1. Train a YOLO detector on the HiLEx question-paper layout dataset.
2. Export/install the trained model as ONNX into
   `vendor/models/qpic-question-detector/`.
3. Bundle `requirements-local-ml.txt` in desktop builds that ship Local ML.
   Use `requirements-local-ml-train.txt` only on developer machines.

The detector should emit at least `question_answer_block`; Qpic also accepts
`question_block` as a question class and `answer_block` / `description` /
`solution_block` as solution classes.

Typical flow:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-local-ml-train.txt

# After cloning/downloading HiLEx:
.venv/bin/python scripts/local_ml/prepare_hilex_yolo.py \
  --hilex-dir /path/to/HiLEx \
  --out-dir temp/hilex_yolo

.venv/bin/python scripts/local_ml/train_hilex_yolo.py \
  --data temp/hilex_yolo/data.yaml \
  --epochs 25 \
  --model yolov8s.pt

.venv/bin/python scripts/local_ml/install_yolo_model.py \
  --weights runs/detect/qpic_hilex/weights/best.pt
```

The app then loads:

```text
vendor/models/qpic-question-detector/model.onnx
vendor/models/qpic-question-detector/labels.json
vendor/models/qpic-question-detector/manifest.json
```
