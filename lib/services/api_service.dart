import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'http://10.0.2.2:8000/api'; // Laravel backend URL

  static Future<Map<String, dynamic>> login(String email, String password) async {
  try {
    final response = await http.post(
      Uri.parse('$baseUrl/login'),
      headers: {'Accept': 'application/json'},
      body: {'email': email, 'password': password},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'success': true,
        'token': data['access_token'],
        'name': data['user']['name'],
        'email': data['user']['email'],
      };
    } else {
      final data = json.decode(response.body);
      return {'success': false, 'message': data['message'] ?? 'Invalid credentials'};
    }
  } catch (e) {
    return {'success': false, 'message': e.toString()};
  }
}
}
