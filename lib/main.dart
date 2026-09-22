import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'api_key_store.dart';
import 'gemini_service.dart';
import 'file_bridge.dart';

void main() => runApp(const VoiceFileAiApp());

class VoiceFileAiApp extends StatelessWidget {
  const VoiceFileAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice File AI',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

enum ChatSender { user, assistant, system }

class ChatMessage {
  final ChatSender sender;
  final String text;
  ChatMessage(this.sender, this.text);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();

  GeminiService? _gemini;
  String? _folderUri;
  List<FileEntry> _folderListing = [];
  bool _isListening = false;
  bool _isBusy = false;
  String _transcript = '';

  /// Segurança contra loop: máximo de ações encadeadas por comando.
  static const int _maxChainedActions = 12;

  /// Extensões que a busca de conteúdo nem tenta abrir (não são texto).
  static const Set<String> _nonSearchableExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico',
    'ogg', 'wav', 'mp3', 'flac', 'ttf', 'otf',
    'zip', 'rar', '7z', 'jar', 'apk', 'aab',
    'exe', 'so', 'dll', 'class',
  };

  static bool _isSearchable(String name) {
    final dot = name.lastIndexOf('.');
    if (dot == -1 || dot == name.length - 1) return true;
    final ext = name.substring(dot + 1).toLowerCase();
    return !_nonSearchableExtensions.contains(ext);
  }

  void _addMessage(ChatSender sender, String text) {
    setState(() => _messages.insert(0, ChatMessage(sender, text)));
  }

  Future<void> _pickFolder() async {
    final uri = await FileBridge.pickFolder();
    if (uri == null) return;
    final isFirstFolder = _folderUri == null;
    setState(() => _folderUri = uri);
    await _refreshListing();
    // A conversa e os ids conhecidos continuam os mesmos — só a pasta que a
    // IA enxerga como "principal" muda. Isso evita a sensação de estar
    // falando com uma IA diferente a cada troca de pasta.
    _addMessage(
      ChatSender.system,
      isFirstFolder
          ? '📂 Pasta selecionada: "${GeminiService.rootNameFromUri(uri)}".'
          : '📂 Pasta principal alterada para "${GeminiService.rootNameFromUri(uri)}".',
    );
  }

