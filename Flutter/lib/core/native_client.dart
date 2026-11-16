import 'package:flutter/services.dart';

typedef JsonMap = Map<String, dynamic>;

JsonMap jsonMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};
List<JsonMap> jsonItems(Object? value) =>
    value is List ? value.map(jsonMap).toList(growable: false) : const [];
String stringValue(Object? value, [String fallback = '']) =>
    value?.toString() ?? fallback;
int intValue(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
double numberValue(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;

class NativeFailure implements Exception {
  const NativeFailure(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Credentials and network routing stay in the native service.
class NativeClient {
  NativeClient({MethodChannel? methods, EventChannel? events})
    : methods = methods ?? const MethodChannel('cc.seekdesk/native.methods.v1'),
      events = events ?? const EventChannel('cc.seekdesk/native.events.v1');

  final MethodChannel methods;
  final EventChannel events;
  int accessRevision = 0;

  Stream<JsonMap> get snapshots => events.receiveBroadcastStream().map(jsonMap);

  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    try {
      final result = await methods.invokeMethod<Object?>(method, {
        ...arguments,
        'accessRevision': accessRevision,
      });
      return jsonMap(result);
    } on MissingPluginException {
      throw const NativeFailure('unavailable', '本机服务尚未连接，请重新启动 SeekDesk。');
    } on PlatformException catch (error) {
      throw NativeFailure(error.code, error.message ?? '操作未完成，请稍后重试。');
    }
  }
}
