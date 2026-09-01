import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup_flow.dart';
import '../backup_setup_status.dart';

/// A one-line "Finish setup" reminder with Set up and Dismiss, for a home
/// screen or the top of settings. Shows only while
/// [BackupSetupStatus.showReminder] is true; otherwise (and while the
/// status loads or fails) it takes no space — it is an item in a list, not
/// a heading, so there is nothing to leave stranded.
///
/// Set up runs [BackupFlow.runSeedSetup], or [BackupFlow.confirmPhraseReEntry]
/// when words exist but are unchecked; pass [onSetUp] to route elsewhere
/// (e.g. to your settings screen) instead.
class BackupSetupReminder extends ConsumerWidget {
  const BackupSetupReminder({super.key, this.onSetUp});

  final VoidCallback? onSetUp;

  static const _flow = BackupFlow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(backupSetupStatusProvider).valueOrNull;
    if (status == null || !status.showReminder(DateTime.now())) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final message = status.hasWords
        ? 'Finish backup setup: check your recovery words.'
        : "Backup isn't set up. Your data is only on this device.";

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
            ],
          ),
          // Wrap, so the two buttons stack rather than overflow at large
          // text sizes.
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => dismissBackupSetupReminder(ref),
                  child: const Text('Dismiss'),
                ),
                FilledButton.tonal(
                  onPressed: onSetUp ??
                      () => status.hasWords
                          ? _flow.confirmPhraseReEntry(context, ref)
                          : _flow.runSeedSetup(context, ref),
                  child: const Text('Set up'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
