import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the native macOS window (unified title bar drag, zoom, full
/// screen, key state and accent color). No-ops on the other platforms.
class WindowBridge {
  WindowBridge._() {
    if (Platform.isMacOS) {
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'fullScreen':
            fullScreen.value = call.arguments == true;
          case 'windowKey':
            isKey.value = call.arguments == true;
          case 'accentColor':
            if (call.arguments case final int argb) accentColor.value = Color(argb);
        }
      });
      _channel
          .invokeMethod<bool>('isFullScreen')
          .then((v) => fullScreen.value = v ?? false)
          .catchError((Object _) => false);
      _channel
          .invokeMethod<bool>('isKeyWindow')
          .then((v) => isKey.value = v ?? true)
          .catchError((Object _) => true);
      _channel
          .invokeMethod<int>('accentColor')
          .then((v) => accentColor.value = v == null ? null : Color(v))
          .catchError((Object _) => null);
    }
  }

  static final instance = WindowBridge._();
  static const _channel = MethodChannel('dbcraft/window');

  final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  /// Whether the window is key (has keyboard focus at the app level).
  final ValueNotifier<bool> isKey = ValueNotifier(true);

  /// The system accent color, or null for the default blue.
  final ValueNotifier<Color?> accentColor = ValueNotifier(null);

  void startDrag() {
    if (Platform.isMacOS) _channel.invokeMethod('startDrag').catchError((_) {});
  }

  void titleBarDoubleClick() {
    if (Platform.isMacOS) _channel.invokeMethod('titleBarDoubleClick').catchError((_) {});
  }
}
