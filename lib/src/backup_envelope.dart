import 'dart:convert';
import 'dart:typed_data';

import 'backup_serializer.dart';

/// The decoded result of [BackupEnvelope.unwrap]: a validated backup payload
/// plus the envelope metadata needed for preview and staleness display.
class UnwrappedBackup {
  /// Schema version recorded at backup time (≤ the app's current version).
  final int schemaVersion;

  /// When the backup was created, or null for pre-v2 backups that never
  /// stamped one (shown as "unknown age" in preview, never an error).
  final DateTime? createdAt;

  /// The app's own data, exactly as it passed to [BackupEnvelope.wrap].
  final Map<String, Object?> payload;

  const UnwrappedBackup({
    required this.schemaVersion,
    required this.createdAt,
    required this.payload,
  });
}

/// Lenient, read-only description of a backup payload — what
/// preview-before-restore shows. Unlike [BackupEnvelope.unwrap] it never
/// rejects: missing fields are null so the UI can say "unknown" instead of
/// refusing to describe a legacy file.
class BackupManifest {
  final String? appId;
  final int? schemaVersion;
  final DateTime? createdAt;

  /// Row count per table, for "12 sessions, 2 profiles" preview lines.
  /// Counts every List-valued entry of the payload (and of a legacy
  /// top-level `tables` map).
  final Map<String, int> tableCounts;

  const BackupManifest({
    required this.appId,
    required this.schemaVersion,
    required this.createdAt,
    required this.tableCounts,
  });
}

/// The fleet-standard backup envelope: `{app, schemaVersion, createdAt,
/// payload}`, JSON-encoded to UTF-8 bytes.
///
/// Nine apps hand-rolled this shape independently (SANCTUARY-BRIEF §2.8);
/// this helper is the single implementation they migrate to so the shape
/// stops drifting, and it adds the `createdAt` stamp that
/// preview-before-restore and staleness copy need. [unwrap] stays tolerant
/// of the pre-helper shapes: `createdAt` may be absent (age shows
/// "unknown"), and [describe] also understands the `{app, schemaVersion,
/// tables}` variant.
abstract final class BackupEnvelope {
  /// Encodes [payload] under the standard envelope. [createdAt] is always
  /// stored as UTC ISO-8601.
  static Uint8List wrap({
    required String appId,
    required int schemaVersion,
    required DateTime createdAt,
    required Map<String, Object?> payload,
  }) {
    final envelope = <String, Object?>{
      'app': appId,
      'schemaVersion': schemaVersion,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'payload': payload,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  /// Decodes and validates an envelope produced by [wrap] or any of the
  /// fleet's legacy hand-rolled shapes (`{app, schemaVersion, payload}`,
  /// `{app, schemaVersion, exportedAt, tables}`, flat domain keys).
  ///
  /// Throws [FormatException] for malformed JSON, a mismatched `app`, or a
  /// missing `schemaVersion`; throws [BackupSchemaException] when the
  /// backup's schema is newer than [currentSchemaVersion] — the same
  /// contract every per-app serializer implemented by hand before this
  /// helper existed.
  ///
  /// [requireAppKey] exists for exactly one reason: Lullaby's shipped
  /// envelopes predate the `app` key. Pass `false` there — an ABSENT key
  /// is then tolerated, but a present-and-wrong one still rejects (the
  /// AEAD context already cryptographically binds the blob to the app;
  /// this check is defense in depth, not the lock).
  ///
  /// The returned payload is `decoded['payload']` when that key holds a
  /// map (the [wrap] shape), otherwise the whole envelope map — legacy
  /// `tables`/flat shapes keep their keys addressable either way. An
  /// envelope with no data keys is accepted here and left to the app's
  /// own restore validation, because "which keys are required" is app
  /// semantics the fleet never agreed on.
  static UnwrappedBackup unwrap(
    Uint8List plaintext, {
    required String expectedAppId,
    required int currentSchemaVersion,
    bool requireAppKey = true,
  }) {
    final decoded = _decodeJsonMap(plaintext);

    final app = decoded['app'];
    final appAcceptable = app is String
        ? app == expectedAppId
        : (app == null && !requireAppKey);
    if (!appAcceptable) {
      throw FormatException(
          "Not a backup for this app (app='${app ?? 'missing'}')");
    }

    final version = decoded['schemaVersion'];
    if (version is! int) {
      throw const FormatException('Missing schemaVersion in backup envelope');
    }
    if (version > currentSchemaVersion) {
      throw BackupSchemaException(version, currentSchemaVersion);
    }

    final payload = decoded['payload'];
    return UnwrappedBackup(
      schemaVersion: version,
      createdAt: _stamp(decoded),
      payload: payload is Map<String, dynamic> ? payload : decoded,
    );
  }

  /// Lenient description for preview: reports whatever envelope metadata is
  /// present (nulls for anything missing) and per-table row counts. Only
  /// throws [FormatException] when the bytes aren't a JSON object at all.
  static BackupManifest describe(Uint8List plaintext) {
    final decoded = _decodeJsonMap(plaintext);

    final counts = <String, int>{};
    void countLists(Object? node) {
      if (node is Map<String, dynamic>) {
        for (final entry in node.entries) {
          final value = entry.value;
          if (value is List) counts[entry.key] = value.length;
        }
      }
    }

    countLists(decoded['payload']);
    // Legacy variants: tables (Lullaby/Lilt/Furrow/Glass) or data
    // (StillLife) at the top level instead of under `payload`.
    countLists(decoded['tables']);
    countLists(decoded['data']);
    // Legacy variant: rows directly at the top level alongside the
    // metadata (Bulwark/Reckon flat domain keys).
    if (decoded['payload'] == null &&
        decoded['tables'] == null &&
        decoded['data'] == null) {
      countLists(decoded);
    }

    final app = decoded['app'];
    final version = decoded['schemaVersion'];
    return BackupManifest(
      appId: app is String ? app : null,
      schemaVersion: version is int ? version : null,
      createdAt: _stamp(decoded),
      tableCounts: counts,
    );
  }

  /// The envelope's creation stamp under any of the fleet's key spellings:
  /// canonical `createdAt`, else `exportedAt` (tables-shape apps), else
  /// `generatedAt` (Reckon).
  static DateTime? _stamp(Map<String, dynamic> decoded) =>
      _parseCreatedAt(decoded['createdAt']) ??
      _parseCreatedAt(decoded['exportedAt']) ??
      _parseCreatedAt(decoded['generatedAt']);

  static Map<String, dynamic> _decodeJsonMap(Uint8List plaintext) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on Object {
      // utf8.decode throws FormatException already; jsonDecode too — but
      // normalize anything unexpected into the one contract callers handle.
      throw const FormatException('Backup payload is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup payload is not a JSON object');
    }
    return decoded;
  }

  /// Age must be information, never an obstacle: an absent or unparseable
  /// stamp reads as null ("unknown age"), not a rejected backup.
  static DateTime? _parseCreatedAt(Object? raw) {
    if (raw is! String) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed?.toUtc();
  }
}
