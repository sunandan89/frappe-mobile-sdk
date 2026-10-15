import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

/// A stand-in server that records every create it is asked to perform.
///
/// `creates` is the number the guard actually let through, which is the single
/// number every test here is really about: the field failure is one logical
/// submit becoming two or three documents.
class _FakeServer {
  _FakeServer();

  final List<Map<String, dynamic>> creates = [];
  final List<String> lookups = [];

  /// Documents the server holds, keyed by mobile_uuid.
  final Map<String, Map<String, dynamic>> stored = {};

  int _seq = 0;

  /// When set, the next create throws this instead of succeeding.
  Object? failNextWith;

  /// When true, a create that throws STILL lands server-side — the shape of a
  /// gateway timeout on a request that went on to commit.
  bool failButStillLands = false;

  Duration createDelay = Duration.zero;

  Future<Map<String, dynamic>> create(Map<String, dynamic> payload) async {
    if (createDelay > Duration.zero) await Future.delayed(createDelay);
    creates.add(Map<String, dynamic>.from(payload));
    final uuid = payload['mobile_uuid']?.toString();
    final failure = failNextWith;
    if (failure != null) {
      failNextWith = null;
      if (failButStillLands && uuid != null) {
        stored[uuid] = {'name': 'DOC-${++_seq}', 'mobile_uuid': uuid};
      }
      throw failure;
    }
    final doc = {'name': 'DOC-${++_seq}', 'mobile_uuid': uuid};
    if (uuid != null) stored[uuid] = doc;
    return doc;
  }

  Future<Map<String, dynamic>?> find(String doctype, String uuid) async {
    lookups.add(uuid);
    return stored[uuid];
  }
}

