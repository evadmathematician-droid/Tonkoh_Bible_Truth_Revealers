import 'package:flutter/material.dart';

import 'force_update_manager.dart';

/// Full-screen block shown while the policy doesn't allow this version.
///
/// It has no close, "Later" or navigation controls and back is disabled.
/// When an update is required the only action is "Update Now"; in
/// maintenance mode the only action is "Try again", which re-checks the
/// policy.
class ForceUpdateScreen extends StatefulWidget {
  const ForceUpdateScreen({
    super.key,
    required this.status,
    required this.logo,
  });

  final ForceUpdateStatus status;
  final Widget logo;

  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen> {
  bool _busy = false;
  String? _error;

  bool get _maintenance =>
      widget.status.decision == ForceUpdateDecision.maintenance;

  /// Remote Config's minimum, or the build Google Play offers when that is
  /// what blocks this install.
  static int _requiredCode(ForceUpdateStatus status) {
    final min = status.policy.minVersionCode;
    final play = status.playVersionCode ?? 0;
    return play > min ? play : min;
  }

  Future<void> _onPressed() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final manager = ForceUpdateManager.instance;
    var ok = true;
    if (_maintenance) {
      await manager.check();
    } else {
      ok = await manager.startUpdate();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = ok
          ? null
          : "Couldn't open the update page. Check your internet connection "
              'and try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.status;
    final policy = status.policy;

    final title = _maintenance ? 'Under maintenance' : 'Update required';
    final message = _maintenance
        ? (policy.maintenanceMessage.isEmpty
            ? ForceUpdateManager.defaultMaintenanceMessage
            : policy.maintenanceMessage)
        : (policy.updateMessage.isEmpty
            ? ForceUpdateManager.defaultUpdateMessage
            : policy.updateMessage);

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 96, height: 96, child: widget.logo),
                    const SizedBox(height: 24),
                    Text(
                      title,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: theme.textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    if (!_maintenance) ...[
                      const SizedBox(height: 24),
                      _VersionRow(
                        label: 'Installed version',
                        value: '${status.installedVersionName} '
                            '(${status.installedVersionCode ?? '?'})',
                      ),
                      const SizedBox(height: 4),
                      _VersionRow(
                        label: 'Required version',
                        value: '${_requiredCode(status)} or newer',
                      ),
                    ],
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _onPressed,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(_maintenance
                                ? Icons.refresh
                                : Icons.system_update),
                        label: Text(_maintenance ? 'Try again' : 'Update Now'),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
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

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$label: ', style: theme.textTheme.bodyMedium),
        Text(
          value,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
