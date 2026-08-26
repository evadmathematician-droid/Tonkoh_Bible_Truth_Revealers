import 'package:flutter/foundation.dart';
import 'app_contact.dart';

/// Equivalent of ContactsCache — app-wide singleton (like GlobalAudioPlayer,
/// 6c), not screen-scoped, so leaving and returning to the Contacts screen
/// reads instantly from here rather than re-querying every time.
class ContactsCache extends ChangeNotifier {
  ContactsCache._internal();
  static final ContactsCache instance = ContactsCache._internal();

  List<AppContact> _contacts = [];
  List<AppContact> get contacts => _contacts;

  bool hasLoadedOnce = false;

  void setContacts(List<AppContact> value) {
    _contacts = value;
    notifyListeners();
  }
}