import 'dart:convert';
import 'package:http/http.dart' as http;
import 'file_bridge.dart';

/// Uma ação que o modelo decidiu executar, já traduzida para algo que a
/// FileBridge entende (os ids que o modelo usa já viraram URIs reais).
class PlannedAction {
  final String toolName;
  final Map<String, dynamic> input;
  final String? callId;

  /// Se preenchido, o pedido do modelo era inválido (id que não existe,
  /// pasta onde devia ser arquivo, etc.). A ação nem chega a ser mostrada
  /// pro usuário: o erro volta direto pro modelo, que pode tentar de novo.
  final String? error;

  PlannedAction({
    required this.toolName,
    required this.input,
    this.callId,
    this.error,
  });

  /// Listar uma pasta só revela nomes (o mesmo que o modelo já vê da pasta
  /// principal), então roda sem pedir confirmação.
  bool get needsConfirmation => toolName != 'list_folder';

  /// Ações que não alteram nada no armazenamento.
  bool get isReadOnly => toolName == 'list_folder' || toolName == 'read_file';

  /// Descrição em português para mostrar na confirmação antes de executar.
  String describe() {
    switch (toolName) {
      case 'list_folder':
        return 'Listar o conteúdo de "${input['name']}"';
      case 'move_file':
        return 'Mover "${input['source_name']}" para "${input['dest_folder_name']}"';
      case 'rename_file':
        return 'Renomear "${input['old_name']}" para "${input['new_name']}"';
      case 'delete_file':
        if (input['is_directory'] == true) {
          return 'Apagar a PASTA "${input['name']}" e tudo que está dentro dela';
        }
        return 'Apagar "${input['name']}"';
      case 'write_file':
        return 'Editar o conteúdo de "${input['name']}"';
      case 'create_file':
        return 'Criar o arquivo "${input['name']}" em "${input['parent_name']}"';
      case 'read_file':
        return 'Ler "${input['name']}"';
      default:
        return 'Ação desconhecida: $toolName';
    }
  }
}

/// Resultado de executar uma ação: se deu certo e, opcionalmente, dados que o
/// modelo precisa ver (listagem de uma pasta, conteúdo de um arquivo...).
class ActionOutcome {
  final bool success;
  final Map<String, dynamic>? data;
  final String? error;

  const ActionOutcome.ok([this.data])
      : success = true,
        error = null;

  const ActionOutcome.fail([this.error])
      : success = false,
        data = null;
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
///
/// IMPORTANTE: o modelo nunca vê nem escreve URIs. Cada arquivo/pasta ganha
/// um id numérico curto (o 0 é a pasta principal escolhida), e as ferramentas
/// recebem só o id. Copiar URIs enormes de volta é justamente onde o modelo
/// errava (trocava maiúscula por minúscula e o Android negava o acesso).
class GeminiService {
  static const _model = 'gemini-3.1-flash-lite';
  static const _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent';

  final String apiKey;
  GeminiService(this.apiKey);

  final List<Map<String, dynamic>> _history = [];

  // Registro de ids <-> itens. O id 0 é sempre a pasta principal.
  final Map<int, FileEntry> _entriesById = {};
  final Map<String, int> _idsByUri = {};
  int _nextId = 1;

  /// Começa uma conversa nova (usado, por exemplo, quando o usuário troca de
  /// pasta — as URIs e ids antigos deixam de fazer sentido).
  void resetConversation() {
    _history.clear();
    _entriesById.clear();
    _idsByUri.clear();
    _nextId = 1;
  }

  int _register(FileEntry entry) {
    final existing = _idsByUri[entry.uri];
    if (existing != null) {
      _entriesById[existing] = entry;
      return existing;
    }
    final id = _nextId++;
    _idsByUri[entry.uri] = id;
    _entriesById[id] = entry;
    return id;
  }

  void _registerRoot(String rootUri) {
    _idsByUri[rootUri] = 0;
    _entriesById[0] = FileEntry(
      uri: rootUri,
      name: _rootName(rootUri),
      isDirectory: true,
    );
  }

