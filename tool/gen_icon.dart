// Generates assets/tray_icon.png + assets/tray_icon.ico (dev tool, not shipped).
// Run: dart run tool/gen_icon.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int size = 32;
const List<int> bg = [0x4A, 0x6B, 0xEB]; // #4A6BEB
const List<int> fg = [0xFF, 0xFF, 0xFF];

Uint8List renderRgba() {
  final px = Uint8List(size * size * 4);
  final half = size / 2;
  final corner = 9.0;
  final ringOuter = size * 0.30;
  final ringInner = size * 0.16;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final cx = x + 0.5, cy = y + 0.5;
      final dx = (cx - half).abs() - (half - corner);
      final dy = (cy - half).abs() - (half - corner);
      final sqDist = math.max(dx, 0) * math.max(dx, 0) + math.max(dy, 0) * math.max(dy, 0);
      final sqEdge = math.sqrt(sqDist);

      var color = bg;
      final ringD = math.sqrt((cx - half) * (cx - half) + (cy - half) * (cy - half));
      if (ringD <= ringOuter && ringD >= ringInner - 1.2) color = fg;

      var alpha = 0;
      if (sqEdge <= corner - 0.6) {
        alpha = 255;
      } else if (sqEdge < corner + 0.6) {
        alpha = 128; // crude AA
      }
      final i = (y * size + x) * 4;
      px[i] = color[0];
      px[i + 1] = color[1];
      px[i + 2] = color[2];
      px[i + 3] = alpha;
    }
  }
  return px;
}

// ---- minimal PNG encoder ----
final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _chunk(String type, Uint8List data) {
  final out = BytesBuilder();
  final typeBytes = type.codeUnits;
  final len = Uint8List(4)
    ..buffer.asByteData().setUint32(0, data.length, Endian.big);
  out.add(len);
  out.add(typeBytes);
  out.add(data);
  final crcInput = Uint8List.fromList([...typeBytes, ...data]);
  final crc = Uint8List(4)..buffer.asByteData().setUint32(0, _crc32(crcInput), Endian.big);
  out.add(crc);
  return out.toBytes();
}

Uint8List encodePng(Uint8List rgba, int w, int h) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.add([0]); // filter: none
    raw.add(Uint8List.sublistView(rgba, y * w * 4, (y + 1) * w * 4));
  }
  final idat = Uint8List.fromList(ZLibCodec(level: 9).encode(raw.toBytes()));

  final ihdr = Uint8List(13);
  final bd = ihdr.buffer.asByteData();
  bd.setUint32(0, w, Endian.big);
  bd.setUint32(4, h, Endian.big);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA

  final png = BytesBuilder();
  png.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  png.add(_chunk('IHDR', ihdr));
  png.add(_chunk('IDAT', idat));
  png.add(_chunk('IEND', Uint8List(0)));
  return png.toBytes();
}

// ---- ICO with one 32bpp BMP entry ----
Uint8List encodeIcoBmp(Uint8List rgba) {
  final bmpHeader = Uint8List(40);
  final bd = bmpHeader.buffer.asByteData();
  bd.setUint32(0, 40, Endian.little);
  bd.setInt32(4, size, Endian.little);
  bd.setInt32(8, size * 2, Endian.little); // height doubled (XOR+AND)
  bd.setUint16(12, 1, Endian.little); // planes
  bd.setUint16(14, 32, Endian.little); // bpp
  bd.setUint32(20, size * size * 4 + size * 4, Endian.little);

  final pixels = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final src = (y * size + x) * 4;
      final dst = ((size - 1 - y) * size + x) * 4; // bottom-up
      pixels[dst] = rgba[src + 2]; // B
      pixels[dst + 1] = rgba[src + 1]; // G
      pixels[dst + 2] = rgba[src]; // R
      pixels[dst + 3] = rgba[src + 3]; // A
    }
  }
  final andMask = Uint8List(size * 4); // all zero → use alpha channel

  final bmp = BytesBuilder();
  bmp.add(bmpHeader);
  bmp.add(pixels);
  bmp.add(andMask);
  final bmpBytes = bmp.toBytes();

  final ico = BytesBuilder();
  final head = ByteData(22);
  head.setUint16(0, 0, Endian.little); // reserved
  head.setUint16(2, 1, Endian.little); // type: icon
  head.setUint16(4, 1, Endian.little); // count
  head.setUint8(6, size); // width
  head.setUint8(7, size); // height
  head.setUint16(8, 0); // colors
  head.setUint16(10, 1, Endian.little); // planes
  head.setUint16(12, 32, Endian.little); // bpp
  head.setUint32(14, bmpBytes.length, Endian.little);
  head.setUint32(18, 22, Endian.little); // offset
  ico.add(head.buffer.asUint8List());
  ico.add(bmpBytes);
  return ico.toBytes();
}

void main() {
  final dir = Directory('assets');
  if (!dir.existsSync()) dir.createSync();
  final rgba = renderRgba();
  File('assets/tray_icon.png').writeAsBytesSync(encodePng(rgba, size, size));
  File('assets/tray_icon.ico').writeAsBytesSync(encodeIcoBmp(rgba));
  stderr.writeln('icons written to assets/');
}
