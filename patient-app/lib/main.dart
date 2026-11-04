import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'core/api_client.dart';

const _brand = Color(0xFF238875);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.isConfigured) {
    runApp(const SetupRequiredApp());
    return;
  }
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
  );
  runApp(const PatientifyApp());
}

class PatientifyApp extends StatelessWidget {
  const PatientifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartMed',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _brand),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F8FB),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final session = snapshot.data!.session;
          if (session == null) return const SignInPage();
          return PatientHome(email: session.user.email ?? 'Signed-in patient');
        },
      ),
    );
  }
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on AuthException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  side: const BorderSide(color: Color(0xFFE8EDF0)),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(26),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.favorite_rounded, color: _brand, size: 32),
                        const SizedBox(height: 16),
                        Text(
                          'Welcome to SmartMed',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Sign in to continue to your patient app.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username],
                          decoration: const InputDecoration(labelText: 'Email'),
                          validator: (value) => value == null || !value.contains('@')
                              ? 'Enter a valid email address.'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          decoration: const InputDecoration(labelText: 'Password'),
                          validator: (value) => value == null || value.isEmpty
                              ? 'Enter your password.'
                              : null,
                          onFieldSubmitted: (_) => _busy ? null : _signIn(),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _signIn,
                          child: _busy
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Sign in securely'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PatientHome extends StatefulWidget {
  const PatientHome({required this.email, super.key});

  final String email;

  @override
  State<PatientHome> createState() => _PatientHomeState();
}

class _PatientHomeState extends State<PatientHome> {
  late final ApiClient _apiClient;
  late Future<Object?> _profile;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(
      supabase: Supabase.instance.client,
      baseUrl: AppConfig.apiBaseUrl,
    );
    _profile = _apiClient.getJson('/me');
  }

  @override
  void dispose() {
    _apiClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SmartMed'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: () async {
              try {
                await Supabase.instance.client.auth.signOut();
              } on AuthException catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(error.message)),
                  );
                }
              }
            },
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              elevation: 0,
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircleAvatar(
                      radius: 27,
                      backgroundColor: Color(0xFFE7F4F0),
                      child: Icon(Icons.health_and_safety_rounded, color: _brand),
                    ),
                    const SizedBox(height: 16),
                    Text('You’re signed in', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(widget.email, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 20),
                    FutureBuilder<Object?>(
                      future: _profile,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const CircularProgressIndicator();
                        }
                        if (snapshot.hasError) {
                          return Column(
                            children: [
                              Text(
                                'Could not load your profile: ${snapshot.error}',
                                textAlign: TextAlign.center,
                              ),
                              TextButton(
                                onPressed: () => setState(
                                  () => _profile = _apiClient.getJson('/me'),
                                ),
                                child: const Text('Try again'),
                              ),
                            ],
                          );
                        }
                        final profile = snapshot.data;
                        final name = profile is Map<String, dynamic>
                            ? profile['full_name'] as String?
                            : null;
                        return Text(
                          name == null
                              ? 'Your profile is ready. Patient features will be added here.'
                              : 'Welcome, $name. Your profile is connected to SmartMed.',
                          textAlign: TextAlign.center,
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Connected API: ${Uri.parse(AppConfig.apiBaseUrl).host}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SetupRequiredApp extends StatelessWidget {
  const SetupRequiredApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartMed setup',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _brand)),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Configure SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY using --dart-define before launching the app.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
