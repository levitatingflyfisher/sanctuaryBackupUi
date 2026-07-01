import 'dart:js_interop';
import 'dart:typed_data';

import 'backup_vault.dart';
import 'file_vault_store.dart';

// ── JS interop for the Origin Private File System (OPFS) ────────────────
// Mirrors the fleet's proven hand-rolled layer (PunctumTemporis
// lib/platform/file_storage_web.dart) — dart:js_interop only, no packages.

@JS('navigator.storage')
external _StorageManager get _storageManager;

extension type _StorageManager._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectory();
}

extension type _GetHandleOptions._(JSObject _) implements JSObject {
  external factory _GetHandleOptions({bool create});
}

extension type _RemoveEntryOptions._(JSObject _) implements JSObject {
  external factory _RemoveEntryOptions({bool recursive});
}

extension type _DirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectoryHandle(
      String name, _GetHandleOptions options);
  external JSPromise<_FileHandle> getFileHandle(
      String name, _GetHandleOptions options);
  external JSPromise<JSAny?> removeEntry(
      String name, _RemoveEntryOptions options);
  external _AsyncIterator<JSString> keys();
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external JSPromise<_WritableStream> createWritable();
  external JSPromise<_WebFile> getFile();
}

extension type _WritableStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny data);
  external JSPromise<JSAny?> close();
}

extension type _WebFile._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

// OPFS directory handles are async iterables; keys() gives the iterator
// protocol object directly in every OPFS implementation.
extension type _AsyncIterator<T extends JSAny>._(JSObject _)
    implements JSObject {
  external JSPromise<_IteratorResult<T>> next();
}

extension type _IteratorResult<T extends JSAny>._(JSObject _)
    implements JSObject {
  external bool get done;
  external T? get value;
}

/// The platform-default [VaultStore] for web builds: snapshots live in an
/// OPFS `sanctuary_vault_<scope>/` directory, riding the fleet's
/// `navigator.storage.persist()` precedent for eviction resistance. The
/// [scope] (appId) is LOAD-BEARING here: OPFS is origin-scoped and every
/// fleet PWA lives on one origin, so an unscoped dir would be a single
/// shared vault whose prune/auto-pin logic could destroy a sibling app's
/// snapshots. On a browser without usable OPFS every operation throws —
/// which the restore path treats as a failed mandatory snapshot
/// (fail-closed, with honest copy), exactly the design.
VaultStore createPlatformVaultStore({String scope = ''}) =>
    FileVaultStore(OpfsVaultFileApi(
        dirName:
            scope.isEmpty ? 'sanctuary_vault' : 'sanctuary_vault_$scope'));

/// The platform [VaultFileApi] under an OPFS `<dirName>/` directory. Apps
/// running a SECOND vault beside the sanctuary one (PunctumTemporis'
/// plaintext metadata snapshots) pass their own [dirName].
VaultFileApi createPlatformVaultFileApi(
        {String dirName = 'sanctuary_vault'}) =>
    OpfsVaultFileApi(dirName: dirName);

/// OPFS-backed [VaultFileApi] over a single flat directory.
class OpfsVaultFileApi implements VaultFileApi {
  final String _dirName;

  OpfsVaultFileApi({String dirName = 'sanctuary_vault'})
      : _dirName = dirName;

  Future<_DirectoryHandle> _dir({required bool create}) async {
    final root = await _storageManager.getDirectory().toDart;
    return root
        .getDirectoryHandle(_dirName, _GetHandleOptions(create: create))
        .toDart;
  }

  @override
  Future<List<String>> listFilenames() async {
    final _DirectoryHandle dir;
    try {
      dir = await _dir(create: false);
    } on Object {
      return const []; // vault dir not created yet
    }
    final names = <String>[];
    final iterator = dir.keys();
    while (true) {
      final result = await iterator.next().toDart;
      if (result.done) break;
      final value = result.value;
      if (value != null) names.add(value.toDart);
    }
    return names;
  }

  @override
  Future<Uint8List?> readFile(String name) async {
    try {
      final dir = await _dir(create: false);
      final handle = await dir
          .getFileHandle(name, _GetHandleOptions(create: false))
          .toDart;
      final file = await handle.getFile().toDart;
      final buffer = await file.arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    } on Object catch (e) {
      // Only a MISSING file/dir reads as absent (DOMException
      // NotFoundError). A real read failure (quota, NotReadableError)
      // must surface — mapping it to null would let the index rewrite
      // path mistake "unreadable" for "empty".
      final text = e.toString();
      if (text.contains('NotFoundError') || text.contains('not found')) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    final dir = await _dir(create: true);
    final handle =
        await dir.getFileHandle(name, _GetHandleOptions(create: true)).toDart;
    final writable = await handle.createWritable().toDart;
    await writable.write(bytes.toJS).toDart;
    await writable.close().toDart;
  }

  @override
  Future<void> deleteFile(String name) async {
    try {
      final dir = await _dir(create: false);
      await dir
          .removeEntry(name, _RemoveEntryOptions(recursive: false))
          .toDart;
    } on Object {
      // Deleting a missing file is a no-op by VaultFileApi contract.
    }
  }
}
