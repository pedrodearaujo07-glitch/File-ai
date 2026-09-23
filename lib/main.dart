import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  /// Pra só avisar uma vez que a conversa está "pesada", não a cada mensagem.
  bool _highStressWarned = false;

  /// Chave usada pra guardar a sessão (conversa + pasta) no armazenamento do
  /// próprio app, pra não perder tudo quando o app é fechado.
  static const _sessionPrefsKey = 'voice_file_ai_session_v1';

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

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  /// Guarda a conversa atual (histórico da IA + mensagens + pasta) no
  /// armazenamento do próprio app, pra continuar de onde parou da próxima
  /// vez que o app for aberto — fechar o app não deve "resetar a IA".
  Future<void> _saveSession() async {
    if (_gemini == null || _folderUri == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'folderUri': _folderUri,
        'messages':
            _messages.map((m) => {'sender': m.sender.name, 'text': m.text}).toList(),
        'gemini': _gemini!.exportSession(),
      };
      await prefs.setString(_sessionPrefsKey, jsonEncode(data));
    } catch (_) {
      // Salvar a sessão é conveniência, não algo crítico — se falhar, a
      // conversa continua funcionando normalmente só que sem persistir.
    }
  }

  /// Tenta retomar a sessão salva ao abrir o app. Se não houver nada salvo,
  /// ou algo estiver corrompido/incompatível, simplesmente começa vazio —
  /// nunca trava o app por causa disso.
  Future<void> _restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionPrefsKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;

      final folderUri = data['folderUri'] as String?;
      if (folderUri == null) return;

      final apiKey = await ApiKeyStore.get();
      if (apiKey == null || apiKey.isEmpty) return;

      final gemini = GeminiService(apiKey)
        ..onStatus = (message) => _addMessage(ChatSender.system, message);
      final geminiData = data['gemini'];
      if (geminiData is Map) {
        gemini.importSession(Map<String, dynamic>.from(geminiData));
      }

      final restoredMessages = <ChatMessage>[];
      final rawMessages = data['messages'];
      if (rawMessages is List) {
        for (final raw in rawMessages) {
          final map = Map<String, dynamic>.from(raw as Map);
          final sender = ChatSender.values.firstWhere(
            (s) => s.name == map['sender'],
            orElse: () => ChatSender.system,
          );
          restoredMessages.add(ChatMessage(sender, map['text'] as String));
        }
      }

      if (!mounted) return;
      setState(() {
        _folderUri = folderUri;
        _gemini = gemini;
        _messages
          ..clear()
          ..addAll(restoredMessages);
      });
      await _refreshListing();
    } catch (_) {
      // Sessão salva corrompida ou de uma versão incompatível — ignora e
      // começa do zero, em vez de travar a abertura do app.
    }
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
    await _saveSession();
  }

  /// Apaga o histórico da conversa (a IA esquece o que foi dito), sem afetar
  /// os arquivos. Diferente de trocar de pasta, isso é sempre uma escolha
  /// explícita do usuário. Antes de limpar, recomenda salvar um backup da
  /// conversa na pasta principal, pra não perder nada importante.
  Future<void> _startNewConversation() async {
    if (_messages.isEmpty) return;
    final stressLabel = _gemini?.stress.label;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Limpar conversa'),
        content: Text(
          'A IA vai esquecer tudo que foi conversado até agora'
          '${stressLabel == null ? '' : ' ($stressLabel)'}. Os arquivos não '
          'são afetados.\n\nRecomendado: salvar um backup da conversa na '
          'pasta principal antes de limpar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'clear'),
            child: const Text('Limpar sem backup'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'backup'),
            child: const Text('Fazer backup e limpar'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;

    if (choice == 'backup') {
      final ok = await _backupSession();
      if (!ok) return; // o erro já foi avisado dentro de _backupSession
    }

    _gemini?.resetConversation();
    setState(() {
      _messages.clear();
      _highStressWarned = false;
    });
    _addMessage(ChatSender.system, '🔄 Conversa reiniciada.');
    await _saveSession();
  }

  /// Salva um resumo legível da conversa atual como um .txt na pasta
  /// principal — os "dados essenciais da sessão" que o usuário pediria de
  /// volta se precisasse, antes de limpar o histórico.
  Future<bool> _backupSession() async {
    if (_folderUri == null) {
      _addMessage(ChatSender.system, '⚠️ Escolha uma pasta antes de fazer backup.');
      return false;
    }
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'backup_conversa_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}.txt';
    final uri = await FileBridge.createFile(
      parentTreeUri: _folderUri!,
      name: name,
      content: _buildSessionBackupText(),
    );
    if (uri == null) {
      _addMessage(ChatSender.system, '⚠️ Não consegui salvar o backup.');
      return false;
    }
    await _refreshListing();
    _addMessage(ChatSender.system, '💾 Backup salvo como "$name".');
    return true;
  }

  String _senderLabel(ChatSender sender) {
    switch (sender) {
      case ChatSender.user:
        return 'Você';
      case ChatSender.assistant:
        return 'IA';
      case ChatSender.system:
        return 'Sistema';
    }
  }

  String _buildSessionBackupText() {
    final buffer = StringBuffer()
      ..writeln('Backup da conversa — Voice File AI')
      ..writeln(
          'Pasta: ${_folderUri == null ? '-' : GeminiService.rootNameFromUri(_folderUri!)}')
      ..writeln('Gerado em: ${DateTime.now()}')
      ..writeln('---');
    // _messages fica do mais novo pro mais antigo; aqui inverte pra ficar
    // em ordem cronológica, como uma conversa de verdade se lê.
    for (final m in _messages.reversed) {
      buffer.writeln('[${_senderLabel(m.sender)}] ${m.text}');
    }
    return buffer.toString();
  }

  Future<void> _refreshListing() async {
    if (_folderUri == null) return;
    try {
      final listing = await FileBridge.listFiles(_folderUri!);
      setState(() => _folderListing = listing);
    } catch (_) {
      _addMessage(
        ChatSender.system,
        '⚠️ Perdi o acesso à pasta principal (a permissão pode ter sido '
        'revogada). Escolha a pasta de novo em "Trocar pasta".',
      );
      setState(() {
        _folderUri = null;
        _folderListing = [];
      });
    }
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
      final stress = _gemini?.stress;
      if (stress != null && stress.isHigh && !_highStressWarned) {
        _highStressWarned = true;
        _addMessage(
          ChatSender.system,
          '💡 A conversa está grande (${stress.label}). Isso deixa as '
          'respostas mais lentas e caras — toque em ↺ no topo pra limpar o '
          'histórico quando quiser (ele vai sugerir um backup antes).',
        );
      }
      await _saveSession();
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
          return await _readFile(input);
        case 'find_by_name':
          return await _findByName(gemini, input['term'], input['folder_uri']);
        case 'map_folder':
          return await _mapFolder(gemini, input['folder_uri']);
        case 'compare_with_backup':
          return await _compareWithBackup(input['zip_uri'], input['folder_uri']);
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
  /// Se `input` tiver start_line/end_line ou start_page/end_page, lê só essa
  /// faixa (arquivos grandes), sem carregar o arquivo inteiro.
  Future<ActionOutcome> _readFile(Map<String, dynamic> input) async {
    const maxChars = 20000;
    final content = await FileBridge.readFile(
      input['uri'],
      startLine: input['start_line'],
      endLine: input['end_line'],
      startPage: input['start_page'],
      endPage: input['end_page'],
    );
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

  /// Procura, em toda a árvore a partir de `rootUri`, arquivos/pastas cujo
  /// nome contenha `term` (sem diferenciar maiúsculas/minúsculas). Só olha
  /// nomes — bem mais rápido que a busca de conteúdo.
  Future<ActionOutcome> _findByName(
    GeminiService gemini,
    String term,
    String rootUri,
  ) async {
    const maxMatches = 60;
    const maxVisited = 2000;
    const maxDepth = 8;
    final lowerTerm = term.toLowerCase();
    final matches = <String>[];
    var visited = 0;
    var truncated = false;

    Future<void> walk(String folderUri, int depth) async {
      if (truncated) return;
      final entries = await FileBridge.listFiles(folderUri);
      for (final e in entries) {
        if (truncated) return;
        visited++;
        if (visited > maxVisited) {
          truncated = true;
          return;
        }
        if (e.name.toLowerCase().contains(lowerTerm)) {
          if (matches.length >= maxMatches) {
            truncated = true;
            return;
          }
          matches.add(gemini.formatEntry(e));
        }
        if (e.isDirectory && depth + 1 < maxDepth) {
          await walk(e.uri, depth + 1);
        }
      }
    }

    try {
      await walk(rootUri, 0);
    } catch (e) {
      return ActionOutcome.fail('Não consegui concluir a busca: $e');
    }

    return ActionOutcome.ok({
      'encontrados': matches.isEmpty
          ? 'Nenhum arquivo ou pasta com "$term" no nome.'
          : matches.join('\n'),
      if (truncated)
        'aviso': 'Busca por nome interrompida (limite de itens visitados ou '
            'resultados). Refine o termo ou procure numa subpasta específica.',
    });
  }

  /// Estrutura completa de uma pasta (recursiva), com destaque separado dos
  /// arquivos modificados mais recentemente em toda a árvore.
  Future<ActionOutcome> _mapFolder(GeminiService gemini, String uri) async {
    const maxEntries = 600;
    const maxDepth = 8;
    const maxHighlights = 20;
    final lines = <String>[];
    final allFiles = <FileEntry>[];
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
        if (!e.isDirectory) allFiles.add(e);
        if (e.isDirectory) {
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
      return ActionOutcome.fail('Não consegui mapear a pasta: $e');
    }

    final recent = [...allFiles]
      ..sort((a, b) => b.lastModified.compareTo(a.lastModified));
    final highlights = recent.where((e) => e.lastModified > 0).take(maxHighlights).map((e) {
      final id = gemini.idFor(e);
      final date = e.modifiedDateLabel;
      return '[id $id] ${e.name}${date == null ? '' : ' ($date)'}';
    }).join('\n');

    return ActionOutcome.ok({
      'estrutura': lines.isEmpty ? '(pasta vazia)' : lines.join('\n'),
      'modificados_recentemente': highlights.isEmpty ? '(sem datas disponíveis)' : highlights,
      if (truncated)
        'aviso': 'Mapa cortado (limite de $maxEntries itens / $maxDepth níveis). '
            'Mapeie subpastas específicas para ver o resto.',
    });
  }

  /// Compara os arquivos atuais de uma pasta com o conteúdo de um backup
  /// .zip (por caminho, tamanho e conteúdo — não só pelo nome).
  Future<ActionOutcome> _compareWithBackup(String zipUri, String folderUri) async {
    Map<String, dynamic>? result;
    try {
      result = await FileBridge.compareWithZipBackup(
        zipUri: zipUri,
        currentTreeUri: folderUri,
      );
    } catch (e) {
      return ActionOutcome.fail('Não consegui comparar com o backup: $e');
    }
    if (result == null) {
      return const ActionOutcome.fail('Não consegui comparar com o backup.');
    }

    final added = (result['added'] as List).cast<String>();
    final removed = (result['removed'] as List).cast<String>();
    final changed = (result['changed'] as List).cast<String>();
    final unchanged = result['unchanged'] as int;

    String section(String title, List<String> items) {
      if (items.isEmpty) return '$title: nenhum';
      const maxShown = 40;
      final shown = items.take(maxShown).join('\n  ');
      final extra =
          items.length > maxShown ? '\n  … e mais ${items.length - maxShown}' : '';
      return '$title (${items.length}):\n  $shown$extra';
    }

    final summary = [
      section('Adicionados desde o backup', added),
      section('Removidos desde o backup', removed),
      section('Alterados desde o backup', changed),
      'Sem mudanças: $unchanged arquivo(s)',
    ].join('\n\n');

    return ActionOutcome.ok({'comparacao': summary});
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
          if (_gemini != null && _messages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _gemini!.stress.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
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

 
