# sanctuary_backup_ui

Drop-in **encrypted-backup UI** for OpenHearth apps, built on
[`sanctuary_auth_core`](../sanctuary_auth_core). It packages the whole
Ghost-tier backup experience — seed-phrase setup with re-entry confirmation,
encrypted `.ohbk` export via the system share sheet, and destructive restore —
as a controller plus three Theme-driven widgets, so each app supplies only its
own data serializer and a small config object.

It was extracted from Lullaby's `sanctuary_backup` feature and made
app-agnostic.

## What you get

- **`BackupSerializer`** — the one interface you implement (`dumpAll()` /
  `restoreAll()`), typically over your Drift database.
- **`SanctuaryBackupConfig`** — per-app identity: `appId`, `aadContext`,
  `appDisplayName`, optional `restoreReplaceConsequence`, the restore-confirm
  `confirmTitle` / `confirmActionLabel` (default to destructive-replace copy;
  upsert-merge apps override them), and an `onAfterRestore` hook.
- **`BackupController`** — seed generate / re-entry confirm, export, restore
  with the typed `RestoreOutcome` enum, and `<appId>-backup-<yyyy-MM-dd>.ohbk`
  filenames.
- **Widgets** — `BackupSettingsSection` (drop into your settings list;
  draws its own heading), `SeedPhraseModal` (the words as a fixed 3x4
  table), `PhraseReEntryDialog` (word-by-word check), `PhraseEntryDialog`
  (restore), `BackupSetupReminder` (the "Finish setup" line), and the
  `BackupVaultSheet` ("Previous backups").
- **`AppScopedSecureKeyStore`** — per-app key-store names on web, where
  the fleet PWAs share one origin.

## Migrating from 0.2

Nothing breaks at compile time: every change is additive or keeps its
signature. What each app should do:

1. **Add `appScopedKeyStoreOverride()`** to the root `ProviderScope`
   overrides (after the config override). Until you do, your PWA shares
   recovery words with every other fleet PWA in the same browser. It does
   nothing on native.
