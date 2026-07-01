import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../backup_config.dart';
import '../backup_controller.dart';
import '../backup_flow.dart';
import '../backup_vault.dart';

/// Opens the "Previous backups" sheet: the app's snapshot vault —
/// generational backups behind every restore (BACKUP_RETENTION_SPEC §2.A).
Future<void> showBackupVaultSheet(BuildContext context) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const BackupVaultSheet(),
    );

/// Human-readable snapshot size: `3 B`, `12 KB`, `1.2 MB`.
String formatSnapshotSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).round()} KB';
  return '${(bytes / (1000 * 1000)).toStringAsFixed(1)} MB';
}

/// The vault management list: preview via restore, pin, delete. Restores
/// route through [BackupFlow.restorePickedBlob], so a snapshot restore
/// gets the exact same preview + confirm + mandatory-snapshot treatment
/// as a picked file.
class BackupVaultSheet extends ConsumerStatefulWidget {
  const BackupVaultSheet({super.key});

  @override
  ConsumerState<BackupVaultSheet> createState() => _BackupVaultSheetState();
}

class _BackupVaultSheetState extends ConsumerState<BackupVaultSheet> {
  late Future<List<VaultEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<List<VaultEntry>> _load() => ref.read(backupVaultProvider).list();

  void _refresh() {
    if (!mounted) return; // menu actions outlive a dismissed sheet
    final next = _load();
    // Braces, not an arrow: an arrow closure would RETURN the assigned
    // Future and trip setState's returned-a-Future assertion.
    setState(() {
      _entries = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<VaultEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          final entries = snapshot.data;
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('Previous backups',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (snapshot.hasError)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          "Couldn't read the snapshots on this device. "
                          'This can happen in a browser that blocks app '
                          'file storage.'),
                      const SizedBox(height: 8),
                      TextButton(
                          onPressed: _refresh, child: const Text('Retry')),
                    ],
                  ),
                )
              else if (entries == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: Text(
                    'No snapshots yet. One is saved automatically before '
                    'every restore, and with every encrypted export when '
                    'there is room.',
                  ),
                )
              else
                for (final entry in entries) _EntryTile(entry, _refresh),
            ],
          );
        },
      ),
    );
  }
}

class _EntryTile extends ConsumerWidget {
  const _EntryTile(this.entry, this.onChanged);

  final VaultEntry entry;
  final VoidCallback onChanged;

  static const _flow = BackupFlow();

  String get _labelText => switch (entry.label) {
        VaultLabel.manual => 'Manual backup',
        VaultLabel.preRestore => 'Safety snapshot',
        VaultLabel.freshness => 'Automatic backup',
      };

  IconData get _icon => switch (entry.label) {
        VaultLabel.manual => Icons.archive_outlined,
        VaultLabel.preRestore => Icons.history,
        VaultLabel.freshness => Icons.schedule,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = DateFormat.yMMMd().format(entry.createdAt.toLocal());
    final age = formatBackupAge(entry.createdAt, DateTime.now());
    return ListTile(
      leading: Icon(_icon),
      title: Text('$date · $age'),
      subtitle:
          Text('$_labelText · ${formatSnapshotSize(entry.sizeBytes)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.pinned || entry.autoPinned)
            const Icon(Icons.push_pin, size: 18),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (action) => switch (action) {
              'restore' => _restore(context, ref),
              'pin' => _togglePin(ref),
              'delete' => _delete(context, ref),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'restore', child: Text('Restore')),
              PopupMenuItem(
                  value: 'pin',
                  child: Text(entry.pinned ? 'Unpin' : 'Pin')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final bytes = await ref.read(backupVaultProvider).read(entry.id);
    if (!context.mounted) return;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This snapshot file is missing from the vault.')));
      onChanged();
      return;
    }
    await _flow.restorePickedBlob(context, ref, bytes);
    onChanged(); // a successful restore added a new pre-restore snapshot
  }

  Future<void> _togglePin(WidgetRef ref) async {
    await ref.read(backupVaultProvider).setPinned(entry.id, !entry.pinned);
    onChanged();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    // Deleting the auto-pinned rollback deserves its own words: it is the
    // undo for the most recent restore, not just another snapshot.
    final consequence = entry.autoPinned
        ? 'This is the safety snapshot from your most recent restore — '
            'deleting it removes that undo. Backup files you exported '
            'elsewhere are not affected.'
        : 'This removes the snapshot from ${entry.pinned ? 'the vault — '
            'it is currently pinned' : 'this device'}. Backup files you '
            'exported elsewhere are not affected.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete snapshot?'),
        content: Text(consequence),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(backupVaultProvider).delete(entry.id);
    onChanged();
  }
}
