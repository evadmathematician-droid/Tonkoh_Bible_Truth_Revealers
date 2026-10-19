import 'dart:async';

import 'package:flutter/material.dart';

import '../../util/phone_utils.dart';
import '../auth/auth_manager.dart';
import '../components/phone_number_field.dart';
import 'account_migration_screen.dart';

class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ProfileSetupScreen({super.key, required this.onDone});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _nameController = TextEditingController();

  // Sierra Leone unless the user picks another country. Deliberately NOT
  // the phone's locale: a UK-locale phone in Freetown turned "034909376"
  // into "+44034909376".
  String _countryIso = kDefaultCountry;
  // Strict E.164 from PhoneNumberField, null while the number is invalid.
  String? _e164;
  bool _hasTypedNumber = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      _showSnack('Please enter your name');
      return;
    }
    if (!_hasTypedNumber) {
      _showSnack('Please enter your phone number');
      return;
    }
    final e164 = _e164;
    if (e164 == null) {
      _showSnack("That doesn't look like a valid phone number — check the "
          'digits and the country.');
      return;
    }

    setState(() => _isSaving = true);

    // Registration opens before sign-in finishes (no network wait at
    // start), so make sure we're signed in before saving.
    final signedIn = Completer<String?>();
    await AuthManager.ensureSignedIn(
      onReady: () => signedIn.complete(null),
      onError: (m) => signedIn.complete(m),
    );
    if (await signedIn.future != null) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _showSnack('No internet connection — connect and try again.');
      return;
    }

    // Only the normalized E.164 is saved (AuthManager re-checks it with the
    // same normalizePhone()).
    await AuthManager.saveProfile(
      name: name,
      phone: e164,
      countryIso: _countryIso,
      onSuccess: () {
        if (!mounted) return;
        setState(() => _isSaving = false);
        widget.onDone();
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _isSaving = false);
        _showSnack(message);
      },
      onAlreadyRegistered: (e164) {
        if (!mounted) return;
        setState(() => _isSaving = false);
        _promptMigration(e164);
      },
    );
  }

  Future<void> _promptMigration(String e164Phone) async {
    final wantsTransfer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Number already registered'),
        content: const Text(
          "This phone number already has an account. If it's yours — say you "
          "got a new device — you can transfer it here after confirming a "
          "couple of people you've chatted with.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Use another number'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
    if (wantsTransfer != true || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountMigrationScreen(
          claimedPhone: e164Phone,
          countryIso: _countryIso,
          onMigrated: widget.onDone,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF3F7FF), Colors.white],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                elevation: 8,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Welcome 👋',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF2346A0),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "Tell us your name and phone number so others know who's sharing.",
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          labelText: 'Your name',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      PhoneNumberField(
                        initialCountry: _countryIso,
                        onChanged: (e164, country) {
                          _e164 = e164;
                          _countryIso = country;
                          _hasTypedNumber = true;
                        },
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _isSaving ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF365DDB),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Text(
                            _isSaving ? 'Saving...' : 'Continue',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
