# Voice File AI

App Android que ouve um comando de voz, manda pra API do Gemini (Google) junto
com a listagem da pasta escolhida, e executa a ação que o modelo devolver
(mover, renomear, apagar, ler ou editar um arquivo) — sempre com confirmação
antes de executar.

## Como funciona

1. Você escolhe uma pasta pelo seletor do próprio Android (SAF). O app só
   consegue mexer no que estiver dentro dessa pasta.
2. Conversa normalmente — por voz (botão "Falar") ou digitando — como um chat.
   O app lembra da conversa inteira (não só do último comando), então dá pra
   corrigir ou complementar um pedido ("não, na verdade renomeia também").
3. Cada comando + a listagem atual da pasta vai pra API do Gemini com as
   "ferramentas" disponíveis (mover, apagar, editar, etc.) descritas. O
   modelo chama no máximo uma ferramenta por vez e espera o resultado antes
   de sugerir a próxima.
4. Antes de executar qualquer ação de verdade, aparece um diálogo de
   confirmação. Depois de confirmar (ou cancelar), o resultado volta pro
   modelo, que responde naturalmente no chat — tipo "Prontinho, movido!" ou
   "Sem problemas, deixei como estava."
5. Trocar de pasta começa uma conversa nova (as URIs da pasta anterior não
   valem mais).

## Primeiros passos

1. Crie um repositório novo no GitHub e suba esses arquivos (mesma pasta raiz
   com `pubspec.yaml`, `lib/`, `android_overlay/`, `.github/`).
2. Vá em **Actions** no repositório e rode o workflow "Build APK" manualmente
   (ou dê um push em `main` — ele já roda sozinho).
3. Quando terminar, baixe o APK em **Actions → (o build) → Artifacts →
   voice-file-ai-debug-apk**, extraia o zip e instale no celular.
4. Abra o app, toque no ⚙️ (configurações) e cole sua chave do Gemini (começa
   com `AIza...`). Você consegue uma **de graça, sem cartão**, em
   https://aistudio.google.com/apikey.

## Sobre a chave de API

Ela fica salva só no aparelho (SharedPreferences) e é usada apenas para
chamar a API do Gemini diretamente. Isso é ótimo pra uso pessoal — mas se um
dia você publicar esse app pra outras pessoas usarem, vale trocar por um
pequeno servidor intermediário, porque uma chave dentro de um APK pode ser
extraída por quem descompilar o app.

## Sobre o modelo e o tier gratuito

O app usa `gemini-3.1-flash-lite`, que tem tier gratuito permanente (sem
cartão) e é rápido o bastante pra esse tipo de comando curto. Os limites
exatos de requisições por minuto/dia dependem da sua conta — dá pra ver em
https://aistudio.google.com/rate-limit. Se o Google trocar o nome do modelo
no futuro, é só atualizar a constante `_model` em `lib/gemini_service.dart`.

## Limitações conhecidas (v0.1)

- Só mexe dentro da árvore de pastas escolhida pelo seletor (limitação do
  Android, não do app).
- "Mover" é implementado como copiar + apagar (mais confiável entre pastas
  diferentes do que a API nativa de mover do Android).
- Edição de arquivo é só para arquivos de texto (sobrescreve o conteúdo
  inteiro — não é uma edição parcial ainda).
- Sem suporte a subpastas aninhadas na listagem (lista só o primeiro nível
  por enquanto).
- Segurança contra loop: o app para sozinho depois de 4 ações encadeadas
  num mesmo comando (evita gasto/ação em excesso se o modelo entrar em loop).
- A conversa fica só na memória — fechar o app apaga o histórico do chat
  (a pasta escolhida também precisa ser reselecionada).

## Próximos passos sugeridos

- Navegar para dentro de subpastas.
- Confirmação por voz também ("sim"/"não"), não só toque.
- Histórico de comandos com "desfazer".
- 
