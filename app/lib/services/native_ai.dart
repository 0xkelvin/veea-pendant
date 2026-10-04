import 'package:flutter/services.dart';
import '../models/session.dart';

class NativeAi {
  static const macModel = 'mac-whisper-large-v3';
  static const channel = MethodChannel('app.veea.sage/ai');
  static const defaultModel = 'large-v3-v20240930_626MB';
  static const models = {
    'Small · multilingual': 'small',
    'Turbo · multilingual': 'large-v3-v20240930_626MB',
    'Large v3 · multilingual': 'large-v3_947MB',
  };
  static String modelLabel(String model) => model == macModel
      ? 'Mac · Whisper large-v3'
      : models.entries
            .firstWhere(
              (entry) => entry.value == model,
              orElse: () => MapEntry(model, model),
            )
            .key;
  static const modelDescriptions = {
    'small': 'About 483 MB. Smaller multilingual model for comparison.',
    defaultModel: 'About 626 MB. Our current everyday transcription model.',
    'large-v3_947MB':
        'About 948 MB. Compressed Large v3 for accuracy comparison. Speed, battery use and Vietnamese accuracy still need testing on this phone.',
  };
  Future<void> _queue = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String> availability() async =>
      await channel.invokeMethod<String>('availability') ?? 'Unavailable';
  Future<void> prepare(String model, {bool download = true}) => _serial(
    () => channel.invokeMethod<void>(download ? 'prepare' : 'prepareCached', {
      'model': model,
    }),
  );
  Future<TranscriptRun> transcribe(
    String path,
    String model, {
    String language = 'auto',
    bool quietSpeech = false,
  }) => _serial(() async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'transcribe',
      {
        'path': path,
        'model': model,
        'language': language,
        'quietSpeech': quietSpeech,
      },
    );
    final json = Map<String, dynamic>.from(result!);
    return TranscriptRun.fromJson(json);
  });

  Future<List<MemoryCandidate>> extract(String text) => _serial(() async {
    final result = await channel.invokeListMethod<dynamic>('extract', {
      'text': text,
    });
    return (result ?? [])
        .map((v) {
          final j = Map<String, dynamic>.from(v as Map);
          return MemoryCandidate(
            id: newId(),
            text: j['text'] as String,
            evidence: j['evidence'] as String,
            kind: j['kind'] as String,
          );
        })
        .where((m) => m.evidence.trim().isNotEmpty && text.contains(m.evidence))
        .toList();
  });

  Future<Map<String, dynamic>> classify(String text) => _serial(() async {
    final result = await channel.invokeMapMethod<String, dynamic>('classify', {
      'text': text,
    });
    return Map<String, dynamic>.from(result!);
  });

  Future<void> protect(String path) =>
      channel.invokeMethod('protect', {'path': path});
  Future<void> saveLibrary(String content) =>
      channel.invokeMethod('saveLibrary', {'content': content});
  Future<String?> readLibrary() => channel.invokeMethod<String>('readLibrary');
}
