import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'backup_serializer.dart';
import 'backup_vault.dart';
import 'vault_store_platform.dart';

/// Per-app configuration for the encrypted-backup UI.
///
/// Provide one via [sanctuaryBackupConfigProvider] at your root
/// [ProviderScope]. Everything app-specific — the backup filename stem, the
/// AEAD context binding the blob to this app, the user-facing copy, and the
/// post-restore refresh — flows through here so the widgets and controller
/// stay app-agnostic.
class SanctuaryBackupConfig {
  /// Lowercase app id, e.g. `'lullaby'`. Used for the backup filename stem
  /// (`<appId>-backup-<yyyy-MM-dd>.ohbk`).
  final String appId;

  /// The AEAD additional-data context bound into every OHBK blob this app
  /// writes, e.g. `'lullaby-backup/v1'`. A blob made for one context can never
  /// be decrypted under another (SANCTUARY-BRIEF §2.3). Lullaby alone keeps the
  /// legacy `'ghost-backup/v1'` for shipped-backup compatibility.
  final String aadContext;

  /// Human-readable app name for user-facing copy, e.g. `'Lullaby'`.
  final String appDisplayName;

  /// Optional app-specific sentence appended to the destructive-restore
  /// confirmation — e.g. a list of the data categories that will be replaced.
  /// When null a generic consequence line is shown.
  final String? restoreReplaceConsequence;

  /// Title of the restore-confirmation dialog. Defaults to
  /// `'Replace all data?'` — correct for destructive-replace apps (the Lullaby
  /// precedent). Apps whose restore is an upsert-merge, not a wipe (e.g.
  /// StillLife), MUST override this so the title doesn't contradict a
  /// merge-honest [restoreReplaceConsequence] body — e.g. `'Restore backup?'`.
  final String confirmTitle;

  /// Label of the confirm button in the restore-confirmation dialog. Defaults
  /// to `'Replace everything'`. Upsert-merge apps should set e.g. `'Restore'`
  /// so the verb matches their non-destructive restore (pairs with
  /// [confirmTitle]).
  final String confirmActionLabel;

  /// Invoked after a successful restore so the app can invalidate any
  /// providers still holding references to now-wiped rows (SANCTUARY-BRIEF
  /// §2.5). Runs with the `BackupController`'s [Ref].
  final void Function(Ref ref)? onAfterRestore;

  /// How many unpinned snapshots the [BackupVault] keeps (pinned entries
  /// never count). 10 is right for KB–MB payloads; media-heavy apps set it
  /// lower (BACKUP_RETENTION_SPEC §3).
  final int vaultKeepN;

  /// How stale the newest snapshot may get before the silent app-open
  /// freshness snapshot fires (BACKUP_RETENTION_SPEC §3).
  final Duration vaultFreshnessAge;

  const SanctuaryBackupConfig({
    required this.appId,
    required this.aadContext,
    required this.appDisplayName,
    this.restoreReplaceConsequence,
    this.confirmTitle = 'Replace all data?',
    this.confirmActionLabel = 'Replace everything',
    this.onAfterRestore,
    this.vaultKeepN = 10,
    this.vaultFreshnessAge = const Duration(days: 7),
  });
}

/// Override this at your root [ProviderScope] with your app's
/// [SanctuaryBackupConfig]. Throws by default so a missing override fails loud.
final sanctuaryBackupConfigProvider = Provider<SanctuaryBackupConfig>(
  (_) => throw UnimplementedError(
    'sanctuaryBackupConfigProvider has no value. Override it at your root '
    'ProviderScope, e.g.:\n'
    "  sanctuaryBackupConfigProvider.overrideWithValue(const "
    "SanctuaryBackupConfig(\n"
    "    appId: 'myapp', aadContext: 'myapp-backup/v1', "
    "appDisplayName: 'MyApp'))",
  ),
);

/// Override this at your root [ProviderScope] with your app's
/// [BackupSerializer]. Throws by default so a missing override fails loud.
final backupSerializerProvider = Provider<BackupSerializer>(
  (_) => throw UnimplementedError(
    'backupSerializerProvider has no value. Override it at your root '
    'ProviderScope with your app-side BackupSerializer, e.g.:\n'
    '  backupSerializerProvider.overrideWith((ref) => '
    'MyAppBackupSerializer(ref.watch(databaseProvider)))',
  ),
);

/// The AEAD cipher used to seal/open OHBK blobs. Override in tests if needed.
final envelopeCipherProvider =
    Provider<EnvelopeCipher>((_) => EnvelopeCipher());

/// Where vault snapshots persist. Defaults to the platform store
/// (app-documents dir on io, OPFS on web), scoped by appId — on web all
/// fleet PWAs share one origin, so an unscoped vault dir would be shared
/// across apps. Tests override with `InMemoryVaultStore` from
/// `testing.dart`.
final vaultStoreProvider = Provider<VaultStore>((ref) =>
    createPlatformVaultStore(
        scope: ref.watch(sanctuaryBackupConfigProvider).appId));

/// The app's snapshot vault — generational keep-N backups behind every
/// restore (BACKUP_RETENTION_SPEC §2.A).
final backupVaultProvider = Provider<BackupVault>((ref) {
  final config = ref.watch(sanctuaryBackupConfigProvider);
  return BackupVault(
    ref.watch(vaultStoreProvider),
    appId: config.appId,
    keepN: config.vaultKeepN,
  );
});
