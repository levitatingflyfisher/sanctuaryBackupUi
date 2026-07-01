import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

/// A repository whose [open] always throws [error] — lets us drive the
/// wrong-phrase fallback branch without real crypto.
class _ThrowingRepo extends BackupRepository {
  _ThrowingRepo(this.error)
      : super(FakeBackupSerializer(), EnvelopeCipher(),
            aadContext: 'testapp-backup/v1');
  final Object error;
  @override
  Future<Uint8List> open(Uint8List blob, Uint8List key) async => throw error;
}

/// A repository whose restore path succeeds as a no-op — lets us drive the
/// happy-path snackbar without a real OHBK blob. [open] returns a small
/// real envelope so the preview dialog has something to describe.
class _OkRepo extends BackupRepository {
  _OkRepo()
      : super(FakeBackupSerializer(), EnvelopeCipher(),
            aadContext: 'testapp-backup/v1');
  @override
  Future<Uint8List> open(Uint8List blob, Uint8List key) async =>
      Uint8List.fromList(
          ('{"app":"testapp","schemaVersion":1,'
                  '"createdAt":"2026-07-10T00:00:00.000Z",'
                  '"payload":{"sessions":[{},{},{}]}}')
              .codeUnits);
  @override
  Future<void> apply(Uint8List plaintext) async {}
}

/// A [VaultStore] whose [put] always fails — the mandatory snapshot cannot
/// be saved, so commit must refuse.
class _FailingVaultStore implements VaultStore {
  @override
  Future<List<VaultEntry>> list() async => const [];
  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) async =>
      throw StateError('disk full');
  @override
  Future<void> update(VaultEntry entry) async {}
  @override
  Future<Uint8List?> read(String id) async => null;
  @override
  Future<void> delete(String id) async {}
}

