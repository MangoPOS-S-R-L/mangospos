# PRD · Modos de Cierre de Caja a Ciegas (Compacto vs Detallado)

| Campo            | Valor                                                              |
| ---------------- | ------------------------------------------------------------------ |
| **Versión**      | 1.0                                                                |
| **Estado**       | Draft — pendiente revisión                                         |
| **Autor**        | Cristian R.                                                        |
| **Fecha**        | 10 mayo 2026                                                       |
| **Producto**     | MangoPOS (Flutter)                                                 |
| **Mercado**      | República Dominicana — restaurantes                                |
| **Programa**     | Cash Control (paralelo a Fiscal Stabilization Program)             |
| **Dependencias** | Schema actual de `cash_register_sessions`, sistema de settings por business |

---

## 1. Contexto y motivación

MangoPOS ya tiene cierre de caja **a ciegas** en producción: el cajero cuenta
efectivo, tarjeta y transferencia sin ver el monto esperado por el sistema, y
solo después de confirmar el conteo se le presenta la varianza. Eso protege
contra el anti-patrón conocido como "cuadre forzado" (ajustar lo contado al
esperado).

El módulo actual es un **modal único** que pide los tres totales en la misma
pantalla. Funciona bien para cajeros experimentados que cierran rápido, pero
tiene fricción para:

- Cajeros nuevos sin entrenamiento estructurado en el flujo.
- Negocios con auditorías estrictas que exigen desglose por denominación.
- Restaurantes con alta rotación de personal donde el conteo guiado reduce
  errores de digitación.

Este PRD agrega un **segundo modo a ciegas** configurable por negocio: un
wizard de 3 pasos (efectivo → tarjeta + transferencia → revisión y firma).
Ambos modos son a ciegas; la diferencia es la estructura de UX. La elección
se hace por business desde _Más opciones > Caja > Modo de cierre de caja_.

---

## 2. Objetivos

1. Implementar wizard de cierre de caja en 3 pasos (efectivo → tarjeta +
   transferencia → revisión + firma) que mantiene el principio a ciegas:
   el cajero **no ve el monto esperado** hasta después de confirmar.
2. Agregar setting por business para elegir entre **modo compacto**
   (modal único, comportamiento actual) y **modo detallado** (wizard 3 pasos).
3. Garantizar navegación 100% por teclado en el wizard (tab, enter, esc,
   atajos numéricos).
4. Mostrar diálogo de confirmación final antes de firmar el cierre en el
   modo detallado (el compacto ya tiene su propio modal de confirmación).
5. **No alterar el modo compacto existente.** Strangler fig: el wizard nuevo
   convive con el dialog actual; el router lee el setting y monta el
   correcto.
6. Garantizar layout responsivo: el wizard hace scroll vertical/horizontal
   automáticamente cuando la pantalla lo amerita, sin perder visibilidad de
   inputs ni del footer fijo.
7. Soportar zoom del wizard (escala `0.85×` a `1.50×`) sin romper navegación
   por teclado ni layout. El control del zoom **no vive en la pantalla de
   cierre** — se configura una sola vez desde _Más opciones > Caja > Zoom del
   cierre de caja_ (ver sección 18) y aplica únicamente a las pantallas de
   cierre (compact y detailed).

## 3. No-objetivos

- Cambiar la visibilidad del esperado en el modo compacto. El comportamiento
  actual queda intacto: cuenta a ciegas, varianza solo después de confirmar.
- Pantalla de supervisor con conciliación enriquecida (PRD separado).
- Reportes de varianza, alertas de tolerancia, autorización por PIN del
  supervisor.
- Modo híbrido (algunos métodos a ciegas, otros no) — ambos modos son a
  ciegas por diseño.
- Múltiples cajas concurrentes en una misma sesión.
- Captura desglosada por red bancaria, tipo de tarjeta o banco emisor.

---

## 4. Setting de modo de cierre

### 4.1. Ubicación en UI

```
Más opciones
└── Caja
    └── Modo de cierre de caja  ← nuevo
```

### 4.2. Componente

`RadioListTile` con dos opciones, label en negrita y descripción debajo:

| Opción                  | Valor      | Descripción                                                                                                                                                                            |
| ----------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Compacto (1 paso)**   | `compact`  | Un solo modal con efectivo, tarjeta y transferencia juntos. Cierre más rápido para cajeros experimentados. (Comportamiento actual del POS.)                                            |
| **Detallado (3 pasos)** | `detailed` | Wizard guiado: primero efectivo con desglose por denominación, luego tarjeta y transferencia, y por último revisión y firma. Más estructurado para cajeros nuevos o auditorías estrictas. |

> **Ambos modos son a ciegas durante el conteo.** El cajero nunca ve el monto
> esperado antes de confirmar. La diferencia es solo estructural (UX).

### 4.3. Persistencia

- **Scope:** por business (no por usuario, no por dispositivo).
- **Tabla:** `business_settings`.
- **Columna nueva:**
  `cash_close_mode TEXT NOT NULL DEFAULT 'compact' CHECK (cash_close_mode IN ('compact', 'detailed'))`.
- **Default `compact`:** mantiene el comportamiento actual del POS para todos
  los negocios existentes (no introduce sorpresas).
- **Cambio en vivo:** sin requerir reinicio. La próxima vez que se abra el
  módulo de cierre, se rutea según el valor actual.
