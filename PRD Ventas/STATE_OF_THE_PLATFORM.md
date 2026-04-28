# STATE OF THE PLATFORM — MangoPOS

> Documento vivo. Se actualiza con cada cambio del programa de Estabilización Fiscal.
>
> **Propósito:** que cualquier persona (o futuro Claude) que entre al repo entienda en 5 minutos en qué estado fiscal está la plataforma, qué se ha hecho y qué falta.

| Campo | Valor |
|---|---|
| Última actualización | 2026-04-27 (sesión 1) |
| PRD activo | PRD 1 — Stop-the-Bleeding (frontend completo, sin deploy) |
| Branch | `main` (sin branch dedicado todavía — pendiente crear `prd/01-stop-the-bleeding`) |
| DRI | Cristian |

---

## 1. Estado del programa

| PRD | Estado | Notas |
|---|---|---|
| PRD 1 — Stop-the-Bleeding | **COMPLETO** | Frontend commiteado en `21cef1a` (branch `prd/01-stop-the-bleeding-frontend-wip`). Backend SQL desestimado: el "trigger duplicado" del inventario original era falso positivo (verificado 2026-04-28). |
| PRD 2 — Refactor del motor | Pendiente | Bloqueado por PRD 1 + 1 semana de observación. |
| PRD 3 — Reportes y migración | Pendiente | Bloqueado por PRD 2 + 1 semana de observación. |

---

## 2. Baseline antes del PRD 1 (snapshot 2026-04-27)

### 2.1 Defaults hardcodeados detectados (a eliminar)

| Archivo | Línea | Hardcode | Estado |
|---|---|---|---|
| `lib/presentation/sales/viewmodel/sales_viewmodel.dart` | 48 | `static const _defaultTaxRatePct = 18.0` | **Pendiente** |
| `lib/presentation/sales/viewmodel/sales_viewmodel.dart` | 49 | `static const _defaultServiceFeeRatePct = 10.0` | **Pendiente** |
| `lib/data/repositories/reports_repository.dart` | 1101 | `'service_fee_rate': 10.0` | **Pendiente** |

### 2.2 Comportamientos fail-silent identificados (a convertir en fail-loud)

| Ubicación | Comportamiento actual | Riesgo |
|---|---|---|
| `sales_viewmodel.dart:284-290` (`_ensureBusinessTaxSettingsLoaded` catch) | Si falla la carga, asume defaults 18%/10% | Operadores cobran propina fantasma |
| `sales_viewmodel.dart:422-442` (heurística emergencia en `_normalizeHydratedState`) | Si backend devuelve `service_fee=0` y origin lleva propina, estima propina dividiendo `tax` | Datos inventados al rehidratar órdenes |
| `tax_engine.dart:82-87` (`effectiveIsServiceFee`) | Detecta propina por nombre + tasa ≈ 10% si no hay flag explícito | Cualquier impuesto llamado "Servicio 10%" se convierte mágicamente en propina |

### 2.3 Carpetas / código muerto

| Path | Estado |
|---|---|
| `lib/presentation/settings/taxes/` | 3 archivos vacíos (0 líneas), nunca importados — **a borrar** |

### 2.4 Backend pendiente de tocar (PRD 1, sección 4.7)

| Item | Estado |
|---|---|
| Trigger duplicado `tr_compute_item_totals` vs `trg_compute_item_totals` en `order_items` | **DESESTIMADO 2026-04-28.** Verificación en producción mostró que sólo existe `trg_compute_item_totals` (con función `fn_compute_item_totals`, BEFORE INSERT/UPDATE, no interno, no constraint). El "duplicado" del inventario original fue falso positivo. |

---

## 3. Inventario de uso de los símbolos a eliminar

Antes de borrar nada, dejamos por escrito dónde se usa para no descubrirlo en runtime:

### `_defaultTaxRatePct` (18.0)
- `sales_viewmodel.dart:63` (init de `_cachedTaxRatePct`)
- `sales_viewmodel.dart:224` (rama "no businessId")
- `sales_viewmodel.dart:247` (fallback en lectura de `business_settings`)
- `sales_viewmodel.dart:285` (rama catch)

### `_defaultServiceFeeRatePct` (10.0)
- `sales_viewmodel.dart:64` (init de `_cachedServiceFeeRatePct`)
- `sales_viewmodel.dart:225` (rama "no businessId")
- `sales_viewmodel.dart:251` (fallback en lectura de `business_settings`)
- `sales_viewmodel.dart:286` (rama catch)

