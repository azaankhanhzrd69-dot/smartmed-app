import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class ApiException implements Exception {
  const ApiException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({
    required SupabaseClient supabase,
    http.Client? httpClient,
    required String baseUrl,
  })  : _supabase = supabase,
        _httpClient = httpClient ?? http.Client(),
        _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final SupabaseClient _supabase;
  final http.Client _httpClient;
  final String _baseUrl;

  Future<Object?> getJson(String path) async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw const ApiException('Sign in is required.', 401);
    }
    final uri = Uri.parse('$_baseUrl/api/v1$path');
    final response = await _httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
    );
    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw ApiException(
        'The API returned an invalid response (${response.statusCode}).',
        response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = body is Map<String, dynamic> && body['detail'] is String
          ? body['detail'] as String
          : 'Request failed (${response.statusCode}).';
      throw ApiException(message, response.statusCode);
    }
    return body;
  }

  void close() => _httpClient.close();
}
