import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BACKUP_RETENTION_SPEC §6.G — the structural passphrase guard.
///
/// The KDF review settled that PBKDF2-2048 is fine ONLY because the root
/// secret is a machine-generated 128-bit BIP39 mnemonic, never a human
/// password. If anyone ever adds a human-passphrase key source to this
/// package, it MUST use Argon2id (OWASP floor m=19MiB, t=2, p=1). This
/// test makes that decision structural: it fails the moment lib/ starts
/// deriving keys from anything that smells like a password, unless
/// Argon2id arrives with it.
void main() {
  test(
      'no human-passphrase key derivation exists without Argon2id '
      '(spec §6.G)', () {
    final libDir = Directory('lib');
    final sources = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    final passwordish =
        RegExp(r'password|passphrase|pass_phrase', caseSensitive: false);
    final argon = RegExp(r'argon2', caseSensitive: false);
    // The one sanctioned vocabulary: BIP39 "seed phrase" / "recovery
    // words" / "phrase" wording tied to the mnemonic flow.
    final sanctioned = RegExp(
        r'seedPhrase|seed phrase|recovery words|PhraseEntry|reEntryPhrase|'
        r'deriveKeysFromPhrase|restoreWithPhrase|prepareRestoreWithPhrase|'
        r'wrongPhrase|confirmPhraseReEntry|generateSeedPhrase|'
        r'SeedPhraseMismatch|invalid recovery phrase|recovery phrase',
        caseSensitive: false);

    // Argon2 evidence must live in the SAME FILE as the offending
    // vocabulary — a stray "argon2" comment elsewhere in lib/ must not
    // neutralize the guard for the whole package. (Scope limitation,
    // recorded: this scans only this package; sanctuary_auth_core is
    // frozen and carries its own review discipline.)
    final offenders = <String>[];
    for (final file in sources) {
      final text = file.readAsStringSync();
      if (argon.hasMatch(text)) continue;
      for (final line in text.split('\n')) {
        if (passwordish.hasMatch(line) && !sanctioned.hasMatch(line)) {
          offenders.add('${file.path}: ${line.trim()}');
        }
      }
    }

    if (offenders.isNotEmpty) {
      fail(
        'Password/passphrase vocabulary appeared in lib/ without Argon2id '
        'in the same file.\nA human-secret key source MUST ship with '
        'Argon2id (OWASP m=19MiB, t=2, p=1 floor) — see '
        'BACKUP_RETENTION_SPEC §6.G and the README.\n'
        'Offending lines:\n${offenders.join('\n')}',
      );
    }
  });
}
