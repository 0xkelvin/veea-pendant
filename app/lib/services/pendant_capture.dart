import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:opus_dart/opus_dart.dart';
import 'opus_runtime.dart';
import 'limitless_protocol.dart';
import 'native_ai.dart';
import 'wav_writer.dart';
export 'wav_writer.dart' show wavHeader;

class PendantCapture extends ChangeNotifier {
  late final _ble = FlutterReactiveBle();
  final devices = <String, DiscoveredDevice>{};
  final _nearbyIds = <String>{};
  final nearby = <String, DiscoveredDevice>{};
  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _rx;
  Timer? _health, _scanTimeout;
  LimitlessProtocol _protocol = LimitlessProtocol();
  SimpleOpusDecoder? _decoder;
  final writer = WavWriter();
  VoidCallback? onDisconnected;
  Future<void> Function(String device, PendantPage page, int? clockOffset)?
  onStoredPage;
  VoidCallback? onStoredSyncFinished;
  String syncStatus = 'Stored audio has not been checked yet';
  String storedTransferOutcome = 'Not checked';
  bool syncingStored = false;
  bool _switchingToLive = false;
  DateTime? _liveCutover;
  Completer<PendantStorageState?>? _storageReply;
  Future<void> _storedQueue = Future.value();
  PendantPageWatermark? _watermark;
  int _batchEnd = -1, _lastAck = -1, _batchPending = 0, _batchEpoch = 0;
  DateTime? _lastStoredPage;
  int? _clockOffset;
  bool _clockSet = false, _liveWriteFailed = false;
  final _livePageKeys = <String>[];
  String? _liveRecordedAt;

  Map<String, dynamic> takeLiveMetadata() {
    final result = <String, dynamic>{
      'pageKeys': _liveWriteFailed
          ? <String>[]
          : List<String>.from(_livePageKeys),
      if (_liveRecordedAt != null) 'recordedAt': _liveRecordedAt,
    };
    _livePageKeys.clear();
    _liveRecordedAt = null;
    return result;
  }

  int packets = 0, protocolErrors = 0, decodeErrors = 0, controlPackets = 0;
  String? lastPacketError;
  Map<String, dynamic> get diagnostics => {
    'packets': packets,
    'decodedFrames': frames,
    'protocolErrors': protocolErrors,
    'decodeErrors': decodeErrors,
    'controlPackets': controlPackets,
    'incompleteMessages': _protocol.droppedMessages,
    'lastError': lastPacketError,
    'writeFailed': _liveWriteFailed,
    'storedTransferOutcome': storedTransferOutcome,
    'storedLastAck': _lastAck,
    'storedTargetPage': _batchEnd,
  };
  String status = 'Not connected';
  String? warning, deviceId;
  bool scanning = false, recording = false, connected = false;
  int frames = 0, errors = 0;
  int get bytesWritten => writer.bytes;
  DateTime? _lastAudio;
  int _generation = 0;

