package com.pedrohenrique.voice_file_ai

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter

class MainActivity : FlutterActivity() {
    private val channelName = "voice_file_ai/files"
    private val pickFolderRequestCode = 4201
    private var pendingPickResult: Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                "readFile" -> readFile(call.argument("uri")!!, result)
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

    private fun readFile(uriStr: String, result: Result) {
        try {
            val uri = Uri.parse(uriStr)
            val text = contentResolver.openInputStream(uri)?.use { input ->
                BufferedReader(InputStreamReader(input)).readText()
            }
            result.success(text)
        } catch (e: Exception) {
            result.error("READ_FAILED", e.message, null)
        }
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
}
