import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../screens/auth/auth_manager.dart';

enum MigrationStatus {
  /// Verified — the account is now claimed by this device. [profile] holds
  /// the account record so it can be cached locally.
  success,

  /// Submitted numbers didn't all match prior chat partners.
  mismatch,

  /// Too many failed attempts — locked until [lockedUntil].
  locked,

  /// The account has no prior chat partners to verify against — the screen
  /// then offers a plain confirmation transfer
  /// ([MigrationService.confirmNoPartnerTransfer]) that signs the account
  /// out on all other devices.
  noPartners,

  /// The server wants exactly [MigrationOutcome.requiredCount] partner
  /// numbers (used by the precheck to size the form). Not a failed attempt.
  needN,

  /// Endpoint unreachable / not deployed / bad response.
  unavailable,
}

class MigrationOutcome {
  final MigrationStatus status;
  final int requiredCount; // needN
  final int attemptsUntilLock; // mismatch
  final int? lockedUntil; // epoch ms — locked, or a mismatch that just locked
  final Map<String, dynamic>? profile; // success

  /// Human-readable reason the call didn't succeed — shown on the
  /// "unavailable" screen so a bad Worker deploy is diagnosable from a
  /// screenshot instead of guesswork. Empty on success.
  final String diagnostic;

  const MigrationOutcome(
    this.status, {
    this.requiredCount = 0,
    this.attemptsUntilLock = 0,
    this.lockedUntil,
    this.profile,
    this.diagnostic = '',
  });
}

/// Talks to the Cloudflare Worker `/migration-verify` endpoint. The Worker
/// owns the verification against `userChats/{claimedPhone}` and the
/// server-authoritative failed-attempt counter / lockout — none of that can
/// live on the client (an attacker would just skip it). See
/// `cloudflare/migration_worker.js` for the endpoint contract.
class MigrationService {
  MigrationService._();
  static final MigrationService instance = MigrationService._();

  static const _endpoint =
      'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/migration-verify';
  static const _secret = 'test-relay-secret-123';

  Future<MigrationOutcome> _post(
    String claimedPhone,
    List<String> candidates, {
    bool confirmNoPartners = false,
  }) async {
    try {
      final newDeviceId = await AuthManager.deviceId();
      debugPrint('MigrationService: POST claimedPhone=$claimedPhone '
          'candidates=${candidates.length} confirmNoPartners=$confirmNoPartners '
          'newDeviceId=$newDeviceId');
      final resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'secret': _secret,
              'claimedPhone': claimedPhone,
              'candidates': candidates,
              'confirmNoPartners': confirmNoPartners,
              'newDeviceId': newDeviceId,
              'newOneSignalId': OneSignal.User.pushSubscription.id ?? '',
            }),
          )
          .timeout(const Duration(seconds: 20));

      dynamic body;
      try {
        body = jsonDecode(resp.body);
      } catch (_) {
        body = null;
      }
      debugPrint('MigrationService: HTTP ${resp.statusCode} body=${resp.body}');

      if (body is! Map) {
        return MigrationOutcome(
          MigrationStatus.unavailable,
          diagnostic: 'HTTP ${resp.statusCode}: '
              '${resp.body.isEmpty ? "(empty response)" : resp.body}',
        );
      }

      if (body['ok'] == true) {
        return MigrationOutcome(
          MigrationStatus.success,
          profile: (body['profile'] as Map?)?.cast<String, dynamic>(),
        );
      }

      final lockedUntil = (body['lockedUntil'] as num?)?.toInt();
      final reason = body['reason'];
      switch (reason) {
        case 'locked':
          return MigrationOutcome(MigrationStatus.locked,
              lockedUntil: lockedUntil);
        case 'mismatch':
          return MigrationOutcome(
            MigrationStatus.mismatch,
            attemptsUntilLock:
                (body['attemptsUntilLock'] as num?)?.toInt() ?? 0,
            lockedUntil: lockedUntil,
          );
        case 'no_partners':
          return const MigrationOutcome(MigrationStatus.noPartners);
        case 'need_n':
          return MigrationOutcome(
            MigrationStatus.needN,
            requiredCount: (body['required'] as num?)?.toInt() ?? 1,
            lockedUntil: lockedUntil,
          );
        case 'bad_secret':
          return const MigrationOutcome(
            MigrationStatus.unavailable,
            diagnostic:
                'Worker rejected the shared secret (RELAY_SECRET on the '
                'Worker must equal the app\'s _secret).',
          );
        case 'bad_request':
          return const MigrationOutcome(
            MigrationStatus.unavailable,
            diagnostic: 'Worker: bad_request (missing claimedPhone / '
                'newDeviceId).',
          );
        default:
          return MigrationOutcome(
            MigrationStatus.unavailable,
            diagnostic: 'Worker reason="$reason" '
                'detail="${body['detail'] ?? ''}"',
          );
      }
    } on http.ClientException catch (e) {
      return MigrationOutcome(MigrationStatus.unavailable,
          diagnostic: 'Network error: $e');
    } catch (e) {
      debugPrint('MigrationService: $e');
      return MigrationOutcome(MigrationStatus.unavailable,
          diagnostic: e.toString());
    }
  }

  /// Learn how many partner numbers are required (and whether currently
  /// locked) without spending a failed attempt.
  Future<MigrationOutcome> precheck(String claimedPhone) =>
      _post(claimedPhone, const []);

  /// Submit the claimed prior chat-partner numbers. On success the account
  /// has been reassigned to this device server-side.
  Future<MigrationOutcome> verify(
          String claimedPhone, List<String> candidates) =>
      _post(claimedPhone, candidates);

  /// For an account with no chat history to verify against: transfer it to
  /// this device on plain confirmation. This signs the account out on every
  /// other device that has it. Subject to a short server-side cooldown
  /// between such transfers.
  Future<MigrationOutcome> confirmNoPartnerTransfer(String claimedPhone) =>
      _post(claimedPhone, const [], confirmNoPartners: true);
}