2. **Delete your own heading above `BackupSettingsSection`** (for
   example WeatherGlass's `_Label('Backup & Restore')`). The section now
   draws "Backup" itself, in every state; pass `title:` to change it.
   Native-tile apps (Sundial, Furrow, WeatherGlass, Hatch) that draw
   their own tiles should draw their heading inside the same
   `authNotifierProvider.when(...)` and give `loading`/`error` visible
   content.
3. **Call `snapshotBeforeWipe()` before "Clear all data"**, and wipe only
   on `PreWipeOutcome.taken` (see Restore safety above).
4. **Show `BackupSetupReminder`** where unfinished setup should be
   noticed (home or top of settings), per operator ruling 48.
5. **Tests that drive the old flows** need updating:
   - setup no longer stores words when the sheet opens. Tap
     "I've written this down" first; "Not now" stores nothing;
   - re-entry is word by word (`PhraseReEntryDialog`, button keys
     `re-entry-next` / `re-entry-back`), and a mismatch no longer shows a
     snack bar;
   - the restore dialog's button stays disabled until twelve words are
     typed, so `pump()` after `enterText`;
   - the strings "Encrypted Backup", "Reset identity" and
     "Load data from an .ohbk file" are now "Backup",
     "Remove recovery words" and "Load data from a backup file".
   - `BackupSetupReminder` and `backupSetupStatusProvider` read
     `backupReminderStoreProvider`. Override it with
     `InMemoryBackupReminderStore` in widget tests.

### Restore safety & retention (v0.2, BACKUP_RETENTION_SPEC)

- **`BackupVault`** — every app keeps stamped generational `.ohbk`
  snapshots (keep-N, default 10; pinnable) in app documents on native and
  OPFS on web. A copy of every manual export and a silent 7-day freshness
  snapshot land there automatically.
- **Mandatory pre-restore snapshot** — `commitRestore` refuses to touch
  data unless a snapshot of the CURRENT data was vaulted first
  (`RestoreOutcome.snapshotFailed`, fail-closed). The snapshot is sealed
  under whichever key performed the restore.
- **Pre-wipe snapshot** — before any action that deletes the user's
  data outside a restore ("Clear all data"), call
  `ref.read(backupControllerProvider.notifier).snapshotBeforeWipe()`.
  Wipe **only** on `PreWipeOutcome.taken`: the current data is then in
  Previous backups as the protected "Safety snapshot" (auto-pinned,
  verified by read-back), and rolling back is an ordinary restore of it.
  On `failed`, do not wipe. On `noKey` (no recovery words yet) there is
  nothing to seal it under: offer setup or the plain export first, or
  wipe only with the user's explicit agreement that there is no way back.
  The wipe must leave the vault (app documents on native, OPFS on web)
  and the recovery words in place: delete your data, not the app's
  storage directory, and do not reset the words as part of it.
  ```dart
  final snap = await ref
      .read(backupControllerProvider.notifier)
      .snapshotBeforeWipe();
  if (snap.outcome == PreWipeOutcome.taken) await wipeEverything();
  ```
- **Preview-before-restore** — `prepareRestore` decrypts first and shows
  what the backup contains (app, age, per-table counts vs current) before
  the confirm dialog. Wrong-phrase attempts never trigger snapshots.
- **Verify by read-back** — every export decrypts and dry-run-parses its
  own output before reporting success ("untested backups don't count").
- **Plaintext export** — one shared "Export as plain JSON" action emitting
  exactly `serializer.dumpAll()` bytes, honestly labeled UNENCRYPTED.
  Plaintext *import* stays per-app (unauthenticated restore is a tamper
  vector).
- **`BackupEnvelope`** — the fleet-standard `{app, schemaVersion,
  createdAt, payload}` helper (tolerant of every legacy shape), plus the
  optional `PreviewableBackupSerializer` for app-level dry-run manifests.
- Call `runStartupMaintenance()` once from app bootstrap (fire-and-forget)
  to enable the freshness snapshot.

### Passphrase guard (spec §6.G)

The KDF here is PBKDF2-2048 over a **machine-generated BIP39 mnemonic** —
that is fine *only because the secret is high-entropy*. Any future
human-passphrase key source MUST use Argon2id (OWASP floor m=19MiB, t=2,
p=1). `test/passphrase_guard_test.dart` enforces this structurally.

Plain `flutter_riverpod` — **no** codegen, **no** `build_runner` — so it wires
into codegen and non-codegen apps alike. Bytes-only file handling
(`XFile.fromData`, `FilePicker(withData: true)`) keeps every consumer's web
build clean.

## Sibling-clone note

Like `eloEngine`, this package is consumed by **sibling path dependency**. Clone
it next to `sanctuary_auth_core` so both resolve:

```
packages/
  sanctuary_auth_core/     # github: levitatingflyfisher/sanctuaryAuthCore
  sanctuary_backup_ui/     # github: levitatingflyfisher/sanctuaryBackupUi
your_app/                  # depends on ../packages/...
```

In your app's `pubspec.yaml`:

```yaml
dependencies:
  sanctuary_auth_core:
    path: ../packages/sanctuary_auth_core
  sanctuary_backup_ui:
    path: ../packages/sanctuary_backup_ui
```

## Three integration steps

### 1. Implement the serializer

```dart
class MyAppBackupSerializer implements BackupSerializer {
  MyAppBackupSerializer(this._db);
  final AppDatabase _db;

  @override
  Future<Uint8List> dumpAll() async {
    // Read every user table; the JSON envelope must carry {app, schemaVersion}
    // so restore can reject a mismatched app or a future schema (defense in
    // depth behind the AEAD context).
  }

  @override
  Future<void> restoreAll(Uint8List plaintext) async {
    // Wipe + re-insert inside ONE transaction. Never a partial restore. Throw
    // BackupSchemaException when the payload's schema is newer than you know.
  }
}
```

### 2. Override the providers at your root `ProviderScope`

```dart
ProviderScope(
  overrides: [
    sanctuaryBackupConfigProvider.overrideWithValue(
      SanctuaryBackupConfig(
        appId: 'myapp',
        aadContext: 'myapp-backup/v1',       // a blob can never cross apps
        appDisplayName: 'MyApp',
        onAfterRestore: (ref) {
          // Invalidate any provider holding references to now-wiped rows.
        },
      ),
    ),
    backupSerializerProvider.overrideWith(
      (ref) => MyAppBackupSerializer(ref.watch(databaseProvider)),
    ),
    // Optional: isolate this app's key material from other apps sharing the
    // household seed. Leave unset (null) to keep the legacy household-wide
    // derivation used by already-shipped backups.
    sanctuaryAppDomainProvider.overrideWithValue('myapp'),
    // Web: keep this app's recovery words apart from the other fleet PWAs
    // on the same origin (see below). A no-op on native.
    appScopedKeyStoreOverride(),
  ],
  child: const MyApp(),
);
```

**Why `appScopedKeyStoreOverride()`.** Every fleet PWA is served from one
origin, `levitatingflyfisher.github.io`, and `flutter_secure_storage` on web
is that origin's localStorage. The default key store uses fixed names
(`oh_mnemonic_v1`, …), so without the override every fleet PWA in a browser
shares one set of recovery words, one "confirmed" flag and one "last
backup" time. "Remove recovery words" in one app removes them in all. The
override namespaces every entry by `appId` (`oh_<appId>_mnemonic_v1`).
Existing shared words are carried over only for the app that can prove they
are its own: a snapshot in its own vault must open under them (apps calling
`runStartupMaintenance` normally have one). The confirmed flag comes with
them; the shared backup time does not. The shared entries are never written
or deleted. An app that cannot prove ownership starts with no words, and the
user restores with the words on paper, which adopts them. The vault itself
was already scoped by `appId` on web (`sanctuary_vault_<appId>`).

Both config providers throw a helpful `UnimplementedError` until overridden, so
a missing override fails loud rather than silently.

### 3. Drop the section into settings

The section draws its own heading ("Backup" by default, `title:` to
change it) together with its tiles, so do **not** put an app heading
above it — the two would stack, and yours would outlive the tiles while
the backup state loads.

```dart
ListView(
  children: const [
    // ...your other settings tiles...
    BackupSettingsSection(),
  ],
)
```

## Finish-setup reminder

Apps open into their task and ask for backup setup when it is needed, but
unfinished setup must not be forgotten. `backupSetupStatusProvider` gives a
`BackupSetupStatus` (`hasWords`, `wordsConfirmed`, `setupFinished`,
`lastBackupAt`, `showReminder(now)`), and `BackupSetupReminder` is a
ready-made line for a home screen or the top of settings: a sentence plus
**Set up** and **Dismiss**. It takes no space once setup is finished. A
dismissal lasts `BackupSetupStatus.reminderSnooze` (30 days), then the
reminder returns, because a dismissal means "not now", not "never". Dismissals are
stored per app (`backupReminderStoreProvider`; override it with
`InMemoryBackupReminderStore` from `testing.dart` in tests).

```dart
Column(children: [
  const BackupSetupReminder(),          // or onSetUp: () => context.go('/settings')
  ...
])
```

## Native-tile apps: call `BackupFlow`

If you draw your own tiles, draw your heading in the same widget, inside
the same `authNotifierProvider.when(...)`, and give its `loading` and
`error` branches visible content (a status line; a message with a retry).
A heading rendered outside that `when` sits over nothing whenever auth is
not `data`.

`BackupSettingsSection` is a Material `ListView` of tiles. Some apps (Sundial,
Furrow, WeatherGlass) have their own visual conventions for a settings screen
and want backup actions rendered as *their* tiles, not this Material section.
Rather than copy-pasting the ~130-line restore orchestration (file-pick →
destructive-confirm → wrong-phrase → phrase-entry fallback → outcome message)
into each app, call the same tested helper the section itself uses —
**`BackupFlow`**:

```dart
class MyRestoreTile extends ConsumerWidget {
  const MyRestoreTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MyOwnStyledTile(
      label: 'Restore from backup',
      onTap: () => const BackupFlow().runRestore(context, ref),
    );
  }
}
```

`BackupFlow` is a stateless, `const`-constructible helper. Every method takes
`(BuildContext context, WidgetRef ref)` and drives `BackupController`,
`SeedPhraseModal`, and `PhraseEntryDialog` with the config-driven copy:

| Method | What it does |
|---|---|
| `runSeedSetup(context, ref)` | Show new words; store them only on "I've written this down"; check them word by word |
| `confirmPhraseReEntry(context, ref)` | Check stored words word by word (finishes an interrupted setup) |
| `showRecoveryWords(context, ref)` | After a confirm, show the stored words again |
| `runExport(context, ref)` | Export the encrypted blob to the system share sheet |
| `runRestore(context, ref)` | Pick an `.ohbk`, confirm, restore (with wrong-phrase fallback) |
| `runResetIdentity(context, ref)` | Danger-zone: wipe key material (keeps data) |

For finer control, `restorePickedBlob(context, ref, bytes)` runs just the
post-file-pick orchestration (confirm → restore → outcome snackbar) if your app
already has the bytes in hand, and `restoreMessage(outcome, config)` maps a
`RestoreOutcome` to its user-facing string. Read `authNotifierProvider`'s
`AsyncValue<AuthState>` yourself to decide which tiles to show (set-up vs.
export vs. reset), exactly as `BackupSettingsSection` does.

## Recovery-phrase honesty copy convention

The seed phrase **is** the user's data — there is no server that holds a copy,
so the copy never pretends otherwise:

- The seed modal states plainly that the 12 words are *"the only way to recover
  your data on a new device."*
- Setup requires **re-entering** the phrase — turning "I clicked 'got it'" into
  a cryptographic proof that the paper copy is actually correct.
- Restore is **destructive-replace** and always shows a confirm dialog that
  states the consequence in full (*"This cannot be undone."*).
- Wrong phrase yields a calm, specific message — never a partial restore.

Keep that register when you customise `appDisplayName` /
`restoreReplaceConsequence` / `confirmTitle` / `confirmActionLabel`:
forgiveness and plain honesty over false comfort. If your restore is an
upsert-merge rather than a wipe (e.g. StillLife), override `confirmTitle` /
`confirmActionLabel` (say `'Restore backup?'` / `'Restore'`) so the dialog's
title and button don't promise a destruction that never happens.

## Testing

`package:sanctuary_backup_ui/testing.dart` ships fakes for consumer TDD without
the OS keychain or real PBKDF2: `InMemorySecureKeyStore`, `FakeCryptoService`,
and `FakeBackupSerializer`. Override the `sanctuary_auth_core` providers with
them in a `ProviderContainer` / `ProviderScope`.

## License

MIT — see [LICENSE](LICENSE).
