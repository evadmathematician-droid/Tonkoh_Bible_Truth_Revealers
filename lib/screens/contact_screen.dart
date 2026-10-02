import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/auth/auth_manager.dart';
import '../calls/start_call.dart';
import '../data/app_contact.dart';
import '../data/contacts_cache.dart';
import '../data/contacts_repository.dart';
import '../data/user_profile.dart';
import '../screens/components/contact_action_sheet.dart';
import '../screens/components/contact_row.dart';
import '../screens/components/full_screen_profile_photo.dart';
import '../screens/components/profile_avatar.dart';
import '../services/share_service.dart';

class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen>
    with WidgetsBindingObserver {
  bool _hasPermission = false;
  bool _isLoading = false; // full-screen spinner (first load only)
  bool _syncing = false; // thin top bar during a manual Refresh over data

  // flutter_contacts only has android/ios plugin implementations (checked
  // in its pubspec — no Windows platform channel handler exists), and there
  // is no browser concept of "device contacts" at all on web. Both platforms
  // get the same "not supported here" treatment as a result.
  bool get _contactsUnsupportedHere => kIsWeb || Platform.isWindows;

  String? _currentUid;
  UserProfile? _currentProfile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissionAndLoad();
    _loadCurrentUser();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-sync whenever the app comes back to the foreground — covers the
  /// "added a contact in the phone's Contacts app, switched back" case
  /// without a persistent background service.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasPermission && mounted) {
      _syncContactsQuietly();
    }
  }

  Future<void> _loadCurrentUser() async {
    await AuthManager.ensureSignedIn(
      onReady: () async {
        final cached = await AuthManager.getCachedProfile();
        if (cached == null) return;
        setState(() {
          _currentProfile = cached;
          _currentUid = cached.uid;
        });
      },
      onError: (_) {},
    );
  }

  Future<void> _checkPermissionAndLoad() async {
    // permission_handler has no web implementation for Permission.contacts
    // (there's no browser API for reading a device's contact list at all),
    // and flutter_contacts has no Windows implementation either — calling
    // .status/.request()/getContacts() on either platform throws. Skip
    // entirely on both.
    if (_contactsUnsupportedHere) {
      setState(() => _hasPermission = false);
      return;
    }

    final status = await Permission.contacts.status;
    setState(() => _hasPermission = status.isGranted);
    if (status.isGranted) {
      if (!ContactsCache.instance.hasLoadedOnce) {
        await _refreshContacts();
      } else {
        _syncContactsQuietly();
      }
    }
  }

  Future<void> _requestPermission() async {
    if (_contactsUnsupportedHere) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Contacts aren't available on this platform — open the app on your phone to see matched contacts."),
        ),
      );
      return;
    }

    final status = await Permission.contacts.request();
    debugPrint('[ContactsDebug] Permission.contacts.request() -> $status '
        '(granted=${status.isGranted}, denied=${status.isDenied}, '
        'permanentlyDenied=${status.isPermanentlyDenied}, restricted=${status.isRestricted})');
    setState(() => _hasPermission = status.isGranted);
    if (status.isGranted) {
      await _refreshContacts();
      return;
    }
    // Once the user has permanently denied (or Android auto-denies without a
    // dialog), request() stops showing the system prompt — the only way back
    // is the App Info screen. Send them there.
    if (status.isPermanentlyDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Contacts permission is blocked. Enable it in Settings → Apps → '
            'TBTR → Permissions, then return and tap Refresh.',
          ),
          action: SnackBarAction(
              label: 'Open settings', onPressed: openAppSettings),
        ),
      );
    }
  }

  /// Visible, user-initiated reload (first-ever load, the Refresh menu item,
  /// or right after a permission grant) — shows the spinner.
  Future<void> _refreshContacts() async {
    if (!_hasPermission) return;
    // Only blank the list for a spinner if we have nothing to show yet; a
    // manual Refresh over existing data keeps the list and shows a thin bar.
    final haveData = ContactsCache.instance.hasLoadedOnce;
    setState(() => haveData ? _syncing = true : _isLoading = true);
    final book = await ContactsRepository.fetchContactBook();
    ContactsCache.instance.setBook(book);
    debugPrint('[ContactsDebug] rendering ${book.onApp.length} on-app + '
        '${book.notOnApp.length} invite rows');
    if (mounted) {
      setState(() {
        _isLoading = false;
        _syncing = false;
      });
    }
  }

  /// Silent background sync — no spinner, updates the cache (and the list
  /// reactively via ListenableBuilder). Debounced so re-entering the screen
  /// or the app resuming doesn't re-scan every time.
  Future<void> _syncContactsQuietly({bool force = false}) async {
    if (!_hasPermission) return;
    if (!force &&
        ContactsCache.instance.syncedWithin(const Duration(minutes: 2))) {
      return;
    }
    final book = await ContactsRepository.fetchContactBook();
    ContactsCache.instance.setBook(book);
  }

  Future<void> _invite(AppContact contact) async {
    await ShareService.instance.inviteToApp(name: contact.name);
  }

  void _showAddContactUnsupported() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Add a contact using your phone\'s Contacts app, then come back and tap Refresh.'),
      ),
    );
  }

  Future<void> _sendSms(String phone) async {
    final uri = Uri(scheme: 'sms', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Places a voice/video call through the private-chat calling system —
  /// the exact same path as the call buttons inside PrivateChatScreen.
  /// [callType] is 'audio' or 'video'.
  Future<void> _startAppCall(AppContact contact, String callType) async {
    final uid = contact.uid;
    if (uid == null || uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "This contact isn't on the app yet — you can only call app users."),
        ),
      );
      return;
    }
    final profile = _currentProfile;
    if (profile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Finishing sign-in — try again in a moment.')),
      );
      return;
    }
    await startPrivateAppCall(
      context: context,
      caller: profile,
      calleeUid: uid,
      calleeName: contact.name,
      callType: callType,
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
      onVoiceCall: (c) => _startAppCall(c, 'audio'),
      onVideoCall: (c) => _startAppCall(c, 'video'),
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
            onPressed: () {
              ContactsCache.instance.clear();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showDiscussionPicker() {
    final eligible =
        ContactsCache.instance.contacts.where((c) => c.uid != null).toList();
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
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
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
                    const SizedBox(height: 14),
                    const Text('WELCOME TO',
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.0,
                            color: Colors.grey,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    // Always one line — scales down on narrow screens.
                    const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'TONKOH BIBLE TRUTH REVEALERS',
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 22,
                            height: 1.05,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF102A72)),
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'We Preach Christ and Him Crucified',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.0,
                          color: Color(0xFFB71C1C),
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Contacts',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF102A72))),
                      ),
                    ),
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
                      _refreshContacts();
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
                  PopupMenuItem(
                      value: 'delete', child: Text('Delete contacts')),
                  PopupMenuItem(
                      value: 'discussion',
                      child: Text('Create a two person discussion')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// TEMPORARY DEBUG BAR — shows ContactsRepository's last-run counters
  /// directly on screen so a screenshot is enough to diagnose matching.
  Widget _buildDebugBar() {
    final err = ContactsRepository.lastError;
    return Container(
      width: double.infinity,
      color: Colors.yellow.shade100,
      padding: const EdgeInsets.all(8),
      child: Text(
        'DEBUG regions=${ContactsRepository.lastRegions}\n'
        'deviceContacts=${ContactsRepository.lastRawDeviceRows} '
        '(sim=${ContactsRepository.lastSimRows}) '
        'numbers=${ContactsRepository.lastDeviceNumbers} '
        'keyed=${ContactsRepository.lastKeyedNumbers} '
        'firebaseUsers=${ContactsRepository.lastFirebaseCount}\n'
        'onApp=${ContactsRepository.lastExactMatches + ContactsRepository.lastLooseMatches} '
        '(exact=${ContactsRepository.lastExactMatches}, loose=${ContactsRepository.lastLooseMatches})  '
        'notOnApp=${ContactsRepository.lastNotOnApp}'
        '${err.isEmpty ? '' : '\nERROR: $err'}',
        style: const TextStyle(fontSize: 11, color: Colors.black87),
      ),
    );
  }

  Widget _buildBody() {
    // Once contacts have loaded at least once this session, always render the
    // cached list — never flash the "Grant access" card (which happens for a
    // few frames on every mount while the async permission check runs) or a
    // spinner on re-entry.
    final haveData = ContactsCache.instance.hasLoadedOnce;

    if (!_hasPermission && !haveData) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                _contactsUnsupportedHere
                    ? "Matching your phone contacts isn't available on this platform. Open the app on your phone to see who's on the app, or use the discussion menu above to message someone directly."
                    : 'Contact permission is needed to show your contacts and which of them are on the app.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
              if (!_contactsUnsupportedHere) ...[
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _requestPermission,
                  child: const Text('Grant Access'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_isLoading && !haveData) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListenableBuilder(
      listenable: ContactsCache.instance,
      builder: (context, _) {
        final book = ContactsCache.instance.book;
        final list = _buildContactList(book);
        if (!_syncing) return list;
        return Column(
          children: [
            const LinearProgressIndicator(minHeight: 2),
            Expanded(child: list),
          ],
        );
      },
    );
  }

  Widget _buildContactList(ContactBook book) {
    // Flat item model so the whole list is lazily built by ListView.builder
    // even with hundreds of contacts.
    final items = <Object>[_ContactItem.debug];
    if (book.total == 0) {
      items.add(_ContactItem.empty);
    } else {
      if (book.onApp.isNotEmpty) {
        items.add(const _SectionHeader('Contacts on Tonkoh'));
        items.addAll(book.onApp);
      }
      if (book.notOnApp.isNotEmpty) {
        items.add(const _SectionHeader('Invite to Tonkoh'));
        items.addAll(book.notOnApp);
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];

        if (item == _ContactItem.debug) return _buildDebugBar();
        if (item == _ContactItem.empty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text(
              'No contacts found on this device.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          );
        }
        if (item is _SectionHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text(
              item.title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFF102A72),
              ),
            ),
          );
        }

        final contact = item as AppContact;
        if (contact.uid != null) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContactRow(
              contact: contact,
              onTap: () => _openActionSheet(contact),
              onAvatarTap: () => _showPhoto(contact),
            ),
          );
        }
        return _InviteTile(contact: contact, onInvite: () => _invite(contact));
      },
    );
  }
}

/// Sentinels for the flat contacts list model.
enum _ContactItem { debug, empty }

class _SectionHeader {
  final String title;
  const _SectionHeader(this.title);
}

/// A lightweight row for a device contact who isn't on the app yet.
class _InviteTile extends StatelessWidget {
  final AppContact contact;
  final VoidCallback onInvite;

  const _InviteTile({required this.contact, required this.onInvite});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: ProfileAvatar(name: contact.name, photoUrl: null, size: 42),
      title: Text(contact.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(contact.phone,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      trailing: OutlinedButton(
        onPressed: onInvite,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF102A72),
          side: const BorderSide(color: Color(0xFF102A72)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          visualDensity: VisualDensity.compact,
        ),
        child: const Text('Invite'),
      ),
    );
  }
}
