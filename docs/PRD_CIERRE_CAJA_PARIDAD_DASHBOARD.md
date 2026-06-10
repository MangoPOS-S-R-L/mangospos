# PRD — Paridad del Cierre de Caja en el Dashboard

**Objetivo:** que la información del **cierre de caja** se muestre en el
**dashboard** (web / administrador) **igual** que en la app POS (Flutter), con
los mismos números y las mismas reglas de cálculo. Esto corrige una
inconsistencia ya arreglada en la app: la "Diferencia" mostraba la diferencia
de **solo efectivo** junto a totales de **todos los métodos**.

- **Estado app POS:** corregido (rama `fix/cash-close-difference-empty-input`).
- **Estado dashboard:** pendiente — este PRD.
- **Fecha:** 2026-06-10.

---

## 1. Contexto y problema

Un cierre real (negocio `800e4643-d35a-4795-b9c3-f70c71bc1187`, 09/06/2026)
mostró números contradictorios:

| Dato | Valor | Origen |
|---|---|---|
| Total Esperado (todos los métodos) | 63,835 | `fn_get_cash_session_summary.expected_total` |
| Total Reportado (todos los métodos) | 63,985 | suma de lo contado/reportado por método |
| **Diferencia mostrada** | **2,700** ❌ | `cash_register_sessions.difference` (solo efectivo) |
| **Diferencia correcta (neta)** | **150** ✅ | `63,985 − 63,835` |

Desglose por método:
- Efectivo: contado 24,310 vs esperado 21,610 → **+2,700**
- Tarjeta: reportado 39,675 vs esperado 42,225 → **−2,550**
- **Neto: +150**

**Causa raíz:** la columna `cash_register_sessions.difference` la calcula
`fn_close_cash_session` como **`end_amount(efectivo) − esperado_efectivo`** — es
una diferencia **solo de efectivo**, intencional para conciliar la gaveta. El
error es de **presentación**: mostrar ese número como "Diferencia" debajo de los
totales de todos los métodos. El dashboard debe replicar la corrección de la app.

> ⚠️ **Trampa #1:** `cash_register_sessions.end_amount` es **solo el efectivo a
> depositar** (24,310), **NO** el total reportado de todos los métodos (63,985).
> El dashboard NO debe usar `end_amount` como "Total Reportado".

> ⚠️ **Trampa #2:** `cash_register_sessions.difference` es **solo efectivo**
> (2,700). NO debe mostrarse como diferencia total.

---

## 2. Objetivo y resultado esperado

El dashboard, al mostrar el resumen/detalle de un cierre, debe presentar:

1. **Ventas por método** (efectivo, tarjeta, transferencia, total).
2. **Flujo de efectivo** (monto inicial, depósitos, retiros, gastos).
3. **Esperado por método** (esperado efectivo / tarjeta / transferencia).
4. **Resultados del cierre**:
   - Total Esperado (todos los métodos).
   - Total Reportado (todos los métodos).
   - **Diferencia NETA = Total Reportado − Total Esperado** (el "headline").
5. **Diferencia por método** (efectivo, tarjeta, transferencia) — para revelar
   patrones como "+efectivo / −tarjeta" (método mal clasificado).

Todos los valores deben **coincidir exactamente** con los de la app POS para la
misma sesión.

---

## 3. Alcance

**Incluye:**
- Vista de detalle/resumen de un cierre en el dashboard.
- Vista de lista de cierres (si existe): etiqueta correcta de la diferencia.
- Reportes/exportaciones de cierre que muestren "diferencia".

**No incluye (esta iteración):**
- Cambiar la lógica SQL de `fn_close_cash_session` (la diferencia de efectivo
  guardada sigue siendo válida como dato de conciliación de gaveta).
- Reescribir cierres históricos.

---

## 4. Fuentes de datos (contrato)

### 4.1. RPC `fn_get_cash_session_summary(p_session_id uuid)` → jsonb
**Única fuente de verdad para los ESPERADOS y las ventas.** Campos relevantes:

| Campo | Significado |
|---|---|
| `start_amount` | Monto inicial de la caja |
| `cash_sales_net` | Ventas netas en efectivo del turno |
| `total_sales_all_methods` | Ventas totales (todos los métodos) |
| `total_deposits` / `total_withdrawals` / `total_expenses` | Movimientos manuales |
| `expected_cash` | Esperado efectivo = `start + cash_sales_net + deposits − withdrawals − expenses` |
| `expected_card` | Esperado tarjeta (= ventas tarjeta) |
| `expected_transfer` | Esperado transferencia (= ventas transferencia) |
| `expected_total` | `expected_cash + expected_card + expected_transfer` |
| `transaction_count` | # de transacciones |

