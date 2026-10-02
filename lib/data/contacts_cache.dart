import 'package:flutter/foundation.dart';
import 'app_contact.dart';
import 'contacts_repository.dart';

/// App-wide singleton cache of the classified contact book, so leaving and
/// returning to the Contacts screen renders instantly rather than
/// re-scanning every time.
class ContactsCache extends ChangeNotifier {
  ContactsCache._internal();
  static final ContactsCache instance = ContactsCache._internal();

  ContactBook _book = const ContactBook();
  ContactBook get book => _book;

  /// App-user contacts only — kept for callers like the "start a discussion"
  /// picker that only care about users you can message in-app.
  List<AppContact> get contacts => _book.onApp;

  bool hasLoadedOnce = false;

  /// When the book was last rebuilt from a full device+Firebase scan. Used to
  /// debounce the silent background sync so re-entering the Contacts screen
  /// (or the app resuming) doesn't kick a fresh scan every time.
  DateTime? lastSyncAt;

  bool syncedWithin(Duration window) {
    final t = lastSyncAt;
    return t != null && DateTime.now().difference(t) < window;
  }

  void setBook(ContactBook value) {
    _book = value;
    lastSyncAt = DateTime.now();
    hasLoadedOnce = true;
    notifyListeners();
  }

  void clear() {
    _book = const ContactBook();
    lastSyncAt = null;
    hasLoadedOnce = false;
    notifyListeners();
  }
}
