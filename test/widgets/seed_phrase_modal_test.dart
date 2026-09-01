import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

// Eight letters is the longest a BIP39 English word gets.
const _longPhrase =
    'abstract accident actually adjust aerobic airport alcohol although '
    'ambition analyst anything approve';

/// Tapers large text below the linear multiplier, like Android 14's curve
/// (ergonomic-ux template): a layout must not assume proportional growth.
class _NonLinearTextScaler extends TextScaler {
  const _NonLinearTextScaler(this.factor);
  final double factor;
  @override
  double scale(double fontSize) {
    final taper = (fontSize / 30.0).clamp(0.0, 1.0);
    return fontSize * (factor - (factor - 1.0) * 0.3 * taper);
  }

  @override
  double get textScaleFactor => factor;
}

void main() {
  // The sheet exists to be copied onto paper exactly, then checked back.
  // A Wrap folds the words 2-3-2 at whatever width the phone has; a fixed
  // three-columns-of-four table reads the same on every phone and at every
  // text size (furrow:visual-display-11, reckon:dont-make-me-think-12).
  for (final (name, scaler) in <(String, TextScaler)>[
    ('1.0', TextScaler.noScaling),
    ('linear 2.0', const TextScaler.linear(2.0)),
    ('non-linear 2.0', const _NonLinearTextScaler(2.0)),
  ]) {
    for (final width in [320.0, 412.0, 800.0]) {
      testWidgets('fixed 3x4 grid, numbered down columns, at ${width}dp x $name',
          (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scaler),
            child: child!,
          ),
          home: Scaffold(
            body: SeedPhraseModal(phrase: _longPhrase, onAcknowledged: () {}),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final words = _longPhrase.split(' ');
        final origins = <Offset>[
          for (var n = 1; n <= 12; n++)
            tester.getTopLeft(find.byKey(ValueKey('seed-word-$n'))),
        ];
        final xs = origins.map((o) => o.dx.round()).toSet();
        final ys = origins.map((o) => o.dy.round()).toSet();
        expect(xs, hasLength(3), reason: 'three columns');
        expect(ys, hasLength(4), reason: 'four rows');
        // 1-4 run down the first column, 5-8 the second, 9-12 the third.
        for (var c = 0; c < 3; c++) {
          for (var r = 1; r < 4; r++) {
            final above = origins[c * 4 + r - 1];
            final here = origins[c * 4 + r];
            expect(here.dx.round(), above.dx.round());
            expect(here.dy, greaterThan(above.dy));
          }
        }
        // Every word is whole: rendered as one unclipped, unwrapped line.
        for (var n = 1; n <= 12; n++) {
          final word = find.descendant(
              of: find.byKey(ValueKey('seed-word-$n')),
              matching: find.text(words[n - 1]));
          expect(word, findsOneWidget);
          final text = tester.widget<Text>(word);
          expect(text.maxLines, 1);
          expect(text.softWrap, isFalse);
          final cell = tester.getRect(find.byKey(ValueKey('seed-word-$n')));
          final wordRect = tester.getRect(word);
          expect(cell.left <= wordRect.left + 0.5 &&
              cell.right >= wordRect.right - 0.5, isTrue,
              reason: 'word ${words[n - 1]} fits inside its cell');
        }
      });
    }
  }

  testWidgets('renders 12 numbered words and the acknowledge button',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeedPhraseModal(phrase: _phrase, onAcknowledged: () {}),
      ),
    ));

    expect(find.byKey(const ValueKey('seed-word-1')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('seed-word-12')),
            matching: find.text('about')),
        findsOneWidget);
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
