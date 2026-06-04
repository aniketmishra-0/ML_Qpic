// ============================================================================
//  Property 8: Per-type numbering  (Validates: Requirements 8.13)
// ============================================================================
//
// An auto-numbered new box equals the max existing same-type number + 1,
// computed INDEPENDENTLY per type (questions vs solutions). This exercises the
// `nextAutoNumber` helper in `lib/features/review/box_logic.dart`, which is a
// verbatim port of the web canvas `nextAutoNumber` (static/index.html): it
// scans only same-type items, parses the first run of digits in each item's
// `qNum`, and returns `max + 1` as a string (or "1" when there is no same-type
// item).
//
// HOW THIS REALIZES PROPERTY 8 (property-based testing note):
// ----------------------------------------------------------------------------
// There is no mature QuickCheck/Hypothesis-style package in this project's
// pubspec (see the same note in test/dto_roundtrip_test.dart). As the task
// allows, the property is realized with a *seeded pseudo-random generator*
// (`math.Random(seed)`) that produces many randomized-but-valid item sets —
// mixing questions and solutions, varying numeric / prefixed / digit-less /
// multi-run `qNum` strings, and including empty sets. The invariant must hold
// for ALL generated inputs, so the seeded loop is the generator and the
// assertions are the property. Fixed seeds keep any failure reproducible.
//
// The expected value is computed by an INDEPENDENT oracle (`_expectedNext`)
// rather than by calling the implementation, so the test genuinely checks the
// "max same-type + 1, per type" semantics instead of tautologically agreeing
// with the code under test.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/features/review/box_logic.dart';
import 'package:qpic_desktop/models/crop.dart';

/// Number of randomized item-sets generated for the property. Large enough to
/// exercise the input space (mixed types, digit-less labels, multi-run labels,
/// empty sets) while keeping the suite fast.
const int _iterations = 500;

/// A throwaway single-page segment; `nextAutoNumber` ignores geometry entirely,
/// so any valid segment works.
const QuestionSegment _seg =
    QuestionSegment(page: 1, yStartPct: 10, yEndPct: 30);

AnalyzedItem _item(String qNum, {required bool isSolution}) => AnalyzedItem(
      qNum: qNum,
      isSolution: isSolution,
      segments: const <QuestionSegment>[_seg],
    );

/// Independent oracle: the highest first-digit-run among SAME-type items, + 1.
///
/// Mirrors the documented contract (Req 8.13) without reusing the production
/// loop: items of the other type are ignored, the first run of digits in each
/// same-type label is parsed, and with no parseable same-type number the result
/// is "1".
String _expectedNext(bool isSolution, List<AnalyzedItem> items) {
  var max = 0;
  for (final it in items) {
    if (it.isSolution != isSolution) continue;
    final m = RegExp(r'\d+').firstMatch(it.qNum);
    if (m != null) {
      final n = int.parse(m.group(0)!);
      if (n > max) max = n;
    }
  }
  return '${max + 1}';
}

// ---------------------------------------------------------------------------
//  Seeded generators
// ---------------------------------------------------------------------------

/// A varied `qNum` string. Covers: pure numbers, type-prefixed numbers,
/// numbers with a trailing suffix, multi-run labels (first run wins), and
/// digit-less labels (which contribute nothing to the max).
String _genQNum(math.Random r) {
  switch (r.nextInt(6)) {
    case 0:
      return '${r.nextInt(200)}'; // "0".."199"
    case 1:
      return 'Q${1 + r.nextInt(150)}';
    case 2:
      return 'S${1 + r.nextInt(150)}';
    case 3:
      return '${1 + r.nextInt(150)}${_pick(r, const ['a', 'b', '.1', ')'])}';
    case 4:
      // Multi-run: only the FIRST run should be parsed by the implementation.
      return '${1 + r.nextInt(150)}-${1 + r.nextInt(999)}';
    default:
      return _pick(r, const ['', 'abc', 'Q', 'S', '-', '??', 'extra']);
  }
}

T _pick<T>(math.Random r, List<T> xs) => xs[r.nextInt(xs.length)];

List<AnalyzedItem> _genItems(math.Random r) {
  final n = r.nextInt(9); // 0..8, includes the empty set
  return List<AnalyzedItem>.generate(
    n,
    (_) => _item(_genQNum(r), isSolution: r.nextBool()),
  );
}

