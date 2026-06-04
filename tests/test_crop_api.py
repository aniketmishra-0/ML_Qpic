import os

import pytest
import httpx

os.environ["ANTHROPIC_API_KEY"] = ""

from app.main import app  # noqa: E402


@pytest.mark.asyncio
async def test_health_endpoint() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/health")
            assert resp.status_code == 200
            data = resp.json()
            assert data["status"] == "ok"
            assert "tesseract_available" in data
            assert "ai_available" in data
            assert "local_ml_available" in data
            assert "version" in data
            assert isinstance(data["tesseract_available"], bool)
            assert isinstance(data["ai_available"], bool)
            assert isinstance(data["local_ml_available"], bool)


@pytest.mark.asyncio
async def test_crop_endpoint_no_file() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post("/api/crop")
            assert resp.status_code == 422


@pytest.mark.asyncio
async def test_crop_endpoint_wrong_file_type() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            files = {"file": ("test.txt", b"hello", "text/plain")}
            # question_pages is required; provide it so the request reaches the
            # content-type check rather than failing query validation.
            resp = await client.post("/api/crop?question_pages=1-5&has_answers=false", files=files)
            assert resp.status_code == 400
            assert "detail" in resp.json()


@pytest.mark.asyncio
async def test_crop_endpoint_requires_question_pages() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            files = {"file": ("test.pdf", b"%PDF-1.4 fake", "application/pdf")}
            resp = await client.post("/api/crop", files=files)
            # has_questions defaults to true, so omitting question_pages is a 400.
            assert resp.status_code == 400
            assert "Question" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_crop_endpoint_rejects_nothing_selected() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            files = {"file": ("test.pdf", b"%PDF-1.4 fake", "application/pdf")}
            # Both toggles off -> nothing to crop -> 400.
            resp = await client.post(
                "/api/crop?has_questions=false&has_answers=false", files=files
            )
            assert resp.status_code == 400
            assert "Nothing to crop" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_crop_endpoint_requires_answer_pages_when_solutions_on() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            files = {"file": ("test.pdf", b"%PDF-1.4 fake", "application/pdf")}
            # has_answers defaults to true, so omitting answer_pages is a 400.
            resp = await client.post("/api/crop?question_pages=1-5", files=files)
            assert resp.status_code == 400
            assert "Answer" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_download_nonexistent_job() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/crop/download/doesnotexist")
            assert resp.status_code == 404


@pytest.mark.asyncio
async def test_align_offsets_endpoint_nonexistent_job() -> None:
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            payload = {
                "job_id": "doesnotexist",
                "segments": [
                    {
                        "page": 1,
                        "x_start_pct": 10.0,
                        "x_end_pct": 90.0,
                        "y_start_pct": 20.0,
                        "y_end_pct": 30.0
                    }
                ]
            }
            resp = await client.post("/api/tools/align-offsets", json=payload)
            assert resp.status_code == 404


@pytest.mark.asyncio
async def test_align_offsets_calculation_logic() -> None:
    from unittest.mock import patch
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            payload = {
                "job_id": "mockjob",
                "segments": [
                    {
                        "page": 1,
                        "x_start_pct": 10.0,
                        "x_end_pct": 90.0,
                        "y_start_pct": 20.0,
                        "y_end_pct": 30.0
                    },
                    {
                        "page": 1,
                        "x_start_pct": 12.0,
                        "x_end_pct": 90.0,
                        "y_start_pct": 40.0,
                        "y_end_pct": 50.0
                    },
                    {
                        "page": 1,
                        "x_start_pct": 30.0,
                        "x_end_pct": 90.0,
                        "y_start_pct": 60.0,
                        "y_end_pct": 70.0
                    }
                ]
            }
            with patch("pathlib.Path.exists", return_value=True):
                resp = await client.post("/api/tools/align-offsets", json=payload)
                assert resp.status_code == 200
                offsets = resp.json()["offsets"]
                assert offsets[0] == 0.0  # reference segment
                assert offsets[1] == 2.0  # 12.0 - 10.0 = 2.0 (within 15% threshold)
                assert offsets[2] == 0.0  # 30.0 - 10.0 = 20.0 (exceeds 15% threshold, zeroed out)


