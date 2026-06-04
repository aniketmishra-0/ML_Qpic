"""Document Quality Enhancer and Watermark Remover Service.

Applies brightness, contrast, adaptive thresholding (watermark removal), and
binarization to PDF pages using PyMuPDF, PIL, and NumPy.

Also provides an advanced "AI Enhance" pipeline (local) using OpenCV's
Non-Local Means denoising, CLAHE adaptive contrast, detail enhancement,
and multi-pass Unsharp Mask sharpening — producing Remini-like results
without requiring an internet connection.

Optional online super-resolution via Hugging Face Inference API
(router.huggingface.co) for 2× upscaling when enabled.
"""

from __future__ import annotations

import io
import logging
from pathlib import Path

import cv2
import fitz
import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
#  Core enhance_image (manual sliders — unchanged contract)
# ---------------------------------------------------------------------------

def enhance_image(
    img: Image.Image,
    binarize: bool = False,
    binarize_threshold: int = 185,
    contrast: float = 1.0,
    brightness: float = 1.0,
    watermark_threshold: int = 255,
    denoise: int = 0,
    deskew: bool = False,
) -> Image.Image:
    """Enhance a single PIL Image using contrast, brightness, watermark threshold, binarization, denoise, and deskewing."""
    
    img = img.convert("RGB")
    
    # 0. Noise Reduction (Denoise) using MedianFilter
    if denoise > 0:
        # denoise=1 -> kernel size 3, denoise=2 -> kernel size 5, etc.
        kernel_size = 2 * denoise + 1
        img = img.filter(ImageFilter.MedianFilter(size=kernel_size))
    
    # 1. Contrast & Brightness adjustments
    if brightness != 1.0:
        img = ImageEnhance.Brightness(img).enhance(brightness)
    if contrast != 1.0:
        img = ImageEnhance.Contrast(img).enhance(contrast)
        
    # 2. Adaptive Watermark/Background Removal
    # 255 means disabled (pure white background threshold)
    if watermark_threshold < 255:
        arr = np.array(img)
        # Identify pixels where red, green, and blue values are all higher than the threshold (faint pixels)
        mask = (arr[:, :, 0] > watermark_threshold) & (arr[:, :, 1] > watermark_threshold) & (arr[:, :, 2] > watermark_threshold)
        arr[mask] = [255, 255, 255]
        img = Image.fromarray(arr)
        
    # 3. Binarization (convert to high-contrast monochrome)
    if binarize:
        gray = img.convert("L")
        # Apply binary threshold
        binary = gray.point(lambda p: 255 if p > binarize_threshold else 0, '1')
        img = binary.convert("RGB")
        
    # 4. Deskewing (rotate to make text rows horizontal)
    if deskew:
        from ..pdf_service import deskew_image
        img = deskew_image(img)
        
    return img


# ---------------------------------------------------------------------------
#  Advanced "AI Enhance" pipeline (local, no internet required)
# ---------------------------------------------------------------------------

