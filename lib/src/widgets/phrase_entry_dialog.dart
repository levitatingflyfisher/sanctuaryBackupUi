import 'package:flutter/material.dart';

/// Dialog prompting the user to type their 12 recovery words.
///
/// Used in two flows:
///   - Restoring from a backup file (user recalls phrase from paper)
///   - Confirming a newly-generated phrase has actually been captured
class PhraseEntryDialog extends StatefulWidget {
  const PhraseEntryDialog({
    super.key,
    this.title = _defaultTitle,
    this.body = _defaultBody,
    this.confirmLabel = _defaultConfirmLabel,
  });

  static const _defaultTitle = 'Enter your 12 recovery words';
  static const _defaultBody =
      'Type or paste the 12 words you wrote down when you set up '
      'encrypted backup.';
  static const _defaultConfirmLabel = 'Restore';

  final String title;
  final String body;
  final String confirmLabel;

  /// Shows the dialog and returns the entered phrase, or null if cancelled.
  static Future<String?> show(
    BuildContext context, {
    String title = _defaultTitle,
    String body = _defaultBody,
    String confirmLabel = _defaultConfirmLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => PhraseEntryDialog(
        title: title,
        body: body,
        confirmLabel: confirmLabel,
      ),
    );
  }

  @override
  State<PhraseEntryDialog> createState() => _PhraseEntryDialogState();
}

class _PhraseEntryDialogState extends State<PhraseEntryDialog> {
  final _controller = TextEditingController();

  static const _wordCount = 12;

  int get _typedWords {
    final text = _controller.text.trim();
    return text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Scroll title + content + actions together so the dialog survives large
      // text scales (320 dp × 3.0) without a vertical overflow.
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.body),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: 'word1 word2 word3 ...',
              border: OutlineInputBorder(),
            ),
            // Count as they type, so Confirm is simply held until the count
            // reads twelve — there is no after-the-fact rejection to show.
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              '$_typedWords of $_wordCount words',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _typedWords == _wordCount
              ? () => Navigator.pop(context, _controller.text.trim())
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
