import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

void main() {
  testWidgets('renders 12 numbered chips and the acknowledge button',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeedPhraseModal(phrase: _phrase, onAcknowledged: () {}),
      ),
    ));

    expect(find.text('1. abandon'), findsOneWidget);
    expect(find.text('12. about'), findsOneWidget);
    expect(find.text("I've written this down"), findsOneWidget);
  });

  testWidgets('tapping acknowledge fires the callback and pops',
      (tester) async {
    var acked = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => SeedPhraseModal(
                phrase: _phrase,
                onAcknowledged: () => acked = true,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text("I've written this down"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I've written this down"));
    await tester.pumpAndSettle();

    expect(acked, isTrue);
    expect(find.byType(SeedPhraseModal), findsNothing);
  });

  testWidgets('no overflow at 320 dp x 3.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(3.0)),
        child: child!,
      ),
      home: Scaffold(
        body: SeedPhraseModal(phrase: _phrase, onAcknowledged: () {}),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
