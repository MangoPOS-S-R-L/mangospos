# PRD — Extensión Retail de MangoPOS (Colmados, Tiendas y Licorerías)

> **Estado:** Borrador para revisión
> **Fecha:** 2026-06-01
> **Dueño de producto:** Cristian Gómez
> **Ámbito:** Convertir MangoPOS de un POS centrado en restaurante a una plataforma
> multi-vertical que sirva igual de bien a **colmados / tiendas de conveniencia**,
> **tiendas generales** y **licorerías**, sin degradar el producto de restaurante.

---

## 0. Marco competitivo — "de tú a tú con Toast"

La intención estratégica permanente de MangoPOS es **competir de tú a tú con Toast**.
Eso fija el listón de calidad de esta extensión:

- **Toast nació restaurante y se está expandiendo a retail** (Toast Retail, tiendas
  de conveniencia adjuntas a restaurantes, bares con tienda). MangoPOS llega al
  mismo punto desde el otro lado: ya tenemos el restaurante sólido; ahora abrimos
  retail con la **misma profundidad**, no como un "modo simplificado" de segunda.
- **Diferenciador defensivo que Toast no tiene en RD:** cumplimiento fiscal NCF/DGII
  nativo y **offline-first real** (ya construido: F1/F2/F5/F6 en prod). Un colmado
  dominicano no puede usar Toast tal cual; sí puede usar MangoPOS. Ese es el foso.
- **Regla de paridad:** cada flujo retail (escaneo, venta por peso, cuadre de caja,
  impresión, inventario) debe sentirse tan terminado como el flujo de restaurante
  equivalente. Si un colmadero compara con Square/Loyverse/Toast Retail, MangoPOS
  debe ganar en velocidad de cobro, offline y fiscalidad local.

**Implicación de diseño:** NO bifurcar la app en dos productos. Una sola base, una
sola cuenta, gateado por `business_type` + feature flags. Un negocio híbrido
(restaurante con colmado al lado, bar con licorería) debe poder encender ambos
mundos en el mismo dispositivo.

---

## 1. Resumen ejecutivo

MangoPOS hoy es un POS de restaurante completo (mesas, KDS, comandas, split bill,
cuadre de caja, NCF, impresión, offline). El análisis del código muestra que la
**base de datos y los modelos ya son sorprendentemente retail-capaces**: el producto
tiene `barcode`, `sku`, `cost`, `sold_by` (unit/piece/weight/volume/package),
`is_inventory_tracked`; el inventario soporta lotes/vencimiento/movimientos; existe
el modo de venta `quick` (mostrador) y la columna `businesses.business_type` ya
incluye `'Tienda de Conveniencia'`.

Lo que falta **no es esquema, es producto**: gatear lo que es de restaurante (KDS,
mesas, zonas, split bill, comandas), construir el **escaneo de código de barras en
el POS**, la **venta por peso (balanza)**, el **onboarding que autoconfigura según
vertical**, e impresión de **etiquetas/precios**. Más reglas específicas de
licorería (control de edad, restricción horaria) y de colmado (fiado/crédito,
venta granel).

Este PRD define el alcance, el modelo de datos incremental, los feature flags, las
fases de entrega y los criterios de aceptación.

---

## 2. Verticales objetivo y sus diferencias

| Vertical | Características clave | Qué necesita que restaurante no usa |
|---|---|---|
| **Colmado / tienda de conveniencia** | Venta rápida de mostrador, alto volumen de SKUs, fiado a clientes conocidos, venta a granel (libra de arroz, salami), recargas | Escaneo, peso/balanza, **fiado/crédito de cliente**, venta por fracción |
| **Tienda general / minimarket** | Catálogo grande, variantes (talla/color), inventario serio, precios por mayor/detalle | Escaneo, **variantes reales**, **multi-precio (mayor/detalle)**, etiquetas |
| **Licorería / liquor store** | Botellas (SKU + barcode), control de inventario por unidad y por caja, **control de edad**, **restricción horaria de venta de alcohol** | Escaneo, **age-gate**, **bloqueo horario**, unidad↔caja (pack) |

