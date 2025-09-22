// lib/presentation/auth/login/login_view.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'login_viewmodel.dart';
import 'login_state.dart';

// --- Colores MangoPOS ---
const _orange = Color(0xFFF7941A);
const _white = Color(0xFFFFFFFF);
const _dark = Color(0xFF32363F);

class LoginView extends ConsumerStatefulWidget {
  const LoginView({super.key});
  @override
  ConsumerState<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<LoginView> {
  final _formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    // ⬇️ AHORA el provider devuelve LoginState directamente (no AsyncValue)
    final state = ref.watch(loginVmProvider); // LoginState
    final vm = ref.read(loginVmProvider.notifier);

    final data = state;
    final isLoading = state.isLoading;
    final isWide = MediaQuery.of(context).size.width >= 980;

    final formCard = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          color: _white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: _dark.withOpacity(.08)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Branding
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _orange,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Center(
                          child: Text(
                            'M',
                            style: TextStyle(
                              color: _white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'MangoPOS',
                        style: TextStyle(
                          color: _dark,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  _label('Introduce tu correo electrónico'),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: data.email,
                    style: const TextStyle(color: _dark),
                    keyboardType: TextInputType.emailAddress,
                    onChanged: vm.setEmail,
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Correo inválido'
                        : null,
                    decoration: _inputDecoration('email@tuempresa.com'),
                  ),
                  const SizedBox(height: 16),

                  _label('Contraseña'),
                  const SizedBox(height: 8),
                  _PasswordField(
                    initial: data.password,
                    onChanged: vm.setPassword,
                  ),
                  const SizedBox(height: 8),

                  Row(
                    children: [
                      Checkbox(
                        value: data.rememberMe,
                        onChanged: (v) => vm.toggleRemember(v ?? false),
                        activeColor: _orange,
                        side: BorderSide(color: _dark.withOpacity(.35)),
                      ),
                      const Text('Recuérdame', style: TextStyle(color: _dark)),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          /* TODO: recuperar contraseña */
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: _dark.withOpacity(.8),
                        ),
                        child: const Text('¿Olvidaste tu contraseña?'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _orange,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      onPressed: isLoading
                          ? null
                          : () async {
                              if (_formKey.currentState?.validate() ?? false) {
                                await vm.submit();
                                if (!mounted) return;
                                final hasError =
                                    ref.read(loginVmProvider).error !=
                                    null; // ← del estado
                                if (!hasError) context.go('/dashboard');
                              }
                            },
                      child: isLoading
                          ? const CircularProgressIndicator.adaptive(
                              valueColor: AlwaysStoppedAnimation<Color>(_white),
                            )
                          : const Text(
                              'Iniciar sesión',
                              style: TextStyle(
                                color: _white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),

                  if (state.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      state.error!,
                      style: const TextStyle(color: Colors.redAccent),
                      textAlign: TextAlign.center,
                    ),
                  ],

                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '¿Eres nuevo aquí?',
                        style: TextStyle(color: _dark.withOpacity(.8)),
                      ),
                      TextButton(
                        onPressed: () => context.go('/register'),
                        style: TextButton.styleFrom(foregroundColor: _orange),
                        child: const Text('Crea una cuenta'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: _white,
      body: SafeArea(
        child: isWide
            ? Row(
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                        child: _VideoPane(),
                      ),
                    ),
                  ),
                  Expanded(child: Center(child: formCard)),
                ],
              )
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                        child: _VideoPane(height: 220),
                      ),
                      const SizedBox(height: 16),
                      formCard,
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _label(String text) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: const TextStyle(
        color: _dark,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: _dark.withOpacity(.45)),
    filled: true,
    fillColor: _white,
    focusedBorder: _border(_orange),
    enabledBorder: _border(_dark.withOpacity(.25)),
    errorBorder: _border(Colors.redAccent),
    focusedErrorBorder: _border(Colors.redAccent),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  );

  OutlineInputBorder _border(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: 1),
  );
}

// --------------------- VIDEO PANE ---------------------
class _VideoPane extends StatefulWidget {
  final double? height;
  const _VideoPane({this.height, super.key});

  @override
  State<_VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<_VideoPane> {
  Player? _player;
  VideoController? _controller;
  String? _webViewType;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  void _initializeVideo() {
    if (kIsWeb) {
      _initializeWebVideo();
    } else {
      _initializeNativeVideo();
    }
  }

  void _initializeWebVideo() {
    // For web, we'll use a simple placeholder that can be enhanced later
    _webViewType = 'mangopos-login-video-${DateTime.now().microsecondsSinceEpoch}';
    
    // Register a basic HTML video element using a workaround
    _registerWebVideo();
    
    setState(() {
      _isInitialized = true;
    });
  }

  void _registerWebVideo() {
    // This is a simplified approach that avoids compile-time issues
    // In a real scenario, you might want to create separate web/native implementations
    if (kIsWeb && _webViewType != null) {
      // For now, we'll just mark as initialized
      // The actual web video implementation would go in a separate web-specific file
      print('Web video initialization for $_webViewType');
    }
  }

  void _initializeNativeVideo() {
    if (!kIsWeb) {
      try {
        _player = Player();
        _controller = VideoController(_player!);
        _player!
          ..open(Media('asset:///assets/videos/video_login.mp4'))
          ..setVolume(0)
          ..setPlaylistMode(PlaylistMode.loop);
        
        setState(() {
          _isInitialized = true;
        });
      } catch (e) {
        print('Error initializing native video: $e');
        setState(() {
          _isInitialized = true; // Show placeholder instead
        });
      }
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && _player != null) {
      _player?.dispose();
      _controller = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Container(
        color: _dark.withOpacity(.06),
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    Widget videoWidget;

    if (kIsWeb) {
      // For web builds, show a placeholder or use webview_flutter_web
      // You could also implement the actual HtmlElementView here if needed
      videoWidget = Container(
        color: _dark.withOpacity(.06),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_circle_outline, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'Video Player\n(Web Implementation)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    } else {
      // Desktop/mobile implementation with media_kit
      videoWidget = _controller == null
          ? Container(
              color: _dark.withOpacity(.06),
              child: const Center(
                child: Text(
                  'Video not available',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          : Video(controller: _controller!, controls: null);
    }

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: _white),
        child: videoWidget,
      ),
    );
  }
}

// ---------------- PASSWORD FIELD ----------------
class _PasswordField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;
  const _PasswordField({required this.initial, required this.onChanged});

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: widget.initial,
      style: const TextStyle(color: _dark),
      obscureText: _obscure,
      onChanged: widget.onChanged,
      validator: (v) =>
          (v == null || v.length < 6) ? 'Mínimo 6 caracteres' : null,
      decoration: InputDecoration(
        hintText: '••••••••',
        hintStyle: TextStyle(color: _dark.withOpacity(.45)),
        filled: true,
        fillColor: _white,
        focusedBorder: _b(_orange),
        enabledBorder: _b(_dark.withOpacity(.25)),
        errorBorder: _b(Colors.redAccent),
        focusedErrorBorder: _b(Colors.redAccent),
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_off : Icons.visibility,
            color: _dark.withOpacity(.7),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );
  }

  OutlineInputBorder _b(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: 1),
  );
}