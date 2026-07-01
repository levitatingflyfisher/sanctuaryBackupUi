import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

Widget _harness({
  required VaultStore vault,
  SecureKeyStore? store,
}) {
  return ProviderScope(
    overrides: [
      secureKeyStoreProvider.overrideWithValue(store ??
          InMemorySecureKeyStore(mnemonic: _validPhrase, acknowledged: true)),
      cryptoServiceProvider
          .overrideWithValue(FakeCryptoService(mnemonic: _validPhrase)),
      backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
      sanctuaryBackupConfigProvider.overrideWithValue(
        const SanctuaryBackupConfig(
          appId: 'testapp',
          aadContext: 'testapp-backup/v1',
          appDisplayName: 'TestApp',
        ),
      ),
      vaultStoreProvider.overrideWithValue(vault),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showBackupVaultSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<VaultEntry> _seed(
  VaultStore store, {
  VaultLabel label = VaultLabel.manual,
  bool pinned = false,
  DateTime? at,
}) {
  final vault = BackupVault(store,
      appId: 'testapp', now: at == null ? null : () => at);
  return vault.save(Uint8List.fromList([1, 2, 3]),
      label: label, pinned: pinned);
}

void main() {
  late InMemoryVaultStore store;

  setUp(() => store = InMemoryVaultStore());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(_harness(vault: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty vault shows the calm empty state', (tester) async {
    await open(tester);
    expect(find.text('Previous backups'), findsOneWidget);
    expect(find.textContaining('No snapshots yet'), findsOneWidget);
  });

  testWidgets('lists entries with legible labels, age and size',
      (tester) async {
    await _seed(store,
        label: VaultLabel.preRestore,
        at: DateTime.utc(2026, 7, 10, 8));
    await _seed(store,
        label: VaultLabel.manual, at: DateTime.utc(2026, 7, 12, 8));
    await open(tester);

    expect(find.textContaining('Safety snapshot'), findsOneWidget);
    expect(find.textContaining('Manual backup'), findsOneWidget);
    expect(find.textContaining('days old'), findsWidgets);
    expect(find.textContaining('3 B'), findsWidgets);
  });

  testWidgets('pin action protects the entry in the store', (tester) async {
    final entry = await _seed(store);
    await open(tester);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    final listed = await store.list();
    expect(listed.single.id, entry.id);
    expect(listed.single.pinned, isTrue);
    // And the sheet re-rendered showing the pin (the menu action refreshes
    // fire-and-forget, so give the rebuilt frame a pump).
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });

  testWidgets('delete asks first, then removes entry and bytes',
      (tester) async {
    final entry = await _seed(store);
    await open(tester);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete snapshot?'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(await store.read(entry.id), isNull);
    await tester.pumpAndSettle();
    expect(find.textContaining('No snapshots yet'), findsOneWidget);
  });

  testWidgets(
      'restore from a snapshot routes through the SAME preview + confirm '
      'path as a file restore', (tester) async {
    // Seed with a REAL sealed blob so prepare can decrypt it.
    final key = Uint8List(32)..fillRange(0, 32, 7);
    final envelope = BackupEnvelope.wrap(
      appId: 'testapp',
      schemaVersion: 1,
      createdAt: DateTime.utc(2026, 7, 1),
      payload: {
        'sessions': [{}, {}]
      },
    );
    final sealed = await GhostBackup.export(envelope, key, EnvelopeCipher(),
        context: 'testapp-backup/v1');
    final vault = BackupVault(store, appId: 'testapp');
    await vault.save(sealed, label: VaultLabel.manual);

    await open(tester);
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Replace all data?'), findsOneWidget);
    expect(find.textContaining('sessions: 2 in backup'), findsOneWidget);
  });

  testWidgets('no overflow at 320 dp x 3.0 text scale with entries',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _seed(store, label: VaultLabel.preRestore, pinned: true);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(3.0)),
      child: _harness(vault: store),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
