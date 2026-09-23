import 'package:flutter/services.dart';

/// Representa um item (arquivo ou pasta) dentro da árvore escolhida pelo usuário.
class FileEntry {
  final String uri;
  final String name;
  final bool isDirectory;

  /// Última modificação, em milissegundos desde 1970 (0 se desconhecida).
  /// O Android (SAF) não guarda uma data de criação separada — só a de
  /// última modificação — então é só isso que dá pra mostrar.
  final int lastModified;

  FileEntry({
    required this.uri,
    required this.name,
    required this.isDirectory,
    this.lastModified = 0,
  });

  factory FileEntry.fromMap(Map<dynamic, dynamic> map) {
    return FileEntry(
      uri: map['uri'] as String,
      name: map['name'] as String,
      isDirectory: map['isDirectory'] as bool,
      lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
    );
  }

  /// Data da última modificação no formato AAAA-MM-DD, ou null se não tiver.
  String? get modifiedDateLabel {
    if (lastModified <= 0) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(lastModified);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
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

  /// Lê um arquivo. Sem argumentos extras, lê tudo (comportamento de sempre).
  /// Pra arquivos grandes, dá pra pedir só uma faixa sem carregar o resto:
  /// startLine/endLine em arquivos de texto simples, ou startPage/endPage em
  /// PDFs (não se aplica a .docx).
  static Future<String?> readFile(
    String uri, {
    int? startLine,
    int? endLine,
    int? startPage,
    int? endPage,
  }) async {
    final result = await _channel.invokeMethod<String>('readFile', {
      'uri': uri,
      if (startLine != null) 'startLine': startLine,
      if (endLine != null) 'endLine': endLine,
      if (startPage != null) 'startPage': startPage,
      if (endPage != null) 'endPage': endPage,
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

  /// Compara os arquivos de uma pasta com o conteúdo de um backup .zip
  /// (por caminho, tamanho e CRC32 — não só pelo nome). Retorna null se
  /// algo der errado (zip inválido, pasta inacessível, etc.).
  static Future<Map<String, dynamic>?> compareWithZipBackup({
    required String zipUri,
    required String currentTreeUri,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'compareWithZipBackup',
      {'zipUri': zipUri, 'currentTreeUri': currentTreeUri},
    );
    return result;
  }
}