void main() {
  late _FakeServer server;
  late CreateIdempotencyGuard guard;

  setUp(() {
    server = _FakeServer();
    guard = CreateIdempotencyGuard(findByMobileUuid: server.find);
  });

  Future<Map<String, dynamic>> run(Map<String, dynamic> data) => guard.run(
    doctype: 'Procurement Transfer',
    data: data,
    create: server.create,
  );

  group('a payload with no usable uuid is untouched', () {
    test('no uuid at all: straight through, no lookup', () async {
      await run({'qty': 1});
      await run({'qty': 1});
      // Nothing to key on, so nothing can be deduped — and critically nothing
      // extra is spent trying. This is the pre-existing behaviour every caller
      // that has not adopted a uuid keeps.
      expect(server.creates, hasLength(2));
      expect(server.lookups, isEmpty);
    });

    test('a BLANK uuid is stripped, never sent', () async {
      // MariaDB allows many NULLs in a unique index but only one empty string,
      // so sending '' is worse than sending nothing.
      await run({'qty': 1, 'mobile_uuid': '   '});
      expect(server.creates.single.containsKey('mobile_uuid'), isFalse);
    });

    test('stripping does not mutate the caller\'s map', () async {
      final data = {'qty': 1, 'mobile_uuid': ''};
      await run(data);
      expect(data.containsKey('mobile_uuid'), isTrue);
    });
  });

  group('the retry cases that actually produced duplicates', () {
    test('a sequential retry of the same uuid creates ONE document', () async {
      // The field shape: submit appears to fail, operator submits again.
      // Observed gaps were 16 s to 5 minutes — a fresh request cycle each time,
      // so an in-flight guard alone would not catch this.
      const u = 'u-1';
      final first = await run({'qty': 1, 'mobile_uuid': u});
      final second = await run({'qty': 1, 'mobile_uuid': u});

      expect(server.creates, hasLength(1), reason: 'only one POST may land');
      expect(second['name'], first['name']);
      expect(server.lookups, [u], reason: 'the retry asks before writing');
    });

    test('a concurrent double-tap issues ONE POST', () async {
      const u = 'u-2';
      server.createDelay = const Duration(milliseconds: 50);
      final a = run({'qty': 1, 'mobile_uuid': u});
      final b = run({'qty': 1, 'mobile_uuid': u});
      final results = await Future.wait([a, b]);

      expect(server.creates, hasLength(1));
      expect(results[0]['name'], results[1]['name']);
      // The second tap never reached the network at all, so it never needed a
      // lookup either.
      expect(server.lookups, isEmpty);
    });

    test('a timeout that DID land resolves to the existing document', () async {
      // The classic generator: the write commits, the response is lost.
      const u = 'u-3';
      server.failNextWith = NetworkException('Connection closed');
      server.failButStillLands = true;

      final doc = await run({'qty': 1, 'mobile_uuid': u});

      expect(doc['name'], 'DOC-1');
      expect(server.creates, hasLength(1));
      expect(server.lookups, [
        u,
      ], reason: 'an ambiguous failure must be resolved, not reported');
    });

    test('a timeout that did NOT land still surfaces the error', () async {
      const u = 'u-4';
      server.failNextWith = NetworkException('Connection closed');
      server.failButStillLands = false;

      await expectLater(
        run({'qty': 1, 'mobile_uuid': u}),
        throwsA(isA<NetworkException>()),
      );
      // Losing the operator's work silently would be worse than the duplicate.
      expect(server.lookups, [u]);
    });
  });

  group('a definitive refusal is not treated as ambiguous', () {
    test('a 417 validation failure is rethrown without a lookup', () async {
      const u = 'u-5';
      server.failNextWith = ApiException('Mandatory field missing', 417);

      await expectLater(
        run({'qty': 1, 'mobile_uuid': u}),
        throwsA(isA<ApiException>()),
      );
      expect(
        server.lookups,
        isEmpty,
        reason: '4xx means nothing was written; a lookup would find nothing',
      );
    });

    test('after a refusal, a corrected resubmit still goes through', () async {
      // The operator fixes the form and submits again with the SAME uuid. That
      // must create the document — the first attempt left nothing behind.
      const u = 'u-6';
      server.failNextWith = ApiException('Mandatory field missing', 417);
      await expectLater(
        run({'qty': 1, 'mobile_uuid': u}),
        throwsA(isA<ApiException>()),
      );

      final doc = await run({'qty': 2, 'mobile_uuid': u});
      expect(doc['name'], isNotNull);
      expect(server.creates, hasLength(2));
    });
  });

  group('isAmbiguousCreateFailure', () {
    test('network and 5xx are ambiguous; 4xx is not', () {
      expect(isAmbiguousCreateFailure(NetworkException('timeout')), isTrue);
      expect(
        isAmbiguousCreateFailure(ApiException('bad gateway', 502)),
        isTrue,
      );
      expect(isAmbiguousCreateFailure(ApiException('boom', null)), isTrue);
      expect(
        isAmbiguousCreateFailure(ApiException('validation', 417)),
        isFalse,
      );
      expect(isAmbiguousCreateFailure(ApiException('forbidden', 403)), isFalse);
    });
  });

  group('the guard never blocks a legitimate save', () {
    test('a lookup that throws does not prevent the create', () async {
      // Being unable to CHECK is not evidence of a duplicate. Refusing to save
      // here would turn a transient read error into lost operator work.
      final failing = CreateIdempotencyGuard(
        findByMobileUuid: (_, _) async => throw NetworkException('offline'),
      );
      const u = 'u-7';
      await failing.run(
        doctype: 'X',
        data: {'mobile_uuid': u},
        create: server.create,
      );
      final doc = await failing.run(
        doctype: 'X',
        data: {'mobile_uuid': u},
        create: server.create,
      );
      expect(doc['name'], isNotNull);
    });

    test('two DIFFERENT documents are never conflated', () async {
      await run({'qty': 1, 'mobile_uuid': 'a'});
      await run({'qty': 2, 'mobile_uuid': 'b'});
      expect(server.creates, hasLength(2));
    });

    test(
      'the same uuid under a different doctype is a different key',
      () async {
        await guard.run(
          doctype: 'A',
          data: {'mobile_uuid': 'x'},
          create: server.create,
        );
        await guard.run(
          doctype: 'B',
          data: {'mobile_uuid': 'x'},
          create: server.create,
        );
        expect(server.creates, hasLength(2));
      },
    );
  });

  group('M5 — a resolved create is reported, not silent', _m5Tests);

  group('H2 — 409 means the document exists', _h2Tests);

  test(
    'reset forgets history, so a later save is not mistaken for a retry',
    () async {
      const u = 'u-8';
      await run({'mobile_uuid': u});
      guard.reset();
      server.stored.clear();
      await run({'mobile_uuid': u});
      expect(server.creates, hasLength(2));
      expect(server.lookups, isEmpty, reason: 'history was cleared');
    },
  );
}

