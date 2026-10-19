import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/migration_service.dart';
import '../../data/profile_photo_cache.dart';
import '../../util/phone_utils.dart';
import '../auth/auth_manager.dart';

/// Self-service account transfer. Reached from `ProfileSetupScreen` when the
/// number being registered already has an account: the claimant proves
/// ownership by naming 1–2 real prior chat partners of that account. The
/// Worker owns verification + the escalating failed-attempt lockout; this
/// screen is just the form + state display.
class AccountMigrationScreen extends StatefulWidget {
  final String claimedPhone; // normalised E.164
  final String countryIso; // to normalise the partner numbers entered here
  final VoidCallback onMigrated;

  const AccountMigrationScreen({
    super.key,
    required this.claimedPhone,
    required this.countryIso,
    required this.onMigrated,
  });

  @override
  State<AccountMigrationScreen> createState() => _AccountMigrationScreenState();
}

enum _Phase { loading, form, locked, noPartners, migrating, unavailable }

/// Why the transfer is locked — drives two very different messages.
enum _LockReason {
  /// Too many wrong verification numbers.
  failedAttempts,

  /// A no-history transfer for this number already went through recently
  /// (the Worker's 10-minute cooldown).
  cooldown,
}

class _AccountMigrationScreenState extends State<AccountMigrationScreen> {
  static const _accent = Color(0xFF102A72);

  _Phase _phase = _Phase.loading;
  int _required = 1;
  int? _lockedUntil;
  _LockReason _lockReason = _LockReason.failedAttempts;
  Duration _remaining = Duration.zero;
  Timer? _countdown;
  String? _error;
  String _diag = '';
  List<TextEditingController> _controllers = [];

