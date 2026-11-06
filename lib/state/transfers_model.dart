import 'package:flutter/foundation.dart';

/// Transfer progress by msgId (outgoing sends).
/// Notifications throttled to ~2% steps so a fast LAN stream doesn't spam rebuilds.
class TransfersModel extends ChangeNotifier {
  final Map<String, double> _progress = {};
  final Map<String, double> _lastNotify = {};

  double? of(String msgId) => _progress[msgId];

  void update(String msgId, double frac) {
    final v = frac.clamp(0.0, 1.0).toDouble();
    _progress[msgId] = v;
    final last = _lastNotify[msgId] ?? -1.0;
    if (v - last >= 0.02 || v >= 1.0) {
      _lastNotify[msgId] = v;
      notifyListeners();
    }
  }

  void remove(String msgId) {
    if (_progress.remove(msgId) != null) {
      _lastNotify.remove(msgId);
      notifyListeners();
    }
  }
}
