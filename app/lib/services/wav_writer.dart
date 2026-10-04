import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class SavedAudio {
  SavedAudio(this.path, this.bytes);
  final String path;
  final int bytes;
  double get seconds => bytes / 32000;
}

/// Serializes packet writes and file rotation: packets queued after a rotation
/// belong to the next file, without tearing down the Bluetooth link.
class WavWriter {
  Future<void> _queue = Future.value();
  RandomAccessFile? _file;
  String? _path;
  int bytes = 0, _checkpoint = 0;
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<SavedAudio?> rotate(String? nextPath) => _enqueue(() async {
    SavedAudio? saved;
    if (_file != null) {
      await _header();
      await _file!.close();
      saved = SavedAudio(_path!, bytes);
      _file = null;
    }
    bytes = 0;
    _checkpoint = 0;
    _path = nextPath;
    if (nextPath != null) {
      _file = await File(nextPath).open(mode: FileMode.write);
      await _file!.writeFrom(wavHeader(0));
    }
    return saved;
  });

  Future<void> write(Uint8List pcm) => _enqueue(() async {
    if (_file == null) throw StateError('Audio file is closed');
    await _file!.writeFrom(pcm);
    bytes += pcm.length;
    if (bytes - _checkpoint >= 160000) {
      await _header();
      _checkpoint = bytes;
    }
  });

  Future<void> _header() async {
    await _file!.setPosition(0);
    await _file!.writeFrom(wavHeader(bytes));
    await _file!.setPosition(bytes + 44);
    await _file!.flush();
  }

  /// Repair a journaled, interrupted capture using complete PCM samples only.
  static Future<int> recover(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() < 44) return 0;
    final bytes = ((await file.length() - 44) ~/ 2) * 2;
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.truncate(bytes + 44);
      await handle.setPosition(0);
      await handle.writeFrom(wavHeader(bytes));
      await handle.flush();
    } finally {
      await handle.close();
    }
    return bytes;
  }
}

Uint8List wavHeader(int pcmBytes) {
  final out = Uint8List(44), b = ByteData.view(Uint8List(44).buffer);
  out.setRange(0, 4, 'RIFF'.codeUnits);
  out.setRange(8, 12, 'WAVE'.codeUnits);
  out.setRange(12, 16, 'fmt '.codeUnits);
  out.setRange(36, 40, 'data'.codeUnits);
  b.setUint32(4, pcmBytes + 36, Endian.little);
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  b.setUint32(40, pcmBytes, Endian.little);
  for (final range in [(4, 8), (16, 36), (40, 44)]) {
    out.setRange(
      range.$1,
      range.$2,
      b.buffer.asUint8List(range.$1, range.$2 - range.$1),
    );
  }
  return out;
}
