import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

// Operator ruling 48: open into the task, ask for setup when it is needed,
// and keep a persistent, dismissable "finish setup" item so unfinished
// setup is never forgotten.

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

List<Override> _overrides(SecureKeyStore store, BackupReminderStore reminders) =>
    [
      secureKeyStoreProvider.overrideWithValue(store),
      cryptoServiceProvider.overrideWithValue(FakeCryptoService()),
      backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
      sanctuaryBackupConfigProvider.overrideWithValue(
          const SanctuaryBackupConfig(
              appId: 'testapp',
              aadContext: 'testapp-backup/v1',
              appDisplayName: 'TestApp')),
      vaultStoreProvider.overrideWithValue(InMemoryVaultStore()),
      backupReminderStoreProvider.overrideWithValue(reminders),
    ];

Widget _app(SecureKeyStore store, BackupReminderStore reminders,
        {TextScaler scaler = TextScaler.noScaling}) =>
    ProviderScope(
      overrides: _overrides(store, reminders),
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child!,
        ),
        home: const Scaffold(body: BackupSetupReminder()),
      ),
    );

void main() {
  group('backupSetupStatusProvider', () {
    Future<BackupSetupStatus> read(SecureKeyStore store,
        [BackupReminderStore? reminders]) async {
      final c = ProviderContainer(
          overrides:
              _overrides(store, reminders ?? InMemoryBackupReminderStore()));
      addTearDown(c.dispose);
      return c.read(backupSetupStatusProvider.future);
    }

    test('no words: not set up, reminder due', () async {
      final s = await read(InMemorySecureKeyStore());
      expect(s.hasWords, isFalse);
      expect(s.wordsConfirmed, isFalse);
      expect(s.setupFinished, isFalse);
      expect(s.showReminder(DateTime.now()), isTrue);
    });

    test('words confirmed: finished, no reminder, last backup reported',
        () async {
      final at = DateTime.utc(2026, 9, 20);
      final s = await read(InMemorySecureKeyStore(
          mnemonic: _phrase, acknowledged: true, lastBackupAt: at));
      expect(s.setupFinished, isTrue);
      expect(s.lastBackupAt, at);
      expect(s.showReminder(DateTime.now()), isFalse);
    });

    test('a dismissal hides the reminder, and it returns after the snooze',
        () async {
      final dismissed = DateTime.utc(2026, 9, 1);
      final s = await read(
          InMemorySecureKeyStore(mnemonic: _phrase),
          InMemoryBackupReminderStore(dismissed));
      expect(s.hasWords, isTrue);
      expect(s.wordsConfirmed, isFalse);
      expect(s.showReminder(dismissed.add(const Duration(days: 1))), isFalse);
      expect(
          s.showReminder(dismissed.add(BackupSetupStatus.reminderSnooze)),
          isTrue);
    });
  });

  group('BackupSetupReminder', () {
    testWidgets('shows a line with Set up and Dismiss when setup is unfinished',
        (tester) async {
      await tester.pumpWidget(
          _app(InMemorySecureKeyStore(), InMemoryBackupReminderStore()));
      await tester.pumpAndSettle();
      expect(find.textContaining("Backup isn't set up"), findsOneWidget);
      expect(find.text('Set up'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('names the remaining step when words are unconfirmed',
        (tester) async {
      await tester.pumpWidget(_app(InMemorySecureKeyStore(mnemonic: _phrase),
          InMemoryBackupReminderStore()));
      await tester.pumpAndSettle();
      expect(find.textContaining('check your recovery words'), findsOneWidget);
    });

    testWidgets('renders nothing once setup is finished', (tester) async {
      await tester.pumpWidget(_app(
          InMemorySecureKeyStore(mnemonic: _phrase, acknowledged: true),
          InMemoryBackupReminderStore()));
      await tester.pumpAndSettle();
      expect(find.text('Set up'), findsNothing);
    });

    testWidgets('Dismiss hides it and remembers the dismissal',
        (tester) async {
      final reminders = InMemoryBackupReminderStore();
      await tester
          .pumpWidget(_app(InMemorySecureKeyStore(), reminders));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Set up'), findsNothing);
      expect(await reminders.readDismissedAt(), isNotNull);
    });

    testWidgets('Set up starts the setup flow', (tester) async {
      await tester.pumpWidget(
          _app(InMemorySecureKeyStore(), InMemoryBackupReminderStore()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(find.byType(SeedPhraseModal), findsOneWidget);
    });

    testWidgets('no overflow at 320 dp x 2.0', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app(
          InMemorySecureKeyStore(), InMemoryBackupReminderStore(),
          scaler: const TextScaler.linear(2.0)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
