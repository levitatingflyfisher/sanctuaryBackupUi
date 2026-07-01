import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

SanctuaryBackupConfig _config({void Function(Ref ref)? onAfterRestore}) =>
    SanctuaryBackupConfig(
      appId: 'testapp',
      aadContext: 'testapp-backup/v1',
      appDisplayName: 'TestApp',
      onAfterRestore: onAfterRestore,
    );

/// A repository whose [open] always throws [error] — the decrypt step is
/// where every outcome-mapping error class first surfaces.
class _ThrowingRepo extends BackupRepository {
  _ThrowingRepo(this.error)
      : super(FakeBackupSerializer(), EnvelopeCipher(),
            aadContext: 'testapp-backup/v1');
  final Object error;
  @override
  Future<Uint8List> open(Uint8List blob, Uint8List key) async => throw error;
}

/// A repository whose restore path succeeds as a no-op.
class _OkRepo extends BackupRepository {
  _OkRepo()
      : super(FakeBackupSerializer(), EnvelopeCipher(),
            aadContext: 'testapp-backup/v1');
  @override
  Future<Uint8List> open(Uint8List blob, Uint8List key) async =>
      Uint8List.fromList('{"app":"testapp","schemaVersion":1}'.codeUnits);
  @override
  Future<void> apply(Uint8List plaintext) async {}
}

void main() {
  ProviderContainer makeContainer({
    SecureKeyStore? store,
    CryptoService? crypto,
    BackupSerializer? serializer,
    BackupRepository? repo,
    SanctuaryBackupConfig? config,
  }) {
    final container = ProviderContainer(overrides: [
      secureKeyStoreProvider
          .overrideWithValue(store ?? InMemorySecureKeyStore()),
      cryptoServiceProvider
          .overrideWithValue(crypto ?? FakeCryptoService()),
      backupSerializerProvider
          .overrideWithValue(serializer ?? FakeBackupSerializer()),
      sanctuaryBackupConfigProvider.overrideWithValue(config ?? _config()),
      vaultStoreProvider.overrideWithValue(InMemoryVaultStore()),
      if (repo != null) backupRepositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  final blob = Uint8List.fromList([1, 2, 3]);

  group('seed generate + confirm', () {
    test('generateSeedPhrase returns and persists a phrase', () async {
      final store = InMemorySecureKeyStore();
      final c = makeContainer(store: store);
      final phrase =
          await c.read(backupControllerProvider.notifier).generateSeedPhrase();
      expect(phrase, isNotNull);
      expect(await store.readMnemonic(), phrase);
    });

    test('confirmSeedAcknowledged is true for the matching phrase', () async {
      final c = makeContainer(crypto: FakeCryptoService(mnemonic: _validPhrase));
      final phrase =
          await c.read(backupControllerProvider.notifier).generateSeedPhrase();
      final ok = await c
          .read(backupControllerProvider.notifier)
          .confirmSeedAcknowledged(phrase!);
      expect(ok, isTrue);
    });

    test('confirmSeedAcknowledged is false for a mismatched phrase', () async {
      final c = makeContainer(crypto: FakeCryptoService(mnemonic: _validPhrase));
      await c.read(backupControllerProvider.notifier).generateSeedPhrase();
      final ok = await c
          .read(backupControllerProvider.notifier)
          .confirmSeedAcknowledged('these are the wrong twelve words to enter');
      expect(ok, isFalse);
    });
  });

  group('exportBackup', () {
    test('produces bytes + <appId>-backup-<date>.ohbk filename', () async {
      final store = InMemorySecureKeyStore(
          mnemonic: _validPhrase, acknowledged: true);
      final c = makeContainer(
          store: store, crypto: FakeCryptoService(mnemonic: _validPhrase));

      final result =
          await c.read(backupControllerProvider.notifier).exportBackup();
      expect(result, isNotNull);
      expect(result!.filename,
          matches(RegExp(r'^testapp-backup-\d{4}-\d{2}-\d{2}\.ohbk$')));
      expect(result.bytes.sublist(0, 4), equals([0x4F, 0x48, 0x42, 0x4B]));
    });

    test('returns null when there is no key', () async {
      final c = makeContainer(); // empty keychain -> ghost, no key
      final result =
          await c.read(backupControllerProvider.notifier).exportBackup();
      expect(result, isNull);
    });
  });

  group('restore outcome mapping', () {
    Future<RestoreOutcome> restoreWith(ProviderContainer c) => c
        .read(backupControllerProvider.notifier)
        .restoreWithPhrase(blob, _validPhrase);

    test('CryptoException -> wrongPhrase', () async {
      expect(
          await restoreWith(
              makeContainer(repo: _ThrowingRepo(CryptoException('wrong key')))),
          RestoreOutcome.wrongPhrase);
    });

    test('BackupFormatException -> corruptFile', () async {
      expect(
          await restoreWith(makeContainer(
              repo: _ThrowingRepo(BackupFormatException('bad magic')))),
          RestoreOutcome.corruptFile);
    });

    test('BackupSchemaException -> tooNewBackup', () async {
      expect(
          await restoreWith(makeContainer(
              repo: _ThrowingRepo(const BackupSchemaException(99, 1)))),
          RestoreOutcome.tooNewBackup);
    });

    test('an unexpected error -> failed', () async {
      expect(
          await restoreWith(
              makeContainer(repo: _ThrowingRepo(StateError('boom')))),
          RestoreOutcome.failed);
    });

    test('restoreFromBlob with no key -> noKey', () async {
      final c = makeContainer(); // ghost
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreFromBlob(blob);
      expect(outcome, RestoreOutcome.noKey);
    });

    test(
        'an invalid BIP39 phrase (real crypto ArgumentError) -> wrongPhrase',
        () async {
      // Regression guard for the stub->real swap: sanctuary_auth_core validates
      // BIP39 and throws ArgumentError for a bad phrase; the controller must
      // translate that to wrongPhrase (calm copy), not failed.
      final c = ProviderContainer(overrides: [
        secureKeyStoreProvider
            .overrideWithValue(InMemorySecureKeyStore()),
        cryptoServiceProvider
            .overrideWithValue(const DefaultCryptoService()),
        backupSerializerProvider
            .overrideWithValue(FakeBackupSerializer()),
        sanctuaryBackupConfigProvider.overrideWithValue(_config()),
      ]);
      addTearDown(c.dispose);

      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreWithPhrase(blob, 'clearly not a valid bip39 recovery phrase');
      expect(outcome, RestoreOutcome.wrongPhrase);
    });
  });

  group('onAfterRestore hook', () {
    test('fires after a successful restore', () async {
      var fired = false;
      final c = makeContainer(
        repo: _OkRepo(),
        config: _config(onAfterRestore: (_) => fired = true),
      );
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreWithPhrase(blob, _validPhrase);
      expect(outcome, RestoreOutcome.success);
      expect(fired, isTrue);
    });
  });
}
