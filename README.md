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
- **Widgets** — `BackupSettingsSection` (drop into your settings list),
  `SeedPhraseModal`, `PhraseEntryDialog`, and the `BackupVaultSheet`
  ("Previous backups").

### Restore safety & retention (v0.2, BACKUP_RETENTION_SPEC)

- **`BackupVault`** — every app keeps stamped generational `.ohbk`
  snapshots (keep-N, default 10; pinnable) in app documents on native and
  OPFS on web. A copy of every manual export and a silent 7-day freshness
  snapshot land there automatically.
- **Mandatory pre-restore snapshot** — `commitRestore` refuses to touch
  data unless a snapshot of the CURRENT data was vaulted first
  (`RestoreOutcome.snapshotFailed`, fail-closed). The snapshot is sealed
  under whichever key performed the restore.
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
  ],
  child: const MyApp(),
);
```

Both config providers throw a helpful `UnimplementedError` until overridden, so
a missing override fails loud rather than silently.

### 3. Drop the section into settings

```dart
ListView(
  children: const [
    // ...your other settings tiles...
    BackupSettingsSection(),
  ],
)
```

## Native-tile apps: call `BackupFlow`

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
| `runSeedSetup(context, ref)` | Generate a phrase, show it, require re-entry to confirm |
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