def test_bilingual_layout_sorting() -> None:
    # Test bilingual layout sorting comparator inside crop.py
    from app.models.schemas import DetectedQuestion, QuestionSegment
    import functools

    def compare_items(it1, it2):
        p1 = it1.segments[0].page if it1.segments else 0
        p2 = it2.segments[0].page if it2.segments else 0
        if p1 != p2:
            return -1 if p1 < p2 else 1

        s1 = it1.segments[0] if it1.segments else None
        s2 = it2.segments[0] if it2.segments else None
        if not s1 or not s2:
            return 0

        c1 = (s1.x_start_pct + s1.x_end_pct) / 2.0
        c2 = (s2.x_start_pct + s2.x_end_pct) / 2.0
        is_side_by_side = (abs(s1.x_start_pct - s2.x_start_pct) > 15.0) or (abs(c1 - c2) > 15.0)

        if is_side_by_side:
            return -1 if s1.x_start_pct < s2.x_start_pct else (1 if s1.x_start_pct > s2.x_start_pct else 0)
        else:
            return -1 if s1.y_start_pct < s2.y_start_pct else (1 if s1.y_start_pct > s2.y_start_pct else 0)

    # 1. Different pages:
    item_p2 = DetectedQuestion(q_num="1", segments=[QuestionSegment(page=2, x_start_pct=10.0, x_end_pct=50.0, y_start_pct=10.0, y_end_pct=20.0)])
    item_p1 = DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, x_start_pct=50.0, x_end_pct=90.0, y_start_pct=10.0, y_end_pct=20.0)])
    items = [item_p2, item_p1]
    items.sort(key=functools.cmp_to_key(compare_items))
    assert items[0] == item_p1
    assert items[1] == item_p2

    # 2. Side-by-side:
    item_left = DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, x_start_pct=10.0, x_end_pct=40.0, y_start_pct=10.0, y_end_pct=20.0)])
    item_right = DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, x_start_pct=55.0, x_end_pct=85.0, y_start_pct=10.0, y_end_pct=20.0)])
    items = [item_right, item_left]
    items.sort(key=functools.cmp_to_key(compare_items))
    assert items[0] == item_left
    assert items[1] == item_right

    # 3. Vertically-stacked (same column / single column):
    item_top = DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, x_start_pct=10.0, x_end_pct=90.0, y_start_pct=10.0, y_end_pct=20.0)])
    item_bottom = DetectedQuestion(q_num="1", segments=[QuestionSegment(page=1, x_start_pct=12.0, x_end_pct=92.0, y_start_pct=30.0, y_end_pct=40.0)])
    items = [item_bottom, item_top]
    items.sort(key=functools.cmp_to_key(compare_items))
    assert items[0] == item_top
    assert items[1] == item_bottom


@pytest.mark.asyncio
async def test_enhance_image_endpoint() -> None:
    from PIL import Image
    import io
    # Create a simple 10x10 test image
    img = Image.new("RGB", (10, 10), color="red")
    img_byte_arr = io.BytesIO()
    img.save(img_byte_arr, format='PNG')
    img_bytes = img_byte_arr.getvalue()

    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            files = {"file": ("test.png", img_bytes, "image/png")}
            data = {
                "binarize": "true",
                "binarize_threshold": "128",
                "contrast": "1.2",
                "brightness": "1.1",
                "watermark_threshold": "240",
                "denoise": "1",
                "deskew": "false",
            }
            resp = await client.post("/api/tools/enhance-image", files=files, data=data)
            assert resp.status_code == 200
            assert resp.headers["content-type"] == "image/png"
            # Read the output image and make sure it has the same size
            out_img = Image.open(io.BytesIO(resp.content))
            assert out_img.size == (10, 10)


