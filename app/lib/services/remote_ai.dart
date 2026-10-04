import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/session.dart';
import 'native_ai.dart';

class MacUnavailable implements Exception {
  const MacUnavailable([
    this.reason = 'Mac unavailable. Audio is saved; retrying when reachable.',
  ]);
  final String reason;
  @override
  String toString() => reason;
}

/// The same interface as local inference, with no automatic on-phone fallback.
class RemoteAi extends NativeAi {
  RemoteAi(
    this.origin,
    this.token, {
    http.Client? client,
    this.pollInterval = const Duration(seconds: 2),
  }) : client = client ?? sharedClient;
  static final sharedClient = http.Client();
  final String origin, token;
  final http.Client client;
  final Duration pollInterval;
  Uri endpoint(String path, [Map<String, String>? query]) => Uri.parse(
    '${origin.replaceAll(RegExp(r'/+$'), '')}$path',
  ).replace(queryParameters: query);
  Map<String, String> get headers => {'Authorization': 'Bearer $token'};
  Future<Map<String, dynamic>> jsonResponse(
    Future<http.Response> future,
  ) async {
    try {
      final response = await future.timeout(const Duration(seconds: 130));
      if (response.statusCode == 401) {
        throw StateError('Mac rejected the pairing token. Check Settings.');
      }
      if (response.statusCode >= 500 || response.statusCode == 429) {
        throw const MacUnavailable();
      }
      if (response.statusCode != 200) {
        throw StateError(
          'Mac rejected this request (${response.statusCode}): ${response.body}',
        );
      }
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } on SocketException {
      throw const MacUnavailable();
    } on http.ClientException {
      throw const MacUnavailable();
    } on TimeoutException {
      throw const MacUnavailable();
    }
  }

  @override
  Future<void> prepare(String model, {bool download = true}) async {
    if (model != NativeAi.macModel) {
      throw StateError('Select the Mac Whisper model.');
    }
    await jsonResponse(
      client
          .get(endpoint('/v1/inference'), headers: headers)
          .timeout(const Duration(seconds: 8)),
    );
  }

  @override
  Future<TranscriptRun> transcribe(
    String path,
    String model, {
    String language = 'auto',
    bool quietSpeech = false,
  }) async {
    final file = File(path);
    if (await file.length() > 20 * 1024 * 1024) {
      throw StateError(
        'Mac transcription accepts WAV recordings up to ten minutes.',
      );
    }
    final submitted = await jsonResponse(
      client.post(
        endpoint('/v1/transcriptions', {
          'model': model,
          'language': language,
          'quietSpeech': '$quietSpeech',
        }),
        headers: {...headers, 'Content-Type': 'audio/wav'},
        body: await file.readAsBytes(),
      ),
    );
    final id = submitted['id'] as String;
    final deadline = DateTime.now().add(const Duration(minutes: 12));
    while (DateTime.now().isBefore(deadline)) {
      final result = await jsonResponse(
        client.get(endpoint('/v1/transcriptions/$id'), headers: headers),
      );
      if (result['status'] == 'complete') {
        return TranscriptRun.fromJson(
          Map<String, dynamic>.from(result['run'] as Map),
        );
      }
      if (result['status'] == 'failed') {
        throw const MacUnavailable(
          'Mac transcription failed. Original audio is saved; retrying later.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    throw const MacUnavailable(
      'Still processing on Mac. The saved job will be checked again.',
    );
  }

  Future<Map<String, dynamic>> conversationBoundary(
    String before,
    String after,
  ) => jsonResponse(
    client.post(
      endpoint('/v1/conversation-boundary'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'before': before.length > 3500
            ? before.substring(before.length - 3500)
            : before,
        'after': after.length > 3500 ? after.substring(0, 3500) : after,
      }),
    ),
  );

  @override
  Future<Map<String, dynamic>> classify(String text) => jsonResponse(
    client.post(
      endpoint('/v1/topics'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'text': text}),
    ),
  );
}
