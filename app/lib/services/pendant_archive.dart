import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:opus_dart/opus_dart.dart';
import 'opus_runtime.dart';
import '../models/session.dart';
import 'library.dart';
import 'limitless_protocol.dart';
import 'wav_writer.dart';

/// Store original device pages before any cumulative ACK can free them.
/// Pending files survive app termination and can be decoded again without BLE.
class PendantArchive {
  PendantArchive(this.library, {this.decode});
  final Library library;
  final Int16List Function(List<int>)? decode;
  bool _importing = false;
  String? lastImportError;
  Future<Directory> get directory async {
    final audio = File(await library.audioPath('archive-location')).parent;
    final dir = await Directory(
      '${audio.path}/pendant-pages',
    ).create(recursive: true);
    await library.ai.protect(dir.path);
    return dir;
  }

  Future<void> store(String device, PendantPage page, int? clockOffset) async {
    final dir = await directory;
    final key = page.key(device);
    // Replayed pages are identical by content hash, including device identity.
    for (final suffix in ['done', 'json']) {
      final existing = File('${dir.path}/$key.$suffix');
      if (!await existing.exists()) continue;
      final saved = jsonDecode(await existing.readAsString()) as Map;
      final checked = PendantPage(
        saved['index'] as int,
        saved['session'] as int,
        base64Decode(saved['data'] as String),
      );
      if (checked.key(saved['device'] as String) != key) {
        throw const FormatException(
          'Existing stored page failed checksum verification',
        );
      }
      return;
    }
    final rawTime = page.timestampMs;
    final corrected = rawTime == null ? null : rawTime - (clockOffset ?? 0);
    final plausible =
        corrected != null &&
        corrected > 1577836800000 &&
        corrected <= DateTime.now().millisecondsSinceEpoch + 300000;
    final record = {
      'key': key,
      'device': device,
      'index': page.index,
      'session': page.session,
      'data': base64Encode(page.data),
      'recordedAt': plausible
          ? DateTime.fromMillisecondsSinceEpoch(
              corrected,
              isUtc: true,
            ).toIso8601String()
          : null,
      'timeSource': !plausible
          ? 'unknown'
          : clockOffset == null
          ? 'device'
          : 'device_adjusted',
      'receivedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final staging = File('${dir.path}/$key.tmp');
    await staging.writeAsString(jsonEncode(record), flush: true);
    await staging.rename('${dir.path}/$key.json');
  }

  Future<int> importPending() async {
    if (_importing) return 0;
    _importing = true;
    lastImportError = null;
    SimpleOpusDecoder? decoder;
    try {
      final dir = await directory;
      final known = <String>{};
      for (final s in library.sessions) {
        final file = File(s.audioPath);
        if (await file.exists() &&
            await file.length() >= 44 + (s.duration * 32000).round() &&
            s.duration > 0) {
          known.addAll(
            (s.captureDiagnostics['pageKeys'] as List? ?? []).cast<String>(),
          );
        }
      }
      final groups = <String, List<Map<String, dynamic>>>{};
      await for (final file in dir.list()) {
        if (file is! File || !file.path.endsWith('.json')) continue;
        final record = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map,
        );
        final page = PendantPage(
          record['index'] as int,
          record['session'] as int,
          base64Decode(record['data'] as String),
        );
        final key = page.key(record['device'] as String);
        if (record['key'] != key || !file.path.endsWith('/$key.json')) {
          throw const FormatException('Stored page checksum mismatch');
        }
        if (known.contains(key)) {
          await file.rename('${dir.path}/$key.done');
          continue;
        }
        final time = DateTime.tryParse(record['recordedAt'] as String? ?? '');
        final bucket = time == null
            ? 'unknown-${page.index ~/ 32}'
            : '${time.millisecondsSinceEpoch ~/ 60000}';
        groups
            .putIfAbsent(
              '${record['device']}:${page.session}:$bucket',
              () => [],
            )
            .add(record);
      }
      if (groups.isEmpty) return 0;
      if (decode == null) {
        await OpusRuntime.ensureLoaded();
        decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      }
      var imported = 0;
      final batches = <List<Map<String, dynamic>>>[];
      for (final records in groups.values) {
        records.sort(
          (a, b) => (a['index'] as int).compareTo(b['index'] as int),
        );
        // Bound memory even for an invalid clock that repeats one timestamp.
        for (var start = 0; start < records.length; start += 32) {
          batches.add(
            records.sublist(start, (start + 32).clamp(0, records.length)),
          );
        }
      }
      for (final records in batches) {
        try {
          if (decode == null) {
            decoder?.destroy();
            decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
          }
          final pcm = BytesBuilder(copy: false);
          // Raw source remains recoverable if parsing or decoding fails here.
          for (final record in records) {
            final page = PendantPage(
              record['index'] as int,
              record['session'] as int,
              base64Decode(record['data'] as String),
            );
            for (final frame in page.frames) {
              final samples =
                  decode?.call(frame) ??
                  decoder!.decode(input: Uint8List.fromList(frame));
              final bytes = Uint8List(samples.length * 2);
              final view = ByteData.sublistView(bytes);
              for (var i = 0; i < samples.length; i++) {
                view.setInt16(i * 2, samples[i], Endian.little);
              }
              pcm.add(bytes);
            }
          }
          final keys = records.map((r) => r['key'] as String).toList();
          if (pcm.isNotEmpty) {
            final id = 'offline-${keys.first}';
            final path = await library.audioPath(id);
            final bytes = pcm.takeBytes();
            final stage = File('$path.building');
            await stage.writeAsBytes([
              ...wavHeader(bytes.length),
              ...bytes,
            ], flush: true);
            await stage.rename(path);
            final session = Session(
              id: id,
              title: 'Recovered Pendant conversation',
              createdAt: records.first['receivedAt'] as String,
              recordedAt: records.first['recordedAt'] as String?,
              timeSource: records.first['timeSource'] as String,
              source: 'limitless_offline',
              audioPath: path,
              duration: bytes.length / 32000,
              processing: 'queued',
              captureDiagnostics: {
                'pageKeys': keys,
                'storedPages': keys.length,
                'recoveredFromPendant': true,
              },
            );
            await library.add(session);
            imported++;
          }
          // Library + WAV are committed before removing anything from the pending set.
          for (final key in keys) {
            await File('${dir.path}/$key.json').rename('${dir.path}/$key.done');
          }
        } catch (e) {
          lastImportError = '$e';
          // Keep this group pending, but allow other recoverable audio through.
        }
      }
      return imported;
    } finally {
      decoder?.destroy();
      _importing = false;
    }
  }
}
