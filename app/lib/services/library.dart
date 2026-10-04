import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/session.dart';
import 'native_ai.dart';
import 'remote_ai.dart';
import 'wav_writer.dart';

class Library extends ChangeNotifier {
  Library({NativeAi? ai}) : ai = ai ?? NativeAi();
  final NativeAi ai;
  final sessions = <Session>[];
  final secure = const FlutterSecureStorage();
  bool ready = false;
  int revision = 0;
  String? loadError;
  Future<void> _saveQueue = Future.value();
  String backendUrl = '', backendToken = '';
  String? pendantId;
  String pendantName = 'Pendant';
  bool autoCapture = true;
  String model = NativeAi.defaultModel, language = 'auto';
  bool quietSpeech = false;
  bool macInference = false;
  NativeAi get inference =>
      macInference ? RemoteAi(backendUrl, backendToken) : ai;
  String get transcriptionModel => macInference ? NativeAi.macModel : model;
  Future<void> savePreferences() async {
    await secure.write(
      key: 'capturePreferences',
      value: jsonEncode({
        'pendantId': pendantId,
        'pendantName': pendantName,
        'autoCapture': autoCapture,
        'macInference': macInference,
        'model': model,
        'language': language,
        'quietSpeech': quietSpeech,
      }),
    );
    notifyListeners();
  }

  Future<void> load() async {
    try {
      backendUrl = await secure.read(key: 'backendUrl') ?? '';
      backendToken = await secure.read(key: 'backendToken') ?? '';
      final preferences = await secure.read(key: 'capturePreferences');
      if (preferences != null) {
        final p = jsonDecode(preferences) as Map;
        pendantId = p['pendantId'] as String?;
        pendantName = p['pendantName'] as String? ?? 'Pendant';
        autoCapture = p['autoCapture'] as bool? ?? true;
        macInference = p['macInference'] as bool? ?? false;
        if (NativeAi.models.containsValue(p['model'])) {
          model = p['model'] as String;
        }
        language = p['language'] as String? ?? 'auto';
        quietSpeech = p['quietSpeech'] as bool? ?? false;
      }
      // USB developer pairing: secrets are imported into Keychain, never bundled.
      final support = await getApplicationSupportDirectory();
      final pairing = File('${support.path}/mac-backend.json');
      if (await pairing.exists()) {
        final config = jsonDecode(await pairing.readAsString()) as Map;
        await settings(config['url'] as String, config['token'] as String);
        macInference = true;
        await savePreferences();
        await pairing.delete();
      }
      final raw = await ai.readLibrary();
      if (raw != null) {
        sessions.addAll(
          (jsonDecode(raw) as List).map(
            (v) => Session.fromJson(Map<String, dynamic>.from(v as Map)),
          ),
        );
      }
      ready = true;
      for (final session in sessions) {
        // Sandboxed container paths can change after reinstalling an app update.
        final root = await getApplicationSupportDirectory();
        session.audioPath =
            '${root.path}/audio/${session.audioPath.split('/').last}';
        if (session.processing == 'recording') {
          final bytes = await WavWriter.recover(session.audioPath);
          session.duration = bytes / 32000;
          session.processing = bytes > 0 ? 'queued' : 'empty';
          session.captureWarning = 'Recovered after capture was interrupted.';
        } else if (session.processing == 'manual' &&
            (session.runs.isNotEmpty ||
                (session.source == 'limitless' && session.duration > 0))) {
          session.processing = 'queued';
        } else if (session.processing == 'transcribing' ||
            session.processing == 'classifying') {
          session.processing = 'queued';
        }
      }
      await save();
    } catch (e) {
      loadError = 'Could not unlock your library: $e';
    }
    notifyListeners();
  }

  Future<void> save() {
    if (!ready) {
      throw StateError(
        'Library has not loaded. Existing data will not be overwritten.',
      );
    }
    revision++;
    final snapshot = jsonEncode(sessions.map((s) => s.toJson()).toList());
    final next = _saveQueue.then((_) => ai.saveLibrary(snapshot));
    _saveQueue = next.catchError((Object _) {});
    notifyListeners();
    return next;
  }

  Future<String> audioPath(String id, [String extension = 'wav']) async {
    final root = await getApplicationSupportDirectory();
    final dir = await Directory('${root.path}/audio').create(recursive: true);
    await ai.protect(dir.path);
    return '${dir.path}/$id.$extension';
  }

  Future<void> add(Session session) async {
    sessions.insert(0, session);
    try {
      await save();
    } catch (_) {
      sessions.remove(session);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> remove(Session session) async {
    final index = sessions.indexOf(session);
    sessions.remove(session);
    try {
      await save();
    } catch (_) {
      sessions.insert(index, session);
      rethrow;
    }
    final file = File(session.audioPath);
    if (await file.exists()) await file.delete();
    for (final key in session.captureDiagnostics['pageKeys'] as List? ?? []) {
      if (key is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) continue;
      for (final ext in ['json', 'done']) {
        final original = File('${file.parent.path}/pendant-pages/$key.$ext');
        if (await original.exists()) await original.delete();
      }
    }
  }

  Future<void> settings(String url, String token) async {
    if (url.isNotEmpty) validateBackendUrl(url);
    await secure.write(key: 'backendUrl', value: url);
    await secure.write(key: 'backendToken', value: token);
    backendUrl = url;
    backendToken = token;
    notifyListeners();
  }

  Future<void> upload(Session session) async {
    validateBackendUrl(backendUrl);
    if (backendToken.isEmpty) {
      throw StateError('Configure the backend token first.');
    }
    final uri = Uri.parse(
      '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/v1/sessions/${session.id}',
    );
    final result = await http
        .put(
          uri,
          headers: {
            'Authorization': 'Bearer $backendToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(session.toJson(remote: true)),
        )
        .timeout(const Duration(seconds: 15));
    if (result.statusCode != 200) {
      throw StateError('Backend rejected backup (${result.statusCode}).');
    }
  }

  Future<void> deleteRemote(Session session) async {
    validateBackendUrl(backendUrl);
    if (backendToken.isEmpty) {
      throw StateError('Configure the backend token first.');
    }
    final uri = Uri.parse(
      '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/v1/sessions/${session.id}',
    );
    final result = await http
        .delete(uri, headers: {'Authorization': 'Bearer $backendToken'})
        .timeout(const Duration(seconds: 15));
    if (result.statusCode != 204) {
      throw StateError('Backend rejected deletion (${result.statusCode}).');
    }
  }
}

void validateBackendUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException(
      'Use a server origin, for example https://sage.example.com',
    );
  }
  final host = uri.host;
  final octets = host.split('.').map(int.tryParse).toList();
  final privateIp =
      octets.length == 4 &&
      octets.every((v) => v != null && v >= 0 && v <= 255) &&
      (octets[0] == 10 ||
          (octets[0] == 192 && octets[1] == 168) ||
          (octets[0] == 172 && octets[1]! >= 16 && octets[1]! <= 31));
  final local =
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host.endsWith('.local') ||
      privateIp;
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
    throw const FormatException(
      'Use HTTPS, or HTTP only on your private development network.',
    );
  }
}
