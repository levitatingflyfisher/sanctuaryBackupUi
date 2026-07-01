import 'dart:typed_data';

/// Why a snapshot exists — drives auto-protection and the list UI's wording.
enum VaultLabel {
  /// A copy of a manual export the user triggered.
  manual,

  /// The mandatory snapshot taken immediately before a restore ran.
  preRestore,

  /// A silent snapshot taken because the newest one had gone stale.
  freshness,
}

/// One stamped snapshot in the vault.
class VaultEntry {
  /// Unique id, also the stored filename:
  /// `<appId>-backup-<compact UTC stamp>.ohbk` (lexically sortable).
  final String id;

  /// When the snapshot was taken (UTC).
  final DateTime createdAt;

  final VaultLabel label;

  /// User-set pin: never auto-pruned, never touched by the vault itself.
  final bool pinned;

  /// Vault-managed protection for the newest pre-restore snapshot — the
  /// rollback must survive pruning while a mistaken restore is still
  /// undoable. Released automatically when a newer pre-restore snapshot
  /// replaces it (unlike [pinned], which only the user changes).
  final bool autoPinned;

  final int sizeBytes;

  const VaultEntry({
    required this.id,
    required this.createdAt,
    required this.label,
    required this.pinned,
    required this.autoPinned,
    required this.sizeBytes,
  });

  bool get protected => pinned || autoPinned;

  VaultEntry copyWith({bool? pinned, bool? autoPinned}) => VaultEntry(
        id: id,
        createdAt: createdAt,
        label: label,
        pinned: pinned ?? this.pinned,
        autoPinned: autoPinned ?? this.autoPinned,
        sizeBytes: sizeBytes,
      );
}

/// Storage seam for vault snapshots: entries (metadata) + blobs, keyed by
/// [VaultEntry.id]. Implementations: app-documents directory on native,
/// OPFS on web, in-memory for tests. The store is dumb — ordering,
/// stamping, pruning and pin policy all live in [BackupVault].
abstract class VaultStore {
  Future<List<VaultEntry>> list();

  Future<void> put(VaultEntry entry, Uint8List bytes);

  /// Metadata-only update (pin changes) — must not touch the blob.
  Future<void> update(VaultEntry entry);

  Future<Uint8List?> read(String id);

  Future<void> delete(String id);
}

/// An app-controlled store of stamped `.ohbk` snapshots with keep-N
/// retention — the generational safety net every restore leans on
/// (BACKUP_RETENTION_SPEC §2.A).
class BackupVault {
  final VaultStore _store;
  final String appId;

  /// How many UNPROTECTED snapshots to keep. Pinned/auto-pinned entries
  /// never prune and don't count toward this.
  final int keepN;

  /// Snapshot filename extension. `.ohbk` for encrypted sanctuary blobs;
  /// apps vaulting plaintext (PunctumTemporis' metadata.json snapshots)
  /// pass their honest extension instead.
  final String extension;

  final DateTime Function() _now;

  BackupVault(
    this._store, {
    required this.appId,
    int keepN = 10,
    this.extension = 'ohbk',
    DateTime Function()? now,
    // Floored at 1: keepN<=0 would let save() prune its own just-written
    // snapshot (and a negative value would throw from skip()).
  })  : keepN = keepN < 1 ? 1 : keepN,
        _now = now ?? DateTime.now;

  /// Stamps, stores and prunes. A [VaultLabel.preRestore] snapshot is
  /// auto-pinned (and releases the previous pre-restore auto-pin — at most
  /// one rollback window is protected at a time).
  Future<VaultEntry> save(
    Uint8List bytes, {
    required VaultLabel label,
    bool pinned = false,
  }) async {
    final createdAt = _now().toUtc();
    final entry = VaultEntry(
      id: await _freshId(createdAt),
      createdAt: createdAt,
      label: label,
      pinned: pinned,
      autoPinned: label == VaultLabel.preRestore,
      sizeBytes: bytes.length,
    );

    // Durability FIRST: the new snapshot must exist before the previous
    // rollback loses its protection. A failed put (disk full — the exact
    // case commitRestore fail-closes on) must leave the old auto-pin
    // intact, or the refusal path itself would destroy the only rollback.
    await _store.put(entry, bytes);

    if (label == VaultLabel.preRestore) {
      // The previous rollback window has passed; its snapshot becomes an
      // ordinary prune candidate. User pins are never touched.
      for (final old in await _store.list()) {
        if (old.id != entry.id &&
            old.autoPinned &&
            old.label == VaultLabel.preRestore) {
          await _store.update(old.copyWith(autoPinned: false));
        }
      }
    }

    await prune();
    return entry;
  }

  /// All snapshots, newest first.
  Future<List<VaultEntry>> list() async {
    final entries = await _store.list();
    entries.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      if (byTime != 0) return byTime;
      // Same-instant saves: a longer id carries a higher collision suffix
      // (`-2`, `-10`…), so it is the newer save; equal lengths compare
      // lexically (`-3` > `-2`).
      final byLength = b.id.length.compareTo(a.id.length);
      return byLength != 0 ? byLength : b.id.compareTo(a.id);
    });
    return entries;
  }

  Future<Uint8List?> read(String id) => _store.read(id);

  Future<void> delete(String id) => _store.delete(id);

  Future<void> setPinned(String id, bool pinned) async {
    for (final entry in await _store.list()) {
      if (entry.id == id) {
        await _store.update(entry.copyWith(pinned: pinned));
        return;
      }
    }
  }

  /// Deletes the oldest unprotected snapshots beyond [keepN].
  Future<void> prune() async {
    final unprotected =
        (await list()).where((e) => !e.protected).toList(); // newest first
    for (final victim in unprotected.skip(keepN)) {
      await _store.delete(victim.id);
    }
  }

  /// The silent staleness net: snapshots [exporter]'s bytes when the newest
  /// snapshot is older than [olderThan] (or the vault is empty). Any failure
  /// — typically "no key yet" — is swallowed: freshness is a background
  /// kindness, never a surfaced error. Returns whether a snapshot was taken.
  Future<bool> maybeFreshnessSnapshot(
    Future<Uint8List> Function() exporter, {
    Duration olderThan = const Duration(days: 7),
  }) async {
    try {
      final entries = await list();
      if (entries.isNotEmpty) {
        final age = _now().toUtc().difference(entries.first.createdAt);
        // A negative age means a future-stamped snapshot (clock damage) —
        // treat as stale, never as eternally fresh.
        if (age >= Duration.zero && age <= olderThan) return false;
      }
      await save(await exporter(), label: VaultLabel.freshness);
      return true;
    } on Object {
      return false;
    }
  }

  /// `<appId>-backup-<yyyyMMddTHHmmssSSSZ>.<extension>`, with a `-2`,
  /// `-3`… suffix if that exact stamp is already taken (two snapshots in
  /// the same millisecond).
  Future<String> _freshId(DateTime createdAt) async {
    final taken = (await _store.list()).map((e) => e.id).toSet();
    final stamp = _compactStamp(createdAt);
    var candidate = '$appId-backup-$stamp.$extension';
    var n = 2;
    while (taken.contains(candidate)) {
      candidate = '$appId-backup-$stamp-$n.$extension';
      n++;
    }
    return candidate;
  }

  /// Filesystem-safe (no colons), lexically sortable, millisecond-precise.
  static String _compactStamp(DateTime utc) {
    String pad(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${utc.year}${pad(utc.month)}${pad(utc.day)}'
        'T${pad(utc.hour)}${pad(utc.minute)}${pad(utc.second)}'
        '${pad(utc.millisecond, 3)}Z';
  }
}
