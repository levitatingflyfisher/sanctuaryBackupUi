import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

Widget _wrap({
  required SecureKeyStore store,
  double textScale = 1.0,
}) {
  return ProviderScope(
    overrides: [
      secureKeyStoreProvider.overrideWithValue(store),
      cryptoServiceProvider
          .overrideWithValue(FakeCryptoService(mnemonic: _validPhrase)),
      backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
      sanctuaryBackupConfigProvider.overrideWithValue(
        const SanctuaryBackupConfig(
          appId: 'testapp',
          aadContext: 'testapp-backup/v1',
          appDisplayName: 'TestApp',
        ),
      ),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(children: const [BackupSettingsSection()]),
      ),
    ),
  );
}

/// A key store whose first read never finishes (auth stays loading) or
/// throws (auth errors).
class _StuckStore extends InMemorySecureKeyStore {
  _StuckStore({this.fail = false});
  final bool fail;
  final _never = Completer<String?>();
  @override
  Future<String?> readMnemonic() =>
      fail ? Future.error(StateError('keystore locked')) : _never.future;
}

Iterable<String> _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');

void main() {
  // The heading and the tiles come from one widget: a loading or failed
  // auth read used to render SizedBox.shrink(), leaving the app's own
  // heading over nothing, and a real failure looked like "not loaded yet"
  // (weatherglass:humane-interface-08, sundial:dmmt-08).
  group('BackupSettingsSection header and body', () {
    testWidgets('loading shows the heading with a status line',
        (tester) async {
      await tester.pumpWidget(_wrap(store: _StuckStore()));
      await tester.pump();
      expect(find.text('Backup'), findsOneWidget);
      expect(find.text('Checking backup status…'), findsOneWidget);
    });

    testWidgets('a failure says so and offers Try again', (tester) async {
      await tester.pumpWidget(_wrap(store: _StuckStore(fail: true)));
      await tester.pumpAndSettle();
      expect(find.text('Backup'), findsOneWidget);
      expect(find.textContaining("Couldn't read"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the heading is neutral, not the accent colour',
        (tester) async {
      await tester.pumpWidget(_wrap(store: InMemorySecureKeyStore()));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Backup'));
      final primary = Theme.of(context).colorScheme.primary;
      final style = tester.widget<Text>(find.text('Backup')).style;
      expect(style?.color, isNot(primary));
    });

    // Plain words (peckish:design-for-hackers-04): no file extensions or
    // crypto vocabulary in the tiles.
    for (final acked in [false, true]) {
      testWidgets('no jargon in the tiles (acknowledged: $acked)',
          (tester) async {
        await tester.pumpWidget(_wrap(
            store: InMemorySecureKeyStore(
                mnemonic: acked ? _validPhrase : null, acknowledged: acked)));
        await tester.pumpAndSettle();
        for (final text in _visibleText(tester)) {
          expect(text.toLowerCase(),
              isNot(matches(RegExp(r'ohbk|mnemonic|envelope|identity|seed'))),
              reason: text);
        }
      });
    }
  });

  group('BackupSettingsSection', () {
    testWidgets('ghost state shows setup + restore, not export',
        (tester) async {
      await tester.pumpWidget(_wrap(store: InMemorySecureKeyStore()));
      await tester.pumpAndSettle();

      expect(find.text('Set up encrypted backup'), findsOneWidget);
      expect(find.text('Restore from backup'), findsOneWidget);
      expect(find.text('Export backup'), findsNothing);
    });

    testWidgets(
        'both states offer Previous backups and the plaintext export '
        '(neither needs a key)', (tester) async {
      await tester.pumpWidget(_wrap(store: InMemorySecureKeyStore()));
      await tester.pumpAndSettle();
      expect(find.text('Previous backups'), findsOneWidget);
      expect(find.text('Export as plain JSON'), findsOneWidget);
    });

    testWidgets('key + acknowledged shows export + reset', (tester) async {
      await tester.pumpWidget(_wrap(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Export backup'), findsOneWidget);
      expect(find.text('Remove recovery words'), findsOneWidget);
      expect(find.text('Set up encrypted backup'), findsNothing);
    });

    testWidgets('"Show my recovery words" is offered once words exist',
        (tester) async {
      await tester.pumpWidget(_wrap(store: InMemorySecureKeyStore()));
      await tester.pumpAndSettle();
      expect(find.text('Show my recovery words'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_wrap(
          store: InMemorySecureKeyStore(mnemonic: _validPhrase)));
      await tester.pumpAndSettle();
      expect(find.text('Show my recovery words'), findsOneWidget);
    });

    testWidgets('shows the section header', (tester) async {
      await tester.pumpWidget(_wrap(store: InMemorySecureKeyStore()));
      await tester.pumpAndSettle();

      expect(find.text('Backup'), findsOneWidget);
    });

    testWidgets('no overflow at 320 dp x 3.0 text scale', (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        textScale: 3.0,
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // F6: the closed-list sweep above never OPENS the dialogs, so their
    // overflow at large text scale went unverified. A realistic phone height
    // (640, not 1400) at 3.0 scale is what actually stresses a fixed-height
    // dialog vertically.
    testWidgets(
        'Remove-words dialog does not overflow at 320 dp x 3.0 text scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        textScale: 3.0,
      ));
      await tester.pumpAndSettle();

      // At 3.0 scale the tiles are tall; the danger-zone tile is below the
      // fold on a 640-tall screen, so scroll it into view before tapping.
      await tester.ensureVisible(find.text('Remove recovery words'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove recovery words'));
      await tester.pumpAndSettle();

      // The danger-zone confirmation is on screen...
      expect(find.text('Remove recovery words from this device?'), findsOneWidget);
      // ...and its ~45-word body fits without a vertical overflow.
      expect(tester.takeException(), isNull);
    });
  });
}
