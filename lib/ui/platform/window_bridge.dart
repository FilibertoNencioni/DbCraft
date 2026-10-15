import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the native macOS window (unified title bar drag, zoom,
/// full screen state). No-ops on the other platforms.
class WindowBridge {
  WindowBridge._() {
    if (Platform.isMacOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'fullScreen') fullScreen.value = call.arguments == true;
      });
      _channel
          .invokeMethod<bool>('isFullScreen')
          .then((v) => fullScreen.value = v ?? false)
          .catchError((Object _) => false);
    }
  }

  static final instance = WindowBridge._();
  static const _channel = MethodChannel('dbcraft/window');

  final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  void startDrag() {
    if (Platform.isMacOS) _channel.invokeMethod('startDrag').catchError((_) {});
  }

  void titleBarDoubleClick() {
    if (Platform.isMacOS) _channel.invokeMethod('titleBarDoubleClick').catchError((_) {});
  }
}
