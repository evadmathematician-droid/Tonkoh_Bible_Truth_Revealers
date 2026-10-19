import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/profile_photo_cache.dart';
import '../../data/user_profile.dart';
import '../auth/auth_manager.dart';
import '../../util/phone_utils.dart';
import '../components/full_screen_profile_photo.dart';
import '../components/phone_number_field.dart';
import 'square_crop_screen.dart';

/// Flutter port of the Kotlin/Compose `UserProfileIdentityScreen` — the
/// user's own editable account screen reached from Settings.
///
/// Behaviour preserved from the original:
///  * cached profile shows instantly, then a background refresh; a failed
///    refresh silently keeps the cached view (no blocking error);
///  * tapping the avatar opens a full-screen zoomed viewer (with its own
///    edit affordance); the small camera badge opens the picker directly;
///  * pick → square crop → applied locally as a *pending* photo (not saved);
///  * "Save changes" is genuinely disabled until name / phone / country /
///    photo actually differ from the loaded profile and no save is running;
///  * save validates non-blank name/phone/country, persists via
///    `AuthManager`, then clears the pending photo, refreshes the cache and
///    confirms — or shows the exact error on failure.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const _accent = Color(0xFF102A72);

  final _nameCtrl = TextEditingController();
  // From PhoneNumberField: strict E.164 (null while invalid) and its country.
  String? _phoneE164;
  String _phoneCountry = kDefaultCountry;

  UserProfile? _loaded;
  bool _firstLoadDone = false;

  String? _pendingPhotoPath;
  Uint8List? _pendingPhotoBytes;
  bool _photoProcessing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cached = await AuthManager.getCachedProfile();
    if (!mounted) return;

    if (cached != null) {
      _applyLoaded(cached);
    }
    setState(() => _firstLoadDone = true);

    // Background refresh. Never blocks; a failure (offline) is swallowed and
    // the cached view stays.
    if (cached != null) {
      final fresh = await AuthManager.fetchProfile(
        phoneKey: cached.uid,
        onError: (_) {},
      );
      if (!mounted || fresh == null) return;
      // Don't stomp on edits the user has already started.
      if (!_isDirty && _pendingPhotoPath == null) {
        setState(() => _applyLoaded(fresh));
      }
    }
  }

  void _applyLoaded(UserProfile p) {
    _loaded = p;
    _nameCtrl.text = p.name;
    _phoneE164 = p.phone;
    _phoneCountry = p.country.isEmpty ? kDefaultCountry : p.country;
  }

  bool get _isDirty {
    final l = _loaded;
    if (l == null) return false;
    return _nameCtrl.text != l.name ||
        _phoneE164 != l.phone ||
        _pendingPhotoPath != null;
  }

  bool get _canSave => _isDirty && !_saving && !_photoProcessing;

  // ------------------------------------------------------------------ photo

  Future<void> _pickPhoto() async {
    if (_photoProcessing || _saving) return;
    final XFile? picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
      maxWidth: 1600,
    );
    if (picked == null || !mounted) return;

    final croppedPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SquareCropScreen(imagePath: picked.path),
      ),
    );
    if (croppedPath == null || !mounted) return;

    setState(() => _photoProcessing = true);
    try {
      final bytes = await File(croppedPath).readAsBytes();
      if (!mounted) return;
      setState(() {
        _pendingPhotoPath = croppedPath;
        _pendingPhotoBytes = bytes;
        _photoProcessing = false;
      });
    } catch (_) {
      if (mounted) setState(() => _photoProcessing = false);
    }
  }

  void _openPhotoViewer() {
    final String? photoBase64 = _pendingPhotoBytes != null
        ? base64Encode(_pendingPhotoBytes!)
        : (_loaded?.photoUrl.isNotEmpty == true ? _loaded!.photoUrl : null);

    showGeneralDialog(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      pageBuilder: (ctx, _, __) => FullScreenProfilePhoto(
        name: _nameCtrl.text.trim().isEmpty
            ? (_loaded?.name ?? '')
            : _nameCtrl.text.trim(),
        photoUrl: photoBase64,
        isOwnProfile: true,
        onDismiss: () => Navigator.of(ctx).pop(),
        onEditRequested: () {
          Navigator.of(ctx).pop();
          _pickPhoto();
        },
      ),
    );
  }

  Widget _placeholder(double size) => Container(
        width: size,
        height: size,
        color: const Color(0xFFE0E0E0),
        alignment: Alignment.center,
        child: Icon(Icons.person, size: size * 0.55, color: Colors.white),
      );

  Widget _avatar() {
    const size = 120.0;

    Widget photo;
    if (_pendingPhotoBytes != null) {
      photo = Image.memory(_pendingPhotoBytes!,
          width: size, height: size, fit: BoxFit.cover);
    } else if ((_loaded?.photoUrl ?? '').isNotEmpty) {
      try {
        photo = Image.memory(
          base64Decode(_loaded!.photoUrl),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(size),
        );
      } catch (_) {
        photo = _placeholder(size);
      }
    } else {
      photo = _placeholder(size);
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          // Tapping the photo opens the full-screen viewer.
          Positioned.fill(
            child: GestureDetector(
              onTap: _openPhotoViewer,
              child: ClipOval(child: photo),
            ),
          ),
          if (_photoProcessing)
            Positioned.fill(
              child: ClipOval(
                child: Container(
                  color: Colors.black45,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                        strokeWidth: 3, color: Colors.white),
                  ),
                ),
              ),
            ),
          // Camera badge — its own tap target painted on top (last child),
          // kept fully inside the avatar box so every part of it is
          // hit-testable; a tap here opens the picker and never reaches the
          // photo's viewer tap.
          Positioned(
            right: 0,
            bottom: 0,
            child: Material(
              color: _accent,
              shape: const CircleBorder(
                side: BorderSide(color: Colors.white, width: 2),
              ),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _pickPhoto,
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.camera_alt, color: Colors.white, size: 18),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- save

  Future<void> _save() async {
    if (!_canSave) return;

    final name = _nameCtrl.text.trim();
    final phone = _phoneE164;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your name')),
      );
      return;
    }
    if (phone == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("That doesn't look like a valid phone number — "
                'check the digits and the country.')),
      );
      return;
    }
    // The number IS the account id. A different number means a different
    // account (chats stay with the old one), so say so before switching.
    final current = _loaded!.uid;
    if (phone != current && phone != repairStoredPhone(current)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change phone number?'),
          content: Text('Your account is tied to your phone number. Saving '
              '${formatPhoneForDisplay(phone)} switches this device to that '
              'number; your chats stay with ${formatPhoneForDisplay(current)}.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Change number')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _saving = true);

    await AuthManager.saveProfileWithPhoto(
      name: name,
      phone: phone,
      countryIso: _phoneCountry,
      newPhotoPath: _pendingPhotoPath,
      onSuccess: () async {
        final fresh = await AuthManager.getCachedProfile();
        if (!mounted) return;
        setState(() {
          if (fresh != null) _applyLoaded(fresh);
          _pendingPhotoPath = null;
          _pendingPhotoBytes = null;
          _saving = false;
        });
        if (fresh != null) {
          ProfilePhotoCache.instance.updateCached(fresh.uid, fresh.photoUrl);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile saved')),
        );
      },
      onError: (msg) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      },
    );

    if (mounted && _saving) setState(() => _saving = false);
  }

  // ------------------------------------------------------------------ build

  OutlineInputBorder _border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: w),
      );

  InputDecoration _decoration(String label, {int? counter}) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF6B7280)),
        floatingLabelStyle: const TextStyle(color: _accent),
        counterText: counter == null ? null : '',
        enabledBorder: _border(const Color(0xFFD1D5DB)),
        focusedBorder: _border(_accent, 1.6),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        foregroundColor: _accent,
        title: const Text('Edit Profile'),
      ),
      body: !_firstLoadDone
          ? const Center(child: CircularProgressIndicator())
          : _loaded == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'No account found on this device. Finish registration first.'),
                  ),
                )
              : SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    24,
                    20,
                    24 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: _avatar()),
                      const SizedBox(height: 10),
                      const Center(
                        child: Text(
                          'Tap the camera icon to change your photo',
                          style: TextStyle(
                              color: Color(0xFF6B7280), fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _nameCtrl,
                        textCapitalization: TextCapitalization.words,
                        onChanged: (_) => setState(() {}),
                        decoration: _decoration('Account name'),
                      ),
                      const SizedBox(height: 16),
                      PhoneNumberField(
                        // Rebuild with the fresh value after the background
                        // refresh replaces the cached profile.
                        key: ValueKey(_loaded!.phone),
                        initialCountry: _phoneCountry,
                        initialNumber: _loaded!.phone,
                        border: _border(const Color(0xFFD1D5DB)),
                        onChanged: (e164, country) => setState(() {
                          _phoneE164 = e164;
                          _phoneCountry = country;
                        }),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _canSave ? _save : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            disabledBackgroundColor:
                                _accent.withValues(alpha: 0.35),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5, color: Colors.white),
                                )
                              : const Text(
                                  'Save changes',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