  /// Esquece um item (e tudo que estava dentro dele, se for pasta): depois de
  /// renomear/mover/apagar, a URI antiga deixa de existir.
  void _forgetUri(String? uri) {
    if (uri == null) return;
    final stale = _idsByUri.keys
        .where((u) => u == uri || u.startsWith('$uri%2F'))
        .toList();
    for (final u in stale) {
      final id = _idsByUri.remove(u);
      if (id != null && id != 0) _entriesById.remove(id);
    }
  }

  /// Nome amigável da pasta principal, tirado do fim da URI da árvore.
  static String _rootName(String treeUri) {
    try {
      final afterTree = treeUri.split('/tree/').last.split('/document/').first;
      final decoded = Uri.decodeComponent(afterTree);
      final last = decoded.split(RegExp(r'[/:]')).last;
      return last.isEmpty ? 'pasta principal' : last;
    } catch (_) {
      return 'pasta principal';
    }
  }

  static int? _asId(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// Formata um item pra mostrar ao modelo (já registrando o id dele).
  /// `depth` recua a linha, pra listagens recursivas ficarem legíveis.
  String formatEntry(FileEntry entry, {int depth = 0}) {
    final id = _register(entry);
    final kind = entry.isDirectory ? 'pasta' : 'arquivo';
    final indent = '  ' * depth;
    return '$indent[id $id] [$kind] ${entry.name}';
  }

  static final List<Map<String, dynamic>> _functionDeclarations = [
    {
      'name': 'list_folder',
      'description':
          'Lista o conteúdo de uma pasta (pode ser a principal, id 0, ou qualquer '
              'subpasta em qualquer nível). Com recursive=true lista também tudo que '
              'está dentro das subpastas (até 6 níveis) — use isso para explorar '
              'e conferir a estrutura. Cada item volta com seu id.',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'integer',
            'description': 'id da pasta a listar (0 = pasta principal)',
          },
          'recursive': {
            'type': 'boolean',
            'description': 'true para incluir tudo dentro das subpastas',
          },
        },
        'required': ['id'],
      },
    },
    {
      'name': 'move_file',
      'description':
          'Move um arquivo (não pasta) para outra pasta dentro da mesma árvore.',
      'parameters': {
        'type': 'object',
        'properties': {
          'source_id': {'type': 'integer', 'description': 'id do arquivo a mover'},
          'dest_folder_id': {
            'type': 'integer',
            'description': 'id da pasta de destino',
          },
        },
        'required': ['source_id', 'dest_folder_id'],
      },
    },
    {
      'name': 'rename_file',
      'description': 'Renomeia um arquivo ou pasta.',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'new_name': {
            'type': 'string',
            'description': 'novo nome simples, sem "/"',
          },
        },
        'required': ['id', 'new_name'],
      },
    },
    {
      'name': 'delete_file',
      'description': 'Apaga um arquivo ou pasta permanentemente.',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      },
    },
    {
      'name': 'read_file',
      'description':
          'Lê o conteúdo de um arquivo de texto (não funciona em pastas nem em '
              'arquivos binários como imagens).',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      },
    },
    {
      'name': 'write_file',
      'description': 'Sobrescreve o conteúdo de um arquivo de texto existente.',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'content': {'type': 'string'},
        },
        'required': ['id', 'content'],
      },
    },
    {
      'name': 'create_file',
      'description': 'Cria um novo arquivo de texto dentro de uma pasta.',
      'parameters': {
        'type': 'object',
        'properties': {
          'parent_id': {
            'type': 'integer',
            'description': 'id da pasta onde criar (0 = pasta principal)',
          },
          'name': {
            'type': 'string',
            'description': 'nome simples do arquivo, sem "/"',
          },
          'content': {'type': 'string'},
        },
        'required': ['parent_id', 'name', 'content'],
      },
    },
  ];

  String _systemPrompt(String currentFolderUri, List<FileEntry> listing) {
    final listingText = listing.isEmpty
        ? '(vazia)'
        : listing.map((e) => formatEntry(e)).join('\n');
    return 'Você é um assistente que conversa naturalmente com o usuário e '
        'controla arquivos no celular dele através de ferramentas. Responda '
        'sempre em português do Brasil, de forma breve e natural, como num chat. '
        'Você tem acesso à pasta principal (id 0) e a TODAS as subpastas dentro '
        'dela, em qualquer nível. O primeiro nível da pasta principal é:\n'
        '$listingText\n\n'
        'Cada item tem um id numérico. Nas ferramentas use SEMPRE só esses ids '
        '(nunca invente ids, nem escreva caminhos ou URIs). '
        'Para ver o que tem dentro de subpastas, chame list_folder — com '
        'recursive=true ele mostra tudo dentro da pasta de uma vez (list_folder '
        'com id 0 e recursive=true mostra a árvore inteira). Nunca opine sobre '
        'o conteúdo de uma pasta sem listá-la antes. Para ler um arquivo de '
        'texto use read_file (não funciona em pastas). '
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
  /// `data` leva o que o modelo precisa enxergar (listagem, conteúdo lido).
  Future<GeminiTurn> reportActionResult({
    required PlannedAction action,
    required bool success,
    required bool cancelledByUser,
    required String currentFolderUri,
    required List<FileEntry> currentFolderListing,
    Map<String, dynamic>? data,
    String? error,
  }) async {
    final Map<String, dynamic> responseBody;
    if (cancelledByUser) {
      responseBody = {'error': 'O usuário cancelou essa ação antes de executar.'};
    } else if (success) {
      responseBody = {'success': true, if (data != null) ...data};
    } else {
      responseBody = {
        'success': false,
        'error': error ?? 'Falha ao executar a ação.',
      };
    }

    // Renomear/mover/apagar muda o endereço do item (e do que está dentro
    // dele, se for pasta): os ids antigos deixam de valer.
    if (success &&
        !cancelledByUser &&
        (action.toolName == 'rename_file' ||
            action.toolName == 'move_file' ||
            action.toolName == 'delete_file')) {
      _forgetUri((action.input['source_uri'] ?? action.input['uri']) as String?);
      responseBody['aviso'] =
          'Os ids antigos desse item (e do que estava dentro dele) deixaram de '
          'valer. Se precisar deles de novo, liste a pasta com list_folder.';
    }

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

  /// Traduz o pedido do modelo (com ids) numa ação com URIs reais. Se algo
  /// estiver errado, devolve uma ação com `error` preenchido.
  PlannedAction _buildAction(
    String tool,
    Map<String, dynamic> args,
    String? callId,
  ) {
    PlannedAction invalid(String message) => PlannedAction(
          toolName: tool,
          input: const {},
          callId: callId,
          error: message,
        );

    FileEntry? entryFor(String key) {
      final id = _asId(args[key]);
      return id == null ? null : _entriesById[id];
    }

    String missing(String key) =>
        'O id "${args[key]}" (parâmetro $key) não existe. Use somente ids que '
        'apareceram nas listagens.';

    String? textArg(String key) {
      final v = args[key];
      return v is String ? v : null;
    }

    bool isRoot(FileEntry e) => _entriesById[0]?.uri == e.uri;
    bool badName(String n) => n.isEmpty || n.contains('/');

    switch (tool) {
      case 'list_folder':
        {
          final dir = entryFor('id');
          if (dir == null) return invalid(missing('id'));
          if (!dir.isDirectory) {
            return invalid(
                '"${dir.name}" não é uma pasta; use read_file para ler arquivos.');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {
              'uri': dir.uri,
              'name': dir.name,
              'recursive':
                  args['recursive'] == true || args['recursive'] == 'true',
            },
          );
        }
      case 'read_file':
        {
          final file = entryFor('id');
          if (file == null) return invalid(missing('id'));
          if (file.isDirectory) {
            return invalid(
                '"${file.name}" é uma pasta, não dá pra ler como arquivo. Use list_folder.');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {'uri': file.uri, 'name': file.name},
          );
        }
      case 'move_file':
        {
          final source = entryFor('source_id');
          if (source == null) return invalid(missing('source_id'));
          final dest = entryFor('dest_folder_id');
          if (dest == null) return invalid(missing('dest_folder_id'));
          if (isRoot(source)) {
            return invalid('A pasta principal não pode ser movida.');
          }
          if (source.isDirectory) {
            return invalid(
                'Mover pastas inteiras ainda não é suportado (só arquivos).');
          }
          if (!dest.isDirectory) {
            return invalid('O destino "${dest.name}" não é uma pasta.');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {
              'source_uri': source.uri,
              'source_name': source.name,
              'dest_folder_uri': dest.uri,
              'dest_folder_name': dest.name,
            },
          );
        }
      case 'rename_file':
        {
          final item = entryFor('id');
          if (item == null) return invalid(missing('id'));
          if (isRoot(item)) {
            return invalid('A pasta principal não pode ser renomeada.');
          }
          final newName = textArg('new_name')?.trim();
          if (newName == null || badName(newName)) {
            return invalid(
                'new_name inválido: precisa ser um nome simples, sem "/".');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {
              'uri': item.uri,
              'old_name': item.name,
              'new_name': newName,
            },
          );
        }
      case 'delete_file':
        {
          final item = entryFor('id');
          if (item == null) return invalid(missing('id'));
          if (isRoot(item)) {
            return invalid('A pasta principal não pode ser apagada.');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {
              'uri': item.uri,
              'name': item.name,
              'is_directory': item.isDirectory,
            },
          );
        }
      case 'write_file':
        {
          final file = entryFor('id');
          if (file == null) return invalid(missing('id'));
          if (file.isDirectory) {
            return invalid(
                '"${file.name}" é uma pasta; write_file só edita arquivos de texto.');
          }
          final content = textArg('content');
          if (content == null) return invalid('Faltou o parâmetro content.');
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {'uri': file.uri, 'name': file.name, 'content': content},
          );
        }
      case 'create_file':
        {
          final parent = entryFor('parent_id');
          if (parent == null) return invalid(missing('parent_id'));
          if (!parent.isDirectory) {
            return invalid('"${parent.name}" não é uma pasta.');
          }
          final name = textArg('name')?.trim();
          if (name == null || badName(name)) {
            return invalid(
                'name inválido: precisa ser um nome simples, sem "/".');
          }
          final content = textArg('content');
          if (content == null) return invalid('Faltou o parâmetro content.');
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {
              'parent_uri': parent.uri,
              'parent_name': parent.name,
              'name': name,
              'content': content,
            },
          );
        }
      default:
        return invalid('Ferramenta desconhecida: $tool');
    }
  }

  Future<GeminiTurn> _callModel(
    String currentFolderUri,
    List<FileEntry> currentFolderListing,
  ) async {
    _registerRoot(currentFolderUri);

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

    final rawParts = (content['parts'] as List<dynamic>?) ?? [];

    // O app responde a uma ferramenta por vez. Se o modelo pediu várias de
    // uma vez (ex.: listar BP e RP juntos), guardamos só a primeira no
    // histórico — senão a API reclama que faltam respostas de ferramenta.
    // Ele pede as outras no turno seguinte.
    final keptParts = <dynamic>[];
    var hasCall = false;
    for (final part in rawParts) {
      if (part is Map && part['functionCall'] != null) {
        if (hasCall) continue;
        hasCall = true;
      }
      keptParts.add(part);
    }

    if (keptParts.isEmpty) {
      return GeminiTurn(text: 'O modelo não devolveu resposta.');
    }

    // Guarda o turno do modelo como veio (preserva campos como thought
    // signatures, essenciais pro Gemini manter o contexto entre chamadas de
    // ferramenta em turnos seguintes).
    _history.add({...content, 'parts': keptParts});

    String? text;
    PlannedAction? action;

    for (final part in keptParts) {
      if (part['text'] != null) {
        text = (text ?? '') + (part['text'] as String);
      } else if (part['functionCall'] != null && action == null) {
        final call = part['functionCall'] as Map<String, dynamic>;
        action = _buildAction(
          call['name'] as String,
          Map<String, dynamic>.from(call['args'] as Map? ?? {}),
          call['id'] as String?,
        );
      }
    }

    return GeminiTurn(text: text, action: action);
  }
}
