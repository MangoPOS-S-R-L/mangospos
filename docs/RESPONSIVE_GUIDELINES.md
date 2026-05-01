# Responsive Guidelines (PRD 6)

Reglas para que cualquier pantalla nueva o refactor en MangoPOS sea
instalable en hardware POS estándar (1280-3840 px ancho × 720-2160 alto)
sin overflows, botones cortados o touch targets chicos.

> Si vas a tocar UI, leé esto primero. Cubre breakpoints, tokens,
> modales, touch targets y los anti-patterns más comunes que rompen
> instalaciones en compact (1366×768 / 1920×1080@150% scaling).

---

## TL;DR

1. Usá `MediaQuery.sizeOf(context)`. **Nunca** `physicalSize` ni
   `view.physicalSize`. El lint script de CI te lo va a frenar.
2. Para layout adaptativo: `Breakpoints.isCompact(context)` (<1366) /
   `Breakpoints.isRegular(context)` / `Breakpoints.isWide(context)`.
3. Para tipografía: `FontSizes.body` (mínimo 14 pt) /
   `FontSizes.button` / `FontSizes.title`. **Nunca** hardcodear `12` u
   otros valores chicos en pantallas críticas.
4. Para spacing: `Insets.sm/md/lg/xl`. Usá `Insets.adaptive(context, base)`
   cuando quieras que reduzca 15% en compact.
5. Para touch targets: `TouchTargets.minSize` (44 px), `comfortable`
   (48 px), `primary` (56 px). Cualquier widget tappable debe respetar
   el mínimo aunque el ícono visual sea más chico.
6. Para modales: usá `MangoModal.showAdaptive(context, type, builder)`
   con el `MangoModalType` correcto. **Nunca** definas `Dialog`
   directamente con `insetPadding` y `ConstrainedBox` ad-hoc.
7. Para alturas con texto: `IntrinsicHeight` o `minHeight` —
   **nunca** `height: X` literal. Permite que `textScaler` 1.3× no
   recorte texto.

Detalle abajo.

---

## Breakpoints

```dart
import 'package:mangopos/app/theme/breakpoints.dart';

if (Breakpoints.isCompact(context)) {
  // <1366 px: sidebar colapsado, modales fullscreen, padding reducido
}

// O selector tipado:
final cols = Breakpoints.select(
  context,
  compact: 3,
  regular: 4,
  wide: 5,
);
```

**Definiciones**:
- **Compact** = `width < 1366` — 1280×720, 1366×768@100 %, 1920×1080@150 %.
- **Regular** = `1366 ≤ width < 1920` — laptops y monitores POS estándar.
- **Wide** = `width ≥ 1920` — monitores desktop grandes.

El cascadeo con Windows DPI scaling es automático: el SO ya entrega
píxeles lógicos. No necesitás código adicional para que un 1920×1080 al
150 % se trate como compact (sale ~1280 lógicos).

---

## Tokens

### Spacing

```dart
import 'package:mangopos/app/theme/sizes.dart';

Padding(padding: EdgeInsets.all(Insets.md))            // 16 px
Padding(padding: EdgeInsets.all(Insets.adaptive(context, Insets.lg)))
// = 24 en regular/wide, 20 (24 × 0.85 redondeado) en compact
```

| Token | px |
|---|---|
| `Insets.xs` | 4 |
| `Insets.sm` | 8 |
| `Insets.md` | 16 |
| `Insets.lg` | 24 |
| `Insets.xl` | 32 |
| `Insets.xxl` | 48 |

### Tipografía

```dart
Text('Producto', style: TextStyle(fontSize: FontSizes.body))
```

| Token | px | Uso |
|---|---|---|
| `FontSizes.caption` | 12 | **Nunca en flujos transaccionales.** Solo labels secundarios. |
| `FontSizes.body` | 14 | Mínimo absoluto en pantallas críticas. |
| `FontSizes.subtitle` | 16 | Subtítulos, valores en cards. |
| `FontSizes.button` | 16 | Botones primarios. |
| `FontSizes.title` | 20 | Headers de pantalla/modal. |
| `FontSizes.display` | 28 | KPIs, totales destacados. |
| `FontSizes.displayXl` | 36 | Totales del cobro, cierre de caja. |

