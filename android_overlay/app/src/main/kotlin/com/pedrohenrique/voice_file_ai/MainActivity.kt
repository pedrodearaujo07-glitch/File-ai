package com.pedrohenrique.voice_file_ai

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.util.Xml
import androidx.documentfile.provider.DocumentFile
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import org.xmlpull.v1.XmlPullParser
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "voice_file_ai/files"
    private val pickFolderRequestCode = 4201
    private var pendingPickResult: Result? = null

    // Extração de texto de PDF exige inicializar o carregador de recursos do
    // PDFBox uma vez antes do primeiro uso.
    private val maxPdfPages = 500

    // Proteção contra OOM ao exibir e, principalmente, contra estourar o
    // limite de 20MB por requisição da API do Gemini (a imagem vai em base64,
    // ~33% maior que o arquivo original, então sobra margem pro resto do
    // pedido — prompt, histórico da conversa etc.).
    private val maxImageBytes = 8L * 1024 * 1024

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PDFBoxResourceLoader.init(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> pickFolder(result)
                "listFiles" -> listFiles(call.argument("treeUri")!!, result)
                "moveFile" -> moveFile(
                    call.argument("sourceUri")!!,
                    call.argument("destTreeUri")!!,
                    result,
                )
                "copyItem" -> copyItem(
                    call.argument("sourceUri")!!,
                    call.argument("destTreeUri")!!,
                    result,
                )
                "renameFile" -> renameFile(call.argument("uri")!!, call.argument("newName")!!, result)
                "deleteFile" -> deleteFile(call.argument("uri")!!, result)
                "readFile" -> readFile(call, result)
                "writeFile" -> writeFile(call.argument("uri")!!, call.argument("content")!!, result)
                "createFolder" -> createFolder(
                    call.argument("parentTreeUri")!!,
                    call.argument("name")!!,
                    result,
                )
                "createFile" -> createFile(
                    call.argument("parentTreeUri")!!,
                    call.argument("name")!!,
                    call.argument("content")!!,
                    result,
                )
                "compareWithZipBackup" -> compareWithZipBackup(
                    call.argument("zipUri")!!,
                    call.argument("currentTreeUri")!!,
                    result,
                )
                "readImageBytes" -> readImageBytes(call.argument("uri")!!, result)
                "createZip" -> createZip(
                    call.argument("itemUris")!!,
                    call.argument("destTreeUri")!!,
                    call.argument("name")!!,
                    result,
                )
                "extractZip" -> extractZip(
                    call.argument("zipUri")!!,
                    call.argument("destTreeUri")!!,
                    result,
                )
                "listGrantedRoots" -> listGrantedRoots(result)
                "printFile" -> printFile(call.argument("uri")!!, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pickFolder(result: Result) {
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        startActivityForResult(intent, pickFolderRequestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickFolderRequestCode) return

        val treeUri = data?.data
        if (resultCode == Activity.RESULT_OK && treeUri != null) {
            // Guarda a permissão para poder acessar essa pasta depois, mesmo
            // após o app ser fechado e reaberto.
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            pendingPickResult?.success(treeUri.toString())
        } else {
            pendingPickResult?.success(null)
        }
        pendingPickResult = null
    }

    private fun listFiles(treeUriStr: String, result: Result) {
        val treeUri = Uri.parse(treeUriStr)
        val dir = DocumentFile.fromTreeUri(this, treeUri)
        if (dir == null || !dir.isDirectory) {
            result.error("NOT_A_DIRECTORY", "URI não é uma pasta válida", null)
            return
        }
        val entries = dir.listFiles().map { f ->
            mapOf(
                "uri" to f.uri.toString(),
                "name" to (f.name ?: "(sem nome)"),
                "isDirectory" to f.isDirectory,
                // O Android (SAF) só guarda a data de última modificação — não
                // existe uma coluna de "data de criação" nesse tipo de provider.
                "lastModified" to f.lastModified(),
            )
        }
        result.success(entries)
    }

    private fun moveFile(sourceUriStr: String, destTreeUriStr: String, result: Result) {
        try {
            val source = DocumentFile.fromTreeUri(this, Uri.parse(sourceUriStr))
            val destDir = DocumentFile.fromTreeUri(this, Uri.parse(destTreeUriStr))
            if (source == null || destDir == null) {
                result.success(false)
                return
            }
            // Copia (arquivo OU pasta inteira, recursivamente) pra pasta
            // destino e só depois apaga a origem. (DocumentsContract.moveDocument
            // só funciona quando os dois documentos vêm da mesma árvore; copiar
            // + apagar é mais confiável entre árvores diferentes.)
            copyRecursive(source, destDir)
            result.success(source.delete())
        } catch (e: Exception) {
            result.error("MOVE_FAILED", e.message, null)
        }
    }

    /// Copia um arquivo ou pasta (recursivamente) pra dentro de uma pasta de
    /// destino, sem apagar a origem.
    private fun copyItem(sourceUriStr: String, destTreeUriStr: String, result: Result) {
        try {
            val source = DocumentFile.fromTreeUri(this, Uri.parse(sourceUriStr))
                ?: throw Exception("Não consegui abrir o item de origem.")
            val destDir = DocumentFile.fromTreeUri(this, Uri.parse(destTreeUriStr))
                ?: throw Exception("Não consegui abrir a pasta de destino.")
            copyRecursive(source, destDir)
            result.success(true)
        } catch (e: Exception) {
            result.error("COPY_FAILED", e.message, null)
        }
    }

    /// Copia `source` (arquivo ou pasta) pra dentro de `destParent`. Se for
    /// pasta, recria a subpasta e copia tudo dentro dela também.
    private fun copyRecursive(source: DocumentFile, destParent: DocumentFile) {
        val name = source.name ?: "item"
        if (source.isDirectory) {
            val newDir = destParent.findFile(name)?.takeIf { it.isDirectory }
                ?: destParent.createDirectory(name)
                ?: throw Exception("Não consegui criar a subpasta $name.")
            for (child in source.listFiles()) {
                copyRecursive(child, newDir)
            }
            return
        }
        val mime = source.type ?: guessMimeType(name)
        val newFile = destParent.createFile(mime, name)
            ?: throw Exception("Não consegui criar o arquivo $name.")
        contentResolver.openInputStream(source.uri)?.use { input ->
            contentResolver.openOutputStream(newFile.uri)?.use { output -> input.copyTo(output) }
        }
    }

    private fun renameFile(uriStr: String, newName: String, result: Result) {
        try {
            val file = DocumentFile.fromSingleUri(this, Uri.parse(uriStr))
            result.success(file?.renameTo(newName) ?: false)
        } catch (e: Exception) {
            result.error("RENAME_FAILED", e.message, null)
        }
    }

    private fun deleteFile(uriStr: String, result: Result) {
        try {
            val file = DocumentFile.fromSingleUri(this, Uri.parse(uriStr))
            result.success(file?.delete() ?: false)
        } catch (e: Exception) {
            result.error("DELETE_FAILED", e.message, null)
        }
    }

    private fun readFile(call: MethodCall, result: Result) {
        try {
            val uri = Uri.parse(call.argument<String>("uri")!!)
            val name = DocumentFile.fromSingleUri(this, uri)?.name ?: ""
            // Um "int" do Dart pode chegar aqui como Integer OU Long,
            // dependendo do valor — lê como Number pra nunca dar
            // ClassCastException, seja qual for o caso.
            fun intArg(key: String): Int? = (call.argument<Any>(key) as? Number)?.toInt()
            val startLine = intArg("startLine")
            val endLine = intArg("endLine")
            val startPage = intArg("startPage")
            val endPage = intArg("endPage")
            val text = when {
                name.endsWith(".pdf", ignoreCase = true) -> readPdfText(uri, startPage, endPage)
                name.endsWith(".docx", ignoreCase = true) -> readDocxText(uri)
                else -> readPlainText(uri, startLine, endLine)
            }
            result.success(text)
        } catch (e: Exception) {
            result.error("READ_FAILED", e.message, null)
        }
    }

    /// Lê um arquivo de texto simples. Sem faixa, lê tudo de uma vez (como
    /// antes). Com startLine/endLine, lê linha por linha e para assim que
    /// passa de endLine — nunca guarda o arquivo inteiro na memória de uma
    /// vez, só o trecho pedido (importante pra arquivos muito grandes).
    private fun readPlainText(uri: Uri, startLine: Int?, endLine: Int?): String {
        val input = contentResolver.openInputStream(uri)
            ?: throw Exception("Não consegui abrir o arquivo.")
        input.use { stream ->
            val reader = BufferedReader(InputStreamReader(stream))
            if (startLine == null && endLine == null) {
                return reader.readText()
            }
            val from = (startLine ?: 1).coerceAtLeast(1)
            val to = endLine ?: Int.MAX_VALUE
            val sb = StringBuilder()
            var lineNumber = 0
            var line = reader.readLine()
            while (line != null) {
                lineNumber++
                if (lineNumber > to) break
                if (lineNumber >= from) {
                    if (sb.isNotEmpty()) sb.append('\n')
                    sb.append(line)
                }
                line = reader.readLine()
            }
            return sb.toString()
        }
    }

    /// Extrai o texto de um PDF com o PDFBox-Android. Sem faixa, processa só
    /// as primeiras maxPdfPages páginas (proteção contra PDFs enormes). Com
    /// startPage/endPage, processa só essa faixa (limitada ao mesmo teto),
    /// sem precisar extrair o documento inteiro.
    private fun readPdfText(uri: Uri, startPage: Int?, endPage: Int?): String {
        val input = contentResolver.openInputStream(uri)
            ?: throw Exception("Não consegui abrir o arquivo.")
        input.use { stream ->
            PDDocument.load(stream).use { document ->
                val total = document.numberOfPages
                val from = (startPage ?: 1).coerceIn(1, total)
                var to = (endPage ?: total).coerceIn(from, total)
                if (to - from + 1 > maxPdfPages) {
                    to = from + maxPdfPages - 1
                }
                val stripper = PDFTextStripper()
                stripper.startPage = from
                stripper.endPage = to
                return stripper.getText(document)
            }
        }
    }

    /// Um .docx é um zip com o texto em word/document.xml. Em vez de trazer
    /// uma biblioteca inteira de Word (pesada e problemática no Android), lê
    /// esse XML diretamente: cada <w:p> vira uma quebra de linha, <w:t> é o
    /// texto de fato, e <w:tab>/<w:br> viram tabulação/quebra de linha.
    private fun readDocxText(uri: Uri): String {
        val input = contentResolver.openInputStream(uri)
            ?: throw Exception("Não consegui abrir o arquivo.")
        input.use { stream ->
            ZipInputStream(stream).use { zip ->
                var entry = zip.nextEntry
                while (entry != null) {
                    if (entry.name == "word/document.xml") {
                        return extractTextFromDocumentXml(zip)
                    }
                    entry = zip.nextEntry
                }
            }
        }
        throw Exception("Não encontrei texto dentro do .docx (o arquivo pode estar corrompido).")
    }

    private fun extractTextFromDocumentXml(input: InputStream): String {
        val parser = Xml.newPullParser()
        parser.setInput(input, "UTF-8")
        val sb = StringBuilder()
        var insideText = false
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "w:p" -> if (sb.isNotEmpty()) sb.append('\n')
                    "w:tab" -> sb.append('\t')
                    "w:br", "w:cr" -> sb.append('\n')
                    "w:t" -> insideText = true
                }
                XmlPullParser.TEXT -> if (insideText) sb.append(parser.text)
                XmlPullParser.END_TAG -> if (parser.name == "w:t") insideText = false
            }
            event = parser.next()
        }
        return sb.toString()
    }

    private fun writeFile(uriStr: String, content: String, result: Result) {
        try {
            val uri = Uri.parse(uriStr)
            val name = DocumentFile.fromSingleUri(this, uri)?.name ?: ""
            when {
                name.endsWith(".pdf", ignoreCase = true) ->
                    contentResolver.openOutputStream(uri, "wt")?.use { out -> writePdfPages(out, content) }
                name.endsWith(".docx", ignoreCase = true) ->
                    contentResolver.openOutputStream(uri, "wt")?.use { out -> writeDocxZip(out, content) }
                else ->
                    // "wt" trunca o arquivo antes de escrever, sobrescrevendo o conteúdo.
                    contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        OutputStreamWriter(output).use { it.write(content) }
                    }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("WRITE_FAILED", e.message, null)
        }
    }

    /// Desenha o texto como páginas de PDF simples (uma fonte, sem imagens ou
    /// tabelas) usando a API de PDF do próprio Android — sem precisar de uma
    /// fonte customizada, ao contrário de escrever PDF pelo PDFBox.
    private fun writePdfPages(output: OutputStream, content: String) {
        val pageWidth = 595 // A4 em pontos, ~72dpi
        val pageHeight = 842
        val margin = 48f
        val paint = Paint().apply {
            textSize = 12f
            color = Color.BLACK
        }
        val lineHeight = paint.textSize * 1.4f
        val maxLinesPerPage = ((pageHeight - margin * 2) / lineHeight).toInt().coerceAtLeast(1)
        val wrappedLines = wrapTextToLines(content, paint, pageWidth - margin * 2)

        val pdf = PdfDocument()
        var lineIndex = 0
        var pageNumber = 1
        do {
            val pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber).create()
            val page = pdf.startPage(pageInfo)
            var y = margin + paint.textSize
            var linesOnPage = 0
            while (lineIndex < wrappedLines.size && linesOnPage < maxLinesPerPage) {
                page.canvas.drawText(wrappedLines[lineIndex], margin, y, paint)
                y += lineHeight
                lineIndex++
                linesOnPage++
            }
            pdf.finishPage(page)
            pageNumber++
        } while (lineIndex < wrappedLines.size)
        pdf.writeTo(output)
        pdf.close()
    }

    /// Quebra o texto em linhas que cabem na largura disponível, respeitando
    /// quebras de linha (\n) já existentes no texto.
    private fun wrapTextToLines(text: String, paint: Paint, maxWidth: Float): List<String> {
        val result = mutableListOf<String>()
        for (paragraph in text.split("\n")) {
            if (paragraph.isEmpty()) {
                result.add("")
                continue
            }
            var current = StringBuilder()
            for (word in paragraph.split(" ")) {
                val candidate = if (current.isEmpty()) word else "$current $word"
                if (paint.measureText(candidate) > maxWidth && current.isNotEmpty()) {
                    result.add(current.toString())
                    current = StringBuilder(word)
                } else {
                    current = StringBuilder(candidate)
                }
            }
            result.add(current.toString())
        }
        return result
    }

    /// Grava um .docx mínimo (só texto corrido, um parágrafo por linha) — os
    /// três arquivos que todo leitor de OOXML espera encontrar num Word válido.
    private fun writeDocxZip(output: OutputStream, content: String) {
        ZipOutputStream(output).use { zip ->
            zip.putNextEntry(ZipEntry("[Content_Types].xml"))
            zip.write(docxContentTypesXml.toByteArray(Charsets.UTF_8))
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("_rels/.rels"))
            zip.write(docxRelsXml.toByteArray(Charsets.UTF_8))
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("word/document.xml"))
            zip.write(buildDocxDocumentXml(content).toByteArray(Charsets.UTF_8))
            zip.closeEntry()
        }
    }

    private fun buildDocxDocumentXml(content: String): String {
        val sb = StringBuilder()
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>")
        sb.append("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">")
        sb.append("<w:body>")
        for (paragraph in content.split("\n")) {
            sb.append("<w:p><w:r><w:t xml:space=\"preserve\">")
            sb.append(escapeXml(paragraph))
            sb.append("</w:t></w:r></w:p>")
        }
        sb.append("<w:sectPr/></w:body></w:document>")
        return sb.toString()
    }

    private fun escapeXml(s: String): String =
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    private val docxContentTypesXml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"""

    private val docxRelsXml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"""

    private fun createFolder(parentTreeUriStr: String, name: String, result: Result) {
        try {
            val parentDir = DocumentFile.fromTreeUri(this, Uri.parse(parentTreeUriStr))
            val newDir = parentDir?.createDirectory(name)
            // null costuma significar que já existe algo com esse nome ali.
            result.success(newDir?.uri?.toString())
        } catch (e: Exception) {
            result.error("CREATE_FOLDER_FAILED", e.message, null)
        }
    }

    /// Cria um arquivo novo. O formato é escolhido pela extensão do nome:
    /// .pdf e .docx são gerados de verdade (texto simples, sem formatação
    /// rica); qualquer outra extensão vira um arquivo de texto comum.
    private fun createFile(parentTreeUriStr: String, name: String, content: String, result: Result) {
        try {
            val parentDir = DocumentFile.fromTreeUri(this, Uri.parse(parentTreeUriStr))
            val mime = when {
                name.endsWith(".pdf", ignoreCase = true) -> "application/pdf"
                name.endsWith(".docx", ignoreCase = true) ->
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                else -> "text/plain"
            }
            val newFile = parentDir?.createFile(mime, name)
            if (newFile == null) {
                result.success(null)
                return
            }
            contentResolver.openOutputStream(newFile.uri)?.use { output ->
                when {
                    name.endsWith(".pdf", ignoreCase = true) -> writePdfPages(output, content)
                    name.endsWith(".docx", ignoreCase = true) -> writeDocxZip(output, content)
                    else -> OutputStreamWriter(output).use { it.write(content) }
                }
            }
            result.success(newFile.uri.toString())
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message, null)
        }
    }

    /// Compara os arquivos atuais de uma pasta com o conteúdo de um backup
    /// .zip, por caminho + tamanho + CRC32 (não só pelo nome — um arquivo do
    /// mesmo tamanho mas conteúdo diferente também conta como alterado).
    /// content:// não dá acesso aleatório, então copia o zip pra um arquivo
    /// temporário no cache do app antes de abrir com ZipFile (mais confiável
    /// que ZipInputStream, que só preenche crc/size depois de ler cada
    /// entrada inteira).
    private fun compareWithZipBackup(zipUriStr: String, currentTreeUriStr: String, result: Result) {
        var tempFile: File? = null
        try {
            // Usa um val (não a var tempFile) nas operações de arquivo abaixo,
            // pra nunca depender de smart-cast numa variável mutável — tempFile
            // só existe pra garantir a limpeza no finally.
            val tmp = File(cacheDir, "backup_compare_${System.currentTimeMillis()}.zip")
            tempFile = tmp
            contentResolver.openInputStream(Uri.parse(zipUriStr))?.use { input ->
                FileOutputStream(tmp).use { output -> input.copyTo(output) }
            } ?: throw Exception("Não consegui abrir o arquivo .zip.")

            val zipEntries = mutableMapOf<String, Pair<Long, Long>>()
            ZipFile(tmp).use { zf ->
                for (e in zf.entries()) {
                    if (!e.isDirectory) zipEntries[e.name] = Pair(e.size, e.crc)
                }
            }

            val rootDoc = DocumentFile.fromTreeUri(this, Uri.parse(currentTreeUriStr))
                ?: throw Exception("Não consegui abrir a pasta atual.")
            val currentEntries = mutableMapOf<String, Pair<Long, Long>>()
            collectCurrentFiles(rootDoc, "", currentEntries)

            val added = mutableListOf<String>()
            val removed = mutableListOf<String>()
            val changed = mutableListOf<String>()
            var unchanged = 0
            val allPaths = zipEntries.keys + currentEntries.keys
            for (path in allPaths) {
                val inZip = zipEntries[path]
                val inCurrent = currentEntries[path]
                when {
                    inZip == null -> added.add(path)
                    inCurrent == null -> removed.add(path)
                    inZip == inCurrent -> unchanged++
                    else -> changed.add(path)
                }
            }
            result.success(
                mapOf(
                    "added" to added.sorted(),
                    "removed" to removed.sorted(),
                    "changed" to changed.sorted(),
                    "unchanged" to unchanged,
                )
            )
        } catch (e: Exception) {
            result.error("COMPARE_FAILED", e.message, null)
        } finally {
            tempFile?.delete()
        }
    }

    /// Percorre a árvore atual calculando (tamanho, CRC32) de cada arquivo,
    /// com o caminho relativo à raiz — pra comparar com as entradas do zip.
    private fun collectCurrentFiles(
        dir: DocumentFile,
        prefix: String,
        out: MutableMap<String, Pair<Long, Long>>,
    ) {
        for (f in dir.listFiles()) {
            val path = if (prefix.isEmpty()) (f.name ?: "") else "$prefix/${f.name}"
            if (f.isDirectory) {
                collectCurrentFiles(f, path, out)
                continue
            }
            val crc = CRC32()
            contentResolver.openInputStream(f.uri)?.use { input ->
                val buffer = ByteArray(8192)
                var read = input.read(buffer)
                while (read >= 0) {
                    crc.update(buffer, 0, read)
                    read = input.read(buffer)
                }
            }
            out[path] = Pair(f.length(), crc.value)
        }
    }

    /// Lê os bytes de uma imagem pra exibir na tela do app (não a interpreta
    /// de forma alguma — só entrega os bytes brutos pro Flutter desenhar).
    private fun readImageBytes(uriStr: String, result: Result) {
        try {
            val uri = Uri.parse(uriStr)
            val size = DocumentFile.fromSingleUri(this, uri)?.length() ?: -1
            if (size > maxImageBytes) {
                throw Exception(
                    "Imagem grande demais pra exibir e enviar " +
                        "(${size / 1024 / 1024}MB, limite ${maxImageBytes / 1024 / 1024}MB)."
                )
            }
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw Exception("Não consegui abrir a imagem.")
            result.success(bytes)
        } catch (e: Exception) {
            result.error("READ_IMAGE_FAILED", e.message, null)
        }
    }

    /// Compacta uma lista de arquivos/pastas (URIs, de qualquer árvore já
    /// autorizada) num novo .zip dentro da pasta de destino.
    private fun createZip(itemUris: List<String>, destTreeUriStr: String, name: String, result: Result) {
        try {
            val destDir = DocumentFile.fromTreeUri(this, Uri.parse(destTreeUriStr))
                ?: throw Exception("Não consegui abrir a pasta de destino.")
            val newFile = destDir.createFile("application/zip", name)
                ?: throw Exception("Não consegui criar o arquivo .zip (nome já existe?).")
            contentResolver.openOutputStream(newFile.uri)?.use { out ->
                ZipOutputStream(out).use { zip ->
                    for (uriStr in itemUris) {
                        val doc = DocumentFile.fromTreeUri(this, Uri.parse(uriStr)) ?: continue
                        addToZip(zip, doc, doc.name ?: "arquivo")
                    }
                }
            }
            result.success(newFile.uri.toString())
        } catch (e: Exception) {
            result.error("CREATE_ZIP_FAILED", e.message, null)
        }
    }

    private fun addToZip(zip: ZipOutputStream, doc: DocumentFile, path: String) {
        if (doc.isDirectory) {
            for (child in doc.listFiles()) {
                addToZip(zip, child, "$path/${child.name}")
            }
            return
        }
        zip.putNextEntry(ZipEntry(path))
        contentResolver.openInputStream(doc.uri)?.use { input -> input.copyTo(zip) }
        zip.closeEntry()
    }

    /// Extrai todo o conteúdo de um .zip dentro de uma pasta de destino,
    /// recriando a estrutura de subpastas que o zip tiver.
    private fun extractZip(zipUriStr: String, destTreeUriStr: String, result: Result) {
        try {
            val destDir = DocumentFile.fromTreeUri(this, Uri.parse(destTreeUriStr))
                ?: throw Exception("Não consegui abrir a pasta de destino.")
            val input = contentResolver.openInputStream(Uri.parse(zipUriStr))
                ?: throw Exception("Não consegui abrir o .zip.")
            var count = 0
            input.use { stream ->
                ZipInputStream(stream).use { zip ->
                    var entry = zip.nextEntry
                    while (entry != null) {
                        if (!entry.isDirectory) {
                            val target = ensurePath(destDir, entry.name)
                            contentResolver.openOutputStream(target.uri, "wt")?.use { out ->
                                zip.copyTo(out)
                            }
                            count++
                        }
                        entry = zip.nextEntry
                    }
                }
            }
            result.success(count)
        } catch (e: Exception) {
            result.error("EXTRACT_ZIP_FAILED", e.message, null)
        }
    }

    /// Garante que as subpastas de um caminho tipo "a/b/c.txt" existam dentro
    /// de `root`, criando o que faltar, e devolve (criando se preciso) o
    /// arquivo final.
    private fun ensurePath(root: DocumentFile, path: String): DocumentFile {
        val parts = path.split("/").filter { it.isNotEmpty() }
        var dir = root
        for (i in 0 until parts.size - 1) {
            val existing = dir.findFile(parts[i])
            dir = if (existing != null && existing.isDirectory) {
                existing
            } else {
                dir.createDirectory(parts[i])
                    ?: throw Exception("Não consegui criar a subpasta ${parts[i]}.")
            }
        }
        val fileName = parts.last()
        val existingFile = dir.findFile(fileName)
        if (existingFile != null) return existingFile
        return dir.createFile(guessMimeType(fileName), fileName)
            ?: throw Exception("Não consegui criar o arquivo $fileName.")
    }

    private fun guessMimeType(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "txt", "json", "mcmeta", "md", "lang" -> "text/plain"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            else -> "application/octet-stream"
        }
    }

    /// Todas as pastas às quais o usuário já deu acesso (não só a atual) —
    /// o Android persiste essas permissões entre sessões automaticamente.
    private fun listGrantedRoots(result: Result) {
        try {
            val uris = contentResolver.persistedUriPermissions
                .filter { it.isReadPermission }
                .map { it.uri.toString() }
            result.success(uris)
        } catch (e: Exception) {
            result.error("LIST_ROOTS_FAILED", e.message, null)
        }
    }

    /// Imprime um arquivo usando o Print Framework do Android, que abre a
    /// caixa de diálogo padrão do sistema: lá o usuário escolhe a impressora
    /// (inclusive impressoras na mesma rede Wi-Fi, se houver um serviço de
    /// impressão ativo — ex.: "Serviço de impressão padrão" do Android) e
    /// confirma. O app não fala com a impressora diretamente; quem cuida da
    /// descoberta na rede e do envio é o próprio sistema.
    private fun printFile(uriStr: String, result: Result) {
        try {
            val uri = Uri.parse(uriStr)
            val name = DocumentFile.fromSingleUri(this, uri)?.name ?: "documento"
            val ext = name.substringAfterLast('.', "").lowercase()

            // O Android só sabe imprimir PDF/imagem nativamente — qualquer
            // outro tipo (texto, .docx) vira um PDF primeiro, reaproveitando
            // o mesmo gerador usado por create_file/write_file.
            val pdfBytes: ByteArray = when (ext) {
                "pdf" -> contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw Exception("Não consegui abrir o arquivo.")
                "png", "jpg", "jpeg", "gif", "bmp", "webp" -> {
                    val imageBytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        ?: throw Exception("Não consegui abrir a imagem.")
                    imageBytesToPdfBytes(imageBytes)
                }
                "docx" -> {
                    val buffer = ByteArrayOutputStream()
                    writePdfPages(buffer, readDocxText(uri))
                    buffer.toByteArray()
                }
                else -> {
                    val text = contentResolver.openInputStream(uri)?.use { input ->
                        BufferedReader(InputStreamReader(input)).readText()
                    } ?: ""
                    val buffer = ByteArrayOutputStream()
                    writePdfPages(buffer, text)
                    buffer.toByteArray()
                }
            }

            val printManager = getSystemService(Context.PRINT_SERVICE) as PrintManager
            val adapter = object : PrintDocumentAdapter() {
                override fun onLayout(
                    oldAttributes: PrintAttributes?,
                    newAttributes: PrintAttributes?,
                    cancellationSignal: CancellationSignal?,
                    callback: LayoutResultCallback?,
                    extras: Bundle?,
                ) {
                    if (cancellationSignal?.isCanceled == true) {
                        callback?.onLayoutCancelled()
                        return
                    }
                    val info = PrintDocumentInfo.Builder(name)
                        .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                        .build()
                    callback?.onLayoutFinished(info, true)
                }

                override fun onWrite(
                    pages: Array<out PageRange>?,
                    destination: ParcelFileDescriptor?,
                    cancellationSignal: CancellationSignal?,
                    callback: WriteResultCallback?,
                ) {
                    try {
                        FileOutputStream(destination?.fileDescriptor).use { out ->
                            out.write(pdfBytes)
                        }
                        callback?.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                    } catch (e: Exception) {
                        callback?.onWriteFailed(e.message)
                    }
                }
            }
            printManager.print(name, adapter, PrintAttributes.Builder().build())
            result.success(true)
        } catch (e: Exception) {
            result.error("PRINT_FAILED", e.message, null)
        }
    }

    /// Desenha uma imagem numa única página de PDF (redimensionada pra caber),
    /// pra poder imprimir imagens pelo mesmo caminho que documentos.
    private fun imageBytesToPdfBytes(imageBytes: ByteArray): ByteArray {
        val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: throw Exception("Não consegui abrir essa imagem.")
        val pageWidth = 595
        val pageHeight = 842
        val margin = 24f
        val pdf = PdfDocument()
        val pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, 1).create()
        val page = pdf.startPage(pageInfo)
        val availableWidth = pageWidth - margin * 2
        val availableHeight = pageHeight - margin * 2
        val scale = minOf(availableWidth / bitmap.width, availableHeight / bitmap.height)
        val drawWidth = bitmap.width * scale
        val drawHeight = bitmap.height * scale
        val left = (pageWidth - drawWidth) / 2f
        val top = (pageHeight - drawHeight) / 2f
        page.canvas.drawBitmap(bitmap, null, RectF(left, top, left + drawWidth, top + drawHeight), null)
        pdf.finishPage(page)
        val buffer = ByteArrayOutputStream()
        pdf.writeTo(buffer)
        pdf.close()
        bitmap.recycle()
        return buffer.toByteArray()
    }
}
