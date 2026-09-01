import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

// Every fleet PWA is served from one origin (levitatingflyfisher.github.io),
// and flutter_secure_storage on web is that origin's localStorage. Without a
// namespace, every app reads and writes the same `oh_mnemonic_v1`: one app's
// "Remove recovery words" erases another's, and one app's backup time shows
// up as another's.

const _legacyPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

void main() {
  group('AppScopedSecureKeyStore', () {
    test('two apps on one storage never see each other\'s values', () async {
      final storage = InMemorySecretStorage();
      final a = AppScopedSecureKeyStore(appId: 'furrow', storage: storage);
      final b = AppScopedSecureKeyStore(appId: 'lullaby', storage: storage);

      await a.writeMnemonic('a words');
      await a.writeSeedAcknowledged();
      await a.writeLastBackupAt(DateTime.utc(2026, 9, 1));

      expect(await b.readMnemonic(), isNull);
      expect(await b.readSeedAcknowledged(), isFalse);
      expect(await b.readLastBackupAt(), isNull);
      expect(await a.readMnemonic(), 'a words');
      expect(storage.values.keys, isNot(contains('oh_mnemonic_v1')));
    });

    test('clearing one app leaves the other app and the legacy slot alone',
        () async {
      final storage = InMemorySecretStorage({'oh_mnemonic_v1': 'legacy'});
      final a = AppScopedSecureKeyStore(appId: 'furrow', storage: storage);
      final b = AppScopedSecureKeyStore(appId: 'lullaby', storage: storage);
      await a.writeMnemonic('a words');
      await b.writeMnemonic('b words');

      await a.clearAll();

      expect(await a.readMnemonic(), isNull);
      expect(await b.readMnemonic(), 'b words');
      expect(storage.values['oh_mnemonic_v1'], 'legacy');
    });

    test(
        'an un-namespaced phrase this app can prove it owns is carried '
        'over, with its acknowledgement but not its backup time', () async {
      final storage = InMemorySecretStorage({
        'oh_mnemonic_v1': _legacyPhrase,
        'oh_seed_ack_v1': 'true',
        'oh_last_backup_v1': '2026-08-01T00:00:00.000Z',
      });
      final store = AppScopedSecureKeyStore(
        appId: 'furrow',
        storage: storage,
        ownsLegacyPhrase: (p) async => p == _legacyPhrase,
      );

      expect(await store.readMnemonic(), _legacyPhrase);
      expect(await store.readSeedAcknowledged(), isTrue);
      // The shared backup time may be another app's export.
      expect(await store.readLastBackupAt(), isNull);
      expect(storage.values['oh_furrow_mnemonic_v1'], _legacyPhrase);
      // Another app may own it too; the legacy slot is left for it.
      expect(storage.values['oh_mnemonic_v1'], _legacyPhrase);
    });

    test('an un-namespaced phrase it cannot prove it owns is never read',
        () async {
      final storage = InMemorySecretStorage({
        'oh_mnemonic_v1': _legacyPhrase,
        'oh_seed_ack_v1': 'true',
      });
      for (final store in [
        AppScopedSecureKeyStore(
            appId: 'furrow',
            storage: storage,
            ownsLegacyPhrase: (_) async => false),
        AppScopedSecureKeyStore(appId: 'furrow', storage: storage),
      ]) {
        expect(await store.readMnemonic(), isNull);
        expect(await store.readSeedAcknowledged(), isFalse);
      }
      expect(storage.values.containsKey('oh_furrow_mnemonic_v1'), isFalse);
    });
  });

  group('legacyPhraseOwnedBy (the ownership proof)', () {
    const aad = 'testapp-backup/v1';
    Uint8List key(int fill) => Uint8List(32)..fillRange(0, 32, fill);

    Future<ProviderContainer> containerWithVault(List<int> sealedFills) async {
      final vaultStore = InMemoryVaultStore();
      final c = ProviderContainer(overrides: [
        cryptoServiceProvider.overrideWithValue(FakeCryptoService()), // key 7
        backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
        sanctuaryBackupConfigProvider.overrideWithValue(
            const SanctuaryBackupConfig(
                appId: 'testapp', aadContext: aad, appDisplayName: 'T')),
        vaultStoreProvider.overrideWithValue(vaultStore),
      ]);
      addTearDown(c.dispose);
      final vault = c.read(backupVaultProvider);
      for (final fill in sealedFills) {
        await vault.save(
            await GhostBackup.export(Uint8List.fromList([1, 2, 3]), key(fill),
                EnvelopeCipher(),
                context: aad),
            label: VaultLabel.freshness);
      }
      return c;
    }

    test('true when a snapshot in THIS app\'s vault opens under the phrase',
        () async {
      final c = await containerWithVault([9, 7]);
      expect(await legacyPhraseOwnedBy(c.read, _legacyPhrase), isTrue);
    });

    test('false with an empty vault', () async {
      final c = await containerWithVault([]);
      expect(await legacyPhraseOwnedBy(c.read, _legacyPhrase), isFalse);
    });

    test('false when no snapshot opens under the phrase', () async {
      final c = await containerWithVault([9]);
      expect(await legacyPhraseOwnedBy(c.read, _legacyPhrase), isFalse);
    });
  });

  group('appScopedKeyStoreOverride', () {
    ProviderContainer make(bool web) {
      final c = ProviderContainer(overrides: [
        sanctuaryBackupConfigProvider.overrideWithValue(
            const SanctuaryBackupConfig(
                appId: 'furrow', aadContext: 'x', appDisplayName: 'F')),
        appScopedKeyStoreOverride(web: web),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('namespaces on web', () {
      expect(make(true).read(secureKeyStoreProvider),
          isA<AppScopedSecureKeyStore>());
    });

    test('leaves native on the default keychain store', () {
      expect(make(false).read(secureKeyStoreProvider),
          isA<FlutterSecureKeyStore>());
    });
  });
}
