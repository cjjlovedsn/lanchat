import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Only one temporary decoder runs at once. Cache a bounded set of compressed
/// frames so rebuilding the chat never creates a player per video bubble.
class VideoPosters {
  static bool enabled = false;
  static Future<void> _tail = Future.value();
  static final _cache = <String, Future<Uint8List?>>{};

  static Future<Uint8List?> load(String path) async {
    if (!enabled) return null;
    final stat = await File(path).stat();
    final key = '$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    if (_cache.containsKey(key)) return _cache[key];
    if (_cache.length >= 24) _cache.remove(_cache.keys.first);
    final future = _tail.then((_) => _capture(path));
    _cache[key] = future;
    _tail = future.then((_) {});
    return future;
  }

  static Future<Uint8List?> _capture(String path) async {
    Player? player;
    try {
      player = Player();
      final controller = VideoController(player);
      await controller
          .setSize(width: 480, height: 270)
          .timeout(const Duration(seconds: 5));
      await player.setVolume(0);
      await player
          .open(Media(path), play: false)
          .timeout(const Duration(seconds: 5));
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 5),
      );
      return await player.screenshot().timeout(const Duration(seconds: 5));
    } catch (_) {
      return null; // The play button remains available for unsupported files.
    } finally {
      try {
        await player?.dispose();
      } catch (_) {}
    }
  }
}

class VideoPoster extends StatefulWidget {
  final String path;
  const VideoPoster({super.key, required this.path});

  @override
  State<VideoPoster> createState() => _VideoPosterState();
}

class _VideoPosterState extends State<VideoPoster> {
  late Future<Uint8List?> _frame;

  @override
  void initState() {
    super.initState();
    _frame = VideoPosters.load(widget.path);
  }

  @override
  void didUpdateWidget(covariant VideoPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _frame = VideoPosters.load(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 260,
        height: 146,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black87),
            FutureBuilder<Uint8List?>(
              future: _frame,
              builder: (context, snapshot) => snapshot.data == null
                  ? const SizedBox.shrink()
                  : Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                      cacheWidth: 520,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
            ),
            const Center(
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 52,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
