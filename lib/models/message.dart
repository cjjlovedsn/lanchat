enum MsgKind { text, file }

/// outgoing: pending → sending → delivered / refused ; incoming: received
enum SendState { pending, sending, delivered, refused, received }

class ChatMessage {
  final String id;
  final bool outgoing;
  final MsgKind kind;
  final String? text;
  final String? fileName;
  final int fileSize;
  final String? filePath;
  final String? sha256;
  final DateTime ts;
  final SendState state;

  const ChatMessage({
    required this.id,
    required this.outgoing,
    required this.kind,
    required this.ts,
    required this.state,
    this.text,
    this.fileName,
    this.fileSize = 0,
    this.filePath,
    this.sha256,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'out': outgoing,
        'kind': kind.name,
        'text': text,
        'name': fileName,
        'size': fileSize,
        'path': filePath,
        'sha': sha256,
        'ts': ts.toIso8601String(),
        'state': state.name,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        outgoing: j['out'] as bool? ?? false,
        kind: j['kind'] == 'file' ? MsgKind.file : MsgKind.text,
        text: j['text'] as String?,
        fileName: j['name'] as String?,
        fileSize: j['size'] as int? ?? 0,
        filePath: j['path'] as String?,
        sha256: j['sha'] as String?,
        ts: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.now(),
        state: SendState.values.firstWhere(
          (s) => s.name == j['state'],
          orElse: () => SendState.delivered,
        ),
      );
}