  /// Apaga o histórico da conversa (a IA esquece o que foi dito), sem afetar
  /// os arquivos. Diferente de trocar de pasta, isso é sempre uma escolha
  /// explícita do usuário.
  Future<void> _startNewConversation() async {
    if (_messages.isEmpty) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Começar conversa nova?'),
            content: const Text(
                'A IA vai esquecer tudo que foi conversado até agora. Os '
                'arquivos não são afetados.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Começar de novo'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    _gemini?.resetConversation();
    setState(() => _messages.clear());
    _addMessage(ChatSender.system, '🔄 Conversa reiniciada.');
  }

  Future<void> _refreshListing() async {
    if (_folderUri == null) return;
    final listing = await FileBridge.listFiles(_folderUri!);
    setState(() => _folderListing = listing);
  }

  Future<GeminiService?> _ensureGemini() async {
    if (_gemini != null) return _gemini;
    final apiKey = await ApiKeyStore.get();
    if (apiKey == null || apiKey.isEmpty) {
      _addMessage(ChatSender.system, '⚠️ Configure sua chave do Gemini nas configurações (ícone no topo).');
      return null;
    }
    _gemini = GeminiService(apiKey)
      ..onStatus = (message) => _addMessage(ChatSender.system, message);
    return _gemini;
  }

  Future<void> _startListening() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _addMessage(ChatSender.system, '⚠️ Permissão de microfone negada.');
      return;
    }
    final available = await _speech.initialize(
      onError: (e) => _addMessage(ChatSender.system, '⚠️ Erro no reconhecimento de voz: ${e.errorMsg}'),
    );
    if (!available) {
      _addMessage(ChatSender.system, '⚠️ Reconhecimento de voz indisponível neste aparelho.');
      return;
    }
    setState(() {
      _isListening = true;
      _transcript = '';
    });
    _speech.listen(
      localeId: 'pt_BR',
      onResult: (result) {
        setState(() => _transcript = result.recognizedWords);
        if (result.finalResult) {
          _stopListeningAndRun();
        }
      },
    );
  }

  Future<void> _stopListeningAndRun() async {
    await _speech.stop();
    setState(() => _isListening = false);
    if (_transcript.trim().isEmpty) return;
    await _runCommand(_transcript.trim());
  }

  Future<void> _submitTypedCommand() async {
    final command = _textController.text.trim();
    if (command.isEmpty) return;
    _textController.clear();
    FocusScope.of(context).unfocus();
    await _runCommand(command);
  }

  Future<void> _runCommand(String command) async {
    if (_folderUri == null) {
      _addMessage(ChatSender.system, '⚠️ Escolha uma pasta primeiro.');
      return;
    }
    final gemini = await _ensureGemini();
    if (gemini == null) return;

    _addMessage(ChatSender.user, command);
    setState(() => _isBusy = true);

    try {
      var turn = await gemini.sendUserMessage(
        text: command,
        currentFolderUri: _folderUri!,
        currentFolderListing: _folderListing,
      );

      var steps = 0;
      while (true) {
        if (turn.text != null && turn.text!.trim().isNotEmpty) {
          _addMessage(ChatSender.assistant, turn.text!.trim());
        }

        final action = turn.action;
        if (action == null) break;

        steps++;
        if (steps > _maxChainedActions) {
          _addMessage(ChatSender.system, '⚠️ Muitas ações em sequência — parando por segurança.');
          break;
        }

        // Pedido inválido do modelo (id que não existe etc.): devolve o erro
        // pra ele se corrigir, sem incomodar o usuário com confirmação.
        if (action.error != null) {
          turn = await gemini.reportActionResult(
            action: action,
            success: false,
            cancelledByUser: false,
            error: action.error,
            currentFolderUri: _folderUri!,
            currentFolderListing: _folderListing,
          );
          continue;
        }

        final confirmed = action.needsConfirmation ? await _confirmAction(action) : true;
        var outcome = const ActionOutcome.fail();
        if (confirmed) {
          _addMessage(ChatSender.system, '⚙️ ${action.summary}');
          outcome = await _executeAction(gemini, action);
          if (!outcome.success) {
            final failedItems = outcome.data?['falharam'];
            final detail = failedItems is List && failedItems.isNotEmpty
                ? '\nNão deu certo: ${failedItems.join(', ')}'
                : '';
            _addMessage(ChatSender.system,
                '⚠️ ${outcome.error ?? 'Não consegui executar a ação.'}$detail');
          }
          if (!action.isReadOnly) await _refreshListing();
        }

        turn = await gemini.reportActionResult(
          action: action,
          success: confirmed && outcome.success,
          cancelledByUser: !confirmed,
          data: outcome.data,
          error: outcome.error,
          currentFolderUri: _folderUri!,
          currentFolderListing: _folderListing,
        );
      }
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      _addMessage(ChatSender.system, '⚠️ Erro: $message');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<bool> _confirmAction(PlannedAction action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar ação'),
        content: SingleChildScrollView(child: Text(action.describe())),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Executa a ação e devolve o resultado, inclusive os dados que o modelo
  /// precisa ver (listagem de uma pasta, conteúdo de um arquivo). Nunca lança:
  /// qualquer erro vira um ActionOutcome.fail, pra sempre voltar pro modelo
  /// (senão o histórico da conversa fica com uma chamada sem resposta).
  Future<ActionOutcome> _executeAction(GeminiService gemini, PlannedAction action) async {
    final input = action.input;
    try {
      switch (action.toolName) {
        case 'list_folder':
          return await _listFolder(gemini, input['uri'], input['recursive'] == true);
        case 'search_files':
          return await _searchFiles(
            gemini,
            input['query'],
            input['folder_uri'],
            input['recursive'] == true,
          );
        case 'move_file':
          return await _runBatch(
            input['items'],
            (item) => FileBridge.moveFile(
              sourceUri: item['uri'],
              destTreeUri: input['dest_folder_uri'],
            ),
          );
        case 'rename_file':
          return _fromBool(
            await FileBridge.renameFile(uri: input['uri'], newName: input['new_name']),
            'Não consegui renomear.',
          );
        case 'delete_file':
          return await _runBatch(
            input['items'],
            (item) => FileBridge.deleteFile(item['uri']),
          );
        case 'read_file':
          return await _readFile(input['uri']);
        case 'write_file':
          return _fromBool(
            await FileBridge.writeFile(uri: input['uri'], content: input['content']),
            'Não consegui gravar o arquivo.',
          );
        case 'create_folder':
          {
            final newUri = await FileBridge.createFolder(
              parentTreeUri: input['parent_uri'],
              name: input['name'],
            );
            return _fromBool(newUri != null,
                'Não consegui criar a pasta (talvez já exista algo com esse nome ali).');
          }
        case 'create_file':
          {
            final newUri = await FileBridge.createFile(
              parentTreeUri: input['parent_uri'],
              name: input['name'],
              content: input['content'],
            );
            return _fromBool(newUri != null, 'Não consegui criar o arquivo.');
          }
        default:
          return ActionOutcome.fail('Ferramenta desconhecida: ${action.toolName}');
      }
    } catch (e) {
      return ActionOutcome.fail('$e');
    }
  }

  ActionOutcome _fromBool(bool ok, String failMessage) =>
      ok ? const ActionOutcome.ok() : ActionOutcome.fail(failMessage);

  /// Roda a mesma operação em vários itens (uma confirmação só) e resume o
  /// resultado: o que deu certo e o que falhou. Uma falha não impede os outros.
  Future<ActionOutcome> _runBatch(
    List<dynamic> items,
    Future<bool> Function(Map<String, dynamic> item) operation,
  ) async {
    final done = <String>[];
    final failed = <String>[];
    for (final raw in items) {
      final item = Map<String, dynamic>.from(raw as Map);
      final name = '${item['name']}';
      try {
        if (await operation(item)) {
          done.add(name);
        } else {
          failed.add(name);
        }
      } catch (_) {
        failed.add(name);
      }
    }
    if (failed.isEmpty) return ActionOutcome.ok({'concluidos': done});
    return ActionOutcome.fail(
      done.isEmpty
          ? 'Não consegui executar a ação.'
          : 'Só parte dos itens foi processada.',
      {'concluidos': done, 'falharam': failed},
    );
  }

  /// Lê um arquivo de texto e devolve o conteúdo pro modelo (limitado, pra não
  /// estourar o contexto). Arquivos binários (imagens, zips) são recusados.
  Future<ActionOutcome> _readFile(String uri) async {
    const maxChars = 20000;
    final content = await FileBridge.readFile(uri);
    if (content == null) {
      return const ActionOutcome.fail('Não consegui ler o arquivo.');
    }
    if (content.contains('\u0000')) {
      return const ActionOutcome.fail(
          'Esse arquivo parece binário (imagem, zip...), não é texto.');
    }
    final preview = content.length > 600 ? '${content.substring(0, 600)}…' : content;
    _addMessage(ChatSender.system, '📄 $preview');
    final truncated = content.length > maxChars;
    return ActionOutcome.ok({
      'conteudo': truncated ? content.substring(0, maxChars) : content,
      if (truncated) 'aviso': 'Arquivo cortado nos primeiros $maxChars caracteres.',
    });
  }

  /// Lista uma pasta (e, se `recursive`, tudo dentro das subpastas) num texto
  /// indentado com o id de cada item — é isso que o modelo enxerga.
  Future<ActionOutcome> _listFolder(GeminiService gemini, String uri, bool recursive) async {
    const maxEntries = 400;
    const maxDepth = 6;
    final lines = <String>[];
    var truncated = false;

    Future<void> walk(String folderUri, int depth) async {
      final entries = await FileBridge.listFiles(folderUri);
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      for (final e in entries) {
        if (lines.length >= maxEntries) {
          truncated = true;
          return;
        }
        lines.add(gemini.formatEntry(e, depth: depth));
        if (recursive && e.isDirectory) {
          if (depth + 1 >= maxDepth) {
            truncated = true;
          } else {
            await walk(e.uri, depth + 1);
            if (truncated && lines.length >= maxEntries) return;
          }
        }
      }
    }

    try {
      await walk(uri, 0);
    } catch (e) {
      return ActionOutcome.fail('Não consegui listar a pasta: $e');
    }

    return ActionOutcome.ok({
      'itens': lines.isEmpty ? '(pasta vazia)' : lines.join('\n'),
      if (truncated)
        'aviso': 'Listagem cortada (limite de $maxEntries itens / $maxDepth níveis). '
            'Liste subpastas específicas para ver o resto.',
    });
  }

  /// Procura um termo dentro do conteúdo dos arquivos de uma pasta (e, se
  /// `recursive`, das subpastas). Pula extensões que claramente não são texto
  /// (imagens, áudio...) sem sequer tentar abri-las.
  Future<ActionOutcome> _searchFiles(
    GeminiService gemini,
    String query,
    String rootUri,
    bool recursive,
  ) async {
    const maxMatches = 30;
    const maxFilesScanned = 500;
    const maxDepth = 6;
    const snippetRadius = 60;

    final lowerQuery = query.toLowerCase();
    final resultLines = <String>[];
    var scanned = 0;
    var truncated = false;

    Future<void> walk(String folderUri, int depth) async {
      if (truncated) return;
      final entries = await FileBridge.listFiles(folderUri);
      for (final e in entries) {
        if (truncated) return;
        if (e.isDirectory) {
          if (recursive && depth + 1 < maxDepth) {
            await walk(e.uri, depth + 1);
          }
          continue;
        }
        if (!_isSearchable(e.name)) continue;
        if (scanned >= maxFilesScanned || resultLines.length >= maxMatches) {
          truncated = true;
          return;
        }
        scanned++;

        String? content;
        try {
          content = await FileBridge.readFile(e.uri);
        } catch (_) {
          content = null;
        }
        if (content == null || content.contains('\u0000')) continue;

        final lowerContent = content.toLowerCase();
        final firstIdx = lowerContent.indexOf(lowerQuery);
        if (firstIdx == -1) continue;

        var count = 0;
        var from = 0;
        while (true) {
          final found = lowerContent.indexOf(lowerQuery, from);
          if (found == -1) break;
          count++;
          from = found + lowerQuery.length;
        }

        final start = (firstIdx - snippetRadius).clamp(0, content.length);
        final end =
            (firstIdx + lowerQuery.length + snippetRadius).clamp(0, content.length);
        var snippet = content.substring(start, end).replaceAll('\n', ' ').trim();
        if (start > 0) snippet = '…$snippet';
        if (end < content.length) snippet = '$snippet…';

        final id = gemini.idFor(e);
        final vezes = count == 1 ? '1x' : '${count}x';
        resultLines.add('[id $id] ${e.name} ($vezes): $snippet');
      }
    }

    try {
      await walk(rootUri, 0);
    } catch (e) {
      return ActionOutcome.fail('Não consegui concluir a busca: $e');
    }

    return ActionOutcome.ok({
      'resultados': resultLines.isEmpty
          ? 'Nenhum arquivo contém "$query".'
          : resultLines.join('\n'),
      if (truncated)
        'aviso': 'Busca interrompida no limite de $maxFilesScanned arquivos '
            'verificados ou $maxMatches resultados — refine o termo ou busque '
            'numa subpasta específica.',
    });
  }

  Future<void> _openSettings() async {
    final controller = TextEditingController(text: await ApiKeyStore.get() ?? '');
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Chave de API do Gemini'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'AIza...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              await ApiKeyStore.set(controller.text.trim());
              _gemini = null; // força recriar com a nova chave
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Widget _buildBubble(ChatMessage message) {
    switch (message.sender) {
      case ChatSender.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              message.text,
              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
            ),
          ),
        );
      case ChatSender.assistant:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(message.text),
          ),
        );
      case ChatSender.system:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              message.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice File AI'),
        actions: [
          IconButton(
            onPressed: _startNewConversation,
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Começar conversa nova',
          ),
          IconButton(onPressed: _openSettings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickFolder,
                    icon: const Icon(Icons.folder_open),
                    label: Text(_folderUri == null ? 'Escolher pasta' : 'Trocar pasta'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      _folderUri == null
                          ? 'Escolha uma pasta e comece a conversar.'
                          : 'Pode falar ou escrever um comando.',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) => _buildBubble(_messages[i]),
                  ),
          ),
          if (_isListening)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_transcript.isEmpty ? 'Ouvindo...' : _transcript),
            ),
          if (_isBusy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    enabled: !_isBusy,
                    decoration: const InputDecoration(
                      hintText: 'Digite uma mensagem...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submitTypedCommand(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _isBusy ? null : _submitTypedCommand,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isBusy
                    ? null
                    : (_isListening ? _stopListeningAndRun : _startListening),
                style: _isListening
                    ? FilledButton.styleFrom(backgroundColor: Colors.red)
                    : null,
                icon: Icon(_isListening ? Icons.stop : Icons.mic),
                label: Text(_isListening ? 'Parar' : 'Falar'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
