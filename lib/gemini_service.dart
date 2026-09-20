import 'dart:convert';
import 'package:http/http.dart' as http;
import 'file_bridge.dart';

/// Uma ação que o modelo decidiu executar, já traduzida para algo que a
/// FileBridge entende.
class PlannedAction {
  final String toolName;
  final Map<String, dynamic> input;

  PlannedAction({required this.toolName, required this.input});

  /// Descrição em português para mostrar na confirmação antes de executar.
  String describe() {
    switch (toolName) {
      case 'move_file':
        return 'Mover "${input['source_name']}" para "${input['dest_folder_name']}"';
      case 'rename_file':
        return 'Renomear "${input['old_name']}" para "${input['new_name']}"';
      case 'delete_file':
        return 'Apagar "${input['name']}"';
      case 'write_file':
        return 'Editar o conteúdo de "${input['name']}"';
      case 'create_file':
        return 'Criar o arquivo "${input['name']}"';
      case 'read_file':
        return 'Ler "${input['name']}"';
      default:
        return 'Ação desconhecida: $toolName';
    }
  }
}

/// Usa a API do Gemini (Google), que tem um tier gratuito permanente.
/// Chave grátis em https://aistudio.google.com/apikey — sem cartão.
class GeminiService {
  static const _model = 'gemini-3.1-flash-lite';
  static const _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent';

  final String apiKey;
  GeminiService(this.apiKey);

  static final List<Map<String, dynamic>> _functionDeclarations = [
    {
      'name': 'move_file',
      'description': 'Move um arquivo existente para outra subpasta dentro da mesma árvore.',
      'parameters': {
        'type': 'object',
        'properties': {
          'source_uri': {'type': 'string'},
          'source_name': {'type': 'string'},
          'dest_folder_uri': {'type': 'string'},
          'dest_folder_name': {'type': 'string'},
        },
        'required': ['source_uri', 'source_name', 'dest_folder_uri', 'dest_folder_name'],
      },
    },
    {
      'name': 'rename_file',
      'description': 'Renomeia um arquivo ou pasta.',
      'parameters': {
        'type': 'object',
        'properties': {
          'uri': {'type': 'string'},
          'old_name': {'type': 'string'},
          'new_name': {'type': 'string'},
        },
        'required': ['uri', 'old_name', 'new_name'],
      },
    },
    {
      'name': 'delete_file',
      'description': 'Apaga um arquivo ou pasta permanentemente.',
      'parameters': {
        'type': 'object',
        'properties': {
          'uri': {'type': 'string'},
          'name': {'type': 'string'},
        },
        'required': ['uri', 'name'],
      },
    },
    {
      'name': 'read_file',
      'description': 'Lê o conteúdo de um arquivo de texto.',
      'parameters': {
        'type': 'object',
        'properties': {
          'uri': {'type': 'string'},
          'name': {'type': 'string'},
        },
        'required': ['uri', 'name'],
      },
    },
    {
      'name': 'write_file',
      'description': 'Sobrescreve o conteúdo de um arquivo de texto existente.',
      'parameters': {
        'type': 'object',
        'properties': {
          'uri': {'type': 'string'},
          'name': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['uri', 'name', 'content'],
      },
    },
    {
      'name': 'create_file',
      'description': 'Cria um novo arquivo de texto dentro da pasta atual.',
      'parameters': {
        'type': 'object',
        'properties': {
          'parent_uri': {'type': 'string'},
          'name': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['parent_uri', 'name', 'content'],
      },
    },
  ];

  /// Manda o comando transcrito + a listagem atual da pasta para o modelo,
  /// e devolve a ação planejada (ou null se o modelo só respondeu texto,
  /// por exemplo pedindo mais informação).
  Future<({PlannedAction? action, String? message})> interpretCommand({
    required String transcript,
    required String currentFolderUri,
    required List<FileEntry> currentFolderListing,
  }) async {
    final listingText = currentFolderListing
        .map((e) => '- ${e.isDirectory ? "[pasta]" : "[arquivo]"} ${e.name} (uri: ${e.uri})')
        .join('\n');

    final systemPrompt =
        'Você controla arquivos no celular do usuário através de ferramentas. '
        'A pasta atual (uri: $currentFolderUri) contém:\n$listingText\n\n'
        'Use SEMPRE as URIs exatas mostradas acima ao chamar uma ferramenta. '
        'Se o comando for ambíguo ou faltar informação, responda só com texto '
        'perguntando o que precisa, em vez de chamar uma ferramenta.';

    final response = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': transcript}
            ]
          }
        ],
        'tools': [
          {'functionDeclarations': _functionDeclarations}
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Erro da API (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      return (action: null, message: 'O modelo não devolveu resposta.');
    }

    final parts = candidates[0]['content']?['parts'] as List<dynamic>? ?? [];

    String? message;
    PlannedAction? action;

    for (final part in parts) {
      if (part['text'] != null) {
        message = (message ?? '') + (part['text'] as String);
      } else if (part['functionCall'] != null && action == null) {
        final call = part['functionCall'] as Map<String, dynamic>;
        action = PlannedAction(
          toolName: call['name'] as String,
          input: Map<String, dynamic>.from(call['args'] as Map? ?? {}),
        );
      }
    }

    return (action: action, message: message);
  }
}
