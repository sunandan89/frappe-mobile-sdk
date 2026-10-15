import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

/// The meta watermark must span every source that can change a doctype's
/// effective schema.
///
/// Using `DocType.modified` alone is why sync could report "up to date" while
/// serving a stale schema: Custom Fields and Property Setters live in their own
/// tables, carry their own `modified`, and neither touches the parent row. The
/// visible symptom is a picker that dies with
/// `Field not permitted in query: <fieldname>` because the client still lists a
/// field the server deleted.
void main() {
  /// Serves `modified` per doctype, and records which sources were asked for.
  ({DoctypeService svc, List<String> asked}) serviceWith({
    String? docType,
    String? customField,
    String? propertySetter,
    Set<String> failing = const {},
  }) {
    final asked = <String>[];
    final client = MockClient((req) async {
      final qp = req.url.queryParameters;
      final target = qp['doctype'] ?? '';
      asked.add(target);
      if (failing.contains(target)) {
        return http.Response('{"exc_type":"PermissionError"}', 403);
      }
      if (target == 'DocType') {
        return http.Response(
          jsonEncode({
            'message': docType == null ? {} : {'modified': docType},
          }),
          200,
        );
      }
      final value = target == 'Custom Field' ? customField : propertySetter;
      return http.Response(
        jsonEncode({
          'message': value == null
              ? <dynamic>[]
              : [
                  {'modified': value},
                ],
        }),
        200,
      );
    });
    return (
      svc: DoctypeService(RestHelper('http://x', client: client)),
      asked: asked,
    );
  }

  test('all three sources are consulted', () async {
    final s = serviceWith(
      docType: '2026-01-01 00:00:00.000000',
      customField: '2026-01-01 00:00:00.000000',
      propertySetter: '2026-01-01 00:00:00.000000',
    );
    await s.svc.getDocTypeWatermark('Crop');
    expect(s.asked.toSet(), {
      'DocType',
      'Custom Field',
      'Property Setter',
    }, reason: 'a watermark that skips a source cannot detect that source');
  });

  test('a NEWER Custom Field wins — the stale-meta bug', () async {
    // The measured shape: the DocType row untouched for months while a Custom
    // Field moved. Before this, the client reported "up to date" here.
    final s = serviceWith(
      docType: '2026-03-12 13:02:17.000000',
      customField: '2026-08-20 14:01:44.000000',
      propertySetter: null,
    );
    expect(
      await s.svc.getDocTypeWatermark('Fumigation Entry'),
      '2026-08-20 14:01:44.000000',
    );
  });

  test('a NEWER Property Setter wins — Customize Form changes', () async {
    // `reqd`, `hidden`, `options` and `read_only` all change through a
    // Property Setter, and none of them touch DocType.modified.
    final s = serviceWith(
      docType: '2026-09-12 11:07:00.000000',
      customField: null,
      propertySetter: '2026-09-17 02:21:21.000000',
    );
    expect(
      await s.svc.getDocTypeWatermark('Procurement'),
      '2026-09-17 02:21:21.000000',
    );
  });

  test('the DocType stamp still wins when it is the newest', () async {
    final s = serviceWith(
      docType: '2026-09-20 10:00:00.000000',
      customField: '2026-08-20 14:01:44.000000',
      propertySetter: '2026-09-01 09:00:00.000000',
    );
    expect(
      await s.svc.getDocTypeWatermark('Crop'),
      '2026-09-20 10:00:00.000000',
    );
  });

  test('comparison is chronological, not shortest-string', () async {
    // Fixed-width `YYYY-MM-DD HH:MM:SS.ffffff` orders lexically the same way it
    // orders chronologically, which is the property this relies on.
    final s = serviceWith(
      docType: '2026-09-09 23:59:59.999999',
      customField: '2026-09-10 00:00:00.000000',
      propertySetter: null,
    );
    expect(await s.svc.getDocTypeWatermark('X'), '2026-09-10 00:00:00.000000');
  });

  test(
    'a doctype with no Custom Fields or Property Setters still works',
    () async {
      final s = serviceWith(
        docType: '2026-05-05 05:05:05.000000',
        customField: null,
        propertySetter: null,
      );
      expect(
        await s.svc.getDocTypeWatermark('Plain'),
        '2026-05-05 05:05:05.000000',
      );
    },
  );

  group('degrades rather than fails', () {
    test('a forbidden Custom Field read still yields the DocType stamp', () async {
      // A site that restricts read on Custom Field lands here. A partial max is
      // never worse than the previous behaviour, which used one source anyway.
      final s = serviceWith(
        docType: '2026-05-05 05:05:05.000000',
        customField: '2026-09-01 00:00:00.000000',
        propertySetter: null,
        failing: {'Custom Field'},
      );
      expect(
        await s.svc.getDocTypeWatermark('Plain'),
        '2026-05-05 05:05:05.000000',
      );
    });

    test('a failed DocType read still yields the newest child stamp', () async {
      final s = serviceWith(
        docType: '2026-01-01 00:00:00.000000',
        customField: '2026-09-01 00:00:00.000000',
        propertySetter: null,
        failing: {'DocType'},
      );
      expect(
        await s.svc.getDocTypeWatermark('Plain'),
        '2026-09-01 00:00:00.000000',
      );
    });

    test('everything failing yields null, not a wrong answer', () async {
      final s = serviceWith(
        docType: '2026-01-01 00:00:00.000000',
        customField: '2026-09-01 00:00:00.000000',
        propertySetter: '2026-09-02 00:00:00.000000',
        failing: {'DocType', 'Custom Field', 'Property Setter'},
      );
      expect(await s.svc.getDocTypeWatermark('Plain'), isNull);
    });
  });
}
