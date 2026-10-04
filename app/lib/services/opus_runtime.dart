import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_library;

/// opus_dart has one late-final library binding for the whole process.
/// Live capture and archive imports must share its initialization.
class OpusRuntime {
  static Future<void>? _loading;
  static Future<void> ensureLoaded() => _loading ??= _initialize();
  static Future<void> _initialize() async {
    try {
      initOpus(await opus_library.load());
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }
}
