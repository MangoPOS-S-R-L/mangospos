// lib/presentation/auth/login/login_view.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mangopos/core/utils/web_utils/web_utils.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'login_state.dart';
import 'login_viewmodel.dart';

const _orange = Color(0xFFF97316);
const _white = Color(0xFFFFFFFF);
const _dark = Color(0xFF32363F);

class LoginView extends ConsumerStatefulWidget {
  const LoginView({super.key});

  @override
  ConsumerState<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<LoginView> {
  @override
  Widget build(BuildContext context) {
    ref.listen<LoginState>(loginVmProvider, (prev, next) {
      if (next.needsBusinessSelection && context.mounted) {
        context.go(AppRoutes.selectBusiness);
      }
    });

    ref.listen<SessionState>(sessionProvider, (prev, next) {
      if (next.status == AuthStatus.authenticated && context.mounted) {
        final home = ref.read(sessionProvider.notifier).homeRoute;
        context.go(home);
      }
    });

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
            side: BorderSide(color: _dark.withValues(alpha: .08)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                  initial: state.password,
                  enabled: !isLoading,
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
                    onPressed: isLoading ? null : () async => vm.submit(),
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

                const SizedBox(height: 12),
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => context.go(AppRoutes.register),
                  style: TextButton.styleFrom(
                    foregroundColor: _orange,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text(
                    '¿No tienes cuenta? Registra tu negocio',
                    style: TextStyle(fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
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
                  'Ingresa desde app.mangopos.do y luego podras conectar la redirección al subdominio de cada negocio.',
                  style: TextStyle(
                    color: _dark.withValues(alpha: .65),
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),

                if (kDebugMode || kIsWeb) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  Builder(
                    builder: (context) {
                      String debugStr = 'N/A';
                      if (kIsWeb) {
                        try {
                          final href = WebUtils.href;
                          final hash = WebUtils.hash;
                          final pathname = WebUtils.pathname;
                          final search = WebUtils.search;
                          debugStr =
                              'href: $href\nhash: $hash\npath: $pathname\nsearch: $search';
                        } catch (e) {
                          debugStr = 'Error leyendo URL: $e';
                        }
                      }
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: .2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '🔍 URL DETECTADA POR FLUTTER:\n$debugStr',
                          style: const TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: Colors.blueGrey,
                          ),
                        ),
                      );
                    },
                  ),
                  const Center(
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
    hintStyle: TextStyle(color: _dark.withValues(alpha: .45)),
    filled: true,
    fillColor: _white,
    focusedBorder: _border(_orange),
    enabledBorder: _border(_dark.withValues(alpha: .25)),
    errorBorder: _border(Colors.redAccent),
    focusedErrorBorder: _border(Colors.redAccent),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  );

  OutlineInputBorder _border(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: 1),
  );
}

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
    _webViewType =
        'mangopos-login-video-${DateTime.now().microsecondsSinceEpoch}';
    _registerWebVideo();
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  void _registerWebVideo() {
    if (kIsWeb && _webViewType != null) {
      debugPrint('Web video initialization for $_webViewType');
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
      debugPrint('Error initializing native video: $e');
      if (mounted) {
        setState(() {
          _isInitialized = true;
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
        color: _dark.withValues(alpha: .06),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    Widget videoWidget;

    if (!_useNativeVideo) {
      final placeholderText = kIsWeb
          ? 'Video no disponible en Web'
          : 'Video desactivado temporalmente en Windows';
      videoWidget = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _orange.withValues(alpha: .16),
              _white,
              _dark.withValues(alpha: .08),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: _white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .08),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.storefront_rounded,
                  size: 44,
                  color: _orange,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                placeholderText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _dark,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'La pantalla de acceso seguira funcionando con fondo estatico.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _dark.withValues(alpha: .65)),
              ),
            ],
          ),
        ),
      );
    } else {
      videoWidget = _controller == null
          ? Container(
              color: _dark.withValues(alpha: .06),
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

class _PasswordField extends StatefulWidget {
  final String initial;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _PasswordField({
    required this.initial,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: widget.initial,
      enabled: widget.enabled,
      style: const TextStyle(color: _dark),
      obscureText: _obscure,
      onChanged: widget.onChanged,
      validator: (v) =>
          (v == null || v.length < 6) ? 'Minimo 6 caracteres' : null,
      decoration: InputDecoration(
        hintText: '********',
        hintStyle: TextStyle(color: _dark.withValues(alpha: .45)),
        filled: true,
        fillColor: _white,
        focusedBorder: _b(_orange),
        enabledBorder: _b(_dark.withValues(alpha: .25)),
        errorBorder: _b(Colors.redAccent),
        focusedErrorBorder: _b(Colors.redAccent),
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_off : Icons.visibility,
            color: _dark.withValues(alpha: .7),
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
