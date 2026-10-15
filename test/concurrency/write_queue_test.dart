import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/write_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  });
  tearDown(() async => db.close());

  test('serializes writes', () async {
    final q = WriteQueue(db: db, doctype: 'X', batchRows: 10);
    final futs = <Future<void>>[];
    for (var i = 0; i < 5; i++) {
      futs.add(
        q.submit<void>((txn) async {
          await txn.insert('t', {'id': i, 'v': '$i'});
        }),
      );
    }
    await Future.wait(futs);
    final rows = await db.query('t');
    expect(rows.length, 5);
  });

  test('propagates errors and unblocks subsequent writes', () async {
    final q = WriteQueue(db: db, doctype: 'X');
    await expectLater(
      q.submit<void>((txn) async => throw StateError('x')),
      throwsStateError,
    );
    await q.submit<void>((txn) async {
      await txn.insert('t', {'id': 99, 'v': 'a'});
    });
    final rows = await db.query('t');
    expect(rows.length, 1);
  });

  test('batches consecutive submits — 20 inserts all commit', () async {
    final q = WriteQueue(db: db, doctype: 'X', batchRows: 100);
    final futs = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      futs.add(
        q.submit<void>((txn) async {
          await txn.insert('t', {'id': i, 'v': '$i'});
        }),
      );
    }
    await Future.wait(futs);
    final rows = await db.query('t');
    expect(rows.length, 20);
  });

  test('returns task result', () async {
    final q = WriteQueue(db: db, doctype: 'X');
    final r = await q.submit<int>((txn) async => 7);
    expect(r, 7);
  });

  test('drains pending submits with error when database is closed', () async {
    // Outer `db.transaction` failure (database closed mid-flight) used to
    // leave already-queued submits hanging on their Completers forever
    // because the kick loop's only catch was inside the transaction
    // callback. Verify the queue now drains pending tasks with the same
    // error so callers can observe the failure.
    final q = WriteQueue(db: db, doctype: 'X', batchRows: 100);

    // Close the database before any flush starts. The first submit's
    // microtask enters _kick(), tries db.transaction(...), and throws.
    await db.close();

    final futs = <Future<void>>[
      for (var i = 0; i < 5; i++)
        q.submit<void>((txn) async {
          await txn.insert('t', {'id': i, 'v': '$i'});
        }),
    ];

    for (final f in futs) {
      await expectLater(f, throwsA(isA<DatabaseException>()));
    }

    // Re-open for tearDown's close to be a no-op-safe.
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  });

  test(
    'caller does not observe success when the outer transaction fails after the body runs',
    () async {
      // B2 (PR#36 round-4): completers were resolved INSIDE the
      // db.transaction callback, before COMMIT. If the transaction then
      // fails to commit, the write is rolled back but the caller already
      // saw success — silent data loss with no observable error. The caller
      // must instead observe the failure.
      final q = WriteQueue(
        db: _CommitFailDatabase(db),
        doctype: 'X',
        batchRows: 100,
      );

      await expectLater(
        q.submit<void>((txn) async {
          await txn.insert('t', {'id': 1, 'v': 'a'});
        }),
        throwsA(isA<_SimulatedCommitFailure>()),
      );

      // The transaction rolled back → the row must not be durable.
      final rows = await db.query('t');
      expect(
        rows,
        isEmpty,
        reason: 'transaction failed to commit → write must not persist',
      );
    },
  );

  test(
    'failed task in batch does not commit its partial writes; siblings do',
    () async {
      // SIG-1: per-task isolation via SQLite savepoints. The outer
      // transaction batches up to `batchRows` tasks for one fsync, but a
      // failure in task[1] must roll back only task[1]'s writes — task[0]
      // and task[2] still commit. Without savepoints, the swallowed
      // exception left task[1]'s partial writes inside the same outer
      // transaction, which then committed alongside the siblings.
      final q = WriteQueue(db: db, doctype: 'X', batchRows: 10);

      final f0 = q.submit<void>((txn) async {
        await txn.insert('t', {'id': 1, 'v': 'one'});
      });
      final f1 = q.submit<void>((txn) async {
        await txn.insert('t', {'id': 2, 'v': 'TWO-PARTIAL'});
        // Throw AFTER the insert so we can prove the insert was rolled back.
        throw StateError('boom');
      });
      final f2 = q.submit<void>((txn) async {
        await txn.insert('t', {'id': 3, 'v': 'three'});
      });

      await expectLater(f0, completes);
      await expectLater(f1, throwsStateError);
      await expectLater(f2, completes);

      final rows = await db.query('t', orderBy: 'id ASC');
      expect(rows.map((r) => r['id']).toList(), [
        1,
        3,
      ], reason: 'task[1] partial insert must have been rolled back');
    },
  );
}

/// Wraps a real [Database] but forces the outer transaction to fail *after*
/// the batch body has run (savepoints released), simulating a commit-time
/// failure (disk full, lock timeout, DB closed at COMMIT). Only [transaction]
/// is exercised by [WriteQueue]; any other member is unexpected.
class _CommitFailDatabase implements Database {
  _CommitFailDatabase(this._inner);
  final Database _inner;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    return _inner.transaction<T>((txn) async {
      await action(txn);
      throw _SimulatedCommitFailure();
    }, exclusive: exclusive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SimulatedCommitFailure implements Exception {
  @override
  String toString() => 'SimulatedCommitFailure';
}