  Future<void> scan() async {
    await stopScan();
    devices.clear();
    _nearbyIds.clear();
    nearby.clear();
    status = 'Checking Bluetooth…';
    notifyListeners();
    final state = await _ble.statusStream
        .firstWhere((state) => state != BleStatus.unknown)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => BleStatus.unknown,
        );
    if (state != BleStatus.ready) {
      status = switch (state) {
        BleStatus.unauthorized =>
          'Allow Bluetooth for Sage in iPhone Settings → Privacy & Security → Bluetooth.',
        BleStatus.poweredOff => 'Turn Bluetooth on in iPhone Settings.',
        _ =>
          'Bluetooth is not ready (${state.name}). Reopen Sage and try again.',
      };
      notifyListeners();
      return;
    }
    scanning = true;
    status = 'Searching for your Pendant…';
    notifyListeners();
    if (Platform.isIOS) {
      try {
        final results = await NativeAi.channel.invokeListMethod<dynamic>(
          'scanPendants',
        );
        for (final result in results ?? []) {
          final item = Map<String, dynamic>.from(result as Map);
          _found(
            DiscoveredDevice(
              id: item['id'] as String,
              name: item['name'] as String,
              serviceData: const {},
              manufacturerData: Uint8List(0),
              rssi: item['rssi'] as int,
              serviceUuids: (item['services'] as List)
                  .map((s) => Uuid.parse(s as String))
                  .toList(),
            ),
          );
        }
      } catch (error) {
        status = 'Bluetooth: $error';
      } finally {
        await stopScan();
      }
      return;
    }
    _scan = _ble
        .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
        .listen(
          _found,
          onError: (Object error) {
            status = 'Bluetooth: $error';
            unawaited(stopScan());
          },
        );
    _scanTimeout = Timer(
      const Duration(seconds: 24),
      () => unawaited(stopScan()),
    );
  }

  void _found(DiscoveredDevice device) {
    _nearbyIds.add(device.id);
    if (nearby.length < 30 || nearby.containsKey(device.id)) {
      nearby[device.id] = device;
    }
    final name = device.name.toLowerCase();
    if (name.contains('limitless') ||
        name.contains('pendant') ||
        device.serviceUuids.contains(Uuid.parse(LimitlessProtocol.service))) {
      devices[device.id] = device;
    }
    status = devices.isEmpty
        ? 'Searching · ${_nearbyIds.length} nearby Bluetooth devices seen'
        : 'Found ${devices.length} Pendant candidate${devices.length == 1 ? '' : 's'}';
    notifyListeners();
  }

  Future<void> stopScan() async {
    final wasScanning = scanning;
    _scanTimeout?.cancel();
    await _scan?.cancel();
    _scan = null;
    scanning = false;
    if (wasScanning && !status.startsWith('Bluetooth:')) {
      status = devices.isEmpty
          ? 'No Pendant found (${_nearbyIds.length} nearby Bluetooth devices seen). Keep it nearby and disconnected from other apps, then retry.'
          : 'Found ${devices.length} Pendant candidate${devices.length == 1 ? '' : 's'}. Tap to connect.';
    }
    notifyListeners();
  }

  QualifiedCharacteristic _characteristic(String uuid) =>
      QualifiedCharacteristic(
        characteristicId: Uuid.parse(uuid),
        serviceId: Uuid.parse(LimitlessProtocol.service),
        deviceId: deviceId!,
      );

  /// Identify a nameless advertisement by services before sending any device commands.
  Future<void> identify(DiscoveredDevice device) async {
    await stopScan();
    if (recording || _connection != null) {
      throw StateError('Finish the current recording first.');
    }
    status = 'Checking the unnamed device’s services…';
    notifyListeners();
    final ready = Completer<void>();
    final connection = _ble
        .connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen(
          (event) {
            if (ready.isCompleted) return;
            if (event.connectionState == DeviceConnectionState.connected) {
              ready.complete();
            } else if (event.connectionState ==
                DeviceConnectionState.disconnected) {
              ready.completeError(
                StateError('Device disconnected before identification.'),
              );
            }
          },
          onError: (Object error) {
            if (!ready.isCompleted) ready.completeError(error);
          },
        );
    try {
      await ready.future.timeout(const Duration(seconds: 12));
      await _ble
          .discoverAllServices(device.id)
          .timeout(const Duration(seconds: 10));
      final services = await _ble.getDiscoveredServices(device.id);
      if (services.any((s) => s.id == Uuid.parse(LimitlessProtocol.service))) {
        devices[device.id] = device;
        status =
            'Limitless service verified. Tap the Pendant below to connect.';
      } else {
        status =
            'This device does not expose the Limitless service. No commands were sent.';
      }
    } catch (error) {
      status = 'Could not identify the unnamed device: $error';
    } finally {
      await connection.cancel();
      notifyListeners();
    }
  }

  Future<void> _command(List<int> command) =>
      _ble.writeCharacteristicWithResponse(
        _characteristic(LimitlessProtocol.tx),
        value: command,
      );

  Future<void> start(DiscoveredDevice device, String path) async {
    await stopScan();
    if (recording || _connection != null) {
      throw StateError('Finish the current recording first.');
    }
    final bluetooth = await _ble.statusStream
        .firstWhere((s) => s != BleStatus.unknown)
        .timeout(const Duration(seconds: 10));
    if (bluetooth != BleStatus.ready) {
      throw StateError(
        'Bluetooth is ${bluetooth.name}. Check Bluetooth permissions and power.',
      );
    }
    await OpusRuntime.ensureLoaded();
    _decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
    await writer.rotate(path);
    deviceId = device.id;
    _protocol = LimitlessProtocol();
    frames = 0;
    errors = 0;
    packets = protocolErrors = decodeErrors = controlPackets = 0;
    lastPacketError = null;
    warning = null;
    _lastAudio = null;
    _clockOffset = null;
    _clockSet = false;
    _liveWriteFailed = false;
    _livePageKeys.clear();
    _liveRecordedAt = null;
    syncingStored = false;
    _switchingToLive = false;
    _liveCutover = null;
    syncStatus = 'Checking stored audio after connection';
    recording = true;
    connected = false;
    status = 'Connecting…';
    final generation = ++_generation;
    final ready = Completer<void>();
    _connection = _ble
        .connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 30),
          servicesWithCharacteristicsToDiscover: {
            Uuid.parse(LimitlessProtocol.service): [
              Uuid.parse(LimitlessProtocol.tx),
              Uuid.parse(LimitlessProtocol.rx),
            ],
          },
        )
        .listen(
          (update) async {
            if (generation != _generation) return;
            if (update.connectionState == DeviceConnectionState.connected) {
              connected = true;
              try {
                status = 'Bluetooth connected · enabling audio notifications…';
                notifyListeners();
                _rx = _ble
                    .subscribeToCharacteristic(
                      _characteristic(LimitlessProtocol.rx),
                    )
                    .listen(
                      _receive,
                      onError: (Object e) =>
                          _problem('Audio stream interrupted: $e'),
                    );
                await Future<void>.delayed(const Duration(seconds: 1));
                if (generation != _generation) return;
                status = 'Bluetooth connected · setting Pendant clock…';
                notifyListeners();
                _clockSet = true;
                await _command(
                  _protocol.setTime(DateTime.now().millisecondsSinceEpoch),
                );
                await Future<void>.delayed(const Duration(milliseconds: 500));
                if (generation != _generation) return;
                status = 'Bluetooth connected · checking stored recordings…';
                notifyListeners();
                await _startStoredSync(generation);
                if (generation != _generation) return;
                status = syncingStored
                    ? 'Recovering stored audio'
                    : 'Connected · waiting for audio';
                _lastAudio = DateTime.now();
                if (!ready.isCompleted) ready.complete();
                _health = Timer.periodic(const Duration(seconds: 2), (_) {
                  if (syncingStored) {
                    if (_lastStoredPage != null &&
                        DateTime.now().difference(_lastStoredPage!).inSeconds >
                            15 &&
                        _batchPending == 0) {
                      unawaited(
                        _finishStoredSync(
                          _batchEpoch,
                          'Stored audio transfer stalled; remaining audio will retry after reconnect',
                        ),
                      );
                    }
                    return;
                  }
                  if (_lastAudio == null ||
                      DateTime.now().difference(_lastAudio!).inSeconds > 8) {
                    _problem(
                      'No recent audio frames. The room may be quiet, or the stream may have paused.',
                    );
                  }
                });
                notifyListeners();
              } catch (e, st) {
                if (!ready.isCompleted) ready.completeError(e, st);
                _problem('Connection setup failed: $e');
              }
            } else if (update.connectionState ==
                DeviceConnectionState.disconnected) {
              connected = false;
              final detail = update.failure;
              final reason = detail == null
                  ? 'iOS supplied no error details.'
                  : '${detail.code.name}: ${detail.message}';
              final message = ready.isCompleted
                  ? 'Pendant disconnected. $reason Stop to save received audio.'
                  : 'Pendant connection failed. $reason';
              _problem(message);
              if (!ready.isCompleted) {
                ready.completeError(StateError(message));
              } else {
                onDisconnected?.call();
              }
            }
          },
          onError: (Object e) {
            connected = false;
            _problem('Bluetooth connection failed: $e');
            if (!ready.isCompleted) ready.completeError(e);
          },
        );
    notifyListeners();
    try {
      await ready.future.timeout(const Duration(seconds: 45));
    } catch (error) {
      final failure = warning ?? 'Pendant connection failed: $error';
      await stop();
      _problem(failure);
      rethrow;
    }
  }

  void _problem(String message) {
    warning = message;
    status = message;
    notifyListeners();
  }

  void _observeControl(List<int> payload) {
    if (!_clockSet && _clockOffset == null) {
      final epoch = LimitlessProtocol.clockEpoch(payload);
      if (epoch != null) {
        final delta = epoch - DateTime.now().millisecondsSinceEpoch;
        if (delta.abs() <= 7 * 24 * 3600000) _clockOffset = delta;
      }
    }
    final storage = LimitlessProtocol.storage(payload);
    if (storage != null &&
        _storageReply != null &&
        !_storageReply!.isCompleted) {
      _storageReply!.complete(storage);
    }
  }

  Future<void> _startStoredSync(int generation) async {
    if (onStoredPage == null) {
      await _command(_protocol.stream(true));
      return;
    }
    final reply = Completer<PendantStorageState?>();
    _storageReply = reply;
    await _command(_protocol.storageStatus());
    final state = await reply.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
    _storageReply = null;
    if (generation != _generation) return;
    if (state == null || !state.hasPages) {
      syncStatus = state == null
          ? 'Storage status unavailable; stored audio was not checked'
          : 'No stored audio waiting';
      await _command(_protocol.stream(true));
      return;
    }
    _watermark = PendantPageWatermark(state.oldest);
    _lastAck = state.oldest - 1;
    _batchEnd = state.newest;
    _batchEpoch++;
    syncingStored = true;
    _lastStoredPage = DateTime.now();
    syncStatus = 'Recovering ${state.newest - state.oldest + 1} stored pages…';
    await _command(_protocol.downloadStored());
    notifyListeners();
  }

  void _queueStored(PendantPage page) {
    if (_batchPending >= 512) {
      unawaited(
        _finishStoredSync(
          _batchEpoch,
          'Transfer paused: storage could not keep up. Remaining pages are on the Pendant.',
        ),
      );
      return;
    }
    final epoch = _batchEpoch, device = deviceId!, offset = _clockOffset;
    _lastStoredPage = DateTime.now();
    _batchPending++;
    _storedQueue = _storedQueue
        .then((_) async {
          if (!syncingStored || epoch != _batchEpoch) return;
          await onStoredPage!(device, page, offset);
          if (!syncingStored || epoch != _batchEpoch) return;
          final saved = _watermark!.save(page.index);
          if (saved > _lastAck &&
              (saved - _lastAck >= 25 || saved >= _batchEnd)) {
            // Only contiguous pages with fsynced local originals may be reclaimed.
            await _command(_protocol.acknowledgeSaved(saved));
            _lastAck = saved;
          }
          syncStatus =
              'Recovering stored audio · page ${saved + 1} / ${_batchEnd + 1}';
          if (saved >= _batchEnd) {
            await _finishStoredSync(
              epoch,
              'Stored audio transferred; preparing conversations',
            );
          }
        })
        .catchError((Object e) async {
          if (epoch == _batchEpoch) {
            await _finishStoredSync(epoch, 'Stored audio recovery paused: $e');
          }
        })
        .whenComplete(() {
          _batchPending--;
        });
  }

  Future<void> _finishStoredSync(int epoch, String message) async {
    if (!syncingStored || epoch != _batchEpoch) return;
    final generation = _generation;
    syncingStored = false;
    _batchEpoch++;
    _switchingToLive = true;
    syncStatus = message;
    storedTransferOutcome = message;
    // Do not ACK an incomplete tail, failed save, or a gap in page indices.
    try {
      if (connected) await _command(_protocol.stream(true));
    } catch (e) {
      _problem('Could not resume live audio: $e');
    }
    if (generation != _generation) return;
    _switchingToLive = false;
    _liveCutover = DateTime.now().subtract(const Duration(seconds: 5));
    _lastAudio = DateTime.now();
    onStoredSyncFinished?.call();
    notifyListeners();
  }

  void _receive(List<int> data) {
    if (!recording) return;
    packets++;
    List<List<int>> encoded;
    List<PendantPage> pages = [];
    try {
      // Firmware also sends bare status/clock notifications. Count these
      // separately; they are not failed Opus audio frames.
      final fields = readProto(data);
      _observeControl(data);
      if (!fields.any((f) => f.number == 3 && f.value is int) ||
          !fields.any((f) => f.number == 4 && f.value is List<int>)) {
        final payload = protoValue(fields, 4);
        if (payload is List<int>) _observeControl(payload);
        controlPackets++;
        return;
      }
      final message = _protocol.receive(data);
      if (message == null) return;
      _observeControl(message.payload);
      pages = LimitlessProtocol.pages(message.payload);
      if (_switchingToLive) return;
      if (syncingStored) {
        for (final page in pages) {
          _queueStored(page);
        }
        return;
      }
      // Late batch notifications must not be appended to today's live WAV.
      if (_liveCutover != null &&
          pages.any(
            (p) =>
                p.timestampMs != null &&
                p.timestampMs! - (_clockOffset ?? 0) <
                    _liveCutover!.millisecondsSinceEpoch,
          )) {
        return;
      }
      encoded = pages.isEmpty
          ? LimitlessProtocol.opusFrames(message.payload)
          : pages.expand((p) => p.frames).toList();
      if (encoded.isEmpty) controlPackets++;
    } catch (error) {
      protocolErrors++;
      lastPacketError = 'Protocol: $error';
      warning =
          '$protocolErrors malformed Bluetooth messages. Check capture details.';
      notifyListeners();
      return;
    }
    final priorErrors = decodeErrors;
    for (final frame in encoded) {
      try {
        final pcm = _decoder!.decode(input: Uint8List.fromList(frame));
        final bytes = Uint8List(pcm.length * 2);
        final view = ByteData.sublistView(bytes);
        for (var i = 0; i < pcm.length; i++) {
          view.setInt16(i * 2, pcm[i], Endian.little);
        }
        unawaited(
          writer.write(bytes).catchError((Object e) {
            _liveWriteFailed = true;
            _problem('Audio could not be saved: $e');
          }),
        );
        frames++;
        _lastAudio = DateTime.now();
      } catch (error) {
        decodeErrors++;
        errors++;
        lastPacketError = 'Opus (${frame.length} bytes): $error';
        warning =
            '$decodeErrors Opus frames could not be decoded; audio may have gaps.';
      }
    }
    if (encoded.isNotEmpty && decodeErrors == priorErrors) {
      _livePageKeys.addAll(pages.map((p) => p.key(deviceId!)));
      _liveRecordedAt ??= DateTime.now().toUtc().toIso8601String();
    }
    if (_protocol.droppedMessages > 0) {
      warning =
          '${_protocol.droppedMessages} incomplete Bluetooth messages; audio may have gaps.';
    }
    status = 'Receiving audio · $frames frames';
    if (frames % 25 == 0 || decodeErrors > 0) notifyListeners();
  }

  Future<double> stop() async {
    ++_generation;
    syncingStored = false;
    _batchEpoch++;
    if (_storageReply != null && !_storageReply!.isCompleted) {
      _storageReply!.complete(null);
    }
    _health?.cancel();
    _health = null;
    if (recording && deviceId != null) {
      try {
        await _command(
          _protocol.stream(false),
        ).timeout(const Duration(seconds: 2));
      } catch (_) {
        /* Device already gone. */
      }
    }
    recording = false;
    connected = false;
    await _rx?.cancel();
    _rx = null;
    await _connection?.cancel();
    _connection = null;
    final saved = await writer.rotate(null);
    _decoder?.destroy();
    _decoder = null;
    status = 'Stopped · ${(saved?.seconds ?? 0).toStringAsFixed(0)}s saved';
    notifyListeners();
    return saved?.seconds ?? 0;
  }
}
