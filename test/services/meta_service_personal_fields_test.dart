// MetaService side of personal fields: the `personal_fields` list from
// `mobile_auth.configuration` shapes the stored meta according to
// `storePersonalFields`, a changed list or setting triggers a re-fetch, and
// values left in the local mirror are blanked when the app does not keep them.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/meta_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _doctype = 'Beneficiary';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  setUp(() async => appDb = await AppDatabase.inMemoryDatabase());
  tearDown(() async => appDb.close());

  /// A server whose configuration lists [personalFields] for Beneficiary
  /// (omitted entirely when null, as an older server would). Counts meta
  /// fetches.
  ({FrappeClient client, int Function() metaFetches}) server(
    List<String>? personalFields,
  ) {
    var metaFetches = 0;
    final client = FrappeClient(
      'http://localhost',
      httpClient: MockClient((req) async {
        if (req.url.path.contains('mobile_auth.configuration')) {
          return _json({
            'data': [
              {
                'mobile_workspace_item': _doctype,
                'doctype_meta_modified_at': '2026-01-01 00:00:00',
                'personal_fields': ?personalFields,
              },
            ],
          });
        }
        if (req.url.path.contains('getdoctype')) {
          metaFetches++;
          return _json({
            'docs': [
              {
                'name': _doctype,
                'modified': '2026-01-01 00:00:00',
                'fields': [
                  {
                    'fieldname': 'full_name',
                    'fieldtype': 'Small Text',
                    'label': 'Name',
                  },
                  {
                    'fieldname': 'village',
                    'fieldtype': 'Data',
                    'label': 'Village',
                  },
                ],
              },
            ],
          });
        }
        return _json({});
      }),
    );
    client.rest.setBearerToken('AT');
    return (client: client, metaFetches: () => metaFetches);
  }

  Future<DocTypeMeta> storedMeta() async {
    final json = await appDb.doctypeMetaDao.getMetaJson(_doctype);
    return DocTypeMeta.fromJson(jsonDecode(json!) as Map<String, dynamic>);
  }

  test(
    'not storing: personal fields are removed from the stored meta',
    () async {
      final s = server(['full_name']);
      await MetaService(s.client, appDb).resyncMobileConfiguration();
      final meta = await storedMeta();
      expect(meta.fields.map((f) => f.fieldname), ['village']);
      expect(meta.personalFields, ['full_name']);
      expect(meta.storesPersonalFields, isFalse);
    },
  );

  test('storing: personal fields are kept and flagged', () async {
    final s = server(['full_name']);
    await MetaService(
      s.client,
      appDb,
      storePersonalFields: true,
    ).resyncMobileConfiguration();
    final meta = await storedMeta();
    expect(meta.fields.map((f) => f.fieldname), ['full_name', 'village']);
    expect(meta.storesPersonalFields, isTrue);
  });

  test('older server without personal_fields: meta stored as before', () async {
    final s = server(null);
    await MetaService(s.client, appDb).resyncMobileConfiguration();
    final meta = await storedMeta();
    expect(meta.fields.map((f) => f.fieldname), ['full_name', 'village']);
    expect(meta.personalFields, isEmpty);
    expect(meta.storesPersonalFields, isFalse);
  });

  test('no re-fetch when nothing changed; re-fetch when the setting or the '
      'list changes', () async {
    final s = server(['full_name']);
    await MetaService(s.client, appDb).resyncMobileConfiguration();
    expect(s.metaFetches(), 1);

    await MetaService(s.client, appDb).resyncMobileConfiguration();
    expect(s.metaFetches(), 1, reason: 'same list, same setting');

    await MetaService(
      s.client,
      appDb,
      storePersonalFields: true,
    ).resyncMobileConfiguration();
    expect(s.metaFetches(), 2, reason: 'setting flipped on');
    expect((await storedMeta()).storesPersonalFields, isTrue);

    final cleared = server(const []);
    await MetaService(
      cleared.client,
      appDb,
      storePersonalFields: true,
    ).resyncMobileConfiguration();
    expect(cleared.metaFetches(), 1, reason: 'list changed');
    expect((await storedMeta()).personalFields, isEmpty);
  });

  test('not storing: values already in the local mirror are blanked', () async {
    // The table was created while full_name was an ordinary field.
    final db = appDb.rawDatabase;
    await db.execute(
      'CREATE TABLE docs__beneficiary (mobile_uuid TEXT PRIMARY KEY, '
      'full_name TEXT, full_name__norm TEXT, village TEXT)',
    );
    await db.insert('docs__beneficiary', {
      'mobile_uuid': 'u-1',
      'full_name': 'Asha Devi',
      'full_name__norm': 'asha devi',
      'village': 'Rampur',
    });
    await db.insert('doctype_meta', {
      'doctype': _doctype,
      'metaJson': '{}',
      'isMobileForm': 1,
      'table_name': 'docs__beneficiary',
    });

    final s = server(['full_name']);
    await MetaService(s.client, appDb).resyncMobileConfiguration();

    final row = (await db.query('docs__beneficiary')).single;
    expect(row['full_name'], isNull);
    expect(row['full_name__norm'], isNull);
    expect(row['village'], 'Rampur');
  });

  test('getMeta strips a kept field once the app stops storing', () async {
    final s = server(['full_name']);
    await MetaService(
      s.client,
      appDb,
      storePersonalFields: true,
    ).resyncMobileConfiguration();
    // Same stored row, read by an install that no longer keeps them.
    final meta = await MetaService(s.client, appDb).getMeta(_doctype);
    expect(meta.fields.map((f) => f.fieldname), ['village']);
  });
}
