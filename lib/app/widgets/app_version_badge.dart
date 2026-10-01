import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Etiqueta discreta con la versión instalada (ej. "v2.0.6"), anclada a la
/// esquina inferior izquierda de toda la app. Sirve para saber de un vistazo
/// qué build tiene cada equipo cuando un cliente reporta un problema.
///
/// No intercepta toques ([IgnorePointer]) para no tapar botones debajo.
class AppVersionBadge extends StatelessWidget {
  const AppVersionBadge({super.key});

  /// Versión instalada leída del bundle (sale de `version:` en pubspec.yaml),
  /// ej. "v2.0.10". Vacía si no se pudo leer. No depende de
  /// `--dart-define=APP_VERSION`, que el build de macOS no pasa.
  static final Future<String> version = PackageInfo.fromPlatform()
      .then((info) => 'v${info.version}')
      .catchError((_) => '');

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomLeft,
          child: FutureBuilder<String>(
            future: version,
            builder: (context, snapshot) {
              final text = snapshot.data ?? '';
              if (text.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  text,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0x80000000),
                    decoration: TextDecoration.none,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Texto "MangoPOS v2.0.10" para el pie de los menús de usuario. No ocupa
/// espacio mientras carga o si la versión no se pudo leer.
class AppVersionText extends StatelessWidget {
  const AppVersionText({super.key, this.style});

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: AppVersionBadge.version,
      builder: (context, snapshot) {
        final text = snapshot.data ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        return Text('MangoPOS $text', style: style);
      },
    );
  }
}
