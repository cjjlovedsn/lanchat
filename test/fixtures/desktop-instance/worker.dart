import 'dart:convert';
import 'dart:io';

import 'package:lanchat/core/desktop_instance.dart';

Future<void> main(List<String> arguments) async {
  final instance = await DesktopInstance.acquire(
    Directory(arguments.single),
    onActivate: () async {
      stdout.writeln('ACTIVATED');
    },
  );
  if (instance == null) {
    stdout.writeln('SECONDARY');
    exit(0);
  }
  stdout.writeln('PRIMARY');
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'quit') {
      await instance.close();
      exit(0);
    }
  }
  await instance.close();
}
