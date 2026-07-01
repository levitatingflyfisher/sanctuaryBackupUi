import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import '../backup_controller.dart';
import '../backup_flow.dart';
import 'backup_vault_sheet.dart';

/// A settings section for encrypted backup: seed phrase setup, export, restore,
/// and identity reset.
///
/// Drop this into your Settings screen's `ListView`. It is app-agnostic: colours
/// and type come from [Theme.of]; app-specific copy comes from
/// [sanctuaryBackupConfigProvider].
///
/// This is a thin Material shell over [BackupFlow]. Apps whose visual
/// conventions clash with this Material list should build their own tiles and
/// call [BackupFlow] directly — see the README's "native-tile apps" section.
class BackupSettingsSection extends ConsumerWidget {
  const BackupSettingsSection({super.key});

  static const _flow = BackupFlow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authNotifierProvider);
    final backupState = ref.watch(backupControllerProvider);
    final isLoading = backupState is AsyncLoading;

    return authAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SizedBox.shrink(),
      data: (authState) {
        final hasKey = authState.masterEncryptionKey != null;
        final seedAcked = authState.seedAcknowledged;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Encrypted Backup',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ),

            // Set up seed phrase (only if no key yet)
            if (!hasKey)
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Set up encrypted backup'),
                subtitle: const Text(
                  'Generate 12 recovery words to protect your data',
                ),
                enabled: !isLoading,
                onTap: () => _flow.runSeedSetup(context, ref),
              ),

            // Mid-setup recovery: key exists but acknowledgement was never
            // completed (user dismissed the re-entry dialog). Without this
            // tile the user has no way forward except "Reset identity" since
            // Export is hidden until seedAcked=true.
            if (hasKey && !seedAcked)
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('Complete backup setup'),
                subtitle: const Text(
                  'Re-enter your recovery words to finish setup',
                ),
                enabled: !isLoading,
                onTap: () => _flow.confirmPhraseReEntry(context, ref),
              ),

            // Export (available after seed acknowledged)
            if (hasKey && seedAcked)
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Export backup'),
                subtitle: authState.lastBackupAt != null
                    ? Text(
                        'Last backup: ${_formatDate(authState.lastBackupAt!)}')
                    : const Text('Save an encrypted copy of all your data'),
                enabled: !isLoading,
                onTap: () => _flow.runExport(context, ref),
              ),

            // Restore (always available)
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Restore from backup'),
              subtitle: const Text('Load data from an .ohbk file'),
              enabled: !isLoading,
              onTap: () => _flow.runRestore(context, ref),
            ),

            // The snapshot vault (always available: restores and exports
            // populate it regardless of auth state).
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Previous backups'),
              subtitle: const Text(
                  'Snapshots kept on this device — restore or pin them'),
              enabled: !isLoading,
              onTap: () => showBackupVaultSheet(context),
            ),

            // Plaintext export (needs no key: sovereignty means you can
            // READ your data, not just recover it).
            ListTile(
              leading: const Icon(Icons.data_object),
              title: const Text('Export as plain JSON'),
              subtitle: const Text('Unencrypted — readable by any program'),
              enabled: !isLoading,
              onTap: () => _flow.runPlaintextExport(context, ref),
            ),

            // Reset identity (danger zone, only if key exists)
            if (hasKey)
              ListTile(
                leading: Icon(Icons.delete_forever,
                    color: Theme.of(context).colorScheme.error),
                title: Text('Reset identity',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
                subtitle: const Text('Wipes recovery words (keeps your data)'),
                enabled: !isLoading,
                onTap: () => _flow.runResetIdentity(context, ref),
              ),

            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        );
      },
    );
  }

  String _formatDate(DateTime dt) {
    final d = dt.toLocal();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
