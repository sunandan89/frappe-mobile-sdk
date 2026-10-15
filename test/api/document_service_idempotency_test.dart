import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/document_service.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

/// M8 — the guard's WIRING into [DocumentService], at the HTTP boundary.
///
/// `create_idempotency_test.dart` covers the guard in isolation with a fake
/// create function. That says nothing about whether `createDocument` routes
/// through it at all, nor about the two-call lookup shape — which is the part
/// that talks to a real server and so the part most likely to drift. These
/// drive the real `RestHelper` against a mock transport and assert on the
/// actual requests.
http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  /// Every request the service issued, in order.
  late List<http.BaseRequest> seen;

  setUp(() => seen = []);

  DocumentService svc(
    Future<http.Response> Function(http.Request req) handler,
  ) => DocumentService(
    RestHelper(
      'http://x',
      client: MockClient((req) async {
        seen.add(req);
        return handler(req);
      }),
    ),
  );

  List<http.BaseRequest> posts() =>
      seen.where((r) => r.method == 'POST').toList();
  List<http.BaseRequest> gets() =>
      seen.where((r) => r.method == 'GET').toList();

  test(
    'a payload with no mobile_uuid issues exactly one POST, no lookup',
    () async {
      final s = svc(
        (_) async => _json({
          'data': {'name': 'DOC-1'},
        }),
      );
      await s.createDocument('Item', {'item_code': 'X'});

      expect(posts(), hasLength(1));
      expect(
        gets(),
        isEmpty,
        reason: 'nothing to key on, so nothing to look up',
      );
    },
  );

  test('a blank mobile_uuid is stripped from the wire body', () async {
    // Empty is worse than absent: a unique index permits many NULLs but only
    // one empty string.
    final s = svc(
      (_) async => _json({
        'data': {'name': 'DOC-1'},
      }),
    );
    await s.createDocument('Item', {'item_code': 'X', 'mobile_uuid': '  '});

    final body = jsonDecode((posts().single as http.Request).body) as Map;
    expect(body.containsKey('mobile_uuid'), isFalse);
  });

  test(
    'a retry of the same uuid issues ONE POST and resolves via lookup',
    () async {
      final s = svc((req) async {
        if (req.method == 'POST')
          return _json({
            'data': {'name': 'DOC-1'},
          });
        if (req.url.path.contains('get_list')) {
          return _json({
            'message': [
              {'name': 'DOC-1'},
            ],
          });
        }
        return _json({
          'data': {'name': 'DOC-1', 'mobile_uuid': 'u-1'},
        });
      });

      await s.createDocument('Item', {'item_code': 'X', 'mobile_uuid': 'u-1'});
      final second = await s.createDocument('Item', {
        'item_code': 'X',
        'mobile_uuid': 'u-1',
      });

      expect(posts(), hasLength(1), reason: 'the retry must not write again');
      expect(second['name'], 'DOC-1');
    },
  );

  test('the lookup is two calls, in the documented shape', () async {
    // Pinned because this is the part that talks to a real server: a projection
    // list query to answer identity, then a full fetch so the returned document
    // is the same shape a real create returns.
    final s = svc((req) async {
      if (req.method == 'POST')
        return _json({
          'data': {'name': 'DOC-7'},
        });
      if (req.url.path.contains('get_list')) {
        return _json({
          'message': [
            {'name': 'DOC-7'},
          ],
        });
      }
      return _json({
        'data': {'name': 'DOC-7', 'qty': 3},
      });
    });

    await s.createDocument('Item', {'mobile_uuid': 'u-2'});
    await s.createDocument('Item', {'mobile_uuid': 'u-2'});

    final lookups = gets();
    expect(lookups, hasLength(2));

    final list = lookups.first.url;
    expect(list.path, contains('frappe.client.get_list'));
    expect(list.queryParameters['doctype'], 'Item');
    expect(list.queryParameters['filters'], contains('mobile_uuid'));
    expect(list.queryParameters['fields'], '["name"]');
    expect(list.queryParameters['limit_page_length'], '1');
    // Oldest first: where the unique index is absent two rows CAN share a uuid,
    // and a retry means the one an earlier attempt created.
    expect(list.queryParameters['order_by'], 'creation asc');

    expect(lookups.last.url.path, contains('/api/resource/Item/DOC-7'));
  });

  test('a lookup that finds nothing lets the create proceed', () async {
    final s = svc((req) async {
      if (req.method == 'POST')
        return _json({
          'data': {'name': 'DOC-2'},
        });
      return _json({'message': <dynamic>[]});
    });

    await s.createDocument('Item', {'mobile_uuid': 'u-3'});
    final second = await s.createDocument('Item', {'mobile_uuid': 'u-3'});

    expect(posts(), hasLength(2), reason: 'no existing doc, so write it');
    expect(second['name'], 'DOC-2');
  });

  group('M2 fast-fail and H1 client wiring', _m2AndH1Tests);

  test('resetCreateIdempotency clears the remembered history', () async {
    final s = svc((req) async {
      if (req.method == 'POST')
        return _json({
          'data': {'name': 'DOC-3'},
        });
      return _json({'message': <dynamic>[]});
    });

    await s.createDocument('Item', {'mobile_uuid': 'u-4'});
    s.resetCreateIdempotency();
    await s.createDocument('Item', {'mobile_uuid': 'u-4'});

    // With the key forgotten the second save is not treated as a retry, so it
    // does not pay for a lookup.
    expect(gets(), isEmpty);
    expect(posts(), hasLength(2));
  });
}