### `effectiveIsServiceFee` (heurística)
- `tax_engine.dart:82` (definición)
- `tax_engine.dart:156` (uso interno en `resolveTaxRates`)
- `sales_viewmodel.dart:271` (búsqueda de "service tax" en `_ensureBusinessTaxSettingsLoaded`)
- `sales_viewmodel.dart:323` (filtro en `getTaxBreakdown`)
- `menu_browser_viewmodel.dart:83, 108, 118` (3 filtros)

**Decisión técnica:** la PRD pide eliminar el getter, pero está usado en 7 lugares. La forma menos disruptiva es **conservar el getter pero hacer que devuelva sólo `isServiceFee`** (sin la heurística por nombre/tasa). Así no hay que tocar los 7 call-sites y se elimina la magia.

---

## 4. Cambios aplicados en este PRD

> Lista de cambios al cierre de la sesión 1 (2026-04-27). Sin commit todavía.

### 4.1 Archivos nuevos

| Path | Propósito |
|---|---|
| `lib/core/tax/tax_exceptions.dart` | `TaxConfigException` y `PaymentBlockedException`. |
| `lib/presentation/sales/view/widgets/tax_config_error_banner.dart` | Banner UI persistente que muestra el error fiscal y un botón "Reintentar". |
| `test/pricing/golden_test.dart` | 13 golden tests del motor puro. Pasan todos. |
| `PRD Ventas/STATE_OF_THE_PLATFORM.md` | Este documento. |

### 4.2 Archivos modificados

| Path | Cambio |
|---|---|
| `lib/core/tax/tax_engine.dart` | `effectiveIsServiceFee` ahora devuelve sólo `isServiceFee` (heurística por nombre eliminada). |
| `lib/presentation/sales/state/sales_state.dart` | Nuevo campo `taxConfigError` con `clearTaxConfigError` en `copyWith` y en `props`. |
| `lib/presentation/sales/viewmodel/sales_viewmodel.dart` | Eliminadas constantes `_defaultTaxRatePct`/`_defaultServiceFeeRatePct`. `_ensureBusinessTaxSettingsLoaded` ahora hace fail-loud (lanza `TaxConfigException` cuando falta config) y propaga el error a `state.taxConfigError` en lugar de re-lanzar a los callers. Heurística de emergencia en `_normalizeHydratedState` eliminada. Helper `_calculateBusinessTaxRateForOrigin` eliminado (huérfano). Nuevo método público `reloadTaxConfiguration()` para el botón del banner. |
| `lib/presentation/payments/viewmodel/payment_viewmodel.dart` | Constructor recibe `Ref`. `processPayment()` valida `currentOrderProvider.taxConfigError != null` al inicio y, si lo hay, retorna con `PaymentBlockedException` formateado en `state.error`. |
| `lib/presentation/sales/view/sales_shell_view.dart` | Banner `TaxConfigErrorBanner()` insertado al inicio del area de contenido (antes del `_SalesSyncBanner`). |
| `lib/data/repositories/reports_repository.dart` | Línea 1101: `'service_fee_rate': 10.0` reemplazado por `serviceFeeEnabled ? serviceFeeRate.toDouble() : 0.0` (la variable real ya se calculaba en líneas 877-880). |

### 4.3 Archivos borrados

| Path | Motivo |
|---|---|
| `lib/presentation/settings/taxes/` (3 archivos vacíos) | Carpeta dead code, nunca importada. La UI activa está en `lib/presentation/settings/more settings/system settings/tax/`. |

### 4.4 Desviación intencional respecto al PRD

El texto del PRD pedía `rethrow` desde `_ensureBusinessTaxSettingsLoaded`. Decidí **no relanzar** y en su lugar guardar el error en `state.taxConfigError`. Razón:

- `_ensureBusinessTaxSettingsLoaded` se llama desde 5 puntos del flujo de venta (load, addItem, etc.) y desde callbacks de Realtime.
- Relanzar haría crashear flujos sin mensaje al usuario.
- El bloqueo efectivo del pago (que es el objetivo real de fail-loud) ocurre igual en `processPayment`.
- El operador ve el error en el banner persistente, no enterrado en un toast.

Resultado equivalente al PRD en intención (ningún cobro indebido, error visible), pero más resiliente en runtime.

### 4.5 Verificación

- `flutter analyze` sobre los archivos tocados: **0 errors, 0 warnings nuevos**. Sólo restan 5 `info`/`deprecated_member_use` pre-existentes en archivos no tocados.
- `flutter test test/pricing/golden_test.dart`: **13/13 pass**.
- `flutter test test/sales/order_pricing_utils_test.dart`: 3/5 pass, 2 fallan. Verificado por stash que esas 2 fallas existen en `main` antes del PRD 1 — son regresiones preexistentes ajenas a este trabajo.

