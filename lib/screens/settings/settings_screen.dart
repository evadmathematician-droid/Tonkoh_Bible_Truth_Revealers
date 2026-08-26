import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/linked_device.dart';
import '../../data/local_contact_store.dart';
import '../../data/user_device_repository.dart';
import '../../data/user_profile.dart';
import '../auth/auth_manager.dart';
import '../components/profile_avatar.dart';

/// Full Settings screen — profile edit (name + picture), linked devices,
/// and delete account. Reuses AuthManager (the existing account
/// repository/service layer — see auth_manager.dart) rather than talking
/// to Firebase directly, same convention as ContactScreen/ProfileSetupScreen.
///
/// NOTE: the "existing calling account settings row" this was meant to
/// port in does not exist anywhere in this codebase — searched
/// exhaustively (WidgetsBindingObserver/didChangeAppLifecycleState,
/// RoleManager/ROLE_DIALER/default-dialer, "calling account") and found
/// nothing to port. This screen ships without it; see the chat summary
/// for what to do next.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _deviceRepo = UserDeviceRepository();
  final _nameController = TextEditingController();

  UserProfile? _profile;
  String? _currentDeviceId;
  List<LinkedDevice> _devices = [];
  bool _isLoadingDevices = true;
  bool _isSavingName = false;
  bool _isUploadingPhoto = false;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final profile = await AuthManager.getCachedProfile();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _nameController.text = profile?.name ?? '';
    });
    if (profile != null) {
      _currentDeviceId = await _deviceRepo.currentDeviceId();
      final devices = await _deviceRepo.fetchDevices(profile.uid);
      if (mounted) {
        setState(() {
          _devices = devices;
          _isLoadingDevices = false;
        });
      }
    } else if (mounted) {
      setState(() => _isLoadingDevices = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Edit name ──────────────────────────────────────────────────────

  bool get _nameChanged =>
      _profile != null && _nameController.text.trim() != _profile!.name && _nameController.text.trim().isNotEmpty;

  Future<void> _saveName() async {
    final profile = _profile;
    if (profile == null || !_nameChanged) return;
    setState(() => _isSavingName = true);
    await AuthManager.saveProfile(
      name: _nameController.text.trim(),
      phone: profile.phone,
      countryIso: profile.country,
      onSuccess: () async {
        final updated = await AuthManager.getCachedProfile();
        if (!mounted) return;
        setState(() {
          _profile = updated;
          _isSavingName = false;
        });
        _showSnack('Name updated');
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _isSavingName = false);
        _showSnack('Could not save: $message');
      },
    );
  }

  // ── Profile picture ───────────────────────────────────────────────

  Future<void> _pickAndUploadPhoto() async {
    final profile = _profile;
    if (profile == null) return;

    // On Android 13+ (and 11+ with Play services) this already routes
    // through the modern Photo Picker (ACTION_PICK_IMAGES) automatically
    // — image_picker has done this under the hood since 0.8.9, no extra
    // native wiring needed. maxWidth/imageQuality downsize the picked
    // image client-side so a typical gallery photo lands comfortably
    // under AuthManager's 600KB base64 cap instead of hard-failing.
    final XFile? picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 720,
      imageQuality: 70,
    );
    if (picked == null) return;

    setState(() => _isUploadingPhoto = true);
    await AuthManager.saveProfileWithPhoto(
      name: profile.name,
      phone: profile.phone,
      countryIso: profile.country,
      newPhotoPath: picked.path,
      onSuccess: () async {
        final updated = await AuthManager.getCachedProfile();
        if (!mounted) return;
        setState(() {
          _profile = updated;
          _isUploadingPhoto = false;
        });
        _showSnack('Profile picture updated');
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _isUploadingPhoto = false);
        _showSnack('Could not update photo: $message');
      },
    );
  }

  // ── Linked devices ────────────────────────────────────────────────

  String _platformLabel(String platform) {
    switch (platform) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'web':
        return 'Web';
      default:
        return platform;
    }
  }

  String _formatLastActive(int millis) {
    if (millis == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Active just now';
    if (diff.inHours < 1) return 'Active ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Active ${diff.inHours}h ago';
    return 'Active ${date.month}/${date.day}/${date.year}';
  }

  Future<void> _confirmUnlink(LinkedDevice device) async {
    final isCurrent = device.deviceId == _currentDeviceId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: Text(
          isCurrent
              ? "This is the device you're using right now. Removing it will sign this device out "
                  'the next time the app is opened.'
              : "This device will lose access to your account and won't receive messages or calls "
                  'until it signs in again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || _profile == null) return;

    await _deviceRepo.unlinkDevice(_profile!.uid, device.deviceId);
    if (!mounted) return;
    setState(() => _devices = _devices.where((d) => d.deviceId != device.deviceId).toList());
    _showSnack(isCurrent ? 'Removed. This device will sign out on next launch.' : 'Device removed');
  }

  // ── Delete account ────────────────────────────────────────────────

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This permanently removes your profile and chat history from the app on every device. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || _profile == null) return;

    setState(() => _isDeleting = true);
    final phoneKey = _profile!.uid;
    await AuthManager.deleteAccount(
      phoneKey: phoneKey,
      onSuccess: () async {
        // Local cleanup — the account is gone, don't leave its cached
        // contacts sitting in this device's local DB.
        await LocalContactStore.instance.clearAll();
        // AuthGate is watching users/{phoneKey} and will flip itself back
        // to the profile-setup screen the moment it sees this node gone
        // (see AuthGate._watchProfileDeletion) — no manual navigation
        // needed here, it discards this whole screen automatically.
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _isDeleting = false);
        _showSnack('Could not delete account: $message');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFF102A72),
        foregroundColor: Colors.white,
      ),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildProfileCard(profile),
                const SizedBox(height: 24),
                _buildLinkedDevicesSection(),
                const SizedBox(height: 24),
                _buildDangerZone(),
              ],
            ),
    );
  }

  Widget _buildProfileCard(UserProfile profile) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Stack(
              children: [
                ProfileAvatar(name: profile.name, photoUrl: profile.photoUrl, size: 88),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: _isUploadingPhoto ? null : _pickAndUploadPhoto,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: const Color(0xFF102A72),
                      child: _isUploadingPhoto
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                suffixIcon: _isSavingName
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : (_nameChanged
                        ? IconButton(icon: const Icon(Icons.check), onPressed: _saveName)
                        : null),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(profile.phone, style: const TextStyle(color: Colors.grey, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkedDevicesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8, left: 4),
          child: Text('Linked Devices', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF102A72))),
        ),
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          elevation: 3,
          child: _isLoadingDevices
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _devices.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No linked devices yet.', style: TextStyle(color: Colors.grey)),
                    )
                  : Column(
                      children: _devices.map((device) {
                        final isCurrent = device.deviceId == _currentDeviceId;
                        return ListTile(
                          leading: Icon(
                            device.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android,
                            color: const Color(0xFF102A72),
                          ),
                          title: Text(
                            isCurrent ? '${_platformLabel(device.platform)} (this device)' : _platformLabel(device.platform),
                          ),
                          subtitle: Text(_formatLastActive(device.lastActiveAt)),
                          trailing: IconButton(
                            icon: const Icon(Icons.link_off, color: Colors.red),
                            onPressed: () => _confirmUnlink(device),
                          ),
                        );
                      }).toList(),
                    ),
        ),
      ],
    );
  }

  Widget _buildDangerZone() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 3,
      child: ListTile(
        leading: _isDeleting
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.delete_forever, color: Colors.red),
        title: const Text('Delete account', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
        subtitle: const Text('Permanently deletes your account and signs you out'),
        onTap: _isDeleting ? null : _confirmDeleteAccount,
      ),
    );
  }
}