- **RLS:** lectura por cualquier usuario del business; escritura solo por roles
  `owner` y `admin`.

### 4.4. Migración SQL

```sql
ALTER TABLE business_settings
  ADD COLUMN cash_close_mode TEXT NOT NULL DEFAULT 'compact'
  CHECK (cash_close_mode IN ('compact', 'detailed'));
```

### 4.5. Auditoría del cambio

Cada cambio del setting se registra en `business_settings_audit_log` (si existe)
o se omite si no hay tabla de audit. Aplica para ambas direcciones del toggle
(compact ↔ detailed); no hay implicancia de seguridad como tal — es solo un
cambio de UX. Útil para análisis de adopción.

---

## 5. Arquitectura — Strangler Fig

### 5.1. Coexistencia

Tres widgets en juego:

```
CashCloseRouter (nuevo)
  ├── BlindCashCloseDialog        (existente, modo compact, intocable)
  └── CashCloseDetailedWizard     (nuevo, modo detailed)
```

`CashCloseRouter` lee `business_settings.cash_close_mode` y monta el widget
correspondiente. No hay lógica compartida entre ambos modos al nivel de UI —
son dos flujos paralelos que terminan escribiendo en `cash_register_sessions`
y en la tabla compartida `cash_count_blind`.

### 5.2. Punto de entrada

El botón "Cerrar caja" en cualquier pantalla de MangoPOS navega a
`CashCloseRouter` en lugar de directamente al `BlindCashCloseDialog`.

### 5.3. Datos compartidos vs separados

| Tabla                                                       | Compact    | Detailed   |
| ----------------------------------------------------------- | ---------- | ---------- |
| `cash_register_sessions` (existente)                        | ✅ Escribe | ✅ Escribe |
| `cash_register_sessions.notes` (texto libre, en uso actual) | ✅ Escribe | ❌ No toca |
| `cash_count_blind` (nueva, desglose firmado)                | ❌ No toca | ✅ Escribe |

> Nota: el modo compact persiste el conteo como texto formateado en
> `cash_register_sessions.notes` — comportamiento intacto, no se modifica
> en este PRD. Solo el modo detailed escribe en `cash_count_blind` con
> desglose estructurado y firma inmutable. Consolidar ambos modos sobre
> la misma tabla queda como future work (§17).

### 5.4. Audit trail

`cash_register_sessions` recibe nueva columna `close_mode_used`:

```sql
ALTER TABLE public.cash_register_sessions
  ADD COLUMN close_mode_used TEXT
  CHECK (close_mode_used IN ('compact', 'detailed'));
```

Se llena al momento del cierre, refleja qué modo se usó (no qué setting estaba
activo). Esto permite cambiar el setting en medio de un turno sin afectar
sesiones ya abiertas.

---

## 6. Schema — `cash_count_blind`

```sql
CREATE TABLE public.cash_count_blind (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cash_register_session_id UUID NOT NULL REFERENCES public.cash_register_sessions(id) ON DELETE CASCADE,
  business_id UUID NOT NULL REFERENCES public.businesses(id),

  -- Totales reportados por el cajero
  cash_amount NUMERIC(12, 2) NOT NULL CHECK (cash_amount >= 0),
  card_amount NUMERIC(12, 2) NOT NULL CHECK (card_amount >= 0),
  transfer_amount NUMERIC(12, 2) NOT NULL CHECK (transfer_amount >= 0),

  -- Desglose de efectivo por denominación (JSONB)
  -- { "2000": 4, "1000": 9, "500": 6, "200": 7, "100": 5, "50": 8, "coins": 240.00 }
  denominations JSONB NOT NULL,

  -- Fondo inicial al momento del cierre (snapshot, copiado de cash_register_sessions.start_amount)
  opening_float NUMERIC(12, 2) NOT NULL,

  -- Nota libre del cajero al supervisor
  supervisor_note TEXT,

  -- Firma
  signed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  signed_by_user_id UUID NOT NULL REFERENCES auth.users(id),

  CONSTRAINT cash_count_blind_session_unique UNIQUE (cash_register_session_id)
);

CREATE INDEX idx_cash_count_blind_business ON public.cash_count_blind(business_id);
CREATE INDEX idx_cash_count_blind_signed_at ON public.cash_count_blind(signed_at DESC);
```

> Nota de naming: el repo usa `cash_register_sessions` (no `cash_sessions`) y
> `start_amount` (no `opening_float`). En `cash_count_blind` mantenemos
> `opening_float` como nombre semántico — es un snapshot, no un FK al campo
> original. La columna FK al session se llama `cash_register_session_id` para
> alinear con el naming del repo.

### 6.1. Inmutabilidad post-firma

Trigger que rechaza UPDATE/DELETE una vez `signed_at IS NOT NULL`:

```sql
CREATE OR REPLACE FUNCTION reject_cash_count_blind_modifications()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.signed_at IS NOT NULL THEN
    RAISE EXCEPTION 'cash_count_blind is immutable after signing';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cash_count_blind_immutable
  BEFORE UPDATE OR DELETE ON cash_count_blind
  FOR EACH ROW EXECUTE FUNCTION reject_cash_count_blind_modifications();
```

### 6.2. RLS