def ai_enhance_image(
    img: Image.Image,
    *,
    strength: int = 3,          # 1-5 (low to aggressive)
    face_enhance: bool = True,  # detail-preserve mode for faces/text
    sharpen: int = 3,           # 0-5 sharpening passes
    upscale: int = 1,           # 1 = keep size, 2 = 2× upscale (local bicubic)
    color_fix: bool = True,     # auto white-balance / color correction
) -> Image.Image:
    """
    Remini-like AI image enhancement using OpenCV algorithms.

    Pipeline:
      1. Non-Local Means Denoising (powerful noise removal preserving edges)
      2. CLAHE adaptive contrast equalization
      3. Detail Enhancement (edge-aware smoothing)
      4. Multi-pass Unsharp Mask sharpening
      5. Auto white-balance / color correction
      6. Optional 2× upscale with Lanczos interpolation

    All processing is 100% local using OpenCV — no internet needed.
    """
    img = img.convert("RGB")
    arr = np.array(img)
    # Convert RGB (PIL) → BGR (OpenCV)
    bgr = cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)

    h, w = bgr.shape[:2]

    # ── Step 1: Non-Local Means Denoising ──
    # Gentle denoising parameters to avoid painterly/plasticky look while removing noise.
    h_lum = 2 + strength * 1.0          # 3.0, 4.0, 5.0, 6.0, 7.0
    h_color = 2 + strength * 0.8        # 2.8, 3.6, 4.4, 5.2, 6.0
    template_ws = 7                      # template window size
    search_ws = 21                       # search window size
    
    denoised = cv2.fastNlMeansDenoisingColored(
        bgr, None, h_lum, h_color, template_ws, search_ws
    )

    # ── Step 2: CLAHE (Contrast Limited Adaptive Histogram Equalization) ──
    # Soft contrast adjustment to avoid dark/light halo outlines.
    lab = cv2.cvtColor(denoised, cv2.COLOR_BGR2LAB)
    l_channel, a_channel, b_channel = cv2.split(lab)
    
    clip_limit = 1.0 + strength * 0.2   # 1.2, 1.4, 1.6, 1.8, 2.0
    clahe = cv2.createCLAHE(clipLimit=clip_limit, tileGridSize=(8, 8))
    l_enhanced = clahe.apply(l_channel)
    
    lab_enhanced = cv2.merge([l_enhanced, a_channel, b_channel])
    result = cv2.cvtColor(lab_enhanced, cv2.COLOR_LAB2BGR)

    # ── Step 3: Detail Enhancement (edge-preserving smooth) ──
    if face_enhance:
        sigma_s = 10 + strength * 3
        sigma_r = max(0.15, 0.30 - strength * 0.03)
        result = cv2.detailEnhance(result, sigma_s=sigma_s, sigma_r=sigma_r)

    # ── Step 4: Multi-pass Unsharp Mask Sharpening ──
    # Gentler sharpening passes to eliminate harsh white halo outlines.
    if sharpen > 0:
        for i in range(sharpen):
            sigma = 1.0 + i * 0.5
            amount = 0.05 + (strength * 0.03) + (i * 0.02)
            
            gaussian = cv2.GaussianBlur(result, (0, 0), sigma)
            result = cv2.addWeighted(result, 1.0 + amount, gaussian, -amount, 0)

    # ── Step 5: Auto White Balance / Color Correction ──
    if color_fix:
        result = _auto_white_balance(result)

    # ── Step 6: Optional upscale (local bicubic/Lanczos) ──
    if upscale >= 2:
        new_w = w * upscale
        new_h = h * upscale
        # INTER_LANCZOS4 gives the highest quality local upscale
        result = cv2.resize(result, (new_w, new_h), interpolation=cv2.INTER_LANCZOS4)

    # Clip values and convert back to PIL
    result = np.clip(result, 0, 255).astype(np.uint8)
    rgb = cv2.cvtColor(result, cv2.COLOR_BGR2RGB)
    return Image.fromarray(rgb)


def _auto_white_balance(bgr: np.ndarray) -> np.ndarray:
    """Simple gray-world auto white balance correction."""
    result = bgr.astype(np.float32)
    avg_b = np.mean(result[:, :, 0])
    avg_g = np.mean(result[:, :, 1])
    avg_r = np.mean(result[:, :, 2])
    avg_all = (avg_b + avg_g + avg_r) / 3.0
    
    if avg_b > 0:
        result[:, :, 0] *= avg_all / avg_b
    if avg_g > 0:
        result[:, :, 1] *= avg_all / avg_g
    if avg_r > 0:
        result[:, :, 2] *= avg_all / avg_r
    
    return np.clip(result, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
#  Online Super-Resolution via Hugging Face Inference API
# ---------------------------------------------------------------------------

async def hf_super_resolve(
    img: Image.Image,
    *,
    api_token: str,
    model: str = "caidas/swin2SR-lightweight-x2-64",
) -> Image.Image:
    """
    Send an image to Hugging Face's Inference API for AI super-resolution.
    Uses router.huggingface.co (the new endpoint that resolves correctly).
    Returns the upscaled PIL Image, or the original on failure.
    """
    import httpx

    api_url = f"https://router.huggingface.co/hf-inference/models/{model}"
    headers = {"Authorization": f"Bearer {api_token}"}

    # Convert PIL → JPEG bytes (smaller payload, faster upload)
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=85)
    img_bytes = buf.getvalue()

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(api_url, headers=headers, content=img_bytes)

            if resp.status_code == 200:
                out_img = Image.open(io.BytesIO(resp.content))
                logger.info(
                    "HF super-resolution OK: %dx%d → %dx%d",
                    img.width, img.height, out_img.width, out_img.height,
                )
                return out_img
            else:
                logger.warning(
                    "HF super-resolution failed: status=%s body=%s",
                    resp.status_code, resp.text[:300],
                )
                return img
    except Exception as exc:
        logger.warning("HF super-resolution error: %s", str(exc))
        return img