### Touch targets

```dart
ElevatedButton(
  style: ElevatedButton.styleFrom(
    minimumSize: const Size(0, TouchTargets.primary), // 56 px
  ),
  ...
)

// Para iconos chicos con área activa generosa:
SizedBox(
  width: TouchTargets.minSize,    // 44 px
  height: TouchTargets.minSize,
  child: IconButton(...),
)
```

| Token | px | Cuándo |
|---|---|---|
| `TouchTargets.minSize` | 44 | Mínimo absoluto, cualquier elemento tappable. |
| `TouchTargets.comfortable` | 48 | POS táctil de uso rápido (kitchen, cobro). |
| `TouchTargets.primary` | 56 | Acciones primarias (Confirmar pago, Enviar a cocina). |

---

## Modales

**Una sola entrada**: `MangoModal.showAdaptive` o `MangoModal.wrap`.

```dart
import 'package:mangopos/app/widgets/mango_modal.dart';

MangoModal.showAdaptive(
  context: context,
  type: MangoModalType.form,    // o .confirmation, .picker, .wizard
  builder: (ctx) => MyModalContent(),
);
```

| Tipo | Compact | Regular/Wide |
|---|---|---|
| `confirmation` | Card centrada ~400 px | Card centrada ~400 px |
| `picker` | Card centrada ~500 px | Card centrada ~500 px |
| `form` | **Fullscreen** | Card grande max 1100 px |
| `wizard` | **Fullscreen** | Card grande max 1150 px |

**Principio de anatomía preservada**: la estructura interna (header,
columnas, footer) NO cambia entre breakpoints. Solo el contenedor
externo adapta tamaño/insetPadding. Un cajero entrenado en 1366
reconoce el mismo modal en 1280.

**Ejemplos en MangoPOS**:
- Confirmación: "¿Anular orden?", "¿Eliminar producto?"
- Picker: Selector de mesero, cliente, fecha, mesa
- Form: PaymentSplitDialog, SplitBillModal, factura/NCF
- Wizard: Setup inicial, alta de impresora

---

## Patrones POS profesional

Aplicables a cualquier modal/pantalla que toque dinero o NCF (cobro,
split, anulación). Estos son los detalles que separan "app
responsive" de "POS profesional".

1. **Total visible siempre** en header y footer del modal. Nunca
   esconder el monto detrás de scroll.
2. **Input principal prominente**: el campo "Monto recibido" debe ser
   visualmente más grande (altura 48 px, font 18 pt) que campos
   secundarios (NCF, propina).
3. **Atajos de denominación arriba** del input (`[Exacto] [200] [500]
   [1000] [2000]` para RD$). Ver `_LeftPanel` en
   `payment_split_screen.dart`.
4. **Botón "Confirmar" disabled hasta válido** + mensaje inline
   explicando qué falta ("Falta RD$ 100"). No dejes al cajero
   adivinando.
5. **Estado loading durante procesamiento**: spinner inline en el
   botón + bloqueo de inputs.
6. **Estado error explícito**: mensaje en línea con el botón, no toast
   que se va. El error tiene que persistir mientras el cajero decide
   qué hacer.
7. **Color de acción más allá del hue**: peso, posición, tamaño y
   eventualmente icono. ~5% de cajeros hombres tiene daltonismo.
8. **Keyboard shortcuts** en flujos transaccionales: Esc para
   cancelar, Enter inteligente (con monto agrega, sin monto y
   completo confirma), letras para método de pago (e/t/r), F1 o `*`
   para "Exacto".

---

## Anti-patterns (lint rule activa)

El script `scripts/check_responsive_rules.sh` corre en CI y falla
el build si encuentra:

### ❌ `MediaQuery.physicalSize` o `view.physicalSize`

Anula el DPI scaling de Windows. Una decisión basada en píxeles físicos
no escala con el slider del SO.

```dart
// ❌ MAL
final w = MediaQuery.of(context).physicalSize.width;

// ✅ BIEN
final w = MediaQuery.sizeOf(context).width;
```

