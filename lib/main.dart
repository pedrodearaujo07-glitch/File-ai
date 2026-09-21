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

  void _addMessage(ChatSender sender, String text) {
    setState(() => _messages.insert(0, ChatMessage(sender, text)));
  }

  Future<void> _pickFolder() async {
    final uri = await FileBridge.pickFolder();
    if (uri == null) return;
    setState(() {
      _folderUri = uri;
      _messages.clear();
    });
    _gemini?.resetConversation();
    await _refreshListing();
    _addMessage(ChatSender.system, '📂 Pasta selecionada. Conversa reiniciada.');
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
    _gemini = GeminiService(apiKey);
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

      var chainGuard = 0;
      while (true) {
        if (turn.text != null && turn.text!.trim().isNotEmpty) {
          _addMessage(ChatSender.assistant, turn.text!.trim());
        }

        final action = turn.action;
        if (action == null) break;

        chainGuard++;
        if (chainGuard > 4) {
          _addMessage(ChatSender.system, '⚠️ Muitas ações em sequência — parando por segurança.');
          break;
        }

        final confirmed = await _confirmAction(action);
        var success = false;
        if (confirmed) {
          _addMessage(ChatSender.system, '⚙️ ${action.describe()}');
          success = await _executeAction(action);
          await _refreshListing();
        }

        turn = await gemini.reportActionResult(
          action: action,
          success: success,
          cancelledByUser: !confirmed,
          currentFolderUri: _folderUri!,
          currentFolderListing: _folderListing,
        );
      }
    } catch (e) {
      _addMessage(ChatSender.system, '⚠️ Erro: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<bool> _confirmAction(PlannedAction action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar ação'),
        content: Text(action.describe()),
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

  Future<bool> _executeAction(PlannedAction action) async {
    final input = action.input;
    switch (action.toolName) {
      case 'move_file':
        return FileBridge.moveFile(
          sourceUri: input['source_uri'],
          destTreeUri: input['dest_folder_uri'],
        );
      case 'rename_file':
        return FileBridge.renameFile(uri: input['uri'], newName: input['new_name']);
      case 'delete_file':
        return FileBridge.deleteFile(input['uri']);
      case 'read_file':
        final content = await FileBridge.readFile(input['uri']);
        if (content != null) {
          _addMessage(ChatSender.system, '📄 $content');
        }
        return content != null;
      case 'write_file':
        return FileBridge.writeFile(uri: input['uri'], content: input['content']);
      case 'create_file':
        final newUri = await FileBridge.createFile(
          parentTreeUri: input['parent_uri'],
          name: input['name'],
          content: input['content'],
        );
        return newUri != null;
      default:
        return false;
    }
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
