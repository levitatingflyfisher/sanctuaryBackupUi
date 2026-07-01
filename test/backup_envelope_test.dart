import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

Uint8List _bytes(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  group('BackupEnvelope.wrap', () {
    test('emits app, schemaVersion, createdAt (UTC ISO8601) and payload', () {
      final out = BackupEnvelope.wrap(
        appId: 'sundial',
        schemaVersion: 4,
        createdAt: DateTime.utc(2026, 7, 16, 9, 30, 15),
        payload: {
          'sessions': [1, 2, 3]
        },
      );
      final json = jsonDecode(utf8.decode(out)) as Map<String, dynamic>;
      expect(json['app'], 'sundial');
      expect(json['schemaVersion'], 4);
      expect(json['createdAt'], '2026-07-16T09:30:15.000Z');
      expect(json['payload'], {
        'sessions': [1, 2, 3]
      });
    });

    test('normalizes a local-time createdAt to UTC', () {
      final local = DateTime(2026, 7, 16, 9, 30, 15);
      final out = BackupEnvelope.wrap(
        appId: 'sundial',
        schemaVersion: 1,
        createdAt: local,
        payload: const {},
      );
      final json = jsonDecode(utf8.decode(out)) as Map<String, dynamic>;
      expect((json['createdAt'] as String).endsWith('Z'), isTrue,
          reason: 'createdAt must always be stored as UTC');
      expect(DateTime.parse(json['createdAt'] as String), local.toUtc());
    });
  });

  group('BackupEnvelope.unwrap', () {
    test('round-trips what wrap produced', () {
      final out = BackupEnvelope.wrap(
        appId: 'lullaby',
        schemaVersion: 7,
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        payload: {
          'feeds': [
            {'id': 1}
          ],
          'settings': {'theme': 'dark'},
        },
      );
      final u = BackupEnvelope.unwrap(out,
          expectedAppId: 'lullaby', currentSchemaVersion: 7);
      expect(u.schemaVersion, 7);
      expect(u.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(u.payload['feeds'], [
        {'id': 1}
      ]);
      expect(u.payload['settings'], {'theme': 'dark'});
    });

    test('rejects a backup made by a different app', () {
      final blob = _bytes({
        'app': 'furrow',
        'schemaVersion': 1,
        'payload': <String, Object?>{},
      });
      expect(
        () => BackupEnvelope.unwrap(blob,
            expectedAppId: 'sundial', currentSchemaVersion: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a future schemaVersion with BackupSchemaException', () {
      final blob = _bytes({
        'app': 'sundial',
        'schemaVersion': 99,
        'payload': <String, Object?>{},
      });
      expect(
        () => BackupEnvelope.unwrap(blob,
            expectedAppId: 'sundial', currentSchemaVersion: 4),
        throwsA(isA<BackupSchemaException>()
            .having((e) => e.backupVersion, 'backupVersion', 99)
            .having((e) => e.currentVersion, 'currentVersion', 4)),
      );
    });

    test('accepts an OLDER schemaVersion (forward-compatible restore)', () {
      final blob = _bytes({
        'app': 'sundial',
        'schemaVersion': 2,
        'payload': {'sessions': <Object?>[]},
      });
      final u = BackupEnvelope.unwrap(blob,
          expectedAppId: 'sundial', currentSchemaVersion: 4);
      expect(u.schemaVersion, 2);
    });

    test('tolerates a missing createdAt (pre-v2 backups) as null', () {
      final blob = _bytes({
        'app': 'sundial',
        'schemaVersion': 1,
        'payload': <String, Object?>{},
      });
      final u = BackupEnvelope.unwrap(blob,
          expectedAppId: 'sundial', currentSchemaVersion: 1);
      expect(u.createdAt, isNull);
    });

    test('tolerates an unparseable createdAt as null rather than throwing', () {
      final blob = _bytes({
        'app': 'sundial',
        'schemaVersion': 1,
        'createdAt': 'not-a-date',
        'payload': <String, Object?>{},
      });
      final u = BackupEnvelope.unwrap(blob,
          expectedAppId: 'sundial', currentSchemaVersion: 1);
      expect(u.createdAt, isNull);
    });

    test('rejects missing app / schemaVersion with FormatException', () {
      // A missing payload key is NOT rejected at envelope level: the fleet's
      // legacy shapes keep rows under tables/data/flat keys, so which data
      // keys are required is app semantics (the app's restoreAll enforces
      // it). App identity and schema version are the envelope's job.
      for (final broken in [
        {'schemaVersion': 1, 'payload': <String, Object?>{}},
        {'app': 'sundial', 'payload': <String, Object?>{}},
      ]) {
        expect(
          () => BackupEnvelope.unwrap(_bytes(broken),
              expectedAppId: 'sundial', currentSchemaVersion: 1),
          throwsA(isA<FormatException>()),
          reason: 'must reject $broken',
        );
      }
    });

    test('rejects non-JSON bytes with FormatException', () {
      expect(
        () => BackupEnvelope.unwrap(Uint8List.fromList([0, 1, 2, 255]),
            expectedAppId: 'sundial', currentSchemaVersion: 1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BackupEnvelope.unwrap — legacy fleet shapes', () {
    test(
        'accepts a Lullaby-shaped envelope with NO app key when the caller '
        'opts out of requiring one', () {
      // Lullaby's shipped envelopes: {schemaVersion, exportedAt, tables} —
      // no 'app', no 'payload'. requireAppKey:false must accept them.
      final blob = _bytes({
        'schemaVersion': 4,
        'exportedAt': '2026-06-01T10:00:00.000Z',
        'tables': {
          'feedingLogs': [1, 2]
        },
      });
      final u = BackupEnvelope.unwrap(blob,
          expectedAppId: 'lullaby',
          currentSchemaVersion: 4,
          requireAppKey: false);
      expect(u.schemaVersion, 4);
      expect(u.payload['tables'], {
        'feedingLogs': [1, 2]
      });
    });

    test('still rejects a PRESENT-but-wrong app key even when not required',
        () {
      final blob = _bytes({
        'app': 'furrow',
        'schemaVersion': 1,
        'tables': <String, Object?>{},
      });
      expect(
        () => BackupEnvelope.unwrap(blob,
            expectedAppId: 'lullaby',
            currentSchemaVersion: 4,
            requireAppKey: false),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing app key with the default strictness still rejects', () {
      final blob = _bytes({
        'schemaVersion': 1,
        'payload': <String, Object?>{},
      });
      expect(
        () => BackupEnvelope.unwrap(blob,
            expectedAppId: 'sundial', currentSchemaVersion: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('a tables-map envelope without payload exposes the whole envelope '
        'as payload', () {
      final blob = _bytes({
        'app': 'furrow',
        'schemaVersion': 1,
        'exportedAt': '2026-05-05T05:05:05.000Z',
        'tables': {
          'habits': [1]
        },
      });
      final u = BackupEnvelope.unwrap(blob,
          expectedAppId: 'furrow', currentSchemaVersion: 1);
      expect(u.payload['tables'], {
        'habits': [1]
      });
    });

    test('createdAt falls back to exportedAt, then generatedAt', () {
      final exported = _bytes({
        'app': 'furrow',
        'schemaVersion': 1,
        'exportedAt': '2026-05-05T05:05:05.000Z',
        'tables': <String, Object?>{},
      });
      expect(
          BackupEnvelope.unwrap(exported,
                  expectedAppId: 'furrow', currentSchemaVersion: 1)
              .createdAt,
          DateTime.utc(2026, 5, 5, 5, 5, 5));

      final generated = _bytes({
        'app': 'reckon',
        'schemaVersion': 5,
        'generatedAt': '2026-04-04T04:04:04.000Z',
        'cases': <Object?>[],
      });
      expect(
          BackupEnvelope.unwrap(generated,
                  expectedAppId: 'reckon', currentSchemaVersion: 5)
              .createdAt,
          DateTime.utc(2026, 4, 4, 4, 4, 4));

      final both = _bytes({
        'app': 'sundial',
        'schemaVersion': 1,
        'createdAt': '2026-01-01T01:01:01.000Z',
        'exportedAt': '2026-02-02T02:02:02.000Z',
        'payload': <String, Object?>{},
      });
      expect(
          BackupEnvelope.unwrap(both,
                  expectedAppId: 'sundial', currentSchemaVersion: 1)
              .createdAt,
          DateTime.utc(2026, 1, 1, 1, 1, 1),
          reason: 'the canonical key wins when present');
    });
  });

  group('BackupEnvelope.describe', () {
    test('reports app, schemaVersion, createdAt and per-table row counts', () {
      final blob = BackupEnvelope.wrap(
        appId: 'sundial',
        schemaVersion: 4,
        createdAt: DateTime.utc(2026, 7, 1),
        payload: {
          'sessions': List.generate(12, (i) => {'id': i}),
          'profiles': [
            {'id': 1},
            {'id': 2}
          ],
          'settings': {'annualGoalHours': 1000},
        },
      );
      final m = BackupEnvelope.describe(blob);
      expect(m.appId, 'sundial');
      expect(m.schemaVersion, 4);
      expect(m.createdAt, DateTime.utc(2026, 7, 1));
      expect(m.tableCounts, {'sessions': 12, 'profiles': 2});
    });

    test('counts rows inside a legacy top-level tables map', () {
      // The fleet's other envelope convention: {app, schemaVersion, tables}.
      final blob = _bytes({
        'app': 'lullaby',
        'schemaVersion': 3,
        'tables': {
          'feeds': [1, 2, 3],
          'sleeps': [1],
        },
      });
      final m = BackupEnvelope.describe(blob);
      expect(m.appId, 'lullaby');
      expect(m.tableCounts, {'feeds': 3, 'sleeps': 1});
    });

    test('counts rows inside a StillLife-style data map and reads exportedAt',
        () {
      final blob = _bytes({
        'app': 'still_life',
        'version': '1.0',
        'exportedAt': '2026-03-03T03:03:03.000Z',
        'data': {
          'items': [1, 2],
          'rooms': [1],
        },
      });
      final m = BackupEnvelope.describe(blob);
      expect(m.tableCounts, {'items': 2, 'rooms': 1});
      expect(m.createdAt, DateTime.utc(2026, 3, 3, 3, 3, 3));
    });

    test('is lenient: missing keys yield nulls, never a throw for valid JSON',
        () {
      final m = BackupEnvelope.describe(_bytes({'something': 'else'}));
      expect(m.appId, isNull);
      expect(m.schemaVersion, isNull);
      expect(m.createdAt, isNull);
      expect(m.tableCounts, isEmpty);
    });

    test('throws FormatException on non-JSON bytes', () {
      expect(
        () => BackupEnvelope.describe(Uint8List.fromList([9, 9, 9])),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
