import 'dart:async';
import 'package:web/web.dart' as web;
import 'package:flutter/foundation.dart';

class RingbackManager {
  web.AudioContext? _ctx;
  web.OscillatorNode? _osc1;
  web.OscillatorNode? _osc2;
  web.GainNode? _gain;
  Timer? _cadenceTimer;
  bool _isRinging = false;

  Future<void> start() async {
    if (_isRinging) return;
    _isRinging = true;
    try {
      _ctx = web.AudioContext();
      _gain = _ctx!.createGain();
      _gain!.gain.value = 0;
      _gain!.connect(_ctx!.destination);

      _osc1 = _ctx!.createOscillator();
      _osc1!.type = 'sine';
      _osc1!.frequency.value = 440;
      _osc1!.connect(_gain!);
      _osc1!.start();

      _osc2 = _ctx!.createOscillator();
      _osc2!.type = 'sine';
      _osc2!.frequency.value = 480;
      _osc2!.connect(_gain!);
      _osc2!.start();

      _runCadence();
    } catch (e) {
      debugPrint('RingbackManager: Failed to start synthesized ringback: $e');
      _isRinging = false;
    }
  }

  void _runCadence() {
    _setOn(true);
    _cadenceTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!_isRinging) return;
      _setOn(true);
      Timer(const Duration(seconds: 2), () {
        if (_isRinging) _setOn(false);
      });
    });
    Timer(const Duration(seconds: 2), () {
      if (_isRinging) _setOn(false);
    });
  }

  void _setOn(bool on) {
    if (_gain == null || _ctx == null) return;
    _gain!.gain.setValueAtTime(on ? 0.15 : 0, _ctx!.currentTime);
  }

  void stop() {
    if (!_isRinging) return;
    _isRinging = false;
    _cadenceTimer?.cancel();
    _cadenceTimer = null;
    try {
      _osc1?.stop();
      _osc2?.stop();
    } catch (_) {}
    try {
      _ctx?.close();
    } catch (_) {}
    _osc1 = null;
    _osc2 = null;
    _gain = null;
    _ctx = null;
  }
}