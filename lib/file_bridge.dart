import 'package:flutter/services.dart';

/// Representa um item (arquivo ou pasta) dentro da árvore escolhida pelo usuário.
class FileEntry {
  final String uri;
  final String name;
  final bool isDirectory;

  FileEntry({required this.uri, required this.name, required this.isDirectory});

  factory FileEntry.fromMap(Map<dynamic, dynamic> map) {
    return FileEntry(
      uri: map['uri'] as String,
      name: map['name'] as String,
      isDirectory: map['isDirectory'] as bool,
    );
  }

  @override
  String toString() => '${isDirectory ? "📁" : "📄"} $name';
}

/// Ponte para as operações reais de arquivo, implementadas em Kotlin via SAF
/// (Storage Access Framework). Todas as operações acontecem só dentro da
/// pasta que o usuário autorizou explicitamente pelo seletor do sistema.
class FileBridge {
  static const _channel = MethodChannel('voice_file_ai/files');

  /// Abre o seletor de pastas do Android. Retorna a URI da árvore escolhida,
  /// ou null se o usuário cancelar.
  static Future<String?> pickFolder() async {
    final result = await _channel.invokeMethod<String>('pickFolder');
    return result;
  }

  /// Lista os arquivos/pastas dentro da árvore autorizada (não recursivo).
  static Future<List<FileEntry>> listFiles(String treeUri) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'listFiles',
      {'treeUri': treeUri},
    );
    if (result == null) return [];
    return result
        .cast<Map<dynamic, dynamic>>()
        .map((m) => FileEntry.fromMap(m))
        .toList();
  }

  /// Move (ou copia+apaga, se necessário) um arquivo para outra pasta dentro
  /// da mesma árvore.
  static Future<bool> moveFile({
    required String sourceUri,
    required String destTreeUri,
  }) async {
    final result = await _channel.invokeMethod<bool>('moveFile', {
      'sourceUri': sourceUri,
      'destTreeUri': destTreeUri,
    });
    return result ?? false;
  }

  static Future<bool> renameFile({
    required String uri,
    required String newName,
  }) async {
    final result = await _channel.invokeMethod<bool>('renameFile', {
      'uri': uri,
      'newName': newName,
    });
    return result ?? false;
  }

  static Future<bool> deleteFile(String uri) async {
    final result = await _channel.invokeMethod<bool>('deleteFile', {
      'uri': uri,
    });
    return result ?? false;
  }

  static Future<String?> readFile(String uri) async {
    final result = await _channel.invokeMethod<String>('readFile', {
      'uri': uri,
    });
    return result;
  }

  static Future<bool> writeFile({
    required String uri,
    required String content,
  }) async {
    final result = await _channel.invokeMethod<bool>('writeFile', {
      'uri': uri,
      'content': content,
    });
    return result ?? false;
  }

  /// Cria uma pasta nova dentro de outra pasta. Retorna a URI da pasta
  /// criada, ou null se falhar (ex.: já existe algo com esse nome ali).
  static Future<String?> createFolder({
    required String parentTreeUri,
    required String name,
  }) async {
    final result = await _channel.invokeMethod<String>('createFolder', {
      'parentTreeUri': parentTreeUri,
      'name': name,
    });
    return result;
  }

  /// Cria um arquivo novo dentro de uma pasta (árvore) com um nome e
  /// conteúdo inicial. Retorna a URI do arquivo criado, ou null se falhar.
  static Future<String?> createFile({
    required String parentTreeUri,
    required String name,
    required String content,
  }) async {
    final result = await _channel.invokeMethod<String>('createFile', {
      'parentTreeUri': parentTreeUri,
      'name': name,
      'content': content,
    });
    return result;
  }
}
