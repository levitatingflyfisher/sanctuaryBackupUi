import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'backup_config.dart';
import 'backup_repository.dart';

/// The string key-value seam under [AppScopedSecureKeyStore], so the store
/// can be tested without the platform plugin.
abstract interface class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// [SecretStorage] over `flutter_secure_storage` — on web, the origin's
/// localStorage.
class FlutterSecretStorage implements SecretStorage {
  const FlutterSecretStorage([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A [SecureKeyStore] whose every entry is namespaced by app id:
/// `oh_<appId>_mnemonic_v1`, and so on.
///
/// Why: every fleet PWA is served from one origin
/// (levitatingflyfisher.github.io), and `flutter_secure_storage` on web is
/// that origin's localStorage. The default `FlutterSecureKeyStore` uses
/// fixed names (`oh_mnemonic_v1`), so every fleet PWA in one browser shares
/// one set of recovery words, one "acknowledged" flag and one "last backup"
/// time. Removing the words in one app removes them in all.
///
/// Migration: when this app has no namespaced words but the old shared
/// slot holds some, they are carried over ONLY when [ownsLegacyPhrase]
/// proves this app owns them (see [legacyPhraseOwnedBy]); the
/// acknowledgement comes with them, the shared backup time does not (it may
/// be another app's). The shared slot is never written or deleted, since
/// another app may own the same words. Without proof the shared slot is
/// never read: this app starts with no words, and the user can restore
/// with the words on paper, which adopts them.
class AppScopedSecureKeyStore implements SecureKeyStore {
  AppScopedSecureKeyStore({
    required String appId,
    SecretStorage storage = const FlutterSecretStorage(),
    Future<bool> Function(String phrase)? ownsLegacyPhrase,
  })  : _prefix = 'oh_${appId}_',
        _storage = storage,
        _ownsLegacyPhrase = ownsLegacyPhrase;

  final String _prefix;
  final SecretStorage _storage;
  final Future<bool> Function(String phrase)? _ownsLegacyPhrase;

  // The shared, un-namespaced names used by FlutterSecureKeyStore.
  static const _legacyMnemonic = 'oh_mnemonic_v1';
  static const _legacySeedAck = 'oh_seed_ack_v1';

  String get _mnemonic => '${_prefix}mnemonic_v1';
  String get _lastBackup => '${_prefix}last_backup_v1';
  String get _seedAck => '${_prefix}seed_ack_v1';
  String get _deviceId => '${_prefix}device_id_v1';

  @override
  Future<String?> readMnemonic() async {
    final scoped = await _storage.read(_mnemonic);
    if (scoped != null) return scoped;
    return _migrateLegacy();
  }

  Future<String?> _migrateLegacy() async {
    final proof = _ownsLegacyPhrase;
    if (proof == null) return null;
    final legacy = await _storage.read(_legacyMnemonic);
    if (legacy == null) return null;
    bool owned;
    try {
      owned = await proof(legacy);
    } on Object {
      owned = false;
    }
    if (!owned) return null;
    if (await _storage.read(_legacySeedAck) == 'true') {
      await _storage.write(_seedAck, 'true');
    }
    await _storage.write(_mnemonic, legacy);
    return legacy;
  }

  @override
  Future<void> writeMnemonic(String phrase) =>
      _storage.write(_mnemonic, phrase);

  @override
  Future<void> writeLastBackupAt(DateTime ts) =>
      _storage.write(_lastBackup, ts.toIso8601String());

  @override
  Future<DateTime?> readLastBackupAt() async {
    final raw = await _storage.read(_lastBackup);
    if (raw == null) return null;
    try {
      return DateTime.parse(raw);
    } on FormatException catch (e) {
      throw KeyStoreException('Corrupt lastBackupAt value: "$raw"', cause: e);
    }
  }

  @override
  Future<void> writeSeedAcknowledged() => _storage.write(_seedAck, 'true');

  @override
  Future<bool> readSeedAcknowledged() async =>
      await _storage.read(_seedAck) == 'true';

  @override
  Future<void> writeDeviceId(String id) => _storage.write(_deviceId, id);

  @override
  Future<String?> readDeviceId() => _storage.read(_deviceId);

  @override
  Future<void> clearAuth() => Future.wait([
        _storage.delete(_mnemonic),
        _storage.delete(_lastBackup),
        _storage.delete(_seedAck),
      ]);

  @override
  Future<void> clearAll() => Future.wait([
        _storage.delete(_mnemonic),
        _storage.delete(_lastBackup),
        _storage.delete(_seedAck),
        _storage.delete(_deviceId),
      ]);
}

/// A provider reader: `ref.read` or `container.read`.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// The ownership proof for [AppScopedSecureKeyStore]'s migration: [phrase]
/// belongs to this app when a snapshot in THIS app's vault (already scoped
/// by app id) opens under the key [phrase] derives for this app's domain
/// and AAD context. Apps that had words call `runStartupMaintenance`, which
/// keeps a snapshot in the vault, so the proof normally exists; without one
/// the answer is false.
Future<bool> legacyPhraseOwnedBy(ProviderReader read, String phrase) async {
  final keys = await read(cryptoServiceProvider)
      .deriveKeysFromPhrase(phrase, appDomain: read(sanctuaryAppDomainProvider));
  final vault = read(backupVaultProvider);
  final repo = read(backupRepositoryProvider);
  for (final entry in await vault.list()) {
    final bytes = await vault.read(entry.id);
    if (bytes == null) continue;
    try {
      await repo.open(bytes, keys.masterEncryptionKey);
      return true;
    } on Object {
      // Sealed under other words (e.g. a restore with typed words); try on.
    }
  }
  return false;
}

/// Override for your root `ProviderScope` that namespaces the key store by
/// [SanctuaryBackupConfig.appId] on web, where fleet PWAs share an origin:
///
/// ```dart
/// ProviderScope(overrides: [
///   sanctuaryBackupConfigProvider.overrideWithValue(myConfig),
///   appScopedKeyStoreOverride(),
///   ...
/// ])
/// ```
///
/// On native platforms each app has its own keychain, so this keeps the
/// default `FlutterSecureKeyStore` and nothing moves. Pass [web] only in
/// tests.
Override appScopedKeyStoreOverride({bool web = kIsWeb}) =>
    secureKeyStoreProvider.overrideWith((ref) {
      if (!web) return FlutterSecureKeyStore();
      return AppScopedSecureKeyStore(
        appId: ref.watch(sanctuaryBackupConfigProvider).appId,
        ownsLegacyPhrase: (phrase) => legacyPhraseOwnedBy(ref.read, phrase),
      );
    });