# ---------------------------------------------------------------------------
#  PDF helpers (unchanged contract)
# ---------------------------------------------------------------------------

def enhance_pdf(
    pdf_source: bytes | str | Path,
    binarize: bool = False,
    contrast: float = 1.0,
    brightness: float = 1.0,
    watermark_threshold: int = 255,
    dpi: int = 200,
    deskew: bool = False,
) -> bytes:
    """Enhance all pages in a PDF and return the compiled enhanced PDF bytes."""
    
    if isinstance(pdf_source, bytes):
        doc = fitz.open(stream=pdf_source, filetype="pdf")
    else:
        doc = fitz.open(str(pdf_source))
    enhanced_images = []
    
    try:
        for page_no in range(doc.page_count):
            page = doc.load_page(page_no)
            
            # Render page pixmap to PNG bytes
            zoom = dpi / 72.0
            mat = fitz.Matrix(zoom, zoom)
            pix = page.get_pixmap(matrix=mat)
            img_data = pix.tobytes("png")
            
            img = Image.open(io.BytesIO(img_data))
            enhanced = enhance_image(
                img,
                binarize=binarize,
                contrast=contrast,
                brightness=brightness,
                watermark_threshold=watermark_threshold,
                deskew=deskew,
            )
            enhanced_images.append(enhanced)
            
        # Re-save all enhanced page images back as a single PDF document
        out_pdf = io.BytesIO()
        if enhanced_images:
            enhanced_images[0].save(
                out_pdf,
                format="PDF",
                save_all=True,
                append_images=enhanced_images[1:]
            )
        return out_pdf.getvalue()
    finally:
        doc.close()

def enhance_page_to_png(
    pdf_source: bytes | str | Path,
    page_no: int, # 1-indexed
    binarize: bool = False,
    contrast: float = 1.0,
    brightness: float = 1.0,
    watermark_threshold: int = 255,
    dpi: int = 200,
    deskew: bool = False,
) -> bytes:
    """Render a single page of a PDF and return its enhanced PNG bytes for real-time preview."""
    
    if isinstance(pdf_source, bytes):
        doc = fitz.open(stream=pdf_source, filetype="pdf")
    else:
        doc = fitz.open(str(pdf_source))
    if page_no < 1 or page_no > doc.page_count:
        doc.close()
        raise IndexError("Page number out of range")
        
    try:
        page = doc.load_page(page_no - 1)
        
        # Render page pixmap
        zoom = dpi / 72.0
        mat = fitz.Matrix(zoom, zoom)
        pix = page.get_pixmap(matrix=mat)
        img_data = pix.tobytes("png")
        
        img = Image.open(io.BytesIO(img_data))
        enhanced = enhance_image(
            img,
            binarize=binarize,
            contrast=contrast,
            brightness=brightness,
            watermark_threshold=watermark_threshold,
            deskew=deskew,
        )
        
        buff = io.BytesIO()
        enhanced.save(buff, format="PNG")
        return buff.getvalue()
    finally:
        doc.close()