### ❌ `textScaleFactor: 1.0` o `TextScaler.linear(1.0)` hardcodeado

Bloquea la accesibilidad. El cajero con vista cansada no puede subir el
texto desde el SO porque "alguien decidió que 1.0 está bien".

```dart
// ❌ MAL
MediaQuery(
  data: MediaQuery.of(context).copyWith(
    textScaler: TextScaler.linear(1.0),
  ),
  child: ...,
)

// ✅ BIEN
// No envolver. Respetar lo que el sistema/MediaQuery decide.
// Si tu widget rompe con textScaler > 1, usá IntrinsicHeight/minHeight
// en vez de bloquear el zoom.
```

### ❌ `height: X` literal en widgets que muestren texto

Si el texto crece (textScaler 1.3× o lenguajes con palabras largas), se
recorta.

```dart
// ❌ MAL
SizedBox(
  height: 40,
  child: Text(label, style: TextStyle(fontSize: 14)),
)

// ✅ BIEN
ConstrainedBox(
  constraints: const BoxConstraints(minHeight: TouchTargets.minSize),
  child: Center(
    child: Text(label, style: TextStyle(fontSize: FontSizes.body)),
  ),
)
```

### ❌ Touch targets <44 px

Cualquier widget tappable necesita 44×44 px mínimo. Si el ícono es
chico, extender área activa con padding.

```dart
// ❌ MAL: ícono de 16 px sin área activa extendida
IconButton(icon: Icon(Icons.close, size: 16), onPressed: ...)

// ✅ BIEN: minimumSize fuerza 44×44 sin importar el iconSize
IconButton(
  icon: const Icon(Icons.close, size: 16),
  iconSize: TouchTargets.minSize,
  splashRadius: 22,
  onPressed: ...,
)
```

### ❌ Excepciones permitidas

Si tenés una razón documentable (ej: badge non-interactivo, número
absoluto en una tabla técnica), agregar:

```dart
// ignore: prd6_responsive
final raw = MediaQuery.of(context).physicalSize;
```

---

## Checklist para PRs nuevas

- [ ] Cualquier dimension/font/spacing usa tokens (`Insets`,
      `FontSizes`, `TouchTargets`).
- [ ] Layout decisions usan `Breakpoints.*` o `LayoutBuilder` en vez
      de `MediaQuery.of().size.width > X` mágico.
- [ ] Touch targets ≥44 px verificados manualmente o con
      `tester.getSize()` en widget tests.
- [ ] Modales usan `MangoModal.showAdaptive`/`wrap`, no `Dialog`
      directo.
- [ ] Probado en compact (1366×768 o 1920@150 %) — al menos toggle
      sidebar + abrir modal principal.
- [ ] `flutter analyze` clean.
- [ ] `bash scripts/check_responsive_rules.sh` clean.
- [ ] Si el PR toca cobro/auth/printing/tenant, validado con cajero
      real (no solo dev/PM).

---

## Referencias en código

| Concepto | Archivo |
|---|---|
| Breakpoints | [`lib/app/theme/breakpoints.dart`](../lib/app/theme/breakpoints.dart) |
| Tokens (Insets/FontSizes/TouchTargets) | [`lib/app/theme/sizes.dart`](../lib/app/theme/sizes.dart) |
| MangoModal helper | [`lib/app/widgets/mango_modal.dart`](../lib/app/widgets/mango_modal.dart) |
| Lint script | [`scripts/check_responsive_rules.sh`](../scripts/check_responsive_rules.sh) |
| Ejemplos vivos | `printers_view.dart` (sidebar colapsable), `payment_split_screen.dart` (modal form + shortcuts), `kitchen_display_screen.dart` (grid adaptativo) |

---

## PRD origen

[`PRD Ventas/PRD_06_responsive_dpi.md`](../PRD%20Ventas/PRD_06_responsive_dpi.md) — diseño completo de breakpoints, tokens, modal anatomy, touch
targets y patrones POS profesional. Esta guía es el resumen ejecutivo
para uso día a día.