> El dashboard **siempre** debe derivar los esperados de este RPC, **nunca** de
> valores potencialmente en cero almacenados en la sesión.

### 4.2. Tabla `cash_register_sessions`
| Columna | Significado | Uso en dashboard |
|---|---|---|
| `start_amount` | Monto inicial | informativo |
| `end_amount` | **Efectivo a depositar** (solo efectivo) | **NO usar como Total Reportado** |
| `difference` | **Diferencia de EFECTIVO** (`end_amount − esperado_efectivo`) | etiquetar "Dif. efectivo", **no** como diferencia total |
| `notes` | Cadena con el desglose reportado (ver 4.3) | parsear "Total reportado" y los reportados por método |
| `status`, `opened_at`, `closed_at` | estado/fechas | informativo |

### 4.3. Formato de `notes` (lo reportado por el cajero)
La app embebe el desglose reportado en `notes`. **Hay dos formatos** según el
modo de cierre — el dashboard debe soportar ambos:

**Cierre ciego (compact):**
```
Cierre ciego | Efectivo: {efectivo} | Tarjetas: {tarjeta} | Transferencias: {transfer} | Total reportado: {total} | Dif. efectivo: {x} | Dif. tarjeta: {y} | Dif. transferencia: {z} | Dif. total: {n} [| Cierre forzado con N mesa(s) abiertas]
```

**Cierre detallado (wizard):**
```
Cierre detallado | Efectivo: {efectivo} | Tarjeta: {tarjeta} | Transferencia: {transfer} | Total reportado: {total}
```

> ⚠️ **Trampa #3 (inconsistencias del string):**
> - El ciego usa `Tarjetas`/`Transferencias` (plural); el detallado usa
>   `Tarjeta`/`Transferencia` (singular). El parser debe aceptar ambos.
> - Los campos `Dif. *` del ciego **pueden ser basura** en cierres viejos (se
>   calcularon con esperado = 0 por un bug ya corregido). **NO confiar en
>   `Dif. total` de las notas**; calcular la diferencia en el cliente.
> - El detallado **no** trae campos `Dif. *`.

**Recomendación fuerte (deuda técnica):** migrar el reportado por método y el
total a **columnas estructuradas** (`reported_cash`, `reported_card`,
`reported_transfer`, `reported_total`) en vez de parsear `notes`. Ver §8.

---

## 5. Reglas de cálculo (canónicas — replican la app)

Dado `summary = fn_get_cash_session_summary(sessionId)` y la sesión:

```
expectedCash      = summary.expected_cash
expectedCard      = summary.expected_card
expectedTransfer  = summary.expected_transfer
expectedTotal     = summary.expected_total            // = suma de los 3

// Reportado: parsear de notes (NO usar end_amount).
reportedCash      = notes.Efectivo
reportedCard      = notes.Tarjeta(s)
reportedTransfer  = notes.Transferencia(s)
reportedTotal     = notes["Total reportado"]
                    ?? (reportedCash + reportedCard + reportedTransfer)

// Diferencias por método
diffCash      = reportedCash     − expectedCash        // +2,700 en el ejemplo
diffCard      = reportedCard     − expectedCard        // −2,550
diffTransfer  = reportedTransfer − expectedTransfer    // 0

// DIFERENCIA NETA (el "headline")
diffTotal     = reportedTotal − expectedTotal          // +150  ✅
```

**Guard (sesiones viejas / notas no parseables):** si `reportedTotal <= 0`
(no se pudo parsear), usar `cash_register_sessions.difference` como respaldo
para no mostrar un neto negativo falso. (Es exactamente lo que hace la app.)

**Color/signo:** `diffTotal == 0` → neutro; `> 0` → verde (sobrante);
`< 0` → rojo (faltante).

---

## 6. Especificación de UI

### 6.1. Detalle / "Ver resumen" de un cierre
Secciones (mismo orden que la app):

1. **Información general:** cajero, abierta, cerrada.
2. **Ventas:** Efectivo / Tarjeta / Transferencia / **Total ventas** (negrita).
3. **Flujo de efectivo:** Monto inicial / Depósitos (+) / Retiros (−) / Gastos (−).
4. **Esperado por método:** Esperado Efectivo / Tarjeta / Transferencia.
5. **Resultados del cierre:**
   - Total Esperado = `expectedTotal`
   - Total Reportado = `reportedTotal`
   - **Diferencia = `diffTotal`** (neta) — resaltada con color por signo.
