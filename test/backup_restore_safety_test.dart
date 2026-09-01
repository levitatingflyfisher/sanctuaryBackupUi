import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

const _aad = 'testapp-backup/v1';

/// The key FakeCryptoService(keyFill: 7) derives.
Uint8List _key([int fill = 7]) => Uint8List(32)..fillRange(0, 32, fill);

Uint8List _envelopeBytes() => BackupEnvelope.wrap(
      appId: 'testapp',
      schemaVersion: 3,
      createdAt: DateTime.utc(2026, 7, 1, 12),
      payload: {
        'sessions': [
          {'id': 1},
          {'id': 2},
          {'id': 3}
        ],
      },
    );

Future<Uint8List> _sealedBlob({int keyFill = 7}) => GhostBackup.export(
    _envelopeBytes(), _key(keyFill), EnvelopeCipher(),
    context: _aad);

/// A [VaultStore] whose [put] always fails — simulates disk-full / quota.
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

/// A serializer whose dumpAll always throws — current-data description must
/// degrade gracefully, not block the preview.
class _ExplodingDumpSerializer extends FakeBackupSerializer {
  @override
  Future<Uint8List> dumpAll() async => throw StateError('db locked');
}

/// A serializer that also implements the optional preview interface.
class _PreviewingSerializer extends FakeBackupSerializer
    implements PreviewableBackupSerializer {
  Object? throwOnDescribe;

  @override
  Future<BackupManifest> describeBackup(Uint8List plaintext) async {
    final err = throwOnDescribe;
    if (err != null) throw err;
    return const BackupManifest(
      appId: 'testapp',
      schemaVersion: 3,
      createdAt: null,
      tableCounts: {'custom': 42},
    );
  }
}

