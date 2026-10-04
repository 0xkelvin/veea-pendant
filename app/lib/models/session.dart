import 'dart:math';

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

class TranscriptRun {
  TranscriptRun({
    required this.model,
    required this.text,
    required this.seconds,
    required this.segments,
    this.language = 'auto',
    this.quietSpeech = false,
    this.audioStats = const {},
  });
  final String model;
  final String text;
  final double seconds;
  final List<Map<String, dynamic>> segments;
  final String language;
  final bool quietSpeech;
  final Map<String, dynamic> audioStats;
  Map<String, dynamic> toJson() => {
    'model': model,
    'text': text,
    'seconds': seconds,
    'segments': segments,
    'language': language,
    'quietSpeech': quietSpeech,
    'audioStats': audioStats,
  };
  factory TranscriptRun.fromJson(Map<String, dynamic> j) => TranscriptRun(
    model: j['model'] as String,
    text: j['text'] as String,
    seconds: (j['seconds'] as num).toDouble(),
    language: j['language'] as String? ?? 'auto',
    quietSpeech: j['quietSpeech'] as bool? ?? false,
    audioStats: Map<String, dynamic>.from(j['audioStats'] as Map? ?? {}),
    segments: (j['segments'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
  );
}

class MemoryCandidate {
  MemoryCandidate({
    required this.id,
    required this.text,
    required this.evidence,
    this.kind = 'observation',
    this.status = 'pending',
  });
  final String id;
  String text;
  final String evidence;
  final String kind;
  String status;
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'evidence': evidence,
    'kind': kind,
    'status': status,
  };
  factory MemoryCandidate.fromJson(Map<String, dynamic> j) => MemoryCandidate(
    id: j['id'] as String,
    text: j['text'] as String,
    evidence: j['evidence'] as String,
    kind: j['kind'] as String? ?? 'observation',
    status: j['status'] as String? ?? 'pending',
  );
}

class TranscriptionRequest {
  const TranscriptionRequest({
    required this.model,
    required this.language,
    required this.quietSpeech,
  });
  final String model, language;
  final bool quietSpeech;
  Map<String, dynamic> toJson() => {
    'model': model,
    'language': language,
    'quietSpeech': quietSpeech,
  };
  factory TranscriptionRequest.fromJson(Map<String, dynamic> json) =>
      TranscriptionRequest(
        model: json['model'] as String,
        language: json['language'] as String,
        quietSpeech: json['quietSpeech'] as bool,
      );
}

class Session {
  Session({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.source,
    required this.audioPath,
    this.reference,
    this.duration = 0,
    this.captureWarning,
    this.recordedAt,
    this.timeSource,
    this.processing = 'manual',
    this.processingError,
    this.transcriptionRequest,
    this.conversationBoundary,
    this.conversationBreak,
    this.topics = const [],
    this.captureDiagnostics = const {},
    List<TranscriptRun>? runs,
    List<MemoryCandidate>? memories,
  }) : runs = runs ?? [],
       memories = memories ?? [];
  final String id;
  String title;
  final String createdAt;
  final String source;
  String audioPath;
  String? reference;
  double duration;
  String? captureWarning;
  String? recordedAt;
  String? timeSource;
  String processing;
  String? processingError;
  TranscriptionRequest? transcriptionRequest;
  Map<String, dynamic>? conversationBoundary;
  bool? conversationBreak;
  List<Map<String, dynamic>> topics;
  Map<String, dynamic> captureDiagnostics;
  final List<TranscriptRun> runs;
  final List<MemoryCandidate> memories;
  String get workingText => reference ?? (runs.isEmpty ? '' : runs.last.text);

  // Any reference change invalidates all previous interpretations, including accepted ones.
  void correct(String text) {
    if (text != reference) {
      memories.clear();
      topics = [];
      reference = text;
      processing = 'queued';
      processingError = null;
    }
  }

  Map<String, dynamic> toJson({bool remote = false}) => {
    'id': id,
    'title': title,
    'createdAt': createdAt,
    'source': source,
    if (!remote) 'audioPath': audioPath,
    'reference': reference,
    'duration': duration,
    'captureWarning': captureWarning,
    'recordedAt': recordedAt,
    'timeSource': timeSource,
    'processing': processing,
    'processingError': processingError,
    if (!remote) 'transcriptionRequest': transcriptionRequest?.toJson(),
    if (!remote) 'conversationBoundary': conversationBoundary,
    if (!remote) 'conversationBreak': conversationBreak,
    'topics': topics,
    'captureDiagnostics': captureDiagnostics,
    'runs': runs.map((r) => r.toJson()).toList(),
    'memories': memories.map((m) => m.toJson()).toList(),
  };
  factory Session.fromJson(Map<String, dynamic> j) => Session(
    id: j['id'] as String,
    title: j['title'] as String,
    createdAt: j['createdAt'] as String,
    source: j['source'] as String,
    audioPath: j['audioPath'] as String? ?? '',
    reference: j['reference'] as String?,
    duration: (j['duration'] as num? ?? 0).toDouble(),
    captureWarning: j['captureWarning'] as String?,
    recordedAt: j['recordedAt'] as String?,
    timeSource: j['timeSource'] as String?,
    processing: j['processing'] as String? ?? 'manual',
    processingError: j['processingError'] as String?,
    conversationBreak: j['conversationBreak'] as bool?,
    conversationBoundary: j['conversationBoundary'] == null
        ? null
        : Map<String, dynamic>.from(j['conversationBoundary'] as Map),
    transcriptionRequest: j['transcriptionRequest'] == null
        ? null
        : TranscriptionRequest.fromJson(
            Map<String, dynamic>.from(j['transcriptionRequest'] as Map),
          ),
    topics: (j['topics'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList(),
    captureDiagnostics: Map<String, dynamic>.from(
      j['captureDiagnostics'] as Map? ?? {},
    ),
    runs: (j['runs'] as List? ?? [])
        .map((e) => TranscriptRun.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    memories: (j['memories'] as List? ?? [])
        .map(
          (e) => MemoryCandidate.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
  );
}

/// Space-delimited token error rate, not a calibrated linguistic Vietnamese WER.
/// Retains accents, ignores punctuation/case, and may exceed 100% with insertions.
double? tokenErrorRate(String reference, String hypothesis) {
  List<String> words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  final r = words(reference), h = words(hypothesis);
  if (r.isEmpty) return null;
  var previous = List<int>.generate(h.length + 1, (i) => i);
  for (var i = 1; i <= r.length; i++) {
    final row = List<int>.filled(h.length + 1, 0)..[0] = i;
    for (var j = 1; j <= h.length; j++) {
      row[j] = min(
        min(previous[j] + 1, row[j - 1] + 1),
        previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1),
      );
    }
    previous = row;
  }
  return previous.last / r.length;
}
