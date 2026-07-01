import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

Uint8List _blob([int fill = 1]) => Uint8List(8)..fillRange(0, 8, fill);

void main() {
  late InMemoryVaultStore store;
  late DateTime clockNow;
  BackupVault vault({int keepN = 10}) => BackupVault(
        store,
        appId: 'sundial',
        keepN: keepN,
        now: () => clockNow,
      );

  setUp(() {
    store = InMemoryVaultStore();
    clockNow = DateTime.utc(2026, 7, 16, 9, 30, 15, 123);
  });

  group('save + stamping', () {
    test('stamps a UTC, filesystem-safe, lexically sortable filename', () async {
      final entry = await vault().save(_blob(), label: VaultLabel.manual);
      expect(entry.id, 'sundial-backup-20260716T093015123Z.ohbk');
      expect(entry.createdAt, clockNow);
      expect(entry.label, VaultLabel.manual);
      expect(entry.sizeBytes, 8);
    });

    test('two saves in the same millisecond get distinct ids and both survive',
        () async {
      final v = vault();
      final a = await v.save(_blob(1), label: VaultLabel.manual);
      final b = await v.save(_blob(2), label: VaultLabel.manual);
      expect(a.id, isNot(b.id));
      final ids = (await v.list()).map((e) => e.id).toSet();
      expect(ids, containsAll({a.id, b.id}));
    });

    test('later stamps sort lexically after earlier ones', () async {
      final v = vault();
      final a = await v.save(_blob(), label: VaultLabel.manual);
      clockNow = clockNow.add(const Duration(days: 30));
      final b = await v.save(_blob(), label: VaultLabel.manual);
      expect(b.id.compareTo(a.id), greaterThan(0));
    });

    test(
        'a custom extension flows into the id (PunctumTemporis stores '
        'plaintext .json snapshots — .ohbk would be a lie)', () async {
      final v = BackupVault(store,
          appId: 'punctum', extension: 'json', now: () => clockNow);
      final entry = await v.save(_blob(), label: VaultLabel.manual);
      expect(entry.id, 'punctum-backup-20260716T093015123Z.json');
    });

    test('saved bytes round-trip through read', () async {
      final v = vault();
      final entry = await v.save(_blob(42), label: VaultLabel.manual);
      expect(await v.read(entry.id), _blob(42));
    });
  });

  group('list ordering', () {
    test('returns newest first regardless of store order', () async {
      final v = vault();
      final first = await v.save(_blob(), label: VaultLabel.manual);
      clockNow = clockNow.add(const Duration(hours: 1));
      final second = await v.save(_blob(), label: VaultLabel.freshness);
      clockNow = clockNow.add(const Duration(hours: 1));
      final third = await v.save(_blob(), label: VaultLabel.manual);
      final listed = await v.list();
      expect(listed.map((e) => e.id).toList(),
          [third.id, second.id, first.id]);
    });
  });

  group('keep-N pruning', () {
    test('prunes oldest unpinned entries beyond keepN', () async {
      final v = vault(keepN: 3);
      final saved = <VaultEntry>[];
      for (var i = 0; i < 5; i++) {
        saved.add(await v.save(_blob(i), label: VaultLabel.manual));
        clockNow = clockNow.add(const Duration(minutes: 1));
      }
      final remaining = (await v.list()).map((e) => e.id).toList();
      expect(remaining, [saved[4].id, saved[3].id, saved[2].id]);
      // Pruned blobs are gone from the store, not just the listing.
      expect(await v.read(saved[0].id), isNull);
    });

    test('user-pinned entries never prune and do not count toward N',
        () async {
      final v = vault(keepN: 2);
      final pinnedEntry =
          await v.save(_blob(9), label: VaultLabel.manual, pinned: true);
      final unpinned = <VaultEntry>[];
      for (var i = 0; i < 4; i++) {
        clockNow = clockNow.add(const Duration(minutes: 1));
        unpinned.add(await v.save(_blob(i), label: VaultLabel.manual));
      }
      final remaining = (await v.list()).map((e) => e.id).toSet();
      expect(remaining,
          {pinnedEntry.id, unpinned[3].id, unpinned[2].id});
    });

    test('setPinned protects an existing entry from later pruning', () async {
      final v = vault(keepN: 2);
      final keeper = await v.save(_blob(1), label: VaultLabel.manual);
      await v.setPinned(keeper.id, true);
      for (var i = 0; i < 3; i++) {
        clockNow = clockNow.add(const Duration(minutes: 1));
        await v.save(_blob(i), label: VaultLabel.manual);
      }
      final remaining = (await v.list()).map((e) => e.id).toSet();
      expect(remaining, contains(keeper.id));
    });
  });

  group('pre-restore auto-pin', () {
    test(
        'REVIEW FIX: a FAILED pre-restore save must NOT strip the previous '
        'rollback\'s auto-pin (release only after the new put succeeds)',
        () async {
      final v = vault(keepN: 1);
      final s1 = await v.save(_blob(1), label: VaultLabel.preRestore);
      expect(s1.autoPinned, isTrue);

      // Disk fills up: the next pre-restore put throws.
      store.failNextPut = true;
      await expectLater(
          v.save(_blob(2), label: VaultLabel.preRestore), throwsStateError);

      final after =
          (await v.list()).singleWhere((e) => e.id == s1.id);
      expect(after.autoPinned, isTrue,
          reason: 'the only existing rollback must stay protected when the '
              'replacement could not be stored');
      // And it survives subsequent pruning pressure.
      for (var i = 0; i < 3; i++) {
        clockNow = clockNow.add(const Duration(minutes: 1));
        await v.save(_blob(i), label: VaultLabel.manual);
      }
      expect((await v.list()).map((e) => e.id), contains(s1.id));
    });

    test('REVIEW FIX: keepN is floored at 1 so save can never prune its own '
        'just-written snapshot', () async {
      final v = BackupVault(store, appId: 'sundial', keepN: 0,
          now: () => clockNow);
      final e = await v.save(_blob(), label: VaultLabel.manual);
      expect((await v.list()).map((x) => x.id), contains(e.id));
      final vNeg = BackupVault(store, appId: 'sundial', keepN: -3,
          now: () => clockNow);
      await vNeg.prune(); // must not throw RangeError
    });

    test(
        'REVIEW FIX: a future-stamped newest snapshot does not disable the '
        'freshness net', () async {
      final v = vault();
      clockNow = DateTime.utc(2027, 1, 1); // stamp in the "future"
      await v.save(_blob(), label: VaultLabel.manual);
      clockNow = DateTime.utc(2026, 7, 16); // clock corrected backwards
      final took = await v.maybeFreshnessSnapshot(() async => _blob(5));
      expect(took, isTrue,
          reason: 'a nonsensical (future) stamp must read as stale, not as '
              'eternally fresh');
    });
    test('a pre-restore snapshot is auto-protected from pruning', () async {
      final v = vault(keepN: 1);
      final pre = await v.save(_blob(7), label: VaultLabel.preRestore);
      expect(pre.autoPinned, isTrue);
      for (var i = 0; i < 3; i++) {
        clockNow = clockNow.add(const Duration(minutes: 1));
        await v.save(_blob(i), label: VaultLabel.manual);
      }
      final remaining = (await v.list()).map((e) => e.id).toSet();
      expect(remaining, contains(pre.id),
          reason: 'the rollback snapshot must survive mid-mistake pruning');
    });

    test(
        'saving a NEW pre-restore snapshot releases the previous auto-pin '
        '(but never a user pin)', () async {
      final v = vault(keepN: 1);
      final old = await v.save(_blob(1), label: VaultLabel.preRestore);
      final userKept = await v.save(_blob(2), label: VaultLabel.manual);
      await v.setPinned(userKept.id, true);
      clockNow = clockNow.add(const Duration(days: 1));
      final fresh = await v.save(_blob(3), label: VaultLabel.preRestore);

      final entries = await v.list();
      final oldNow = entries.where((e) => e.id == old.id);
      // The old pre-restore entry lost auto-protection: it either got pruned
      // (keepN=1) or survives unprotected — but it must NOT still be
      // auto-pinned.
      if (oldNow.isNotEmpty) {
        expect(oldNow.single.autoPinned, isFalse);
      }
      expect(entries.map((e) => e.id), contains(userKept.id));
      expect(
          entries.singleWhere((e) => e.id == fresh.id).autoPinned, isTrue);
    });
  });

  group('delete', () {
    test('removes the entry and its bytes', () async {
      final v = vault();
      final entry = await v.save(_blob(), label: VaultLabel.manual);
      await v.delete(entry.id);
      expect(await v.list(), isEmpty);
      expect(await v.read(entry.id), isNull);
    });
  });

  group('freshness snapshot', () {
    test('saves when the vault is empty', () async {
      final v = vault();
      final took = await v.maybeFreshnessSnapshot(() async => _blob(5));
      expect(took, isTrue);
      final entries = await v.list();
      expect(entries.single.label, VaultLabel.freshness);
    });

    test('does nothing when the newest snapshot is recent enough', () async {
      final v = vault();
      await v.save(_blob(), label: VaultLabel.manual);
      clockNow = clockNow.add(const Duration(days: 3));
      final took = await v.maybeFreshnessSnapshot(() async => _blob(5));
      expect(took, isFalse);
      expect((await v.list()).length, 1);
    });

    test('saves when the newest snapshot is older than the threshold',
        () async {
      final v = vault();
      await v.save(_blob(), label: VaultLabel.manual);
      clockNow = clockNow.add(const Duration(days: 8));
      final took = await v.maybeFreshnessSnapshot(() async => _blob(5));
      expect(took, isTrue);
      expect((await v.list()).length, 2);
    });

    test('a failing exporter is silent: returns false, vault unchanged',
        () async {
      final v = vault();
      final took = await v.maybeFreshnessSnapshot(
          () async => throw StateError('no key yet'));
      expect(took, isFalse);
      expect(await v.list(), isEmpty);
    });
  });
}