> Helpers existentes en el repo: `public.user_has_business_access(uid, business_id)`
> y `public.user_business_role(uid, business_id)`. No existe `current_business_id()`
> ni `user_has_role()` — usamos los helpers reales.

```sql
ALTER TABLE public.cash_count_blind ENABLE ROW LEVEL SECURITY;

-- Cajero: insertar/leer solo sus propios cierres dentro de un business al
-- que tiene acceso. La inmutabilidad post-firma la garantiza el trigger
-- (sección 6.1), no la RLS.
CREATE POLICY cash_count_blind_cashier_rw ON public.cash_count_blind
  FOR ALL
  TO authenticated
  USING (
    public.user_has_business_access(auth.uid(), business_id)
    AND signed_by_user_id = auth.uid()
  )
  WITH CHECK (
    public.user_has_business_access(auth.uid(), business_id)
    AND signed_by_user_id = auth.uid()
  );

-- Supervisor/admin/owner: leer todos los cierres del business.
CREATE POLICY cash_count_blind_supervisor_read ON public.cash_count_blind
  FOR SELECT
  TO authenticated
  USING (
    public.user_business_role(auth.uid(), business_id) = ANY (ARRAY['owner', 'admin', 'supervisor'])
  );
```

---

## 7. UI — Wizard de 3 pasos

### 7.1. Layout común

Cada paso comparte:

- **Header** (56 px): icono + título "Cierre de caja" + subtítulo
  `Caja {N} · {nombre cajero} · {fecha}` + badge morado "Detallado".
- **Stepper** (48 px): 3 columnas con barra de progreso de 3 px y label.
- **Body** (scrollable): contenido del paso.
- **Footer** (56 px): botón secundario izquierda, botón primario derecha.

### 7.2. Paso 1 — Efectivo

Tabla de denominaciones con 7 filas: `2000`, `1000`, `500`, `200`, `100`, `50`,
`Monedas (suma)`.

| Columna      | Comportamiento                                                                                                    |
| ------------ | ----------------------------------------------------------------------------------------------------------------- |
| Denominación | Read-only, label con badge cream                                                                                  |
| Cantidad     | `TextField` con `TextInputType.number`, `FilteringTextInputFormatter.digitsOnly` excepto monedas que es `decimal` |
| Subtotal     | Read-only, calculado en vivo (`cantidad × valor`)                                                                 |

Debajo de la tabla, dos cards lado a lado:

- **Fondo inicial** (cream): viene de `cash_sessions.opening_float`, read-only.
- **Efectivo del turno** (ámbar `#FAEEDA`): `total_contado - opening_float`,
  calculado en vivo.

Si `efectivo_del_turno < 0`, mostrar en rojo pero permitir continuar (puede
pasar si hubo retiros).

### 7.3. Paso 2 — Tarjeta y Transferencia

Dos cards apiladas verticalmente, cada una con:

- Icono + título
- Descripción ayuda corta
- Input único de total (decimal, RD$)

Al pie, card cream con "Total pagos electrónicos" =
`card_amount + transfer_amount`.

### 7.4. Paso 3 — Confirmar y firmar

Resumen de los 3 métodos (efectivo, tarjeta, transferencia) con su total
respectivo. Total reportado en card ámbar.

Textarea opcional para nota al supervisor (max 500 caracteres).

Aviso de inmutabilidad post-firma.

### 7.5. Botones primarios y estados

| Paso | Botón secundario | Botón primario       | Habilitado cuando               |
| ---- | ---------------- | -------------------- | ------------------------------- |
| 1    | Cancelar         | Continuar            | Siempre (los ceros son válidos) |
| 2    | Atrás            | Revisar y confirmar  | Siempre                         |
| 3    | Revisar          | Firmar y cerrar caja | Siempre                         |

> Decisión: no validar campos en blanco como error. El cajero puede
> legítimamente reportar 0 en cualquier método (no había transferencias ese
> día). La validación de razonabilidad la hace el supervisor.

### 7.6. Scroll y layout responsivo

El wizard debe funcionar desde tablets de 7" en orientación vertical hasta
monitores externos de escritorio. Reglas:

- **Body scrollable.** El contenido entre header/stepper y footer va envuelto
  en `SingleChildScrollView` con `physics: ClampingScrollPhysics()`. Header,
  stepper y footer permanecen pinned vía `Column` + `Expanded` para el body.
- **Footer sticky.** Los botones primario/secundario nunca quedan ocultos tras
  el contenido. El footer ocupa su altura fija de 56 px aun cuando el body
  scrollea.
- **Anchos mínimos.** Si el ancho disponible < 600 px, las dos cards
  laterales (`Fondo inicial` / `Efectivo del turno` en paso 1, y las dos
  tarjetas de método en paso 2) se apilan verticalmente. ≥ 600 px se muestran
  lado a lado.
- **Tabla de denominaciones compacta.** Para anchos < 480 px, cada fila
  colapsa a layout vertical: denominación arriba, cantidad y subtotal en
  segunda línea.
- **On-screen keyboard.** Cuando aparece el teclado virtual, el wizard se
  ajusta vía `MediaQuery.viewInsets` y desplaza el input enfocado al centro
  del área visible mediante `Scrollable.ensureVisible(focusNode.context)`.
- **Foco fuera de viewport.** Cuando un input recibe foco vía `Tab` y queda
  fuera del área visible, hacer scroll automático para que esté completamente
  visible (con padding de 24 px arriba/abajo).
