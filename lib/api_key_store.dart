import 'package:shared_preferences/shared_preferences.dart';

/// Guarda a chave da API do Gemini só no aparelho do usuário.
/// Nunca é enviada a lugar nenhum além da própria API do Gemini.
class ApiKeyStore {
  static const _key = 'gemini_api_key';

  static Future<String?> get() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  static Future<void> set(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value);
  }
}
