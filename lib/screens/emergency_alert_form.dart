import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class EmergencyAlertForm extends StatefulWidget {
  final String token; // Pass in the warden's auth token

  const EmergencyAlertForm({super.key, required this.token});

  @override
  EmergencyAlertFormState createState() => EmergencyAlertFormState();
}

class EmergencyAlertFormState extends State<EmergencyAlertForm> {
  final _formKey = GlobalKey<FormState>();
  String title = '';
  String message = '';
  String priority = 'medium';

  Future<void> sendEmergencyAlert() async {
    final url = Uri.parse('http://192.168.18.65:8000/api/emergency-alerts');

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'title': title,
          'message': message,
          'priority': priority,
        }),
      );

      debugPrint('Status code: ${response.statusCode}');
      debugPrint('Response body: ${response.body}');

      if (!mounted) return;

      if (response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Alert sent successfully')),
        );
        Navigator.pop(context);
      } else {
        String errorMessage = 'Unknown error';
        try {
          final responseJson = jsonDecode(response.body);
          errorMessage = responseJson['message'] ?? errorMessage;
        } catch (_) {}

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed: $errorMessage')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🚫 Error: $e')),
      );
    }
  }

  void handleSubmit() {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();
      sendEmergencyAlert();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Emergency Alert')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                decoration: const InputDecoration(labelText: 'Alert Title'),
                validator: (value) => value!.isEmpty ? 'Required' : null,
                onSaved: (value) => title = value!,
              ),
              TextFormField(
                decoration:
                    const InputDecoration(labelText: 'Message (optional)'),
                onSaved: (value) => message = value ?? '',
              ),
              DropdownButtonFormField<String>(
                value: priority,
                decoration: const InputDecoration(labelText: 'Priority'),
                items: ['low', 'medium', 'high', 'critical']
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text(p.toUpperCase()),
                        ))
                    .toList(),
                onChanged: (value) => setState(() => priority = value!),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: handleSubmit,
                child: const Text('Submit Alert'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