void main() {
  late InMemoryVaultStore vaultStore;

  ProviderContainer makeContainer({
    SecureKeyStore? store,
    BackupSerializer? serializer,
    VaultStore? vault,
    SanctuaryBackupConfig? config,
  }) {
    final container = ProviderContainer(overrides: [
      secureKeyStoreProvider.overrideWithValue(store ??
          InMemorySecureKeyStore(mnemonic: _validPhrase, acknowledged: true)),
      cryptoServiceProvider
          .overrideWithValue(FakeCryptoService(mnemonic: _validPhrase)),
      backupSerializerProvider
          .overrideWithValue(serializer ?? FakeBackupSerializer()),
      sanctuaryBackupConfigProvider.overrideWithValue(config ??
          const SanctuaryBackupConfig(
              appId: 'testapp',
              aadContext: _aad,
              appDisplayName: 'TestApp')),
      vaultStoreProvider.overrideWithValue(vault ?? vaultStore),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    vaultStore = InMemoryVaultStore();
  });

  group('BackupRepository.open / apply', () {
    test('open decrypts without ever calling the serializer', () async {
      final serializer = FakeBackupSerializer();
      final repo = BackupRepository(serializer, EnvelopeCipher(),
          aadContext: _aad);
      final blob = await _sealedBlob();
      final plaintext = await repo.open(blob, _key());
      expect(plaintext, _envelopeBytes());
      expect(serializer.restored, isNull,
          reason: 'open must NEVER write');
    });

    test('open with the wrong key throws CryptoException', () async {
      final repo = BackupRepository(FakeBackupSerializer(), EnvelopeCipher(),
          aadContext: _aad);
      final blob = await _sealedBlob();
      expect(() => repo.open(blob, _key(9)),
          throwsA(isA<CryptoException>()));
    });

    test('apply hands the plaintext to serializer.restoreAll', () async {
      final serializer = FakeBackupSerializer();
      final repo = BackupRepository(serializer, EnvelopeCipher(),
          aadContext: _aad);
      await repo.apply(_envelopeBytes());
      expect(serializer.restored, _envelopeBytes());
    });
  });

  group('prepareRestore (device key)', () {
    test('returns a manifest built from the decrypted payload', () async {
      final c = makeContainer();
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob());
      expect(prep.blocked, isNull);
      expect(prep.prepared, isNotNull);
      final m = prep.prepared!.manifest;
      expect(m.appId, 'testapp');
      expect(m.schemaVersion, 3);
      expect(m.createdAt, DateTime.utc(2026, 7, 1, 12));
      expect(m.tableCounts, {'sessions': 3});
    });

    test('with no key -> blocked noKey', () async {
      final c = makeContainer(store: InMemorySecureKeyStore());
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob());
      expect(prep.blocked, RestoreOutcome.noKey);
      expect(prep.prepared, isNull);
    });

    test('garbage bytes -> blocked corruptFile', () async {
      final c = makeContainer();
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(Uint8List.fromList([1, 2, 3]));
      expect(prep.blocked, RestoreOutcome.corruptFile);
    });

    test('a blob sealed under a different phrase -> blocked wrongPhrase',
        () async {
      final c = makeContainer();
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob(keyFill: 9));
      expect(prep.blocked, RestoreOutcome.wrongPhrase);
    });

    test('uses PreviewableBackupSerializer.describeBackup when implemented',
        () async {
      final c = makeContainer(serializer: _PreviewingSerializer());
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob());
      expect(prep.prepared!.manifest.tableCounts, {'custom': 42});
    });

    test(
        'a BackupSchemaException from describeBackup -> blocked tooNewBackup '
        '(rejected BEFORE any snapshot or confirm)', () async {
      final serializer = _PreviewingSerializer()
        ..throwOnDescribe = const BackupSchemaException(99, 3);
      final c = makeContainer(serializer: serializer);
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob());
      expect(prep.blocked, RestoreOutcome.tooNewBackup);
    });
  });

  group('prepareRestoreWithPhrase', () {
    test('derives the key from the phrase and opens the blob', () async {
      // Fresh install: no local key at all.
      final c = makeContainer(store: InMemorySecureKeyStore());
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestoreWithPhrase(await _sealedBlob(), _validPhrase);
      expect(prep.blocked, isNull);
      expect(prep.prepared!.manifest.tableCounts, {'sessions': 3});
    });

    test('an invalid phrase -> blocked wrongPhrase', () async {
      final c = ProviderContainer(overrides: [
        secureKeyStoreProvider.overrideWithValue(InMemorySecureKeyStore()),
        cryptoServiceProvider.overrideWithValue(const DefaultCryptoService()),
        backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
        sanctuaryBackupConfigProvider.overrideWithValue(
            const SanctuaryBackupConfig(
                appId: 'testapp',
                aadContext: _aad,
                appDisplayName: 'TestApp')),
        vaultStoreProvider.overrideWithValue(InMemoryVaultStore()),
      ]);
      addTearDown(c.dispose);
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestoreWithPhrase(
              await _sealedBlob(), 'definitely not twelve valid words');
      expect(prep.blocked, RestoreOutcome.wrongPhrase);
    });
  });

  group('commitRestore — the mandatory pre-restore snapshot', () {
    test(
        'takes a pre-restore snapshot of CURRENT data, then applies; the '
        'snapshot decrypts (under the same key) to what dumpAll returned',
        () async {
      final currentData = Uint8List.fromList(utf8.encode(
          '{"app":"testapp","schemaVersion":3,"payload":{"sessions":[]}}'));
      final serializer = FakeBackupSerializer(currentData);
      final c = makeContainer(serializer: serializer);
      final notifier = c.read(backupControllerProvider.notifier);

      final prep = await notifier.prepareRestore(await _sealedBlob());
      final outcome = await notifier.commitRestore(prep.prepared!);

      expect(outcome, RestoreOutcome.success);
      expect(serializer.restored, _envelopeBytes(),
          reason: 'the incoming payload must be applied');

      final vault = c.read(backupVaultProvider);
      final entries = await vault.list();
      expect(entries, hasLength(1));
      expect(entries.single.label, VaultLabel.preRestore);
      expect(entries.single.autoPinned, isTrue);
      final snapshotBlob = await vault.read(entries.single.id);
      final roundTripped = await GhostBackup.import(
          snapshotBlob!, _key(), EnvelopeCipher(),
          context: _aad);
      expect(roundTripped, currentData,
          reason: 'the rollback must contain the pre-restore data');
    });

    test(
        'FAIL-CLOSED: when the snapshot cannot be saved the restore does '
        'not run at all', () async {
      final serializer = FakeBackupSerializer();
      final c =
          makeContainer(serializer: serializer, vault: _FailingVaultStore());
      final notifier = c.read(backupControllerProvider.notifier);

      final prep = await notifier.prepareRestore(await _sealedBlob());
      final outcome = await notifier.commitRestore(prep.prepared!);

      expect(outcome, RestoreOutcome.snapshotFailed);
      expect(serializer.restored, isNull,
          reason: 'data must be untouched when the safety net failed');
    });

    test('onAfterRestore fires on success', () async {
      var fired = false;
      final c = makeContainer(
          config: SanctuaryBackupConfig(
              appId: 'testapp',
              aadContext: _aad,
              appDisplayName: 'TestApp',
              onAfterRestore: (_) => fired = true));
      final notifier = c.read(backupControllerProvider.notifier);
      final prep = await notifier.prepareRestore(await _sealedBlob());
      await notifier.commitRestore(prep.prepared!);
      expect(fired, isTrue);
    });
  });

  group('legacy one-shot restore wrappers', () {
    test('restoreFromBlob now takes the mandatory snapshot too', () async {
      final c = makeContainer();
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreFromBlob(await _sealedBlob());
      expect(outcome, RestoreOutcome.success);
      final entries = await c.read(backupVaultProvider).list();
      expect(entries.map((e) => e.label), contains(VaultLabel.preRestore));
    });

    test('restoreWithPhrase snapshots under the phrase-derived key',
        () async {
      final c = makeContainer(store: InMemorySecureKeyStore());
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreWithPhrase(await _sealedBlob(), _validPhrase);
      expect(outcome, RestoreOutcome.success);
      final vault = c.read(backupVaultProvider);
      final entries = await vault.list();
      expect(entries, hasLength(1));
      // Recoverable with the same words the user just typed.
      final blob = await vault.read(entries.single.id);
      await GhostBackup.import(blob!, _key(), EnvelopeCipher(), context: _aad);
    });
  });

  group('preview context', () {
    test('prepare fills currentTableCounts from the CURRENT data', () async {
      final current = BackupEnvelope.wrap(
        appId: 'testapp',
        schemaVersion: 3,
        createdAt: DateTime.utc(2026, 7, 15),
        payload: {
          'sessions': [
            {'id': 9}
          ],
        },
      );
      final c = makeContainer(serializer: FakeBackupSerializer(current));
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob());
      expect(prep.prepared!.currentTableCounts, {'sessions': 1},
          reason: 'preview compares backup counts against what exists now');
    });

    test('a failing dumpAll leaves currentTableCounts null, not a throw',
        () async {
      final c = makeContainer(serializer: _ExplodingDumpSerializer());
      final prep = await c
          .read(backupControllerProvider.notifier)
          .prepareRestore(await _sealedBlob());
      expect(prep.blocked, isNull);
      expect(prep.prepared!.currentTableCounts, isNull);
    });
  });

  // Every app shipping this section also ships a "Clear all data", and no
  // wipe took a snapshot (mantle:hackers-04, finding 7). The pre-wipe
  // snapshot sits beside the pre-restore one: same key, same auto-pin, same
  // read-back, same fail-closed contract.
  group('snapshotBeforeWipe', () {
    test('vaults current data as the protected rollback, verified', () async {
      final current = _envelopeBytes();
      final c = makeContainer(serializer: FakeBackupSerializer(current));
      final result =
          await c.read(backupControllerProvider.notifier).snapshotBeforeWipe();

      expect(result.outcome, PreWipeOutcome.taken);
      final entries = await c.read(backupVaultProvider).list();
      expect(entries.single.id, result.entry!.id);
      expect(entries.single.label, VaultLabel.preRestore);
      expect(entries.single.autoPinned, isTrue);
      final blob = await c.read(backupVaultProvider).read(result.entry!.id);
      expect(
          await GhostBackup.import(blob!, _key(), EnvelopeCipher(),
              context: _aad),
          current);
    });

    test('without words on the device -> noKey, nothing written', () async {
      final c = makeContainer(store: InMemorySecureKeyStore());
      final result =
          await c.read(backupControllerProvider.notifier).snapshotBeforeWipe();
      expect(result.outcome, PreWipeOutcome.noKey);
      expect(result.entry, isNull);
      expect(await c.read(backupVaultProvider).list(), isEmpty);
    });

    test('a vault that cannot save -> failed (the app must not wipe)',
        () async {
      final c = makeContainer(vault: _FailingVaultStore());
      final result =
          await c.read(backupControllerProvider.notifier).snapshotBeforeWipe();
      expect(result.outcome, PreWipeOutcome.failed);
      expect(result.entry, isNull);
    });
  });

  group('runStartupMaintenance (silent freshness snapshot)', () {
    test('takes a snapshot when the vault is empty and a key exists',
        () async {
      final c = makeContainer(serializer: FakeBackupSerializer(_envelopeBytes()));
      final took = await c
          .read(backupControllerProvider.notifier)
          .runStartupMaintenance();
      expect(took, isTrue);
      final entries = await c.read(backupVaultProvider).list();
      expect(entries.single.label, VaultLabel.freshness);
    });

    test('is a silent no-op without a key', () async {
      final c = makeContainer(store: InMemorySecureKeyStore());
      final took = await c
          .read(backupControllerProvider.notifier)
          .runStartupMaintenance();
      expect(took, isFalse);
      expect(await c.read(backupVaultProvider).list(), isEmpty);
    });

    test('is a silent no-op when the vault store itself is broken', () async {
      final c = makeContainer(vault: _FailingVaultStore());
      final took = await c
          .read(backupControllerProvider.notifier)
          .runStartupMaintenance();
      expect(took, isFalse);
    });
  });

  group('formatBackupAge', () {
    final now = DateTime.utc(2026, 7, 16, 12);
    test('renders today / yesterday / N days / unknown', () {
      expect(formatBackupAge(DateTime.utc(2026, 7, 16, 9), now),
          'made today');
      expect(formatBackupAge(DateTime.utc(2026, 7, 15, 9), now),
          'made yesterday');
      expect(formatBackupAge(DateTime.utc(2026, 7, 4), now),
          '12 days old');
      expect(formatBackupAge(null, now), 'age unknown');
    });

    test('never shows negative ages for slight clock skew', () {
      expect(formatBackupAge(DateTime.utc(2026, 7, 16, 13), now),
          'made today');
    });
  });

  group('restore-adopt (the Lullaby defect, fixed for the whole fleet)', () {
    test(
        'a FRESH INSTALL restoring with a phrase ADOPTS it: the phrase is '
        'persisted, acknowledged, and the key is live afterwards', () async {
      final keyStore = InMemorySecureKeyStore(); // ghost: nothing set up
      final c = makeContainer(store: keyStore);
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreWithPhrase(await _sealedBlob(), _validPhrase);
      expect(outcome, RestoreOutcome.success);

      expect(await keyStore.readMnemonic(), _validPhrase,
          reason: 'without adoption the restored data is orphaned — the '
              'user could never export again without a NEW identity');
      expect(await keyStore.readSeedAcknowledged(), isTrue,
          reason: 'typing the words to restore IS proof of possession');
      final auth = await c.read(authNotifierProvider.future);
      expect(auth.masterEncryptionKey, isNotNull);
    });

    test(
        'a device that ALREADY has an identity never gets it overwritten by '
        'restoring a foreign-phrase backup', () async {
      const devicePhrase =
          'legal winner thank year wave sausage worth useful legal winner '
          'thank yellow';
      final keyStore = InMemorySecureKeyStore(
          mnemonic: devicePhrase, acknowledged: true);
      final c = makeContainer(store: keyStore);
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreWithPhrase(await _sealedBlob(), _validPhrase);
      expect(outcome, RestoreOutcome.success);
      expect(await keyStore.readMnemonic(), devicePhrase,
          reason: 'restoring someone else\'s backup must not hijack this '
              'device\'s identity');
    });

    test('a failed phrase-restore adopts nothing', () async {
      final keyStore = InMemorySecureKeyStore();
      final c = makeContainer(
          store: keyStore, serializer: FakeBackupSerializer());
      final outcome = await c
          .read(backupControllerProvider.notifier)
          .restoreWithPhrase(
              Uint8List.fromList([1, 2, 3]), _validPhrase); // corrupt
      expect(outcome, isNot(RestoreOutcome.success));
      expect(await keyStore.readMnemonic(), isNull);
    });
  });

  group('exportBackup — verify by read-back + vault copy', () {
    test('returns a manifest proving the read-back and stores a vault copy',
        () async {
      final serializer = FakeBackupSerializer(_envelopeBytes());
      final c = makeContainer(serializer: serializer);
      final result =
          await c.read(backupControllerProvider.notifier).exportBackup();
      expect(result, isNotNull);
      expect(result!.manifest.tableCounts, {'sessions': 3},
          reason: 'the manifest comes from re-reading the sealed bytes');
      final entries = await c.read(backupVaultProvider).list();
      expect(entries, hasLength(1));
      expect(entries.single.label, VaultLabel.manual);
      expect(await c.read(backupVaultProvider).read(entries.single.id),
          result.bytes);
    });

    test('read-back failure surfaces as export failure, not silent success',
        () async {
      // A serializer that emits bytes describe() cannot parse.
      final serializer =
          FakeBackupSerializer(Uint8List.fromList([0xFF, 0x00, 0x81]));
      final c = makeContainer(serializer: serializer);
      final result =
          await c.read(backupControllerProvider.notifier).exportBackup();
      expect(result, isNull);
      expect((await c.read(backupVaultProvider).list()), isEmpty,
          reason: 'an unverified export must not be vaulted either');
    });

    test('a failing vault copy does NOT fail the export (best-effort)',
        () async {
      final serializer = FakeBackupSerializer(_envelopeBytes());
      final c = makeContainer(
          serializer: serializer, vault: _FailingVaultStore());
      final result =
          await c.read(backupControllerProvider.notifier).exportBackup();
      expect(result, isNotNull,
          reason: 'the shared file is the primary artifact; the vault copy '
              'is a bonus');
    });
  });
}
