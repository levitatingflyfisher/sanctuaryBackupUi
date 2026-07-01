# Changelog

All notable changes to `sanctuary_backup_ui` are documented here. This package
follows [semantic versioning](https://semver.org/); until 1.0.0 the public API
may still shift between minor versions.

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
