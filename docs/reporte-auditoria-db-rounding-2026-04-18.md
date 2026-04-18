# Auditoría DB: drift de 1 centavo / impuestos inclusivos

Fecha: 2026-04-18

## Alcance revisado

Revisé únicamente la capa DB/SQL y rutas backend cercanas al problema:

- `CLAUDE.md`
- `supabase/schema.sql`
- Migraciones:
  - `supabase/migrations/20260327_0001_service_fee_autocalc.sql`
  - `supabase/migrations/20260327_0004_inclusive_service_fee_exact_totals.sql`
  - `supabase/migrations/20260327_0005_fix_itbis_service_overlap.sql`
  - `supabase/migrations/20260327_0009_split_items_equally_preserve_amounts.sql`
  - `supabase/migrations/20260407_0002_service_fee_section_toggles.sql`
  - `supabase/migrations/20260408_0001_tax_area_toggles.sql`
  - `supabase/migrations/20260408_0002_inclusive_tax_hardening.sql`
  - `supabase/migrations/20260410_0001_fix_tax_and_totals.sql`
  - `supabase/migrations/20260412_0001_fix_order_totals_origin.sql`
  - `supabase/migrations/20260412_0003_final_tax_engine_consolidation.sql`
  - `supabase/migrations/20260417_0600_fix_pricing_discrepancies.sql`
  - `supabase/migrations/20260304_0010_split_items_equally.sql`
  - `supabase/migrations/20260305_0013_split_decimal_totals_hardening.sql`
- Objetos SQL/rutas revisadas:
  - tablas `orders`, `order_items`, `order_checks`, `taxes`, `business_settings`, `order_item_modifiers`
  - funciones `fn_compute_item_totals`, `calculate_order_totals`, `calculate_check_totals`, `fn_resolve_order_item_tax_profile`, `fn_add_item_from_menu`, `fn_update_item_tax_rate`, `fn_split_items_equally`, `fn_recalc_order_totals`
  - triggers sobre `order_items`
- Código app que claramente compensa problemas de DB:
  - `lib/core/tax/tax_engine.dart`
  - `lib/data/utils/order_pricing_utils.dart`

## Conclusión corta

Sí: la capa DB **sí puede producir y también preservar** inconsistencias de 1 centavo y problemas de impuestos inclusivos.

No vi un solo bug aislado; vi una **cadena de definiciones SQL superpuestas** donde migraciones posteriores corrigen algo y otras posteriores vuelven a romper parte del modelo.

## Hallazgos

### 1) La última migración relevante vuelve a romper el cálculo inclusivo

La migración más reciente del motor (`20260417_0600_fix_pricing_discrepancies.sql`) redefine `fn_compute_item_totals` así:

- en modo `inclusive` usa `v_extract_rate := v_tax_rate`
- **ignora `original_tax_rate`** para extraer la base

Eso contradice el hardening previo de:

- `20260408_0001_tax_area_toggles.sql`
- `20260408_0002_inclusive_tax_hardening.sql`
- `20260412_0003_final_tax_engine_consolidation.sql`

que habían introducido `original_tax_rate` precisamente para desescalar precios inclusivos con la tasa completa original.

**Riesgo exacto:**

- si el precio de catálogo fue cargado con tasa completa (ej. ITBIS + ley) pero luego el `tax_rate` efectivo cambia por origen/toggle/takeout, la base queda mal extraída
- eso produce subtotal/tax distintos al precio visible esperado
- aparece drift de ±0.01 y también “inclusive-tax inconsistencies” porque el total visible ya no cierra limpio con la descomposición guardada

### 2) El split de items no preserva `original_tax_rate`

Las rutas de split (`20260327_0009_split_items_equally_preserve_amounts.sql` y también la lógica reescrita en `20260417_0600_fix_pricing_discrepancies.sql`) insertan nuevos `order_items` copiando:

- `tax_mode`
- `tax_rate`

pero **no copian `original_tax_rate`**.

**Riesgo exacto:**

- un item inclusivo original puede haberse creado con tasa completa correcta
- después del split, los clones pierden esa tasa original
- al recalcularse por trigger, la base se extrae con una tasa distinta
- eso cambia subtotal/tax/check total aunque el precio visible del producto no haya cambiado
- en checks divididos esto puede seguir alimentando diferencias de centavos e inconsistencias entre order/check/item

### 3) No encontré trigger equivalente en `order_item_modifiers` para forzar recálculo

`fn_compute_item_totals` depende de `order_item_modifiers`, pero los triggers visibles de recálculo están sobre `order_items`, no sobre `order_item_modifiers`.

**Riesgo exacto:**

- si se agregan/editar/quitan modifiers, el item puede conservar `subtotal/tax/total` viejos
- la DB entonces **preserva valores incorrectos** hasta que otra actualización casual del item dispare el recálculo
- esto cuadra mucho con bugs “intermitentes” donde a veces cierra y a veces no

### 4) La DB calcula item-level y order-level con reglas distintas

En `20260417_0600_fix_pricing_discrepancies.sql`:

