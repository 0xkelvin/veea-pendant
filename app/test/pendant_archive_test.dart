import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_sage/models/session.dart';
import 'package:veea_sage/services/limitless_protocol.dart';
import 'package:veea_sage/services/pendant_archive.dart';
import 'package:veea_sage/services/wav_writer.dart';
import 'automation_test.dart' show TestAi, TestLibrary;

class FailingLibrary extends TestLibrary {
  FailingLibrary(super.root, super.ai);
  bool fail = true;
  @override
  Future<void> save() async {
    if (fail) throw const FileSystemException('Disk full');
    await super.save();
  }
}

PendantPage page(int index, {int? timestamp = 1791080400000}) =>
    PendantPage(index, 9, [
      if (timestamp != null) ...intField(1, timestamp),
      // flash-page chunk -> audio -> Opus frame (a valid tiny DTX packet).
      26, 7, 18, 5, 34, 3, 0xf8, 0xff, 0xfe,
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('sage-archive-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test(
    'storage/page wire parsing and cumulative ACK never jump a missing page',
    () {
      final status = LimitlessProtocol.storage([
        42,
        10,
        42,
        8,
        8,
        4,
        16,
        7,
        24,
        9,
        32,
        10,
      ])!;
      expect([status.oldest, status.newest, status.session], [4, 7, 9]);
      final p = page(4);
      final parsed = LimitlessProtocol.pages(
        bytesField(2, [
          ...intField(2, 9),
          ...intField(5, 4),
          ...bytesField(6, p.data),
        ]),
      ).single;
      expect(parsed.frames.single, [0xf8, 0xff, 0xfe]);
      expect(parsed.timestampMs, 1791080400000);
      final watermark = PendantPageWatermark(4);
      expect(watermark.save(6), 3);
      expect(watermark.save(4), 4);
      expect(watermark.save(4), 4);
      expect(watermark.save(5), 6);
      expect(watermark.save(8), 6);
      expect(watermark.save(7), 8);
      final envelope = LimitlessProtocol().downloadStored();
      final command = protoValue(readProto(envelope), 4) as List<int>;
      expect(protoValue(readProto(command), 8), [8, 1, 16, 0]);
    },
  );

  test(
    'durable pages recover after restart with original time and no duplicate imports',
    () async {
      final library = TestLibrary(root, TestAi());
      final archive = PendantArchive(library, decode: (_) => Int16List(1600));
      final p = page(4);
      await archive.store('device', p, 1000);
      await archive.store('device', p, 1000);
      expect(library.sessions, isEmpty);
      final restarted = PendantArchive(library, decode: (_) => Int16List(1600));
      expect(await restarted.importPending(), 1);
      expect(
        library.sessions.single.recordedAt,
        DateTime.fromMillisecondsSinceEpoch(
          1791080399000,
          isUtc: true,
        ).toIso8601String(),
      );
      expect(library.sessions.single.timeSource, 'device_adjusted');
      expect(await File(library.sessions.single.audioPath).length(), 3244);
      await restarted.store('device', p, 0);
      expect(await restarted.importPending(), 0);
      expect(library.sessions.length, 1);
    },
  );

  test(
    'failed library commit leaves raw pages pending and a retry recovers them',
    () async {
      final library = FailingLibrary(root, TestAi());
      final archive = PendantArchive(library, decode: (_) => Int16List(1600));
      final p = page(4);
      await archive.store('device', p, null);
      expect(await archive.importPending(), 0);
      expect(archive.lastImportError, contains('Disk full'));
      expect(library.sessions, isEmpty);
      expect(
        await File(
          '${(await archive.directory).path}/${p.key('device')}.json',
        ).exists(),
        isTrue,
      );
      library.fail = false;
      expect(await archive.importPending(), 1);
      expect(library.sessions.length, 1);
    },
  );

  test(
    'exact pages already committed in a live WAV are not imported twice',
    () async {
      final library = TestLibrary(root, TestAi());
      final p = page(4);
      final path = await library.audioPath('live');
      await File(path).writeAsBytes([...wavHeader(32000), ...Uint8List(32000)]);
      await library.add(
        Session(
          id: 'live',
          title: 'Live',
          createdAt: 'now',
          source: 'limitless',
          audioPath: path,
          duration: 1,
          captureDiagnostics: {
            'pageKeys': [p.key('device')],
          },
        ),
      );
      final archive = PendantArchive(
        library,
        decode: (_) => throw StateError('Should not decode duplicate'),
      );
      await archive.store('device', p, null);
      expect(await archive.importPending(), 0);
      expect(library.sessions.length, 1);
    },
  );

  test(
    'missing device time is unknown, never replaced with download time',
    () async {
      final library = TestLibrary(root, TestAi());
      final archive = PendantArchive(library, decode: (_) => Int16List(1600));
      await archive.store('device', page(4, timestamp: null), null);
      expect(await archive.importPending(), 1);
      expect(library.sessions.single.recordedAt, isNull);
      expect(library.sessions.single.timeSource, 'unknown');
      expect(
        Session.fromJson(library.sessions.single.toJson()).recordedAt,
        isNull,
      );
    },
  );

  test(
    'undecodable audio remains recoverable in the local pending archive',
    () async {
      final archive = PendantArchive(
        TestLibrary(root, TestAi()),
        decode: (_) => throw const FormatException('Invalid Opus'),
      );
      final p = page(4);
      await archive.store('device', p, null);
      expect(await archive.importPending(), 0);
      expect(archive.lastImportError, contains('Invalid Opus'));
      expect(
        await File(
          '${(await archive.directory).path}/${p.key('device')}.json',
        ).exists(),
        isTrue,
      );
    },
  );
}
