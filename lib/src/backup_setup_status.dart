import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'app_scoped_key_store.dart';
import 'backup_config.dart';

/// Where backup setup stands on this device, for a "Finish setup" reminder
/// (operator ruling 48: open into the task; keep a persistent, dismissable
/// item so unfinished setup is never forgotten).
class BackupSetupStatus {
  const BackupSetupStatus({
    required this.hasWords,
    required this.wordsConfirmed,
    this.lastBackupAt,
    this.reminderDismissedAt,
  });

  /// How long a dismissal hides the reminder before it comes back. A
  /// dismissal is "not now", not "never": unfinished setup is the one state
  /// in which a lost phone loses everything.
  static const reminderSnooze = Duration(days: 30);

  /// Recovery words exist on this device.
  final bool hasWords;

  /// The user has checked their paper copy of the words.
  final bool wordsConfirmed;

  /// When the last encrypted backup was exported, if ever.
  final DateTime? lastBackupAt;

  /// When the user last dismissed the reminder, if ever.
  final DateTime? reminderDismissedAt;

  bool get setupFinished => hasWords && wordsConfirmed;

  /// Whether the reminder should show at [now]: setup unfinished, and not
  /// dismissed within [reminderSnooze].
  bool showReminder(DateTime now) {
    if (setupFinished) return false;
    final dismissed = reminderDismissedAt;
    return dismissed == null ||
        now.toUtc().difference(dismissed.toUtc()) >= reminderSnooze;
  }
}

/// Persists when the "Finish setup" reminder was dismissed.
abstract interface class BackupReminderStore {
  Future<DateTime?> readDismissedAt();
  Future<void> writeDismissedAt(DateTime at);
}

/// Default [BackupReminderStore] over [SecretStorage], under
/// `oh_<appId>_setup_reminder_dismissed_v1` (namespaced like the key store,
/// since web PWAs share one origin). Failures read as "never dismissed" and
/// writes that fail are dropped: a reminder that shows again is harmless.
class SecretStorageReminderStore implements BackupReminderStore {
  SecretStorageReminderStore({
    required String appId,
    SecretStorage storage = const FlutterSecretStorage(),
  })  : _key = 'oh_${appId}_setup_reminder_dismissed_v1',
        _storage = storage;

  final String _key;
  final SecretStorage _storage;

  @override
  Future<DateTime?> readDismissedAt() async {
    try {
      final raw = await _storage.read(_key);
      return raw == null ? null : DateTime.tryParse(raw);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeDismissedAt(DateTime at) async {
    try {
      await _storage.write(_key, at.toUtc().toIso8601String());
    } on Object {
      // See class doc.
    }
  }
}

/// The app's [BackupReminderStore]. Override in tests with
/// `InMemoryBackupReminderStore` from `testing.dart`.
final backupReminderStoreProvider = Provider<BackupReminderStore>((ref) =>
    SecretStorageReminderStore(
        appId: ref.watch(sanctuaryBackupConfigProvider).appId));

/// This device's [BackupSetupStatus]; follows the auth state, so it updates
/// as soon as words are stored or confirmed.
final backupSetupStatusProvider =
    FutureProvider<BackupSetupStatus>((ref) async {
  final auth = await ref.watch(authNotifierProvider.future);
  final dismissed =
      await ref.watch(backupReminderStoreProvider).readDismissedAt();
  return BackupSetupStatus(
    hasWords: auth.masterEncryptionKey != null,
    wordsConfirmed: auth.seedAcknowledged,
    lastBackupAt: auth.lastBackupAt,
    reminderDismissedAt: dismissed,
  );
});

/// Records a dismissal of the reminder now and refreshes the status.
Future<void> dismissBackupSetupReminder(WidgetRef ref) async {
  await ref.read(backupReminderStoreProvider).writeDismissedAt(DateTime.now());
  ref.invalidate(backupSetupStatusProvider);
}
