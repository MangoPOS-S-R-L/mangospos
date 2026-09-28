import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Etiqueta discreta con la versión instalada (ej. "v2.0.6"), anclada a la
/// esquina inferior izquierda de toda la app. Sirve para saber de un vistazo
/// qué build tiene cada equipo cuando un cliente reporta un problema.
///
/// No intercepta toques ([IgnorePointer]) para no tapar botones debajo.
class AppVersionBadge extends StatelessWidget {
  const AppVersionBadge({super.key});

  static final Future<String> _version = PackageInfo.fromPlatform()
      .then((info) => 'v${info.version}')
      .catchError((_) => '');

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomLeft,
          child: FutureBuilder<String>(
            future: _version,
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
