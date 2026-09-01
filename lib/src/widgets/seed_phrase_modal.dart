import 'package:flutter/material.dart';

/// Displays the 12-word seed phrase in a modal bottom sheet.
/// The user must tap "I've written this down" to dismiss.
///
/// App-agnostic: all colours and type come from [Theme.of].
class SeedPhraseModal extends StatelessWidget {
  final String phrase;
  final VoidCallback onAcknowledged;

  /// The button label. Setup uses the default; viewing the words again
  /// passes e.g. `'Done'`.
  final String acknowledgeLabel;

  /// When set, a secondary button with this label closes the sheet without
  /// acknowledging (popping `false`) — setup passes `'Not now'`.
  final String? declineLabel;

  const SeedPhraseModal({
    super.key,
    required this.phrase,
    required this.onAcknowledged,
    this.acknowledgeLabel = "I've written this down",
    this.declineLabel,
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
            _WordTable(words: words),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  onAcknowledged();
                  Navigator.pop(context, true);
                },
                icon: const Icon(Icons.check),
                label: Text(acknowledgeLabel),
              ),
            ),
            if (declineLabel != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(declineLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The twelve words as a fixed table: three columns of four, numbered down
/// each column, identical on every phone width and at every text size.
///
/// A `Wrap` of chips folded the words 2-3-2 at whatever width the phone
/// had, so the sheet a person copied from and the sheet they checked
/// against could differ (furrow:visual-display-11). Each cell scales its
/// line down rather than breaking a word or clipping it: a whole word in
/// smaller type can still be copied exactly; half a word cannot.
///
/// Columns are laid out as three `Column`s, so a screen reader reads 1 to
/// 12 in order rather than across rows.
class _WordTable extends StatelessWidget {
  const _WordTable({required this.words});

  final List<String> words;

  static const _rows = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final numberStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final wordStyle = theme.textTheme.titleMedium;
    final columns = (words.length / _rows).ceil();
    // One fixed row height for every cell, from the user's text size, so a
    // cell whose word had to shrink to fit does not pull its row out of
    // line with the other two columns.
    final fontSize = wordStyle?.fontSize ?? 16;
    final rowHeight =
        MediaQuery.textScalerOf(context).scale(fontSize) * 1.5 + 12;

    Widget cell(int index) {
      final n = index + 1;
      return Container(
        key: ValueKey('seed-word-$n'),
        height: rowHeight,
        padding: const EdgeInsets.symmetric(vertical: 6),
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // Figure-space padding keeps 1-9 right-aligned with 10-12.
              Text(n.toString().padLeft(2, '\u2007'), style: numberStyle),
              const SizedBox(width: 8),
              Text(
                words[index],
                style: wordStyle,
                maxLines: 1,
                softWrap: false,
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < columns; c++)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var r = 0; r < _rows; r++)
                  if (c * _rows + r < words.length) cell(c * _rows + r),
              ],
            ),
          ),
      ],
    );
  }
}
