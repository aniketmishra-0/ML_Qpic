// Snap-to-content seam for the Review Canvas (Req 9).
//
// This is the implementation that plugs into the [SegmentInterceptor] seam the
// canvas controller (task 11.5) and [ReviewController] (task 12.1) expose. On
// box-end, when the Snap toggle is on, the controller hands the freshly drawn
// segment to this interceptor BEFORE it is committed. The interceptor asks the
// engine to tighten the box to its content via `POST /api/snap` and returns the
// tightened rect so the canvas replaces the drawn box with it (Req 9.1, 9.2).
//
// NEVER-DEGRADE CONTRACT (Req 9.3, 9.4): manual selection must always work,
// even offline. On ANY failure — a transport/HTTP error, a malformed response,
// or the engine echoing the box back because it could not snap — this returns
// the user's ORIGINAL drawn segment unchanged. The engine itself echoes the box
// back when it can't tighten (see `app/services/snap_service.py`), so an
// "unchanged" response naturally reproduces the drawn box; the error path
// guarantees the same. This mirrors the web `snapSegment` try/fallback exactly.
//
// Engine boundary (Req 1.4, 1.5): there is ZERO engine logic in Dart here. This
// only shapes a [SnapRequest] from the drawn box and copies the [SnapResponse]
// coordinates back onto a [QuestionSegment]. All of the actual content analysis
// (rendering the box, finding the ink bounds, adding the margin) happens in the
// Python engine and is reached over localhost HTTP.

import '../../core/api_client.dart';
import '../../models/crop.dart';
import 'review_canvas_controller.dart' show SegmentInterceptor;

/// Builds a [SegmentInterceptor] that snaps a drawn box to its content via
/// `POST /api/snap`, falling back to the drawn box on error/unchanged.
///
/// The interceptor reads [enabled] and [jobId] LAZILY on every call so the
/// owning controller can flip the Snap toggle or load a new session without
/// re-wiring the seam:
///   * [enabled] — when it returns false the box is committed verbatim and no
///     request is made (the Snap toggle is off).
///   * [jobId] — the engine crop/analyze job id; when empty (no session loaded)
///     the box is committed verbatim, since snap has nothing to render against.
///
/// On a successful response the returned [QuestionSegment] keeps the drawn box's
/// [QuestionSegment.page] and adopts the engine's tightened
/// `x_start_pct/x_end_pct/y_start_pct/y_end_pct` (Req 9.2). On any thrown error
/// (including [ApiException]) the original [drawn] segment is returned (Req 9.4).
SegmentInterceptor buildSnapInterceptor({
  required ApiClient apiClient,
  required String Function() jobId,
  required bool Function() enabled,
}) {
  return (QuestionSegment drawn) async {
    if (!enabled()) return drawn;

    final String job = jobId();
    if (job.isEmpty) return drawn;

    try {
      final SnapResponse res = await apiClient.snap(
        SnapRequest(
          jobId: job,
          page: drawn.page,
          xStartPct: drawn.xStartPct,
          xEndPct: drawn.xEndPct,
          yStartPct: drawn.yStartPct,
          yEndPct: drawn.yEndPct,
        ),
      );
      // Replace the box with the tightened rect (Req 9.2). The page never
      // changes — snap only tightens within the page the box was drawn on. When
      // the engine echoes the box back (could-not-snap), these coordinates equal
      // the drawn ones, so the box is kept as-is (Req 9.3) — never degraded.
      return QuestionSegment(
        page: drawn.page,
        xStartPct: res.xStartPct,
        xEndPct: res.xEndPct,
        yStartPct: res.yStartPct,
        yEndPct: res.yEndPct,
      );
    } catch (_) {
      // Any error (HTTP 4xx/5xx, timeout, connection refused, malformed body):
      // keep the user's drawn box unchanged so selection never degrades
      // (Req 9.4) and manual cropping always works, even fully offline.
      return drawn;
    }
  };
}
