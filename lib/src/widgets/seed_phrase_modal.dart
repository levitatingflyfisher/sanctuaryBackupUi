import 'package:flutter/material.dart';

/// Displays the 12-word seed phrase in a modal bottom sheet.
/// The user must tap "I've written this down" to dismiss.
///
/// App-agnostic: all colours and type come from [Theme.of].
class SeedPhraseModal extends StatelessWidget {
  final String phrase;
  final VoidCallback onAcknowledged;

  const SeedPhraseModal({
    super.key,
    required this.phrase,
    required this.onAcknowledged,
  });

  @override
  Widget build(BuildContext context) {
    final words = phrase.split(' ');
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      // Scrollable so the sheet survives large text scales (320 dp × 3.0)
      // without a vertical overflow.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your recovery words',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Write these 12 words down on paper and keep them somewhere '
              'safe. They are the only way to recover your data on a new '
              'device.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < words.length; i++)
                    Chip(
                      label: Text('${i + 1}. ${words[i]}'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  onAcknowledged();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.check),
                label: const Text("I've written this down"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