- **Scroll con teclado físico.** `PageUp` / `PageDown` desplazan el body 80%
  del viewport. Rueda del mouse y trackpad gestures funcionan sin
  restricciones, sin interferir con el `tab order`.
- **Sin overflow silencioso.** El `analyzer` debe estar libre de
  `RenderFlex overflowed by N pixels` en los breakpoints 360, 480, 600, 768,
  1024 y 1440 px.

---

## 8. Navegación por teclado

> Requisito explícito del producto. Críticamente importante para cajeros
> experimentados que cierran rápido.

### 8.1. Tab order global

| Posición | Elemento                             |
| -------- | ------------------------------------ |
| 1        | Primer input de la pantalla actual   |
| 2..N     | Inputs subsiguientes en orden visual |
| N+1      | Botón secundario (Atrás/Cancelar)    |
| N+2      | Botón primario (Continuar/Firmar)    |

`Shift+Tab` recorre en sentido inverso.

### 8.2. Atajos por teclado

| Tecla                   | Acción                                                                                                |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| `Tab` / `Shift+Tab`     | Mover foco entre campos                                                                               |
| `Enter`                 | Avanzar al siguiente paso (equivalente a clic en botón primario) si estoy en el último input del paso |
| `Enter` (en otro input) | Mover foco al siguiente input (`TextInputAction.next`)                                                |
| `Esc`                   | Volver al paso anterior; en paso 1, mostrar diálogo "¿Cancelar cierre?"                               |
| `F2`                    | Avanzar al siguiente paso (alternativa a Enter, sin importar el foco actual)                          |
| `Ctrl+Enter`            | Saltar directo a confirmación final desde paso 3                                                      |

### 8.3. Auto-focus

- Al entrar a cada paso, foco automático en el primer input.
- Si el cajero regresa a un paso anterior, foco en el primer input.

### 8.4. Configuración por field

```dart
TextField(
  keyboardType: TextInputType.number, // o TextInputType.numberWithOptions(decimal: true) para monedas/totales
  textInputAction: TextInputAction.next, // last input del paso usa TextInputAction.done
  inputFormatters: [
    FilteringTextInputFormatter.digitsOnly, // o RegExp(r'^\d*\.?\d{0,2}$') para decimales
  ],
  autofocus: isFirstField,
  focusNode: focusNode,
  onSubmitted: (_) => _advanceFocusOrStep(),
)
```

### 8.5. Implementación a nivel de app

Usar `Shortcuts` + `Actions` widget envolviendo el wizard:

```dart
Shortcuts(
  shortcuts: {
    LogicalKeySet(LogicalKeyboardKey.escape): GoBackIntent(),
    LogicalKeySet(LogicalKeyboardKey.f2): AdvanceStepIntent(),
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter): JumpToConfirmIntent(),
  },
  child: Actions(
    actions: { ... },
    child: CashCloseDetailedWizard(),
  ),
);
```

### 8.6. Indicador visual de foco

`FocusableActionDetector` con borde de 2 px en color primario (`#1D9E75`) sobre
el elemento enfocado, para que sea evidente al usuario de teclado dónde está el
cursor.

### 8.7. Compatibilidad con zoom del wizard

> El wizard **no expone controles de zoom propios**. El zoom se controla
> exclusivamente desde _Más opciones > Caja > Zoom del cierre de caja_ (ver
> sección 18) y aplica únicamente a las pantallas de cierre (compact y detailed).
> El resto de la app no se ve afectada.

Garantías del wizard frente al factor de zoom:

- A `0.85×` (UI compacta), todos los textos se mantienen legibles (mínimo 11
  px efectivo) y no hay solapamiento entre stepper, header y body.
- A `1.00×` (default), el layout es el especificado en mockups.
- A `1.25×` y `1.50×`, el body activa scroll automáticamente sin romper el
  footer pinned ni el `tab order`. Los inputs no se truncan.
- El indicador visual de foco (borde 2 px) escala proporcionalmente con el
  factor.
- El diálogo de confirmación final (sección 9) también respeta el factor: si
  el contenido excede la altura disponible, se vuelve scrollable internamente
  pero los botones siguen visibles.
- Atajos de zoom estándar (`Ctrl+=`, `Ctrl+-`, `Ctrl+0`) están **deshabilitados
  dentro del wizard** — el cajero no debe poder cambiar el zoom durante el
  conteo, evitando errores accidentales en medio de la digitación.

---

## 9. Diálogo de confirmación final

> Requisito explícito del producto.

### 9.1. Trigger

Al hacer clic (o Enter) en "Firmar y cerrar caja" en paso 3.

### 9.2. Layout

`AlertDialog` modal con:

- **Título:** `¿Desea enviar el conteo?`
- **Body:**
  - Resumen compacto: 3 líneas `Efectivo · Tarjeta · Transferencia` con sus
    montos.
  - Total reportado en negrita.
  - Texto: _"Esta acción no se puede deshacer. La conciliación contra el sistema
    la verá únicamente el supervisor."_
- **Botones:**
  - `Cancelar` (secundario, foco por defecto — más seguro)
  - `Sí, firmar y cerrar` (primario, color verde `#1D9E75`)

### 9.3. Comportamiento por teclado

