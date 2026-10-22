import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Whether the phone truly has no internet — what the offline banner shows.
///
/// Firebase's `.info/connected` alone is the wrong signal: it is false for
/// the first second of every launch and resume even on perfect internet,
/// which used to flash "Offline" / "Updating…" each time. Here the phone
/// counts as offline only when:
///  - Android reports no network at all (after a short debounce), or
///  - it has a network (Wi-Fi without internet, expired data bundle) but a
///    real request to a tiny Google endpoint fails.
///
/// Starts "online", so nothing is shown while the first check runs; cached
/// chats and the feed render the same either way.
class ConnectionStatus with WidgetsBindingObserver {
  ConnectionStatus._();
  static final ConnectionStatus instance = ConnectionStatus._();

  /// True only while the phone has no working internet.
  final ValueNotifier<bool> offline = ValueNotifier(false);

  static final Uri _probeUri =
      Uri.parse('https://clients3.google.com/generate_204');

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<DatabaseEvent>? _dbSub;
  Timer? _debounce;
  Timer? _retry;
  Timer? _dbGrace;
  bool _hasNetwork = true;
  bool _started = false;
  bool _probing = false;

  void start() {
    if (_started || kIsWeb) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_onConnectivity);
    unawaited(Connectivity()
        .checkConnectivity()
        .then(_onConnectivity)
        .catchError((Object _) {}));

    // Firebase disconnected for a while although Android says there is a
    // network: find out whether the internet actually works.
    _dbSub = FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen((e) {
      _dbGrace?.cancel();
      if (e.snapshot.value == true) {
        _set(false);
      } else if (_hasNetwork) {
        _dbGrace = Timer(const Duration(seconds: 10), _probe);
      }
    });
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    _hasNetwork = results.any((r) => r != ConnectivityResult.none);
    _debounce?.cancel();
    if (!_hasNetwork) {
      // Switching networks briefly reports "none"; don't flash the banner.
      _debounce = Timer(const Duration(seconds: 2), () {
        if (!_hasNetwork) _set(true);
      });
    } else {
      _probe();
    }
  }

  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    try {
      if (!_hasNetwork) return _set(true);
      bool ok;
      try {
        final res =
            await http.get(_probeUri).timeout(const Duration(seconds: 6));
        ok = res.statusCode < 500;
      } catch (_) {
        ok = false;
      }
      _set(!ok);
    } finally {
      _probing = false;
    }
  }

  void _set(bool isOffline) {
    offline.value = isOffline;
    _retry?.cancel();
    // While offline, look again now and then so the banner goes away even
    // if Android doesn't report a network change.
    if (isOffline) _retry = Timer(const Duration(seconds: 15), _probe);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && offline.value) _probe();
  }

  @visibleForTesting
  Future<void> stop() async {
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    await _connectivitySub?.cancel();
    await _dbSub?.cancel();
    _debounce?.cancel();
    _retry?.cancel();
    _dbGrace?.cancel();
  }
}
