import 'dart:typed_data';

import 'backup_envelope.dart';

/// The app-supplied bridge between a consuming app's local store and the
/// encrypted-backup pipeline.
///
/// Implement this once per app (typically over your Drift database):
/// [dumpAll] returns the app's full user-data payload as JSON-encoded bytes;
/// [restoreAll] replaces all local data with a payload previously produced by
/// [dumpAll]. The plaintext never leaves this interface unencrypted —
/// [BackupRepository] wraps it in an OHBK envelope before it touches disk or a
/// share sheet.
abstract class BackupSerializer {
  /// Serializes every user-data table to a JSON [Uint8List].
  ///
  /// Per SANCTUARY-BRIEF §2.8 the JSON envelope should carry an
  /// `{app, schemaVersion}` (or equivalent) so [restoreAll] can reject a
  /// mismatched app or a future schema — defense in depth behind the AEAD
  /// context.
  Future<Uint8List> dumpAll();

  /// Restores all user data from [plaintext] (previously produced by
  /// [dumpAll]).
  ///
  /// **Destructive:** implementations must wipe existing data and re-insert
  /// inside a single transaction (SANCTUARY-BRIEF §2.5) — never a partial
  /// restore. Throw [BackupSchemaException] when the payload's schema is newer
  /// than the running app can restore.
  Future<void> restoreAll(Uint8List plaintext);
}

/// Optional companion to [BackupSerializer]: an app-level dry-run parse.
///
/// When implemented, preview-before-restore and verify use
/// [describeBackup] instead of the generic [BackupEnvelope.describe], so
/// the manifest reflects the app's real validation (wrong app, future
/// schema, malformed payload) — throw exactly what `restoreAll` would.
/// Kept as a separate interface (not a method on [BackupSerializer])
/// because every shipped app `implements` that class, and a new member
/// would break them all.
abstract interface class PreviewableBackupSerializer {
  /// Validates [plaintext] WITHOUT writing anything and returns its
  /// manifest. Must throw [FormatException] / [BackupSchemaException] for
  /// payloads `restoreAll` would reject.
  Future<BackupManifest> describeBackup(Uint8List plaintext);
}

/// Thrown by a [BackupSerializer] when a backup's schema version is newer than
/// the running app can restore.
///
/// `BackupController` maps this to `RestoreOutcome.tooNewBackup` so the UI can
/// tell the user to update the app rather than showing a generic failure.
class BackupSchemaException implements Exception {
  /// The schema version recorded in the backup payload.
  final int backupVersion;

  /// The schema version the running app understands.
  final int currentVersion;

  const BackupSchemaException(this.backupVersion, this.currentVersion);

  @override
  String toString() =>
      'BackupSchemaException: backup schema v$backupVersion is newer than '
      'current v$currentVersion. Update the app before restoring this backup.';
}
