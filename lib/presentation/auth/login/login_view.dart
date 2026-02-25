// lib/presentation/auth/login/login_view.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'login_viewmodel.dart';

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
  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listen for errors to show SnackBar
    ref.listen(loginVmProvider, (prev, next) {
      if (prev?.isLoading == true &&
          next.isLoading == false &&
          next.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.error!),
            backgroundColor: Colors.redAccent,
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    });

    final state = ref.watch(loginVmProvider);
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

                _label('Correo electrónico'),
                const SizedBox(height: 8),
                TextField(
                  keyboardType: TextInputType.emailAddress,
                  enabled: !isLoading,
                  onChanged: vm.setEmail,
                  decoration: _inputDecoration('tucorreo@ejemplo.com'),
                  style: const TextStyle(
                    color: _dark,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),

                _label('Contraseña'),
                const SizedBox(height: 8),
                _PasswordField(
                  initial: data.password,
                  onChanged: vm.setPassword,
                ),
                const SizedBox(height: 24),

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
                            await vm.submit();
                            if (!mounted) return;
                            final hasError =
                                ref.read(loginVmProvider).error != null;
                            if (!hasError) context.go('/dashboard');
                          },
                    child: isLoading
                        ? const CircularProgressIndicator.adaptive(
                            valueColor: AlwaysStoppedAnimation<Color>(_white),
                          )
                        : const Text(
                            'Iniciar sesion',
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

                const SizedBox(height: 8),
                Text(
                  'Si no tienes cuenta, contacta al administrador.',
                  style: TextStyle(color: _dark.withOpacity(.65), fontSize: 11),
                  textAlign: TextAlign.center,
                ),

                // DEBUG INFO
                if (kDebugMode || kIsWeb) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  Center(
                    child: Text(
                      'WASM Build - Debug Mode\nRev: 1.0.1',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 10),
                    ),
                  ),
                ],
              ],
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
  const _VideoPane({this.height});

  @override
  State<_VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<_VideoPane> {
  Player? _player;
  VideoController? _controller;
  String? _webViewType;
  bool _isInitialized = false;
  late final bool _useNativeVideo;

  @override
  void initState() {
    super.initState();
    _useNativeVideo =
        !kIsWeb && defaultTargetPlatform != TargetPlatform.windows;
    _initializeVideo();
  }

  void _initializeVideo() {
    if (!_useNativeVideo) {
      _initializeWebVideo();
    } else {
      _initializeNativeVideo();
    }
  }

  void _initializeWebVideo() {
    // For web, we'll use a simple placeholder that can be enhanced later
    _webViewType =
        'mangopos-login-video-${DateTime.now().microsecondsSinceEpoch}';

    // Register a basic HTML video element using a workaround
    _registerWebVideo();

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
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
    try {
      _player = Player();
      _controller = VideoController(_player!);
      _player!
        ..open(Media('asset:///assets/videos/video_login.mp4'))
        ..setVolume(0)
        ..setPlaylistMode(PlaylistMode.loop);

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      print('Error initializing native video: $e');
      if (mounted) {
        setState(() {
          _isInitialized = true; // Show placeholder instead
        });
      }
    }
  }

  @override
  void dispose() {
    if (_useNativeVideo) {
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
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    Widget videoWidget;

    if (!_useNativeVideo) {
      // For web/Windows builds, show a placeholder.
      final placeholderText = kIsWeb
          ? 'Video no disponible en Web'
          : 'Video no disponible en Windows';
      videoWidget = Container(
        color: _dark.withOpacity(.06),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.play_circle_outline,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                placeholderText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
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
          (v == null || v.length < 6) ? 'Minimo 6 caracteres' : null,
      decoration: InputDecoration(
        hintText: '********',
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
