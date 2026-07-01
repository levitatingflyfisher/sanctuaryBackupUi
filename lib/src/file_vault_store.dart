import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'backup_vault.dart';

/// The minimal file surface a [FileVaultStore] needs: one flat directory of
/// named files. Implementations: `dart:io` on native, OPFS on web,
/// in-memory in tests — all the retention logic stays platform-free above
/// this seam.
abstract class VaultFileApi {
  Future<List<String>> listFilenames();

  /// Returns null when the file doesn't exist.
  Future<Uint8List?> readFile(String name);

  Future<void> writeFile(String name, Uint8List bytes);

  /// Deleting a missing file is a no-op, never an error.
  Future<void> deleteFile(String name);
}

/// [VaultStore] over a flat directory: one blob file per snapshot plus an
/// `index.json` carrying the metadata (label, pins, stamps).
///
/// The index is a cache, not the truth — the blob files are. A corrupt or
/// missing index self-heals by rebuilding entries from the stamp-named
/// blob files, and recovered entries come back PINNED: losing a pin is
/// annoying, losing a snapshot is the thing this whole spec exists to
/// prevent — and prune() would otherwise convert stripped pins straight
/// into deletions. Index mutations are serialized on one queue and always
/// rewrite the FULL recovered view, so a transiently unreadable index (or
/// interleaved saves — the fire-and-forget freshness snapshot racing a
/// user restore) can never persist an emptied index.
class FileVaultStore implements VaultStore {
  static const _indexFile = 'index.json';

  final VaultFileApi _files;

  FileVaultStore(this._files);

  /// Mutation queue: every index read-modify-write runs alone.
  Future<void> _tail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// A vault blob is stamp-named (`…-backup-<compact UTC stamp>…`) —
  /// extension-agnostic, since apps vault plaintext snapshots too. The
  /// filter exists to skip the index, `.part` write temps and any foreign
  /// file a user drops in the directory.
  static final _blobName = RegExp(r'-backup-\d{8}T\d{9}Z');

  @override
  Future<List<VaultEntry>> list() => _serialized(_listInner);

  Future<List<VaultEntry>> _listInner() async {
    final index = await _readIndex();
    final blobNames = (await _files.listFilenames())
        .where((n) =>
            n != _indexFile &&
            !n.endsWith('.part') &&
            _blobName.hasMatch(n))
        .toSet();

    final entries = <VaultEntry>[];
    for (final name in blobNames) {
      final indexed = index[name];
      if (indexed != null) {
        entries.add(indexed);
      } else {
        // Orphan blob: index write was lost or corrupted. Recover it
        // PROTECTED (pinned) with safe defaults — see the class doc.
        final bytes = await _files.readFile(name);
        if (bytes == null) continue; // vanished between list and read
        entries.add(VaultEntry(
          id: name,
          createdAt: _stampFromId(name) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          label: VaultLabel.manual,
          pinned: true,
          autoPinned: false,
          sizeBytes: bytes.length,
        ));
      }
    }
    return entries;
  }

  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) =>
      _serialized(() async {
        // Blob first, index second: a crash in between leaves an orphan
        // blob that list() recovers, never an index entry pointing at
        // nothing.
        await _files.writeFile(entry.id, bytes);
        await _rewriteIndex((view) => view..[entry.id] = entry);
      });

  @override
  Future<void> update(VaultEntry entry) => _serialized(
      () => _rewriteIndex((view) => view..[entry.id] = entry));

  @override
  Future<Uint8List?> read(String id) => _files.readFile(id);

  @override
  Future<void> delete(String id) => _serialized(() async {
        await _files.deleteFile(id);
        await _rewriteIndex((view) => view..remove(id));
      });

  /// Rewrites the index from the FULL current view (index entries plus
  /// recovered orphans), mutated by [change]. This is what makes a
  /// transiently unreadable index non-fatal: the blobs on disk re-seed the
  /// view, so the rewrite can never persist "only the entry I just
  /// touched".
  Future<void> _rewriteIndex(
      Map<String, VaultEntry> Function(Map<String, VaultEntry>)
          change) async {
    final view = {
      for (final entry in await _listInner()) entry.id: entry,
    };
    await _writeIndex(change(view));
  }

  Future<Map<String, VaultEntry>> _readIndex() async {
    final bytes = await _files.readFile(_indexFile);
    if (bytes == null) return {};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, VaultEntry>{};
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (value is! Map<String, dynamic>) continue;
        final entry = _entryFromJson(key, value);
        if (entry != null) result[key] = entry;
      }
      return result;
    } on Object {
      // Corrupt index — self-heal from the blob files (see class doc).
      return {};
    }
  }

  Future<void> _writeIndex(Map<String, VaultEntry> index) async {
    final json = {
      for (final MapEntry(:key, :value) in index.entries)
        key: {
          'createdAt': value.createdAt.toIso8601String(),
          'label': value.label.name,
          'pinned': value.pinned,
          'autoPinned': value.autoPinned,
          'sizeBytes': value.sizeBytes,
        },
    };
    await _files.writeFile(
        _indexFile, Uint8List.fromList(utf8.encode(jsonEncode(json))));
  }

  VaultEntry? _entryFromJson(String id, Map<String, dynamic> json) {
    final createdAtRaw = json['createdAt'];
    final createdAt =
        createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null;
    if (createdAt == null) return null;
    return VaultEntry(
      id: id,
      createdAt: createdAt.toUtc(),
      label: VaultLabel.values.asNameMap()[json['label']] ??
          VaultLabel.manual,
      pinned: json['pinned'] == true,
      autoPinned: json['autoPinned'] == true,
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
    );
  }

  /// Recovers the UTC stamp from a `<appId>-backup-<stamp>[-n].ohbk`
  /// filename; null when the name doesn't carry one.
  static DateTime? _stampFromId(String id) {
    final match = RegExp(r'-backup-(\d{8})T(\d{9})Z').firstMatch(id);
    if (match == null) return null;
    final d = match.group(1)!, t = match.group(2)!;
    return DateTime.utc(
      int.parse(d.substring(0, 4)),
      int.parse(d.substring(4, 6)),
      int.parse(d.substring(6, 8)),
      int.parse(t.substring(0, 2)),
      int.parse(t.substring(2, 4)),
      int.parse(t.substring(4, 6)),
      int.parse(t.substring(6, 9)),
    );
  }
}