6. **Diferencia por método** (nuevo, recomendado): Efectivo `diffCash`,
   Tarjeta `diffCard`, Transferencia `diffTransfer`. Hace visible el patrón
   "+efectivo / −tarjeta" (método mal clasificado).
7. **Notas:** texto crudo de `notes` (informativo).

### 6.2. Lista de cierres
- Si se muestra un único número de diferencia por fila y solo se tiene
  `session.difference` (sin llamar al RPC por fila), **etiquetarlo
  "Dif. efectivo"** (no "Diferencia"), porque es la diferencia de efectivo.
- La diferencia **neta** se muestra al abrir el detalle (donde sí se llama al
  RPC). Alternativa: si el dashboard puede traer `expected_total` por fila de
  forma barata, mostrar la neta también en la lista.

---

## 7. Casos borde

1. **Cierre con esperado 0 por fallo de carga (bug histórico):** ya no debe
   ocurrir en cierres nuevos (la app ahora aborta el cierre si no puede cargar
   los datos en vez de cerrar con ceros). Para cierres viejos afectados, el
   dashboard recalcula esperados desde el RPC, así que mostrará los esperados
   reales aunque las `notes` tengan `Dif.` basura.
2. **Sesión abierta:** no mostrar diferencia (no hay cierre).
3. **`notes` ausente/malformado:** aplicar el guard de §5 (caer a
   `session.difference`); mostrar Total Reportado = `reportedTotal` o, si 0,
   `end_amount` como último recurso (documentar que es solo efectivo).
4. **Cierre forzado con mesas abiertas:** la nota incluye "Cierre forzado con
   N mesa(s) abiertas"; mostrarla como advertencia.

---

## 8. Recomendación de deuda técnica (opcional, fuera del MVP)

Parsear `notes` es frágil (dos formatos, plural/singular, campos basura).
Recomendado a futuro:
- Agregar columnas estructuradas a `cash_register_sessions`:
  `reported_cash`, `reported_card`, `reported_transfer`, `reported_total`,
  `diff_total` (neta).
- Que `fn_close_cash_session` reciba/guarde esos valores.
- Dashboard y app leen columnas en vez de parsear `notes`.

Esto eliminaría las tres "trampas" de este PRD. **No bloquea el MVP**, que se
resuelve con las reglas de §5 sobre los datos actuales.

---

## 9. Criterios de aceptación

Usando la sesión del ejemplo (negocio `800e4643…`):

| # | Caso | Esperado |
|---|---|---|
| 1 | Detalle del cierre | Total Esperado **63,835**, Total Reportado **63,985**, **Diferencia 150** (verde) |
| 2 | Diferencia por método | Efectivo **+2,700**, Tarjeta **−2,550**, Transferencia **0** |
| 3 | Lista de cierres | la fila muestra **"Dif. efectivo: 2,700"** (etiquetado), no "Diferencia: 2,700" |
| 4 | Paridad con app | los 5 valores anteriores coinciden carácter por carácter con la app POS para la misma sesión |
| 5 | Notas basura | aunque `notes` diga `Dif. total: 63985`, el dashboard muestra **150** (lo calcula, no lo lee de notas) |
| 6 | Esperado nunca en cero | Total Esperado se deriva de `fn_get_cash_session_summary`, nunca de `end_amount`/0 |

---

## 10. Referencias (implementación de la app POS)

- `lib/presentation/cashier/view/cash_closures_view.dart`
  - `_showSummary(...)` — modal de resumen; `difference = reportedTotal − expectedTotal` con guard.
  - `_reportedBreakdown(session)` — parser de `notes` (acepta los dos formatos).
  - Lista — etiqueta "Dif. efectivo".
- `lib/presentation/cashier/state/blind_cash_close_models.dart`
  - `CashCloseCalculator.calculate()` — `totalDifference = totalReported − expectedTotal`.
- `lib/presentation/cashier/view/cashier_view.dart`
  - `_buildCloseInput()` — usa `fn_get_cash_session_summary`; carga de movimientos resiliente; aborta el cierre si no puede cargar los datos (evita cierres con esperado 0).
- SQL: `supabase/migrations/20260514_0001_fix_cash_close_missing_start_amount.sql`
  (`fn_close_cash_session`: `difference = end_amount − expected_cash`, solo efectivo),
  y `fn_get_cash_session_summary` (esperados por método).
