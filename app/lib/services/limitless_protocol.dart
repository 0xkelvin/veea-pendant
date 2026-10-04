// Protocol derived from BasedHardware/omi (MIT). See THIRD_PARTY_NOTICES.md.
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';

Object? protoValue(List<ProtoField> fields, int n) =>
    fields.where((f) => f.number == n).firstOrNull?.value;

class PendantStorageState {
  PendantStorageState(this.oldest, this.newest, this.session);
  final int oldest, newest, session;
  bool get hasPages => oldest >= 0 && newest >= oldest;
}

class PendantPage {
  PendantPage(this.index, this.session, this.data);
  final int index, session;
  final List<int> data;
  int? get timestampMs {
    final value = protoValue(readProto(data), 1);
    return value is int && value > 1577836800000 ? value : null;
  }

  String key(String device) => sha256.convert([
    ...utf8.encode('$device:$session:$index:'),
    ...data,
  ]).toString();
  List<List<int>> get frames {
    final result = <List<int>>[];
    for (final chunk in readProto(
      data,
    ).where((f) => f.number == 3 && f.value is List<int>)) {
      for (final audio in readProto(
        chunk.value as List<int>,
      ).where((f) => f.number == 2 && f.value is List<int>)) {
        final extracted = LimitlessProtocol.opusFrames(
          audio.value as List<int>,
        );
        if (extracted.isEmpty &&
            readProto(audio.value as List<int>).any(
              (f) => f.value is List<int> && (f.value as List<int>).isNotEmpty,
            )) {
          throw const FormatException(
            'Audio page contains no recognized Opus frames',
          );
        }
        result.addAll(extracted);
      }
    }
    return result;
  }
}

/// ACKs are cumulative. A later page must never acknowledge a missing page.
class PendantPageWatermark {
  PendantPageWatermark(int oldest) : committed = oldest - 1;
  int committed;
  final _saved = <int>{};
  int save(int index) {
    if (index > committed) _saved.add(index);
    while (_saved.remove(committed + 1)) {
      committed++;
    }
    return committed;
  }
}

class ProtoField {
  ProtoField(this.number, this.value);
  final int number;
  final Object value;
}

List<int> varint(int value) {
  if (value < 0) throw const FormatException('Negative varint');
  final bytes = <int>[];
  do {
    bytes.add((value & 127) | (value > 127 ? 128 : 0));
    value >>= 7;
  } while (value != 0);
  return bytes;
}

List<int> intField(int field, int value) => [
  ...varint(field << 3),
  ...varint(value),
];
List<int> bytesField(int field, List<int> value) => [
  ...varint((field << 3) | 2),
  ...varint(value.length),
  ...value,
];

List<ProtoField> readProto(List<int> bytes) {
  var offset = 0;
  int readInt() {
    var result = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      if (offset >= bytes.length) {
        throw const FormatException('Truncated varint');
      }
      final b = bytes[offset++];
      if (shift == 63 && b > 1) throw const FormatException('Oversized varint');
      result |= (b & 127) << shift;
      if (b < 128) return result;
    }
    throw const FormatException('Oversized varint');
  }

  final fields = <ProtoField>[];
  while (offset < bytes.length) {
    final tag = readInt(), field = tag >> 3, wire = tag & 7;
    if (field == 0) throw const FormatException('Invalid field');
    if (wire == 0) {
      fields.add(ProtoField(field, readInt()));
    } else if (wire == 2) {
      final count = readInt();
      if (count < 0 || count > bytes.length - offset) {
        throw const FormatException('Truncated field');
      }
      fields.add(ProtoField(field, bytes.sublist(offset, offset + count)));
      offset += count;
    } else if (wire == 1 || wire == 5) {
      offset += wire == 1 ? 8 : 4;
      if (offset > bytes.length) {
        throw const FormatException('Truncated fixed field');
      }
    } else {
      throw const FormatException('Unsupported wire type');
    }
  }
  return fields;
}

class PendantMessage {
  PendantMessage(this.index, this.payload);
  final int index;
  final List<int> payload;
}

class LimitlessProtocol {
  static const service = '632de001-604c-446b-a80f-7963e950f3fb';
  static const tx = '632de002-604c-446b-a80f-7963e950f3fb';
  static const rx = '632de003-604c-446b-a80f-7963e950f3fb';
  int _index = 0, _request = 0;
  final _fragments = <int, Map<int, List<int>>>{};
  final _counts = <int, int>{};
  final _completed = Queue<int>();
  int droppedMessages = 0;