**Punto en común:** todas son **venta de mostrador rápida, sin cocina, sin mesa, con
escaneo, con inventario que descuenta en tiempo real**. Ese es el núcleo "Retail Core".

---

## 3. Estado actual del código (línea base verificada)

### 3.1. Ya retail-ready (NO tocar el esquema, solo exponer en UI)
- **Modelo de producto** — `lib/data/models/menu_item.dart`:
  `barcode`, `sku`, `cost`, `price`, `SoldBy {unit, piece, weight, volume, package}`,
  `hasVariants`, `categoryId`, `isInventoryTracked`, `allowNegativeSale`,
  `printAreaCode`, `taxMode`. Tabla `menu_items` ya tiene todas esas columnas.
- **Inventario** — `lib/presentation/inventory/`, `inventory_repository.dart`:
  `inventory_stock` (qty_on_hand, reserved, unit_of_measure), `inventory_movements`
  (purchase/sale/adjustment/transfer/waste/return), `inventory_lots`
  (lote, vencimiento, costo, FIFO/LIFO), conteos físicos.
- **Compras** — `lib/presentation/purchases/`, `purchases_repository.dart`:
  PO → recepción → movimiento de stock.
- **Modo venta rápida** — ya existe: `salesModeQuickEnabled`, `order_origin = 'quick'`,
  `TableSession.tableId` puede ser NULL (`lib/data/models/sales_models.dart`).
- **Feature flags** — `BusinessFeatures` en
  `lib/data/repositories/pos_settings_repository.dart`; provider en
  `lib/core/business/business_features_provider.dart`; persistidos en
  `business_settings`.
- **`businesses.business_type`** — el CHECK ya incluye `'Tienda de Conveniencia'`
  (y otros). Hoy **no gatea nada**.
- **Impresión** — `lib/core/printing/`, `printing_v2_repository.dart`: recibos
  multi-copia, ruteo por `print_area_code`, network/bluetooth/usb, cola
  `print_jobs`, failover. Reutilizable para etiquetas y display de cliente.
- **Offline + NCF** — F1/F2/F5/F6 en prod; `ncf_sequences`, `fiscal_documents`.

### 3.2. Acoplado a restaurante (gatear / ocultar)
- **Mesas/zonas** — `lib/data/models/dining_table.dart`, tablas `dining_tables`,
  `zones`. `salesModeTableEnabled`.
- **KDS / cocina** — `lib/presentation/kds/`, `lib/presentation/kitchen/`,
  `kitchen_models.dart`. `kitchenEnabled`.
- **Split bill** — `lib/presentation/split_bill/`.
- **Comandas / pre-bills** — impresión de tickets de cocina, `prints_prebills`.

### 3.3. Falta construir (no existe)
- **Escaneo de código de barras en POS** — flag `barcodeEnabled` existe; **no hay UI**.
- **Venta por peso / integración de balanza** — `SoldBy.weight` existe; sin driver.
- **Onboarding por vertical** — `business_type` no autoconfigura flags.
- **Multi-precio** (mayor/detalle) — hoy 1 solo `price`.
- **Fiado / crédito de cliente** — no existe cuenta por cobrar de cliente en POS.
- **Control de edad + bloqueo horario** (licorería) — no existe.
- **Unidad ↔ pack/caja** (vender por unidad o por caja del mismo SKU) — parcial via
  `package`, sin factor de conversión explícito.
- **Etiquetas de precio / código de barras impresas** — infra de impresión existe,
  plantilla no.

---

## 4. Principios de arquitectura para esta extensión

1. **Una sola base, gateada por configuración.** Nada de fork. `business_type`
   define *defaults* de feature flags; el dueño puede ajustar flag por flag.
2. **Seguir el patrón local.** Replicar el camino existente
   router → screen → viewmodel/provider → repository → datasource/model. No inventar
   arquitectura paralela (regla de CLAUDE.md).
