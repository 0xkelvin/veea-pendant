import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'models/session.dart';
import 'models/conversation.dart';
import 'models/audio_timeline.dart';
import 'services/library.dart';
import 'services/native_ai.dart';
import 'services/pendant_capture.dart';
import 'services/automation.dart';
import 'widgets/source_playback.dart';

class SageApp extends StatelessWidget {
  const SageApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sage',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff8f6f0),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff385d4b),
        surface: const Color(0xfff8f6f0),
      ),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xfff8f6f0)),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final library = Library(), pendant = PendantCapture();
  late final SageAutomation automation;
  final recorder = AudioRecorder();
  final player = AudioPlayer();
  int tab = 0;
  bool busy = false, micRecording = false;
  String? task, activePath, activeId;
  DateTime? started;
  String selectedModel = NativeAi.defaultModel;
  String selectedLanguage = 'auto';
  bool quietSpeech = false;
  bool get aiBusy => busy || automation.processing;
  String aiStatus = 'Checking on-device memory model…';
  Session? selected;
  String? conversationAnchor;
  bool reviewingSection = false;
  int _conversationRevision = -1;
  List<Conversation> _conversationCache = [];
  bool get capturing => micRecording || pendant.recording;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    automation = SageAutomation(library, pendant)..addListener(refresh);
    library.addListener(refresh);
    pendant.addListener(refresh);
    unawaited(
      library.load().then((_) async {
        if (!mounted) return;
        setState(() {
          selectedModel = library.transcriptionModel;
          selectedLanguage = library.language;
          quietSpeech = library.quietSpeech;
        });
        await automation.start();
      }),
    );
    library.ai
        .availability()
        .then((v) {
          if (mounted) setState(() => aiStatus = v);
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() => aiStatus = 'Local AI requires the iOS build.');
          }
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    automation.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> saveTranscriptionPreferences() async {
    library.language = selectedLanguage;
    library.quietSpeech = quietSpeech;
    await library.savePreferences();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    automation.removeListener(refresh);
    automation.dispose();
    library.removeListener(refresh);
    pendant.removeListener(refresh);
    unawaited(pendant.stopScan());
    unawaited(pendant.stop());
    unawaited(recorder.dispose());
    unawaited(player.dispose());
    super.dispose();
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
      );
    }
  }

  Future<void> work(String label, Future<void> Function() operation) async {
    if (busy) return;
    automation.queueSuspended = true;
    setState(() {
      busy = true;
      task = label;
    });
    try {
      await operation();
    } catch (e) {
      message(e.toString());
    } finally {
      automation.queueSuspended = false;
      if (mounted) {
        setState(() {
          busy = false;
          task = null;
        });
      }
    }
  }

  Future<void> queueTranscription(Session session) async {
    await player.pause();
    await automation.requestTranscription(
      session,
      TranscriptionRequest(
        model: selectedModel,
        language: selectedLanguage,
        quietSpeech: quietSpeech,
      ),
    );
  }

  Future<void> importAudio() => work('Importing audio…', () async {
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['wav', 'm4a', 'mp3', 'flac', 'aiff'],
    );
    if (f == null || f.path == null) return;
    final id = newId();
    final path = await library.audioPath(id, f.extension ?? 'wav');
    final source = File(f.path!);
    if (await source.length() > 250 * 1024 * 1024) {
      throw StateError('Import a file under 250 MB for this prototype.');
    }
    await source.copy(path);
    await library.ai.protect(path);
    double duration = 0;
    try {
      duration = ((await player.setFilePath(path))?.inMilliseconds ?? 0) / 1000;
    } catch (_) {}
    final s = Session(
      id: id,
      title: f.name,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      source: 'import',
      audioPath: path,
      duration: duration,
    );
    await library.add(s);
    setState(() {
      selected = s;
      conversationAnchor = null;
      reviewingSection = false;
      tab = 1;
    });
  });
  Future<void> toggleMic() => work(
    micRecording ? 'Saving recording…' : 'Starting microphone…',
    () async {
      if (micRecording) {
        final path = await recorder.stop();
        setState(() => micRecording = false);
        if (path == null) throw StateError('No recording was saved.');
        await library.ai.protect(path);
        final s = Session(
          id: activeId!,
          title: 'Voice note',
          createdAt: started!.toUtc().toIso8601String(),
          source: 'microphone',
          audioPath: path,
          duration: DateTime.now().difference(started!).inMilliseconds / 1000,
        );
        await library.add(s);
        setState(() {
          selected = s;
          conversationAnchor = null;
          reviewingSection = false;
          tab = 1;
        });
      } else {
        if (library.autoCapture && library.pendantId != null) {
          await automation.pause();
        }
        if (!await recorder.hasPermission()) {
          throw StateError('Allow microphone access in Settings.');
        }
        await player.pause();
        activeId = newId();
        activePath = await library.audioPath(activeId!);
        started = DateTime.now();
        await recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: activePath!,
        );
        setState(() => micRecording = true);
      }
    },
  );
  Future<void> stopPendant() => work('Saving Pendant audio…', () async {
    final session = await automation.pause();
    if (session != null && mounted) {
      setState(() {
        selected = session;
        conversationAnchor = null;
        reviewingSection = false;
        tab = 1;
      });
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: tab == 1 && selected != null
          ? IconButton(
              tooltip: 'Back to conversations',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() {
                if (reviewingSection && conversationAnchor != null) {
                  reviewingSection = false;
                } else {
                  tab = 0;
                }
              }),
            )
          : null,
      title: const Text(
        'sage',
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w600,
          letterSpacing: -1,
        ),
      ),
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 16),
          child: Chip(label: Text('PROTOTYPE')),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (busy) ...[
            const LinearProgressIndicator(),
            Padding(padding: const EdgeInsets.all(10), child: Text(task!)),
          ],
          Expanded(
            child: !library.ready
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        library.loadError ?? 'Opening your encrypted library…',
                      ),
                    ),
                  )
                : IndexedStack(
                    index: tab,
                    children: [
                      capturePage(),
                      reviewPage(),
                      memoriesPage(),
                      settingsPage(),
                    ],
                  ),
          ),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.graphic_eq), label: 'Capture'),
        NavigationDestination(icon: Icon(Icons.notes_rounded), label: 'Review'),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          label: 'Memories',
        ),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
      ],
    ),
  );
  Widget page(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
    children: children,
  );
  Widget heading(
    String eyebrow,
    String title,
    String text, {
    int? titleLines,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: const TextStyle(
            letterSpacing: 2,
            fontSize: 11,
            color: Color(0xff617768),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          maxLines: titleLines,
          overflow: titleLines == null ? null : TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w500,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 10),
        Text(text, style: TextStyle(color: Colors.grey.shade700, height: 1.5)),
      ],
    ),
  );
  Widget panel(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  Widget capturePage() => page([
    heading(
      'Your day, remembered',
      'Conversations,\nready to revisit.',
      library.macInference
          ? 'Sage reconnects to your Pendant. Your Mac prepares transcripts and topics.'
          : 'Sage reconnects to your saved Pendant and prepares transcripts and topics on this iPhone.',
    ),
    panel([
      const Icon(Icons.sensors, size: 44),
      const SizedBox(height: 12),
      const Text(
        'Limitless Pendant',
        style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      Text(pendant.status),
      const SizedBox(height: 6),
      Text(automation.status, style: const TextStyle(fontSize: 12)),
      if (automation.processing)
        Text(
          '${automation.pendingCount} audio sections waiting',
          style: const TextStyle(fontSize: 12),
        ),
      const SizedBox(height: 6),
      Text(pendant.syncStatus, style: const TextStyle(fontSize: 12)),
      if (pendant.warning != null && pendant.warning != pendant.status)
        Text(
          pendant.warning!,
          style: const TextStyle(color: Colors.deepOrange),
        ),
      const SizedBox(height: 14),
      if (pendant.recording)
        FilledButton.icon(
          onPressed: busy ? null : stopPendant,
          icon: const Icon(Icons.stop),
          label: const Text('Pause & save'),
        )
      else
        OutlinedButton.icon(
          onPressed: busy || capturing || pendant.scanning
              ? null
              : () => work('Starting Bluetooth scan…', pendant.scan),
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(pendant.scanning ? 'Searching…' : 'Find my Pendant'),
        ),
      if (!pendant.recording && library.pendantId != null)
        FilledButton.tonal(
          onPressed: busy || automation.connecting
              ? null
              : () => work('Resuming capture…', automation.resume),
          child: Text(
            library.autoCapture
                ? 'Reconnect saved Pendant'
                : 'Resume automatic capture',
          ),
        ),
      ...pendant.devices.values.map(
        (d) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(d.name.isEmpty ? 'Limitless Pendant' : d.name),
          subtitle: Text('${d.rssi} dBm'),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy || capturing || automation.connecting
              ? null
              : () => work('Connecting to Pendant…', () async {
                  await automation.connect(d);
                }),
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Audio saves every minute. After reconnecting, Sage checks the Pendant for stored recordings before returning to live audio. Keep Sage open while recovering audio.',
        style: TextStyle(fontSize: 12),
      ),
      if (!pendant.scanning &&
          !capturing &&
          pendant.nearby.isNotEmpty &&
          pendant.devices.isEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Discovery details'),
          subtitle: const Text('Nearby advertisements, for troubleshooting'),
          children: pendant.nearby.values
              .map(
                (d) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${d.name.isEmpty ? "Unnamed device" : d.name} · ${d.rssi} dBm',
                  ),
                  subtitle: Text(
                    'Services: ${d.serviceUuids.isEmpty ? "none advertised" : d.serviceUuids.join(", ")}',
                  ),
                  trailing: d.name.isEmpty
                      ? TextButton(
                          onPressed: busy
                              ? null
                              : () => work(
                                  'Identifying nearby device…',
                                  () => pendant.identify(d),
                                ),
                          child: const Text('Identify'),
                        )
                      : null,
                ),
              )
              .toList(),
        ),
    ]),
    const SizedBox(height: 12),
    panel([
      const Text('Try a short recording', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: busy || pendant.recording ? null : toggleMic,
        icon: Icon(micRecording ? Icons.stop : Icons.mic_none),
        label: Text(
          micRecording ? 'Stop & save voice note' : 'Record with iPhone',
        ),
      ),
      TextButton.icon(
        onPressed: busy || capturing ? null : importAudio,
        icon: const Icon(Icons.file_open_outlined),
        label: const Text('Import an audio file'),
      ),
      Text(
        library.macInference
            ? 'Let everyone know before recording. Saved audio is sent to your Mac for processing.'
            : 'Let everyone know before recording. Audio stays on this phone; uploads require a separate action.',
        style: TextStyle(fontSize: 12),
      ),
    ]),
    const SizedBox(height: 24),
    Text(
      '${conversations.length} conversations',
      style: const TextStyle(fontSize: 20),
    ),
    if (library.sessions.isEmpty)
      const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('Your first conversation will appear here.'),
      ),
    ...conversations.map(
      (conversation) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const CircleAvatar(child: Icon(Icons.forum_outlined)),
        title: Text(
          conversation.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conversationRange(conversation),
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '${audioLength(conversation.audioSeconds)} of audio${conversation.recording
                  ? ' · recording'
                  : conversation.pending > 0
                  ? ' · ${conversation.pending} sections processing'
                  : ''}',
            ),
            Text(
              conversation.text.isEmpty
                  ? 'Audio saved · transcript pending or no speech recognised'
                  : conversation.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => setState(() {
          selected = conversation.sections.first;
          conversationAnchor = selected!.id;
          reviewingSection = false;
          tab = 1;
        }),
      ),
    ),
  ]);

  List<Conversation> get conversations {
    if (_conversationRevision != library.revision) {
      _conversationCache = groupConversations(library.sessions);
      _conversationRevision = library.revision;
    }
    return _conversationCache;
  }

  String audioLength(double seconds) {
    final n = seconds.round();
    return n < 60 ? '${n}s' : '${n ~/ 60}m ${n % 60}s';
  }

  String clockTime(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  String conversationRange(Conversation conversation) {
    final start = conversation.start?.toLocal(),
        end = conversation.end?.toLocal();
    if (start == null || end == null) return 'Recording time unavailable';
    final endDate =
        start.year != end.year ||
            start.month != end.month ||
            start.day != end.day
        ? '${end.day}/${end.month}/${end.year} · '
        : '';
    return '${start.day}/${start.month}/${start.year} · ${clockTime(start)} – $endDate${clockTime(end)}';
  }

  Widget conversationPage(Conversation conversation) {
    final clips = conversation.sections
        .where((s) => s.processing != 'recording' && s.duration > 0)
        .map(
          (s) => AudioClip(
            s.audioPath,
            Duration(milliseconds: (s.duration * 1000).round()),
          ),
        )
        .toList();
    final ordered = conversations;
    final index = ordered.indexWhere(
      (g) => g.sections.any((s) => s.id == conversationAnchor),
    );
    final older = index >= 0 && index + 1 < ordered.length
        ? ordered[index + 1]
        : null;
    final canJoin =
        older != null &&
        compatibleSections(older.sections.last, conversation.sections.first);
    return page([
      heading(
        'Conversation',
        conversation.title,
        conversationRange(conversation),
        titleLines: 3,
      ),
      panel([
        Text(
          '${audioLength(conversation.audioSeconds)} of audio · ${conversation.sections.length} saved sections',
        ),
        if (conversation.pending > 0)
          Text(
            '${conversation.pending} sections still recording or processing. The transcript will fill in here.',
          ),
        const Text(
          'Nearby recordings are grouped by pauses and discussion continuity. Grouping may update as transcripts arrive.',
          style: TextStyle(fontSize: 12),
        ),
        if (canJoin)
          TextButton(
            onPressed: busy
                ? null
                : () => work('Joining conversations…', () async {
                    conversation.sections.first.conversationBreak = false;
                    await library.save();
                  }),
            child: const Text('Join previous conversation'),
          ),
        if (conversation.sections.first.conversationBreak != null)
          TextButton(
            onPressed: busy
                ? null
                : () => work('Restoring automatic grouping…', () async {
                    conversation.sections.first.conversationBreak = null;
                    await library.save();
                  }),
            child: const Text('Use automatic grouping here'),
          ),
      ]),
      if (clips.isNotEmpty)
        panel([
          SourcePlayback(
            key: ValueKey('group-${conversationAnchor!}'),
            player: player,
            path: 'conversation-${conversationAnchor!}',
            duration: AudioTimeline(clips).duration,
            clips: clips,
            enabled: tab == 1 && !busy && !micRecording,
            onError: message,
          ),
        ]),
      const Text('Transcript', style: TextStyle(fontSize: 23)),
      const SizedBox(height: 8),
      const Text(
        'Review a passage to correct it, compare models, or propose memories.',
        style: TextStyle(fontSize: 12),
      ),
      ...conversation.sections.asMap().entries.map((entry) {
        final section = entry.value;
        final start = recordingStart(section)?.toLocal();
        return panel([
          Text(
            start == null ? 'Time unavailable' : clockTime(start),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (section.workingText.trim().isNotEmpty)
            SelectableText(section.workingText)
          else
            Text(transcriptStatus(section)),
          if (section.reference != null)
            const Text('Your checked version', style: TextStyle(fontSize: 12)),
          if (section.processingError != null)
            Text(
              section.processingError!,
              style: const TextStyle(fontSize: 12),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  selected = section;
                  reviewingSection = true;
                }),
                child: const Text('Review this passage'),
              ),
              if (entry.key > 0)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => work('Splitting conversation…', () async {
                          section.conversationBreak = true;
                          conversationAnchor = section.id;
                          selected = section;
                          await library.save();
                        }),
                  child: const Text('Start new conversation here'),
                ),
              if (entry.key > 0 && section.conversationBreak != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => work('Restoring automatic grouping…', () async {
                          section.conversationBreak = null;
                          await library.save();
                        }),
                  child: const Text('Use automatic grouping here'),
                ),
            ],
          ),
        ]);
      }),
    ]);
  }

  String conversationTime(Session session) {
    if (session.source == 'limitless_offline' && session.recordedAt == null) {
      return 'Recording time unavailable · recovered from Pendant';
    }
    final date = DateTime.tryParse(
      session.recordedAt ?? session.createdAt,
    )?.toLocal();
    if (date == null) return 'Recording time unavailable';
    String two(int n) => n.toString().padLeft(2, '0');
    final label = session.source == 'import' ? 'Imported' : 'Recorded';
    return '$label ${two(date.day)}/${two(date.month)}/${date.year} · ${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  String transcriptStatus(Session session) => switch (session.processing) {
    'recording' =>
      'Recording now. Transcription starts after this section saves.',
    'queued' => 'Audio saved · waiting for transcription',
    'transcribing' =>
      library.macInference
          ? 'Transcribing this conversation on your Mac…'
          : 'Transcribing this conversation on your iPhone…',
    'classifying' || 'topics_pending' => 'Transcript saved · topics pending',
    'no_speech' =>
      'No speech recognised. The original audio is still available.',
    'failed' => 'Processing failed. See the error below and retry.',
    _ => 'No transcript yet. Select Transcribe next to process this recording.',
  };

  Widget reviewPage() {
    if (conversationAnchor != null && !reviewingSection) {
      for (final conversation in conversations) {
        if (conversation.sections.any((s) => s.id == conversationAnchor)) {
          return conversationPage(conversation);
        }
      }
    }
    final s = selected;
    if (s == null) {
      return page([
        heading(
          'Listen, then verify',
          'A little accuracy\ngoes a long way.',
          'Record or import a conversation in Capture to begin.',
        ),
      ]);
    }
    return page([
      heading(
        'Review the source',
        s.title,
        'Preserve mixed-language wording. Correct names, commitments, and negation before making memories.',
      ),
      panel([
        Text(
          conversationTime(s),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          s.source == 'import'
              ? 'Import time; the original recording time is unknown.'
              : s.source == 'limitless_offline'
              ? 'Recovered from Pendant storage. ${s.recordedAt == null ? 'Device timestamp was unavailable.' : 'Time comes from the Pendant clock${s.timeSource == 'device_adjusted' ? ', adjusted using the reconnect clock reading' : ''}.'}'
              : 'Local phone time at capture${s.timeSource == null ? ' (approximate for earlier recordings)' : ''}.',
        ),
      ]),
      panel([
        const Text('Transcript', style: TextStyle(fontSize: 21)),
        const SizedBox(height: 10),
        if (s.workingText.trim().isNotEmpty)
          SelectableText(s.workingText)
        else
          Text(transcriptStatus(s)),
        if (s.reference != null)
          const Text('Your checked version', style: TextStyle(fontSize: 12)),
        if (s.processing == 'queued') ...[
          const SizedBox(height: 8),
          Text(
            automation.prioritySessionId == s.id
                ? 'This conversation is next after the current job.'
                : '${automation.pendingCount} conversations waiting. Recent recordings are processed first.',
            style: const TextStyle(fontSize: 12),
          ),
        ],
        if (s.processing != 'recording' &&
            s.id != automation.processingSessionId &&
            (s.runs.isEmpty ||
                s.processing == 'failed' ||
                s.processing == 'topics_pending' ||
                s.processing == 'queued'))
          TextButton(
            onPressed: busy
                ? null
                : () => work(
                    'Prioritising conversation…',
                    () => s.runs.isEmpty
                        ? queueTranscription(s)
                        : automation.retry(s),
                  ),
            child: Text(
              s.runs.isEmpty ? 'Transcribe next' : 'Retry topics next',
            ),
          ),
      ]),
      if (s.captureWarning != null)
        panel([
          Text(
            s.captureWarning!,
            style: const TextStyle(color: Colors.deepOrange),
          ),
        ]),
      panel([
        Text('Processing: ${s.processing.replaceAll('_', ' ')}'),
        if (s.processingError != null) Text(s.processingError!),
        if (s.topics.isNotEmpty)
          Wrap(
            spacing: 6,
            children: s.topics
                .map((t) => Chip(label: Text(t['label'] as String)))
                .toList(),
          ),
        if (s.captureDiagnostics.isNotEmpty)
          ExpansionTile(
            title: const Text('Capture details'),
            children: s.captureDiagnostics.entries
                .where((e) => e.key != 'pageKeys')
                .map((e) => ListTile(title: Text('${e.key}: ${e.value}')))
                .toList(),
          ),
      ]),
      panel([
        SourcePlayback(
          player: player,
          path: s.audioPath,
          duration: Duration(milliseconds: (s.duration * 1000).round()),
          // Pendant capture writes a different WAV through BLE and does not
          // use the iPhone microphone or its playback audio session.
          enabled:
              tab == 1 && !busy && !micRecording && s.processing != 'recording',
          onError: message,
        ),
        if (s.processing == 'recording')
          const Text(
            'This section is still recording. You can play it once it is saved.',
          ),
      ]),
      panel([
        DropdownButtonFormField<String>(
          initialValue: selectedModel,
          decoration: const InputDecoration(labelText: 'Model to compare'),
          isExpanded: true,
          items:
              (library.macInference
                      ? {'Mac · Whisper large-v3': NativeAi.macModel}
                      : NativeAi.models)
                  .entries
                  .map(
                    (e) => DropdownMenuItem(value: e.value, child: Text(e.key)),
                  )
                  .toList(),
          onChanged: busy
              ? null
              : (v) {
                  setState(() => selectedModel = v!);
                },
        ),
        const SizedBox(height: 8),
        Text(
          selectedModel == NativeAi.macModel
              ? 'Runs on your Mac. Audio is sent to your configured local server; no paid AI API.'
              : NativeAi.modelDescriptions[selectedModel] ?? '',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        Text(
          'Automatic transcription: ${NativeAi.modelLabel(library.transcriptionModel)}',
        ),
        if (!library.macInference && selectedModel != library.model)
          TextButton(
            onPressed: aiBusy
                ? null
                : () => work('Setting automatic transcription model…', () async {
                    // Verify it is downloaded before changing the durable queue.
                    await library.ai.prepare(selectedModel, download: false);
                    library.model = selectedModel;
                    await library.savePreferences();
                  }),
            child: const Text('Use selected model for automatic transcription'),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: selectedLanguage,
          decoration: const InputDecoration(labelText: 'Speech language'),
          items: const [
            DropdownMenuItem(
              value: 'auto',
              child: Text('Automatic · Vietnamese + English'),
            ),
            DropdownMenuItem(value: 'vi', child: Text('Vietnamese first')),
            DropdownMenuItem(value: 'en', child: Text('English')),
          ],
          onChanged: busy
              ? null
              : (v) {
                  setState(() => selectedLanguage = v!);
                  unawaited(saveTranscriptionPreferences());
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Quiet speech retry'),
          subtitle: const Text(
            'Boosts only the transcription copy and relaxes silence rejection. Review for invented words in noise.',
          ),
          value: quietSpeech,
          onChanged: busy
              ? null
              : (v) {
                  setState(() => quietSpeech = v);
                  unawaited(saveTranscriptionPreferences());
                },
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: aiBusy
              ? null
              : () => work(
                  'Downloading / loading model. First use may take several minutes…',
                  () async {
                    await library.inference.prepare(selectedModel);
                    for (final pending in library.sessions.where(
                      (p) => p.processing == 'failed',
                    )) {
                      pending.processing = 'queued';
                    }
                    await library.save();
                  },
                ),
          child: Text(
            library.macInference
                ? 'Check Mac connection'
                : 'Download / load model',
          ),
        ),
        Text(
          library.macInference
              ? 'Whisper and topic generation run on your Mac. Keep both devices on the same network.'
              : 'Downloads model files from Hugging Face. Your audio is not uploaded.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed:
              busy ||
                  s.processing == 'recording' ||
                  s.id == automation.processingSessionId
              ? null
              : () => work(
                  'Queueing selected model…',
                  () => queueTranscription(s),
                ),
          child: Text(
            s.id == automation.processingSessionId
                ? 'Processing this conversation…'
                : s.transcriptionRequest != null
                ? 'Update queued transcription'
                : s.runs.isEmpty
                ? 'Transcribe next'
                : 'Queue comparison on same audio',
          ),
        ),
        if (s.transcriptionRequest != null)
          Text(
            'Queued: ${NativeAi.modelLabel(s.transcriptionRequest!.model)} · ${s.transcriptionRequest!.language}. Starts after the current job; keep the app open.',
          ),
        const Text(
          'Each run is saved separately below. Use the same language and quiet-speech settings for a fair model comparison. Your checked transcript is preserved.',
          style: TextStyle(fontSize: 12),
        ),
      ]),
      if (s.runs.isNotEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Transcript comparisons', style: TextStyle(fontSize: 21)),
        ),
      for (final run in s.runs)
        panel([
          Text(
            NativeAi.modelLabel(run.model),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            '${run.seconds.toStringAsFixed(1)}s processing · ${run.language}${run.quietSpeech ? ' · quiet retry' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          SelectableText(
            run.text.isEmpty
                ? 'No speech recognized. Audio is preserved; this does not mean the recording was empty.'
                : run.text,
          ),
          if (run.audioStats.isNotEmpty)
            Text(
              'Source level: ${(run.audioStats['rmsDb'] as num).toStringAsFixed(1)} dBFS · peak ${(run.audioStats['peakDb'] as num).toStringAsFixed(1)} dBFS · inference gain ${(run.audioStats['gain'] as num).toStringAsFixed(1)}×',
              style: const TextStyle(fontSize: 12),
            ),
          if (s.reference != null &&
              tokenErrorRate(s.reference!, run.text) != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Token error rate: ${(tokenErrorRate(s.reference!, run.text)! * 100).toStringAsFixed(1)}%',
              ),
            ),
        ]),
      if (s.runs.isNotEmpty || s.reference != null) ...[
        const SizedBox(height: 12),
        const Text('Your checked transcript', style: TextStyle(fontSize: 21)),
        const SizedBox(height: 8),
        Text(s.reference ?? 'Not reviewed yet.'),
        OutlinedButton(
          onPressed: busy
              ? null
              : () async {
                  final corrected = await editText(
                    'Check against the recording',
                    s.workingText,
                    'Changing this clears memories derived from the old transcript.',
                  );
                  if (corrected != null) {
                    await work('Saving correction…', () async {
                      s.correct(corrected);
                      await library.save();
                    });
                  }
                },
          child: const Text('Edit & confirm transcript'),
        ),
        const Text(
          'Token error rate compares space-separated words, ignoring case and punctuation. It is not an emotion or understanding score.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed:
              aiBusy || s.reference == null || s.reference!.trim().isEmpty
              ? null
              : () => work('Proposing memories on device…', () async {
                  if (s.memories.any((m) => m.status == 'accepted')) {
                    throw StateError(
                      'Accepted memories exist. Edit the transcript first if you want to replace them.',
                    );
                  }
                  final candidates = await library.ai.extract(s.reference!);
                  s.memories
                    ..clear()
                    ..addAll(candidates);
                  await library.save();
                  setState(() => tab = 2);
                  if (candidates.isEmpty) {
                    message('No supported memory candidates found.');
                  }
                }),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Propose memories'),
        ),
      ],
      const SizedBox(height: 20),
      TextButton(
        onPressed: aiBusy || capturing
            ? null
            : () async {
                if (await confirm(
                  'Delete this moment?',
                  'Remove audio, transcripts, and memories from this phone. A separately uploaded backend copy is not deleted by this action.',
                )) {
                  await work('Deleting…', () async {
                    await player.stop();
                    await library.remove(s);
                    setState(() {
                      selected = null;
                      conversationAnchor = null;
                      reviewingSection = false;
                      tab = 0;
                    });
                  });
                }
              },
        child: const Text(
          'Delete from this phone',
          style: TextStyle(color: Colors.redAccent),
        ),
      ),
    ]);
  }

  Widget memoriesPage() {
    final s = selected;
    return page([
      heading(
        'Understanding needs evidence',
        'You decide\nwhat stays.',
        'These are proposals, not established facts. Speaker identity is not inferred in this prototype.',
      ),
      if (s == null || s.memories.isEmpty)
        panel([
          const Text(
            'No candidates yet. Confirm a transcript in Review, then propose memories.',
          ),
        ])
      else ...[
        Text(s.title, style: const TextStyle(fontSize: 18)),
        ...s.memories.map(
          (m) => panel([
            Text(
              '${m.kind.replaceAll('_', ' ')} · ${m.status}',
              style: const TextStyle(fontSize: 12, color: Color(0xff617768)),
            ),
            const SizedBox(height: 8),
            Text(m.text, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 12),
            Text(
              '“${m.evidence}”',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (m.status != 'accepted')
                  FilledButton.tonal(
                    onPressed: busy
                        ? null
                        : () => work('Saving approval…', () async {
                            m.status = 'accepted';
                            await library.save();
                          }),
                    child: const Text('Accept'),
                  ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final value = await editText(
                            'Correct this memory',
                            m.text,
                            'Keep it supported by the quoted transcript.',
                          );
                          if (value != null && value.trim().isNotEmpty) {
                            await work('Saving correction…', () async {
                              m.text = value.trim();
                              m.status = 'pending';
                              await library.save();
                            });
                          }
                        },
                  child: const Text('Edit'),
                ),
                if (m.status != 'rejected')
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => work('Saving rejection…', () async {
                            m.status = 'rejected';
                            await library.save();
                          }),
                    child: const Text('Reject'),
                  ),
              ],
            ),
          ]),
        ),
      ],
      const SizedBox(height: 16),
      const Text(
        'No automatic advice or emotion diagnosis. The first milestone is accurate, correctable memory.',
      ),
    ]);
  }

  Widget settingsPage() => page([
    heading(
      'Your data, deliberately',
      'Local by default.',
      'Original audio stays on the iPhone. Mac processing sends a copy to your configured server. The transcript library is encrypted with a key stored in Keychain.',
    ),
    panel([
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Automatic Pendant capture'),
        subtitle: const Text(
          'Reconnect the saved Pendant when Sage opens. Save and process conversations automatically. Pausing stays paused after reopening.',
        ),
        value: library.autoCapture,
        onChanged: busy || automation.connecting
            ? null
            : (v) => work('Updating capture…', () async {
                if (v) {
                  await automation.resume();
                } else {
                  await automation.pause();
                }
              }),
      ),
      const Text(
        'Keep Sage running for live Bluetooth capture. Local transcription is queued while the app is inactive and resumes when you open it. Force-closing stops live capture.',
      ),
    ]),
    panel([
      const Text('Local memory model', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 8),
      Text(aiStatus),
      TextButton(
        onPressed: busy
            ? null
            : () => work('Checking model…', () async {
                aiStatus = await library.ai.availability();
              }),
        child: const Text('Check availability'),
      ),
    ]),
    panel([
      const Text('Mac backend', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 8),
      Text(
        library.backendUrl.isEmpty
            ? 'Not configured · no uploads'
            : library.backendUrl,
      ),
      const SizedBox(height: 8),
      const Text(
        'Mac processing sends saved audio to this server for transcription and text for topics. HTTP is for your trusted private Wi-Fi only. No third-party AI service is used.',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Process on Mac'),
        subtitle: const Text(
          'Keep the phone cool: queue audio when the Mac is offline. A running job finishes on its current device.',
        ),
        value: library.macInference,
        onChanged:
            busy || library.backendUrl.isEmpty || library.backendToken.isEmpty
            ? null
            : (value) => work('Updating processing location…', () async {
                library.macInference = value;
                selectedModel = library.transcriptionModel;
                await library.savePreferences();
              }),
      ),
      TextButton(
        onPressed: busy ? null : backendSettings,
        child: const Text('Configure server'),
      ),
      OutlinedButton(
        onPressed: busy || selected == null || library.backendUrl.isEmpty
            ? null
            : () async {
                if (await confirm(
                  'Back up this conversation?',
                  'Send all transcripts, your correction, and memory candidates for “${selected!.title}” to ${library.backendUrl}? Audio stays here.',
                )) {
                  await work('Backing up text…', () async {
                    await library.upload(selected!);
                    message('Text backup saved.');
                  });
                }
              },
        child: const Text('Back up selected conversation'),
      ),
      TextButton(
        onPressed: busy || selected == null || library.backendUrl.isEmpty
            ? null
            : () async {
                final session = selected!;
                if (await confirm(
                  'Delete server copy?',
                  'Delete the text backup for “${session.title}” from ${library.backendUrl}? Your phone copy stays available.',
                )) {
                  await work('Deleting server copy…', () async {
                    await library.deleteRemote(session);
                    message('Server copy deleted.');
                  });
                }
              },
        child: const Text('Delete selected conversation from server'),
      ),
    ]),
    panel([
      const Text('Prototype boundaries', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 8),
      const Text(
        '• Limitless live streaming verified on this Pendant; long background runs still need testing.\n• Stored audio recovery runs after reconnecting; keep the app open until it finishes.\n• Local transcription resumes when the app is active. Conversations use short audio sections.\n• Speaker identification and cloud AI are not enabled.\n• No battery or accuracy claims until measured.\n• Audio uses iOS file protection and is excluded from backup. Imported originals remain in their original location.',
      ),
    ]),
  ]);

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;
  Future<String?> editText(String title, String initial, String help) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(help),
                const SizedBox(height: 16),
                TextField(controller: controller, minLines: 5, maxLines: 12),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return value;
  }

  Future<void> backendSettings() async {
    final url = TextEditingController(text: library.backendUrl),
        token = TextEditingController(text: library.backendToken);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Your backend'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Server URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: token,
                obscureText: true,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Bearer token'),
              ),
              const SizedBox(height: 12),
              const Text(
                'For development use your Mac’s LAN address. HTTP on a private network is unencrypted; use HTTPS for sensitive conversations.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(c, (url.text.trim(), token.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), () {
      url.dispose();
      token.dispose();
    });
    if (result != null) {
      await work(
        'Saving settings…',
        () => library.settings(result.$1, result.$2),
      );
    }
  }
}
