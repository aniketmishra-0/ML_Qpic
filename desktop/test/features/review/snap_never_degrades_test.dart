// Snap-never-degrades property test — Task 12.3.
//
// ============================================================================
//  Property 9: "Snap never degrades"  (Validates: Requirements 9.3, 9.4)
// ============================================================================
//
// Requirement 9.3: IF the snap response returns the box coordinates unchanged,
//   THEN the Review_Canvas SHALL keep the user's drawn box without degrading it.
// Requirement 9.4: IF the `POST /api/snap` request returns an error response,
//   THEN the Review_Canvas SHALL keep the user's drawn box unchanged.
//
// The never-degrade contract is realized by `buildSnapInterceptor` in
// `lib/features/review/snap_interceptor.dart`: on a successful response it
// adopts the engine's tightened rect, but on ANY thrown error (HTTP 4xx/5xx,
// timeout, connection refused, malformed body) it returns the user's ORIGINAL
// drawn segment, and when the engine echoes the box back the adopted rect
// equals the drawn one. Either way the selection is never worsened.
//
// HOW THIS REALIZES PROPERTY 9 (property-based testing note):
// As the rest of this suite establishes (see `dto_roundtrip_test.dart`,
// `min_box_guard_test.dart`, `api_contract_test.dart`), this project has no
// QuickCheck/Hypothesis-style package in its pubspec, so a property is realized
// with a *seeded* pseudo-random generator (`math.Random(seed)`) that drives a
// large number of randomized-but-valid inputs and asserts the universal
// invariant on every one. The seeded loop is the generator; the assertions are
// the property. Fixed seeds keep any failure reproducible.
//
// The universal invariant under test, for ANY drawn box geometry AND ANY
// error-or-echo response from the engine:
//
//     out.page       == drawn.page
//     out.xStartPct  == drawn.xStartPct
//     out.xEndPct    == drawn.xEndPct
//     out.yStartPct  == drawn.yStartPct
//     out.yEndPct    == drawn.yEndPct
//
// i.e. the committed box equals the user's drawn box EXACTLY — snap degraded
// nothing.
//
// The engine is faked with a Dio `HttpClientAdapter` (no network) that can
// return any status + body, or throw a transport `DioException`. The input
// space is exercised intelligently:
//   * geometries — full-page, edge-hugging, tiny, and arbitrary normalized
//     boxes on a wide range of pages;
//   * degrade triggers — every common 4xx/5xx status with an engine
//     `{"detail": ...}` body, malformed/partial/empty/non-object 200 bodies,
//     and the four Dio transport error types;
//   * echo responses — the engine returning the drawn box verbatim.
// A deterministic sweep crosses every trigger variant with representative
// geometries so no variant is left unexercised, and a randomized seeded loop
// adds breadth across geometries and triggers together.
//
// This COMPLEMENTS the four fixed examples in `snap_interceptor_test.dart`
// (Req 9.1–9.4); it does not duplicate them — those pin the request shape and
// the happy-path tighten, while this asserts the degradation invariant holds
// universally.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/features/review/snap_interceptor.dart';
import 'package:qpic_desktop/models/crop.dart';

/// Randomized cases generated for the breadth loops. Each case is a full
/// interceptor round-trip against a fresh fake engine; kept modest so the suite
/// stays fast while covering the geometry × trigger space densely.
const int _iterations = 400;