3. **Aditivo y compatible.** Migraciones aditivas, columnas nullable, defaults que
   **preservan el comportamiento legacy de restaurante**. Cero regresión.
4. **No tocar áreas sensibles sin gating explícito:** `main.dart`, auth/sesión,
   impresión, flujo de caja, pagos, scoping de negocio/tenant, guards de router.
5. **Offline primero también en retail.** El escaneo, el descuento de inventario y
   el cobro deben funcionar sin conexión, conciliando al reconectar (misma filosofía
   que F1–F6).

---

## 5. Modelo de configuración: `business_type` → feature flags

### 5.1. Perfiles de vertical (defaults sugeridos)

| Flag | Restaurante | Colmado | Tienda | Licorería |
|---|---|---|---|---|
| `salesModeTableEnabled` | ✅ | ❌ | ❌ | ❌ |
| `salesModeQuickEnabled` | ✅ | ✅ | ✅ | ✅ |
| `kitchenEnabled` | ✅ | ❌ | ❌ | ❌ |
| `splitBillEnabled` | ✅ | ❌ | ❌ | ❌ |
| `barcodeEnabled` | opcional | ✅ | ✅ | ✅ |
| `scaleEnabled` (nuevo) | ❌ | ✅ | opcional | ❌ |
| `inventoryMode` | basic | basic/advanced | advanced | advanced |
| `customerCreditEnabled` (nuevo, "fiado") | ❌ | ✅ | opcional | opcional |
| `multiPriceEnabled` (nuevo, mayor/detalle) | ❌ | opcional | ✅ | ✅ |
| `ageRestrictionEnabled` (nuevo) | ❌ | opcional | ❌ | ✅ |
| `alcoholHoursEnabled` (nuevo) | ❌ | opcional | ❌ | ✅ |
| `labelPrintingEnabled` (nuevo) | ❌ | opcional | ✅ | ✅ |

> Los flags nuevos se agregan a `BusinessFeatures` con **default `false`** para no
> alterar a ningún negocio existente. El perfil solo **propone** valores en el
> onboarding; nada se fuerza.

### 5.2. Onboarding por vertical
- Al crear/editar negocio, elegir `business_type`.
- Un servicio `RetailProfileDefaults.forBusinessType(type)` devuelve el set de flags
  sugerido y los aplica a `business_settings` (el dueño puede sobrescribir cualquiera
  en Ajustes).
- **No retroactivo:** negocios existentes conservan sus flags actuales; solo se les
  ofrece "aplicar perfil" de forma explícita.

---

## 6. Requisitos funcionales por área

### 6.1. POS / Caja en modo Retail (núcleo)
- **RF-1 Venta de mostrador por defecto.** Si `!salesModeTableEnabled`, la app abre
  directo en carrito rápido (`origin='quick'`, `tableId=null`), sin selector de mesa.
  Entrada en `lib/presentation/sales/view/sales_shell_view.dart` (ya lee el flag).
- **RF-2 Escaneo de código de barras.** Campo que captura input de pistola/teclado
  (ráfaga rápida + Enter), busca por `menu_items.barcode`, agrega al carrito; si hay
  varias coincidencias o ninguna, feedback inmediato. Debe funcionar **offline**
  contra el catálogo cacheado. Soporte para cámara (móvil) y lector USB/HID (escritorio).
- **RF-3 Venta por peso.** Para `soldBy = weight/volume`, permitir ingreso manual y,
  si `scaleEnabled`, lectura de balanza (ver §7). Calcular precio = peso × precio
  unitario. Mostrar tara opcional.
- **RF-4 Venta por fracción / granel.** Vender 0.5, 0.25 de unidad (libra de arroz,
  fracción de salami) cuando el SKU lo permita.
- **RF-5 Multi-precio.** Si `multiPriceEnabled`, el ítem puede tener precio detalle y
  precio por mayor (o por nivel de cliente); el cajero elige o se aplica por regla.
