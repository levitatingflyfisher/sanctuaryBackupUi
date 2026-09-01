import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'backup_config.dart';
import 'backup_envelope.dart';
import 'backup_repository.dart';
import 'backup_serializer.dart';
import 'backup_vault.dart';

/// The distinguishable outcomes of a restore attempt, so the UI can show a
/// legible, specific message instead of one catch-all string.
enum RestoreOutcome {
  success,
  noKey,
  wrongPhrase,
  corruptFile,
  tooNewBackup,

  /// The mandatory pre-restore snapshot could not be saved, so the restore
  /// was refused before touching any data (fail-closed,
  /// BACKUP_RETENTION_SPEC §2.B).
  snapshotFailed,
  failed,
}

/// What [BackupController.snapshotBeforeWipe] achieved.
enum PreWipeOutcome {
  /// A verified snapshot of the current data is in the vault. Safe to wipe.
  taken,

  /// No recovery words on this device, so there is no key to seal a
  /// snapshot under. Nothing was written. The app decides: offer backup
  /// setup first, offer the plain export, or wipe with the user's
  /// explicit consent that there is no way back.
  noKey,

  /// The snapshot could not be saved or did not read back. Do NOT wipe.
  failed,
}

/// Result of [BackupController.snapshotBeforeWipe]: [entry] is set only
/// when [outcome] is [PreWipeOutcome.taken].
typedef PreWipeSnapshot = ({PreWipeOutcome outcome, VaultEntry? entry});

/// A decrypted-and-described backup, ready to be committed. Produced by
/// [BackupController.prepareRestore] / [prepareRestoreWithPhrase]; the UI
/// shows [manifest] in the preview/confirm dialog, then hands the whole
/// handle to [BackupController.commitRestore]. Treat as opaque outside this
/// package.
class PreparedRestore {
  /// What the preview dialog shows: app, schema, age, row counts.
  final BackupManifest manifest;

  /// Row counts of the data currently on this device, so the preview can
  /// say "12 sessions in the backup, 340 here now". Null when current data
  /// couldn't be described — preview then shows only the backup's side.
  final Map<String, int>? currentTableCounts;

  /// The decrypted payload, applied on commit.
  final Uint8List plaintext;

  /// The key that opened the blob — the pre-restore snapshot is sealed
  /// under this same key, so the rollback is recoverable with exactly the
  /// credentials the user just used.
  final Uint8List key;

  /// Set ONLY when the restore was prepared with a typed phrase on a
  /// device that had no identity yet: on successful commit that phrase is
  /// adopted (persisted + acknowledged), because otherwise the restored
  /// data is orphaned — the user could never export again without minting
  /// a new identity. A device that already has a key NEVER adopts (no
  /// identity hijack by restoring someone else's backup).
  final String? adoptPhrase;

  const PreparedRestore({
    required this.manifest,
    required this.plaintext,
    required this.key,
    this.currentTableCounts,
    this.adoptPhrase,
  });
}

/// Calm staleness copy for preview and vault listings: "made today",
/// "made yesterday", "N days old", "age unknown". Age is information,
/// never guilt (BACKUP_RETENTION_SPEC §2.D). A stamp more than a day in
/// the future is clock damage — "unknown", never a false "made today".
String formatBackupAge(DateTime? createdAt, DateTime now) {
  if (createdAt == null) return 'age unknown';
  final days = now.toUtc().difference(createdAt.toUtc()).inDays;
  if (days < -1) return 'age unknown';
  if (days <= 0) return 'made today';
  if (days == 1) return 'made yesterday';
  return '$days days old';
}

/// Result of a prepare call: either a [PreparedRestore] ready for preview +
/// commit, or the [RestoreOutcome] that blocked it.
typedef RestorePrep = ({PreparedRestore? prepared, RestoreOutcome? blocked});

