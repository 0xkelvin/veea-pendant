import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import '../models/session.dart';
import 'library.dart';
import 'remote_ai.dart';
import 'native_ai.dart';
import 'conversation_organizer.dart';
import 'pendant_capture.dart';
import 'pendant_archive.dart';

/// Reconnects the selected Pendant and journals continuous capture in short files.
/// Foreground processing uses the selected phone or authenticated Mac engine.
class SageAutomation extends ChangeNotifier {
  SageAutomation(this.library, this.pendant)
    : archive = PendantArchive(library),
      organizer = ConversationOrganizer(library) {
    pendant.onDisconnected = () => unawaited(_lostConnection());
    pendant.onStoredPage = archive.store;
    pendant.onStoredSyncFinished = () {
      _needsImport = true;
    };
  }
  final PendantArchive archive;
  final ConversationOrganizer organizer;
  bool _needsImport = true, _importing = false;
  final Library library;
  final PendantCapture pendant;
  Timer? _timer;
  Session? _active;
  bool foreground = true, connecting = false, processing = false;
  // Manual model loading/comparisons own the inference engine until finished.
  bool queueSuspended = false;
  bool _rotating = false, _stopping = false, _disposed = false;
  DateTime _nextConnect = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _sectionStarted = DateTime.now();
  int _attempts = 0;
  String status = 'Automatic capture ready';
  bool pairingBlocked = false;
  String? processingSessionId, prioritySessionId;
  DateTime _nextProcess = DateTime.fromMillisecondsSinceEpoch(0);
  int get pendingCount =>
      library.sessions.where((s) => s.processing == 'queued').length;

  List<Session> get pendingSessions {
    final pending = library.sessions
        .where((s) => s.processing == 'queued')
        .toList();
    pending.sort((a, b) {
      if (a.id == b.id) return 0;
      if (a.id == prioritySessionId) return -1;
      if (b.id == prioritySessionId) return 1;
      if ((a.transcriptionRequest != null) !=
          (b.transcriptionRequest != null)) {
        return a.transcriptionRequest != null ? -1 : 1;
      }
      return (b.recordedAt ?? b.createdAt).compareTo(
        a.recordedAt ?? a.createdAt,
      );
    });
    return pending;
  }

