import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

VaultEntry _entry(
  String id, {
  DateTime? createdAt,
  VaultLabel label = VaultLabel.manual,
  bool pinned = false,
  bool autoPinned = false,
}) =>
    VaultEntry(
      id: id,
      createdAt: createdAt ?? DateTime.utc(2026, 7, 16, 9, 30, 15, 123),
      label: label,
      pinned: pinned,
      autoPinned: autoPinned,
      sizeBytes: 3,
    );

void main() {
  group('FileVaultStore over an in-memory file api', () {
    late InMemoryVaultFileApi files;
    FileVaultStore store() => FileVaultStore(files);

    setUp(() => files = InMemoryVaultFileApi());

    test('put / list / read round-trips entry metadata and bytes', () async {
      final s = store();
      final entry = _entry(
        'sundial-backup-20260716T093015123Z.ohbk',
        label: VaultLabel.preRestore,
        autoPinned: true,
      );
      await s.put(entry, Uint8List.fromList([1, 2, 3]));

      final listed = await s.list();
      expect(listed, hasLength(1));
      expect(listed.single.id, entry.id);
      expect(listed.single.createdAt, entry.createdAt);
      expect(listed.single.label, VaultLabel.preRestore);
      expect(listed.single.autoPinned, isTrue);
      expect(listed.single.pinned, isFalse);
      expect(listed.single.sizeBytes, 3);
      expect(await s.read(entry.id), Uint8List.fromList([1, 2, 3]));
    });

    test('update changes metadata without touching the blob', () async {
      final s = store();
      final entry = _entry('a-backup-20260716T093015123Z.ohbk');
      await s.put(entry, Uint8List.fromList([9]));
      await s.update(entry.copyWith(pinned: true));
      expect((await s.list()).single.pinned, isTrue);
      expect(await s.read(entry.id), Uint8List.fromList([9]));
    });

    test('delete removes entry and blob', () async {
      final s = store();
      final entry = _entry('a-backup-20260716T093015123Z.ohbk');
      await s.put(entry, Uint8List.fromList([9]));
      await s.delete(entry.id);
      expect(await s.list(), isEmpty);
      expect(await s.read(entry.id), isNull);
    });

    test('persists across store instances sharing the same files', () async {
      await store().put(
          _entry('a-backup-20260716T093015123Z.ohbk', pinned: true),
          Uint8List.fromList([7]));
      final second = store();
      expect((await second.list()).single.pinned, isTrue);
      expect(await second.read('a-backup-20260716T093015123Z.ohbk'),
          Uint8List.fromList([7]));
    });

    test(
        'a CORRUPT index self-heals: entries rebuild from the blob files '
        'with stamps parsed from filenames — and REVIEW FIX: recovered '
        'entries come back PINNED, because prune() would otherwise convert '
        'pin loss into the snapshot loss this class exists to prevent',
        () async {
      final s = store();
      await s.put(
          _entry('sundial-backup-20260716T093015123Z.ohbk', pinned: true),
          Uint8List.fromList([1]));
      await files.writeFile(
          'index.json', Uint8List.fromList(utf8.encode('{not json')));

      final listed = await store().list();
      expect(listed, hasLength(1));
      expect(listed.single.id, 'sundial-backup-20260716T093015123Z.ohbk');
      expect(listed.single.createdAt, DateTime.utc(2026, 7, 16, 9, 30, 15, 123),
          reason: 'stamp must be recovered from the filename');
      expect(listed.single.label, VaultLabel.manual);
      expect(listed.single.pinned, isTrue,
          reason: 'recovered entries are protected until the user acts');
      expect(await store().read(listed.single.id), Uint8List.fromList([1]));
    });

    test(
        'REVIEW FIX: put() after an index wipe re-persists the recovered '
        'entries instead of writing an index containing only the new one',
        () async {
      final s = store();
      await s.put(_entry('a-backup-20260716T093015123Z.ohbk'),
          Uint8List.fromList([1]));
      await files.deleteFile('index.json'); // transient loss / unreadable

      await s.put(
          _entry('b-backup-20260716T093015124Z.ohbk'),
          Uint8List.fromList([2]));

      // A fresh store (reading only the rewritten index + blobs) must still
      // know BOTH entries.
      final listed = await store().list();
      expect(listed.map((e) => e.id).toSet(), {
        'a-backup-20260716T093015123Z.ohbk',
        'b-backup-20260716T093015124Z.ohbk',
      });
    });

    test(
        'REVIEW FIX: concurrent saves do not lose index entries '
        '(read-modify-write is serialized)', () async {
      final s = store();
      await Future.wait([
        for (var i = 0; i < 6; i++)
          s.put(
              _entry('c$i-backup-20260716T09301512${i}Z.ohbk'),
              Uint8List.fromList([i])),
      ]);
      expect((await store().list()), hasLength(6),
          reason: 'every interleaved put must survive in the index');
    });

    test('an orphan blob file (missing from the index) is listed', () async {
      final s = store();
      await s.put(_entry('a-backup-20260716T093015123Z.ohbk'),
          Uint8List.fromList([1]));
      await files.writeFile(
          'a-backup-20260101T000000000Z.ohbk', Uint8List.fromList([2, 2]));

      final ids = (await s.list()).map((e) => e.id).toSet();
      expect(ids, contains('a-backup-20260101T000000000Z.ohbk'));
      final orphan = (await s.list())
          .singleWhere((e) => e.id == 'a-backup-20260101T000000000Z.ohbk');
      expect(orphan.createdAt, DateTime.utc(2026, 1, 1));
      expect(orphan.sizeBytes, 2);
    });

    test('an index entry whose blob vanished is dropped from list', () async {
      final s = store();
      await s.put(_entry('a-backup-20260716T093015123Z.ohbk'),
          Uint8List.fromList([1]));
      await files.deleteFile('a-backup-20260716T093015123Z.ohbk');
      expect(await s.list(), isEmpty);
    });

    test(
        'orphan recovery accepts any stamp-named blob (any extension) but '
        'ignores foreign files and .part temps', () async {
      await files.writeFile('notes.txt', Uint8List.fromList([1]));
      await files.writeFile(
          '.a-backup-20260101T000000000Z.json.part', Uint8List.fromList([1]));
      await files.writeFile(
          'punctum-backup-20260101T000000000Z.json', Uint8List.fromList([2]));
      final listed = await store().list();
      expect(listed.map((e) => e.id).toList(),
          ['punctum-backup-20260101T000000000Z.json']);
      expect(listed.single.createdAt, DateTime.utc(2026, 1, 1));
    });
  });

  group('IoVaultFileApi (temp dir integration)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vault_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('writes, lists, reads and deletes files; auto-creates the dir',
        () async {
      final api =
          IoVaultFileApi(() async => Directory('${tmp.path}/nested/vault'));
      await api.writeFile('a.ohbk', Uint8List.fromList([1, 2]));
      expect(await api.listFilenames(), ['a.ohbk']);
      expect(await api.readFile('a.ohbk'), Uint8List.fromList([1, 2]));
      expect(await api.readFile('missing.ohbk'), isNull);
      await api.deleteFile('a.ohbk');
      expect(await api.listFilenames(), isEmpty);
      // Deleting a missing file is a no-op, not an error.
      await api.deleteFile('missing.ohbk');
    });

    test('full FileVaultStore round-trip on the real filesystem', () async {
      final api = IoVaultFileApi(() async => tmp);
      final s = FileVaultStore(api);
      await s.put(
          _entry('sundial-backup-20260716T093015123Z.ohbk',
              label: VaultLabel.freshness),
          Uint8List.fromList([4, 5, 6]));
      final fresh = FileVaultStore(IoVaultFileApi(() async => tmp));
      final listed = await fresh.list();
      expect(listed.single.label, VaultLabel.freshness);
      expect(await fresh.read(listed.single.id), Uint8List.fromList([4, 5, 6]));
    });
  });
}
