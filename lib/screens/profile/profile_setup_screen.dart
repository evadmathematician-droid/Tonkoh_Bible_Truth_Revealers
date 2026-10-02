import 'package:flutter/material.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:intl_phone_field/intl_phone_field.dart';

import '../auth/auth_manager.dart';
import 'account_migration_screen.dart';

// Countries pinned to the top of the picker — this app's core user base.
// Everyone else picks their own country from the full ISO list the
// package ships, so users from any country are fully supported.
const List<String> _priorityIso = ['SL', 'GN', 'LR', 'GH', 'NG'];

/// Full ISO country list with the priority countries hoisted to the top.
List<Country> _orderedCountries() {
  final priority = <Country>[];
  for (final iso in _priorityIso) {
    final match = countries.where((c) => c.code == iso);
    if (match.isNotEmpty) priority.add(match.first);
  }
  final rest = countries.where((c) => !_priorityIso.contains(c.code)).toList();
  return [...priority, ...rest];
}

/// Best-guess starting country so most people never have to open the
/// picker. Device locale country if we recognise it, otherwise Sierra
/// Leone. This is ONLY the pre-selection — it is always overridable, and
/// it is never assumed once the user has picked or typed a number.
String _defaultCountryIso() {
  final localeCountry =
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  if (localeCountry != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(localeCountry)) {
    return localeCountry.toUpperCase();
  }
  return 'SL';
}

class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ProfileSetupScreen({super.key, required this.onDone});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _nameController = TextEditingController();

  late String _countryIso;
  // Full international number the picker produced, e.g. "+23376123456".
  String _completeNumber = '';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _countryIso = _defaultCountryIso();
  }

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
    if (_completeNumber.trim().isEmpty) {
      _showSnack('Please enter your phone number');
      return;
    }

    setState(() => _isSaving = true);

    // AuthManager.saveProfile runs the SAME normalizePhone() path used for
    // contact matching. We hand it the already-international number (with
    // its "+" and dial code from the picker) plus the selected ISO, so the
    // stored value is correct global E.164 for ANY country — no "+232"
    // assumption anywhere.
    await AuthManager.saveProfile(
      name: name,
      phone: _completeNumber.trim(),
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
                      IntlPhoneField(
                        initialCountryCode: _countryIso,
                        countries: _orderedCountries(),
                        disableLengthCheck: false,
                        invalidNumberMessage: 'Invalid phone number',
                        decoration: InputDecoration(
                          labelText: 'Phone number',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onCountryChanged: (country) {
                          setState(() => _countryIso = country.code);
                        },
                        onChanged: (phone) {
                          _completeNumber = phone.completeNumber;
                          _countryIso = phone.countryISOCode;
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
