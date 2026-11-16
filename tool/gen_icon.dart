// Compatibility entry point for the shared brand asset generator.
// Requires Python 3 and Pillow. Run from the repository root.
import 'dart:io';

void main(List<String> args) {
  try {
    final result = Process.runSync(Platform.isWindows ? 'python' : 'python3', [
      'tool/generate_brand_assets.py',
      ...args,
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    exitCode = result.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln('Install Python 3 and Pillow to generate icons: $error');
    exitCode = 1;
  }
}
