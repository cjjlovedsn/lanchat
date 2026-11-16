import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanchat/core/message_text.dart';
import 'package:lanchat/ui/widgets/message_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/models/message.dart';
import 'package:lanchat/ui/widgets/bubble.dart';

// 1x1 transparent PNG
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('image file renders inline thumbnail', (tester) async {
    final tmp = File(
      '${Directory.systemTemp.path}/lanchat_bubble_test_${DateTime.now().millisecondsSinceEpoch}.png',
    )..writeAsBytesSync(_png);
    addTearDown(() => tmp.deleteSync());

    await tester.pumpWidget(
      _wrap(MessageBubble(msg: _fileMsg('pic.png', tmp.path))),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.text('pic.png'),
      findsNothing,
    ); // name row replaced by thumbnail
  });

  testWidgets('cleaned-up received file shows hint', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          msg: _fileMsg('doc.pdf', '/nonexistent/lanchat-test/doc.pdf'),
        ),
      ),
    );
    expect(find.text('文件已被清理或移动'), findsOneWidget);
    expect(find.text('doc.pdf'), findsOneWidget);
  });

  testWidgets('copy code keeps exact whitespace and excludes transport fence', (
    tester,
  ) async {
    const code = '  if (ready) {\n    run();\n  }\n\n';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _wrap(MessageText(text: encodeCode(code), color: Colors.black)),
    );
    await tester.tap(find.byTooltip('复制代码'));
    await tester.pump();
    expect(copied, code);
  });

  testWidgets('normal messages expose selectable clickable links', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const MessageText(
          text: '打开 http://192.168.1.20:8080/path。',
          color: Colors.black,
        ),
      ),
    );
    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    final links = selectable.textSpan!.children!.whereType<TextSpan>().where(
      (span) => span.recognizer != null,
    );
    expect(links.single.text, 'http://192.168.1.20:8080/path');
  });

  testWidgets('video card shows play hint', (tester) async {
    final tmp = File(
      '${Directory.systemTemp.path}/lanchat_bubble_test_${DateTime.now().millisecondsSinceEpoch}.mp4',
    )..writeAsBytesSync(List.filled(8, 0));
    addTearDown(() => tmp.deleteSync());

    await tester.pumpWidget(
      _wrap(MessageBubble(msg: _fileMsg('clip.mp4', tmp.path))),
    );
    expect(find.textContaining('点击播放'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });
}