- **RF-6 Sin cocina, sin comanda.** Si `!kitchenEnabled`, no se envía a KDS, no se
  imprime ticket de cocina; el cobro es inmediato.
- **RF-7 Cuadre de caja idéntico.** Reutilizar el flujo de cierre de caja existente
  (ver `README_CIERRE_CAJA_FLUTTER.md`) sin cambios — es agnóstico de vertical.

### 6.2. Catálogo / Producto
- **RF-8 Variantes retail reales.** Para tienda: variantes por atributo
  (talla/color) con SKU/barcode propio por variante. Distinguir conceptualmente de
  "modificadores" de restaurante (reusar `has_variants` + `modifier_groups` o
  modelar variantes explícitas — decisión D-3).
- **RF-9 Unidad ↔ pack/caja.** Mismo producto vendible por unidad o por caja con
  **factor de conversión** (ej. caja = 24 unidades), descontando inventario en la
  unidad base. Clave para licorería y colmado.
- **RF-10 Costo y margen.** Ya existe `cost`; exponer margen en UI de producto.
- **RF-11 Carga masiva de catálogo.** Import CSV/Excel de productos (un colmado tiene
  cientos de SKUs). Mapear barcode/sku/precio/costo/categoría/stock inicial.

### 6.3. Inventario (retail serio)
- **RF-12 Descuento en tiempo real** al vender (ya soportado por
  `inventory_movements` autoconsume).
- **RF-13 Escaneo en recepción y conteo.** Escanear barcode al recibir compra y al
  hacer conteo físico (hoy falta UI de escaneo en esos flujos).
- **RF-14 Lotes y vencimiento** para perecederos (ya existe `inventory_lots`;
  exponer alertas de vencimiento).
- **RF-15 Alertas de stock bajo / reorden.** Nivel mínimo por producto y aviso.

### 6.4. Cliente / Fiado (colmado)
- **RF-16 Cuenta de cliente / fiado.** Asociar venta a un cliente y dejarla "a
  crédito"; registrar abonos; ver saldo. Cuenta por cobrar simple a nivel de negocio.
  Reusar `lib/presentation/customers/`.
- **RF-17 Límite de crédito** opcional por cliente y bloqueo al excederlo.

### 6.5. Licorería (compliance)
- **RF-18 Control de edad (age-gate).** Si `ageRestrictionEnabled` y el ítem está
  marcado como restringido, exigir confirmación de mayoría de edad antes de cobrar.
- **RF-19 Restricción horaria de alcohol.** Si `alcoholHoursEnabled`, bloquear venta
  de ítems de alcohol fuera del horario legal configurado (RD: ley de horario de
  expendio). Configurable por día.

### 6.6. Impresión retail
- **RF-20 Recibo simplificado.** Sin mesa/mesero/banner de cocina cuando
  `!kitchenEnabled`. Mantener NCF/fiscal.
- **RF-21 Etiquetas de precio / código de barras.** Plantilla de etiqueta ruteable a
  impresora de etiquetas via `print_areas` (reusar infra de impresión).
- **RF-22 Display de cliente** (opcional, reusa print_area / pantalla secundaria).

### 6.7. Fiscal (sin regresión)
- **RF-23 NCF en retail.** El consumo de NCF y `fiscal_documents` funciona igual; un
  colmado emite consumo final/crédito fiscal como el restaurante. Respetar el modelo
  unificado de impuestos (ver nota interna: `service_fee_enabled` debe quedar `false`
  en retail; no introducir service fee).

---

## 7. Hardware

