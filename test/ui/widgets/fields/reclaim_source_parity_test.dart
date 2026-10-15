// The pick path reclaimed `fieldState.value`; the discard path reclaimed the
// precedence-aware value. They diverge in exactly the case the field documents:
// before the first interaction `fieldState.value` is still null while the WIDGET
// value holds what an async document load supplied. So replacing a loaded
// attachment reclaimed null — the staged file it replaced leaked until the
// orphan sweep found it. Round-4 review M2.
//
// Direction matters: the bug leaks (recoverable). Aligning the DISCARD path to
// the raw value instead would delete files still in use (unrecoverable), which
// is why the pick path is the one that moves.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_paths.dart';

void main() {
  final reclaimed = <String?>[];

  setUp(reclaimed.clear);

  Future<void> pumpAttach(WidgetTester tester, {required String? value}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachField(
            field: DocField(fieldname: 'doc', fieldtype: 'Attach'),
            value: value,
            enabled: true,
            reclaimAttachment: (v) async => reclaimed.add(v),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('discard reclaims the value a document load supplied', (
    tester,
  ) async {
    // No interaction yet: fieldState.value is null, the widget value is live.
    await pumpAttach(tester, value: '/outbox/abc/report.pdf');

    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pump();

    expect(reclaimed, <String?>[
      '/outbox/abc/report.pdf',
    ], reason: 'the discard path already used the precedence-aware value');
  });

  testWidgets('the value reclaimed is trimmed, matching isStagedPath', (
    tester,
  ) async {
    await pumpAttach(tester, value: '  /outbox/abc/report.pdf  ');

    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pump();

    expect(
      reclaimed.single,
      '/outbox/abc/report.pdf',
      reason:
          'isStagedPath canonicalises what it is handed; an untrimmed '
          'path is a different string',
    );
  });

  testWidgets('an explicit clear survives — the value is not resurrected', (
    tester,
  ) async {
    await pumpAttach(tester, value: '/outbox/abc/report.pdf');
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pump();
    reclaimed.clear();

    // Rebuild with the SAME widget value. hasInteractedByUser is now true, so
    // the cleared state must win rather than the widget value coming back.
    await pumpAttach(tester, value: '/outbox/abc/report.pdf');

    expect(
      find.byTooltip('Remove attachment'),
      findsNothing,
      reason: 'the field is empty, so there is nothing to remove',
    );
  });

  group('liveAttachmentValue — the shared expression both paths now use', () {
    // The pick path is behind a static `FilePicker.pickFiles()` with no seam,
    // so it cannot be driven from a widget test. Sharing the expression is what
    // makes it correct: these cases pin the semantics for BOTH call sites.
    test('before any interaction the widget value wins (async doc load)', () {
      expect(
        liveAttachmentValue(
          hasInteractedByUser: false,
          fieldValue: null,
          widgetValue: '/outbox/abc/report.pdf',
        ),
        '/outbox/abc/report.pdf',
        reason: 'reading fieldValue raw here returned null — the leak',
      );
    });

    test('after an interaction the field value wins, so a clear survives', () {
      expect(
        liveAttachmentValue(
          hasInteractedByUser: true,
          fieldValue: null,
          widgetValue: '/outbox/abc/report.pdf',
        ),
        isNull,
        reason: 'an explicit clear must not be undone by the widget value',
      );
    });

    test('the result is trimmed for isStagedPath', () {
      expect(
        liveAttachmentValue(
          hasInteractedByUser: false,
          fieldValue: null,
          widgetValue: '  /outbox/abc/report.pdf  ',
        ),
        '/outbox/abc/report.pdf',
      );
    });

    test('a field value set by the user is preferred once interacted', () {
      expect(
        liveAttachmentValue(
          hasInteractedByUser: true,
          fieldValue: '/outbox/new/pick.pdf',
          widgetValue: '/outbox/old/loaded.pdf',
        ),
        '/outbox/new/pick.pdf',
      );
    });

    test('falls back to the field value when the widget has none', () {
      expect(
        liveAttachmentValue(
          hasInteractedByUser: false,
          fieldValue: '/outbox/abc/x.pdf',
          widgetValue: null,
        ),
        '/outbox/abc/x.pdf',
      );
    });
  });
}
