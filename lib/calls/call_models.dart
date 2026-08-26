import 'package:flutter/foundation.dart';

enum CallState { ringing, accepted, declined, ended, missed, cancelled }

@immutable
class CallSession {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerPhoto;
  final String calleeId;
  final String chatId;
  final String type; // audio | video
  final CallState state;
  final int createdAt;

  const CallSession({
    required this.callId,
    required this.callerId,
    required this.callerName,
    this.callerPhoto = '',
    required this.calleeId,
    required this.chatId,
    this.type = 'audio',
    this.state = CallState.ringing,
    required this.createdAt,
  });

  CallSession copyWith({
    String? callId,
    String? callerId,
    String? callerName,
    String? callerPhoto,
    String? calleeId,
    String? chatId,
    String? type,
    CallState? state,
    int? createdAt,
  }) {
    return CallSession(
      callId: callId ?? this.callId,
      callerId: callerId ?? this.callerId,
      callerName: callerName ?? this.callerName,
      callerPhoto: callerPhoto ?? this.callerPhoto,
      calleeId: calleeId ?? this.calleeId,
      chatId: chatId ?? this.chatId,
      type: type ?? this.type,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'callId': callId,
    'callerId': callerId,
    'callerName': callerName,
    'callerPhoto': callerPhoto,
    'calleeId': calleeId,
    'chatId': chatId,
    'type': type,
    'state': state.name.toUpperCase(),
    'createdAt': createdAt,
  };

  factory CallSession.fromMap(String callId, Map<dynamic, dynamic> map) {
    return CallSession(
      callId: callId,
      callerId: (map['callerId'] ?? '') as String,
      callerName: (map['callerName'] ?? '') as String,
      callerPhoto: (map['callerPhoto'] ?? '') as String,
      calleeId: (map['calleeId'] ?? '') as String,
      chatId: (map['chatId'] ?? '') as String,
      type: (map['type'] ?? map['callType'] ?? 'audio') as String,
      state: parseCallState(map['state'] ?? map['status']),
      createdAt: ((map['createdAt'] ?? map['timestamp'] ?? 0) as num).toInt(),
    );
  }

  static CallState parseCallState(String? raw)  {
    if (raw == null) return CallState.ringing;
    final s = raw.toString().toUpperCase();
    return CallState.values.firstWhere(
          (e) => e.name.toUpperCase() == s,
      orElse: () => CallState.ringing,
    );
  }
}

@immutable
class IceCandidateModel {
  final String sdpMid;
  final int sdpMLineIndex;
  final String candidate;

  const IceCandidateModel({
    required this.sdpMid,
    required this.sdpMLineIndex,
    required this.candidate,
  });

  Map<String, dynamic> toMap() => {
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
    'candidate': candidate,
  };

  factory IceCandidateModel.fromMap(Map<dynamic, dynamic> map) {
    return IceCandidateModel(
      sdpMid: (map['sdpMid'] ?? '') as String,
      sdpMLineIndex: (map['sdpMLineIndex'] ?? 0) as int,
      candidate: (map['candidate'] ?? '') as String,
    );
  }
}

@immutable
class SdpPayload {
  final String type;
  final String sdp;

  const SdpPayload({required this.type, required this.sdp});

  Map<String, dynamic> toMap() => {
    'type': type,
    'sdp': sdp,
  };

  factory SdpPayload.fromMap(Map<dynamic, dynamic> map) {
    return SdpPayload(
      type: (map['type'] ?? '') as String,
      sdp: (map['sdp'] ?? '') as String,
    );
  }
}