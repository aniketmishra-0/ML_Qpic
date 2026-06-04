import os
import json
import pytest
import httpx
from pathlib import Path
from unittest.mock import patch, MagicMock

from app.main import app
from app.routers.crop import _load_cached_enhancements

def test_load_cached_enhancements_default(tmp_path):
    # Non-existent file should yield defaults
    config = _load_cached_enhancements(tmp_path)
    assert config["binarize"] is False
    assert config["contrast"] == 1.0
    assert config["brightness"] == 1.0
    assert config["watermark_threshold"] == 255
    assert config["deskew"] is False

def test_load_cached_enhancements_valid(tmp_path):
    # Write sample enhancements config
    data = {
        "binarize": True,
        "contrast": 1.8,
        "brightness": 1.2,
        "watermark_threshold": 230,
        "deskew": True
    }
    (tmp_path / "enhancements.json").write_text(json.dumps(data), "utf-8")
    
    config = _load_cached_enhancements(tmp_path)
    assert config["binarize"] is True
    assert config["contrast"] == 1.8
    assert config["brightness"] == 1.2
    assert config["watermark_threshold"] == 230
    assert config["deskew"] is True

def test_load_cached_enhancements_corrupted(tmp_path):
    # Invalid json should yield defaults
    (tmp_path / "enhancements.json").write_text("corrupted content", "utf-8")
    
    config = _load_cached_enhancements(tmp_path)
    assert config["binarize"] is False
    assert config["contrast"] == 1.0
    assert config["brightness"] == 1.0
    assert config["watermark_threshold"] == 255
    assert config["deskew"] is False
