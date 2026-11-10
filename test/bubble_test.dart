import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/models/message.dart';
import 'package:lanchat/ui/widgets/bubble.dart';

// 1x1 transparent PNG
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

ChatMessage _fileMsg(String name, String? path) => ChatMessage(
      id: 'm1',
      outgoing: false,
      kind: MsgKind.file,
      fileName: name,
      fileSize: 100,
      filePath: path,
      ts: DateTime(2026, 1, 1, 12, 0),
      state: SendState.received,
    );

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('image file renders inline thumbnail', (tester) async {
    final tmp = File(
        '${Directory.systemTemp.path}/lanchat_bubble_test_${DateTime.now().millisecondsSinceEpoch}.png')
      ..writeAsBytesSync(_png);
    addTearDown(() => tmp.deleteSync());

    await tester.pumpWidget(_wrap(MessageBubble(msg: _fileMsg('pic.png', tmp.path))));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('pic.png'), findsNothing); // name row replaced by thumbnail
  });

  testWidgets('cleaned-up received file shows hint', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
        msg: _fileMsg('doc.pdf', '/nonexistent/lanchat-test/doc.pdf'))));
    expect(find.text('文件已被清理或移动'), findsOneWidget);
    expect(find.text('doc.pdf'), findsOneWidget);
  });

  testWidgets('video card shows play hint', (tester) async {
    final tmp = File(
        '${Directory.systemTemp.path}/lanchat_bubble_test_${DateTime.now().millisecondsSinceEpoch}.mp4')
      ..writeAsBytesSync(List.filled(8, 0));
    addTearDown(() => tmp.deleteSync());

    await tester.pumpWidget(_wrap(MessageBubble(msg: _fileMsg('clip.mp4', tmp.path))));
    expect(find.textContaining('点击播放'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });
}
