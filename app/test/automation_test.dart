import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:veea_sage/models/session.dart';
import 'package:veea_sage/services/automation.dart';
import 'package:veea_sage/services/library.dart';
import 'package:veea_sage/services/native_ai.dart';
import 'package:veea_sage/services/remote_ai.dart';
import 'package:veea_sage/services/pendant_capture.dart';
import 'package:veea_sage/services/wav_writer.dart';

class TestAi extends NativeAi {
  int calls = 0;
  bool failTopics = false;
  bool offline = false;
  Completer<void>? transcriptionGate;
  final transcribedPaths = <String>[];
  final requests = <TranscriptionRequest>[];
  @override
  Future<void> protect(String path) async {}
  @override
  Future<void> prepare(String model, {bool download = true}) async {
    expect(download, isFalse);
    if (offline) throw const MacUnavailable();
  }

  @override
  Future<TranscriptRun> transcribe(
    String path,
    String model, {
    String language = 'auto',
    bool quietSpeech = false,
  }) async {
    calls++;
    transcribedPaths.add(path);
    requests.add(
      TranscriptionRequest(
        model: model,
        language: language,
        quietSpeech: quietSpeech,
      ),
    );
    await transcriptionGate?.future;
    return TranscriptRun(
      model: model,
      language: language,
      quietSpeech: quietSpeech,
      text: 'Tôi chưa gửi firmware.',
      seconds: 1,
      segments: [],
    );
  }

  @override
  Future<Map<String, dynamic>> classify(String text) async {
    if (failTopics) throw StateError('Local model unavailable');
    return {
      'topics': [
        {'label': 'Firmware', 'evidence': 'chưa gửi firmware'},
        {'label': 'Invented', 'evidence': 'not in source'},
      ],
    };
  }
}

class TestLibrary extends Library {
  TestLibrary(this.root, TestAi ai) : super(ai: ai) {
    ready = true;
  }
  @override
  NativeAi get inference => ai;
  final Directory root;
  int saved = 0;
  @override
  Future<void> save() async {
    saved++;
  }

  @override
  Future<void> savePreferences() async {}
  @override
  Future<String> audioPath(String id, [String extension = 'wav']) async =>
      '${root.path}/$id.$extension';
}

class TestPendant extends PendantCapture {
  int starts = 0;
  @override
  Future<void> start(DiscoveredDevice device, String path) async {
    starts++;
    recording = true;
    connected = true;
    deviceId = device.id;
    await writer.rotate(path);
    await writer.write(Uint8List(32000));
  }

