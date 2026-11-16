import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'store.dart';

/// Reads attachment formats only after the user invokes Paste. File formats
/// take priority over an image thumbnail or a filename in the text flavor.
class ClipboardAttachments {
  static const _native = MethodChannel('lanchat/clipboard');

  static Future<List<String>> read(AppStore store) async {
    final files =
        (Platform.isMacOS
                ? await _native.invokeListMethod<String>('files') ?? <String>[]
                : await Pasteboard.files())
            .toSet()
            .toList();
    if (files.isNotEmpty) return importFiles(store, files);
    final image = await Pasteboard.image;
    if (image == null || image.isEmpty) return [];
    return [await saveImage(store, image)];
  }

  static Future<List<String>> importFiles(
    AppStore store,
    List<String> paths,
  ) async {
    if (Platform.isAndroid) {
      final copied = await _native.invokeListMethod<String>('import', paths);
      paths = copied ?? [];
      // The content resolver produces cache files; retain originals for the
      // sender's image preview even after delivery removes the outbox blob.
      final result = <String>[];
      for (final path in paths) {
        final dir = _directory(store);
        final copy = await File(path).copy(p.join(dir.path, p.basename(path)));
        result.add(copy.path);
      }
      return result;
    }
    final result = <String>[];
    for (final path in paths) {
      final normalized = path.startsWith('file:')
          ? Uri.parse(path).toFilePath()
          : path;
      if (!await File(normalized).exists()) {
        throw const FileSystemException('剪贴板包含不可读取的文件或文件夹');
      }
      result.add(normalized);
    }
    return result;
  }

  static Directory _directory(AppStore store) =>
      Directory(p.join(store.base.path, 'clipboard', const Uuid().v4()))
        ..createSync(recursive: true);

  static Future<String> saveImage(AppStore store, Uint8List bytes) async {
    // Pasteboard returns PNG on desktop; Android may preserve JPEG/GIF/WebP.
    final extension = bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8
        ? 'jpg'
        : bytes.length >= 6 && String.fromCharCodes(bytes.take(3)) == 'GIF'
        ? 'gif'
        : bytes.length >= 12 &&
              String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP'
        ? 'webp'
        : 'png';
    final file = File(
      p.join(
        _directory(store).path,
        '粘贴的图片-${DateTime.now().millisecondsSinceEpoch}.$extension',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