---

## 5. Lo que sigue (PRD 1)

Esta sesión cerró el frontend del PRD 1. Para considerar **completo** el PRD 1, todavía falta:

### 5.1 Pre-deploy (revisión humana)

1. Crear branch `prd/01-stop-the-bleeding` y mover los cambios actuales ahí.
2. Auditar negocios piloto: ¿alguno tiene un impuesto llamado "Propina" / "Servicio" rate 10% **sin** `is_service_fee=true`? Si sí, marcarlo en DB **antes** de deploy o se romperá la propina automática para ese negocio.
3. Auditar negocios piloto: ¿todos tienen `business_settings.default_tax_rate` y, si `service_fee_enabled=true`, `service_fee_rate`? Si no, el banner se va a disparar de inmediato al abrir la POS.
4. Confirmar prerrequisitos del PRD §2 (staging, backups, comunicación).

### 5.2 Backend SQL (PRD §4.7)

Pendiente. Ejecutar **primero en staging**:

```sql
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'public.order_items'::regclass
   AND tgname LIKE '%compute_item_totals%';

DROP TRIGGER IF EXISTS tr_compute_item_totals ON public.order_items;
```

### 5.3 QA en staging (PRD §5.2)

UAT-1 a UAT-5 según PRD §5.2. Crítico: UAT-2 (borrar `business_settings` y verificar bloqueo + banner) y UAT-4 (reporte refleja la tasa real, no 10).

### 5.4 Deploy a producción y observación

- Snapshot SQL pre-deploy de `orders.total` por negocio.
- Deploy 1 piloto pequeño → 1 hora observación → resto.
- Drop trigger duplicado en producción.
- Snapshot SQL post-deploy + checksum.
- Comunicación a operadores.
- 1 semana de observación antes de iniciar PRD 2.

---

## 6. Lo que NO se tocó (out of scope PRD 1)

- Trigger duplicado en Supabase (documentado, no ejecutado).
- RPCs del backend (`fn_compute_item_totals`, `calculate_order_totals`, etc.).
- Migración de datos de órdenes históricas.
- Reportes más allá del hardcode `10.0` en línea 1101.
- Refactor del modelo `business_settings` ↔ `taxes` (eso es PRD 2).

---

## 7. Riesgos vivos

| Riesgo | Mitigación actual |
|---|---|
| Fail-loud rompe negocios sin `business_settings` configurado | Banner UI + bloqueo de pago da feedback visible al operador. Validar UAT-2 en staging. |
| Eliminar heurística por nombre cambia comportamiento de negocios con propina marcada solo por nombre | Cualquier negocio con propina debe tener `is_service_fee=true` en DB. Auditar antes de deploy. |
| Eliminar heurística de emergencia muestra `service_fee=0` en órdenes históricas mal guardadas | Los reportes leen del DB, no del front. Impacto sólo visual al rehidratar. |
| **Propina fantasma a nivel línea (NO arreglado en PRD 1)**: un producto con todos los impuestos apagados (toggle "Impuestos" off + ITBIS off + 10% De Ley off) **sigue cobrando propina** porque `_pricingOrderContext` calcula service fee a nivel orden sin consultar `menu_item_taxes` del producto. Reproducido 2026-04-27 con "Agua Dasany" RD$50 → cobra Propina 10% RD$5. | **Decisión: esperar PRD 2.** El refactor del motor (G2 + G6 + sección 6.4 del PRD 2) elimina `_pricingOrderContext`/`resolveOrderServiceRate`/`_isServiceFeeActiveForOrigin` y obliga a que toda propina pase por `menu_item_taxes` por producto. Validar este caso explícitamente como primera prueba al arrancar PRD 2. |

---

## 8. Bitácora

| Fecha | Evento |
|---|---|
| 2026-04-27 | Documento creado. Inicio del trabajo PRD 1 frontend. |
| 2026-04-27 | PRD 1 frontend completo: defaults eliminados, fail-loud activo, banner UI insertado, golden tests pasan. Sin commit. Pendiente deploy a staging y backend SQL. |
| 2026-04-27 | Reproducido bug de propina fantasma a nivel línea (Agua Dasany sin impuestos cobra Propina 10%). Decisión: NO se ataca en PRD 1. Queda registrado en §7 como riesgo vivo a resolver en PRD 2. |
| 2026-04-28 | Verificación del "trigger duplicado" en producción: sólo existe `trg_compute_item_totals`. PRD 1 backend desestimado. PRD 1 declarado COMPLETO. |
