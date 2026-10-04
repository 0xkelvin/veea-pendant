import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veea_sage/services/native_ai.dart';
import 'package:veea_sage/services/remote_ai.dart';

void main() {
  test(
    'Mac job uploads settings, polls and restores a timestamped run',
    () async {
      final root = await Directory.systemTemp.createTemp('sage-remote-');
      final file = File('${root.path}/sample.wav');
      await file.writeAsBytes([1, 2, 3]);
      var polls = 0;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret');
        if (request.method == 'POST') {
          expect(request.url.queryParameters['language'], 'vi');
          expect(request.url.queryParameters['quietSpeech'], 'true');
          expect(request.bodyBytes, [1, 2, 3]);
          return http.Response('{"id":"job-1"}', 200);
        }
        polls++;
        if (polls == 1) return http.Response('{"status":"processing"}', 200);
        return http.Response(
          jsonEncode({
            'status': 'complete',
            'run': {
              'model': NativeAi.macModel,
              'text': 'Chưa gửi firmware.',
              'seconds': 0.5,
              'language': 'vi',
              'quietSpeech': true,
              'segments': [
                {'start': 1.2, 'end': 2.3, 'text': 'Chưa gửi firmware.'},
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final ai = RemoteAi(
        'http://mac.local:8789',
        'secret',
        client: client,
        pollInterval: Duration.zero,
      );
      final run = await ai.transcribe(
        file.path,
        NativeAi.macModel,
        language: 'vi',
        quietSpeech: true,
      );
      expect(run.text, 'Chưa gửi firmware.');
      expect(run.segments.single['start'], 1.2);
      expect(polls, 2);
      await root.delete(recursive: true);
    },
  );
  test(
    'offline Mac is retriable; rejected token is a configuration error',
    () async {
      final offline = RemoteAi(
        'http://mac.local:8789',
        'secret',
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(
        offline.prepare(NativeAi.macModel),
        throwsA(isA<MacUnavailable>()),
      );
      final rejected = RemoteAi(
        'http://mac.local:8789',
        'secret',
        client: MockClient((_) async => http.Response('Unauthorized', 401)),
      );
      await expectLater(
        rejected.prepare(NativeAi.macModel),
        throwsA(isA<StateError>()),
      );
    },
  );
}
