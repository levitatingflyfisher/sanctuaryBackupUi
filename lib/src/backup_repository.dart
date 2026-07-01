import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'backup_config.dart';
import 'backup_serializer.dart';

/// Orchestrates a [BackupSerializer] and [GhostBackup] to produce/consume
/// encrypted OHBK blobs, binding each blob to a per-app AEAD context.
class BackupRepository {
  final BackupSerializer _serializer;
  final EnvelopeCipher _cipher;
  final String _aadContext;

  const BackupRepository(
    this._serializer,
    this._cipher, {
    required String aadContext,
  }) : _aadContext = aadContext;

  /// Serializes all app data, encrypts it under [key], and returns the OHBK
  /// blob bytes ready to be saved to a file.
  Future<Uint8List> export(Uint8List key) async {
    final plaintext = await _serializer.dumpAll();
    return GhostBackup.export(plaintext, key, _cipher, context: _aadContext);
  }

  /// Decrypts an OHBK [blob] with [key] and returns the plaintext payload —
  /// NEVER writes. This is the read half of [restore], split out so preview,
  /// verify-by-read-back, and the pre-restore snapshot can all establish
  /// "this blob opens" before anything destructive happens.
  ///
  /// Throws [BackupFormatException] for malformed blobs and [CryptoException]
  /// for a wrong key / tampered data / context mismatch.
  Future<Uint8List> open(Uint8List blob, Uint8List key) =>
      GhostBackup.import(blob, key, _cipher, context: _aadContext);

  /// Hands an already-decrypted [plaintext] (from [open]) to the serializer,
  /// replacing all local data. Throws [BackupSchemaException] for a future
  /// schema version.
  Future<void> apply(Uint8List plaintext) => _serializer.restoreAll(plaintext);

  /// Decrypts an OHBK [blob] with [key] and restores all data, replacing what
  /// exists — [open] followed by [apply].
  ///
  /// Throws [BackupFormatException] for malformed blobs, [CryptoException] for
  /// a wrong key / tampered data / context mismatch, and [BackupSchemaException]
  /// for a future schema version.
  Future<void> restore(Uint8List blob, Uint8List key) async {
    await apply(await open(blob, key));
  }
}

final backupRepositoryProvider = Provider<BackupRepository>((ref) {
  final config = ref.watch(sanctuaryBackupConfigProvider);
  return BackupRepository(
    ref.watch(backupSerializerProvider),
    ref.watch(envelopeCipherProvider),
    aadContext: config.aadContext,
  );
});
