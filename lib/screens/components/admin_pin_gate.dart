import 'package:flutter/material.dart';

import '../auth/auth_manager.dart';

/// Shared PIN-entry gate for every admin-only screen. Extracted out of
/// AdminScreen so AdminAudioApprovalScreen can use the exact same check
/// instead of trusting that users only ever arrive there through
/// AdminScreen's button — GoRouter exposes `/adminApproval` directly, so
/// without its own gate that route had no PIN protection at all.
class AdminPinGate extends StatefulWidget {
  final VoidCallback onUnlock;
  const AdminPinGate({super.key, required this.onUnlock});

  @override
  State<AdminPinGate> createState() => _AdminPinGateState();
}

class _AdminPinGateState extends State<AdminPinGate> {
  final _pinController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  void _submit() {
    if (AuthManager.isAdminPinCorrect(_pinController.text)) {
      AuthManager.isAdminUnlockedThisSession = true;
      widget.onUnlock();
    } else {
      setState(() {
        _errorText = 'Incorrect PIN';
        _pinController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF163E8E), Color(0xFFEEF4FF)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              elevation: 10,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🔒 Admin Access',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF163E8E))),
                    const SizedBox(height: 8),
                    const Text('Enter PIN to continue',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey)),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      onChanged: (_) => setState(() => _errorText = null),
                      decoration: InputDecoration(
                        labelText: 'PIN',
                        counterText: '',
                        errorText: _errorText,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E5BFF),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Unlock', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
