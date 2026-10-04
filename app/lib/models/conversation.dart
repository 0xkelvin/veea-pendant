import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'session.dart';

/// A reversible view over source recordings, never a replacement for them.
class Conversation {
  Conversation(List<Session> values) : sections = List.unmodifiable(values);
  final List<Session> sections;
  String get id => sections.first.id;
  DateTime? get start => recordingStart(sections.first);
  DateTime? get end => recordingEnd(sections.last);
  double get audioSeconds => sections.fold(0, (n, s) => n + s.duration);
  int get pending => sections
      .where(
        (s) => [
          'queued',
          'transcribing',
          'classifying',
          'recording',
        ].contains(s.processing),
      )
      .length;
  bool get recording => sections.any((s) => s.processing == 'recording');
  String get text => sections
      .map((s) => s.workingText.trim())
      .where((s) => s.isNotEmpty)
      .join('\n\n');
  String get title {
    final labels = <String>[];
    for (final section in sections) {
      for (final topic in section.topics) {
        final label = (topic['label'] as String? ?? '').trim();
        if (label.isNotEmpty &&
            !labels.any((v) => v.toLowerCase() == label.toLowerCase())) {
          labels.add(label);
        }
      }
    }
    if (labels.isNotEmpty) return labels.take(3).join(' · ');
    if (sections.length == 1) return sections.first.title;
    return recording ? 'Conversation in progress' : 'Conversation';
  }
}

DateTime? recordingStart(Session s) =>
    s.source == 'limitless_offline' && s.recordedAt == null
    ? null
    : DateTime.tryParse(s.recordedAt ?? s.createdAt);
DateTime? recordingEnd(Session s) =>
    recordingStart(s)?.add(Duration(milliseconds: (s.duration * 1000).round()));
bool pendantSection(Session s) =>
    s.source == 'limitless' || s.source == 'limitless_offline';

/// Never automatically combine imports, unknown timestamps or overlapping copies.
bool compatibleSections(Session a, Session b) {
  final end = recordingEnd(a), start = recordingStart(b);
  return pendantSection(a) &&
      pendantSection(b) &&
      end != null &&
      start != null &&
      start.difference(end).inMilliseconds >= -3000;
}

DateTime? speechTime(Session s, {required bool end}) {
  final start = recordingStart(s);
  if (start == null || s.workingText.trim().isEmpty) return null;
  // A checked transcript may differ from the raw ASR alignment.
  if (s.reference != null || s.runs.isEmpty) {
    return end ? recordingEnd(s) : start;
  }
  final times =
      s.runs.last.segments
          .where((v) => (v['text'] as String? ?? '').trim().isNotEmpty)
          .map((v) => v[end ? 'end' : 'start'])
          .whereType<num>()
          .map((v) => v.toDouble())
          .where((v) => v.isFinite && v >= 0 && v <= s.duration + 1)
          .toList()
        ..sort();
  if (times.isEmpty) return end ? recordingEnd(s) : start;
  return start.add(
    Duration(milliseconds: ((end ? times.last : times.first) * 1000).round()),
  );
}

String boundaryFingerprint(Session before, Session after) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          before.id,
          before.workingText,
          after.id,
          after.workingText,
        ]),
      ),
    )
    .toString();

bool validBoundary(Session before, Session after) =>
    after.conversationBoundary?['fingerprint'] ==
    boundaryFingerprint(before, after);

class BoundaryPair {
  const BoundaryPair(this.before, this.after);
  final Session before, after;
}

/// A two-minute interruption ends the automatic group. Transcript timestamps can
/// reveal silence inside otherwise adjacent minute files. AI decisions are cached
/// against both exact texts and ignored as soon as a correction changes either.
List<Conversation> groupConversations(Iterable<Session> values) {
  final ordered = values.where((s) => s.processing != 'empty').toList()
    ..sort((a, b) {
      final time =
          (recordingStart(a) ??
                  DateTime.tryParse(a.createdAt) ??
                  DateTime(1970))
              .compareTo(
                recordingStart(b) ??
                    DateTime.tryParse(b.createdAt) ??
                    DateTime(1970),
              );
      return time != 0 ? time : a.id.compareTo(b.id);
    });
  final groups = <Conversation>[];
  var current = <Session>[];
  Session? spoken;
  void finish() {
    if (current.isNotEmpty) groups.add(Conversation(current));
    current = [];
    spoken = null;
  }

  for (final s in ordered) {
    if (current.isNotEmpty) {
      final previous = current.last;
      var split = !compatibleSections(previous, s);
      if (!split) {
        if (s.conversationBreak != null) {
          split = s.conversationBreak!;
        } else {
          final gap = recordingStart(s)!.difference(recordingEnd(previous)!);
          split = gap >= const Duration(minutes: 2);
          final latestSpeech = spoken == null
              ? null
              : speechTime(spoken!, end: true);
          final nextSpeech = speechTime(s, end: false) ?? recordingStart(s);
          if (latestSpeech != null &&
              nextSpeech != null &&
              nextSpeech.difference(latestSpeech) >=
                  const Duration(minutes: 2)) {
            split = true;
          }
          // Also bound runs of confirmed silence; unknown/queued audio is not silence.
          if (spoken == null &&
              current.every((v) => v.processing == 'no_speech') &&
              recordingStart(s)!.difference(recordingStart(current.first)!) >=
                  const Duration(minutes: 2)) {
            split = true;
          }
          if (spoken != null &&
              s.workingText.trim().isNotEmpty &&
              validBoundary(spoken!, s) &&
              s.conversationBoundary!['newConversation'] == true &&
              (s.conversationBoundary!['confidence'] as num? ?? 0) >= 0.85) {
            split = true;
          }
        }
      }
      if (split) finish();
    }
    current.add(s);
    if (s.workingText.trim().isNotEmpty) spoken = s;
  }
  finish();
  return groups.reversed.toList();
}

/// Evaluate both joins and previously split AI decisions, including late arrivals.
List<BoundaryPair> boundaryCandidates(Iterable<Session> values) {
  final ordered = values.where((s) => s.processing != 'empty').toList()
    ..sort(
      (a, b) => (recordingStart(a) ?? DateTime(1970)).compareTo(
        recordingStart(b) ?? DateTime(1970),
      ),
    );
  final pairs = <BoundaryPair>[];
  Session? before, previous;
  for (final s in ordered) {
    if (previous != null &&
        (!compatibleSections(previous, s) ||
            recordingStart(s)!.difference(recordingEnd(previous)!) >=
                const Duration(minutes: 2))) {
      before = null;
    }
    if (s.processing == 'recording') {
      previous = s;
      continue;
    }
    if (s.workingText.trim().isNotEmpty) {
      if (before != null &&
          s.conversationBreak == null &&
          !validBoundary(before, s)) {
        final last = speechTime(before, end: true),
            next = speechTime(s, end: false);
        if (last != null &&
            next != null &&
            next.difference(last) < const Duration(minutes: 2)) {
          pairs.add(BoundaryPair(before, s));
        }
      }
      before = s;
    } else if (s.processing != 'no_speech') {
      // Await the intervening transcript instead of skipping unknown context.
      before = null;
    }
    previous = s;
  }
  return pairs.reversed.toList();
}
