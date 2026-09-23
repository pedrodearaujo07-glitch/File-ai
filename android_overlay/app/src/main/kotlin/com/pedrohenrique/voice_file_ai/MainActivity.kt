package com.pedrohenrique.voice_file_ai

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
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
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.zip.CRC32
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "voice_file_ai/files"
    private val pickFolderRequestCode = 4201
    private var pendingPickResult: Result? = null

    // Extração de texto de PDF exige inicializar o carregador de recursos do
    // PDFBox uma vez antes do primeiro uso.
    private val maxPdfPages = 500

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
            val sourceUri = Uri.parse(sourceUriStr)
            val destTreeUri = Uri.parse(destTreeUriStr)
            val sourceFile = DocumentFile.fromSingleUri(this, sourceUri)
            val destDir = DocumentFile.fromTreeUri(this, destTreeUri)

            if (sourceFile == null || destDir == null) {
                result.success(false)
                return
            }

            // Copia o conteúdo para a pasta destino e depois apaga o original.
            // (DocumentsContract.moveDocument só funciona quando ambos os
            // documentos vêm do mesmo provider/árvore; copiar+apagar é mais
            // confiável entre árvores diferentes.)
            val newFile = destDir.createFile(
                sourceFile.type ?: "application/octet-stream",
                sourceFile.name ?: "arquivo",
            ) ?: return result.success(false)

            contentResolver.openInputStream(sourceUri).use { input ->
                contentResolver.openOutputStream(newFile.uri).use { output ->
                    if (input == null || output == null) {
                        result.success(false)
                        return
                    }
                    input.copyTo(output)
                }
            }
            sourceFile.delete()
            result.success(true)
        } catch (e: Exception) {
            result.error("MOVE_FAILED", e.message, null)
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
            // "wt" trunca o arquivo antes de escrever, sobrescrevendo o conteúdo.
            contentResolver.openOutputStream(uri, "wt")?.use { output ->
                OutputStreamWriter(output).use { it.write(content) }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("WRITE_FAILED", e.message, null)
        }
    }

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

    private fun createFile(parentTreeUriStr: String, name: String, content: String, result: Result) {
        try {
            val parentDir = DocumentFile.fromTreeUri(this, Uri.parse(parentTreeUriStr))
            val newFile = parentDir?.createFile("text/plain", name)
            if (newFile == null) {
                result.success(null)
                return
            }
            contentResolver.openOutputStream(newFile.uri)?.use { output ->
                OutputStreamWriter(output).use { it.write(content) }
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
}