| Dispositivo | Estado | Plan |
|---|---|---|
| **Lector de barras USB/HID** | No integrado | Capturar como teclado (ráfaga + Enter); no requiere driver especial. Cubre la mayoría de colmados. |
| **Cámara como escáner** (móvil/tablet) | No integrado | Usar paquete de escaneo ya disponible o agregar uno (revisar `pubspec.yaml` antes de añadir dependencia, regla CLAUDE.md). |
| **Balanza** | No integrado | Empezar con **entrada manual de peso** (cubre el 80%). Integración serial/USB de balanza como fase posterior, detrás de `scaleEnabled`. |
| **Impresora de etiquetas** | Infra lista | Plantilla nueva + ruteo por `print_area`. |
| **Gaveta de efectivo** | Probable que ya exista via impresora | Verificar en `lib/core/printing/`; el pulso de gaveta suele ir por la impresora de recibos. |

---

## 8. Cambios de esquema (mínimos, aditivos)

> Filosofía igual que las migraciones offline existentes: aditivo, nullable, default
> que preserva legacy. Nada destructivo.

- `business_settings`: nuevas columnas de flags (`scale_enabled`,
  `customer_credit_enabled`, `multi_price_enabled`, `age_restriction_enabled`,
  `alcohol_hours_enabled`, `label_printing_enabled`), todas `not null default false`.
- `menu_items`:
  - `is_age_restricted boolean not null default false` (licorería).
  - `pack_factor numeric` nullable + `pack_barcode text` nullable (unidad↔caja),
    o tabla `menu_item_units` si se quiere N unidades (decisión D-2).
  - `min_stock numeric` nullable (alertas de reorden).
- Multi-precio: tabla `menu_item_prices` (`menu_item_id`, `price_tier`, `price`) o
  columnas `price_wholesale` (decisión D-1; tabla escala mejor).
- Fiado: reusar/`extender` lo de `customers`; cuenta por cobrar
  (`customer_credit_entries`: venta, abono, saldo) — decisión D-4.
- Horario alcohol: `business_settings.alcohol_hours` jsonb (por día).

**Todo lo demás (productos, inventario, lotes, NCF, impresión) NO requiere esquema
nuevo.**

---

## 9. Fases de entrega

> Cada fase entra detrás de flags, aditiva, sin regresión a restaurante. Orden por
> valor/riesgo. Nomenclatura `R#` (Retail).

### **R0 — Gating y perfiles (fundación)** · riesgo bajo
- Agregar flags nuevos a `BusinessFeatures` (default false).
- `RetailProfileDefaults.forBusinessType()` + onboarding que sugiere perfil.
- Ocultar mesas/KDS/split bill/comandas cuando los flags están en off.
- **Resultado:** un negocio puede ponerse en "modo colmado" y la app se ve retail
  (venta rápida, sin cocina). Sin escaneo aún.
- **Aceptación:** crear negocio "Tienda de Conveniencia" → abre en carrito rápido,
  sin pestaña de cocina/mesas; restaurante existente intacto.

### **R1 — Escaneo de código de barras en POS** · riesgo medio · ALTO valor
- Captura HID + búsqueda por barcode offline + agregar al carrito.
- Escaneo por cámara en móvil.
- **Aceptación:** escanear 20 productos seguidos los agrega correctamente, offline,
  < X ms por escaneo.

### **R2 — Venta por peso/fracción + multi-precio** · riesgo medio
- Entrada manual de peso, venta por fracción, precio mayor/detalle.
- **Aceptación:** vender 0.75 lb de un producto por peso calcula precio correcto;
  aplicar precio por mayor cambia el total.

### **R3 — Inventario retail + carga masiva** · riesgo medio
- Escaneo en recepción/conteo, alertas de stock mínimo, import CSV de catálogo.
- **Aceptación:** importar 300 SKUs desde CSV; recibir compra escaneando; alerta de
  stock bajo dispara.

### **R4 — Fiado / crédito de cliente (colmado)** · riesgo medio
- Venta a crédito, abonos, saldo, límite.
- **Aceptación:** vender a crédito a un cliente, registrar abono, saldo cuadra; todo
  offline-conciliable.

### **R5 — Compliance licorería** · riesgo bajo-medio
- Age-gate por ítem, bloqueo horario de alcohol.
- **Aceptación:** intentar vender alcohol fuera de horario se bloquea; ítem
  restringido pide confirmación de edad.

