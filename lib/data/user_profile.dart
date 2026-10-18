class UserProfile {
  final String uid; // this IS the E.164 phone number, per AuthManager.kt
  final String name;
  final String phone;
  final String country;
  final String photoUrl; // Base64-encoded JPEG string, NOT a URL (see PrivateChatScreen.kt note)
  final int createdAt;

  // Random per-install id (see AuthManager.deviceId) of whichever device
  // most recently registered/saved this phone number's profile — enforces
  // one active device per phone number. Blank means a profile saved before
  // this field existed. See UsersProfile.kt's activeDeviceId for the full
  // explanation — this mirrors it exactly.
  final String activeDeviceId;

  // Firebase Auth uid (anonymous sign-in) of the install that owns this
  // record. The database rules let only that login write the record, and
  // authIndex/{authUid} maps it back to the phone. Blank on records saved
  // before the field existed — the owning device fills it in on its next
  // launch (AuthManager.linkAuthUid), and an account migration resets it.
  final String authUid;

  UserProfile({
    required this.uid,
    required this.name,
    required this.phone,
    required this.country,
    required this.photoUrl,
    required this.createdAt,
    this.activeDeviceId = '',
    this.authUid = '',
  });

  factory UserProfile.fromMap(Map<dynamic, dynamic> map) {
    return UserProfile(
      uid: map['uid'] as String? ?? '',
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      country: map['country'] as String? ?? '',
      photoUrl: map['photoUrl'] as String? ?? '',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
      activeDeviceId: map['activeDeviceId'] as String? ?? '',
      authUid: map['authUid'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'phone': phone,
      'country': country,
      'photoUrl': photoUrl,
      'createdAt': createdAt,
      'activeDeviceId': activeDeviceId,
      if (authUid.isNotEmpty) 'authUid': authUid,
    };
  }
}
