import 'package:flutter/material.dart';

import '../data/feedback_repository.dart';

/// Flutter port of the Kotlin/Compose `FeedbackScreen`.
///
/// Two required fields (WhatsApp number + message), a single-select
/// "TYPE OF FEEDBACK" chip pair defaulting to "improvement", a submit
/// button gated on both fields being non-blank, and — on a successful send —
/// the phone + message clear (the selected type stays) and a green
/// confirmation line appears below the form. The form scrolls and lifts
/// above the keyboard.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  static const _accent = Color(0xFF102A72);
  static const _bg = Color(0xFFF6F8FC);
  static const _muted = Color(0xFF6B7280);

  final _phoneController = TextEditingController();
  final _messageController = TextEditingController();

  String _type = 'improvement'; // 'improvement' | 'challenge'
  bool _isSending = false;
  bool _sent = false;

  bool get _canSubmit =>
      _phoneController.text.trim().isNotEmpty &&
      _messageController.text.trim().isNotEmpty &&
      !_isSending;

  @override
  void dispose() {
    _phoneController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _isSending = true;
      _sent = false;
    });

    try {
      await FeedbackRepository.instance.sendFeedback(
        message: _messageController.text,
        type: _type,
        phone: _phoneController.text,
      );
      if (!mounted) return;
      setState(() {
        // Clear the fields but keep the selected type — the form is not
        // reset and we do not navigate away.
        _phoneController.clear();
        _messageController.clear();
        _isSending = false;
        _sent = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send feedback: $e')),
      );
    }
  }

  OutlineInputBorder _border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  InputDecoration _fieldDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: _muted),
        floatingLabelStyle: const TextStyle(color: _accent),
        enabledBorder: _border(const Color(0xFFD1D5DB)),
        focusedBorder: _border(_accent, 1.6),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        foregroundColor: _accent,
        title: const Text('Feedback'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            // imePadding equivalent — grow the scroll extent above the keyboard
            // so nothing is ever hidden behind it.
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Card(
            elevation: 2,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Send Feedback',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _accent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Tell us what's working and what isn't — we read every message.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    onChanged: (_) => setState(() {}),
                    decoration: _fieldDecoration('WhatsApp number'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _messageController,
                    minLines: 6,
                    maxLines: 10,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: _fieldDecoration('Your message'),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'TYPE OF FEEDBACK',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _TypeChip(
                          label: 'Improvement',
                          selected: _type == 'improvement',
                          onTap: () => setState(() => _type = 'improvement'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _TypeChip(
                          label: 'Challenge',
                          selected: _type == 'challenge',
                          onTap: () => setState(() => _type = 'challenge'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _canSubmit ? _submit : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        disabledBackgroundColor:
                            _accent.withValues(alpha: 0.4),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isSending
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Submit',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                    ),
                  ),
                  if (_sent) ...[
                    const SizedBox(height: 16),
                    const Text(
                      '✓ Thanks — your feedback was sent.',
                      style: TextStyle(
                        color: Color(0xFF2E7D32),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  static const _accent = Color(0xFF102A72);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _accent : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? _accent : const Color(0xFFE0E0E0),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
