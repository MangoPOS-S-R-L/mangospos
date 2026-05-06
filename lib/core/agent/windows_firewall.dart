// Windows Firewall helper para el agent LAN.
//
// Cuando MangoPOS comparte una impresora BT/USB en la LAN, el agent local
// escucha en TCP :4000 (ver lib/core/agent/mobile_print_agent.dart). Por
// default Windows Defender Firewall bloquea conexiones entrantes a apps
// no firmadas, asi que tablets y otros devices del business no pueden
// rutear print jobs hacia este host.
//
// Solucion: agregar una regla de Windows Firewall que permita inbound
// TCP en el puerto del agent. La operacion es idempotente — se chequea
// si la regla ya existe (sin necesidad de admin) y solo se invoca el
// comando elevado si falta. Una vez aceptada por el usuario en el primer
// arranque post-install, no vuelve a aparecer el UAC.
//
// Cancelacion del UAC: si el usuario dice "No" al prompt, addRule()
// retorna false. La app sigue funcionando normalmente para impresion
// local; solo el LAN sharing queda inhabilitado hasta que el usuario
// acepte (o agregue la regla manualmente). No se reintenta en la misma
// sesion para no spam-promptear.
//
// No-op en macOS, Linux, iOS, Android y Web: el SO maneja diferente la
// politica de firewall y es responsabilidad del operador.

import 'dart:io';

import 'package:flutter/foundation.dart';

class WindowsFirewall {
  static const String defaultRuleName = 'MangoPOS Print Agent';
  static const int defaultPort = 4000;

  // Se setea a true tras el primer addRule fallido en la sesion para evitar
  // spam de UAC si el usuario dice "No". Reset al reiniciar la app — nuevo
  // arranque, nueva chance.
  static bool _userDismissedThisSession = false;

  static void _log(String msg) {
    debugPrint('[WindowsFirewall] $msg');
  }

  /// `true` si la regla de firewall con [name] ya existe. No requiere admin.
  ///
  /// `netsh ... show rule` retorna exit code 0 cuando hay match, no-cero
  /// cuando no. Usamos el exit code en vez de parsear stdout porque el
  /// texto cambia segun idioma del SO (ES/EN/etc) y romperia el chequeo.
  static Future<bool> ruleExists({String name = defaultRuleName}) async {
    if (kIsWeb || !Platform.isWindows) return true; // n/a, no bloquea flujo
    try {
      final r = await Process.run(
        'netsh',
        ['advfirewall', 'firewall', 'show', 'rule', 'name=$name'],
        // runInShell ayuda a resolver netsh en PATH cuando se invoca desde
        // contextos donde Process.run no encuentra el binario directamente.
        runInShell: true,
      );
      return r.exitCode == 0;
    } catch (e) {
      _log('ruleExists("$name") error: $e');
      // Conservador: si no podemos chequear, asumimos que no existe para
      // que ensureRule intente crearla.
      return false;
    }
  }

  /// Intenta agregar la regla de firewall. Lanza el prompt UAC.
  ///
  /// Retorna `true` solo si la regla queda en su lugar tras el intento.
  /// Si el usuario rechaza el UAC, retorna `false` y marca el flag de
  /// sesion para no volver a promptear hasta el proximo arranque.
  static Future<bool> addRule({
    String name = defaultRuleName,
    int port = defaultPort,
  }) async {
    if (kIsWeb || !Platform.isWindows) return true;

    // PowerShell Start-Process con -Verb RunAs eleva al UAC. Pasamos los
    // argumentos a netsh como string unico — Start-Process los reparte al
    // proceso hijo. -Wait nos deja capturar el resultado; -WindowStyle
    // Hidden evita que asome la consola al usuario.
    //
    // Las comillas dobles dentro del ArgumentList se escapan con backtick
    // (` en PowerShell) porque el shell exterior ya consume un nivel de
    // quoting.
    final psCommand =
        'try { '
        'Start-Process netsh -ArgumentList '
        '"advfirewall firewall add rule name=`"$name`" '
        'dir=in action=allow protocol=TCP localport=$port" '
        '-Verb RunAs -Wait -WindowStyle Hidden -ErrorAction Stop; '
        'exit 0 '
        '} catch { exit 1 }';

    try {
      _log('intentando agregar regla "$name" puerto $port (UAC se va a abrir)…');
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psCommand],
        runInShell: true,
      );
      if (r.exitCode != 0) {
        _log(
          'powershell exit=${r.exitCode}. Probable: usuario cancelo UAC. '
          'stdout="${r.stdout}" stderr="${r.stderr}"',
        );
        _userDismissedThisSession = true;
        return false;
      }
      // Verificacion: el exit code de Start-Process puede ser 0 aunque la
      // regla no haya quedado (e.g. netsh fallo internamente). Re-chequeamos.
      final exists = await ruleExists(name: name);
      if (exists) {
        _log('regla "$name" creada exitosamente.');
      } else {
        _log('powershell exit=0 pero la regla no aparece. addRule fallo.');
        _userDismissedThisSession = true;
      }
      return exists;
    } catch (e) {
      _log('addRule("$name") error: $e');
      _userDismissedThisSession = true;
      return false;
    }
  }

  /// Garantiza que la regla exista. No-op si ya esta o si el usuario
  /// rechazo UAC en esta sesion. Idempotente — seguro de llamar en cada
  /// arranque del agent.
  ///
  /// Retorna `true` si la regla esta en su lugar al terminar.
  static Future<bool> ensureRule({
    String name = defaultRuleName,
    int port = defaultPort,
  }) async {
    if (kIsWeb || !Platform.isWindows) return true;

    if (await ruleExists(name: name)) {
      _log('regla "$name" ya existe, skip.');
      return true;
    }

    if (_userDismissedThisSession) {
      _log(
        'regla "$name" falta pero el usuario rechazo UAC en esta sesion. '
        'Skip hasta el proximo arranque.',
      );
      return false;
    }

    return await addRule(name: name, port: port);
  }
}