void main() {
  group('Property 9 — snap never degrades (seeded property generator)', () {
    // ------------------------------------------------------------------ 9.4
    test('error responses keep the drawn box across every error status',
        () async {
      final seed = 'Property9-error-status'.hashCode & 0x7fffffff;
      // Deterministic sweep: every error status crossed with edge geometries.
      var n = 0;
      for (final int status in _errorStatuses) {
        for (final QuestionSegment drawn in _edgeGeometries) {
          final out = await _run(
            drawn,
            _ErrorBody(statusCode: status, body: _detailBody),
          );
          _expectKept(out, drawn,
              reason: 'status $status must not degrade the box');
          n++;
        }
      }
      expect(n, _errorStatuses.length * _edgeGeometries.length);

      // Breadth: random geometry × random error status.
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final drawn = _genDrawn(r);
        final status = _pick(r, _errorStatuses);
        final out =
            await _run(drawn, _ErrorBody(statusCode: status, body: _detailBody));
        _expectKept(out, drawn, reason: 'status $status, drawn=$drawn');
      }
    });

    // ------------------------------------------------------------------ 9.4
    test('malformed / partial / non-object 200 bodies keep the drawn box',
        () async {
      final seed = 'Property9-malformed-body'.hashCode & 0x7fffffff;
      // Deterministic sweep: every malformed body × edge geometries.
      var n = 0;
      for (final String body in _malformedBodies) {
        for (final QuestionSegment drawn in _edgeGeometries) {
          final out =
              await _run(drawn, _ErrorBody(statusCode: 200, body: body));
          _expectKept(out, drawn,
              reason: 'malformed 200 body ${jsonEncode(body)} must not degrade');
          n++;
        }
      }
      expect(n, _malformedBodies.length * _edgeGeometries.length);

      // Breadth: random geometry × random malformed body.
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final drawn = _genDrawn(r);
        final body = _pick(r, _malformedBodies);
        final out = await _run(drawn, _ErrorBody(statusCode: 200, body: body));
        _expectKept(out, drawn, reason: 'body=${jsonEncode(body)}, drawn=$drawn');
      }
    });

    // ------------------------------------------------------------------ 9.4
    test('transport failures (timeout / connection refused) keep the drawn box',
        () async {
      final seed = 'Property9-transport'.hashCode & 0x7fffffff;
      // Deterministic sweep: every transport error type × edge geometries.
      var n = 0;
      for (final DioExceptionType type in _transportErrors) {
        for (final QuestionSegment drawn in _edgeGeometries) {
          final out = await _run(drawn, _ThrowError(type));
          _expectKept(out, drawn,
              reason: '$type must not degrade the box');
          n++;
        }
      }
      expect(n, _transportErrors.length * _edgeGeometries.length);

      // Breadth: random geometry × random transport error.
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final drawn = _genDrawn(r);
        final type = _pick(r, _transportErrors);
        final out = await _run(drawn, _ThrowError(type));
        _expectKept(out, drawn, reason: '$type, drawn=$drawn');
      }
    });

    // ------------------------------------------------------------------ 9.3
    test('an unchanged (echoed-back) response keeps the drawn box', () async {
      final seed = 'Property9-echo'.hashCode & 0x7fffffff;
      // Deterministic sweep over edge geometries: echo the exact drawn rect.
      for (final QuestionSegment drawn in _edgeGeometries) {
        final out = await _run(drawn, _ErrorBody(statusCode: 200, body: _echo(drawn)));
        _expectKept(out, drawn, reason: 'echoed rect must be kept verbatim');
      }

      // Breadth: random geometry, engine echoes the box back unchanged.
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(seed + i);
        final drawn = _genDrawn(r);
        final out =
            await _run(drawn, _ErrorBody(statusCode: 200, body: _echo(drawn)));
        _expectKept(out, drawn, reason: 'echo drawn=$drawn');
      }
    });
  });
}

// ===========================================================================
//  Property assertion
// ===========================================================================

/// Asserts the interceptor output equals the user's drawn box EXACTLY — no
/// coordinate moved and the page is unchanged (Property 9).
void _expectKept(QuestionSegment out, QuestionSegment drawn,
    {required String reason}) {
  expect(out.page, drawn.page, reason: 'page changed — $reason');
  expect(out.xStartPct, drawn.xStartPct, reason: 'x_start changed — $reason');
  expect(out.xEndPct, drawn.xEndPct, reason: 'x_end changed — $reason');
  expect(out.yStartPct, drawn.yStartPct, reason: 'y_start changed — $reason');
  expect(out.yEndPct, drawn.yEndPct, reason: 'y_end changed — $reason');
}

// ===========================================================================
//  Drive the interceptor against a fake engine
// ===========================================================================

/// Builds an interceptor wired to a fake engine described by [scenario] and
/// runs the drawn box through it (Snap on, a real job id so a request is made).
Future<QuestionSegment> _run(QuestionSegment drawn, _Scenario scenario) {
  final dio = Dio()..httpClientAdapter = _SnapAdapter(scenario);
  final client = ApiClient(Uri.parse('http://127.0.0.1:54321'), dio: dio);
  final intercept = buildSnapInterceptor(
    apiClient: client,
    jobId: () => 'job-snap',
    enabled: () => true,
  );
  return intercept(drawn);
}

/// What the fake engine should do for a single call.
sealed class _Scenario {}

