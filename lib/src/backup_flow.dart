import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_config.dart';
import 'backup_controller.dart';
import 'widgets/phrase_entry_dialog.dart';
import 'widgets/seed_phrase_modal.dart';

/// Reusable backup orchestration — seed setup, export, restore, and identity
/// reset — driving [BackupController], [SeedPhraseModal] and
/// [PhraseEntryDialog] with the config-driven copy.
///
/// [BackupSettingsSection] is a thin Material shell over this. Apps whose own
/// visual conventions clash with that Material section can build their own
/// tiles and call these methods directly:
///
/// ```dart
/// class MyBackupTile extends ConsumerWidget {
///   @override
///   Widget build(BuildContext context, WidgetRef ref) => ListTile(
///         title: const Text('Restore'),
///         onTap: () => const BackupFlow().runRestore(context, ref),
///       );
/// }
/// ```
///
/// [runRestore] handles the whole file-pick → destructive-confirm →
/// wrong-phrase → [PhraseEntryDialog] fallback → outcome-message flow that
/// would otherwise be copy-pasted into every native-tile app.
class BackupFlow {
  const BackupFlow();

  /// Generates a new seed phrase, shows it for the user to write down, then
  /// requires re-entry to prove the paper copy is correct.
  Future<void> runSeedSetup(BuildContext context, WidgetRef ref) async {
    final phrase =
        await ref.read(backupControllerProvider.notifier).generateSeedPhrase();
    if (phrase == null || !context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // The recovery words must be acknowledged via the button, not
      // barrier-dismissed or swiped away.
      isDismissible: false,
      enableDrag: false,
      builder: (_) => SeedPhraseModal(
        phrase: phrase,
        onAcknowledged: () {},
      ),
    );

    if (!context.mounted) return;
    await confirmPhraseReEntry(context, ref);
  }

