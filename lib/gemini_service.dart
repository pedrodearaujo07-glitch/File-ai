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

  /// Itens de uma ação em lote (mover/apagar vários de uma vez).
  List<Map<String, dynamic>> get _items {
    final raw = input['items'];
    if (raw is! List) return const [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Lista de nomes (até 15) pra mostrar na confirmação de um lote.
  String _bulkList() {
    const maxShown = 15;
    final names = _items.map((i) => '${i['name']}').toList();
    final shown = names.take(maxShown).map((n) => '• $n').join('\n');
    final extra =
        names.length > maxShown ? '\n… e mais ${names.length - maxShown}' : '';
    return '$shown$extra';
  }

  /// Só a primeira linha da descrição (pra mensagem curta no chat).
  String get summary =>
      describe().split('\n').first.replaceAll(RegExp(r':$'), '');

  /// Descrição em português para mostrar na confirmação antes de executar.
  String describe() {
    switch (toolName) {
      case 'list_folder':
        return 'Listar o conteúdo de "${input['name']}"';
      case 'move_file':
        {
          final items = _items;
          final dest = input['dest_folder_name'];
          if (items.length == 1) {
            return 'Mover "${items.first['name']}" para "$dest"';
          }
          return 'Mover ${items.length} arquivos para "$dest":\n${_bulkList()}';
        }
      case 'rename_file':
        return 'Renomear "${input['old_name']}" para "${input['new_name']}"';
      case 'delete_file':
        {
          final items = _items;
          if (items.length == 1) {
            final item = items.first;
            if (item['is_directory'] == true) {
              return 'Apagar a PASTA "${item['name']}" e tudo que está dentro dela';
            }
            return 'Apagar "${item['name']}"';
          }
          final folders = items.where((i) => i['is_directory'] == true).length;
          final extra =
              folders > 0 ? ' (inclui $folders pasta(s), com tudo que há dentro)' : '';
          return 'Apagar ${items.length} itens$extra:\n${_bulkList()}';
        }
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

  /// `data` opcional: numa falha parcial (ex.: 3 de 5 arquivos apagados) leva
  /// a lista do que deu certo e do que falhou.
  const ActionOutcome.fail([this.error, this.data]) : success = false;
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

  /// Máximo de itens por chamada em lote (mover/apagar).
  static const int _maxBatch = 100;

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
          'Move um ou vários arquivos (não pastas) para UMA pasta de destino, '
              'com uma única confirmação do usuário. Para mover vários, passe '
              'todos os ids de uma vez em source_ids.',
      'parameters': {
        'type': 'object',
        'properties': {
          'source_ids': {
            'type': 'array',
            'items': {'type': 'integer'},
            'description': 'ids dos arquivos a mover',
          },
          'dest_folder_id': {
            'type': 'integer',
            'description': 'id da pasta de destino',
          },
        },
        'required': ['source_ids', 'dest_folder_id'],
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
      'description':
          'Apaga um ou vários arquivos/pastas permanentemente, com uma única '
              'confirmação do usuário. Para apagar vários, passe todos os ids '
              'de uma vez em ids.',
      'parameters': {
        'type': 'object',
        'properties': {
          'ids': {
            'type': 'array',
            'items': {'type': 'integer'},
            'description': 'ids dos itens a apagar',
          },
        },
        'required': ['ids'],
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
        'Para apagar ou mover VÁRIOS arquivos, faça numa única chamada '
        'passando todos os ids de uma vez (o usuário confirma uma vez só) — '
        'não chame a ferramenta arquivo por arquivo. '
        'Chame no máximo UMA ferramenta por vez — se o pedido do usuário exigir '
        'várias ações diferentes, execute a primeira e espere o resultado antes '
        'de propor a próxima. Se o comando for ambíguo ou faltar informação, '
        'responda só com texto perguntando o que precisa, em vez de chamar uma '
        'ferramenta. Escreva em texto simples: não use markdown (nada de '
        'asteriscos ou #), o chat não formata isso.';
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
        if (data != null) ...data,
      };
    }

    // Renomear/mover/apagar muda o endereço do item (e do que está dentro
    // dele, se for pasta): os ids antigos deixam de valer. Vale também
    // quando um lote deu certo só em parte.
    if (!cancelledByUser &&
        (action.toolName == 'rename_file' ||
            action.toolName == 'move_file' ||
            action.toolName == 'delete_file')) {
      final done = data?['concluidos'];
      final changedSomething = success || (done is List && done.isNotEmpty);
      if (changedSomething) {
        final items = action.input['items'];
        if (items is List) {
          for (final item in items) {
            _forgetUri((item as Map)['uri'] as String?);
          }
        } else {
          _forgetUri(action.input['uri'] as String?);
        }
        responseBody['aviso'] =
            'Os ids antigos dos itens afetados (e do que estava dentro deles) '
            'deixaram de valer. Se precisar deles de novo, liste a pasta com '
            'list_folder.';
      }
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

    // Lê uma lista de ids (aceita também um id solto, por garantia).
    List<int>? idList(String listKey, String singleKey) {
      final raw = args[listKey] ?? args[singleKey];
      final List<dynamic> values;
      if (raw is List) {
        values = raw;
      } else if (raw == null) {
        values = [];
      } else {
        values = [raw];
      }
      final ids = <int>[];
      for (final v in values) {
        final id = _asId(v);
        if (id == null) return null;
        if (!ids.contains(id)) ids.add(id);
      }
      return ids;
    }

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
          final ids = idList('source_ids', 'source_id');
          if (ids == null || ids.isEmpty) {
            return invalid(
                'Passe em source_ids a lista de ids (números) dos arquivos a mover.');
          }
          if (ids.length > _maxBatch) {
            return invalid('No máximo $_maxBatch arquivos por vez.');
          }
          final dest = entryFor('dest_folder_id');
          if (dest == null) return invalid(missing('dest_folder_id'));
          if (!dest.isDirectory) {
            return invalid('O destino "${dest.name}" não é uma pasta.');
          }
          final items = <Map<String, dynamic>>[];
          final unknown = <int>[];
          for (final id in ids) {
            final entry = _entriesById[id];
            if (entry == null) {
              unknown.add(id);
              continue;
            }
            if (isRoot(entry)) {
              return invalid('A pasta principal não pode ser movida.');
            }
            if (entry.isDirectory) {
              return invalid(
                  'Mover pastas inteiras ainda não é suportado ("${entry.name}" é uma pasta).');
            }
            items.add({'uri': entry.uri, 'name': entry.name});
          }
          if (unknown.isNotEmpty) {
            return invalid('Estes ids não existem: ${unknown.join(', ')}. '
                'Use somente ids que apareceram nas listagens.');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {
              'items': items,
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
          final ids = idList('ids', 'id');
          if (ids == null || ids.isEmpty) {
            return invalid(
                'Passe em ids a lista de ids (números) dos itens a apagar.');
          }
          if (ids.length > _maxBatch) {
            return invalid('No máximo $_maxBatch itens por vez.');
          }
          final items = <Map<String, dynamic>>[];
          final unknown = <int>[];
          for (final id in ids) {
            final entry = _entriesById[id];
            if (entry == null) {
              unknown.add(id);
              continue;
            }
            if (isRoot(entry)) {
              return invalid('A pasta principal não pode ser apagada.');
            }
            items.add({
              'uri': entry.uri,
              'name': entry.name,
              'is_directory': entry.isDirectory,
            });
          }
          if (unknown.isNotEmpty) {
            return invalid('Estes ids não existem: ${unknown.join(', ')}. '
                'Use somente ids que apareceram nas listagens.');
          }
          return PlannedAction(
            toolName: tool,
            callId: callId,
            input: {'items': items},
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

  /// Avisa o usuário de coisas como "tentando de novo..." (opcional).
  void Function(String message)? onStatus;

  // Erros temporários do lado do Google (sobrecarga, limite, instabilidade).
  static const _retryableStatus = {429, 500, 502, 503, 504};
  static const _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
  ];

  /// Manda a requisição e, se o Gemini responder com um erro temporário
  /// (ex.: 503 "high demand") ou a conexão falhar, tenta de novo algumas
  /// vezes esperando um pouco mais a cada tentativa.
  Future<http.Response> _postWithRetry(String body) async {
    for (var attempt = 0;; attempt++) {
      final isLast = attempt >= _retryDelays.length;
      http.Response response;
      try {
        response = await http.post(
          Uri.parse(_endpoint),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: body,
        );
      } catch (_) {
        if (isLast) rethrow;
        onStatus?.call('⏳ Sem conexão com o Gemini. Tentando de novo...');
        await Future.delayed(_retryDelays[attempt]);
        continue;
      }
      if (response.statusCode == 200 ||
          isLast ||
          !_retryableStatus.contains(response.statusCode)) {
        return response;
      }
      onStatus?.call(
          '⏳ O Gemini está sobrecarregado (erro ${response.statusCode}). '
          'Tentando de novo (${attempt + 1}/${_retryDelays.length})...');
      await Future.delayed(_retryDelays[attempt]);
    }
  }

  String _friendlyError(http.Response response) {
    switch (response.statusCode) {
      case 503:
        return 'O Gemini está sobrecarregado no momento (503). A Google avisa '
            'que costuma ser temporário — tente de novo em alguns instantes.';
      case 429:
        return 'Limite de requisições do Gemini atingido (429). Espere um '
            'pouco e tente de novo.';
      default:
        return 'Erro da API (${response.statusCode}): ${response.body}';
    }
  }

  Future<GeminiTurn> _callModel(
    String currentFolderUri,
    List<FileEntry> currentFolderListing,
  ) async {
    _registerRoot(currentFolderUri);

    final response = await _postWithRetry(jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt(currentFolderUri, currentFolderListing)}
        ]
      },
      'contents': _history,
      'tools': [
        {'functionDeclarations': _functionDeclarations}
      ],
    }));

    if (response.statusCode != 200) {
      throw Exception(_friendlyError(response));
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

   