void main() {
  group('Property 8 — per-type auto numbering (seeded property generator)', () {
    test('nextAutoNumber == max same-type number + 1, independent per type',
        () {
      final baseSeed = 'Property8:per-type-numbering'.hashCode & 0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final seed = baseSeed + i;
        final r = math.Random(seed);
        final items = _genItems(r);

        for (final isSolution in const [false, true]) {
          // 1) Equals the independent oracle (max same-type + 1).
          expect(
            nextAutoNumber(isSolution, items),
            equals(_expectedNext(isSolution, items)),
            reason: 'isSolution=$isSolution mismatch (iteration $i, '
                'seed $seed): ${items.map((e) => '${e.qNum}'
                '/${e.isSolution ? 'S' : 'Q'}').toList()}',
          );

          // 2) Per-type independence: numbering depends ONLY on same-type
          //    items. Restricting the list to the same type leaves the result
          //    unchanged, and the other type's items never shift it.
          final sameTypeOnly =
              items.where((it) => it.isSolution == isSolution).toList();
          expect(
            nextAutoNumber(isSolution, items),
            equals(nextAutoNumber(isSolution, sameTypeOnly)),
            reason: 'other-type items must not affect numbering '
                '(isSolution=$isSolution, iteration $i, seed $seed)',
          );
        }
      }
    });

    test('adding an other-type box never changes this type\'s next number', () {
      final baseSeed = 'Property8:cross-type-noninterference'.hashCode &
          0x7fffffff;
      for (var i = 0; i < _iterations; i++) {
        final r = math.Random(baseSeed + i);
        final items = _genItems(r);
        const isSolution = false; // numbering for QUESTIONS
        final before = nextAutoNumber(isSolution, items);

        // Inject an arbitrary SOLUTION with a large number; questions unchanged.
        final withSolution = [
          ...items,
          _item('S${1000 + r.nextInt(1000)}', isSolution: true),
        ];
        expect(
          nextAutoNumber(isSolution, withSolution),
          equals(before),
          reason: 'a new solution must not move the next question number '
              '(iteration $i, seed ${baseSeed + i})',
        );
      }
    });
  });

  // Concrete examples / edge cases that pin the documented behavior (Req 8.13).
  group('nextAutoNumber — unit examples', () {
    test('empty list yields "1" for both types', () {
      expect(nextAutoNumber(false, const <AnalyzedItem>[]), '1');
      expect(nextAutoNumber(true, const <AnalyzedItem>[]), '1');
    });

    test('numbers each type independently from a mixed list', () {
      final items = <AnalyzedItem>[
        _item('1', isSolution: false),
        _item('3', isSolution: false),
        _item('5', isSolution: true),
      ];
      expect(nextAutoNumber(false, items), '4'); // max question 3 -> 4
      expect(nextAutoNumber(true, items), '6'); // max solution 5 -> 6
    });

    test('other-type items are ignored when none of this type exist', () {
      final items = <AnalyzedItem>[
        _item('Q9', isSolution: false),
        _item('Q40', isSolution: false),
      ];
      // No solutions present -> next solution is "1" despite large questions.
      expect(nextAutoNumber(true, items), '1');
    });

    test('parses the leading digit run of a prefixed/suffixed label', () {
      final items = <AnalyzedItem>[
        _item('Q12', isSolution: false),
        _item('7a', isSolution: false),
      ];
      expect(nextAutoNumber(false, items), '13'); // max(12, 7) -> 13
    });

    test('first run of digits wins for multi-run labels', () {
      final items = <AnalyzedItem>[
        _item('12-99', isSolution: false),
      ];
      expect(nextAutoNumber(false, items), '13'); // first run 12 -> 13
    });

    test('digit-less labels contribute nothing (treated as 0)', () {
      final items = <AnalyzedItem>[
        _item('abc', isSolution: false),
        _item('', isSolution: false),
      ];
      expect(nextAutoNumber(false, items), '1');
    });
  });

  group('nextAutoNumber — bilingual mode manual crop pairing', () {
    test('empty list yields "1"', () {
      expect(nextAutoNumber(false, const <AnalyzedItem>[], bilingualModeActive: true), '1');
    });

    test('first box drawn gets "1", second box drawn gets "1" to pair, third box gets "2"', () {
      final items1 = const <AnalyzedItem>[];
      expect(nextAutoNumber(false, items1, bilingualModeActive: true), '1');

      final items2 = <AnalyzedItem>[
        _item('1', isSolution: false),
      ];
      expect(nextAutoNumber(false, items2, bilingualModeActive: true), '1'); // second box gets same number

      final items3 = <AnalyzedItem>[
        _item('1', isSolution: false),
        _item('1', isSolution: false),
      ];
      expect(nextAutoNumber(false, items3, bilingualModeActive: true), '2'); // third box increments

      final items4 = <AnalyzedItem>[
        _item('1', isSolution: false),
        _item('1', isSolution: false),
        _item('2', isSolution: false),
      ];
      expect(nextAutoNumber(false, items4, bilingualModeActive: true), '2'); // fourth box completes pair
    });

    test('ignores other type items when determining pairs', () {
      final items = <AnalyzedItem>[
        _item('1', isSolution: false), // Question 1
        _item('1', isSolution: true),  // Solution 1
      ];
      // Question 1 has only 1 item of its type (the solution is ignored), so next question is still 1
      expect(nextAutoNumber(false, items, bilingualModeActive: true), '1');
      // Solution 1 has only 1 item of its type (the question is ignored), so next solution is still 1
      expect(nextAutoNumber(true, items, bilingualModeActive: true), '1');
    });
  });
}