/// Return a fixed status + body (a non-2xx status makes Dio throw, exercising
/// Req 9.4; a 200 with a malformed body makes parsing throw downstream).
class _ErrorBody implements _Scenario {
  _ErrorBody({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

/// Throw a transport [DioException] before any response (timeout, connection
/// refused, cancellation) — the offline / engine-unreachable path of Req 9.4.
class _ThrowError implements _Scenario {
  _ThrowError(this.type);
  final DioExceptionType type;
}

/// A fake Dio adapter that realizes a [_Scenario]. It drains the request stream
/// so nothing leaks, then either throws or returns the canned response.
class _SnapAdapter implements HttpClientAdapter {
  _SnapAdapter(this.scenario);
  final _Scenario scenario;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    final s = scenario;
    if (s is _ThrowError) {
      throw DioException(
        requestOptions: options,
        type: s.type,
        error: 'simulated ${s.type}',
      );
    }
    s as _ErrorBody;
    return ResponseBody.fromString(
      s.body,
      s.statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// ===========================================================================
//  Trigger variants (degrade triggers)
// ===========================================================================

/// Engine error bodies are always `{"detail": ...}` (FastAPI HTTPException).
const String _detailBody = '{"detail": "could not snap"}';

/// Every common 4xx/5xx the engine (or its host) can return. Dio's default
/// `validateStatus` rejects all of these, so `snap()` throws an [ApiException].
const List<int> _errorStatuses = <int>[
  400, 401, 403, 404, 408, 409, 413, 415, 422, 429,
  500, 501, 502, 503, 504,
];

/// 200-status bodies that cannot be parsed into a valid [SnapResponse], so the
/// interceptor must fall back to the drawn box (Req 9.4). Covers empty,
/// non-JSON, truncated, empty-object, partial, wrong-typed, array, and `null`.
const List<String> _malformedBodies = <String>[
  '',
  'not json at all',
  '{',
  '{}',
  '{"x_start_pct": 1.0}',
  '{"x_start_pct": 1.0, "x_end_pct": 2.0}',
  '{"x_start_pct":"a","x_end_pct":"b","y_start_pct":"c","y_end_pct":"d"}',
  '[1, 2, 3]',
  'null',
  '"a string"',
];

/// Transport-level failures with no HTTP response at all.
const List<DioExceptionType> _transportErrors = <DioExceptionType>[
  DioExceptionType.connectionTimeout,
  DioExceptionType.sendTimeout,
  DioExceptionType.receiveTimeout,
  DioExceptionType.connectionError,
];

/// The engine "could not snap" echo: the response body is the drawn box's own
/// coordinates, returned verbatim (Req 9.3).
String _echo(QuestionSegment d) => jsonEncode(<String, dynamic>{
      'x_start_pct': d.xStartPct,
      'x_end_pct': d.xEndPct,
      'y_start_pct': d.yStartPct,
      'y_end_pct': d.yEndPct,
    });

// ===========================================================================
//  Geometry generators
// ===========================================================================

/// Representative edge geometries crossed deterministically with every trigger
/// so each variant is exercised on extreme boxes, not only random ones.
final List<QuestionSegment> _edgeGeometries = <QuestionSegment>[
  // Full page.
  const QuestionSegment(page: 1, xStartPct: 0, xEndPct: 100, yStartPct: 0, yEndPct: 100),
  // Tiny box hugging the origin.
  const QuestionSegment(page: 1, xStartPct: 0, xEndPct: 1.5, yStartPct: 0, yEndPct: 1.5),
  // Tiny box hugging the far corner.
  const QuestionSegment(page: 7, xStartPct: 98.5, xEndPct: 100, yStartPct: 98.5, yEndPct: 100),
  // A typical mid-page selection.
  const QuestionSegment(page: 3, xStartPct: 12.34, xEndPct: 67.89, yStartPct: 20.5, yEndPct: 80.25),
  // A high page number (multi-hundred-page PDF).
  const QuestionSegment(page: 250, xStartPct: 5, xEndPct: 95, yStartPct: 5, yEndPct: 95),
];

/// A randomized-but-valid drawn box: a real page number and a normalized box
/// (end >= start) in page-percentage space, with coordinates rounded to 2
/// decimals so the echo body round-trips through JSON exactly.
QuestionSegment _genDrawn(math.Random r) {
  final int page = 1 + r.nextInt(300);
  final (double x0, double x1) = _interval(r);
  final (double y0, double y1) = _interval(r);
  return QuestionSegment(
    page: page,
    xStartPct: x0,
    xEndPct: x1,
    yStartPct: y0,
    yEndPct: y1,
  );
}

/// A normalized [start, end] pair in [0, 100] (end >= start), 2-decimal rounded.
(double, double) _interval(math.Random r) {
  final double a = _round2(r.nextDouble() * 100);
  final double b = _round2(r.nextDouble() * 100);
  return a <= b ? (a, b) : (b, a);
}

double _round2(double v) => (v * 100).round() / 100;

T _pick<T>(math.Random r, List<T> xs) => xs[r.nextInt(xs.length)];
