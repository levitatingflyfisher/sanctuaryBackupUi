import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

void main() {
  group('throw-by-default providers give an actionable message', () {
    test('sanctuaryBackupConfigProvider names the override + where', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        () => container.read(sanctuaryBackupConfigProvider),
        throwsA(
          isA<UnimplementedError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('sanctuaryBackupConfigProvider'),
              contains('overrideWithValue'),
              contains('root ProviderScope'),
            ),
          ),
        ),
      );
    });

    test('backupSerializerProvider names the override + the interface', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        () => container.read(backupSerializerProvider),
        throwsA(
          isA<UnimplementedError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('backupSerializerProvider'),
              contains('overrideWith'),
              contains('BackupSerializer'),
            ),
          ),
        ),
      );
    });
  });
}