  /// Loops the re-entry dialog until the typed words match the generated
  /// phrase (or the user backs out), converting the "I clicked got it" UX
  /// assertion into a cryptographic check.
  Future<void> confirmPhraseReEntry(
      BuildContext context, WidgetRef ref) async {
    while (context.mounted) {
      final reEntry = await PhraseEntryDialog.show(
        context,
        title: 'Re-enter your recovery words',
        body: 'Type the 12 words you just wrote down. This proves your '
            'paper copy is correct — without it, a typo could cost you all '
            'your data later.',
        confirmLabel: 'Confirm',
      );
      if (reEntry == null || !context.mounted) return;

      final ok = await ref
          .read(backupControllerProvider.notifier)
          .confirmSeedAcknowledged(reEntry);
      if (!context.mounted) return;
      if (ok) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Words didn't match. Check your paper copy and try again."),
        ),
      );
    }
  }

  /// Exports an encrypted backup blob (verified by read-back, vault copy
  /// stored) and hands it to the system share sheet, then reports the
  /// verification honestly.
  Future<void> runExport(BuildContext context, WidgetRef ref) async {
    final result =
        await ref.read(backupControllerProvider.notifier).exportBackup();
    if (result == null) {
      // An export that failed (including a failed verify-by-read-back)
      // must never look like "nothing happened".
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Backup failed — nothing was exported. Please try again.')));
      }
      return;
    }
    if (!context.mounted) return;

    // Bytes-only share so the web build stays clean (no dart:io File).
    await Share.shareXFiles([
      XFile.fromData(result.bytes,
          mimeType: 'application/octet-stream', name: result.filename),
    ]);

    if (!context.mounted) return;
    final items = result.manifest.tableCounts.values
        .fold<int>(0, (sum, n) => sum + n);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      // "Untested backups don't count": the count PROVES the read-back
      // (BACKUP_RETENTION_SPEC §2.C); the second sentence is the 3-2-1
      // nudge — copy, not a feature (§3).
      content: Text(items > 0
          ? 'Backed up and verified — $items items. Keep a copy somewhere '
              'off this device.'
          : 'Backed up and verified. Keep a copy somewhere off this device.'),
    ));
  }

  /// Shares all app data as plain, unencrypted JSON — exactly the
  /// serializer's own bytes, honestly labeled (BACKUP_RETENTION_SPEC §2.E:
  /// sovereignty means you can READ your data, not just recover it).
  Future<void> runPlaintextExport(BuildContext context, WidgetRef ref) async {
    final config = ref.read(sanctuaryBackupConfigProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Export unencrypted copy?'),
        content: Text(
          'This creates a plain JSON file of all your '
          '${config.appDisplayName} data. It is NOT encrypted — anyone with '
          'the file can read it. It is the copy any program can open.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Export unencrypted'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final Uint8List bytes;
    try {
      bytes = await ref.read(backupSerializerProvider).dumpAll();
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't read your data for export. Try again.")));
      return;
    }
    if (!context.mounted) return;

    final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
    await Share.shareXFiles([
      XFile.fromData(bytes,
          mimeType: 'application/json',
          name: '${config.appId}-data-$date-UNENCRYPTED.json'),
    ]);
  }

  /// Picks an `.ohbk` file and restores it — the full file-pick → confirm →
  /// wrong-phrase fallback → outcome flow.
  Future<void> runRestore(BuildContext context, WidgetRef ref) async {
    final blob = await _pickBackupFile();
    if (blob == null || !context.mounted) return;
    await restorePickedBlob(context, ref, blob);
  }

  /// Picks a backup file and returns its bytes, or null if the user cancelled.
  ///
  /// `withData` so we get bytes on every platform (no dart:io path handling,
  /// web-safe).
  Future<Uint8List?> _pickBackupFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (picked == null ||
        picked.files.isEmpty ||
        picked.files.first.bytes == null) {
      return null;
    }
    return picked.files.first.bytes!;
  }

  /// The restore orchestration once the backup bytes are in hand:
  /// decrypt-first prepare, wrong-phrase fallback, preview + confirm, then
  /// the committed restore (which takes the mandatory pre-restore
  /// snapshot). Split out from the file pick so the flow is testable
  /// without the file_picker plugin. Returns the final [RestoreOutcome],
  /// or null if the user cancelled at a dialog.
  Future<RestoreOutcome?> restorePickedBlob(
      BuildContext context, WidgetRef ref, Uint8List blob) async {
    final authState = await ref.read(authNotifierProvider.future);
    final hasKey = authState.masterEncryptionKey != null;
    if (!context.mounted) return null;

    final notifier = ref.read(backupControllerProvider.notifier);
    final config = ref.read(sanctuaryBackupConfigProvider);

    RestorePrep prep;
    // A restore prepared with typed words on a device that HAS its own key
    // seals the rollback under those typed words, not the device key — the
    // preview copy must say so instead of promising an unconditional
    // rollback.
    var foreignKey = false;
    if (hasKey) {
      prep = await notifier.prepareRestore(blob);

      // This device's key didn't unlock the backup (it was made under a
      // different phrase) — offer to enter the words it was created with,
      // BEFORE any destructive confirm for a blob we couldn't even open.
      if (prep.blocked == RestoreOutcome.wrongPhrase && context.mounted) {
        final phrase = await PhraseEntryDialog.show(
          context,
          title: "Enter the backup's recovery words",
          body: 'This backup was made with a different set of words than this '
              'device has. Enter the 12 words from when it was created.',
        );
        if (phrase == null || !context.mounted) return null;
        prep = await notifier.prepareRestoreWithPhrase(blob, phrase);
        foreignKey = prep.prepared != null;
      }
    } else {
      final phrase = await PhraseEntryDialog.show(context);
      if (phrase == null || !context.mounted) return null;
      prep = await notifier.prepareRestoreWithPhrase(blob, phrase);
    }
    if (!context.mounted) return prep.blocked;

    final prepared = prep.prepared;
    if (prepared == null) {
      final outcome = prep.blocked!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(restoreMessage(outcome, config))),
      );
      return outcome;
    }

    final confirm = await _confirmWithPreview(context, config, prepared,
        foreignKey: foreignKey);
    if (!confirm || !context.mounted) return null;

    final outcome = await notifier.commitRestore(prepared);
    if (!context.mounted) return outcome;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(restoreMessage(outcome, config))),
    );
    return outcome;
  }

  /// Maps a [RestoreOutcome] to a calm, specific user-facing message.
  String restoreMessage(RestoreOutcome outcome, SanctuaryBackupConfig config) =>
      switch (outcome) {
        RestoreOutcome.success => 'Data restored successfully.',
        RestoreOutcome.wrongPhrase =>
          "Those words didn't unlock this backup. Try the words from when it "
              'was made.',
        RestoreOutcome.corruptFile =>
          "This file looks damaged or isn't a ${config.appDisplayName} backup.",
        RestoreOutcome.tooNewBackup =>
          'This backup was made by a newer version of ${config.appDisplayName}. '
              'Update the app, then restore.',
        RestoreOutcome.noKey =>
          'Set up encrypted backup first, or enter your recovery words.',
        RestoreOutcome.snapshotFailed =>
          "Couldn't save a safety snapshot of your current data, so the "
              'restore was not started. This can happen when storage is '
              "full, or in a browser that can't keep app files.",
        RestoreOutcome.failed => 'Restore failed. Please try again.',
      };

  /// Confirms the danger-zone identity reset (wipes key material, keeps data).
  Future<void> runResetIdentity(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // Scroll title + content + actions together so the ~45-word body
        // survives large text scales (320 dp × 3.0) without a vertical
        // overflow — matching _confirmDestructive and PhraseEntryDialog.
        scrollable: true,
        title: const Text('Reset identity?'),
        content: const Text(
          'This will erase your recovery words from this device. '
          'Your data will NOT be deleted, but you won\'t be able to '
          'make encrypted backups until you set up a new phrase.\n\n'
          'Any existing backup files will only be recoverable with the '
          'old recovery words.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(backupControllerProvider.notifier).resetIdentity();
    }
  }

  /// The preview + confirm dialog (BACKUP_RETENTION_SPEC §2.D): what the
  /// backup contains and how old it is, what exists on this device now,
  /// the app's consequence copy, and the safety-net line — with the
  /// pre-restore snapshot, "cannot be undone" stopped being true, so the
  /// copy stopped saying it.
  Future<bool> _confirmWithPreview(BuildContext context,
      SanctuaryBackupConfig config, PreparedRestore prepared,
      {bool foreignKey = false}) async {
    // States the destructive-replace consequence plainly (SANCTUARY-BRIEF
    // §2.5). Apps may supply a more specific middle sentence via
    // [SanctuaryBackupConfig.restoreReplaceConsequence].
    final consequence = config.restoreReplaceConsequence ??
        'Restoring will permanently delete all current '
            '${config.appDisplayName} data on this device and replace it with '
            'the contents of the backup file.';
    final preview = _previewLines(prepared);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(config.confirmTitle),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (preview.isNotEmpty) ...[
              Text(preview.join('\n'),
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            Text(consequence),
            const SizedBox(height: 12),
            Text(
              foreignKey
                  ? 'A snapshot of your current data is saved to "Previous '
                      'backups" first, so you can roll back — opening it '
                      'will need the words you just entered.'
                  : 'A snapshot of your current data is saved to "Previous '
                      'backups" first, so you can roll back.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(config.confirmActionLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// "This backup: 12 days old" + one "table: N in backup · M here now"
  /// line per table. Empty when the manifest carries nothing usable.
  List<String> _previewLines(PreparedRestore prepared) {
    final lines = <String>[
      'This backup: '
          '${formatBackupAge(prepared.manifest.createdAt, DateTime.now())}',
    ];
    final current = prepared.currentTableCounts;
    for (final MapEntry(:key, :value)
        in prepared.manifest.tableCounts.entries) {
      final now = current == null ? '' : ' · ${current[key] ?? 0} here now';
      lines.add('$key: $value in backup$now');
    }
    return lines;
  }
}
