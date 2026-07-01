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

void main() {
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
      expect(find.text('Reset identity'), findsOneWidget);
      expect(find.text('Set up encrypted backup'), findsNothing);
    });

    testWidgets('shows the section header', (tester) async {
      await tester.pumpWidget(_wrap(store: InMemorySecureKeyStore()));
      await tester.pumpAndSettle();

      expect(find.text('Encrypted Backup'), findsOneWidget);
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
        'Reset identity dialog does not overflow at 320 dp x 3.0 text scale',
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
      await tester.ensureVisible(find.text('Reset identity'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset identity'));
      await tester.pumpAndSettle();

      // The danger-zone confirmation is on screen...
      expect(find.text('Reset identity?'), findsOneWidget);
      // ...and its ~45-word body fits without a vertical overflow.
      expect(tester.takeException(), isNull);
    });
  });
}
