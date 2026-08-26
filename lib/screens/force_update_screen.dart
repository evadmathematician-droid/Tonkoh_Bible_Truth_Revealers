import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/play_update_service.dart';

const _kBrand = Color(0xFF102A72);

/// Blocks all access to the app. No "Later"/"Skip"/close affordance
/// anywhere on purpose — PopScope(canPop: false) also swallows the Android
/// back button so the only way off this screen is updating.
class ForceUpdateScreen extends StatefulWidget {
  final String updateUrl;

  /// When true, "Update Now" tries Google Play's own in-app immediate-update
  /// flow (the same Play Core mechanism the previous native MainActivity
  /// used) before falling back to opening the store listing.
  final bool usePlayImmediateFlow;

  const ForceUpdateScreen({
    super.key,
    required this.updateUrl,
    this.usePlayImmediateFlow = false,
  });

  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen> {
  bool _launching = false;

  Future<void> _openStore() async {
    setState(() => _launching = true);
    try {
      if (widget.usePlayImmediateFlow) {
        // On success, Play installs the update and restarts the app itself
        // — this normally never returns. It only returns here if the user
        // backed out or the flow failed, so fall through to the store
        // listing below.
        final completed = await PlayUpdateService.performImmediateUpdate();
        if (completed) return;
      }
      final uri = Uri.parse(widget.updateUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.system_update, size: 72, color: _kBrand),
                  const SizedBox(height: 24),
                  const Text(
                    'Update Required',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _kBrand),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A new version of Tonkoh Bible Truth Revealers is required to continue. '
                    'Please update the app to keep using it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.black87),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _kBrand,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _launching ? null : _openStore,
                      child: _launching
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Update Now'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