### **R6 — Etiquetas / display de cliente** · riesgo bajo
- Plantilla de etiqueta de precio/barcode ruteada a impresora de etiquetas.
- **Aceptación:** imprimir etiqueta legible con barcode escaneable de vuelta.

### **R7 — Balanza por hardware** · riesgo alto · diferible
- Driver serial/USB de balanza detrás de `scaleEnabled`.
- **Aceptación:** leer peso de balanza física llena el campo automáticamente.

> R0–R3 entregan un colmado/tienda **funcional y competitivo**. R4–R7 profundizan por
> vertical. Priorizar R0→R1→R3 para tener "vender escaneando con inventario" cuanto antes.

---

## 10. Decisiones abiertas (a confirmar antes de construir)

- **D-1 Multi-precio:** ¿columnas (`price_wholesale`) o tabla `menu_item_prices`?
  → Recomendado: tabla (escala a niveles de cliente).
- **D-2 Unidad↔caja:** ¿`pack_factor` en `menu_items` o tabla `menu_item_units`?
  → Recomendado: tabla si se necesitan >2 unidades por SKU.
- **D-3 Variantes retail vs modificadores:** ¿reusar `modifier_groups`/`has_variants`
  o modelar variantes explícitas con SKU/barcode por variante?
- **D-4 Fiado:** ¿módulo de cuentas por cobrar propio o extensión de `customers`?
- **D-5 Híbridos:** ¿UI para un negocio que es restaurante **y** colmado a la vez?
  (encender ambos sets de flags en el mismo dispositivo).
- **D-6 Escáner cámara:** ¿qué paquete? Revisar `pubspec.yaml` antes de añadir.

---

## 11. Riesgos y mitigaciones

- **Regresión a restaurante** (área sensible). → Todo detrás de flags con default
  legacy; QA de regresión de mesas/KDS/split bill/cuadre en cada fase.
- **Fiscal NCF en retail.** → No cambiar mecánica de emisión; reusar tal cual;
  validar que `service_fee_enabled=false` y modelo unificado de impuestos no se rompa.
- **Offline.** → Escaneo y descuento de inventario deben operar contra cache y
  conciliar (seguir patrón F1–F6); no asumir conexión.
- **Rendimiento de catálogo grande** (cientos/miles de SKUs por negocio). → Indexar
  `barcode`/`sku`; búsqueda local eficiente; paginación en UI de productos.
- **Compliance licorería mal configurada** (bloqueo horario). → Defaults
  conservadores, claramente editables, con aviso al dueño.
- **Hardware heterogéneo** (lectores/balanzas baratos). → Empezar por HID/manual
  (cobertura amplia sin drivers); hardware específico como fase aislada.

---

## 12. Métricas de éxito

- **Adopción:** # de negocios con `business_type` retail activos.
- **Velocidad de cobro:** tiempo medio de una venta de mostrador escaneada
  (objetivo: igual o mejor que Square/Loyverse/Toast Retail).
- **Escaneo:** % de ítems agregados por escaneo vs manual.
- **Offline:** % de ventas retail completadas sin conexión y conciliadas sin error.
- **Inventario:** exactitud de stock (conteo físico vs sistema).
- **Sin regresión:** 0 incidentes en flujos de restaurante (mesas/KDS/caja/fiscal).

---

## 12-bis. Reportes retail (extensión del módulo de Reportes)

El módulo de Reportes ya es maduro (ventas con 11 sub-reportes, por mesero, caja,
impuestos, compras, inventario, fiscal; export PDF/CSV; presets de fecha; cache
offline; `fl_chart`). Estos **extras** no existen y son los que un retailer espera —
donde le ganamos a Square/Loyverse en RD. Algunos sirven también a restaurante y se
pueden adelantar en `main`.

