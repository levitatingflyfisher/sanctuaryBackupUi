/// Drop-in encrypted-backup UI for OpenHearth apps, built on
/// `sanctuary_auth_core`.
///
/// Three integration steps (see the README):
///   1. Implement [BackupSerializer] over your store and override
///      [backupSerializerProvider].
///   2. Override [sanctuaryBackupConfigProvider] with your app's
///      [SanctuaryBackupConfig] at the root `ProviderScope` (and, for apps
///      wanting isolated key material, `sanctuaryAppDomainProvider` from
///      `sanctuary_auth_core`).
///   3. Drop `BackupSettingsSection` into your settings screen.
///
/// Test-support fakes live in `package:sanctuary_backup_ui/testing.dart`.
library;

export 'src/backup_serializer.dart';
export 'src/backup_envelope.dart';
export 'src/backup_vault.dart';
export 'src/file_vault_store.dart';
export 'src/vault_store_platform.dart';
export 'src/backup_config.dart';
export 'src/backup_repository.dart';
export 'src/backup_controller.dart';
export 'src/backup_flow.dart';
export 'src/widgets/backup_settings_section.dart';
export 'src/widgets/backup_vault_sheet.dart';
export 'src/widgets/seed_phrase_modal.dart';
export 'src/widgets/phrase_entry_dialog.dart';
