"""Document Quality Enhancer and Watermark Remover Service.

Applies brightness, contrast, adaptive thresholding (watermark removal), and
binarization to PDF pages using PyMuPDF, PIL, and NumPy.
"""

from __future__ import annotations

import io
import fitz
import numpy as np
from PIL import Image, ImageEnhance

def enhance_image(
    img: Image.Image,
    binarize: bool = False,
    contrast: float = 1.0,
    brightness: float = 1.0,
    watermark_threshold: int = 255,
    deskew: bool = False,
) -> Image.Image:
    """Enhance a single PIL Image using contrast, brightness, watermark threshold, binarization, and deskewing."""
    
    img = img.convert("RGB")
    
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
        # Apply binary threshold (pixels lighter than 185 become pure white, others black)
        binary = gray.point(lambda p: 255 if p > 185 else 0, '1')
        img = binary.convert("RGB")
        
    # 4. Deskewing (rotate to make text rows horizontal)
    if deskew:
        from ..pdf_service import deskew_image
        img = deskew_image(img)
        
    return img

from pathlib import Path

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
