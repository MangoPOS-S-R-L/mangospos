import '../../presentation/shell/shell_destinations.dart';
import '../router/route_permissions.dart';

/// Forma del conmutador de módulos, derivada del **número de destinos que el
/// rol alcanza de verdad** (PRD §7.2).
///
/// No es una preferencia ni una constante por rol: cuando a un negocio le
/// activan un add-on, el rol cruza el umbral solo.
enum SwitcherShape {
  /// Un solo destino: el módulo llena la pantalla, no se dibuja conmutador.
  none,

  /// Barra inferior de 64 dp con todos los destinos visibles.
  bottomBar,

  /// Lanzador en hoja, agrupado por prefijo de permiso y con búsqueda.
  launcher,
}

/// Techo de la barra inferior: cinco ítems a 600 dp son 120 dp cada uno con la
/// etiqueta completa. El sexto fuerza el lanzador.
const int kBottomBarMaxDestinations = 5;

SwitcherShape switcherShapeFor(int destinations) {
  if (destinations <= 1) return SwitcherShape.none;
  if (destinations <= kBottomBarMaxDestinations) return SwitcherShape.bottomBar;
  return SwitcherShape.launcher;
}

/// Destinos que la sesión alcanza de verdad.
///
/// El permiso NO se declara aquí: sale de [ShellDestination.permissionCode] y,
/// si ese viene vacío, de [requiredPermissionForPath] — que es la misma fuente
/// que usa el `redirect` del router. Así un destino nuevo se declara una vez y
/// queda gateado solo, sin dos listas que puedan divergir.
///
/// Nota de diseño: el DDT proponía un catálogo `kAllDestinations` propio. No se
/// creó porque `kPrimaryDestinations` ya existe y además contempla feature
/// flags del negocio y add-ons de pago, que el DDT no modela. Una tercera lista
/// habría sido una fuente de verdad de más.
List<ShellDestination> destinationsFor({
  required Set<String> permissions,
  required Set<String> enabledFeatures,
  required Set<String> enabledModules,
  bool isOwner = false,
  List<ShellDestination> all = kPrimaryDestinations,
}) {
  return all.where((d) {
    // 1) Add-on que la plataforma debe haber activado para el negocio.
    if (d.requiresModule != null &&
        !enabledModules.contains(d.requiresModule)) {
      return false;
    }
    // 2) Feature flag que el dueño controla en Ajustes.
    if (d.requiresFeature != null &&
        !enabledFeatures.contains(d.requiresFeature)) {
      return false;
    }
    // 3) Permiso del rol. El owner pasa siempre, igual que en el resto de la
    //    app.
    if (isOwner) return true;
    final needed = d.permissionCode ?? requiredPermissionForPath(d.route);
    return needed == null || permissions.contains(needed);
  }).toList(growable: false);
}

/// Atajo: la forma que corresponde a esta sesión.
SwitcherShape switcherShapeForSession({
  required Set<String> permissions,
  required Set<String> enabledFeatures,
  required Set<String> enabledModules,
  bool isOwner = false,
}) =>
    switcherShapeFor(
      destinationsFor(
        permissions: permissions,
        enabledFeatures: enabledFeatures,
        enabledModules: enabledModules,
        isOwner: isOwner,
      ).length,
    );
