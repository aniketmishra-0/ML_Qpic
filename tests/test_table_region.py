"""Regression tests for data-table regions in question crops.

Exam questions routinely embed a grid — a truth table, a "Column-I / Column-II"
matching table, a reagent list, a value matrix, a chemical-reaction grid. These
are grids *of text*, so the generic vector-figure path rejects them (its
``_encloses_body_text`` guard exists to drop phantom rule-merges, and a real
table trips it). Without a dedicated path the owning question's crop is clipped
to the surrounding prose and the table is sliced.

These tests pin the fix: a bordered table is detected, emitted as a figure
region, and folds into the owning question so the crop grows to contain the
whole grid.
"""

from __future__ import annotations

import fitz

from app.services.detector.figure_detector import extract_figures_for_page
from app.services.detector.table_detector import detect_tables
from app.services.detector.text_detector import TextDetector

W, H = 595, 842


def _build_table_pdf() -> bytes:
    """A question whose body holds a bordered 4x3 matching table that sits
    below the last prose line; the table's bottom border is the lowest mark."""

    doc = fitz.open()
    p = doc.new_page(width=W, height=H)
    p.insert_text((60, 90), "Q5. Match the items in Column-I with Column-II:", fontsize=12)

    # Bordered grid: 4 rows x 3 cols, drawn as ruling lines (lines strategy).
    x0, y0 = 70, 130
    col_w, row_h = 150, 34
    n_rows, n_cols = 4, 3
    xs = [x0 + j * col_w for j in range(n_cols + 1)]
    ys = [y0 + i * row_h for i in range(n_rows + 1)]
    for y in ys:
        p.draw_line((xs[0], y), (xs[-1], y), width=0.8)
    for x in xs:
        p.draw_line((x, ys[0]), (x, ys[-1]), width=0.8)
    for i in range(n_rows):
        for j in range(n_cols):
            p.insert_text((xs[j] + 6, ys[i] + 22), f"r{i}c{j}", fontsize=9)

    table_bottom = ys[-1]
    # An options line BELOW the table so the question clearly continues past it.
    p.insert_text((60, table_bottom + 40), "(1) A-p  (2) A-q  (3) A-r  (4) A-s", fontsize=11)
    data = doc.tobytes()
    doc.close()
    return data, table_bottom


def test_detect_tables_finds_the_grid() -> None:
    pdf, table_bottom = _build_table_pdf()
    with fitz.open(stream=pdf, filetype="pdf") as doc:
        tables = detect_tables(doc.load_page(0))
    assert len(tables) >= 1, tables
    t = tables[0]
    assert t.y0 < 140 and t.y1 >= table_bottom - 2
    assert t.x0 < 80 and t.x1 > 500


def test_table_is_emitted_as_a_figure_region() -> None:
    pdf, table_bottom = _build_table_pdf()
    with fitz.open(stream=pdf, filetype="pdf") as doc:
        figs = extract_figures_for_page(doc.load_page(0), 1)
    assert any(
        f.y_top < 140 and f.y_bottom >= table_bottom - 2 and f.x_left < 80 and f.x_right > 500
        for f in figs
    ), figs


def test_question_crop_grows_to_contain_the_table() -> None:
    """The Q5 crop must reach below the table to its options line, not stop at
    the stem (the reported table-cut-off bug)."""

    pdf, table_bottom = _build_table_pdf()
    questions = TextDetector().detect(pdf, padding_px=10)
    q5 = next((q for q in questions if q.q_num == "5"), None)
    assert q5 is not None
    seg = next((s for s in q5.segments if s.page == 1), None)
    assert seg is not None
    # The crop must reach at least the table's bottom border.
    assert seg.y_end_pct >= (table_bottom / H) * 100.0 - 0.5, seg.y_end_pct


