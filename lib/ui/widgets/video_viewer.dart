import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/util.dart';

Future<void> showVideoViewer(BuildContext context, String path, String name) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _VideoViewer(path: path, name: name),
    ),
  );
}

class _VideoViewer extends StatefulWidget {
  final String path;
  final String name;
  const _VideoViewer({required this.path, required this.name});

  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errors;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final player = Player();
      _player = player;
      _controller = VideoController(player);
      _errors = player.stream.error.listen((message) {
        if (mounted) setState(() => _error = message);
      });
      await player.open(Media(widget.path));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _errors?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _openExternal() async {
    await _player?.pause();
    final ok = await openDirect(widget.path);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开系统播放器，请检查文件或默认应用')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: '用系统播放器打开',
            onPressed: _openExternal,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '此视频暂时无法在应用内播放',
                      style: TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _openExternal,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('用系统播放器打开'),
                    ),
                  ],
                ),
              ),
            )
          : _controller == null
          ? const Center(child: CircularProgressIndicator())
          : Video(controller: _controller!),
    );
  }
}
