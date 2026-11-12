import 'dart:io';

import 'package:flutter/services.dart';

/// Android scoped-storage gate for writing to public directories.
/// Desktop platforms are always "granted".
class StoragePerm {
  static const _channel = MethodChannel('lanchat/storage');

  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isGranted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "All files access" screen for this app.
  static Future<void> request() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('request');
    } catch (_) {}
  }
}
