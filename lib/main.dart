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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final List<String> _log = [];

  String? _folderUri;
  List<FileEntry> _folderListing = [];
  bool _isListening = false;
  bool _isBusy = false;
  String _transcript = '';

  void _addLog(String line) {
    setState(() => _log.insert(0, line));
  }

  Future<void> _pickFolder() async {
    final uri = await FileBridge.pickFolder();
    if (uri == null) return;
    setState(() => _folderUri = uri);
    await _refreshListing();
    _addLog('📂 Pasta selecionada.');
  }

  Future<void> _refreshListing() async {
    if (_folderUri == null) return;
    final listing = await FileBridge.listFiles(_folderUri!);
    setState(() => _folderListing = listing);
  }

  Future<void> _startListening() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _addLog('⚠️ Permissão de microfone negada.');
      return;
    }
    final available = await _speech.initialize(
      onError: (e) => _addLog('⚠️ Erro no reconhecimento de voz: ${e.errorMsg}'),
    );
    if (!available) {
      _addLog('⚠️ Reconhecimento de voz indisponível neste aparelho.');
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

  Future<void> _runCommand(String command) async {
    if (_folderUri == null) {
      _addLog('⚠️ Escolha uma pasta primeiro.');
      return;
    }
    final apiKey = await ApiKeyStore.get();
    if (apiKey == null || apiKey.isEmpty) {
      _addLog('⚠️ Configure sua chave do Gemini nas configurações (ícone no topo).');
      return;
    }

    setState(() => _isBusy = true);
    _addLog('🎤 "$command"');

    try {
      final service = GeminiService(apiKey);
      final result = await service.interpretCommand(
        transcript: command,
        currentFolderUri: _folderUri!,
        currentFolderListing: _folderListing,
      );

      if (result.action == null) {
        _addLog('💬 ${result.message ?? "(sem resposta)"}');
        return;
      }

      final confirmed = await _confirmAction(result.action!);
      if (!confirmed) {
        _addLog('❌ Ação cancelada.');
        return;
      }

      await _executeAction(result.action!);
      await _refreshListing();
    } catch (e) {
      _addLog('⚠️ Erro: $e');
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

  Future<void> _executeAction(PlannedAction action) async {
    final input = action.input;
    switch (action.toolName) {
      case 'move_file':
        final ok = await FileBridge.moveFile(
          sourceUri: input['source_uri'],
          destTreeUri: input['dest_folder_uri'],
        );
        _addLog(ok ? '✅ Movido.' : '⚠️ Falha ao mover.');
        break;
      case 'rename_file':
        final ok = await FileBridge.renameFile(
          uri: input['uri'],
          newName: input['new_name'],
        );
        _addLog(ok ? '✅ Renomeado.' : '⚠️ Falha ao renomear.');
        break;
      case 'delete_file':
        final ok = await FileBridge.deleteFile(input['uri']);
        _addLog(ok ? '✅ Apagado.' : '⚠️ Falha ao apagar.');
        break;
      case 'read_file':
        final content = await FileBridge.readFile(input['uri']);
        _addLog('📄 Conteúdo:\n${content ?? "(vazio ou ilegível)"}');
        break;
      case 'write_file':
        final ok = await FileBridge.writeFile(
          uri: input['uri'],
          content: input['content'],
        );
        _addLog(ok ? '✅ Arquivo atualizado.' : '⚠️ Falha ao editar.');
        break;
      case 'create_file':
        final newUri = await FileBridge.createFile(
          parentTreeUri: input['parent_uri'],
          name: input['name'],
          content: input['content'],
        );
        _addLog(newUri != null ? '✅ Criado.' : '⚠️ Falha ao criar.');
        break;
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
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
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
          if (_folderUri != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${_folderListing.length} itens nesta pasta'),
              ),
            ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _log.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(_log[i]),
              ),
            ),
          ),
          if (_isListening)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_transcript.isEmpty ? 'Ouvindo...' : _transcript),
            ),
          if (_isBusy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FloatingActionButton.large(
              onPressed: _isBusy
                  ? null
                  : (_isListening ? _stopListeningAndRun : _startListening),
              backgroundColor: _isListening ? Colors.red : null,
              child: Icon(_isListening ? Icons.stop : Icons.mic),
            ),
          ),
        ],
      ),
    );
  }
}
