import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'backup_vault.dart';
import 'file_vault_store.dart';

/// The platform-default [VaultStore] for io platforms: snapshots live in
/// `<app documents>/sanctuary_vault_<scope>/` as one blob file per entry
/// plus an `index.json` carrying the metadata (label, pins, stamps).
///
/// [scope] (the appId) is part of the directory name because on web every
/// fleet PWA shares ONE origin — an unscoped OPFS dir would be one shared
/// vault whose prune/auto-pin logic could destroy a sibling app's
/// snapshots. Scoped on io too for symmetry (each app owns its documents
/// dir there, so it costs nothing).
VaultStore createPlatformVaultStore({String scope = ''}) =>
    FileVaultStore(createPlatformVaultFileApi(
        dirName: scope.isEmpty ? 'sanctuary_vault' : 'sanctuary_vault_$scope'));

/// The platform [VaultFileApi] under `<app documents>/<dirName>/`. Apps
/// running a SECOND vault beside the sanctuary one (PunctumTemporis'
/// plaintext metadata snapshots) pass their own [dirName].
VaultFileApi createPlatformVaultFileApi(
        {String dirName = 'sanctuary_vault'}) =>
    IoVaultFileApi(() async => Directory(
        '${(await getApplicationDocumentsDirectory()).path}/$dirName'));

/// Filesystem-backed [VaultFileApi]. The base directory is resolved lazily
/// on every operation — synchronous construction (provider-friendly),
/// tests point it at a temp dir, and no first-error caching (the drift
/// LazyDatabase brick precedent: a cached resolution failure must not
/// disable the vault for the whole session).
class IoVaultFileApi implements VaultFileApi {
  final Future<Directory> Function() _resolveBaseDir;

  IoVaultFileApi(this._resolveBaseDir);

  Future<Directory> _dir() async {
    final dir = await _resolveBaseDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<List<String>> listFilenames() async {
    final dir = await _dir();
    return dir
        .list()
        .where((e) => e is File)
        .map((e) => e.uri.pathSegments.last)
        .toList();
  }

  /// Monotonic suffix so concurrent writes never share a temp file.
  static int _tmpCounter = 0;

  @override
  Future<Uint8List?> readFile(String name) async {
    final file = File('${(await _dir()).path}/$name');
    try {
      return await file.readAsBytes();
    } on PathNotFoundException {
      // TOCTOU-safe: deleted between any existence check and the read
      // still honors the "null when missing" contract.
      return null;
    } on FileSystemException {
      if (!await file.exists()) return null;
      rethrow; // a REAL read failure must not masquerade as "absent"
    }
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    final dir = await _dir();
    // Write-then-rename so a crash mid-write never corrupts a snapshot or
    // the index (restic/Borg atomicity discipline at household scale).
    final tmp = File('${dir.path}/.$name.${_tmpCounter++}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename('${dir.path}/$name');
  }

  @override
  Future<void> deleteFile(String name) async {
    final file = File('${(await _dir()).path}/$name');
    if (await file.exists()) await file.delete();
  }
}
