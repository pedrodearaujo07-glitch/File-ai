import 'dart:convert';
import 'package:http/http.dart' as http;
import 'file_bridge.dart';

/// Uma ação que o modelo decidiu executar, já traduzida para algo que a
/// FileBridge entende.
class PlannedAction {
  final String toolName;
  final Map<String, dynamic> input;
  final String? callId;

  PlannedAction({required this.toolName, required this.input, this.callId});

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

/// O que o modelo devolveu num turno: uma fala (para mostrar no chat) e/ou
/// uma ação a confirmar antes de executar.
class GeminiTurn {
  final String? text;
  final PlannedAction? action;
  GeminiTurn({this.text, this.action});
}

/// Usa a API do Gemini (Google), que tem um tier gratuito permanente.
/// Chave grátis em https://aistudio.google.com/apikey — sem cartão.
///
/// Mantém o histórico da conversa internamente, então dá pra usar como um
/// chat normal: o modelo lembra do que foi dito e do que já foi executado
/// nos turnos anteriores.
class GeminiService {
  static const _model = 'gemini-3.1-flash-lite';
  static const _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent';

  final String apiKey;
  GeminiService(this.apiKey);

  final List<Map<String, dynamic>> _history = [];

  /// Começa uma conversa nova (usado, por exemplo, quando o usuário troca de
  /// pasta — as URIs antigas deixam de fazer sentido).
  void resetConversation() => _history.clear();

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

  String _systemPrompt(String currentFolderUri, List<FileEntry> listing) {
    final listingText = listing
        .map((e) => '- ${e.isDirectory ? "[pasta]" : "[arquivo]"} ${e.name} (uri: ${e.uri})')
        .join('\n');
    return 'Você é um assistente que conversa naturalmente com o usuário e '
        'controla arquivos no celular dele através de ferramentas. Responda '
        'sempre em português do Brasil, de forma breve e natural, como num chat. '
        'A pasta atual (uri: $currentFolderUri) contém:\n$listingText\n\n'
        'Use SEMPRE as URIs exatas mostradas acima ao chamar uma ferramenta. '
        'Chame no máximo UMA ferramenta por vez — se o pedido do usuário exigir '
        'várias ações, execute a primeira e espere o resultado antes de propor '
        'a próxima. Se o comando for ambíguo ou faltar informação, responda só '
        'com texto perguntando o que precisa, em vez de chamar uma ferramenta.';
  }

  /// Manda uma mensagem do usuário (por voz ou digitada) e devolve o que o
  /// modelo respondeu.
  Future<GeminiTurn> sendUserMessage({
    required String text,
    required String currentFolderUri,
    required List<FileEntry> currentFolderListing,
  }) async {
    _history.add({
      'role': 'user',
      'parts': [
        {'text': text}
      ],
    });
    return _callModel(currentFolderUri, currentFolderListing);
  }

  /// Conta pro modelo o resultado de uma ação que acabou de ser executada
  /// (ou cancelada pelo usuário), e devolve a resposta natural dele.
  Future<GeminiTurn> reportActionResult({
    required PlannedAction action,
    required bool success,
    required bool cancelledByUser,
    required String currentFolderUri,
    required List<FileEntry> currentFolderListing,
  }) async {
    final Map<String, dynamic> responseBody = cancelledByUser
        ? {'error': 'O usuário cancelou essa ação antes de executar.'}
        : {'success': success, if (!success) 'error': 'Falha ao executar a ação.'};

    _history.add({
      'role': 'user',
      'parts': [
        {
          'functionResponse': {
            if (action.callId != null) 'id': action.callId,
            'name': action.toolName,
            'response': responseBody,
          }
        }
      ],
    });
    return _callModel(currentFolderUri, currentFolderListing);
  }

  Future<GeminiTurn> _callModel(
    String currentFolderUri,
    List<FileEntry> currentFolderListing,
  ) async {
    final response = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': _systemPrompt(currentFolderUri, currentFolderListing)}
          ]
        },
        'contents': _history,
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
      return GeminiTurn(text: 'O modelo não devolveu resposta.');
    }

    final content = candidates[0]['content'] as Map<String, dynamic>?;
    if (content == null) {
      return GeminiTurn(text: 'O modelo não devolveu resposta.');
    }

    // Guarda o turno do modelo exatamente como veio (preserva campos como
    // thought signatures, essenciais pro Gemini manter o contexto entre
    // chamadas de ferramenta em turnos seguintes).
    _history.add(content);

    final parts = content['parts'] as List<dynamic>? ?? [];

    String? text;
    PlannedAction? action;

    for (final part in parts) {
      if (part['text'] != null) {
        text = (text ?? '') + (part['text'] as String);
      } else if (part['functionCall'] != null && action == null) {
        final call = part['functionCall'] as Map<String, dynamic>;
        action = PlannedAction(
          toolName: call['name'] as String,
          input: Map<String, dynamic>.from(call['args'] as Map? ?? {}),
          callId: call['id'] as String?,
        );
      }
    }

    return GeminiTurn(text: text, action: action);
  }
}
