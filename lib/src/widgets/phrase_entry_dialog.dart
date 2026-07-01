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
  String? _error;

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
            decoration: InputDecoration(
              hintText: 'word1 word2 word3 ...',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final phrase = _controller.text.trim();
            final wordCount = phrase.split(RegExp(r'\s+')).length;
            if (wordCount != 12) {
              setState(() => _error = 'Please enter exactly 12 words');
              return;
            }
            Navigator.pop(context, phrase);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
