# Changelog

All notable changes to `sanctuary_backup_ui` are documented here. This package
follows [semantic versioning](https://semver.org/); until 1.0.0 the public API
may still shift between minor versions.

## Unreleased (0.3.0)

The seed-sheet and backup-section release (fleet lens audit 2026-09-16,
backlog item 2). See "Migrating from 0.2" in the README.

### Added
- `PhraseReEntryDialog` — checks a new phrase one word at a time with a
  counter ("Word 5 of 12"). A word that does not match is named in place
  and stays in the field; earlier words are kept (Back revisits them);
  "Show the words again" opens the sheet over the dialog.
- `SeedPhraseModal.acknowledgeLabel` (default "I've written this down")
  and `declineLabel` (a secondary button that pops `false`).
- `BackupController.draftSeedPhrase()` / `saveSeedPhrase(phrase)` —
  create words without storing them, then store them on consent (never
  over existing words).
- `BackupController.snapshotBeforeWipe()` → `PreWipeSnapshot`
  (`PreWipeOutcome.taken / noKey / failed`) — the pre-wipe snapshot for
  "Clear all data", with the pre-restore snapshot's contract (device key,
  auto-pinned `VaultLabel.preRestore`, read-back verified). Wipe only on
  `taken`. No new `VaultLabel` value, because apps switch on it
  exhaustively.
- `AppScopedSecureKeyStore` + `appScopedKeyStoreOverride()` — on web,
  namespaces every key-store entry by `appId`, because the fleet PWAs
  share one origin and therefore one localStorage. Shared words already
  there move over only for an app whose own vault proves it owns them
  (`legacyPhraseOwnedBy`); the shared backup time never moves; the shared
  entries are never written or deleted. Native keeps the default store.
  Adds a direct `flutter_secure_storage` dependency (already transitive).
  `testing.dart` gains `InMemorySecretStorage`.
- `BackupSetupStatus` + `backupSetupStatusProvider` (words present?
  confirmed? last backup?) and `BackupSetupReminder`, a dismissable
  "Finish setup" line with Set up / Dismiss (operator ruling 48). A
  dismissal lasts 30 days (`reminderSnooze`). Stored per app via
  `backupReminderStoreProvider`; `testing.dart` gains
  `InMemoryBackupReminderStore`.
- `BackupFlow.showRecoveryWords` and a "Show my recovery words" tile
  (whenever words exist), behind a confirm — the package has no device
  lock of its own.

### Changed
- `BackupSettingsSection` draws its heading and its tiles from one
  widget. Loading shows the heading with "Checking backup status…"; a
  failed read shows the heading, a message and Try again — never
  `SizedBox.shrink()` under an app's heading. The heading is neutral
  (theme text colour, not `colorScheme.primary`), reads "Backup" by
  default, and takes a `title` parameter.
- Plain words: "Load data from a backup file" (was "an .ohbk file");
  "Remove recovery words" (was "Reset identity"), with a matching dialog;
  the vault sheet no longer says "vault".
- `BackupFlow.runSeedSetup` stores the words only when the user taps
  "I've written this down". "Not now", or swiping the sheet away, stores
  nothing (the sheet is now dismissible, since leaving loses nothing).
  Previously the phrase was persisted the moment Set up was tapped.
- `BackupFlow.confirmPhraseReEntry` uses `PhraseReEntryDialog`. The old
  loop — close the dialog, show a snack bar, reopen it empty — is gone.
- `PhraseEntryDialog` (restore) counts words as they are typed ("7 of 12
  words") and holds its confirm button until the count reads twelve; the
  "Please enter exactly 12 words" error that clipped at large text sizes
  is gone.
- `SeedPhraseModal` sets the twelve words as a fixed table — three
  columns of four, numbered down each column — at every width and text
  size, instead of a `Wrap` of chips that folded 2-3-2. A word that does
  not fit its cell is scaled down whole, never wrapped or clipped.

## 0.2.0 — 2026-07-16

The restore-safety & retention release (BACKUP_RETENTION_SPEC): restore
became boring.

### Added
- `BackupVault` — stamped generational keep-N snapshots with pins;
  filesystem store on io, OPFS on web (`FileVaultStore` over a
  `VaultFileApi` seam; self-healing index).
- **Mandatory pre-restore snapshot**: `commitRestore` refuses to touch
  data when a snapshot of the current data cannot be vaulted first
  (`RestoreOutcome.snapshotFailed`, fail-closed). Sealed under whichever
  key performed the restore.
- Two-phase restore (`prepareRestore` → preview manifest →
  `commitRestore`) with age + per-table counts vs current in the confirm
  dialog; the "cannot be undone" line is gone because it stopped being
  true.
- Verify-by-read-back on every export (+ vault copy of every manual
  export); `exportBackup` now returns the read-back `manifest`.
- `BackupEnvelope` wrap/unwrap/describe — one envelope implementation,
  tolerant of every legacy fleet shape; optional
  `PreviewableBackupSerializer` for app-level dry-run parses.
- "Previous backups" vault sheet (restore / pin / delete) + tile, shared
  plaintext export ("Export as plain JSON", honestly labeled), silent
  7-day freshness snapshot via `runStartupMaintenance()`.
- Restore-adopt: a fresh-install phrase restore persists the typed phrase
  as the device identity (never overwrites an existing one).
- Passphrase guard test (spec §6.G): a human-passphrase key source can
  never ship without Argon2id.

### Changed
- `exportBackup` return type gains `manifest`; `BackupRepository` splits
  into `open`/`apply` (restore = both); `file_picker` constraint widened
  to `<11.0.0`.

## 0.1.0

First release — extracted from Lullaby's `sanctuary_backup` feature and made
app-agnostic.

### Added

- **`BackupSerializer`** — the app-supplied interface (`dumpAll()` /
  `restoreAll()`) bridging a consuming app's store to the encrypted pipeline,
  plus `BackupSchemaException` for future-schema rejection.
- **`SanctuaryBackupConfig`** — per-app configuration (`appId`, `aadContext`,
  `appDisplayName`, optional `restoreReplaceConsequence`, `onAfterRestore`),
  exposed through the throw-by-default `sanctuaryBackupConfigProvider` and
  `backupSerializerProvider`.
- **`BackupRepository`** — binds each OHBK blob to the app's AEAD `aadContext`
  via `GhostBackup.export`/`import`.
- **`BackupController`** — the `RestoreOutcome` enum, seed generate / re-entry
  confirm flow, `<appId>-backup-<yyyy-MM-dd>.ohbk` filenames, and an
  `onAfterRestore` hook in place of hardcoded invalidations.
- **Widgets** — `BackupSettingsSection`, `SeedPhraseModal` (re-entry confirm),
  and `PhraseEntryDialog`, all Theme-driven and app-agnostic; the modal and
  dialog bodies scroll so they survive a 320 dp × 3.0 text-scale layout.
- **Test support** (`package:sanctuary_backup_ui/testing.dart`) —
  `InMemorySecureKeyStore`, `FakeCryptoService`, and `FakeBackupSerializer`
  for consumer TDD without the OS keychain or real PBKDF2.
