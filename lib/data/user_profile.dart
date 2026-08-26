class UserProfile {
  final String uid; // this IS the E.164 phone number, per AuthManager.kt
  final String name;
  final String phone;
  final String country;
  final String photoUrl; // Base64-encoded JPEG string, NOT a URL (see PrivateChatScreen.kt note)
  final int createdAt;

  UserProfile({
    required this.uid,
    required this.name,
    required this.phone,
    required this.country,
    required this.photoUrl,
    required this.createdAt,
  });

  factory UserProfile.fromMap(Map<dynamic, dynamic> map) {
    return UserProfile(
      uid: map['uid'] as String? ?? '',
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      country: map['country'] as String? ?? '',
      photoUrl: map['photoUrl'] as String? ?? '',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
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
    };
  }
}