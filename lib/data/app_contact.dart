class AppContact {
  final String name;
  final String phone;
  final String? uid;
  final String? photoUrl; // Base64 profile photo, same format as UserProfile.photoUrl
  final String source;

  const AppContact({
    required this.name,
    required this.phone,
    this.uid,
    this.photoUrl,
    this.source = 'UNKNOWN',
  });
}