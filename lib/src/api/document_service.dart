// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
import '../sync/personal_fields.dart';
import 'create_idempotency.dart';
import 'rest_helper.dart';
import 'utils.dart';

class DocumentService {
  final RestHelper _restHelper;

  DocumentService(this._restHelper, {OnResolvedExisting? onResolvedExisting}) {
    _idempotency = CreateIdempotencyGuard(
      findByMobileUuid: _findByMobileUuid,
      onResolvedExisting: onResolvedExisting,
    );
  }

  late final CreateIdempotencyGuard _idempotency;

  /// Bound on each idempotency lookup. Short on purpose — see
  /// [_findByMobileUuid]. Two lookups worst case, so ~20s total rather
  /// than the default budget's ~186s.
  static const Duration _lookupTimeout = Duration(seconds: 10);

  /// Drops every remembered create attempt.
  ///
  /// Wired into logout by `AuthService.logout`. Kept public because a host that
  /// switches user without going through that path must call it too: the
  /// remembered set is keyed on `(doctype, uuid)` with no notion of who was
  /// signed in.
  ///
  /// The consequence of forgetting is small rather than none — v4 uuids do not
  /// collide across users, so a stale entry costs at most one wasted lookup on
  /// a key the new user will never send.
  void resetCreateIdempotency() => _idempotency.reset();

  /// Creates [doctype] from [data].
  ///
  /// When [data] carries a non-blank `mobile_uuid` the write is made
  /// **idempotent on that value**: a retry of the same logical document returns
  /// the document the earlier attempt created instead of making a second one.
  /// See [CreateIdempotencyGuard] for what that does and does not guarantee.
  ///
  /// The uuid must be minted ONCE per logical document by the caller and reused
  /// across retries — that stability is the entire mechanism, exactly as the
  /// offline path gets it from the local row's primary key. Minting a fresh
  /// uuid per attempt would restore the old behaviour precisely.
  ///
  /// A payload with no `mobile_uuid` (or a blank one) takes the original path
  /// unchanged: same request, same errors, no extra round trips.
  Future<Map<String, dynamic>> createDocument(
    String doctype,
    Map<String, dynamic> data, {
    bool useFrappeClient = false,
  }) {
    return _idempotency.run(
      doctype: doctype,
      data: data,
      create: (payload) => _create(doctype, payload, useFrappeClient),
    );
  }

  Future<Map<String, dynamic>> _create(
    String doctype,
    Map<String, dynamic> data,
    bool useFrappeClient,
  ) async {
    if (useFrappeClient) {
      final response = await _restHelper.post(
        '/api/method/frappe.client.insert',
        body: {'doc': jsonEncode(data..['doctype'] = doctype)},
      );
      return unwrapMessage<Map<String, dynamic>>(response);
    } else {
      final response = await _restHelper.post(
        '/api/resource/$doctype',
        body: data,
      );
      return withoutEncryptedPersonalValues(
        unwrapData<Map<String, dynamic>>(response),
      );
    }
  }

  /// The document already carrying [mobileUuid], or null if none does.
  ///
  /// Two calls on purpose. `get_list` answers the identity question but returns
  /// only a projection, and callers of [createDocument] consume the created
  /// document (workflow transitions read `name`, screens read server-assigned
  /// defaults), so handing back a one-field stub would be a different value
  /// than a real create returns. The second fetch keeps the two paths
  /// indistinguishable to every caller — see `onResolvedExisting` for how a
  /// caller is nonetheless TOLD which of the two happened.
  ///
  /// Both requests are **fast-fail**: `maxRetries: 0` and a short timeout. The
  /// condition that triggers a lookup is a network error or a 5xx — i.e. the
  /// network is down or the server is unwell — which is precisely when the
  /// default budget (30s x 3 retries, ~93s worst case, `rest_helper.dart`)
  /// would be spent in full before `_findQuietly` swallows the result and
  /// returns null anyway. The guard exists so an operator stops retrying
  /// blindly; making the failure take four times as long to appear works
  /// against that. Being unable to check is already handled correctly — the
  /// create simply proceeds.
  Future<Map<String, dynamic>?> _findByMobileUuid(
    String doctype,
    String mobileUuid,
  ) async {
    final listed = await _restHelper.get(
      '/api/method/frappe.client.get_list',
      queryParams: {
        'doctype': doctype,
        'filters': jsonEncode([
          [kMobileUuidField, '=', mobileUuid],
        ]),
        'fields': jsonEncode(['name']),
        'limit_page_length': 1,
        // Oldest first. On a site whose unique index is absent two rows CAN
        // already share a uuid; without an order the row you resolve to is
        // whatever the server happens to return. The first one written is the
        // one an earlier attempt created, so it is the one a retry means.
        'order_by': 'creation asc',
      },
      timeout: _lookupTimeout,
      maxRetries: 0,
    );
    final rows = unwrapMessage<dynamic>(listed);
    if (rows is! List || rows.isEmpty) return null;
    final first = rows.first;
    final name = (first is Map) ? first['name']?.toString() : null;
    if (name == null || name.isEmpty) return null;
    final doc = await _restHelper.get(
      '/api/resource/$doctype/$name',
      timeout: _lookupTimeout,
      maxRetries: 0,
    );
    return withoutEncryptedPersonalValues(
      unwrapData<Map<String, dynamic>>(doc),
    );
  }

  Future<Map<String, dynamic>> updateDocument(
    String doctype,
    String name,
    Map<String, dynamic> data,
  ) async {
    final response = await _restHelper.put(
      '/api/resource/$doctype/$name',
      body: data,
    );
    return withoutEncryptedPersonalValues(
      unwrapData<Map<String, dynamic>>(response),
    );
  }

  Future<void> deleteDocument(String doctype, String name) async {
    await _restHelper.delete('/api/resource/$doctype/$name');
  }

  Future<Map<String, dynamic>> submitDocument(
    String doctype,
    String name,
  ) async {
    return updateDocument(doctype, name, {'docstatus': 1});
  }

  Future<Map<String, dynamic>> cancelDocument(
    String doctype,
    String name,
  ) async {
    return updateDocument(doctype, name, {'docstatus': 2});
  }
}
