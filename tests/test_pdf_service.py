import fitz
import pytest
from fastapi import HTTPException

from app.config import Settings
from app.services.pdf_service import pdf_to_images, validate_pdf


def _make_pdf_bytes(page_count: int = 1) -> bytes:
    doc = fitz.open()
    for i in range(page_count):
        page = doc.new_page()
        page.insert_text((72, 72), f"Page {i + 1}")
    data = doc.tobytes()
    doc.close()
    return data


def test_validate_pdf_valid() -> None:
    pdf_bytes = _make_pdf_bytes(page_count=2)
    settings = Settings(MAX_PAGES=10, MAX_PDF_SIZE_MB=5)
    validate_pdf(pdf_bytes, settings)


def test_validate_pdf_too_large() -> None:
    pdf_bytes = _make_pdf_bytes(page_count=1)
    settings = Settings(MAX_PDF_SIZE_MB=0)
    with pytest.raises(HTTPException) as exc:
        validate_pdf(pdf_bytes, settings)
    assert exc.value.status_code == 413


def test_validate_pdf_not_pdf() -> None:
    settings = Settings()
    with pytest.raises(HTTPException) as exc:
        validate_pdf(b"not a pdf", settings)
    assert exc.value.status_code == 400


def test_pdf_to_images_returns_correct_count() -> None:
    pdf_bytes = _make_pdf_bytes(page_count=3)
    images = pdf_to_images(pdf_bytes, dpi=100)
    assert len(images) == 3


def test_parallel_render_pdf_to_files(tmp_path) -> None:
    from app.services.pdf_service import parallel_render_pdf_to_files
    pdf_bytes = _make_pdf_bytes(page_count=3)
    pdf_path = tmp_path / "test.pdf"
    pdf_path.write_bytes(pdf_bytes)
    
    results = parallel_render_pdf_to_files(pdf_path, dpi=72, output_dir=tmp_path, stem="test_page")
    assert len(results) == 3
    for fname, w, h, sz in results:
        assert (tmp_path / fname).exists()
        assert sz > 0
        assert w > 0
        assert h > 0


def test_parallel_render_quality(tmp_path) -> None:
    from app.services.pdf_service import parallel_render_pdf_to_files
    pdf_bytes = _make_pdf_bytes(page_count=1)
    pdf_path = tmp_path / "test.pdf"
    pdf_path.write_bytes(pdf_bytes)
    
    # Render with Low Quality (60)
    low_dir = tmp_path / "low"
    low_dir.mkdir()
    low_results = parallel_render_pdf_to_files(pdf_path, dpi=150, output_dir=low_dir, stem="low_page", jpg_quality=60)
    
    # Render with High Quality (90)
    high_dir = tmp_path / "high"
    high_dir.mkdir()
    high_results = parallel_render_pdf_to_files(pdf_path, dpi=150, output_dir=high_dir, stem="high_page", jpg_quality=90)
    
    assert len(low_results) == 1
    assert len(high_results) == 1
    
    low_size = low_results[0][3]
    high_size = high_results[0][3]
    
    # Low quality JPEG should be smaller than High quality JPEG
    assert low_size < high_size


