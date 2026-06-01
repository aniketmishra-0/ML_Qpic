"""Tests for the Qpic packaging sidecar (headless launcher).

These tests live outside the engine tree (`app/`) and the desktop Flutter
project (`desktop/`); they exercise only the new packaging sidecar entry point
(`packaging/sidecar.py`) and the engine's existing, unchanged OCR/Tesseract
behavior over its public surface. No file under `app/` is modified.
"""
