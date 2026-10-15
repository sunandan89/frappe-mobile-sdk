// Personal fields: values `mobile_control` stores encrypted (`enc:v1:...`).
//
// Pins the three local guarantees:
//   * not stored unless the app opts in (`storePersonalFields`), exactly like
//     Password fields — no column, nothing written on pull, nothing pushed;
//   * stored and synced when it does;
//   * a ciphertext is never stored or sent as if it were the value.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_assembler.dart';
import 'package:frappe_mobile_sdk/src/sync/personal_fields.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Fictional sample data.
const _cipher = 'enc:v1:gAAAAABfictionalTokenOnly==';

Map<String, dynamic> _serverMeta() => {
  'name': 'Beneficiary',
  'fields': [
    {'fieldname': 'full_name', 'fieldtype': 'Small Text', 'label': 'Name'},
    {'fieldname': 'village', 'fieldtype': 'Data', 'label': 'Village'},
  ],
};

DocTypeMeta _meta({required bool store}) => DocTypeMeta.fromJson(
  applyPersonalFieldPolicy(
    _serverMeta(),
    personalFields: const ['full_name'],
    store: store,
  ),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('applyPersonalFieldPolicy', () {
    test('drops the fields and records the decision when not storing', () {
      final out = applyPersonalFieldPolicy(
        _serverMeta(),
        personalFields: const ['full_name'],
        store: false,
      );
      final names = (out['fields'] as List).map((f) => f['fieldname']);
      expect(names, ['village']);
      final annotation = readPersonalFieldAnnotation(out)!;
      expect(annotation.fields, ['full_name']);
      expect(annotation.stored, isFalse);
      final meta = DocTypeMeta.fromJson(out);
      expect(meta.personalFields, ['full_name']);
      expect(meta.storesPersonalFields, isFalse);
    });

    test('keeps the fields when storing', () {
      final meta = _meta(store: true);
      expect(meta.fields.map((f) => f.fieldname), ['full_name', 'village']);
      expect(meta.storesPersonalFields, isTrue);
    });

    test('a meta stored before the setting has no annotation', () {
      expect(readPersonalFieldAnnotation(_serverMeta()), isNull);
      final meta = DocTypeMeta.fromJson(_serverMeta());
      expect(meta.personalFields, isEmpty);
      expect(meta.storesPersonalFields, isFalse);
    });

    test('does not mutate the server map', () {
      final server = _serverMeta();
      applyPersonalFieldPolicy(
        server,
        personalFields: const ['full_name'],
        store: false,
      );
      expect((server['fields'] as List).length, 2);
      expect(server.containsKey(personalFieldsMetaKey), isFalse);
    });
  });

  group('ciphertext helpers', () {
    test('detects and drops only enc:v1: strings', () {
      expect(isEncryptedPersonalValue(_cipher), isTrue);
      expect(isEncryptedPersonalValue('Asha Devi'), isFalse);
      expect(isEncryptedPersonalValue(null), isFalse);
      expect(isEncryptedPersonalValue(7), isFalse);
      final doc = {'name': 'B-1', 'full_name': _cipher, 'village': 'Rampur'};
      expect(withoutEncryptedPersonalValues(doc), {
        'name': 'B-1',
        'village': 'Rampur',
      });
      final clean = {'name': 'B-1'};
      expect(identical(withoutEncryptedPersonalValues(clean), clean), isTrue);
    });

    test('normalisePersonalFields tolerates junk', () {
      expect(normalisePersonalFields(null), isEmpty);
      expect(normalisePersonalFields('full_name'), isEmpty);
      expect(
        normalisePersonalFields([' phone ', 'full_name', '', 3, 'phone']),
        ['full_name', 'phone'],
      );
    });
  });

  test(
    'routing: only a doctype that KEEPS personal fields needs full docs',
    () {
      expect(metaPullsFullDocs(_meta(store: true)), isTrue);
      expect(metaPullsFullDocs(_meta(store: false)), isFalse);
      expect(metaPullsFullDocs(DocTypeMeta.fromJson(_serverMeta())), isFalse);
    },
  );

  group('pull apply', () {
    late Database db;
    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          doctype TEXT NOT NULL,
          mobile_uuid TEXT NOT NULL,
          operation TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'pending',
          error_code TEXT,
          error_message TEXT,
          payload TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
    });
    tearDown(() async => db.close());

    Future<void> provision(DocTypeMeta meta) async {
      for (final s in buildParentSchemaDDL(meta, tableName: 'docs__b')) {
        await db.execute(s);
      }
    }

    Future<Set<String>> columns() async => (await db.rawQuery(
      'PRAGMA table_info(docs__b)',
    )).map((r) => r['name'] as String).toSet();

    Future<void> pull(
      DocTypeMeta meta,
      Map<String, dynamic> row, {
      bool initial = false,
    }) => PullApply.applyPage(
      db: db,
      parentMeta: meta,
      parentTable: 'docs__b',
      childMetasByFieldname: const {},
      rows: [row],
      isInitialSync: initial,
    );

    test('not allowed: no column, value dropped, other fields kept', () async {
      final meta = _meta(store: false);
      await provision(meta);
      expect(await columns(), isNot(contains('full_name')));
      await pull(meta, {
        'name': 'B-1',
        'modified': '2026-01-01 00:00:00',
        'full_name': 'Asha Devi',
        'village': 'Rampur',
      });
      final rows = await db.query('docs__b');
      expect(rows.single['village'], 'Rampur');
      expect(rows.single.containsKey('full_name'), isFalse);
    });

    for (final initial in [false, true]) {
      test('allowed: clear value stored (initial=$initial)', () async {
        final meta = _meta(store: true);
        await provision(meta);
        await pull(meta, {
          'name': 'B-1',
          'modified': '2026-01-01 00:00:00',
          'full_name': 'Asha Devi',
          'village': 'Rampur',
        }, initial: initial);
        final rows = await db.query('docs__b');
        expect(rows.single['full_name'], 'Asha Devi');
      });

      test('ciphertext is never stored (initial=$initial)', () async {
        final meta = _meta(store: true);
        await provision(meta);
        await pull(meta, {
          'name': 'B-1',
          'modified': '2026-01-01 00:00:00',
          'full_name': _cipher,
          'village': 'Rampur',
        }, initial: initial);
        final rows = await db.query('docs__b');
        expect(rows.single['full_name'], isNull);
        expect(rows.single['village'], 'Rampur');
      });
    }

    test('ciphertext on re-pull leaves the stored clear value alone', () async {
      final meta = _meta(store: true);
      await provision(meta);
      await pull(meta, {
        'name': 'B-1',
        'modified': '2026-01-01 00:00:00',
        'full_name': 'Asha Devi',
      });
      await pull(meta, {
        'name': 'B-1',
        'modified': '2026-01-02 00:00:00',
        'full_name': _cipher,
      });
      final rows = await db.query('docs__b');
      expect(rows.single['full_name'], 'Asha Devi');
      expect(rows.single['modified'], '2026-01-02 00:00:00');
    });
  });

  group('push payload', () {
    late Database db;
    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    });
    tearDown(() async => db.close());

    OutboxRow row() => OutboxRow(
      id: 1,
      doctype: 'Beneficiary',
      mobileUuid: 'u-1',
      operation: OutboxOperation.update,
      state: OutboxState.pending,
      retryCount: 0,
      createdAt: DateTime.utc(2026, 1, 1),
    );

    Future<Map<String, Object?>> assemble(DocTypeMeta meta) =>
        PayloadAssembler.assemble(
          db: db,
          row: row(),
          parentMeta: meta,
          parentTable: 'docs__b',
          childMetasByFieldname: const {},
          resolveServerName: (_, _) async => null,
        );

    test('a leftover column of a dropped personal field is never sent — '
        'its null would clear the server value', () async {
      // Table provisioned while the field was an ordinary field.
      for (final s in buildParentSchemaDDL(
        DocTypeMeta.fromJson(_serverMeta()),
        tableName: 'docs__b',
      )) {
        await db.execute(s);
      }
      await db.insert('docs__b', {
        'mobile_uuid': 'u-1',
        'sync_status': 'dirty',
        'local_modified': 1,
        'full_name': null,
        'village': 'Rampur',
      });
      final payload = await assemble(_meta(store: false));
      expect(payload.containsKey('full_name'), isFalse);
      expect(payload['village'], 'Rampur');
    });

    test('a kept personal field is sent as typed', () async {
      for (final s in buildParentSchemaDDL(
        _meta(store: true),
        tableName: 'docs__b',
      )) {
        await db.execute(s);
      }
      await db.insert('docs__b', {
        'mobile_uuid': 'u-1',
        'sync_status': 'dirty',
        'local_modified': 1,
        'full_name': 'Asha Devi',
      });
      final payload = await assemble(_meta(store: true));
      expect(payload['full_name'], 'Asha Devi');
    });

    test('a ciphertext is never sent', () async {
      for (final s in buildParentSchemaDDL(
        _meta(store: true),
        tableName: 'docs__b',
      )) {
        await db.execute(s);
      }
      await db.insert('docs__b', {
        'mobile_uuid': 'u-1',
        'sync_status': 'dirty',
        'local_modified': 1,
        'full_name': _cipher,
      });
      final payload = await assemble(_meta(store: true));
      expect(payload.containsKey('full_name'), isFalse);
    });
  });
}