- `Tab` / `Shift+Tab`: alternar entre los dos botones.
- `Enter`: ejecutar acción del botón con foco.
- `Esc`: equivalente a "Cancelar".
- Foco inicial en "Cancelar" (decisión deliberada — Enter accidental no debe
  firmar).

### 9.4. Acción al confirmar

1. Mostrar `CircularProgressIndicator` en el botón primario (deshabilita ambos).
2. Llamar a `cashCountBlindRepository.signAndClose(...)`.
3. Si éxito: cerrar diálogo, cerrar wizard, navegar a pantalla de inicio con
   snackbar verde "Caja cerrada · Sesión #{N}".
4. Si error: mostrar snackbar rojo con mensaje y permitir reintentar (no
   descartar el conteo).

---

## 10. Validación

### 10.1. Reglas

| Campo                    | Validación                        |
| ------------------------ | --------------------------------- |
| Cantidad de denominación | Entero ≥ 0                        |
| Suma de monedas          | Decimal ≥ 0, max 2 decimales      |
| Total tarjeta            | Decimal ≥ 0, max 2 decimales      |
| Total transferencia      | Decimal ≥ 0, max 2 decimales      |
| Nota supervisor          | String ≤ 500 caracteres, opcional |

### 10.2. Cuándo se habilita "Continuar"

Siempre. Los campos vacíos se interpretan como cero.

### 10.3. Errores visuales

Solo se muestran errores cuando el formato es inválido (e.g., letras en campo
numérico). Texto de ayuda en rojo bajo el campo, borde del input en `#A32D2D`.

### 10.4. Validación al firmar

Antes de abrir el diálogo de confirmación, validar:

1. Todos los campos numéricos parsean correctamente.
2. `signed_by_user_id` coincide con la sesión actual.
3. `cash_session_id` corresponde a una sesión `OPEN`.

Si algo falla, mostrar snackbar y NO abrir el diálogo.

---

## 11. Persistencia local del borrador

### 11.1. Motivación

En tablets de restaurante (especialmente T10M Pro), reinicios por luz son
comunes. Perder un conteo de 47 órdenes es inaceptable.

### 11.2. Implementación

- **Storage:** SQLite local (drift) en tabla `cash_close_drafts`.
- **Schema:**
  ```dart
  class CashCloseDrafts extends Table {
    TextColumn get cashSessionId => text()();
    TextColumn get businessId => text()();
    TextColumn get state => text()(); // JSON serializado del wizard
    DateTimeColumn get updatedAt => dateTime()();
    @override
    Set<Column> get primaryKey => {cashSessionId};
  }
  ```
- **Auto-save:** debounce de 500 ms en cada `onChanged` de cualquier input.
- **Recuperación:** al abrir el wizard, si existe draft para la
  `cash_session_id` actual, mostrar diálogo "¿Continuar conteo previo o empezar
  de cero?".
- **Limpieza:** al firmar exitosamente, borrar el draft.

---

## 12. Telemetría

Eventos a registrar (en tabla `events` o servicio de analytics):

| Evento                             | Cuándo                          | Payload                                         |
| ---------------------------------- | ------------------------------- | ----------------------------------------------- |
| `cash_close.mode_setting_changed`  | Cambio del toggle               | `{ from, to, business_id, user_id }`            |
| `cash_close.detailed_started`         | Cajero abre wizard detallado    | `{ cash_session_id }`                           |
| `cash_close.detailed_step_completed`  | Avanza de paso                  | `{ step, time_spent_ms }`                       |
| `cash_close.detailed_signed`          | Firma                           | `{ cash_session_id, total_reported, has_note }` |
| `cash_close.detailed_cancelled`       | Sale sin firmar                 | `{ step_reached, time_spent_ms }`               |
| `cash_close.detailed_draft_recovered` | Recupera borrador tras reinicio | `{ cash_session_id, age_ms }`                   |
| `cash_close.ui_scale_changed`      | Cambio del slider de zoom       | `{ from, to, device_id }` (ver sección 18.6)    |

Importante para validar adopción y detectar fricción.

---

## 13. Definition of Done por sub-fase

> Disciplina commit-per-sub-phase. Cada sub-fase termina con commit firmado y CI
> verde.

### Sub-fase A · Setting toggle (backend + UI settings)

- [ ] Migración SQL para `business_settings.cash_close_mode`.
- [ ] RLS verificada.
- [ ] Pantalla _Más opciones > Caja > Modo de cierre de caja_ renderiza con
      `RadioListTile`.
- [ ] Cambio del setting persiste y se refleja inmediatamente.
- [ ] Test widget: render correcto y persistencia.
- [ ] **Commit:** `feat(settings): add cash close mode toggle`

### Sub-fase B · Schema `cash_count_blind`

- [ ] Migración SQL forward y backward.
- [ ] Trigger de inmutabilidad.
- [ ] RLS para cajero y supervisor.
- [ ] Test SQL: insert + signed → update falla.
- [ ] **Commit:**
      `feat(schema): add cash_count_blind table with immutability trigger`

### Sub-fase C · Wizard UI sin lógica (3 pasos en blanco)