- `fn_compute_item_totals` guarda `item.subtotal`, `item.tax`, `item.total`
- pero `calculate_order_totals` y `calculate_check_totals` recalculan impuesto agregado por `tax_rate` (`SUM(ROUND(rate_sum * rate, 2))`) para reducir drift

Eso mejora el header del pedido, pero crea otra tensión:

- `order.tax` puede no ser exactamente igual a `SUM(order_items.tax)`
- `order.total` puede cerrar distinto a la suma de items ya redondeados

**Riesgo exacto:**

- aunque el agregado del pedido mejore, la DB sigue almacenando dos “verdades” distintas
- cualquier pantalla, ticket o RPC que mezcle `order_items.tax/total` con `orders.tax/total` puede mostrar 1 centavo de diferencia

### 5) La app ya trae lógica de compensación porque no confía del todo en la DB

`lib/data/utils/order_pricing_utils.dart` contiene comentarios explícitos de que:

- `item.total` de DB puede estar mal / stale
- para inclusive se recalcula desde el precio visible
- se intenta absorber el residuo de ±0.01 del lado app

Eso es una señal fuerte de que la inconsistencia ya existe aguas abajo del SQL.

**Conclusión técnica:** la DB no solo participa; **es parte del problema fuente**, y la app ya está parchando síntomas.

### 6) `supabase/schema.sql` no coincide con la cadena de migraciones revisada

El `schema.sql` leído sigue mostrando una versión vieja:

- `order_items.total` como columna generada
- sin `original_tax_rate`
- sin `is_service_fee`
- sin `apply_on_zone/manual/quick/delivery`
- sin `service_fee_on_*`
- con funciones antiguas de tax/totals

Mientras que varias migraciones posteriores sí agregan/cambian esas piezas.

**Riesgo exacto:**

- cualquier reset, dump o recreación apoyada en `schema.sql` puede dejar una DB distinta a la realmente esperada por la app
- eso puede reintroducir bugs corregidos o romper fixes recientes
- también hace muy difícil saber cuál es el “source of truth” real del motor fiscal

### 7) Hay demasiadas reescrituras del mismo motor fiscal

La secuencia 2026-03-27 → 2026-04-17 reescribe varias veces las mismas funciones clave:

- `fn_compute_item_totals`
- `calculate_order_totals`
- `calculate_check_totals`
- `fn_resolve_order_item_tax_profile`
- `fn_add_item_from_menu`

**Riesgo exacto:**

- es fácil que una migración posterior “arregle” una cosa y reviva otra ya corregida
- el comportamiento final depende del orden exacto de aplicación, no de una sola definición clara

## Qué cambiaría si la DB es parte del problema

### Cambios recomendados

1. **Consolidar una sola versión final del motor fiscal**
   - dejar una sola migración/fix final que vuelva a definir juntas:
     - `fn_compute_item_totals`
     - `calculate_order_totals`
     - `calculate_check_totals`
     - `fn_resolve_order_item_tax_profile`
     - `fn_add_item_from_menu`
     - `fn_split_items_equally`
   - y eliminar la ambigüedad histórica del chain actual

2. **En `fn_compute_item_totals`, volver a usar `original_tax_rate` para inclusive**
   - extraer base con la tasa completa original
   - aplicar impuesto efectivo con `tax_rate`
   - no degradar eso a `tax_rate` salvo fallback real para data legacy

3. **Hacer que split copie `original_tax_rate`**
   - también cualquier otro campo que afecte pricing (`print_area_code` si importa al flujo)
   - sin eso, los clones de split no son matemáticamente equivalentes al item original

4. **Agregar triggers o RPC de recálculo para `order_item_modifiers`**
   - al insertar/editar/eliminar modifier debe recalcularse el item padre y luego order/check
   - ahora mismo hay riesgo real de datos persistidos stale

5. **Elegir una sola verdad para impuestos/totales**
   - o se confía en `order_items.tax/total` y el order suma eso
   - o se recalcula agregado por rate y no se usa `item.tax` como cifra “final” en UI/reportes
   - hoy ambas estrategias conviven y eso es una fuente directa de diferencias visibles

6. **Regenerar `supabase/schema.sql` desde la DB/migraciones correctas**
   - el schema del repo está atrasado frente a lo que las migraciones pretenden dejar
   - mientras eso siga así, cualquier auditoría o reconstrucción seguirá siendo confusa

## Veredicto final

La DB **sí es parte del problema**.

Los dos puntos más peligrosos para el drift/inclusive-tax son:

1. `20260417_0600_fix_pricing_discrepancies.sql` reintroduce un cálculo inclusivo incorrecto al no usar `original_tax_rate`
2. el split de items no preserva `original_tax_rate`, así que puede seguir sembrando datos inconsistentes en checks/órdenes

Y además hay un tercer problema de persistencia:

3. cambios en `order_item_modifiers` pueden dejar totales stale porque no vi un recálculo equivalente disparado desde esa tabla

Si quieren atacar la raíz en DB, yo empezaría por esos tres primero.