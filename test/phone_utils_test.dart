import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tbtrapp/util/phone_utils.dart';

void main() {
  group('normalizePhone — Sierra Leone default', () {
    const want = '+23231932652';
    for (final input in [
      '031932652',
      '31932652',
      '031 932 652',
      '031-932-652',
      '(031) 932652',
      '23231932652',
      '+23231932652',
      '0023231932652',
      '+232 31 932 652',
      '+232 (0)31 932 652',
      '+232 031 932 652',
      ' 031.932.652 ',
      '＋23231932652',
    ]) {
      test('"$input" → $want', () => expect(normalizePhone(input), want));
    }

    test('wrong saved form "+031932652" is repaired',
        () => expect(normalizePhone('+031932652'), want));
    test('wrong saved form "+076123456" is repaired',
        () => expect(normalizePhone('+076123456'), '+23276123456'));

    test('other SL ranges', () {
      for (final n in ['076123456', '077123456', '078123456', '079123456',
          '088123456', '099123456', '030123456', '033123456', '034123456',
          '072564353', '075123456', '080123456', '025123456']) {
        expect(normalizePhone(n), '+232${n.substring(1)}', reason: n);
      }
    });
  });

  group('normalizePhone — other countries keep their code', () {
    test('UK with +', () =>
        expect(normalizePhone('+44 7911 123456'), '+447911123456'));
    test('UK with 00', () =>
        expect(normalizePhone('00447911123456'), '+447911123456'));
    test('Guinea', () =>
        expect(normalizePhone('+224 620 12 34 56'), '+224620123456'));
    test('Nigeria', () =>
        expect(normalizePhone('+234 803 560 0038'), '+2348035600038'));
    test('Liberia', () =>
        expect(normalizePhone('+231 77 012 3456'), '+231770123456'));
    test('Ghana typed nationally with GH default', () =>
        expect(normalizePhone('024 412 3456', defaultCountry: 'GH'),
            '+233244123456'));
    test('never forced to +232', () =>
        expect(normalizePhone('+447911123456', defaultCountry: 'SL'),
            '+447911123456'));
  });

  group('normalizePhone — invalid input returns null', () {
    for (final input in [
      '',
      '   ',
      '12',
      '12345',
      '0319',
      '+232 31',
      '+23231932652999999',
      '031932652123456789',
      'abcdefgh',
      '+0',
      '+44034909376', // UK +44 with a trunk 0 — not a real UK number
    ]) {
      test('"$input" → null', () => expect(normalizePhone(input), isNull));
    }
  });

  group('random spacing and punctuation', () {
    final rng = Random(42);
    const seps = [' ', '-', '.', '(', ')', '  ', '/'];
    String scramble(String s) {
      final b = StringBuffer();
      for (final ch in s.split('')) {
        b.write(ch);
        if (rng.nextInt(3) == 0) b.write(seps[rng.nextInt(seps.length)]);
      }
      return b.toString();
    }

    for (final base in ['031932652', '+23231932652', '0023231932652',
        '23231932652', '31932652']) {
      for (var i = 0; i < 20; i++) {
        final input = scramble(base);
        test('"$input"', () => expect(normalizePhone(input), '+23231932652'));
      }
    }
  });

  group('repairStoredPhone', () {
    test('valid E.164 stays', () =>
        expect(repairStoredPhone('+23231932652'), '+23231932652'));
    test('"+031932652" → +232', () =>
        expect(repairStoredPhone('+031932652'), '+23231932652'));
    test('bare national "088236249" → +232', () =>
        expect(repairStoredPhone('088236249'), '+23288236249'));
    test('wrong country "+44034909376" → +232', () =>
        expect(repairStoredPhone('+44034909376'), '+23234909376'));
    test('garbage stays null', () =>
        expect(repairStoredPhone('+23200000001'), isNull));
  });

  group('canonicalUserId', () {
    test('legacy auth uid unchanged', () => expect(
        canonicalUserId('IJ4xicRRPMcsUe878ibJlJVYGvp1'),
        'IJ4xicRRPMcsUe878ibJlJVYGvp1'));
    test('broken phone id repaired',
        () => expect(canonicalUserId('+031932652'), '+23231932652'));
    test('good phone id unchanged',
        () => expect(canonicalUserId('+23276123456'), '+23276123456'));
  });

  group('formatPhoneForDisplay', () {
    test('SL grouping', () =>
        expect(formatPhoneForDisplay('+23231932652'), '+232 31 932 652'));
    test('old broken form shows repaired', () =>
        expect(formatPhoneForDisplay('+031932652'), '+232 31 932 652'));
    test('UK', () =>
        expect(formatPhoneForDisplay('+447911123456'), startsWith('+44 ')));
    test('non-phone unchanged', () =>
        expect(formatPhoneForDisplay('Pastor John'), 'Pastor John'));
  });

  test('isE164', () {
    expect(isE164('+23231932652'), isTrue);
    expect(isE164('+031932652'), isFalse);
    expect(isE164('23231932652'), isFalse);
  });

  test('countryOfPhone', () {
    expect(countryOfPhone('+23231932652'), 'SL');
    expect(countryOfPhone('+2348035600038'), 'NG');
  });
}