- [ ] `CashCloseDetailedWizard` widget.
- [ ] 3 pantallas con header, stepper, body, footer.
- [ ] Navegación entre pasos con `PageController` o equivalente.
- [ ] Colores tomados de `MangoColors` (la app aún no tiene dark mode, no se fuerza theme).
- [ ] Body envuelto en `SingleChildScrollView`; header y footer pinned.
- [ ] Footer sticky verificado con body lleno y vacío.
- [ ] Layout responsivo verificado en 360, 480, 600, 768, 1024 y 1440 px sin
      `RenderFlex overflow`.
- [ ] Cards laterales colapsan a stack vertical en < 600 px.
- [ ] Goldens: 1 por paso (paso 1, 2, 3 vacíos) en 768 px y 1440 px.
- [ ] **Commit:** `feat(cash-close): add blind wizard UI scaffolding`

### Sub-fase D · Lógica de inputs y validación

- [ ] Inputs numéricos con formatters correctos.
- [ ] Cálculos en vivo (subtotales, efectivo del turno, total pagos
      electrónicos, total reportado).
- [ ] Validación de formato.
- [ ] Goldens: 1 por paso con valores poblados.
- [ ] **Commit:**
      `feat(cash-close): add blind wizard input logic and validation`

### Sub-fase E · Navegación por teclado

- [ ] Tab order correcto en cada paso.
- [ ] Atajos `Esc`, `F2`, `Ctrl+Enter`, `Enter` funcionando.
- [ ] Auto-focus al cambiar de paso.
- [ ] Indicador visual de foco.
- [ ] `PageUp` / `PageDown` desplazan el body 80% del viewport.
- [ ] Foco fuera de viewport hace scroll automático con padding 24 px.
- [ ] Atajos de zoom (`Ctrl+=`, `Ctrl+-`, `Ctrl+0`) **deshabilitados** dentro
      del wizard (ver 8.7).
- [ ] Test integration: flujo completo solo con teclado, incluyendo casos en
      los que el body necesita scroll para alcanzar el último input.
- [ ] **Commit:**
      `feat(cash-close): add full keyboard navigation to blind wizard`

### Sub-fase F · Diálogo de confirmación final

- [ ] `AlertDialog` con resumen y dos botones.
- [ ] Foco inicial en "Cancelar".
- [ ] Tab/Enter/Esc funcionando.
- [ ] Loading state durante firma.
- [ ] Manejo de éxito/error.
- [ ] Test widget: diálogo con sus 3 estados (idle, loading, error).
- [ ] **Commit:** `feat(cash-close): add final confirmation dialog`

### Sub-fase G · Persistencia local de borrador

- [ ] Tabla `cash_close_drafts` en drift.
- [ ] Auto-save con debounce.
- [ ] Recuperación al abrir wizard.
- [ ] Limpieza tras firma exitosa.
- [ ] Test integration: simular kill de la app entre pasos.
- [ ] **Commit:** `feat(cash-close): persist detailed close drafts locally`

### Sub-fase H · Router y strangler fig

- [ ] `CashCloseRouter` lee `cash_close_mode` y monta el widget correcto.
- [ ] Botón "Cerrar caja" en toda la app navega al router.
- [ ] `cash_sessions.close_mode_used` se llena correctamente.
- [ ] Test integration: cambiar setting → cerrar caja → verificar módulo
      correcto.
- [ ] **Commit:**
      `feat(cash-close): integrate blind module via strangler fig router`

### Sub-fase I · Telemetría

- [ ] Eventos disparados en los hooks correctos.
- [ ] Tabla/servicio de events recibiendo los eventos.
- [ ] **Commit:** `feat(cash-close): add detailed close telemetry`

### Sub-fase J · QA y regresión

- [ ] Tests E2E del modo compact (asegurar que no se rompió).
- [ ] Tests E2E del modo detailed (flujo completo, teclado, mouse, mixto).
- [ ] Smoke test en T10M Pro real con APK universal.
- [ ] Smoke test del wizard en `ui_scale` `0.85`, `1.00`, `1.25`, `1.50`:
      footer visible, sin overflow, tab order intacto.
- [ ] Smoke test responsivo: rotar tablet portrait/landscape mid-conteo, no se
      pierden datos ni el foco.
- [ ] **Commit:** `test(cash-close): full regression for both modules`

### Sub-fase K · Setting de zoom del wizard de cierre

- [ ] Pantalla _Más opciones > Caja > Zoom del cierre de caja_ con slider de
      5 stops, labels y botones `−` / `+`.
- [ ] Persistencia en `SharedPreferences` con clave `cash_close.ui_scale`.
- [ ] Vista previa en vivo dentro de la pantalla de _Caja_ con un fragmento
      representativo del wizard (input + subtotal + botón).
- [ ] `CashCloseScaleScope` envuelve sólo al `CashCloseRouter` y aplica el
      factor vía `MediaQuery(data: ...copyWith(textScaler: ...))`.
- [ ] Verificar que el factor **no se propaga** fuera del scope: cashier,
      dashboard, settings y demás pantallas no escalan.
- [ ] Atajos `Ctrl+−`, `Ctrl+=`, `Ctrl+0` activos sólo en la pantalla _Caja_
      con el slider enfocado; **no registrados** en el wizard.
- [ ] Composición correcta con preferencia de fuente del SO (multiplicativa).
- [ ] Telemetría `cash_close.ui_scale_changed` disparada.
- [ ] Test widget: cambio de slider re-renderiza textos del wizard sin
      reiniciar; pantallas exteriores al scope quedan intactas.