  List<int> _command(int type, List<int> data) => [
    ...intField(1, _index++),
    ...intField(2, 0),
    ...intField(3, 1),
    ...bytesField(4, [
      ...bytesField(type, data),
      ...bytesField(30, [...intField(1, ++_request), ...intField(2, 0)]),
    ]),
  ];
  List<int> setTime(int ms) => _command(6, intField(1, ms));
  List<int> stream(bool enabled) =>
      _command(8, [...intField(1, 0), ...intField(2, enabled ? 1 : 0)]);
  List<int> storageStatus() => _command(21, []);
  List<int> downloadStored() =>
      _command(8, [...intField(1, 1), ...intField(2, 0)]);
  List<int> acknowledgeSaved(int index) => _command(7, intField(1, index));

  static List<PendantPage> pages(List<int> payload) {
    final pages = <PendantPage>[];
    for (final f in readProto(payload)) {
      if (f.number != 2 || f.value is! List<int>) continue;
      final fields = readProto(f.value as List<int>);
      final index = protoValue(fields, 5),
          session = protoValue(fields, 2),
          data = protoValue(fields, 6);
      if (data is! List<int>) continue;
      if (index is! int || index < 0 || session is! int || session < 0) {
        throw const FormatException('Stored page is missing its identity');
      }
      pages.add(PendantPage(index, session, data));
    }
    return pages;
  }

  static PendantStorageState? storage(List<int> payload) {
    for (final status in readProto(
      payload,
    ).where((f) => f.number == 5 && f.value is List<int>)) {
      for (final state in readProto(
        status.value as List<int>,
      ).where((f) => f.number == 5 && f.value is List<int>)) {
        final fields = readProto(state.value as List<int>);
        final oldest = protoValue(fields, 1) ?? 0,
            newest = protoValue(fields, 2) ?? 0,
            session = protoValue(fields, 3) ?? 0;
        if (oldest is int && newest is int && session is int) {
          return PendantStorageState(oldest, newest, session);
        }
      }
    }
    return null;
  }

  static int? clockEpoch(List<int> payload) {
    final fields = readProto(payload);
    int? epoch(Object? v) => v is int && v > 1577836800000 ? v : null;
    if (protoValue(fields, 1) == 8) return epoch(protoValue(fields, 6));
    final inner = protoValue(fields, 8);
    if (inner is List<int>) {
      final value = protoValue(readProto(inner), 6);
      if (value is List<int>) return epoch(protoValue(readProto(value), 1));
      return epoch(value);
    }
    return null;
  }

  PendantMessage? receive(List<int> bytes) {
    final fields = readProto(bytes);
    Object? get(int n) => fields.where((f) => f.number == n).firstOrNull?.value;
    final index = get(1), seq = get(2) ?? 0, count = get(3), payload = get(4);
    if (index is! int ||
        seq is! int ||
        count is! int ||
        payload is! List<int> ||
        count < 1 ||
        count > 128 ||
        seq < 0 ||
        seq >= count) {
      throw FormatException(
        'Invalid BLE envelope (index=$index, sequence=$seq, fragments=$count, payload=${payload is List<int> ? payload.length : 'missing'})',
      );
    }
    if (_completed.contains(index)) return null;
    if (_counts[index] != null && _counts[index] != count) {
      _fragments.remove(index);
      _counts.remove(index);
      droppedMessages++;
      throw const FormatException('Inconsistent fragment count');
    }
    if (!_fragments.containsKey(index) && _fragments.length >= 32) {
      final stale = _fragments.keys.first;
      _fragments.remove(stale);
      _counts.remove(stale);
      droppedMessages++;
    }
    _counts[index] = count;
    final parts = _fragments.putIfAbsent(index, () => {});
    parts[seq] = payload;
    if (parts.length != count) return null;
    final merged = <int>[for (var i = 0; i < count; i++) ...parts[i]!];
    _fragments.remove(index);
    _counts.remove(index);
    _completed.add(index);
    if (_completed.length > 128) _completed.removeFirst();
    return PendantMessage(index, merged);
  }

  /// Walk protobuf boundaries rather than scanning arbitrary encoded audio bytes.
  static List<List<int>> opusFrames(List<int> payload, [int depth = 0]) {
    if (depth > 8) return [];
    final frames = <List<int>>[];
    const toc = {0xb8, 0x78, 0xf8, 0xb0, 0x70, 0xf0};
    for (final f in readProto(payload)) {
      if (f.value is! List<int>) continue;
      final data = f.value as List<int>;
      if (f.number == 4 &&
          data.isNotEmpty &&
          data.length <= 1275 &&
          toc.contains(data.first)) {
        frames.add(data);
      } else {
        try {
          frames.addAll(opusFrames(data, depth + 1));
        } on FormatException {
          /* Non-audio binary field. */
        }
      }
    }
    return frames;
  }
}
