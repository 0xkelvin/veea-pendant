import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_sage/models/session.dart';
import 'package:veea_sage/services/library.dart';
import 'package:veea_sage/services/limitless_protocol.dart';
import 'package:veea_sage/services/pendant_capture.dart';

void main() {
  test(
    'negation correction invalidates accepted memories, preserves model output',
    () {
      final session = Session(
        id: '1',
        title: 'Test',
        createdAt: '2026-10-04',
        source: 'import',
        audioPath: '/private/audio.wav',
        reference: 'Tôi đã gửi firmware.',
        runs: [
          TranscriptRun(
            model: 'small',
            text: 'Tôi đã gửi firmware.',
            seconds: 1,
            segments: [],
          ),
        ],
        memories: [
          MemoryCandidate(
            id: 'm',
            text: 'Firmware sent',
            evidence: 'đã gửi',
            status: 'accepted',
          ),
        ],
      );
      session.correct('Tôi chưa gửi firmware.');
      expect(session.memories, isEmpty);
      expect(session.runs.single.text, 'Tôi đã gửi firmware.');
      expect(session.toJson(remote: true).containsKey('audioPath'), isFalse);
      expect(Session.fromJson(session.toJson()).reference, session.reference);
    },
  );
  test(
    'bilingual token scoring preserves accents and counts negation errors',
    () {
      expect(
        tokenErrorRate('Tôi chưa gửi firmware', 'tôi chưa gửi firmware!'),
        0,
      );
      expect(
        tokenErrorRate('Tôi chưa gửi firmware', 'Tôi đã gửi firmware'),
        .25,
      );
      expect(tokenErrorRate('má', 'ma'), 1);
      expect(tokenErrorRate('', 'anything'), isNull);
      expect(tokenErrorRate('one', 'one two three'), 2);
    },
  );
  test(
    'BLE reassembles out of order, ignores duplicates, respects boundaries',
    () {
      final protocol = LimitlessProtocol();
      // Wire bytes independently authored: message 7, two fragments, seq 1 then 0.
      expect(protocol.receive([8, 7, 16, 1, 24, 2, 34, 2, 30, 40]), isNull);
      expect(protocol.receive([8, 7, 16, 1, 24, 2, 34, 2, 30, 40]), isNull);
      expect(protocol.receive([8, 7, 16, 0, 24, 2, 34, 2, 10, 20])!.payload, [
        10,
        20,
        30,
        40,
      ]);
      expect(protocol.receive([8, 7, 16, 0, 24, 2, 34, 2, 10, 20]), isNull);
      expect(
        () => protocol.receive([8, 8, 16, 0, 24, 1, 34, 10, 1]),
        throwsFormatException,
      );
      expect(() => readProto([0x80]), throwsFormatException);
      expect(() => readProto([0]), throwsFormatException);
      final frame = [0xb8, 1, 2, 3, 4, 5, 6, 7, 8, 9];
      expect(LimitlessProtocol.opusFrames([26, 14, 18, 12, 34, 10, ...frame]), [
        frame,
      ]);
      expect(LimitlessProtocol.opusFrames([42, 10, ...frame]), isEmpty);
    },
  );
  test(
    'inconsistent BLE fragments fail and incomplete messages are bounded',
    () {
      final protocol = LimitlessProtocol();
      protocol.receive([8, 1, 16, 0, 24, 2, 34, 1, 42]);
      expect(
        () => protocol.receive([8, 1, 16, 1, 24, 3, 34, 1, 42]),
        throwsFormatException,
      );
      for (var i = 2; i <= 34; i++) {
        protocol.receive([8, i, 16, 0, 24, 2, 34, 1, 42]);
      }
      expect(protocol.droppedMessages, 2);
    },
  );
  test('short Opus packets and 64-bit metadata are not discarded', () {
    expect(LimitlessProtocol.opusFrames([34, 3, 0xf8, 0xff, 0xfe]), [
      [0xf8, 0xff, 0xfe],
    ]);
    expect(
      readProto([
        8,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        1,
      ]).single.value,
      -1,
    );
    expect(
      () => readProto([18, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1]),
      throwsFormatException,
    );
  });
  test('WAV header describes 16 kHz mono little endian PCM accurately', () {
    final header = wavHeader(32000);
    final fields = ByteData.sublistView(header);
    expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
    expect(fields.getUint32(4, Endian.little), 32036);
    expect(fields.getUint16(22, Endian.little), 1);
    expect(fields.getUint32(24, Endian.little), 16000);
    expect(fields.getUint32(40, Endian.little), 32000);
  });
  test('backup requires HTTPS except explicitly local development origins', () {
    for (final url in [
      'https://sage.example.com',
      'http://127.0.0.1:8787',
      'http://192.168.1.2:8787',
    ]) {
      expect(() => validateBackendUrl(url), returnsNormally);
    }
    for (final url in [
      'http://sage.example.com',
      'https://user:pass@example.com',
      'https://example.com/path',
      'https://example.com?token=abc',
    ]) {
      expect(() => validateBackendUrl(url), throwsFormatException);
    }
  });
}
