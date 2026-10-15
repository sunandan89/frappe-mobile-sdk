// Personal fields: values the server (mobile_control) stores encrypted.
//
// The server lists them per form in `mobile_auth.configuration` as
// `personal_fields: [fieldname, ...]`. Over `frappe.client.get_list` and
// `/api/resource` they come back as ciphertext (`enc:v1:<token>`); only
// `mobile_sync.get_docs_with_children` returns clear values, and only to
// users in the field's allowed roles (everyone else gets null).
//
// The SDK keeps the clear values in its local database only when the app
// passes `FrappeSDK(storePersonalFields: true)` — intended for apps that
// also encrypt the local database. Otherwise the fields are removed from the
// stored DocType meta, which keeps them out of the local schema, pull, push
// and the form renderer, exactly as Password fields are kept out today.
//
// The decision is recorded on the stored meta JSON under two keys, so it
// survives restarts and offline launches without a separate store:
//   * [personalFieldsMetaKey]       — the server's list for the doctype
//   * [personalFieldsStoredMetaKey] — whether this install keeps them

/// Prefix the server puts in front of an encrypted value.
const String encryptedValuePrefix = 'enc:v1:';

/// Meta JSON key: the doctype's personal fields as last configured.
const String personalFieldsMetaKey = '__mobile_personal_fields';

/// Meta JSON key: whether those fields were kept in the stored meta.
const String personalFieldsStoredMetaKey = '__mobile_personal_fields_stored';

/// True for a server-side ciphertext. Such a value must never be stored or
/// shown as if it were the clear value.
bool isEncryptedPersonalValue(Object? value) =>
    value is String && value.startsWith(encryptedValuePrefix);

/// True when [doc] carries at least one top-level ciphertext value.
bool hasEncryptedPersonalValues(Map<String, dynamic> doc) =>
    doc.values.any(isEncryptedPersonalValue);

/// A copy of [doc] without its top-level ciphertext values.
Map<String, dynamic> withoutEncryptedPersonalValues(Map<String, dynamic> doc) {
  if (!hasEncryptedPersonalValues(doc)) return doc;
  return <String, dynamic>{
    for (final e in doc.entries)
      if (!isEncryptedPersonalValue(e.value)) e.key: e.value,
  };
}

/// Normalised list of personal field names: strings only, trimmed, no blanks,
/// de-duplicated, sorted (so two lists compare by value).
List<String> normalisePersonalFields(Object? raw) {
  if (raw is! List) return const <String>[];
  final set = <String>{
    for (final v in raw)
      if (v is String && v.trim().isNotEmpty) v.trim(),
  };
  return set.toList()..sort();
}

/// The personal-field annotation already on a stored meta JSON, or null when
/// the meta was stored before personal fields were known.
({List<String> fields, bool stored})? readPersonalFieldAnnotation(
  Map<String, dynamic> metaJson,
) {
  if (!metaJson.containsKey(personalFieldsMetaKey)) return null;
  return (
    fields: normalisePersonalFields(metaJson[personalFieldsMetaKey]),
    stored: metaJson[personalFieldsStoredMetaKey] == true,
  );
}

/// Returns a copy of the server meta JSON [metaJson] annotated with
/// [personalFields] and [store]. When [store] is false the personal fields are
/// removed from `fields`, so nothing downstream creates a column for them,
/// writes them on pull, sends them on push or renders them.
Map<String, dynamic> applyPersonalFieldPolicy(
  Map<String, dynamic> metaJson, {
  required List<String> personalFields,
  required bool store,
}) {
  final fields = normalisePersonalFields(personalFields);
  final out = Map<String, dynamic>.from(metaJson);
  out[personalFieldsMetaKey] = fields;
  out[personalFieldsStoredMetaKey] = store;
  if (!store && fields.isNotEmpty && out['fields'] is List) {
    final drop = fields.toSet();
    out['fields'] = [
      for (final f in out['fields'] as List)
        if (!(f is Map && drop.contains(f['fieldname']))) f,
    ];
  }
  return out;
}
