import 'package:flutter_test/flutter_test.dart';
import 'package:veea_sage/models/conversation.dart';
import 'package:veea_sage/models/session.dart';
import 'package:veea_sage/models/audio_timeline.dart';

Session section(
  String id,
  int second, {
  double duration = 60,
  String text = 'Firmware đang được kiểm tra.',
  String source = 'limitless',
  bool known = true,
}) => Session(
  id: id,
  title: 'Pendant conversation',
  createdAt: DateTime.utc(
    2026,
    10,
    4,
  ).add(Duration(seconds: second)).toIso8601String(),
  recordedAt: known
      ? DateTime.utc(
          2026,
          10,
          4,
        ).add(Duration(seconds: second)).toIso8601String()
      : null,
  source: source,
  audioPath: '$id.wav',
  duration: duration,
  processing: text.isEmpty ? 'no_speech' : 'ready',
  runs: [TranscriptRun(model: 'test', text: text, seconds: 1, segments: [])],
);

void main() {
  test(
    'minute files form one chronological discussion; originals stay untouched',
    () {
      final a = section('a', 0), b = section('b', 62), c = section('c', 124);
      b.correct('Chưa gửi firmware.');
      final groups = groupConversations([c, a, b]);
      expect(groups.length, 1);
      expect(groups.single.sections.map((s) => s.id), ['a', 'b', 'c']);
      expect(groups.single.audioSeconds, 180);
      expect(groups.single.text, contains('Chưa gửi firmware.'));
      expect(b.runs.single.text, 'Firmware đang được kiểm tra.');
      expect(b.audioPath, 'b.wav');
    },
  );
  test(
    'long gaps, overlaps, imports and unknown recovery times are separate',
    () {
      expect(
        groupConversations([section('a', 0), section('b', 240)]).length,
        2,
      );
      expect(groupConversations([section('a', 0), section('b', 25)]).length, 2);
      expect(
        groupConversations([
          section('a', 0),
          section('b', 60, source: 'import'),
        ]).length,
        2,
      );
      expect(
        groupConversations([
          section('a', 0),
          section('b', 60, source: 'limitless_offline', known: false),
        ]).length,
        2,
      );
      expect(
        groupConversations([
          section('a', 0),
          section('b', 60, source: 'limitless_offline'),
        ]).length,
        1,
      );
    },
  );
  test(
    'speech timestamps detect a pause across otherwise adjacent audio files',
    () {
      final a = section('a', 0),
          quiet = section('quiet', 60, text: ''),
          quiet2 = section('quiet2', 120, text: ''),
          b = section('b', 180);
      a.runs.clear();
      a.runs.add(
        TranscriptRun(
          model: 'test',
          text: 'Done.',
          seconds: 1,
          segments: [
            {'start': 0.0, 'end': 5.0, 'text': 'Done.'},
          ],
        ),
      );
      final groups = groupConversations([a, quiet, quiet2, b]);
      expect(groups.length, 2);
      expect(groups.last.sections.map((s) => s.id), ['a', 'quiet', 'quiet2']);
      expect(groups.first.sections.single.id, 'b');
    },
  );
  test(
    'semantic split is conservative, cached, and invalidated by corrections',
    () {
      final a = section('a', 0), b = section('b', 62);
      b.conversationBoundary = {
        'fingerprint': boundaryFingerprint(a, b),
        'newConversation': true,
        'confidence': 0.7,
      };
      expect(groupConversations([a, b]).length, 1);
      b.conversationBoundary!['confidence'] = 0.96;
      expect(groupConversations([a, b]).length, 2);
      a.correct('Let us continue the firmware discussion.');
      expect(groupConversations([a, b]).length, 1);
      expect(boundaryCandidates([a, b]).single.after, b);
    },
  );
  test('manual joins and splits persist across reload and override AI', () {
    final a = section('a', 0), b = section('b', 62);
    b.conversationBreak = true;
    final restored = Session.fromJson(b.toJson());
    expect(groupConversations([a, restored]).length, 2);
    restored.conversationBreak = false;
    restored.conversationBoundary = {
      'fingerprint': boundaryFingerprint(a, restored),
      'newConversation': true,
      'confidence': 1,
    };
    expect(groupConversations([a, restored]).length, 1);
    expect(boundaryCandidates([a, restored]), isEmpty);
  });
  test(
    'late recovered section replaces stale adjacency without duplicate sources',
    () {
      final a = section('a', 0),
          b = section('b', 120),
          middle = section('middle', 60, source: 'limitless_offline');
      b.conversationBoundary = {
        'fingerprint': boundaryFingerprint(a, b),
        'newConversation': true,
        'confidence': 1,
      };
      final groups = groupConversations([b, a, middle]);
      expect(groups.length, 1);
      expect(groups.single.sections.length, 3);
      expect(
        boundaryCandidates([
          b,
          a,
          middle,
        ]).map((p) => '${p.before.id}-${p.after.id}'),
        ['middle-b', 'a-middle'],
      );
    },
  );
  test(
    'playlist seeks cross file boundaries and clamp to recorded duration',
    () {
      final timeline = AudioTimeline([
        const AudioClip('a', Duration(seconds: 62)),
        const AudioClip('b', Duration(seconds: 60)),
        const AudioClip('c', Duration(seconds: 10)),
      ]);
      expect(timeline.duration, const Duration(seconds: 132));
      expect(timeline.locate(const Duration(seconds: 62)), (
        index: 1,
        position: Duration.zero,
      ));
      expect(timeline.locate(const Duration(seconds: 75)), (
        index: 1,
        position: const Duration(seconds: 13),
      ));
      expect(timeline.locate(const Duration(seconds: -5)), (
        index: 0,
        position: Duration.zero,
      ));
      expect(timeline.locate(const Duration(seconds: 500)), (
        index: 2,
        position: const Duration(seconds: 10),
      ));
      expect(
        timeline.position(2, const Duration(seconds: 3)),
        const Duration(seconds: 125),
      );
    },
  );
}