- [ ] **Commit:** `feat(cash-close): add cash-close wizard zoom slider`

---

## 14. Plan de testing

### 14.1. Unit tests

- Cálculos del wizard: subtotales, total contado, efectivo del turno, total
  pagos electrónicos, total reportado.
- Parseo de inputs (con coma vs punto decimal).
- Validación de formato.

### 14.2. Widget tests (golden)

- Cada paso vacío (3 goldens).
- Cada paso lleno (3 goldens).
- Diálogo de confirmación (1 golden).
- Setting toggle con cada valor (2 goldens).

### 14.3. Integration tests

- Flujo completo cajero → firma → verificar `cash_count_blind` en DB.
- Cambio de setting → siguiente cierre usa nuevo módulo.
- Recuperación de borrador.
- Navegación 100% por teclado.

### 14.4. Acceptance scenarios

| ID    | Escenario                                        | Resultado esperado                                                       |
| ----- | ------------------------------------------------ | ------------------------------------------------------------------------ |
| AC-1  | Business con setting `compact` cierra caja       | Se muestra el modal único existente (BlindCashCloseDialog)               |
| AC-2  | Business con setting `detailed` cierra caja      | Se muestra wizard de 3 pasos sin monto esperado visible durante el conteo |
| AC-3  | Cajero completa wizard detallado y firma         | `cash_count_blind` insertado, sesión cerrada, módulo no muestra varianza al cajero |
| AC-4  | Cajero presiona Esc en paso 1                    | Diálogo "¿Cancelar cierre?"                                              |
| AC-5  | Cajero presiona Enter en último input del paso 3 | Diálogo de confirmación se abre                                          |
| AC-6  | Cajero presiona Esc en diálogo de confirmación   | Diálogo se cierra, vuelve al paso 3 con datos intactos                   |
| AC-7  | App se cierra entre paso 2 y 3                   | Al reabrir, ofrece recuperar el borrador                                 |
| AC-8  | Supervisor cambia setting de detailed a compact  | Cierres en curso no se afectan; nuevos cierres usan compact              |
| AC-9  | Cajero firma, intento de UPDATE en DB            | Trigger rechaza con error                                                |
| AC-10 | Cajero navega solo con teclado de inicio a fin   | Completa el flujo sin tocar mouse                                        |
| AC-11 | Wizard abierto en tablet 480 px (paso 1 con todas las denominaciones llenas) | Body scrollea verticalmente; footer permanece visible; sin overflow      |
| AC-12 | Cajero presiona `Tab` y el siguiente input está fuera del viewport | Body scrollea automáticamente para mostrar el input enfocado con padding 24 px |
| AC-13 | Aparece teclado virtual en tablet Android         | El input enfocado queda en el área visible; footer no se oculta tras el teclado |
| AC-14 | Owner cambia _Más opciones > Caja > Zoom del cierre de caja_ a `1.50×` y abre wizard | Wizard renderiza con texto escalado, body scrollea, footer pinned, tab order intacto. Cashier/dashboard no se ven afectados |
| AC-15 | Cajero presiona `Ctrl++` dentro del wizard        | No pasa nada — el atajo no está registrado dentro del wizard             |
| AC-17 | Owner cambia el zoom a `1.30×` y luego abre cashier (no el wizard) | Cashier renderiza con textScaler default del SO, sin escalar — el setting no se propagó fuera del scope |
| AC-16 | Cajero rota tablet de portrait a landscape mid-conteo | Datos del paso actual se preservan; layout se reflowea sin perder foco |

---

## 15. Plan de rollout

1. **Beta interna:** desplegar a un solo business piloto (uno conocido,
   idealmente con un supervisor que entienda el modelo).
2. **Telemetría 7 días:** revisar `cash_close.detailed_*` events para detectar
   drop-offs, errores, tiempo por paso.
3. **Iteración:** si tiempo medio por cierre detallado > 2× del modo compact,
   revisar UX.
4. **Release general:** publicar nueva versión con setting visible para todos.
   Default sigue siendo `compact` para no sorprender.
5. **Comunicación:** changelog en MangoPOS y mensaje en pantalla principal del
   POS para owners.

---

## 16. Open questions

| # | Pregunta                                                                                        | Bloquea release?                                                    |
| - | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 1 | ¿El cajero ve la varianza después de firmar (read-only) o nunca?                                | No — asumimos _nunca_, supervisor only. Documentar.                 |
| 2 | ¿Tolerancia configurable por business para futuro PRD del supervisor?                           | No — fuera de scope.                                                |
| 3 | ¿Soportar otros métodos (cheque, gift card, cuenta corriente)?                                  | No — fuera de scope. Si se agregan, son nuevas secciones en paso 2. |
| 4 | ¿Forzar light mode globalmente o solo en el wizard de cierre?                                   | **Resuelto:** la app no tiene dark mode todavía, así que el wizard usa `MangoColors` sin envolver theme (decisión 10 mayo 2026). |
| 5 | ¿El `opening_float` es editable al cierre o read-only desde apertura?                           | **Resuelto:** read-only desde apertura (decisión 10 mayo 2026).     |
| 6 | ¿Cuál es el comportamiento si una sesión se cierra sin pasar por el wizard (bug, fuerza mayor)? | Definir flag `force_closed_by_admin` en `cash_sessions` con motivo. |