  @override
  Future<double> stop() async {
    recording = false;
    connected = false;
    return (await writer.rotate(null))?.seconds ?? 0;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sage-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'offline Mac retains audio request without falling back to phone',
    () async {
      final ai = TestAi()..offline = true;
      final library = TestLibrary(root, ai)..macInference = true;
      final session = Session(
        id: 'offline',
        title: 'Offline',
        createdAt: 'now',
        source: 'limitless',
        audioPath: 'preserved.wav',
        processing: 'queued',
        transcriptionRequest: const TranscriptionRequest(
          model: NativeAi.macModel,
          language: 'vi',
          quietSpeech: false,
        ),
      );
      library.sessions.add(session);
      final automation = SageAutomation(library, TestPendant());
      await automation.processQueue();
      expect(ai.calls, 0);
      expect(session.processing, 'queued');
      expect(session.transcriptionRequest, isNotNull);
      expect(session.audioPath, 'preserved.wav');
      ai.offline = false;
      await automation.processQueue();
      expect(session.processing, 'ready');
      expect(ai.requests.single.model, NativeAi.macModel);
      expect(ai.requests.single.language, 'vi');
      automation.dispose();
    },
  );
  test(
    'queued comparison preserves selected settings and existing checked text',
    () async {
      final ai = TestAi()..transcriptionGate = Completer<void>();
      final library = TestLibrary(root, ai);
      final active = Session(
        id: 'active',
        title: 'Active',
        createdAt: '2026-10-04',
        source: 'import',
        audioPath: 'active.wav',
        processing: 'queued',
      );
      final comparison = Session(
        id: 'compare',
        title: 'Compare',
        createdAt: '2026-10-03',
        source: 'import',
        audioPath: 'compare.wav',
        reference: 'Checked words',
        runs: [
          TranscriptRun(
            model: 'small',
            text: 'Earlier words',
            seconds: 1,
            segments: [],
          ),
        ],
      );
      library.sessions.addAll([active, comparison]);
      final automation = SageAutomation(library, TestPendant());
      final running = automation.processQueue();
      while (ai.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await automation.requestTranscription(
        comparison,
        const TranscriptionRequest(
          model: 'large-v3_947MB',
          language: 'vi',
          quietSpeech: true,
        ),
      );
      expect(ai.calls, 1);
      final restored = Session.fromJson(comparison.toJson());
      expect(restored.transcriptionRequest!.model, 'large-v3_947MB');
      expect(restored.transcriptionRequest!.language, 'vi');
      expect(restored.transcriptionRequest!.quietSpeech, isTrue);
      library.sessions[1] = restored;
      ai.transcriptionGate!.complete();
      await running;
      await automation.processQueue();
      expect(ai.transcribedPaths, ['active.wav', 'compare.wav']);
      expect(ai.requests.last.model, 'large-v3_947MB');
      expect(ai.requests.last.language, 'vi');
      expect(ai.requests.last.quietSpeech, isTrue);
      expect(restored.runs.length, 2);
      expect(restored.reference, 'Checked words');
      expect(restored.transcriptionRequest, isNull);
      automation.dispose();
    },
  );
  test(
    'recent audio precedes backlog and a requested conversation runs next',
    () async {
      final ai = TestAi()..transcriptionGate = Completer<void>();
      final library = TestLibrary(root, ai);
      Session recording(String id, String recorded) => Session(
        id: id,
        title: id,
        createdAt: '2026-10-04T12:00:00Z',
        recordedAt: recorded,
        source: 'limitless_offline',
        audioPath: '$id.wav',
        processing: 'queued',
      );
      final oldest = recording('oldest', '2026-10-04T02:00:00Z');
      final middle = recording('middle', '2026-10-04T08:00:00Z');
      final recent = recording('recent', '2026-10-04T11:00:00Z');
      library.sessions.addAll([oldest, recent, middle]);
      final automation = SageAutomation(library, TestPendant());
      final active = automation.processQueue();
      while (ai.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(automation.processingSessionId, recent.id);
      expect(ai.transcribedPaths, ['recent.wav']);
      await automation.retry(oldest);
      expect(automation.prioritySessionId, oldest.id);
      expect(ai.calls, 1); // Do not interrupt or overlap the active native job.
      ai.transcriptionGate!.complete();
      await active;
      expect(recent.processing, 'ready');
      expect(automation.pendingCount, 2); // One job per queue turn.
      await automation.processQueue();
      expect(ai.transcribedPaths, ['recent.wav', 'oldest.wav']);
      expect(middle.processing, 'queued');
      expect(automation.prioritySessionId, isNull);
      automation.dispose();
    },
  );
  test(
    'manual comparison holds queue; saved runs survive and Turbo remains default',
    () async {
      final ai = TestAi();
      final library = TestLibrary(root, ai);
      final session = Session(
        id: 'compare',
        title: 'Same source',
        createdAt: 'now',
        source: 'import',
        audioPath: 'same.wav',
        processing: 'queued',
        reference: 'Tôi chưa gửi firmware.',
      );
      library.sessions.add(session);
      final automation = SageAutomation(library, TestPendant())
        ..queueSuspended = true;
      await automation.processQueue();
      expect(ai.calls, 0);
      expect(session.processing, 'queued');
      session.runs.addAll([
        TranscriptRun(
          model: NativeAi.defaultModel,
          text: 'Tôi đã gửi firmware.',
          seconds: 2,
          segments: [],
        ),
        TranscriptRun(
          model: 'large-v3_947MB',
          text: 'Tôi chưa gửi firmware.',
          seconds: 6,
          segments: [],
        ),
      ]);
      automation.queueSuspended = false;
      await automation.processQueue();
      expect(ai.calls, 0);
      expect(library.model, NativeAi.defaultModel);
      final restored = Session.fromJson(session.toJson());
      expect(restored.runs.map((r) => r.model), [
        NativeAi.defaultModel,
        'large-v3_947MB',
      ]);
      expect(restored.runs.first.text, 'Tôi đã gửi firmware.');
      expect(restored.runs.last.seconds, 6);
      expect(restored.reference, 'Tôi chưa gửi firmware.');
      expect(restored.processing, 'ready');
      automation.dispose();
    },
  );
  test(
    'rotation neither loses nor duplicates queued PCM; recovery repairs header',
    () async {
      final writer = WavWriter();
      final a = '${root.path}/a.wav', b = '${root.path}/b.wav';
      await writer.rotate(a);
      final before = writer.write(Uint8List.fromList([1, 2, 3, 4]));
      final rotated = writer.rotate(b);
      final after = writer.write(Uint8List.fromList([5, 6]));
      await before;
      expect((await rotated)!.bytes, 4);
      await after;
      await writer.rotate(null);
      expect((await File(a).readAsBytes()).sublist(44), [1, 2, 3, 4]);
      expect((await File(b).readAsBytes()).sublist(44), [5, 6]);
      await File(b).writeAsBytes([7, 8, 9], mode: FileMode.append);
      expect(await WavWriter.recover(b), 4);
      final recovered = await File(b).readAsBytes();
      expect(recovered.length, 48);
      expect(ByteData.sublistView(recovered).getUint32(40, Endian.little), 4);
      expect(recovered.sublist(44), [5, 6, 7, 8]);
    },
  );
  test(
    'selected Pendant reconnects on startup; pause persists and saves capture',
    () async {
      final ai = TestAi(), pendant = TestPendant();
      final library = TestLibrary(root, ai)..pendantId = 'saved-id';
      final automation = SageAutomation(library, pendant)..foreground = false;
      await automation.start();
      expect(pendant.starts, 0);
      automation.foreground = true;
      await automation.tick();
      expect(pendant.starts, 1);
      automation.foreground = false;
      final saved = await automation.pause();
      expect(saved!.duration, 1);
      expect(saved.processing, 'queued');
      expect(library.autoCapture, isFalse);
      automation.foreground = true;
      await automation.tick();
      expect(pendant.starts, 1);
      while (automation.processing) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(saved.processing, 'ready');
      expect(saved.topics.length, 1);
      expect(saved.title, 'Firmware');
      automation.dispose();
    },
  );
  test(
    'topic failure preserves transcript and retry does not rerun speech model',
    () async {
      final ai = TestAi()..failTopics = true;
      final library = TestLibrary(root, ai);
      final session = Session(
        id: '1',
        title: 'Test',
        createdAt: 'now',
        source: 'limitless',
        audioPath: 'test.wav',
        processing: 'queued',
      );
      library.sessions.add(session);
      final automation = SageAutomation(library, TestPendant());
      await automation.processQueue();
      expect(session.processing, 'topics_pending');
      expect(session.runs.length, 1);
      ai.failTopics = false;
      await automation.retry(session);
      expect(ai.calls, 1);
      expect(session.processing, 'ready');
      expect(session.workingText, 'Tôi chưa gửi firmware.');
      automation.dispose();
    },
  );
  test(
    'disconnect after setup saves audio and schedules reconnection without pausing',
    () async {
      final ai = TestAi(), pendant = TestPendant();
      final library = TestLibrary(root, ai)..pendantId = 'saved-id';
      final automation = SageAutomation(library, pendant);
      await automation.tick();
      pendant.connected = false;
      automation.foreground = false;
      await automation.tick();
      expect(pendant.recording, isFalse);
      expect(library.autoCapture, isTrue);
      expect(library.sessions.single.duration, 1);
      expect(library.sessions.single.processing, 'queued');
      automation.dispose();
    },
  );
}
