import 'dart:convert';

/// A private, revocable capability delivered through the existing chat outbox.
class FolderInvite {
  static const prefix = 'LanChat 共享文件夹（需要新版客户端）\n[lanchat-folder-v1]';
  final String id;
  final String token;
  final String name;
  const FolderInvite({
    required this.id,
    required this.token,
    required this.name,
  });

  Map<String, dynamic> toJson() => {'id': id, 'token': token, 'name': name};
  String encode() => prefix + jsonEncode(toJson());

  static FolderInvite? parse(String? text) {
    if (text == null || !text.startsWith(prefix)) return null;
    try {
      final json = jsonDecode(text.substring(prefix.length)) as Map;
      final id = json['id'] as String;
      final token = json['token'] as String;
      final name = json['name'] as String;
      if (id.isEmpty || token.length < 32 || name.isEmpty || name.length > 255) {
        return null;
      }
      return FolderInvite(id: id, token: token, name: name);
    } catch (_) {
      return null;
    }
  }
}

class FolderGrant {
  final FolderInvite invite;
  final String peerId;
  final String root;
  final bool writable;
  const FolderGrant({
    required this.invite,
    required this.peerId,
    required this.root,
    this.writable = false,
  });

  FolderGrant withWritable(bool value) =>
      FolderGrant(invite: invite, peerId: peerId, root: root, writable: value);
  Map<String, dynamic> toJson() => {
    ...invite.toJson(),
    'peerId': peerId,
    'root': root,
    'writable': writable,
  };
}

class FolderEntry {
  final String name;
  final bool directory;
  final int size;
  const FolderEntry({
    required this.name,
    required this.directory,
    this.size = 0,
  });
  Map<String, dynamic> toJson() => {
    'name': name,
    'directory': directory,
    'size': size,
  };
  factory FolderEntry.fromJson(Map<String, dynamic> json) => FolderEntry(
    name: json['name'] as String,
    directory: json['directory'] == true,
    size: json['size'] as int? ?? 0,
  );
}

class FolderListing {
  final List<FolderEntry> entries;
  final bool writable;
  const FolderListing(this.entries, this.writable);
}