/// M2 — H6's fast-fail is the whole of that fix and is one keystroke from being
/// deleted by someone who reads the default budget as fine. H1 — the listener
/// must be reachable through `FrappeClient`, not only through a constructor
/// nothing in the SDK calls.
void _m2AndH1Tests() {
  test('M2 — a failing lookup is attempted ONCE, not retried', () async {
    // The lookup fires precisely when the network is down or the server is
    // unwell, which is when the default 30s x 3 budget is spent in full and
    // then swallowed. One attempt, then give up and let the create proceed.
    var lookupAttempts = 0;
    final s = DocumentService(
      RestHelper(
        'http://x',
        client: MockClient((req) async {
          if (req.method == 'POST') {
            return http.Response(
              jsonEncode({
                'data': {'name': 'DOC-1'},
              }),
              200,
            );
          }
          lookupAttempts++;
          return http.Response('upstream gone', 502);
        }),
      ),
    );

    await s.createDocument('Item', {'mobile_uuid': 'u-m2'});
    // Second save: the key is remembered, so the pre-flight lookup runs — and
    // fails. The create must still go through.
    await s.createDocument('Item', {'mobile_uuid': 'u-m2'});

    expect(
      lookupAttempts,
      1,
      reason: 'maxRetries: 0 — a failing lookup must not be retried 3 times',
    );
  });

  test(
    'H1 — FrappeClient threads onResolvedExisting to its DocumentService',
    () async {
      // Before this, the listener existed only on a `DocumentService` constructor
      // that nothing in the SDK called, so every real path ran with a null
      // listener and a resolved create was reported to no one.
      final reported = <String>[];
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          if (req.method == 'POST') {
            return http.Response(
              jsonEncode({
                'data': {'name': 'DOC-9'},
              }),
              200,
            );
          }
          if (req.url.path.contains('get_list')) {
            return http.Response(
              jsonEncode({
                'message': [
                  {'name': 'DOC-9'},
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'data': {'name': 'DOC-9', 'mobile_uuid': 'u-h1'},
            }),
            200,
          );
        }),
        onResolvedExisting: (doctype, uuid, existing, payload) =>
            reported.add('$doctype/$uuid'),
      );

      await client.document.createDocument('Item', {'mobile_uuid': 'u-h1'});
      await client.document.createDocument('Item', {'mobile_uuid': 'u-h1'});

      expect(reported, [
        'Item/u-h1',
      ], reason: 'the resolve must reach a listener supplied to FrappeClient');
    },
  );
}
