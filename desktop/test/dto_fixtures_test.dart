// DTO fixture + structural tests — Task 4.2.
//
// Companion to dto_roundtrip_test.dart. Where the round-trip test exercises the
// invariant across many *generated* cases, this file pins it against *captured
// engine JSON fixtures* (test/fixtures/engine_fixtures.json) — JSON shaped
// exactly like what `app/models/schemas.py` (Pydantic model_dump) emits — and
// adds the structural evidence for Property 2 ("No Dart engine logic").
//
// Property 2 — Validates: Requirements 1.4, 1.5.
//
// What this proves:
//   * fromJson -> toJson reproduces the captured engine JSON byte-for-key,
//     preserving EXACT snake_case names (x_start_pct, questions_download_url,
//     answer_key_count, preview_url, …) and explicit nullability (null stays
//     null, present stays present).
//   * The DTOs invent NO computed/derived field and DROP nothing.
//   * Client-only UI flags (editing, manualOrder, hovered, zoom, pan, …) never
//     appear in any serialized payload.
//   * The model source under lib/models/ imports no library capable of engine
//     work (dart:ui, dart:io, image/pdf/ocr packages) — the DTOs are inert
//     data carriers, so Dart cannot compute crop/detection/OCR/PDF artifacts
//     (Req 1.4) and never rasterizes PDFs in Dart (Req 1.5).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';
import 'package:qpic_desktop/models/rename.dart';
import 'package:qpic_desktop/models/tools.dart';

typedef _JsonMap = Map<String, dynamic>;

/// Loads the captured engine fixtures (relative to the package root, which is
/// the working directory under `flutter test`).
_JsonMap _loadFixtures() {
  final file = File('test/fixtures/engine_fixtures.json');
  expect(file.existsSync(), isTrue,
      reason: 'engine fixtures must exist at ${file.path}');
  return jsonDecode(file.readAsStringSync()) as _JsonMap;
}

/// Asserts that `fromJson(fixture).toJson()` exactly reproduces the captured
/// engine JSON for [name] — same keys, same values, same nullability.
void _expectFixtureIdentity(
  _JsonMap fixtures,
  String name,
  _JsonMap Function(_JsonMap json) roundtrip,
) {
  expect(fixtures.containsKey(name), isTrue,
      reason: 'fixture "$name" must be present');
  final fixture = (fixtures[name] as Map).cast<String, dynamic>();
  final out = roundtrip(fixture);
  expect(out, equals(fixture),
      reason: '$name: toJson(fromJson(fixture)) must equal the captured '
          'engine JSON verbatim (field names + values + nullability).');
}