/// Pumps a single button that, when tapped, runs [action] with a live
/// [BuildContext] beneath the [Navigator]/[Overlay] (so dialogs and snackbars
/// work) and the enclosing [WidgetRef].
Widget _harness({
  required SecureKeyStore store,
  required Future<void> Function(BuildContext, WidgetRef) action,
  SanctuaryBackupConfig? config,
  BackupRepository? repo,
  VaultStore? vault,
  double textScale = 1.0,
}) {
  return ProviderScope(
    overrides: [
      secureKeyStoreProvider.overrideWithValue(store),
      cryptoServiceProvider
          .overrideWithValue(FakeCryptoService(mnemonic: _validPhrase)),
      backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
      sanctuaryBackupConfigProvider.overrideWithValue(
        config ??
            const SanctuaryBackupConfig(
              appId: 'testapp',
              aadContext: 'testapp-backup/v1',
              appDisplayName: 'TestApp',
            ),
      ),
      vaultStoreProvider.overrideWithValue(vault ?? InMemoryVaultStore()),
      if (repo != null) backupRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Consumer(
        builder: (context, ref, _) => Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => action(context, ref),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final blob = Uint8List.fromList([1, 2, 3]);

  group('BackupFlow.restorePickedBlob', () {
    testWidgets('has-key path: confirm -> success snackbar', (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // Destructive-confirm dialog appears before any write.
      expect(find.text('Replace all data?'), findsOneWidget);
      await tester.tap(find.text('Replace everything'));
      await tester.pumpAndSettle();

      expect(find.text('Data restored successfully.'), findsOneWidget);
    });

    testWidgets('has-key path: cancelling confirm restores nothing',
        (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // No outcome snackbar of any kind.
      expect(find.text('Data restored successfully.'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
        'has-key path: wrong key falls back to PhraseEntryDialog '
        'BEFORE any confirm dialog (decrypt-first order)', (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _ThrowingRepo(CryptoException('wrong key')),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // The device key didn't unlock it -> we offer to enter the backup's
      // words immediately; no destructive confirm was shown for a blob we
      // couldn't even open.
      expect(find.text("Enter the backup's recovery words"), findsOneWidget);
      expect(find.text('Replace all data?'), findsNothing);
    });

    testWidgets(
        'preview: the confirm dialog shows age, row counts vs current, and '
        'the rollback safety-net line instead of "cannot be undone"',
        (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('Replace all data?'), findsOneWidget);
      expect(find.textContaining('This backup:'), findsOneWidget,
          reason: 'staleness line (age is information, not guilt)');
      expect(find.textContaining('sessions: 3 in backup'), findsOneWidget);
      expect(find.textContaining('here now'), findsOneWidget,
          reason: 'the preview compares against current data');
      expect(find.textContaining('Previous backups'), findsOneWidget,
          reason: 'the safety-net line replaces the old scare copy');
      expect(find.textContaining('cannot be undone'), findsNothing,
          reason: 'no longer true — the pre-restore snapshot exists now');
    });

    testWidgets(
        'FAIL-CLOSED surface: when the snapshot cannot be saved the user '
        'sees the snapshotFailed message and data is untouched',
        (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        vault: _FailingVaultStore(),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace everything'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't save a safety snapshot"),
          findsOneWidget);
      expect(find.text('Data restored successfully.'), findsNothing);
    });

    testWidgets(
        'confirm dialog title + verb come from config (F7)',
        (tester) async {
      // An upsert-merge app (e.g. StillLife) whose restore is NOT a wipe must
      // be able to override the destructive-replace title and button verb so
      // they don't contradict its merge-honest consequence body.
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        config: const SanctuaryBackupConfig(
          appId: 'stilllife',
          aadContext: 'stilllife-backup/v1',
          appDisplayName: 'Still Life',
          confirmTitle: 'Restore backup?',
          confirmActionLabel: 'Restore',
        ),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('Restore backup?'), findsOneWidget);
      expect(find.text('Replace all data?'), findsNothing);
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Replace everything'), findsNothing);
    });

    testWidgets(
        'confirm dialog defaults preserve destructive-replace copy (F7)',
        (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // A config that sets neither field keeps the pre-F7 copy verbatim, so
      // destructive-replace apps are unaffected.
      expect(find.text('Replace all data?'), findsOneWidget);
      expect(find.text('Replace everything'), findsOneWidget);
    });

    // F6: the destructive-confirm dialog carries the longest, app-customized
    // copy (restoreReplaceConsequence). Open it at a realistic phone height
    // (640) × 3.0 scale with a long, multi-clause consequence and assert it
    // scrolls rather than overflows. This is the coverage the closed-list
    // sweep never had.
    testWidgets(
        'confirm dialog with a long consequence does not overflow at '
        '320 dp x 3.0 text scale', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(
            mnemonic: _validPhrase, acknowledged: true),
        repo: _OkRepo(),
        textScale: 3.0,
        config: const SanctuaryBackupConfig(
          appId: 'reckon',
          aadContext: 'reckon-backup/v1',
          appDisplayName: 'Reckon',
          restoreReplaceConsequence:
              'Restoring will delete every case, poll, outside view, '
              'resolution, model prediction, and your profile currently on '
              'this device, then replace them with the contents of the backup '
              'file. It does not touch ReckonParty groups or the forecaster '
              'roster — those are not part of this backup.',
        ),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('Replace all data?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no-key (ghost) path: phrase first, then confirm',
        (tester) async {
      await tester.pumpWidget(_harness(
        store: InMemorySecureKeyStore(), // ghost: no key
        repo: _OkRepo(),
        action: (c, ref) =>
            const BackupFlow().restorePickedBlob(c, ref, blob),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // Ghost users are asked for the phrase BEFORE the destructive confirm.
      expect(find.text('Enter your 12 recovery words'), findsOneWidget);
      await tester.enterText(find.byType(TextField), _validPhrase);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.text('Replace all data?'), findsOneWidget);
    });
  });
}
