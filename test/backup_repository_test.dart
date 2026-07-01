import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

Uint8List _key(int fill) => Uint8List(32)..fillRange(0, 32, fill);

/// A serializer whose [restoreAll] always throws a future-schema error.
class _SchemaThrowingSerializer implements BackupSerializer {
  @override
  Future<Uint8List> dumpAll() async => Uint8List(0);
  @override
  Future<void> restoreAll(Uint8List plaintext) async =>
      throw const BackupSchemaException(99, 1);
}

void main() {
  final cipher = EnvelopeCipher();
  final payload = Uint8List.fromList(
      utf8.encode('{"app":"lullaby","schemaVersion":4,"tables":{"babies":[]}}'));

  test('export produces an OHBK blob and restore round-trips the payload',
      () async {
    final src = FakeBackupSerializer(payload);
    final dst = FakeBackupSerializer();
    final out =
        BackupRepository(src, cipher, aadContext: 'lullaby-backup/v1');
    final into =
        BackupRepository(dst, cipher, aadContext: 'lullaby-backup/v1');

    final blob = await out.export(_key(9));
    expect(blob.sublist(0, 4), equals([0x4F, 0x48, 0x42, 0x4B])); // "OHBK"

    await into.restore(blob, _key(9));
    expect(dst.restored, equals(payload));
  });

  test('a wrong key throws CryptoException', () async {
    final repo = BackupRepository(FakeBackupSerializer(), cipher,
        aadContext: 'lullaby-backup/v1');
    final blob = await repo.export(_key(1));

    final other = BackupRepository(FakeBackupSerializer(), cipher,
        aadContext: 'lullaby-backup/v1');
    expect(() => other.restore(blob, _key(2)),
        throwsA(isA<CryptoException>()));
  });

  test('a blob bound to a different aadContext cannot be restored', () async {
    // §2.3: a blob can never cross apps/paths — the AEAD context binds it.
    final appA = BackupRepository(FakeBackupSerializer(), cipher,
        aadContext: 'appA-backup/v1');
    final blob = await appA.export(_key(5));

    final appB = BackupRepository(FakeBackupSerializer(), cipher,
        aadContext: 'appB-backup/v1');
    expect(() => appB.restore(blob, _key(5)),
        throwsA(isA<CryptoException>()));
  });

  test('a truncated blob throws BackupFormatException', () async {
    final repo = BackupRepository(FakeBackupSerializer(), cipher,
        aadContext: 'lullaby-backup/v1');
    final blob = await repo.export(_key(1));

    expect(() => repo.restore(Uint8List.sublistView(blob, 0, 10), _key(1)),
        throwsA(isA<BackupFormatException>()));
  });

  test('a BackupSchemaException from the serializer propagates', () async {
    final blob = await BackupRepository(FakeBackupSerializer(), cipher,
            aadContext: 'lullaby-backup/v1')
        .export(_key(3));

    final repo = BackupRepository(_SchemaThrowingSerializer(), cipher,
        aadContext: 'lullaby-backup/v1');
    expect(() => repo.restore(blob, _key(3)),
        throwsA(isA<BackupSchemaException>()));
  });
}