void main() {
  late _JsonMap fixtures;

  setUpAll(() {
    fixtures = _loadFixtures();
  });

  group('Property 2 — captured engine fixtures round-trip verbatim', () {
    test('QuestionSegment', () {
      _expectFixtureIdentity(fixtures, 'QuestionSegment',
          (j) => QuestionSegment.fromJson(j).toJson());
    });
    test('CropResponse', () {
      _expectFixtureIdentity(
          fixtures, 'CropResponse', (j) => CropResponse.fromJson(j).toJson());
    });
    test('PageInfo', () {
      _expectFixtureIdentity(
          fixtures, 'PageInfo', (j) => PageInfo.fromJson(j).toJson());
    });
    test('AnalyzedItem', () {
      _expectFixtureIdentity(
          fixtures, 'AnalyzedItem', (j) => AnalyzedItem.fromJson(j).toJson());
    });
    test('ReviewNote', () {
      _expectFixtureIdentity(
          fixtures, 'ReviewNote', (j) => ReviewNote.fromJson(j).toJson());
    });
    test('AnalyzeResponse', () {
      _expectFixtureIdentity(fixtures, 'AnalyzeResponse',
          (j) => AnalyzeResponse.fromJson(j).toJson());
    });
    test('SnapRequest', () {
      _expectFixtureIdentity(
          fixtures, 'SnapRequest', (j) => SnapRequest.fromJson(j).toJson());
    });
    test('SnapResponse', () {
      _expectFixtureIdentity(
          fixtures, 'SnapResponse', (j) => SnapResponse.fromJson(j).toJson());
    });
    test('FinalizeItem', () {
      _expectFixtureIdentity(
          fixtures, 'FinalizeItem', (j) => FinalizeItem.fromJson(j).toJson());
    });
    test('FinalizeRequest', () {
      _expectFixtureIdentity(fixtures, 'FinalizeRequest',
          (j) => FinalizeRequest.fromJson(j).toJson());
    });
    test('HealthResponse', () {
      _expectFixtureIdentity(fixtures, 'HealthResponse',
          (j) => HealthResponse.fromJson(j).toJson());
    });
    test('RenamePlanItem', () {
      _expectFixtureIdentity(fixtures, 'RenamePlanItem',
          (j) => RenamePlanItem.fromJson(j).toJson());
    });
    test('RenamePreviewResponse', () {
      _expectFixtureIdentity(fixtures, 'RenamePreviewResponse',
          (j) => RenamePreviewResponse.fromJson(j).toJson());
    });
    test('PdfImageItem', () {
      _expectFixtureIdentity(
          fixtures, 'PdfImageItem', (j) => PdfImageItem.fromJson(j).toJson());
    });
    test('PdfToImagesResponse', () {
      _expectFixtureIdentity(fixtures, 'PdfToImagesResponse',
          (j) => PdfToImagesResponse.fromJson(j).toJson());
    });
    test('RenameSessionResponse', () {
      _expectFixtureIdentity(fixtures, 'RenameSessionResponse',
          (j) => RenameSessionResponse.fromJson(j).toJson());
    });
    test('RenameUploadResponse', () {
      _expectFixtureIdentity(fixtures, 'RenameUploadResponse',
          (j) => RenameUploadResponse.fromJson(j).toJson());
    });
    test('RenameFinalizeResponse', () {
      _expectFixtureIdentity(fixtures, 'RenameFinalizeResponse',
          (j) => RenameFinalizeResponse.fromJson(j).toJson());
    });
    test('CompressResponse', () {
      _expectFixtureIdentity(fixtures, 'CompressResponse',
          (j) => CompressResponse.fromJson(j).toJson());
    });
    test('EditableSpanModel', () {
      _expectFixtureIdentity(fixtures, 'EditableSpanModel',
          (j) => EditableSpanModel.fromJson(j).toJson());
    });
    test('EditPageModel', () {
      _expectFixtureIdentity(
          fixtures, 'EditPageModel', (j) => EditPageModel.fromJson(j).toJson());
    });
    test('EditExtractResponse', () {
      _expectFixtureIdentity(fixtures, 'EditExtractResponse',
          (j) => EditExtractResponse.fromJson(j).toJson());
    });
    test('PreflightResponse', () {
      _expectFixtureIdentity(fixtures, 'PreflightResponse',
          (j) => PreflightResponse.fromJson(j).toJson());
    });
  });

  group('Property 2 — exact snake_case contract keys are preserved', () {
    test('crop/analyze/snap segment keys use page-percentage snake_case', () {
      final seg = QuestionSegment.fromJson(
              (fixtures['QuestionSegment'] as Map).cast<String, dynamic>())
          .toJson();
      expect(seg.keys,
          containsAll(['x_start_pct', 'x_end_pct', 'y_start_pct', 'y_end_pct']));
    });

    test('CropResponse keeps questions_download_url nullability', () {
      // Fixture has questions present + solutions null.
      final out = CropResponse.fromJson(
              (fixtures['CropResponse'] as Map).cast<String, dynamic>())
          .toJson();
      expect(out.containsKey('questions_download_url'), isTrue);
      expect(out.containsKey('solutions_download_url'), isTrue);
      expect(out['questions_download_url'], isNotNull);
      expect(out['solutions_download_url'], isNull);
    });

    test('AnalyzeResponse keeps answer_key_count and preview_url', () {
      final out = AnalyzeResponse.fromJson(
              (fixtures['AnalyzeResponse'] as Map).cast<String, dynamic>())
          .toJson();
      expect(out.containsKey('answer_key_count'), isTrue);
      final pages = out['pages'] as List;
      expect((pages.first as Map).containsKey('preview_url'), isTrue);
    });

    test('null inner fields stay null (ReviewNote.q_num)', () {
      final note = ReviewNote.fromJson(<String, dynamic>{
        'kind': 'low_confidence',
        'message': 'x',
        'q_num': null,
        'page': null,
        'is_solution': false,
      }).toJson();
      expect(note.containsKey('q_num'), isTrue);
      expect(note['q_num'], isNull);
      expect(note.containsKey('page'), isTrue);
      expect(note['page'], isNull);
    });
  });

  group('Property 2 — no client-only UI flags ever serialize', () {
    // Every DTO toJson() must omit client-only review/UI state. We round-trip
    // each captured fixture and assert none of these keys appear.
    const forbidden = <String>{
      'editing',
      'manualOrder',
      'manual_order',
      'hovered',
      'hoveredIndex',
      'zoom',
      'pan',
      'panOffset',
      'currentPageIndex',
      'editingIndex',
    };

    final roundtrips = <String, _JsonMap Function(_JsonMap)>{
      'QuestionSegment': (j) => QuestionSegment.fromJson(j).toJson(),
      'CropResponse': (j) => CropResponse.fromJson(j).toJson(),
      'PageInfo': (j) => PageInfo.fromJson(j).toJson(),
      'AnalyzedItem': (j) => AnalyzedItem.fromJson(j).toJson(),
      'ReviewNote': (j) => ReviewNote.fromJson(j).toJson(),
      'AnalyzeResponse': (j) => AnalyzeResponse.fromJson(j).toJson(),
      'SnapRequest': (j) => SnapRequest.fromJson(j).toJson(),
      'SnapResponse': (j) => SnapResponse.fromJson(j).toJson(),
      'FinalizeItem': (j) => FinalizeItem.fromJson(j).toJson(),
      'FinalizeRequest': (j) => FinalizeRequest.fromJson(j).toJson(),
      'CompressResponse': (j) => CompressResponse.fromJson(j).toJson(),
      'EditExtractResponse': (j) => EditExtractResponse.fromJson(j).toJson(),
      'PreflightResponse': (j) => PreflightResponse.fromJson(j).toJson(),
    };

    for (final entry in roundtrips.entries) {
      test('${entry.key} has no client-only keys (recursive)', () {
        final fixture =
            (fixtures[entry.key] as Map).cast<String, dynamic>();
        final out = entry.value(fixture);
        final keys = _allKeysRecursive(out);
        for (final f in forbidden) {
          expect(keys.contains(f), isFalse,
              reason: '${entry.key}: client-only key "$f" must never serialize');
        }
      });
    }
  });

  group('Property 2 — DTO source is inert (no engine-capable imports)', () {
    // The models cannot compute crop/detection/OCR/PDF artifacts or rasterize
    // PDFs if they import no library able to do so. Only sibling model imports
    // ('crop.dart', etc.) are allowed.
    const modelFiles = <String>[
      'lib/models/crop.dart',
      'lib/models/analyze.dart',
      'lib/models/rename.dart',
      'lib/models/tools.dart',
    ];

    // Libraries that would enable engine work / IO / rendering.
    const bannedImportFragments = <String>[
      'dart:ui',
      'dart:io',
      'dart:ffi',
      'dart:isolate',
      'package:flutter/',
      'package:image',
      'package:pdf',
      'package:printing',
      'package:pdfx',
      'package:tesseract',
      'package:opencv',
      'package:dio', // network belongs to ApiClient, not DTOs
      'package:http',
    ];

    for (final path in modelFiles) {
      test('$path imports nothing engine-capable', () {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path must exist');
        final imports = file
            .readAsLinesSync()
            .map((l) => l.trim())
            .where((l) => l.startsWith('import ') || l.startsWith('export '))
            .toList();

        for (final imp in imports) {
          for (final banned in bannedImportFragments) {
            expect(imp.contains(banned), isFalse,
                reason: '$path must not import "$banned" (found: $imp). '
                    'DTOs are transport-only data carriers with no engine '
                    'logic and no PDF rasterization in Dart.');
          }
        }
      });
    }
  });
}

/// Collects every key appearing anywhere in a decoded JSON structure.
Set<String> _allKeysRecursive(dynamic node) {
  final keys = <String>{};
  if (node is Map) {
    for (final e in node.entries) {
      keys.add(e.key.toString());
      keys.addAll(_allKeysRecursive(e.value));
    }
  } else if (node is List) {
    for (final item in node) {
      keys.addAll(_allKeysRecursive(item));
    }
  }
  return keys;
}
