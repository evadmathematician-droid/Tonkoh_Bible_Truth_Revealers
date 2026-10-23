import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/profile_photo_cache.dart';
import '../../data/profile_settings_repository.dart';
import '../../data/user_profile.dart';
import '../../util/base64_image_cache.dart';
import '../../util/phone_utils.dart';
import '../../permissions/permission_flow.dart';
import '../auth/auth_manager.dart';
import '../auth/presence_manager.dart';
import 'square_crop_screen.dart';

/// Settings (☰ → Settings): profile photo, account name, and the account's
/// phone number and country (read-only — the number is the account).
///
/// Opens instantly from the cached profile, then refreshes from the
/// database. Save is enabled only when the photo or name changed; it writes
/// just those fields (ProfileSettingsRepository), updates the cached
/// profile at once (drawer header, feed, chats), and queues the change when
/// offline.
class SettingsScreen extends StatefulWidget {
  /// Injected in tests.
  final ProfileSettingsRepository? repository;
  final UserProfile? initialProfile;

  const SettingsScreen({super.key, this.repository, this.initialProfile});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _accent = Color(0xFF102A72);

  late final ProfileSettingsRepository _repo =
      widget.repository ?? ProfileSettingsRepository.instance;
  final _nameCtrl = TextEditingController();

  UserProfile? _profile;

  // Pending photo edit: new JPEG bytes, or "remove".
  Uint8List? _newPhoto;
  bool _removePhoto = false;
  bool _processingPhoto = false;
  bool _saving = false;
  bool _stayOnline = true;

