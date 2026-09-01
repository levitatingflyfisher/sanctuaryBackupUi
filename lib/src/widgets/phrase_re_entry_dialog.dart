import 'package:flutter/material.dart';

/// Checks a newly written-down recovery phrase one word at a time.
///
/// Replaces a single twelve-word text box whose mismatch closed the dialog,
/// showed a snack bar at the far edge of the screen, and reopened it empty
/// (furrow:mind-in-mind-02, furrow:about-face-06). Here:
///
/// - one word per step, with a counter ("Word 5 of 12");
/// - a word that does not match is named in place, right under the field,
///   and what was typed stays in the field;
/// - earlier words are kept — Back revisits them — so one slip never costs
///   the other eleven;
/// - "Show the words again" opens the sheet over the dialog when the paper
///   copy itself is in doubt, and nothing typed is lost.
///
/// The expected words are used only for comparison and are never shown
/// here: showing them would let the check pass without the paper copy.
/// The returned phrase is still verified by
/// `BackupController.confirmSeedAcknowledged`, which stays the authority.
class PhraseReEntryDialog extends StatefulWidget {
  const PhraseReEntryDialog({
    super.key,
    required this.expectedPhrase,
    this.onShowWords,
  });

  /// The phrase the user wrote down. Compared case- and
  /// whitespace-insensitively, word by word.
  final String expectedPhrase;

  /// Shows the words again (typically a [SeedPhraseModal] with a "Done"
  /// button). When null the "Show the words again" button is hidden.
  final Future<void> Function()? onShowWords;

  /// Shows the dialog; returns the confirmed phrase, or null if cancelled.
  static Future<String?> show(
    BuildContext context, {
    required String expectedPhrase,
    Future<void> Function()? onShowWords,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => PhraseReEntryDialog(
        expectedPhrase: expectedPhrase,
        onShowWords: onShowWords,
      ),
    );
  }

  @override
  State<PhraseReEntryDialog> createState() => _PhraseReEntryDialogState();
}

class _PhraseReEntryDialogState extends State<PhraseReEntryDialog> {
  late final List<String> _expected = _split(widget.expectedPhrase);
  late final List<String> _typed = List.filled(_expected.length, '');
  final _controller = TextEditingController();
  final _focus = FocusNode();
  int _index = 0;

  /// The 1-based word that last failed to match, shown until it is edited.
  int? _mismatch;

  static List<String> _split(String phrase) =>
      phrase.trim().toLowerCase().split(RegExp(r'\s+'));

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    setState(() {
      _typed[_index] = _controller.text;
      _index = index;
      _mismatch = null;
      _controller.text = _typed[index];
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    });
    _focus.requestFocus();
  }

  void _next() {
    final word = _controller.text.trim().toLowerCase();
    if (word.isEmpty) return;
    if (word != _expected[_index]) {
      setState(() => _mismatch = _index + 1);
      return;
    }
    _typed[_index] = word;
    if (_index == _expected.length - 1) {
      Navigator.pop(context, _typed.map((w) => w.trim().toLowerCase()).join(' '));
      return;
    }
    _goTo(_index + 1);
  }

  Future<void> _showWords() async {
    _typed[_index] = _controller.text;
    await widget.onShowWords?.call();
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _expected.length;
    final isLast = _index == total - 1;
    final hasText = _controller.text.trim().isNotEmpty;

    return AlertDialog(
      // Title, content and actions scroll together so the dialog survives
      // large text scales without a vertical overflow.
      scrollable: true,
      title: const Text('Check your recovery words'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Type each word from your paper copy.'),
          const SizedBox(height: 16),
          Text(
            'Word ${_index + 1} of $total',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction:
                isLast ? TextInputAction.done : TextInputAction.next,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (_) => setState(() => _mismatch = null),
            onSubmitted: (_) => _next(),
          ),
          if (_mismatch != null) ...[
            const SizedBox(height: 8),
            // An ordinary wrapping Text, not the field's errorText: that is
            // one line and ellipsizes at large text sizes.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline,
                    size: 20, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "That doesn't match word $_mismatch on your recovery "
                    'sheet. Check word $_mismatch on your paper copy.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
          if (widget.onShowWords != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _showWords,
              child: const Text('Show the words again'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_index > 0)
          TextButton(
            key: const ValueKey('re-entry-back'),
            onPressed: () => _goTo(_index - 1),
            child: const Text('Back'),
          ),
        FilledButton(
          key: const ValueKey('re-entry-next'),
          onPressed: hasText ? _next : null,
          child: Text(isLast ? 'Confirm' : 'Next'),
        ),
      ],
    );
  }
}