  @override
  void initState() {
    super.initState();
    _precheck();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _precheck() async {
    setState(() => _phase = _Phase.loading);
    final r = await MigrationService.instance.precheck(widget.claimedPhone);
    if (!mounted) return;
    _applyOutcome(r, fromPrecheck: true);
  }

  void _applyOutcome(
    MigrationOutcome r, {
    bool fromPrecheck = false,
    bool noPartnerConfirm = false,
  }) {
    switch (r.status) {
      case MigrationStatus.needN:
        setState(() {
          _required = r.requiredCount.clamp(1, 2);
          for (final c in _controllers) {
            c.dispose();
          }
          _controllers =
              List.generate(_required, (_) => TextEditingController());
          _phase = _Phase.form;
        });
        break;
      case MigrationStatus.locked:
        _lockedUntil = r.lockedUntil;
        // A `locked` straight off the no-history confirm path is the 10-min
        // cooldown; otherwise it's the failed-attempts lockout.
        _lockReason = noPartnerConfirm
            ? _LockReason.cooldown
            : _LockReason.failedAttempts;
        setState(() => _phase = _Phase.locked);
        _startCountdown();
        break;
      case MigrationStatus.noPartners:
        setState(() => _phase = _Phase.noPartners);
        break;
      case MigrationStatus.mismatch:
        if (r.lockedUntil != null) {
          _lockedUntil = r.lockedUntil;
          _lockReason = _LockReason.failedAttempts;
          setState(() => _phase = _Phase.locked);
          _startCountdown();
        } else {
          setState(() {
            _phase = _Phase.form;
            _error =
                "That didn't match this account's chat history. ${r.attemptsUntilLock} attempt(s) left before a temporary lock.";
          });
        }
        break;
      case MigrationStatus.success:
        _onSuccess(r);
        break;
      case MigrationStatus.unavailable:
        setState(() {
          _diag = r.diagnostic;
          _phase = fromPrecheck
              ? _Phase.unavailable
              : (noPartnerConfirm ? _Phase.noPartners : _Phase.form);
          if (!fromPrecheck) {
            _error = 'Transfer is temporarily unavailable.'
                '${r.diagnostic.isEmpty ? '' : '\n${r.diagnostic}'}';
          }
        });
        break;
    }
  }

  Future<void> _onSuccess(MigrationOutcome r) async {
    // The account is now claimed by this device server-side. Record that
    // locally BEFORE navigating so the auth-gate device-ownership watcher
    // doesn't sign us straight back out on a stale RTDB cache emission that
    // still carries the previous owner's activeDeviceId.
    await AuthManager.markThisDeviceClaimed(widget.claimedPhone);

    // Pull + cache the profile so AuthGate can go Ready.
    await AuthManager.fetchProfile(
        phoneKey: widget.claimedPhone, onError: (_) {});
    final cached = await AuthManager.getCachedProfile();
    if (cached != null) {
      ProfilePhotoCache.instance.updateCached(cached.uid, cached.photoUrl);
    }
    if (!mounted) return;
    // Pop back to the root route; AuthGate rebuilds to the home screen when
    // onMigrated() runs.
    Navigator.of(context).popUntil((route) => route.isFirst);
    widget.onMigrated();
  }

  void _startCountdown() {
    _countdown?.cancel();
    void tick() {
      final until = _lockedUntil;
      if (until == null) return;
      final left = until - DateTime.now().millisecondsSinceEpoch;
      if (left <= 0) {
        _countdown?.cancel();
        _precheck(); // lock expired — reload
      } else {
        setState(() => _remaining = Duration(milliseconds: left));
      }
    }

    tick();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  String _fmtRemaining(Duration d) {
    if (d.inHours >= 24) {
      final days = d.inDays;
      final hrs = d.inHours % 24;
      return '${days}d ${hrs}h';
    }
    if (d.inHours >= 1) {
      return '${d.inHours}h ${d.inMinutes % 60}m';
    }
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  Future<void> _submit() async {
    // The user may fill one field or both — only ONE needs to match a real
    // chat partner for the transfer to go through. Send whichever are filled.
    final raw = _controllers
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (raw.isEmpty) {
      setState(() => _error = 'Enter at least one phone number.');
      return;
    }
    final normalised =
        raw.map((s) => normalizePhone(s, defaultCountry: widget.countryIso)).toList();
    if (normalised.any((n) => n == null)) {
      setState(() => _error = "One of those doesn't look like a valid number.");
      return;
    }

    setState(() {
      _phase = _Phase.migrating;
      _error = null;
    });
    final r = await MigrationService.instance
        .verify(widget.claimedPhone, normalised.cast<String>());
    if (!mounted) return;
    _applyOutcome(r);
  }

  // ------------------------------------------------------------------ build

  OutlineInputBorder _border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: w),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        foregroundColor: _accent,
        title: const Text('Transfer account'),
      ),
      body: SafeArea(child: _bodyForPhase()),
    );
  }

  Widget _bodyForPhase() {
    switch (_phase) {
      case _Phase.loading:
      case _Phase.migrating:
        return const Center(child: CircularProgressIndicator());
      case _Phase.unavailable:
        return _unavailableBody();
      case _Phase.noPartners:
        return _noPartnersBody();
      case _Phase.locked:
        return _messageBody(
          Icons.lock_clock,
          _lockReason == _LockReason.cooldown
              ? 'A transfer for this number was completed recently.\n'
                  'Try again in ${_fmtRemaining(_remaining)}.'
              : 'Too many failed attempts.\n'
                  'Try again in ${_fmtRemaining(_remaining)}.',
        );
      case _Phase.form:
        return _formBody();
    }
  }

  Widget _unavailableBody() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: _accent),
            const SizedBox(height: 16),
            const Text(
              'Account transfer is temporarily unavailable.\nPlease try again later.',
              textAlign: TextAlign.center,
            ),
            if (_diag.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _diag,
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF6B7280)),
                ),
              ),
            ],
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: _precheck,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  /// Zero chat partners — nothing to verify against. Offer a plain
  /// confirmation transfer that signs the account out on every other device.
  Widget _noPartnersBody() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_user_outlined, size: 48, color: _accent),
            const SizedBox(height: 16),
            const Text(
              "We couldn't find any chat history for this number, so we can't "
              "verify you that way.\n\n"
              "If this is your number, you can transfer it directly — this "
              "will sign out any other device using it.",
              textAlign: TextAlign.center,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFFC62828), fontWeight: FontWeight.w500),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _confirmNoPartnerTransfer,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Transfer anyway',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmNoPartnerTransfer() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transfer this account?'),
        content: const Text(
          'This will move the account to this device and immediately sign it '
          'out on all other devices that currently have it. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _phase = _Phase.migrating;
      _error = null;
    });
    final r = await MigrationService.instance
        .confirmNoPartnerTransfer(widget.claimedPhone);
    if (!mounted) return;
    _applyOutcome(r, noPartnerConfirm: true);
  }

  Widget _messageBody(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: _accent),
              const SizedBox(height: 16),
              Text(text, textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget _formBody() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        24,
        20,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Confirm it\'s your account',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: _accent),
          ),
          const SizedBox(height: 8),
          Text(
            _required == 1
                ? "Enter the phone number of one person you've had a private chat with using this account."
                : "Enter the phone number of at least one person you've had a private chat with using this account. Filling both makes verification more reliable.",
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
          ),
          const SizedBox(height: 20),
          for (var i = 0; i < _controllers.length; i++) ...[
            TextField(
              controller: _controllers[i],
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: (_controllers.length > 1 && i == 1)
                    ? 'Chat partner 2 (optional)'
                    : 'Chat partner ${i + 1}',
                labelStyle: const TextStyle(color: Color(0xFF6B7280)),
                floatingLabelStyle: const TextStyle(color: _accent),
                enabledBorder: _border(const Color(0xFFD1D5DB)),
                focusedBorder: _border(_accent, 1.6),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!,
                style: const TextStyle(
                    color: Color(0xFFC62828), fontWeight: FontWeight.w500)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Verify & transfer',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
        ],
      ),
    );
  }
}