  Future<void> start() async {
    if (!library.ready) return;
    await _importStored();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(tick()),
    );
    await tick();
  }

  void setForeground(bool value) {
    foreground = value;
    if (value) unawaited(tick());
  }

  Future<void> tick() async {
    if (_disposed || !library.ready) return;
    if (foreground && !queueSuspended) unawaited(organizer.tick());
    if (pendant.recording && !pendant.connected && !connecting && !_stopping) {
      await _lostConnection();
    }
    if (_needsImport &&
        !pendant.syncingStored &&
        !connecting &&
        !_stopping &&
        !_rotating) {
      await _importStored();
    }
    if (pendant.recording &&
        !connecting &&
        !_stopping &&
        !_rotating &&
        pendant.bytesWritten > 0 &&
        DateTime.now().difference(_sectionStarted).inSeconds >= 60) {
      await _rotate();
    }
    if (foreground &&
        library.autoCapture &&
        !pairingBlocked &&
        !pendant.recording &&
        !connecting &&
        !_stopping &&
        !pendant.scanning &&
        library.pendantId != null &&
        DateTime.now().isAfter(_nextConnect)) {
      await connect(_rememberedDevice());
    }
    if (foreground && !processing && DateTime.now().isAfter(_nextProcess)) {
      unawaited(processQueue());
    }
  }

  Future<void> _importStored() async {
    if (_importing || !_needsImport) return;
    _importing = true;
    _needsImport = false;
    try {
      final count = await archive.importPending();
      if (archive.lastImportError != null) {
        pendant.syncStatus =
            'Recovered $count sections; some saved pages still need import: ${archive.lastImportError}';
        notifyListeners();
      } else if (count > 0) {
        pendant.syncStatus =
            'Recovered $count conversation sections from stored audio';
        notifyListeners();
      }
    } catch (e) {
      // Originals stay in the durable pending archive and retry on next launch.
      pendant.syncStatus =
          'Stored audio is saved on this phone but needs another import attempt: $e';
      notifyListeners();
    } finally {
      _importing = false;
    }
  }

  DiscoveredDevice _rememberedDevice() => DiscoveredDevice(
    id: library.pendantId!,
    name: library.pendantName,
    serviceData: const {},
    manufacturerData: Uint8List(0),
    rssi: 0,
    serviceUuids: const [],
  );

  Future<Session> _newSection() async {
    final id = newId();
    final session = Session(
      id: id,
      title: 'Pendant conversation',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      source: 'limitless',
      audioPath: await library.audioPath(id),
      processing: 'recording',
    );
    // Journal BEFORE creating the file, so recovery never needs to guess ownership.
    await library.add(session);
    return session;
  }

  Future<void> connect(DiscoveredDevice device) async {
    if (connecting || pendant.recording || _stopping || _disposed) return;
    connecting = true;
    pairingBlocked = false;
    status = 'Connecting to ${device.name.isEmpty ? 'Pendant' : device.name}…';
    notifyListeners();
    try {
      _active = await _newSection();
      await pendant.start(device, _active!.audioPath);
      library.pendantId = device.id;
      library.pendantName = device.name.isEmpty ? 'Pendant' : device.name;
      library.autoCapture = true;
      await library.savePreferences();
      _sectionStarted = DateTime.now();
      _attempts = 0;
      status = 'Capturing · saving one-minute sections automatically';
    } catch (error) {
      final text = pendant.warning ?? '$error';
      pairingBlocked =
          text.contains('pairing information') ||
          text.contains('Encryption is insufficient') ||
          text.contains('Authentication is insufficient');
      status = pairingBlocked
          ? 'Pairing needs attention. Check the Pendant connection message before retrying.'
          : 'Pendant unavailable. Saved-device retry will run automatically.';
      if (_active != null) {
        _active!.processing = 'empty';
        _active!.processingError = text;
        await library.save();
        _active = null;
      }
      _attempts++;
      _nextConnect = DateTime.now().add(
        Duration(seconds: _attempts < 3 ? 15 : 60),
      );
    } finally {
      connecting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _rotate() async {
    _rotating = true;
    try {
      final previous = _active;
      final next = await _newSection();
      final metadata = pendant.takeLiveMetadata();
      final saved = await pendant.writer.rotate(next.audioPath);
      _active = next;
      _sectionStarted = DateTime.now();
      if (previous != null && saved != null) {
        _finish(previous, saved.seconds, metadata: metadata);
        await library.save();
      }
    } catch (error) {
      status = 'Could not save audio section: $error';
      library.autoCapture = false;
    } finally {
      _rotating = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _finish(
    Session session,
    double duration, {
    Map<String, dynamic>? metadata,
  }) {
    session.duration = duration;
    session.captureWarning = pendant.warning;
    final timing = metadata ?? pendant.takeLiveMetadata();
    session.captureDiagnostics = {...pendant.diagnostics, ...timing};
    if (pendant.diagnostics['writeFailed'] == true) {
      session.captureDiagnostics['pageKeys'] = <String>[];
    }
    session.recordedAt = timing['recordedAt'] as String? ?? session.createdAt;
    session.timeSource = 'phone';
    session.processing = duration > 0 ? 'queued' : 'empty';
  }

  Future<Session?> pause({bool rememberPause = true}) async {
    if (_stopping) return null;
    _stopping = true;
    try {
      if (rememberPause) {
        library.autoCapture = false;
        await library.savePreferences();
      }
      // Rotation is brief, but must complete before finalizing its current file.
      while (_rotating) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final session = _active;
      final duration = await pendant.stop();
      if (session != null) {
        _finish(session, duration);
        await library.save();
      }
      _active = null;
      status = rememberPause ? 'Capture paused' : 'Waiting to reconnect';
      return session != null && duration > 0 ? session : null;
    } finally {
      _stopping = false;
      if (!_disposed) notifyListeners();
      if (foreground) unawaited(processQueue());
    }
  }

  Future<void> _lostConnection() async {
    if (_stopping || connecting) return;
    await pause(rememberPause: false);
    _needsImport = true;
    _nextConnect = DateTime.now().add(const Duration(seconds: 5));
  }

  Future<void> resume() async {
    library.autoCapture = true;
    pairingBlocked = false;
    _nextConnect = DateTime.fromMillisecondsSinceEpoch(0);
    await library.savePreferences();
    await tick();
  }

  Future<void> retry(Session session) async {
    if (session.id == processingSessionId ||
        session.processing == 'recording') {
      return;
    }
    session.processing = 'queued';
    session.processingError = null;
    prioritySessionId = session.id;
    _nextProcess = DateTime.fromMillisecondsSinceEpoch(0);
    await library.save();
    await processQueue();
  }

  Future<void> requestTranscription(
    Session session,
    TranscriptionRequest request,
  ) async {
    if (session.id == processingSessionId ||
        session.processing == 'recording') {
      return;
    }
    session.transcriptionRequest = request;
    session.processing = 'queued';
    session.processingError = null;
    prioritySessionId = session.id;
    _nextProcess = DateTime.fromMillisecondsSinceEpoch(0);
    await library.save();
    if (!_disposed) notifyListeners();
    // The timer starts the job after the UI releases its short save operation.
  }

  Future<void> processQueue() async {
    if (processing || queueSuspended || !foreground || _disposed) return;
    final pending = pendingSessions;
    if (pending.isEmpty) return;
    processing = true;
    final inference = library.inference;
    final onMac = library.macInference;
    var macOffline = false;
    notifyListeners();
    try {
      // Re-evaluate priority between jobs; a backlog must not monopolize the
      // engine or make today's conversations wait behind hours of old audio.
      for (final session in pending.take(1)) {
        if (queueSuspended || !foreground || _disposed) break;
        if (session.processing != 'queued') continue;
        processingSessionId = session.id;
        if (prioritySessionId == session.id) prioritySessionId = null;
        session.processing = 'transcribing';
        session.processingError = null;
        await library.save();
        try {
          final request = session.transcriptionRequest;
          if (session.runs.isEmpty || request != null) {
            status = onMac
                ? 'Transcribing a saved conversation on your Mac…'
                : 'Transcribing a saved conversation on this iPhone…';
            notifyListeners();
            final model = onMac
                ? NativeAi.macModel
                : (request?.model == NativeAi.macModel
                          ? library.model
                          : request?.model) ??
                      library.model;
            await inference.prepare(model, download: false);
            final run = await inference.transcribe(
              session.audioPath,
              model,
              language: request?.language ?? library.language,
              quietSpeech: request?.quietSpeech ?? library.quietSpeech,
            );
            session.runs.add(run);
            session.transcriptionRequest = null;
            session.topics = [];
            if (session.reference == null) session.memories.clear();
            // Commit transcription before attempting optional topic generation.
            await library.save();
          }
          if (session.workingText.trim().isEmpty) {
            session.processing = 'no_speech';
            session.processingError =
                'No speech recognized. Audio is preserved; try Vietnamese or Quiet speech in Review.';
          } else {
            session.processing = 'classifying';
            status = onMac
                ? 'Transcript saved · preparing topics on your Mac…'
                : 'Transcript saved · preparing topics on this iPhone…';
            await library.save();
            final classified = await inference.classify(session.workingText);
            session.topics = (classified['topics'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .where(
                  (t) =>
                      (t['evidence'] as String).isNotEmpty &&
                      session.workingText.contains(t['evidence'] as String),
                )
                .toList();
            if (session.topics.isNotEmpty) {
              session.title = session.topics
                  .map((t) => t['label'])
                  .take(2)
                  .join(' · ');
            }
            session.processing = 'ready';
          }
        } on MacUnavailable catch (error) {
          macOffline = true;
          session.processing =
              session.runs.isEmpty || session.transcriptionRequest != null
              ? 'queued'
              : 'topics_pending';
          session.processingError = '$error';
        } catch (error) {
          session.processing = session.runs.isEmpty
              ? 'failed'
              : 'topics_pending';
          session.processingError = '$error';
        }
        await library.save();
      }
    } finally {
      processing = false;
      processingSessionId = null;
      // Keep a breathing interval between local jobs instead of continuously
      // draining hundreds of recovered recordings on the phone.
      _nextProcess = DateTime.now().add(
        Duration(
          seconds: macOffline
              ? 60
              : onMac
              ? 2
              : 10,
        ),
      );
      status = macOffline
          ? 'Waiting for your Mac · audio saved · retry in one minute'
          : pendingCount > 0
          ? '$pendingCount audio sections waiting · recent recordings first'
          : 'Saved conversations processed';
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    organizer.disposed = true;
    _timer?.cancel();
    pendant.onDisconnected = null;
    pendant.onStoredPage = null;
    pendant.onStoredSyncFinished = null;
    super.dispose();
  }
}
