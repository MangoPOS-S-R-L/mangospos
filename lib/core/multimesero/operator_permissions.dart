// Resolución de permisos del OPERADOR, no del dispositivo.
//
// Problema que resuelve
// ─────────────────────
// En modo multimesero una tablet queda logueada con un mesero y los demás
// se identifican con su PIN al entrar a cada mesa. Pero todos los gates
// leían `sessionProvider`, o sea los permisos del usuario logueado: el
// mesero A le prestaba sus permisos a todos los que entraran después, y
// los permisos que el dueño le daba a B no se evaluaban nunca.
//
// Acá centralizamos la regla: manda quien está operando.
//
// Orden de resolución
// ───────────────────
//   1. Hay un mesero identificado por PIN CON permisos resueltos → los suyos.
//   2. Cualquier otro caso → los de la sesión del dispositivo.
//
// El paso 2 cubre lo que siempre funcionó: dispositivos de owner/admin/
// cajero (donde el flujo de PIN de mesero ni se dispara), meseros sin
// cuenta de login, y fallos de lectura al resolver los permisos del PIN.
// Ante la duda usamos la sesión — el comportamiento histórico — para no
// dejar a nadie sin poder trabajar.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/session/session_controller.dart';
import 'active_waiter_provider.dart';

/// `true` si quien está operando el dispositivo tiene [permission].
///
/// Usa `read` (no `watch`): los gates se evalúan dentro de handlers, fuera
/// del build. Para gates que viven en un `build` y deben repintar, usa
/// [watchOperatorPermission].
bool operatorHasPermission(WidgetRef ref, String permission) {
  final fromWaiter = ref.read(activeWaiterProvider)?.hasPermission(permission);
  if (fromWaiter != null) return fromWaiter;
  return ref.read(sessionProvider.notifier).hasPermission(permission);
}

/// Igual que [operatorHasPermission] pero suscribe el widget a los cambios
/// del mesero activo y de la sesión. Para usar dentro de `build`.
bool watchOperatorPermission(WidgetRef ref, String permission) {
  final fromWaiter = ref.watch(activeWaiterProvider)?.hasPermission(permission);
  if (fromWaiter != null) return fromWaiter;
  ref.watch(sessionProvider);
  return ref.read(sessionProvider.notifier).hasPermission(permission);
}

/// Variante de [operatorHasPermission] para los `Ref` de providers y
/// notifiers (los viewmodels no tienen `WidgetRef`). Misma regla.
bool operatorHasPermissionRef(Ref ref, String permission) {
  final fromWaiter = ref.read(activeWaiterProvider)?.hasPermission(permission);
  if (fromWaiter != null) return fromWaiter;
  return ref.read(sessionProvider.notifier).hasPermission(permission);
}

/// `true` si quien opera es el dueño del negocio.
///
/// Cuando hay un mesero identificado por PIN, el dueño de la sesión NO
/// cuenta: el que está operando la mesa es el mesero, y darle el bypass de
/// owner sería justamente el agujero que este módulo cierra. Sin mesero
/// identificado, vale el owner de la sesión.
bool operatorIsOwner(WidgetRef ref) {
  if (ref.read(activeWaiterProvider)?.permissions != null) return false;
  return ref.read(sessionProvider).isOwner;
}