### Transversales (sirven a restaurante Y retail — adelantables en `main`)
- **RF-R1 Margen / rentabilidad por producto y categoría.** Utilidad bruta
  (venta neta − costo) y margen %. El RPC `get_sales_summary_v2` ya emite `cost` y
  `gross_profit` stubbeados en 0; solo hay que cablear el costo real. Ver
  [SPEC_REPORTE_MARGEN.md](SPEC_REPORTE_MARGEN.md). **Mejor relación valor/esfuerzo.**
- **RF-R2 Comparación de períodos.** "Este período vs anterior", % de crecimiento,
  flechas. Hoy se filtra por rango pero no se compara. Polish de alto impacto.
- **RF-R3 Auditoría de anulaciones/descuentos/cortesías (loss prevention).** Vista
  dedicada: quién anuló, tendencia de cortesías, reembolsos.
- **RF-R4 Cierre Z / Reporte X.** Resumen fiscal de fin de día (estándar retail que
  piden contadores). Refuerza el foso fiscal NCF. Data ya disponible.
- **RF-R5 Heatmap hora × día de la semana.** Para staffing/horarios. Ya existe el
  breakdown por hora; falta la matriz visual.

### Retail-específicos (dependen de fases de este PRD)
- **RF-R6 Rotación de inventario y stock muerto.** *El reporte más importante para un
  colmado* (cientos de SKUs): qué no se mueve en 30/60/90 días y velocidad de
  rotación. Se arma con `inventory_movements`. → Fase **R3**.
- **RF-R7 Valorización de inventario (FIFO/LIFO).** Valor del stock a costo, usando
  `inventory_lots`. Estándar retail/contable. → Fase **R3**.
- **RF-R8 Sugerencia de reorden / punto de pedido.** Basada en velocidad de venta.
  Feature "killer". → Fase **R3**.
- **RF-R9 Aging de cuentas por cobrar (fiado).** Saldos por cliente por antigüedad
  (0-30 / 31-60 / +60). → Fase **R4**.
- **RF-R10 Registro de ventas restringidas (licorería).** Log auditable de ventas de
  alcohol/edad-restringida con hora, para cumplimiento. → Fase **R5**.

### Polish (cuando haya tracción)
- **RF-R11 Reportes programados** (email/WhatsApp): digest diario/semanal al dueño
  (encaja con la infra de agentes/`schedule`).
- **RF-R12 Análisis de canasta** (qué se vende junto): colocación de productos y combos.

> **Orden sugerido por impacto/esfuerzo:** RF-R1 → RF-R2 → RF-R6 → RF-R4. Los R1/R2/R4
> no dependen de la rama retail y benefician a los restaurantes hoy.

---

## 13. Fuera de alcance (por ahora)

- E-commerce / tienda online.
- Programa de lealtad/puntos (futuro).
- Combos/bundles complejos (mencionado como futuro en el código).
- Integración contable externa.
- Balanza por hardware queda en R7 (diferible).

---

## 14. Referencias de código (anclas)

- Producto: `lib/data/models/menu_item.dart` · tabla `menu_items`
- Flags: `lib/data/repositories/pos_settings_repository.dart` (`BusinessFeatures`),
  `lib/core/business/business_features_provider.dart`, tabla `business_settings`
- Modos de venta: `lib/presentation/sales/view/sales_shell_view.dart`
- Caja/sesión: `lib/data/models/sales_models.dart` (`TableSession`),
  `lib/presentation/cashier/`
- Restaurante a gatear: `lib/presentation/kds/`, `lib/presentation/kitchen/`,
  `lib/presentation/split_bill/`, `lib/data/models/dining_table.dart`
- Inventario: `lib/presentation/inventory/`, `lib/data/repositories/inventory_repository.dart`
- Compras: `lib/presentation/purchases/`
- Impresión: `lib/core/printing/`, `lib/data/repositories/printing_v2_repository.dart`
- `businesses.business_type`: ver CHECK en `supabase/schema.sql`
- Cuadre de caja: `README_CIERRE_CAJA_FLUTTER.md`
