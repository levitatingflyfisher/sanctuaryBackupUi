import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

/// Pumps a launcher button that opens [PhraseEntryDialog.show] and records the
/// returned value.
Future<void> _pumpLauncher(
  WidgetTester tester, {
  required void Function(String?) onResult,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => onResult(await PhraseEntryDialog.show(context)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('returns the phrase when exactly 12 words are entered',
      (tester) async {
    String? result;
    await _pumpLauncher(tester, onResult: (r) => result = r);

    const phrase =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';
    await tester.enterText(find.byType(TextField), phrase);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(result, phrase);
  });

  testWidgets('shows an error and stays open for the wrong word count',
      (tester) async {
    String? result;
    var called = false;
    await _pumpLauncher(tester, onResult: (r) {
      called = true;
      result = r;
    });

    await tester.enterText(find.byType(TextField), 'only three words');
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter exactly 12 words'), findsOneWidget);
    expect(called, isFalse); // dialog did not pop
    expect(result, isNull);
  });

  testWidgets('no overflow at 320 dp x 3.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpLauncher(tester, onResult: (_) {}, textScale: 3.0);

    expect(tester.takeException(), isNull);
  });
}
