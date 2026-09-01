import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

const _phrase =
    'abstract accident actually adjust aerobic airport alcohol although '
    'ambition analyst anything approve';
final _words = _phrase.split(' ');

Future<void> _pump(
  WidgetTester tester, {
  required void Function(String?) onResult,
  Future<void> Function()? onShowWords,
  TextScaler scaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => onResult(await PhraseReEntryDialog.show(
            context,
            expectedPhrase: _phrase,
            onShowWords: onShowWords,
          )),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder get _next => find.byKey(const ValueKey('re-entry-next'));
Finder get _back => find.byKey(const ValueKey('re-entry-back'));

Future<void> _type(WidgetTester tester, String word) async {
  await tester.enterText(find.byType(TextField), word);
  await tester.pump();
  await tester.ensureVisible(_next);
  await tester.tap(_next);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('asks for one word at a time with a counter', (tester) async {
    await _pump(tester, onResult: (_) {});
    expect(find.text('Word 1 of 12'), findsOneWidget);
    await _type(tester, _words[0]);
    expect(find.text('Word 2 of 12'), findsOneWidget);
  });

  testWidgets('Next is inert until something is typed', (tester) async {
    await _pump(tester, onResult: (_) {});
    expect(tester.widget<FilledButton>(_next).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'abstract');
    await tester.pump();
    expect(tester.widget<FilledButton>(_next).onPressed, isNotNull);
  });

  testWidgets(
      'a wrong word is named in place, keeps what was typed, and keeps '
      'every earlier word', (tester) async {
    String? result;
    var returned = false;
    await _pump(tester, onResult: (r) {
      returned = true;
      result = r;
    });
    for (var i = 0; i < 4; i++) {
      await _type(tester, _words[i]);
    }
    await _type(tester, 'aerobics'); // word 5, one letter off

    expect(returned, isFalse, reason: 'the dialog stays open');
    expect(result, isNull);
    expect(find.text('Word 5 of 12'), findsOneWidget);
    expect(find.textContaining('word 5'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'aerobics');
    expect(find.byType(SnackBar), findsNothing);

    // Back shows word 4 exactly as it was typed.
    await tester.tap(_back);
    await tester.pumpAndSettle();
    expect(find.text('Word 4 of 12'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        _words[3]);
  });

  testWidgets('twelve right words return the phrase', (tester) async {
    String? result;
    await _pump(tester, onResult: (r) => result = r);
    for (final w in _words) {
      await _type(tester, '  ${w.toUpperCase()} ');
    }
    expect(result, _phrase);
  });

  testWidgets('"Show the words again" keeps what was typed', (tester) async {
    var shown = 0;
    await _pump(tester, onResult: (_) {}, onShowWords: () async => shown++);
    await _type(tester, _words[0]);
    await tester.enterText(find.byType(TextField), 'acci');
    await tester.pump();
    await tester.tap(find.text('Show the words again'));
    await tester.pumpAndSettle();
    expect(shown, 1);
    expect(find.text('Word 2 of 12'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'acci');
  });

  for (final scale in [2.0, 3.0]) {
    testWidgets(
        'at 320 dp x $scale the counter and the mismatch message are '
        'whole', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(tester,
          onResult: (_) {}, scaler: TextScaler.linear(scale));
      await _type(tester, 'wrong');
      expect(tester.takeException(), isNull);

      final message = tester.widget<Text>(find.textContaining('word 1'));
      expect(message.maxLines, isNull);
      expect(message.overflow, isNot(TextOverflow.ellipsis));
    });
  }
}
