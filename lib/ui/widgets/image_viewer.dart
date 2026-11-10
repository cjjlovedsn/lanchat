import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/util.dart';

/// Fullscreen image viewer with pinch zoom.
class ImageViewer extends StatelessWidget {
  final String path;
  const ImageViewer({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '打开所在位置',
            icon: const Icon(Icons.folder_open),
            onPressed: () => openOrReveal(path),
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.file(File(path), fit: BoxFit.contain),
        ),
      ),
    );
  }
}

void showImageViewer(BuildContext context, String path) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ImageViewer(path: path),
    ),
  );
}
