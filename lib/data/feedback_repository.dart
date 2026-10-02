import 'package:firebase_database/firebase_database.dart';

/// One feedback submission. Mirrors the Kotlin `FeedbackDataModel` and the
/// shape `AdminScreen`'s [FeedbackItem] already reads back from
/// `feedback/{pushId}`.
class FeedbackModel {
  /// 'improvement' | 'challenge'
  final String type;
  final String message;
  final String phone;
  final int timestamp;

  const FeedbackModel({
    required this.type,
    required this.message,
    required this.phone,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'type': type,
        'message': message,
        'phone': phone,
        'timestamp': timestamp,
      };
}

/// Equivalent of the Kotlin `viewModel.sendFeedback(...)` — writes one
/// submission under the RTDB `feedback` node.
class FeedbackRepository {
  FeedbackRepository._();
  static final FeedbackRepository instance = FeedbackRepository._();

  final DatabaseReference _ref = FirebaseDatabase.instance.ref('feedback');

  Future<void> sendFeedback({
    required String message,
    required String type,
    required String phone,
  }) async {
    final model = FeedbackModel(
      type: type,
      message: message.trim(),
      phone: phone.trim(),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _ref.push().set(model.toMap());
  }
}