/// Manages backup operations: seed phrase generation, export, and restore.
///
/// App-agnostic — everything app-specific comes from
/// [sanctuaryBackupConfigProvider] and [backupSerializerProvider]. The seed
/// generate / re-entry confirm flow, key access, and restore all delegate to
/// `sanctuary_auth_core`'s [authNotifierProvider].
class BackupController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  /// Creates a new 12-word phrase for display WITHOUT storing it. Nothing
  /// exists on the device until the user consents with [saveSeedPhrase]
  /// ("I've written this down"); leaving the sheet leaves no key behind.
  String draftSeedPhrase() =>
      ref.read(cryptoServiceProvider).generateMnemonic();

  /// Stores a phrase from [draftSeedPhrase] as this device's recovery words,
  /// once the user has said they wrote it down. Refuses (returns false) when
  /// words already exist on the device: an existing identity is never
  /// overwritten here (same guard as `AuthNotifier.generateSeedPhrase`).
  Future<bool> saveSeedPhrase(String phrase) async {
    state = const AsyncLoading();
    try {
      final store = ref.read(secureKeyStoreProvider);
      if (await store.readMnemonic() != null) {
        state = const AsyncData(null);
        return false;
      }
      await store.writeMnemonic(phrase);
      ref.invalidate(authNotifierProvider);
      await ref.read(authNotifierProvider.future);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  /// Generates a new 12-word seed phrase, STORES it, and returns it for
  /// display. Prefer [draftSeedPhrase] + [saveSeedPhrase], which store only
  /// on consent; kept for apps that call it directly.
  Future<String?> generateSeedPhrase() async {
    state = const AsyncLoading();
    try {
      final phrase =
          await ref.read(authNotifierProvider.notifier).generateSeedPhrase();
      state = const AsyncData(null);
      return phrase;
    } catch (e, st) {
      state = AsyncError(e, st);
      return null;
    }
  }

  /// Records that the user has written down their seed phrase.
  ///
  /// [reEntryPhrase] must match the phrase previously returned by
  /// [generateSeedPhrase]; the library uses this to convert a UX assertion
  /// ("I clicked 'got it'") into a cryptographic check ("I can reproduce the
  /// phrase"). Returns `true` on success, `false` on mismatch.
  Future<bool> confirmSeedAcknowledged(String reEntryPhrase) async {
    try {
      await ref
          .read(authNotifierProvider.notifier)
          .confirmSeedAcknowledged(reEntryPhrase: reEntryPhrase);
      return true;
    } on SeedPhraseMismatchException {
      return false;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  /// Exports an encrypted backup blob, verifies it by read-back, stores a
  /// vault copy, and returns it with a suggested filename of the form
  /// `<appId>-backup-<yyyy-MM-dd>.ohbk`. Returns null on failure —
  /// including when the read-back fails: an export we can't re-open is a
  /// failure, never a silent success ("untested backups don't count",
  /// BACKUP_RETENTION_SPEC §1.2).
  Future<({Uint8List bytes, String filename, BackupManifest manifest})?>
      exportBackup() async {
    state = const AsyncLoading();
    try {
      final authState = await ref.read(authNotifierProvider.future);
      final key = authState.masterEncryptionKey;
      if (key == null) {
        state = AsyncError(
          StateError('No encryption key — set up a seed phrase first.'),
          StackTrace.current,
        );
        return null;
      }

      final repo = ref.read(backupRepositoryProvider);
      final blob = await repo.export(key);

      // Verify by read-back: decrypt the actual output bytes and dry-run
      // parse them. Throws (-> export failure) if the file wouldn't restore.
      final manifest = await _describe(await repo.open(blob, key));

      // A vault copy of every manual export — best-effort: the shared file
      // is the primary artifact, so a full vault must not block the export.
      try {
        await ref
            .read(backupVaultProvider)
            .save(blob, label: VaultLabel.manual);
      } on Object {
        // Snapshot copy is a bonus; the export itself verified fine.
      }

      await ref.read(authNotifierProvider.notifier).recordBackupCompleted();

      final appId = ref.read(sanctuaryBackupConfigProvider).appId;
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      state = const AsyncData(null);
      return (
        bytes: blob,
        filename: '$appId-backup-$date.ohbk',
        manifest: manifest,
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      return null;
    }
  }

  /// Decrypts [blob] with this device's key and returns a preview-ready
  /// [PreparedRestore] — or the [RestoreOutcome] that blocked it. Never
  /// writes.
  Future<RestorePrep> prepareRestore(Uint8List blob) async {
    final authState = await ref.read(authNotifierProvider.future);
    final key = authState.masterEncryptionKey;
    if (key == null) return (prepared: null, blocked: RestoreOutcome.noKey);
    return _prepare(blob, key);
  }

  /// Like [prepareRestore] but with a manually entered seed phrase — fresh
  /// installs, or a backup made under different words.
  Future<RestorePrep> prepareRestoreWithPhrase(
      Uint8List blob, String phrase) async {
    final appDomain = ref.read(sanctuaryAppDomainProvider);
    final DerivedKeys keys;
    try {
      keys = await ref
          .read(cryptoServiceProvider)
          .deriveKeysFromPhrase(phrase, appDomain: appDomain);
    } on ArgumentError catch (e, st) {
      // sanctuary_auth_core throws ArgumentError for a bad BIP39 phrase;
      // surface the calm "wrong words" outcome (SANCTUARY-BRIEF §2.4).
      state = AsyncError(CryptoException('Invalid recovery phrase', cause: e), st);
      return (prepared: null, blocked: RestoreOutcome.wrongPhrase);
    }

    // Fresh install? Then a successful commit should ADOPT this phrase as
    // the device identity (see PreparedRestore.adoptPhrase).
    final authState = await ref.read(authNotifierProvider.future);
    final adoptPhrase =
        authState.masterEncryptionKey == null ? phrase : null;

    final prep = await _prepare(blob, keys.masterEncryptionKey);
    final prepared = prep.prepared;
    if (prepared == null || adoptPhrase == null) return prep;
    return (
      prepared: PreparedRestore(
        manifest: prepared.manifest,
        plaintext: prepared.plaintext,
        key: prepared.key,
        currentTableCounts: prepared.currentTableCounts,
        adoptPhrase: adoptPhrase,
      ),
      blocked: null,
    );
  }

  Future<RestorePrep> _prepare(Uint8List blob, Uint8List key) async {
    state = const AsyncLoading();
    try {
      final plaintext =
          await ref.read(backupRepositoryProvider).open(blob, key);
      final manifest = await _describe(plaintext);
      state = const AsyncData(null);
      return (
        prepared: PreparedRestore(
          manifest: manifest,
          plaintext: plaintext,
          key: key,
          currentTableCounts: await _currentCounts(),
        ),
        blocked: null,
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      return (prepared: null, blocked: _outcomeFor(e));
    }
  }

  /// Row counts of the data on this device right now — best-effort: a
  /// store that can't dump (mid-migration, locked) degrades the preview,
  /// it never blocks it.
  Future<Map<String, int>?> _currentCounts() async {
    try {
      final current = await ref.read(backupSerializerProvider).dumpAll();
      return (await _describe(current)).tableCounts;
    } on Object {
      return null;
    }
  }

  /// The silent app-open freshness net (BACKUP_RETENTION_SPEC §3): when a
  /// key exists and the newest snapshot is older than the configured age,
  /// vault a fresh one. Never surfaces errors — call it fire-and-forget
  /// from app bootstrap. Returns whether a snapshot was taken.
  Future<bool> runStartupMaintenance() async {
    try {
      final authState = await ref.read(authNotifierProvider.future);
      final key = authState.masterEncryptionKey;
      if (key == null) return false;
      final config = ref.read(sanctuaryBackupConfigProvider);
      return await ref.read(backupVaultProvider).maybeFreshnessSnapshot(
            () => ref.read(backupRepositoryProvider).export(key),
            olderThan: config.vaultFreshnessAge,
          );
    } on Object {
      return false;
    }
  }

  /// The pre-wipe snapshot: call before any app action that deletes the
  /// user's data outside a restore (typically "Clear all data").
  ///
  /// Contract, identical to the snapshot [commitRestore] takes:
  /// - the current data is exported under this device's key and saved to
  ///   the vault as [VaultLabel.preRestore] ("Safety snapshot" in Previous
  ///   backups), auto-pinned — it becomes the one protected rollback,
  ///   releasing any earlier one;
  /// - the stored bytes are read back and decrypted before this returns
  ///   [PreWipeOutcome.taken];
  /// - the app wipes ONLY on [PreWipeOutcome.taken]. On
  ///   [PreWipeOutcome.failed] it must not wipe. On [PreWipeOutcome.noKey]
  ///   see that value's doc.
  ///
  /// Rolling back is an ordinary restore of that entry from Previous
  /// backups (`BackupVaultSheet`), which itself snapshots first.
  ///
  /// The wipe itself must leave two things alone, or the snapshot is lost
  /// or locked: the vault (app documents on native, OPFS on web — delete
  /// your database rows, not the app's storage directory) and the recovery
  /// words (do not call `resetIdentity`/`clearAuth` as part of it; without
  /// them the snapshot opens only with the paper copy).
  ///
  /// Reuses [VaultLabel.preRestore] rather than adding a label, because
  /// apps switch exhaustively on [VaultLabel].
  Future<PreWipeSnapshot> snapshotBeforeWipe() async {
    final Uint8List? key;
    try {
      key = (await ref.read(authNotifierProvider.future)).masterEncryptionKey;
    } on Object {
      return (outcome: PreWipeOutcome.failed, entry: null);
    }
    if (key == null) return (outcome: PreWipeOutcome.noKey, entry: null);
    try {
      final entry = await _saveVerifiedRollback(key);
      return (outcome: PreWipeOutcome.taken, entry: entry);
    } on Object {
      return (outcome: PreWipeOutcome.failed, entry: null);
    }
  }

  /// Exports current data under [key], vaults it as the auto-pinned
  /// rollback, and proves the stored bytes decrypt under [key]. Throws on
  /// any failure.
  Future<VaultEntry> _saveVerifiedRollback(Uint8List key) async {
    final repo = ref.read(backupRepositoryProvider);
    final vault = ref.read(backupVaultProvider);
    final entry =
        await vault.save(await repo.export(key), label: VaultLabel.preRestore);
    // "Untested backups don't count" applies doubly to the rollback the
    // whole promise rests on: re-read the stored bytes and prove they
    // decrypt under the same key before anything destructive happens.
    final readBack = await vault.read(entry.id);
    if (readBack == null) {
      throw StateError('rollback snapshot vanished on read-back');
    }
    await repo.open(readBack, key);
    return entry;
  }

  /// App-level dry-run parse when the serializer supports it, generic
  /// envelope description otherwise.
  Future<BackupManifest> _describe(Uint8List plaintext) async {
    // A case pattern, because PreviewableBackupSerializer is deliberately
    // NOT a subtype of BackupSerializer (see its doc) so `is` can't promote.
    if (ref.read(backupSerializerProvider)
        case final PreviewableBackupSerializer previewable) {
      return previewable.describeBackup(plaintext);
    }
    return BackupEnvelope.describe(plaintext);
  }

  /// Commits a [PreparedRestore]: takes the MANDATORY pre-restore snapshot
  /// of current data (sealed under [PreparedRestore.key], auto-pinned in
  /// the vault, VERIFIED by read-back), then applies the payload. Refuses
  /// to touch any data when the snapshot cannot be saved or does not
  /// re-open (fail-closed, BACKUP_RETENTION_SPEC §2.B).
  Future<RestoreOutcome> commitRestore(PreparedRestore prepared) async {
    state = const AsyncLoading();

    try {
      await _saveVerifiedRollback(prepared.key);
    } catch (e, st) {
      state = AsyncError(e, st);
      return RestoreOutcome.snapshotFailed;
    }

    try {
      await ref.read(backupRepositoryProvider).apply(prepared.plaintext);
    } catch (e, st) {
      state = AsyncError(e, st);
      return _outcomeFor(e);
    }

    // The destructive apply SUCCEEDED — everything after this must not
    // repaint the restore as failed. Adopt is best-effort: a keystore
    // flake leaves the device in the ordinary ghost state (data restored,
    // identity set up later via the normal flow), never "Restore failed"
    // over replaced data.
    try {
      await _maybeAdoptPhrase(prepared.adoptPhrase);
    } on Object {
      // Recorded via state below; the restore itself succeeded.
    }
    _refreshAfterRestore();
    state = const AsyncData(null);
    return RestoreOutcome.success;
  }

  /// After a successful fresh-install phrase restore, persist the typed
  /// phrase as this device's identity (uses only the frozen core's public
  /// seams). Typing the words to restore IS proof of possession, so
  /// acknowledgement is recorded too. Re-checks the KEYSTORE (not the
  /// cached provider state — a second tab/window could have minted an
  /// identity meanwhile): an existing mnemonic is never overwritten.
  Future<void> _maybeAdoptPhrase(String? phrase) async {
    if (phrase == null) return;
    final store = ref.read(secureKeyStoreProvider);
    if (await store.readMnemonic() != null) return;
    await store.writeMnemonic(phrase);
    await store.writeSeedAcknowledged();
    ref.invalidate(authNotifierProvider);
  }

  /// Decrypts and restores data from an OHBK blob using the user's current
  /// master key — prepare + commit in one step, including the mandatory
  /// pre-restore snapshot. UIs wanting preview-before-restore call
  /// [prepareRestore] / [commitRestore] separately.
  Future<RestoreOutcome> restoreFromBlob(Uint8List blob) async {
    final prep = await prepareRestore(blob);
    final prepared = prep.prepared;
    if (prepared == null) return prep.blocked!;
    return commitRestore(prepared);
  }

  /// Restores from a blob using a manually entered seed phrase — used on fresh
  /// installs, or when this device's key doesn't match the backup. Prepare +
  /// commit in one step, including the mandatory pre-restore snapshot.
  Future<RestoreOutcome> restoreWithPhrase(
      Uint8List blob, String phrase) async {
    final prep = await prepareRestoreWithPhrase(blob, phrase);
    final prepared = prep.prepared;
    if (prepared == null) return prep.blocked!;
    return commitRestore(prepared);
  }

  /// Maps a thrown error to the specific outcome the UI copy needs.
  RestoreOutcome _outcomeFor(Object error) => switch (error) {
        CryptoException() => RestoreOutcome.wrongPhrase,
        BackupSchemaException() => RestoreOutcome.tooNewBackup,
        BackupFormatException() => RestoreOutcome.corruptFile,
        FormatException() => RestoreOutcome.corruptFile,
        _ => RestoreOutcome.failed,
      };

  /// After a destructive restore the store's watch streams self-refresh, but
  /// in-memory app state can still reference wiped rows. The app supplies the
  /// invalidations via [SanctuaryBackupConfig.onAfterRestore].
  void _refreshAfterRestore() {
    ref.read(sanctuaryBackupConfigProvider).onAfterRestore?.call(ref);
  }

  /// Wipes all key material. App data is NOT affected.
  Future<void> resetIdentity() async {
    state = const AsyncLoading();
    try {
      await ref.read(authNotifierProvider.notifier).resetIdentity();
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final backupControllerProvider =
    NotifierProvider<BackupController, AsyncValue<void>>(
  BackupController.new,
);