/// M5 — a resolved create must be REPORTED, not silently passed off as a
/// create. These cover the reachable sequence the review names: a create that
/// lands but whose response is lost, a lookup that also fails, then a corrected
/// resubmit that silently resolves to the FIRST payload.
void _m5Tests() {
  late _FakeServer server;

  setUp(() => server = _FakeServer());

  test('a resolve after an ambiguous failure is reported', () async {
    final seen = <Map<String, dynamic>>[];
    final guard = CreateIdempotencyGuard(
      findByMobileUuid: server.find,
      onResolvedExisting: (dt, uuid, existing, payload) => seen.add({
        'dt': dt,
        'uuid': uuid,
        'existing': existing,
        'sent': payload,
      }),
    );
    server.failNextWith = NetworkException('closed');
    server.failButStillLands = true;

    await guard.run(
      doctype: 'PT',
      data: {'qty': 1, 'mobile_uuid': 'm-1'},
      create: server.create,
    );

    expect(seen, hasLength(1), reason: 'the caller must be told it resolved');
    expect(seen.single['uuid'], 'm-1');
  });

  test('the corrected-resubmit case reports, carrying BOTH payloads', () async {
    // The sequence that used to discard an operator's correction in silence.
    final seen = <Map<String, dynamic>>[];
    final guard = CreateIdempotencyGuard(
      findByMobileUuid: server.find,
      onResolvedExisting: (dt, uuid, existing, payload) =>
          seen.add({'existing': existing, 'sent': payload}),
    );
    await guard.run(
      doctype: 'PT',
      data: {'qty': 1, 'mobile_uuid': 'm-2'},
      create: server.create,
    );
    // Operator corrects the quantity and saves again.
    final out = await guard.run(
      doctype: 'PT',
      data: {'qty': 999, 'mobile_uuid': 'm-2'},
      create: server.create,
    );

    expect(server.creates, hasLength(1), reason: 'still only one document');
    expect(seen, hasLength(1));
    // The UI needs both to say anything useful: what is stored, and what the
    // operator just tried to save.
    expect((seen.single['sent'] as Map)['qty'], 999);
    expect(out['name'], 'DOC-1');
  });

  test('a real create reports nothing', () async {
    final seen = <String>[];
    final guard = CreateIdempotencyGuard(
      findByMobileUuid: server.find,
      onResolvedExisting: (_, uuid, _, _) => seen.add(uuid),
    );
    await guard.run(
      doctype: 'PT',
      data: {'mobile_uuid': 'm-3'},
      create: server.create,
    );
    expect(seen, isEmpty);
  });

  test(
    'a null listener keeps the old behaviour — adoption is not breaking',
    () async {
      final guard = CreateIdempotencyGuard(findByMobileUuid: server.find);
      await guard.run(
        doctype: 'PT',
        data: {'mobile_uuid': 'm-4'},
        create: server.create,
      );
      final second = await guard.run(
        doctype: 'PT',
        data: {'mobile_uuid': 'm-4'},
        create: server.create,
      );
      expect(server.creates, hasLength(1));
      expect(second['name'], 'DOC-1');
    },
  );
}

/// H2 — a 409 is the server saying the document ALREADY EXISTS, not "nothing
/// was written". Classifying it as a definitive refusal showed the operator a
/// failure for a record that saved, which they answer by retrying — the exact
/// failure this guard exists to end, arriving through the one response that
/// states the answer outright.
void _h2Tests() {
  late _FakeServer server;
  setUp(() => server = _FakeServer());

  test('409 is ambiguous; other 4xx are not', () {
    expect(
      isAmbiguousCreateFailure(ApiException('Duplicate entry', 409)),
      isTrue,
    );
    expect(isAmbiguousCreateFailure(ApiException('validation', 417)), isFalse);
    expect(isAmbiguousCreateFailure(ApiException('forbidden', 403)), isFalse);
    expect(isAmbiguousCreateFailure(ApiException('bad request', 400)), isFalse);
  });

  test('a 409 resolves to the document the earlier attempt created', () async {
    // Reachable with no network misbehaviour: the pre-flight cannot run on the
    // first attempt after an app restart, because the attempted set is
    // in-memory. The unique index then answers 409.
    final guard = CreateIdempotencyGuard(findByMobileUuid: server.find);
    server.stored['u-409'] = {'name': 'DOC-EARLIER', 'mobile_uuid': 'u-409'};
    server.failNextWith = ApiException('Duplicate entry', 409);

    final doc = await guard.run(
      doctype: 'PT',
      data: {'mobile_uuid': 'u-409'},
      create: server.create,
    );

    expect(doc['name'], 'DOC-EARLIER');
    expect(server.lookups, ['u-409']);
  });

  test(
    'a 409 whose document cannot be found still surfaces the error',
    () async {
      // Nothing to resolve to — losing the operator's work silently would be
      // worse than showing them the failure.
      final guard = CreateIdempotencyGuard(findByMobileUuid: server.find);
      server.failNextWith = ApiException('Duplicate entry', 409);

      await expectLater(
        guard.run(
          doctype: 'PT',
          data: {'mobile_uuid': 'u-410'},
          create: server.create,
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('NetworkException is judged as a network error even with a status', () {
    // L1 — `NetworkException extends FrappeException`, so the `is
    // NetworkException` arm must stay FIRST. Swapped, this would be judged by
    // the code and a 417-carrying network error would be called definitive.
    expect(isAmbiguousCreateFailure(NetworkException('timeout', 417)), isTrue);
  });
}
