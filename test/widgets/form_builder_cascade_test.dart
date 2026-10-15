import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart'
    show ChangeSource;

/// Tests for [FrappeFormBuilder.cascadeProgrammaticChanges] — Frappe
/// `frm.set_value` parity: a value set programmatically by [onFieldChange]
/// re-fires that field's own change handler so its dependents recompute.
///
/// Baseline (flag OFF) documents WHY the SDK does not cascade on its own: the
/// change pipeline writes the patch into form state *before* calling
/// `patchValue`, so the re-entrant `onChanged` sees `oldValue == value` and its
/// guard no-ops the handler. The flag forces that re-fire, loop-safely.
void main() {
  DocTypeMeta metaABC() => DocTypeMeta(
    name: 'TestDoctype',
    fields: <DocField>[
      DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
      DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
      DocField(fieldname: 'c', fieldtype: 'Data', label: 'C'),
    ],
  );

  // a='hello' ⇒ compute b; b changing ⇒ compute c; c terminates.
  Map<String, dynamic>? chainHandler(
    String name,
    dynamic value,
    Map<String, dynamic> data, {
    ChangeSource source = ChangeSource.user,
  }) {
    if (name == 'a' && value == 'hello') return {'b': 'B:hello'};
    if (name == 'b') return {'c': 'C:$value'};
    return null;
  }

  testWidgets('cascade OFF (default): a computed field does NOT chain', (
    tester,
  ) async {
    Map<String, dynamic>? emitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: metaABC(),
            // cascadeProgrammaticChanges defaults to false
            onFieldChange: chainHandler,
            onFormDataChanged: (d) => emitted = d,
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'hello');
    await tester.pumpAndSettle();

    expect(emitted?['b'], 'B:hello', reason: 'a→b direct patch still applies');
    expect(
      (emitted?['c'] ?? '').toString(),
      isEmpty,
      reason: 'without the flag, b must not re-fire its own handler → c unset',
    );
  });

  testWidgets('cascade ON: a computed field re-fires its handler (a→b→c)', (
    tester,
  ) async {
    Map<String, dynamic>? emitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: metaABC(),
            cascadeProgrammaticChanges: true,
            onFieldChange: chainHandler,
            onFormDataChanged: (d) => emitted = d,
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'hello');
    await tester.pumpAndSettle();

    expect(emitted?['b'], 'B:hello', reason: 'a→b direct patch');
    expect(
      emitted?['c'],
      'C:B:hello',
      reason: "b's programmatic set must cascade to c",
    );
  });

  testWidgets(
    'cascade ON: the user edit is ChangeSource.user, cascade re-fires are '
    'ChangeSource.reaction (so hosts can gate side-effects)',
    (tester) async {
      // #2 regression: because each cascade hop re-runs onFieldChange, a
      // side-effecting handler must be able to tell the originating user edit
      // apart from a re-fire. The legacy path used to pass no source (defaulting
      // to ChangeSource.user for EVERY hop); it now tags re-fires as .reaction,
      // matching the reactive controller.
      final sources = <String, List<ChangeSource>>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: metaABC(),
              cascadeProgrammaticChanges: true,
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                (sources[name] ??= <ChangeSource>[]).add(source);
                if (name == 'a' && value == 'hello') return {'b': 'B:hello'};
                if (name == 'b') return {'c': 'C:$value'};
                return null;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const ValueKey('data_a')), 'hello');
      await tester.pumpAndSettle();

      expect(sources['a'], [
        ChangeSource.user,
      ], reason: 'the field the user typed into is ChangeSource.user');
      expect(sources['b'], [
        ChangeSource.reaction,
      ], reason: "b was set by a's handler → its re-fire is a reaction");
      expect(sources['c'], [
        ChangeSource.reaction,
      ], reason: 'a cascade hop deeper is still a reaction, never .user');
    },
  );

  testWidgets(
    'cascade ON: a typed (Check) computed field re-fires EXACTLY once',
    (tester) async {
      // Regression guard for the double-fire risk: the handler returns `1`
      // (int) for a Check field, which FieldNormalizer turns into `true`
      // (bool). Without the echo suppression, the synchronous patchValue echo
      // (oldValue 1 != true) AND the explicit cascade would both fire the
      // `flag` handler. It must fire exactly once.
      var flagHandlerCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'TestDoctype',
                fields: <DocField>[
                  DocField(fieldname: 'trigger', fieldtype: 'Data', label: 'T'),
                  DocField(fieldname: 'flag', fieldtype: 'Check', label: 'F'),
                ],
              ),
              cascadeProgrammaticChanges: true,
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                if (name == 'trigger') return {'flag': 1};
                if (name == 'flag') {
                  flagHandlerCalls++;
                  return null;
                }
                return null;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const ValueKey('data_trigger')), 'x');
      await tester.pumpAndSettle();

      expect(
        flagHandlerCalls,
        1,
        reason: 'echo must be suppressed; only the explicit cascade fires',
      );
    },
  );

  testWidgets('cascade terminates on a non-converging handler (depth cap)', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: DocTypeMeta(
              name: 'TestDoctype',
              fields: <DocField>[
                DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
                DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
              ],
            ),
            cascadeProgrammaticChanges: true,
            onFieldChange: (name, value, data, {source = ChangeSource.user}) {
              calls++;
              // b keeps setting itself to a NEW value ⇒ value-equality never
              // stops it; only the depth cap can. Proves the backstop.
              if (name == 'a') return {'b': '1'};
              if (name == 'b') {
                return {'b': '${(int.tryParse('$value') ?? 0) + 1}'};
              }
              return null;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'go');
    await tester.pumpAndSettle();

    // The key assertion is that pumpAndSettle RETURNS (no infinite loop).
    // Calls are bounded: 1 for `a` + at most (depth cap) re-fires for `b`.
    // Pin the exact count: 1 dispatch for `a` + _maxProgrammaticCascadeDepth
    // (12) non-converging re-fires for `b`. `lessThanOrEqualTo(20)` also passed
    // if the cap silently changed to 5 or 19, which is the one thing this test
    // exists to police.
    expect(
      calls,
      equals(13),
      reason: 'cascade must stop at the depth cap (1 + 12), not loop forever',
    );
  });

  testWidgets('cascade OFF: a SELF-referential rewrite must not recurse '
      '(StackOverflow regression)', (tester) async {
    // Regression: a handler that REWRITES its own field's value
    // ('hi' → 'HI') used to be patched back into the widget synchronously,
    // inside the text field's own didChange/controller dispatch — the
    // in-flight editing value and the patch alternated in unbounded
    // synchronous recursion (StackOverflowError), cascade flag irrelevant.
    // The self-key widget patch is now deferred one frame. With the flag
    // OFF the handler must fire exactly once (no cascade re-fire).
    var aHandlerCalls = 0;
    Map<String, dynamic>? emitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: DocTypeMeta(
              name: 'TestDoctype',
              fields: <DocField>[
                DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
              ],
            ),
            // cascadeProgrammaticChanges defaults to false
            onFieldChange: (name, value, data, {source = ChangeSource.user}) {
              if (name == 'a') {
                aHandlerCalls++;
                return {'a': value.toString().toUpperCase()};
              }
              return null;
            },
            onFormDataChanged: (d) => emitted = d,
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'hi');
    await tester.pumpAndSettle();

    expect(emitted?['a'], 'HI', reason: 'self-rewrite must land in the doc');
    expect(
      aHandlerCalls,
      1,
      reason:
          'flag OFF: user edit fires once, deferred self-patch echo '
          'must not re-run the handler',
    );
  });

  testWidgets(
    'cascade ON: a SELF-referential patch (handler normalises its own field) '
    'converges after exactly one re-fire',
    (tester) async {
      // Edge case: the handler patches the SAME field that is changing. The
      // field's own new value is written into form state BEFORE the handler
      // runs, so the cascade's `prior` for the self-key is the just-typed
      // value — the re-fire happens because the handler REWROTE it
      // ('hi' → 'HI'), and the idempotent rewrite ('HI' → 'HI') converges on
      // the next round via value-equality. No depth-cap involvement.
      var aHandlerCalls = 0;
      Map<String, dynamic>? emitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'TestDoctype',
                fields: <DocField>[
                  DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
                  DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
                ],
              ),
              cascadeProgrammaticChanges: true,
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                if (name == 'a') {
                  aHandlerCalls++;
                  final normalized = value.toString().toUpperCase();
                  return {'a': normalized, 'b': 'B:$normalized'};
                }
                return null;
              },
              onFormDataChanged: (d) => emitted = d,
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const ValueKey('data_a')), 'hi');
      await tester.pumpAndSettle();

      expect(emitted?['a'], 'HI', reason: 'self-patch must win over the edit');
      expect(emitted?['b'], 'B:HI', reason: 'sibling patch applies alongside');
      expect(
        aHandlerCalls,
        2,
        reason:
            'exactly the user edit + ONE self re-fire ("hi"→"HI" rewrite); '
            'the idempotent second pass ("HI"→"HI") must not re-fire again',
      );
    },
  );

  testWidgets(
    'cascade OFF: a self-referential handler on a TYPED field must not loop '
    '(deferred self-key echo hang regression)',
    (tester) async {
      // Regression: the deferred self-key echo used to raise
      // [_programmaticEchoGuard] only when the cascade flag was ON. With it
      // OFF and a TYPED field, the handler patch lands in _formData in one
      // representation (bool `true`) while the Check widget's onChanged echoes
      // another (int `1`), so `oldValue != value` stays true, the handler
      // re-fires every post-frame, and the ONLY loop breaker — the depth cap
      // in _scheduleProgrammaticCascade — never runs because it is
      // cascade-gated. That is an uncapped infinite hang (pre-fix a
      // synchronous StackOverflow). The self-key echo guard is now
      // unconditional, so the echo is a pure state-sync no-op and the handler
      // fires exactly once. The throw-after-N counter turns a would-be hang
      // into a fast, deterministic failure instead of a pumpAndSettle timeout.
      var flagHandlerCalls = 0;
      Map<String, dynamic>? emitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'TestDoctype',
                fields: <DocField>[
                  DocField(fieldname: 'flag', fieldtype: 'Check', label: 'F'),
                ],
              ),
              // cascadeProgrammaticChanges defaults to false
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                if (name == 'flag') {
                  flagHandlerCalls++;
                  if (flagHandlerCalls > 5) {
                    throw StateError(
                      'self-key echo looped ($flagHandlerCalls calls) — the '
                      'deferred echo must be guarded regardless of the cascade '
                      'flag',
                    );
                  }
                  // Return bool while the widget echoes int: idempotent in
                  // intent, but a representation the widget never converges to.
                  return {'flag': true};
                }
                return null;
              },
              onFormDataChanged: (d) => emitted = d,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('check_flag')));
      await tester.pumpAndSettle();

      // Exactly once. `lessThanOrEqualTo(5)` could never fail here — the guard
      // inside the handler throws at > 5, so any reachable value satisfied it,
      // and a partial regression leaking two or three extra frames stayed
      // green. The documented contract is "the handler fires exactly once".
      expect(
        flagHandlerCalls,
        equals(1),
        reason: 'the deferred self-key echo must not re-fire the handler',
      );
      // Pin the representation. The handler returns bool `true`; what lands in
      // doc space is int 1, because the Check widget's echo goes through
      // FieldNormalizer. `anyOf(true, 1)` accepted either and so asserted
      // nothing about which one the payload carries.
      expect(
        emitted?['flag'],
        equals(1),
        reason: 'the self-patch value must land in the doc as Frappe 0/1',
      );
    },
  );

  testWidgets(
    'cascade ON: numeric value-equality skips a representation-only re-fire '
    '(10 vs "10.0")',
    (tester) async {
      // b starts at int 10. The handler for `a` patches b to the string
      // "10.0" — numerically identical. The cascade value-equality must treat
      // 10 == "10.0" and NOT re-fire b's handler. Pre-fix the trimmed-string
      // compare ("10" != "10.0") let a representation-only change through as a
      // harmless-but-avoidable extra self-terminating re-fire.
      var bHandlerCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'TestDoctype',
                fields: <DocField>[
                  DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
                  DocField(fieldname: 'b', fieldtype: 'Float', label: 'B'),
                ],
              ),
              initialData: const {'b': 10},
              cascadeProgrammaticChanges: true,
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                if (name == 'a') return {'b': '10.0'};
                if (name == 'b') bHandlerCalls++;
                return null;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const ValueKey('data_a')), 'go');
      await tester.pumpAndSettle();

      expect(
        bHandlerCalls,
        0,
        reason:
            'a numerically-equal patch (10 vs "10.0") must not re-fire b\'s '
            'handler',
      );
    },
  );

  testWidgets(
    'cascade ON: numeric equality does NOT apply to non-numeric fieldtypes '
    '("007" vs "7" on a Link/Data field is a real change)',
    (tester) async {
      // Counterpart to the test above: numeric comparison is gated on the
      // field's fieldtype. A Data/Link id is an opaque string, so "007" and
      // "7" must compare UNEQUAL and the cascade must re-fire — an
      // unconditional numeric compare would swallow this legitimate change.
      var bHandlerCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'TestDoctype',
                fields: <DocField>[
                  DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
                  DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
                ],
              ),
              initialData: const {'b': '007'},
              cascadeProgrammaticChanges: true,
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                if (name == 'a') return {'b': '7'};
                if (name == 'b') bHandlerCalls++;
                return null;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const ValueKey('data_a')), 'go');
      await tester.pumpAndSettle();

      expect(
        bHandlerCalls,
        1,
        reason:
            'on a non-numeric field "007" → "7" is a real change and must '
            'cascade exactly once',
      );
    },
  );
}
