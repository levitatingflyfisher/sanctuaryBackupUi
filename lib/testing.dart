/// Test-support fakes for consumers of `sanctuary_backup_ui`.
///
/// Import this only from test code:
/// ```dart
/// import 'package:sanctuary_backup_ui/testing.dart';
/// ```
/// It lets you exercise the backup controller/widgets without the OS keychain
/// or real PBKDF2.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'src/backup_serializer.dart';
import 'src/backup_vault.dart';
import 'src/file_vault_store.dart';

/// An in-memory [SecureKeyStore] for widget/controller tests — no OS keychain.
///
/// Override `secureKeyStoreProvider` (from `sanctuary_auth_core`) with an
/// instance of this. Seed it with a [mnemonic] / [acknowledged] / [lastBackupAt]
/// to simulate a user who has already set up backup.
class InMemorySecureKeyStore implements SecureKeyStore {
  String? _mnemonic;
  bool _acknowledged;
  DateTime? _lastBackupAt;
  String? _deviceId;

  InMemorySecureKeyStore({
    String? mnemonic,
    bool acknowledged = false,
    DateTime? lastBackupAt,
    String? deviceId,
  })  : _mnemonic = mnemonic,
        _acknowledged = acknowledged,
        _lastBackupAt = lastBackupAt,
        _deviceId = deviceId;

  @override
  Future<String?> readMnemonic() async => _mnemonic;

  @override
  Future<void> writeMnemonic(String phrase) async => _mnemonic = phrase;

  @override
  Future<bool> readSeedAcknowledged() async => _acknowledged;

  @override
  Future<void> writeSeedAcknowledged() async => _acknowledged = true;

  @override
  Future<DateTime?> readLastBackupAt() async => _lastBackupAt;

  @override
  Future<void> writeLastBackupAt(DateTime ts) async => _lastBackupAt = ts;

  @override
  Future<String?> readDeviceId() async => _deviceId;

  @override
  Future<void> writeDeviceId(String id) async => _deviceId = id;

  @override
  Future<void> clearAuth() async {
    _mnemonic = null;
    _acknowledged = false;
    _lastBackupAt = null;
  }

  @override
  Future<void> clearAll() async {
    await clearAuth();
    _deviceId = null;
  }
}

/// A [CryptoService] returning fixed 32-byte keys — fast and deterministic,
/// so controller/widget tests don't run real PBKDF2.
///
/// Set [throwOnDerive] to simulate an invalid phrase.
class FakeCryptoService implements CryptoService {
  FakeCryptoService({
    this.keyFill = 7,
    this.mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon about',
    this.throwOnDerive,
  });

  final int keyFill;
  final String mnemonic;
  final Object? throwOnDerive;

  @override
  String generateMnemonic() => mnemonic;

  @override
  Future<DerivedKeys> deriveKeysFromPhrase(
    String phrase, {
    String? appDomain,
  }) async {
    final err = throwOnDerive;
    if (err != null) throw err;
    Uint8List filled(int v) => Uint8List(32)..fillRange(0, 32, v);
    return DerivedKeys(
      masterEncryptionKey: filled(keyFill),
      syncKey: filled(keyFill + 1),
      authKey: filled(keyFill + 2),
      recoveryKey: filled(keyFill + 3),
      syncChannelId: filled(keyFill + 4),
    );
  }
}

/// An in-memory [VaultStore] so vault/controller tests run without a
/// filesystem or IndexedDB.
class InMemoryVaultStore implements VaultStore {
  final _entries = <String, VaultEntry>{};
  final _blobs = <String, Uint8List>{};

  /// When set, the next [put] throws (simulates disk-full mid-save) and
  /// the flag resets.
  bool failNextPut = false;

  @override
  Future<List<VaultEntry>> list() async => _entries.values.toList();

  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) async {
    if (failNextPut) {
      failNextPut = false;
      throw StateError('disk full');
    }
    _entries[entry.id] = entry;
    _blobs[entry.id] = bytes;
  }

  @override
  Future<void> update(VaultEntry entry) async => _entries[entry.id] = entry;

  @override
  Future<Uint8List?> read(String id) async => _blobs[id];

  @override
  Future<void> delete(String id) async {
    _entries.remove(id);
    _blobs.remove(id);
  }
}

/// An in-memory [VaultFileApi] so [FileVaultStore]'s retention logic tests
/// run without a filesystem or OPFS.
class InMemoryVaultFileApi implements VaultFileApi {
  final files = <String, Uint8List>{};

  @override
  Future<List<String>> listFilenames() async => files.keys.toList();

  @override
  Future<Uint8List?> readFile(String name) async => files[name];

  @override
  Future<void> writeFile(String name, Uint8List bytes) async =>
      files[name] = bytes;

  @override
  Future<void> deleteFile(String name) async => files.remove(name);
}

/// A [BackupSerializer] backed by an in-memory buffer: [dumpAll] returns
/// [payload]; [restoreAll] records the bytes it was handed in [restored].
class FakeBackupSerializer implements BackupSerializer {
  Uint8List payload;
  Uint8List? restored;

  FakeBackupSerializer([Uint8List? initial])
      : payload = initial ??
            Uint8List.fromList(
                utf8.encode('{"app":"fake","schemaVersion":1,"tables":{}}'));

  @override
  Future<Uint8List> dumpAll() async => payload;

  @override
  Future<void> restoreAll(Uint8List plaintext) async => restored = plaintext;
}