def _build_chem_structure_pdf() -> bytes:
    """A question whose body holds a chemical structure / display formula: a
    dense compact cluster of many short bond/arrow strokes mixed with a few atom
    labels, sitting between the stem and the options. This is the case the plain
    text-overlap guard wrongly rejects (it contains text) and which the
    stroke-density override must rescue so the crop grows to include it."""

    doc = fitz.open()
    p = doc.new_page(width=W, height=H)
    p.insert_text((60, 90), "Q6. Identify the major product of the reaction below:", fontsize=12)

    # A dense lattice of short, mutually-disconnected strokes (bonds / arrows /
    # bracket marks). Drawing them as separate non-touching segments keeps each
    # one a distinct drawing object, mimicking a real structure's many strokes.
    x0, y0 = 150.0, 150.0
    struct_bottom = y0
    for row in range(6):
        for col in range(6):
            sx = x0 + col * 16
            sy = y0 + row * 14
            # alternate stroke orientation so it reads as a 2-D lattice
            if (row + col) % 2 == 0:
                p.draw_line((sx, sy), (sx + 10, sy), width=1.0)  # short horizontal bond
            else:
                p.draw_line((sx, sy), (sx, sy + 9), width=1.0)  # short vertical bond
            struct_bottom = max(struct_bottom, sy + 9)
    # A few atom / reagent labels inside the structure's bounding box.
    p.insert_text((x0 + 4, y0 + 20), "OH", fontsize=8)
    p.insert_text((x0 + 50, y0 + 50), "Cl", fontsize=8)
    p.insert_text((x0 + 30, y0 + 70), "C", fontsize=8)

    p.insert_text((60, struct_bottom + 40), "(1) P  (2) Q  (3) R  (4) S", fontsize=11)
    data = doc.tobytes()
    doc.close()
    return data, struct_bottom


def test_chemical_structure_is_emitted_as_a_figure_region() -> None:
    pdf, struct_bottom = _build_chem_structure_pdf()
    with fitz.open(stream=pdf, filetype="pdf") as doc:
        figs = extract_figures_for_page(doc.load_page(0), 1)
    # A region covering the structure must survive the text-overlap guard.
    assert any(
        f.y_top < 165 and f.y_bottom >= struct_bottom - 6 and f.x_left < 160 and f.x_right >= 239
        for f in figs
    ), figs


def test_chemical_structure_crop_grows_to_contain_it() -> None:
    pdf, struct_bottom = _build_chem_structure_pdf()
    questions = TextDetector().detect(pdf, padding_px=10)
    q6 = next((q for q in questions if q.q_num == "6"), None)
    assert q6 is not None
    seg = next((s for s in q6.segments if s.page == 1), None)
    assert seg is not None
    assert seg.y_end_pct >= (struct_bottom / H) * 100.0 - 1.0, seg.y_end_pct


def _build_underlined_prose_pdf() -> bytes:
    """A solution page of prose where many bold labels are underlined. The
    underline strokes must NOT be mistaken for a chemical structure / formula
    and rescued as a figure (they ride on text, so they're decoration)."""

    doc = fitz.open()
    p = doc.new_page(width=W, height=H)
    p.insert_text((60, 90), "Q7 Text Solution:", fontsize=12)
    y = 120
    for i in range(1, 12):
        label = f"Statement {i} is correct:"
        p.insert_text((60, y), label, fontsize=11, fontname="helvetica-bold")
        lw = fitz.get_text_length(label, fontname="helvetica-bold", fontsize=11)
        # Underline stroke riding on the baseline.
        p.draw_rect(fitz.Rect(60, y + 1.6, 60 + lw, y + 2.3), color=None, fill=(0, 0, 0))
        p.insert_text((60, y + 16), "The cited article establishes this clearly.", fontsize=10)
        y += 40
    data = doc.tobytes()
    doc.close()
    return data


def test_underlined_prose_is_not_rescued_as_figure() -> None:
    pdf = _build_underlined_prose_pdf()
    with fitz.open(stream=pdf, filetype="pdf") as doc:
        figs = extract_figures_for_page(doc.load_page(0), 1)
    # No wide figure should span the prose block (underlines aren't a structure).
    wide = [f for f in figs if (f.x_right - f.x_left) > 0.5 * W and (f.y_bottom - f.y_top) > 0.2 * H]
    assert wide == [], wide
