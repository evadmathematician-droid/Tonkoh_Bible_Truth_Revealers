import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/auth/auth_manager.dart';
import '../data/app_contact.dart';
import '../data/contacts_cache.dart';
import '../data/contacts_sync_service.dart';
import '../data/local_contact_store.dart';
import '../screens/components/contact_action_sheet.dart';
import '../screens/components/contact_row.dart';
import '../screens/components/full_screen_profile_photo.dart';
import '../screens/chat/chat_helpers.dart';
import '../calls/call_initiator.dart';
import '../navigation/call_navigator.dart';

class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  // Tri-state, not bool: `status` (denied/granted/permanentlyDenied) drives
  // which banner (if any) renders above the list. The list itself never
  // waits on this — it always renders whatever's already in the local
  // Room-equivalent table (LocalContactStore), so a denied/revoked
  // permission degrades to chat-only contacts instead of an empty screen.
  PermissionStatus _permissionStatus = PermissionStatus.denied;
  bool _isSyncing = false;

  String? _currentUid;
  String _currentUserName = '';
  String _currentUserPhotoUrl = '';

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
    _loadFromLocalDbThenSync();
  }

  Future<void> _loadCurrentUser() async {
    await AuthManager.ensureSignedIn(
      onReady: () async {
        final cached = await AuthManager.getCachedProfile();
        if (cached == null || !mounted) return;
        setState(() {
          _currentUid = cached.uid;
          _currentUserName = cached.name;
          _currentUserPhotoUrl = cached.photoUrl;
        });
      },
      onError: (_) {},
    );
  }

  /// Instant paint from the local DB (no network, no permission prompt),
  /// then a background sync to refresh it — this is the "don't query
  /// ContactsContract/Firebase directly on every render" path.
  Future<void> _loadFromLocalDbThenSync() async {
    final cachedRows = await LocalContactStore.instance.getAll();
    if (mounted) ContactsCache.instance.setContacts(cachedRows);

    if (!kIsWeb) {
      final status = await Permission.contacts.status;
      if (mounted) setState(() => _permissionStatus = status);
    }

    await _syncInBackground();
  }

  Future<void> _syncInBackground() async {
    if (_currentUid == null) {
      final cached = await AuthManager.getCachedProfile();
      if (cached == null) return;
      _currentUid = cached.uid;
    }
    if (!mounted) return;
    setState(() => _isSyncing = true);
    await ContactsSyncService.sync(_currentUid!);
    ContactsCache.instance.hasLoadedOnce = true;
    if (mounted) setState(() => _isSyncing = false);
  }

  Future<void> _onPullToRefresh() => _syncInBackground();

  Future<void> _showPermissionRationale() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Contacts aren't available in the web version — open the app on your phone to see matched contacts.",
          ),
        ),
      );
      return;
    }

    if (_permissionStatus.isPermanentlyDenied) {
      final goToSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Contacts access is off'),
          content: const Text(
            "You previously denied contacts access. To see which of your contacts "
            "are using the app, turn on Contacts permission in your phone's app settings.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open Settings')),
          ],
        ),
      );
      if (goToSettings == true) await openAppSettings();
      return;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Allow contacts access?'),
        content: const Text(
          "We'll check your contacts' phone numbers against people already using the app, "
          "so you can message them without adding anything manually. Your contacts are never "
          'uploaded — only phone numbers are compared, locally, against registered users.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (proceed != true) return;

    final status = await Permission.contacts.request();
    if (!mounted) return;
    setState(() => _permissionStatus = status);
    if (status.isGranted) {
      await _syncInBackground();
    }
  }

  void _showAddContactUnsupported() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Add a contact using your phone\'s Contacts app, then come back and tap Refresh.'),
      ),
    );
  }

  Future<void> _sendSms(String phone) async {
    final uri = Uri(scheme: 'sms', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _dialPhone(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  void _showVideoCallUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Video calling is only available for contacts on the app.')),
    );
  }

  // Mirrors _startCall in private_chat_screen.dart — same CallInitiator /
  // CallNavigator flow, just addressed at a contact's uid instead of a
  // chat's fixed otherUid.
  Future<void> _startCall(AppContact contact, String callType) async {
    final uid = _currentUid;
    final calleeUid = contact.uid;
    if (uid == null || calleeUid == null) return;

    final initiator = CallInitiator();
    await initiator.initiateCall(
      callerUid: uid,
      callerName: _currentUserName,
      callerPhoto: _currentUserPhotoUrl,
      calleeUid: calleeUid,
      chatId: privateChatId(uid, calleeUid),
      callType: callType,
      onCallIdReady: (callId) {
        CallNavigator.toOutgoingCall(
          callId: callId,
          calleeName: contact.name,
          callType: callType,
        );
      },
    );
  }

  void _openActionSheet(AppContact contact) {
    showContactActionSheet(
      context: context,
      contact: contact,
      onMessage: (c) {
        if (c.uid != null) {
          context.push('/privateChat/${c.uid}');
        } else {
          _sendSms(c.phone);
        }
      },
      onVoiceCall: (c) {
        if (c.uid != null) {
          _startCall(c, 'audio');
        } else {
          _dialPhone(c.phone);
        }
      },
      onVideoCall: (c) {
        if (c.uid != null) {
          _startCall(c, 'video');
        } else {
          _showVideoCallUnavailable();
        }
      },
    );
  }

  void _confirmClearContacts() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear contact list?'),
        content: const Text(
          'This clears the list shown here. It won\'t delete anything from your phone\'s contacts. '
          'You can rebuild it anytime with Refresh.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await LocalContactStore.instance.clearAll();
              ContactsCache.instance.setContacts([]);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showDiscussionPicker() {
    final eligible = ContactsCache.instance.contacts.where((c) => c.uid != null).toList();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a discussion with…'),
        content: SizedBox(
          width: double.maxFinite,
          child: eligible.isEmpty
              ? const Text('No matched contacts yet. Try Refresh first.')
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: eligible.length,
                    itemBuilder: (context, index) {
                      final contact = eligible[index];
                      return ListTile(
                        title: Text(contact.name),
                        onTap: () {
                          Navigator.pop(context);
                          context.push('/privateChat/${contact.uid}');
                        },
                      );
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showPhoto(AppContact contact) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      pageBuilder: (context, __, ___) {
        return FullScreenProfilePhoto(
          name: contact.name,
          photoUrl: contact.photoUrl,
          isOwnProfile: contact.uid == _currentUid,
          onDismiss: () => Navigator.pop(context),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF6F9FF), Color(0xFFE7F0FF), Colors.white],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 36),
                    const Text('WELCOME TO', style: TextStyle(fontSize: 15, color: Colors.grey, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 8),
                    const Text(
                      'TONKOH BIBLE\nTRUTH REVEALERS',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF102A72)),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'We Preach Christ and Him Crucified',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Color(0xFFB71C1C), fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('Contacts on the app',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF102A72))),
                      ),
                    ),
                    if (!kIsWeb && !_permissionStatus.isGranted) _buildPermissionBanner(),
                    Expanded(child: _buildBody()),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFF102A72)),
                onSelected: (value) {
                  switch (value) {
                    case 'add':
                      _showAddContactUnsupported();
                      break;
                    case 'refresh':
                      _syncInBackground();
                      break;
                    case 'delete':
                      _confirmClearContacts();
                      break;
                    case 'discussion':
                      _showDiscussionPicker();
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'add', child: Text('Add contact')),
                  PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                  PopupMenuItem(value: 'delete', child: Text('Delete contacts')),
                  PopupMenuItem(value: 'discussion', child: Text('Create a two person discussion')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: const Color(0xFFEFF3FF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.contacts_outlined, color: Color(0xFF102A72)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Allow contacts access to see more people you know on the app.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
              TextButton(onPressed: _showPermissionRationale, child: const Text('Allow')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return RefreshIndicator(
      onRefresh: _onPullToRefresh,
      child: ListenableBuilder(
        listenable: ContactsCache.instance,
        builder: (context, _) {
          final contacts = ContactsCache.instance.contacts;
          if (contacts.isEmpty) {
            if (_isSyncing) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              // ListView (not a bare Text) so pull-to-refresh still works
              // on an empty list — a Center/Text alone has no scrollable
              // surface for RefreshIndicator to attach its gesture to.
              children: const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Text(
                    'None of your contacts are using the app yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ),
              ],
            );
          }
          return ListView.separated(
            itemCount: contacts.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final contact = contacts[index];
              return ContactRow(
                contact: contact,
                onTap: () => _openActionSheet(contact),
                onAvatarTap: contact.uid != null ? () => _showPhoto(contact) : null,
              );
            },
          );
        },
      ),
    );
  }
}