---

## 17. Out of scope / Future work

- Pantalla de supervisor con vista de varianza, tolerancia configurable,
  autorización por PIN. (PRD separado)
- Reportes de tendencia de varianza por cajero, por turno, por día.
- Bloqueo automático de cajeros con varianza recurrente sobre umbral.
- Modo detallado para apertura de caja también (no solo cierre).
- Consolidar storage del modo compact sobre `cash_count_blind` (hoy escribe
  en `cash_register_sessions.notes` como texto), para habilitar reportes
  unificados entre ambos modos.
- Sincronización offline robusta vía outbox pattern para cierres en sitios con
  conexión inestable.

---

## 18. Setting de zoom del wizard de cierre de caja

> Scope acotado: este zoom afecta **únicamente** a las pantallas de cierre
> de caja (compact y detailed). El resto de la app — cashier, dashboard,
> reports, settings —
> **no se ve afectado**. El control vive en _Configuración_ y no en la
> pantalla de cierre, para no contaminar el conteo con UI extra.

### 18.1. Ubicación en UI

```
Más opciones
└── Caja
    ├── Modo de cierre de caja      (sección 4)
    └── Zoom del cierre de caja     ← nuevo
```

Los dos settings comparten la misma pantalla de _Caja_ porque ambos
parametrizan el flujo de cierre.

### 18.2. Componente

`Slider` discreto con 5 stops + label numérico al lado:

| Stop | Multiplicador | Label en UI      |
| ---- | ------------- | ---------------- |
| 1    | `0.85×`       | Compacto         |
| 2    | `1.00×`       | Normal (default) |
| 3    | `1.15×`       | Grande           |
| 4    | `1.30×`       | Más grande       |
| 5    | `1.50×`       | Máximo           |

Botones laterales `−` y `+` con atajos `Ctrl+−` / `Ctrl+=` (o `Ctrl++`) para
ajustar mientras el slider tiene foco en _Caja_. `Ctrl+0` resetea a `1.00×`.
Estos atajos **no se cargan dentro del wizard** (ver 8.7) — el cajero no
debe poder cambiar el zoom durante el conteo.

Vista previa en vivo: panel demo a la derecha del slider que muestra un
fragmento del wizard (input + subtotal + botón) con el factor aplicado, para
que el usuario calibre antes de salir de Configuración.

### 18.3. Persistencia

- **Scope:** por dispositivo (no por business, no por usuario). Es preferencia
  visual del hardware donde corre la app.
- **Storage:** `SharedPreferences` con clave `cash_close.ui_scale` (double).
- **Default:** `1.00`.
- **Rango válido:** `[0.85, 1.50]`. Valores fuera de rango se clampan al
  cargar.
- **Cambio en vivo:** si el wizard ya está abierto al cambiar el setting (caso
  raro — implicaría dos pantallas concurrentes), el cambio aplica al próximo
  `build`. Sin reinicio.

### 18.4. Implementación

- Wrapper `CashCloseScaleScope` que envuelve **únicamente** al
  `CashCloseRouter` (y por extensión a `CashCloseClassic` y
  `CashCloseDetailedWizard`).
- Lee `cash_close.ui_scale` desde un `Riverpod` provider y aplica
  `MediaQuery(data: data.copyWith(textScaler: ...), child: ...)` localmente.
- **No se modifica el `MaterialApp` raíz**, no se modifica el theme, no se
  toca ninguna otra pantalla.
- Composición con la preferencia del SO: el factor del SO se preserva y se
  multiplica por `cash_close.ui_scale` dentro del scope.

### 18.5. Restricciones

- **Sólo escala texto** (vía `textScaler`). Iconos del wizard siguen
  `Theme.of(context).iconTheme` sin alteración.
- **El factor no se propaga** fuera del `CashCloseScaleScope` — si desde el
  wizard se navega a un diálogo modal `MangoModal`, ese diálogo debe quedar
  dentro del scope para heredar el factor (verificar en sub-fase F).
- **Pantallas fuera del cierre no escalan**: cashier, dashboard, reports,
  settings, etc. siguen su comportamiento original (default
  `MediaQuery.textScalerOf(context)` del SO).

### 18.6. Telemetría

| Evento                        | Cuándo        | Payload                   |
| ----------------------------- | ------------- | ------------------------- |
| `cash_close.ui_scale_changed` | Slider cambia | `{ from, to, device_id }` |

### 18.7. Migración / rollout

- No requiere migración SQL — preferencia local, default `1.00`.
- Se libera junto con el modo detailed. Como el setting es self-contained y
  no impacta tablas ni RLS, también puede salir antes (en sub-fase K) sin
  bloquear el resto.
- DoD: ver sub-fase K (sección 13).

---

## 19. Referencias

- Mockups del wizard a ciegas: conversación de diseño 10 mayo 2026 (4
  iteraciones, versión final 3 pasos en light mode con valores).
- `STATE_OF_THE_PLATFORM.md` — sección de cash management.
- PRDs Fiscal Stabilization Program 1–5 (contexto de control fiscal).
- `MANUAL_DEFERRED_DECISION.md` — patrón de decisiones formales.
- `lib/app/theme/sizes.dart` — tokens de spacing/tipografía y reglas de
  `MediaQuery.textScalerOf(context)` ya vigentes.
