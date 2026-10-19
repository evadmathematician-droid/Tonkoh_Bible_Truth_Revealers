import 'package:flutter/material.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../util/phone_utils.dart';

/// Phone number entry used by registration and Edit Profile: a country
/// picker (Sierra Leone by default) next to a free-form number field, and a
/// live preview of exactly what will be saved — "Your number: +232 31 932
/// 652".
///
/// The number may be typed any way people write it — with or without the
/// leading 0, with the country code, with spaces or dashes. It is turned
/// into strict E.164 by [normalizePhone]; [onChanged] reports that value
/// (null while it isn't a valid number) plus the number's country.
class PhoneNumberField extends StatefulWidget {
  /// ISO code of the country selected at start ("SL").
  final String initialCountry;

  /// Stored E.164 number to start from (Edit Profile), or empty.
  final String initialNumber;

  final void Function(String? e164, String countryIso) onChanged;
  final InputBorder? border;
  final bool enabled;

  const PhoneNumberField({
    super.key,
    this.initialCountry = kDefaultCountry,
    this.initialNumber = '',
    required this.onChanged,
    this.border,
    this.enabled = true,
  });

  @override
  State<PhoneNumberField> createState() => _PhoneNumberFieldState();
}

Country _countryFor(String iso) {
  final up = iso.toUpperCase();
  return countries.firstWhere((c) => c.code == up,
      orElse: () => countries.firstWhere((c) => c.code == kDefaultCountry));
}

/// Full ISO list with this app's core countries first.
List<Country> orderedCountries() {
  final priority = [
    for (final iso in kPriorityCountries)
      ...countries.where((c) => c.code == iso),
  ];
  final rest =
      countries.where((c) => !kPriorityCountries.contains(c.code)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  return [...priority, ...rest];
}

class _PhoneNumberFieldState extends State<PhoneNumberField> {
  late Country _country;
  final _ctrl = TextEditingController();
  String? _e164;

  @override
  void initState() {
    super.initState();
    _country = _countryFor(widget.initialCountry);
    final stored = repairStoredPhone(widget.initialNumber);
    if (stored != null) {
      try {
        final p = PhoneNumber.parse(stored);
        _country = _countryFor(p.isoCode.name);
        _ctrl.text = p.formatNsn();
      } catch (_) {
        _ctrl.text = widget.initialNumber;
      }
    } else {
      _ctrl.text = widget.initialNumber;
    }
    _recompute(notify: false);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _recompute({bool notify = true}) {
    _e164 = normalizePhone(_ctrl.text, defaultCountry: _country.code);
    if (notify) {
      widget.onChanged(
          _e164, _e164 == null ? _country.code : (countryOfPhone(_e164!) ?? _country.code));
    }
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<Country>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CountrySheet(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _country = picked;
      _recompute();
    });
  }

  @override
  Widget build(BuildContext context) {
    final border = widget.border ??
        OutlineInputBorder(borderRadius: BorderRadius.circular(14));
    final text = _ctrl.text.trim();
    final valid = _e164 != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // An InputDecorator needs a bounded width, and a Row gives its
            // non-flexible children none — so the picker gets a fixed
            // compact width, and its content shrinks to fit (long dial
            // codes, large system font) instead of overflowing.
            SizedBox(
              width: 108,
              child: InkWell(
                key: const Key('phoneCountryPicker'),
                borderRadius: BorderRadius.circular(14),
                onTap: widget.enabled ? _pickCountry : null,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Country',
                    border: border,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_country.flag,
                            style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 4),
                        Text('+${_country.dialCode}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('phoneNumberInput'),
                controller: _ctrl,
                enabled: widget.enabled,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                decoration: InputDecoration(
                  labelText: 'Phone number',
                  hintText: _country.code == 'SL' ? '076 123 456' : null,
                  border: border,
                ),
                onChanged: (_) => setState(_recompute),
              ),
            ),
          ],
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(valid ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: valid
                      ? const Color(0xFF2E7D32)
                      : Theme.of(context).colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  valid
                      ? 'Your number: ${formatPhoneForDisplay(_e164!)}'
                      : 'Not a valid ${_country.name} number — check the '
                          'digits or pick another country.',
                  key: const Key('phonePreview'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: valid ? FontWeight.w600 : FontWeight.normal,
                    color: valid
                        ? const Color(0xFF2E7D32)
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _CountrySheet extends StatefulWidget {
  const _CountrySheet();

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  final _all = orderedCountries();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final list = q.isEmpty
        ? _all
        : _all
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                c.dialCode.contains(q.replaceAll('+', '')) ||
                c.code.toLowerCase() == q)
            .toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: false,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search country or code',
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final c = list[i];
                return ListTile(
                  leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                  title: Text(c.name),
                  trailing: Text('+${c.dialCode}'),
                  onTap: () => Navigator.pop(context, c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
