import '../models/conversation.dart';
import 'library.dart';
import 'remote_ai.dart';

class ConversationOrganizer {
  ConversationOrganizer(this.library);
  final Library library;
  bool _running = false, disposed = false;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> tick() async {
    if (disposed ||
        _running ||
        !library.macInference ||
        DateTime.now().isBefore(_next)) {
      return;
    }
    final pairs = boundaryCandidates(library.sessions);
    if (pairs.isEmpty) return;
    _running = true;
    final pair = pairs.first;
    final fingerprint = boundaryFingerprint(pair.before, pair.after);
    try {
      final ai = RemoteAi(library.backendUrl, library.backendToken);
      final decision = await ai.conversationBoundary(
        pair.before.workingText,
        pair.after.workingText,
      );
      if (!disposed &&
          pair.after.conversationBreak == null &&
          library.sessions.contains(pair.after) &&
          library.sessions.contains(pair.before) &&
          fingerprint == boundaryFingerprint(pair.before, pair.after)) {
        pair.after.conversationBoundary = {
          ...decision,
          'fingerprint': fingerprint,
          'previousId': pair.before.id,
        };
        await library.save();
      }
      _next = DateTime.now().add(const Duration(seconds: 5));
    } catch (_) {
      // Grouping is optional: keep the time-based view and every source recording.
      _next = DateTime.now().add(const Duration(minutes: 1));
    } finally {
      _running = false;
    }
  }
}
