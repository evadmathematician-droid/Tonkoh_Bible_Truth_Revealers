import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import '../auth/auth_manager.dart';

// Priority/local countries pinned to the top of the dropdown, matching
// PRIORITY_CODES in ProfileSetupScreen.kt.
const List<String> _priorityCodes = ['SL', 'GN', 'LR', 'GH', 'NG'];

// ⚠️ NOTE: Dart has no built-in equivalent of Kotlin's
// Locale.getISOCountries() + Locale(code).displayCountry giving all ~195
// countries with display names out of the box. This is a curated subset
// covering common countries + your priority list. If you need the full
// ISO set, the `country_picker` or `intl` (CountryNames) pub packages can
// supply it — happy to wire one in if you want full coverage instead of
// this hand-picked list.
const Map<String, String> _countryNames = {
  'SL': 'Sierra Leone',
  'GN': 'Guinea',
  'LR': 'Liberia',
  'GH': 'Ghana',
  'NG': 'Nigeria',
  'US': 'United States',
  'GB': 'United Kingdom',
  'CA': 'Canada',
  'AU': 'Australia',
  'FR': 'France',
  'DE': 'Germany',
  'ES': 'Spain',
  'IT': 'Italy',
  'NL': 'Netherlands',
  'BE': 'Belgium',
  'PT': 'Portugal',
  'IE': 'Ireland',
  'ZA': 'South Africa',
  'KE': 'Kenya',
  'ET': 'Ethiopia',
  'UG': 'Uganda',
  'TZ': 'Tanzania',
  'SN': 'Senegal',
  'CI': "Côte d'Ivoire",
  'ML': 'Mali',
  'CM': 'Cameroon',
  'EG': 'Egypt',
  'MA': 'Morocco',
  'IN': 'India',
  'PK': 'Pakistan',
  'BD': 'Bangladesh',
  'CN': 'China',
  'JP': 'Japan',
  'KR': 'South Korea',
  'PH': 'Philippines',
  'ID': 'Indonesia',
  'MY': 'Malaysia',
  'SG': 'Singapore',
  'AE': 'United Arab Emirates',
  'SA': 'Saudi Arabia',
  'BR': 'Brazil',
  'MX': 'Mexico',
  'AR': 'Argentina',
  'CO': 'Colombia',
  'JM': 'Jamaica',
  'TT': 'Trinidad and Tobago',
};

List<MapEntry<String, String>> get _countryOptions {
  final all = _countryNames.entries.toList();
  final priority = _priorityCodes
      .map((c) => all.firstWhere((e) => e.key == c, orElse: () => MapEntry(c, c)))
      .toList();
  final rest = all.where((e) => !_priorityCodes.contains(e.key)).toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  return [...priority, ...rest];
}

// Best-guess default so most people never have to touch the picker.
// No SIM-country API available in plain Flutter without a platform
// plugin (e.g. sim_data), so this falls back through device locale only,
// then Sierra Leone — one rung shorter than the Kotlin version.
String _detectDefaultCountry() {
  final localeCountry =
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  if (localeCountry != null &&
      localeCountry.isNotEmpty &&
      _countryNames.containsKey(localeCountry)) {
    return localeCountry;
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
  final _phoneController = TextEditingController();
  late String _countryIso;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _countryIso = _detectDefaultCountry();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String get _selectedCountryName =>
      _countryNames[_countryIso] ?? _countryIso;

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || phone.isEmpty) {
      _showSnack('Please fill in both fields');
      return;
    }

    setState(() => _isSaving = true);

    await AuthManager.saveProfile(
      name: name,
      phone: phone,
      countryIso: _countryIso,
      onSuccess: () {
        setState(() => _isSaving = false);
        widget.onDone();
      },
      onError: (message) {
        setState(() => _isSaving = false);
        _showSnack('Error: $message');
      },
    );
  }

  Future<void> _openCountryPicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _CountryPickerSheet(currentIso: _countryIso),
    );
    if (selected != null) {
      setState(() => _countryIso = selected);
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
                        decoration: InputDecoration(
                          labelText: 'Your name',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      InkWell(
                        onTap: _openCountryPicker,
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Country',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            suffixIcon: const Icon(Icons.arrow_drop_down),
                          ),
                          child: Text(_selectedCountryName),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: 'Phone number',
                          hintText: 'With or without country code',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
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

/// Searchable country picker, equivalent role to CountryPickerField's
/// Popup+LazyColumn in the Kotlin version. Uses ListView.builder so only
/// visible rows are built, same performance intent as LazyColumn.
class _CountryPickerSheet extends StatefulWidget {
  final String currentIso;
  const _CountryPickerSheet({required this.currentIso});

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final options = _countryOptions
        .where((e) => _query.isEmpty ||
        e.value.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search country',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: options.isEmpty
                    ? const Center(
                  child: Text('No matches', style: TextStyle(color: Colors.grey)),
                )
                    : ListView.builder(
                  controller: scrollController,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final entry = options[index];
                    return ListTile(
                      title: Text(entry.value),
                      onTap: () => Navigator.pop(context, entry.key),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}