  @override
  void initState() {
    super.initState();
    final p = widget.initialProfile ?? AuthManager.lastKnownProfile;
    if (p != null) _apply(p);
    if (widget.initialProfile == null) _load();
    PresenceManager.stayOnlineInBackground().then((v) {
      if (mounted && v != _stayOnline) setState(() => _stayOnline = v);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _apply(UserProfile p) {
    _profile = p;
    _nameCtrl.text = p.name;
  }

  Future<void> _load() async {
    final cached = await AuthManager.getCachedProfile();
    if (!mounted || cached == null) return;
    if (_profile == null) setState(() => _apply(cached));
    // Background refresh — unless an offline edit is still waiting (the
    // server copy would be older than what this phone shows).
    if (await _repo.pending() != null) return;
    final fresh =
        await AuthManager.fetchProfile(phoneKey: cached.uid, onError: (_) {});
    if (!mounted || fresh == null || _dirty) return;
    setState(() => _apply(fresh));
  }

  // ── state ────────────────────────────────────────────────────────────

  String get _cleanName => ProfileSettingsRepository.cleanName(_nameCtrl.text);
  bool get _nameChanged => _profile != null && _cleanName != _profile!.name;
  bool get _photoChanged => _newPhoto != null || _removePhoto;
  bool get _dirty => _nameChanged || _photoChanged;
  String? get _nameError => ProfileSettingsRepository.validateName(_nameCtrl.text);
  bool get _canSave =>
      _dirty && _nameError == null && !_saving && !_processingPhoto;

  bool get _hasPhoto =>
      _newPhoto != null ||
      (!_removePhoto && (_profile?.photoUrl.isNotEmpty ?? false));

  // ── photo ────────────────────────────────────────────────────────────

  Future<void> _openPhotoSheet() async {
    if (_saving || _processingPhoto) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (_hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Remove photo',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'remove') {
      setState(() {
        _newPhoto = null;
        _removePhoto = true;
      });
      return;
    }
    await _pick(choice == 'camera' ? ImageSource.camera : ImageSource.gallery);
  }

  Future<void> _pick(ImageSource source) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 90,
        preferredCameraDevice: CameraDevice.front,
      );
    } on PlatformException catch (e) {
      // camera_access_denied / photo_access_denied / no_available_camera
      if (mounted) _permissionHelp(source, e.code);
      return;
    }
    if (picked == null || !mounted) return;

    final croppedPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => SquareCropScreen(imagePath: picked!.path)),
    );
    if (croppedPath == null || !mounted) return;

    setState(() => _processingPhoto = true);
    try {
      final bytes = await File(croppedPath).readAsBytes();
      final jpeg = await compute(compressProfilePhoto, bytes);
      if (!mounted) return;
      setState(() {
        _newPhoto = jpeg;
        _removePhoto = false;
      });
    } catch (e) {
      _snack("Couldn't use that photo — try another one.");
    } finally {
      if (mounted) setState(() => _processingPhoto = false);
    }
  }

  void _permissionHelp(ImageSource source, String code) {
    final what = source == ImageSource.camera ? 'camera' : 'photos';
    if (code == 'no_available_camera') {
      _snack('No camera available on this device.');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Allow access to your $what'),
        content: Text(
            'T.B.T.R needs access to your $what to set your profile picture. '
            'You can allow it in the app settings.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  // ── save ─────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final p = _profile;
    if (p == null || !_canSave) return;
    final name = _nameChanged ? _cleanName : null;
    final photo = _removePhoto
        ? ''
        : (_newPhoto != null ? base64Encode(_newPhoto!) : null);

    setState(() => _saving = true);
    // Show it everywhere at once (drawer header, feed, chats) — also when
    // the database write has to wait for the connection.
    await AuthManager.updateCachedProfile(name: name, photoUrl: photo);
    if (photo != null) ProfilePhotoCache.instance.updateCached(p.uid, photo);

    try {
      final result = await _repo.save(uid: p.uid, name: name, photoUrl: photo);
      if (!mounted) return;
      setState(() {
        _apply(AuthManager.lastKnownProfile ?? p);
        _newPhoto = null;
        _removePhoto = false;
      });
      _snack(result == ProfileSaveResult.saved
          ? 'Profile saved ✓'
          : 'Will save when you are online');
    } catch (e) {
      // Kept queued (retried automatically) and the edits stay on screen.
      _snack("Couldn't save: ${_reason(e)}. It will retry automatically.");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _reason(Object e) {
    final s = e.toString();
    if (s.contains('permission-denied') || s.contains('Permission denied')) {
      return 'the database refused the change';
    }
    if (s.contains('Timeout')) return 'the connection timed out';
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your new name or photo has not been saved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ── build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          setState(() {
            _newPhoto = null;
            _removePhoto = false;
            if (_profile != null) _nameCtrl.text = _profile!.name;
          });
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(foregroundColor: _accent, title: const Text('Settings')),
        body: p == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'No account found on this device. Finish registration first.'),
                ),
              )
            : SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                        children: [
                          Center(child: _avatar(p)),
                          const SizedBox(height: 8),
                          const Center(
                            child: Text('Tap the photo to change it',
                                style: TextStyle(
                                    color: Color(0xFF6B7280), fontSize: 12)),
                          ),
                          const SizedBox(height: 28),
                          TextField(
                            key: const Key('settingsName'),
                            controller: _nameCtrl,
                            enabled: !_saving,
                            textCapitalization: TextCapitalization.words,
                            maxLength: ProfileSettingsRepository.nameMax + 10,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'Account name',
                              helperText: 'This is the name others see',
                              counterText: '',
                              errorText: _nameCtrl.text.isEmpty &&
                                      !_nameChanged
                                  ? null
                                  : _nameError,
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _phoneTile(p),
                          const SizedBox(height: 12),
                          _countryTile(p),
                          const SizedBox(height: 20),
                          SwitchListTile(
                            key: const Key('settingsStayOnline'),
                            contentPadding: EdgeInsets.zero,
                            activeThumbColor: _accent,
                            title: const Text('Stay online in background'),
                            subtitle: const Text(
                                'Others see you as Online while TBTR is open '
                                'in the background and you have internet.'),
                            value: _stayOnline,
                            onChanged: (v) {
                              setState(() => _stayOnline = v);
                              PresenceManager.setStayOnlineInBackground(v);
                            },
                          ),
                          if (PermissionFlow.supported)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.verified_user_outlined,
                                  color: _accent),
                              title: const Text('App permissions'),
                              onTap: () => PermissionFlow.requestAll(context),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          key: const Key('settingsSave'),
                          onPressed: _canSave ? _save : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            disabledBackgroundColor:
                                _accent.withValues(alpha: 0.30),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5, color: Colors.white))
                              : const Text('Save',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.white)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _avatar(UserProfile p) {
    const size = 128.0;
    ImageProvider? image;
    if (_newPhoto != null) {
      image = MemoryImage(_newPhoto!);
    } else if (!_removePhoto) {
      final bytes = Base64ImageCache.decode(p.photoUrl);
      if (bytes != null) image = MemoryImage(bytes);
    }
    final busy = _processingPhoto || (_saving && _photoChanged);
    return Semantics(
      button: true,
      label: 'Change profile photo',
      child: GestureDetector(
        key: const Key('settingsAvatar'),
        onTap: _openPhotoSheet,
        child: SizedBox(
          width: size + 8,
          height: size + 8,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircleAvatar(
                radius: size / 2,
                backgroundColor: _accent.withValues(alpha: 0.10),
                backgroundImage: image,
                child: image == null
                    ? const Icon(Icons.person, size: 72, color: _accent)
                    : null,
              ),
              if (busy)
                const SizedBox(
                  width: size + 6,
                  height: size + 6,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.photo_camera,
                      size: 18, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phoneTile(UserProfile p) {
    final shown = formatPhoneForDisplay(p.phone.isEmpty ? p.uid : p.phone);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Phone number',
        helperText: 'This is your T.B.T.R number',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        suffixIcon: IconButton(
          key: const Key('settingsCopyPhone'),
          tooltip: 'Copy number',
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: shown));
            _snack('Number copied');
          },
        ),
      ),
      child: Text(shown,
          key: const Key('settingsPhone'),
          style: const TextStyle(fontSize: 16)),
    );
  }

  Widget _countryTile(UserProfile p) {
    final iso = countryOfPhone(repairStoredPhone(p.phone) ?? p.phone) ??
        (p.country.isEmpty ? null : p.country.toUpperCase());
    final match = iso == null ? null : countries.where((c) => c.code == iso);
    final c = (match == null || match.isEmpty) ? null : match.first;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Country',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        c == null ? (iso ?? 'Unknown') : '${c.flag}  ${c.name} (${c.code}) +${c.dialCode}',
        key: const Key('settingsCountry'),
        style: const TextStyle(fontSize: 16),
      ),
    );
  }
}

/// Re-encodes a cropped photo as a JPEG of at most 800×800 so it is small
/// enough to save and load quickly on slow networks. Top-level for compute().
Uint8List compressProfilePhoto(Uint8List input) {
  final decoded = img.decodeImage(input);
  if (decoded == null) throw const FormatException('Unreadable image');
  final resized = decoded.width > 800 || decoded.height > 800
      ? img.copyResize(decoded,
          width: decoded.width >= decoded.height ? 800 : null,
          height: decoded.height > decoded.width ? 800 : null,
          interpolation: img.Interpolation.average)
      : decoded;
  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}

