# PRD 7 — Reporte Fases 2.2 y 4.1

**Upload de fotos + Inventario Realtime**

| | |
|---|---|
| **Fecha** | 2026-05-24 |
| **Alcance** | `lib/` (production code) |
| **Metodología** | Grep + lectura manual de paths críticos |

---

## Fase 2.2 — Compresión/optimización de fotos al upload

### Estado: 🔴 **FAIL** — sin compresión ni resize. Upload raw

### Inventario de paths de upload

| Path | Bucket | Validaciones | Compresión |
|---|---|---|---|
| [`products_viewmodel.dart:235-257`](../lib/presentation/products/viewmodel/products_viewmodel.dart) (`addProduct`) | `menu-items` | Solo `_guessExt()` | ❌ Ninguna |
| [`products_viewmodel.dart:344-360`](../lib/presentation/products/viewmodel/products_viewmodel.dart) (`updateProduct`) | `menu-items` | Solo `_guessExt()` | ❌ Ninguna |
| [`menu_items_viewmodel.dart:110-125`](../lib/presentation/settings/more%20settings/menus/menu%20items/viewmodel/menu_items_viewmodel.dart) | `menu-items` | Ninguna evidente | ❌ Ninguna |
| [`business_profile_repository.dart:166-195`](../lib/data/repositories/business_profile_repository.dart) (`uploadLogo`) | `business-logos` | Tipo (png/jpg/jpeg), comentario menciona "≤2MB en el caller" pero no se valida | ❌ Ninguna |
| [`storage_repository.dart:24`](../lib/data/repositories/storage_repository.dart) (genérico) | configurable | Ninguna | ❌ Ninguna |

### Hallazgos

- **Ningún path comprime ni hace resize antes de subir**. Los bytes que entrega `FilePicker` o `image_picker` se persisten tal cual al bucket.
- **Sin límite de tamaño server-side detectable** (depende de policy del bucket en Supabase Storage).
- **Sin validación de dimensiones máximas**. Un usuario puede subir una foto de 4032×3024 (~5-8 MB de un iPhone) y queda en el bucket.
- El comentario en `uploadLogo` que dice "validar size ≤2MB en el caller" **no se cumple en ningún caller**.

### Impacto

- **Crecimiento descontrolado de Storage**: con 15 negocios subiendo fotos crudas de iPhone (~5MB c/u), 100 productos por negocio = ~7.5GB solo en menú. Hoy disco está al 40/200 GB pero esto escala mal.
- **Performance del cliente**: las pantallas de menú descargan imágenes de 5MB cada una. En LAN/3G eso es 5-15s por imagen. `cached_network_image` mitiga después de la primera vez, pero el primer load es brutal.
- **Costo de ancho de banda**: si algún día Supabase Storage tiene egress facturable, esto multiplica el costo por 20-30×.

### Acción recomendada (alto ROI, ~1 día)

Implementar pre-procesamiento client-side antes de cualquier upload:

```dart
// pseudo
final compressed = await FlutterImageCompress.compressWithList(
  bytes,
  minWidth: 1024,
  minHeight: 1024,
  quality: 85,
  format: CompressFormat.jpeg,
);
// resultado típico: 5MB → 80-150 KB
```

Aplica a los 5 paths listados. Centralizar en un único helper `ImageUploadHelper.compress(bytes)` para que cualquier path nuevo lo use.

**Estado tras fix esperado**: 🟢 OK (promedio <200 KB por foto).

---

## Fase 4.1 — Inventario de canales Realtime

### Estado: 🟡 **OBS — con un 🔴 crítico** (canal global sin filtro Y sin dispose)

### Resumen

| Total | 🟢 OK | 🟡 OBS | 🔴 FAIL |
|---|---|---|---|
| 8 suscripciones | 2 | 5 | 1 |

### Inventario

| Archivo:Línea | Tabla(s) | Filtro `business_id` | Dispose | Estado |
|---|---|---|---|---|
| [`zones_repository.dart:685-725`](../lib/data/repositories/zones_repository.dart) | table_sessions, orders, order_items, order_checks, payments, dining_tables | ❌ | ❌ **leak** | 🔴 |
| [`printing_repository.dart:1121-1150`](../lib/data/repositories/printing_repository.dart) | print_jobs, printers | ✓ `business_id=eq.X` | ✓ `ref.onDispose` | 🟢 |
| [`print_service.dart:27-36`](../lib/services/printing/print_service.dart) | print_jobs (stream) | implícito | ✓ `stopPrintWorker()` | 🟢 |
| [`kitchen_viewmodel.dart:173-183`](../lib/presentation/kitchen/viewmodel/kitchen_viewmodel.dart) | order_items | ❌ | ✓ `dispose()` | 🟡 |
| [`delivery_viewmodel.dart:86-113`](../lib/presentation/delivery/viewmodel/delivery_viewmodel.dart) | table_sessions, orders, order_items | ❌ | ✓ `ref.onDispose()` | 🟡 |
| [`sales_by_zone_viewmodel.dart:248-300`](../lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart) | table_sessions, orders | ❌ | ✓ `ref.onDispose()` | 🟡 |
| [`menu_browser_viewmodel.dart:266-290`](../lib/presentation/sales/viewmodel/menu_browser_viewmodel.dart) | inventory_stock, menu_items | ❌ | ✓ `dispose()` | 🟡 |
| [`kds_viewmodel.dart:125-138`](../lib/presentation/kds/viewmodel/kds_viewmodel.dart) | order_items | ❌ | ✓ observer pattern | 🟡 |

### Casos 🔴 detallados

#### Z.1 — `zones_repository.dart:685-725` (canal `zones:status`)

**Problema doble**:
1. Suscribe 6 tablas (`table_sessions`, `orders`, `order_items`, `order_checks`, `payments`, `dining_tables`) **sin filtro de `business_id`**.
2. El método `subscribe()` retorna el `RealtimeChannel` pero **nunca se llama `.unsubscribe()` en ningún lugar del codebase**. Memory leak + suscripción persistente toda la vida del proceso.

**Impacto si RLS falla**: cliente recibe eventos de TODAS las mesas/órdenes/pagos de todos los negocios. Cross-tenant data leak en tiempo real.

**Impacto sin fallo de RLS**: Realtime descarta los eventos no autorizados antes de entregarlos al cliente, **pero el costo de fan-out de Supabase sí se paga**. Con 15 negocios, cada uno recibe los eventos de los otros 14 (filtrados por RLS = descartados, pero igual viajan).

**Fix recomendado**:
- Cambiar `channel('zones:status')` a `channel('zones:status:${businessId}')` con `filter: 'business_id=eq.${businessId}'` en cada `onPostgresChanges`.
- Exponer un `Closer` del canal y asegurar `unsubscribe()` en disposal del provider que lo usa.

### Patrones detectados

1. **87.5% tienen `dispose()` correcto** ✓
2. **75% NO usan `filter: business_id=eq.X` en Realtime** — confían 100% en RLS. Misma observación que Fase 1.4 — single point of failure.
3. **`menu_browser` y `kds_viewmodel`** son los más expuestos: escuchan tablas de alto volumen (`inventory_stock`, `order_items`) sin filtro. Si un terminal abre 8 horas → recibe TODOS los eventos del cluster.

### Top recomendaciones Fase 4

1. **Crítico**: arreglar `zones_repository.dart` — agregar filtro + dispose. ~0.5 días.
2. **Importante**: agregar `filter: 'business_id=eq.X'` a las 5 suscripciones 🟡. Defensa en profundidad + reduce fan-out de Supabase. ~1 día.
3. **Documentación**: agregar a `CLAUDE.md` regla: "Todo `postgresChanges` sobre tabla con `business_id` requiere `filter` explícito".

---

## SQLs listos para Fases 1A/1B/1C (correlos tú en Supabase)

Como complemento, te dejo aquí los queries del PRD para que los corras y me pegues outputs. Yo armo los reportes 1A/1B/1C cuando me los pases.

### Fase 1A — Inventario de tablas + tamaños

```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
  pg_total_relation_size(schemaname||'.'||tablename) AS size_bytes,
  n_live_tup AS approx_rows
FROM pg_stat_user_tables
WHERE schemaname='public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### Fase 1B — Auditoría `business_id`

```sql
-- Qué tablas tienen business_id, si es nullable, y si tiene FK
SELECT
  t.table_name,
  EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema='public'
      AND c.table_name=t.table_name
      AND c.column_name='business_id'
  ) AS tiene_business_id,
  (SELECT is_nullable FROM information_schema.columns c
   WHERE c.table_schema='public'
     AND c.table_name=t.table_name
     AND c.column_name='business_id') AS nullable,
  (SELECT confrelid::regclass::text
   FROM pg_constraint
   WHERE conrelid = ('public.'||t.table_name)::regclass
     AND contype = 'f'
     AND 'business_id' = ANY(
       SELECT attname FROM pg_attribute
       WHERE attrelid = conrelid AND attnum = ANY(conkey)
     )
   LIMIT 1) AS fk_target,
  (SELECT confdeltype
   FROM pg_constraint
   WHERE conrelid = ('public.'||t.table_name)::regclass
     AND contype = 'f'
     AND 'business_id' = ANY(
       SELECT attname FROM pg_attribute
       WHERE attrelid = conrelid AND attnum = ANY(conkey)
     )
   LIMIT 1) AS on_delete
FROM information_schema.tables t
WHERE t.table_schema='public'
  AND t.table_type='BASE TABLE'
ORDER BY tiene_business_id DESC, t.table_name;
```

`on_delete`: `a`=NO ACTION, `r`=RESTRICT, `c`=CASCADE, `n`=SET NULL, `d`=SET DEFAULT. **Cualquier `c` (CASCADE) en una tabla transaccional es FAIL.**

### Fase 1C — Auditoría RLS

```sql
-- Qué tablas tienen RLS habilitada
SELECT
  schemaname,
  tablename,
  rowsecurity AS rls_enabled,
  forcerowsecurity AS rls_forced
FROM pg_tables
WHERE schemaname='public'
ORDER BY rls_enabled DESC, tablename;

-- Policies activas (revisar USING/WITH CHECK manualmente)
SELECT
  tablename,
  policyname,
  cmd,
  permissive,
  qual AS using_clause,
  with_check
FROM pg_policies
WHERE schemaname='public'
ORDER BY tablename, policyname;

-- Smoking gun: policies que usan USING(true) o similar
SELECT tablename, policyname, qual
FROM pg_policies
WHERE schemaname='public'
  AND (qual ILIKE '%true%' OR qual IS NULL);

-- Tablas con business_id pero SIN RLS activa
SELECT t.tablename
FROM pg_tables t
WHERE t.schemaname='public'
  AND t.rowsecurity = false
  AND EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema='public'
      AND c.table_name = t.tablename
      AND c.column_name = 'business_id'
  );
```

### Fase 3A — Setup `pg_stat_statements` (ventana 48-72h)

```sql
-- Verificar instalado
SELECT * FROM pg_extension WHERE extname='pg_stat_statements';

-- Resetear estadísticas (anotar fecha/hora)
SELECT pg_stat_statements_reset();
SELECT now() AS reset_at;
```

Después de 48-72h con uso normal, corre:

```sql
-- Top por tiempo total
SELECT substring(query, 1, 100) AS short_query,
       calls, total_exec_time::int AS total_ms,
       mean_exec_time::numeric(10,2) AS mean_ms,
       rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 20;

-- Top por frecuencia (sospechosas de N+1)
SELECT substring(query, 1, 100) AS short_query, calls,
       mean_exec_time::numeric(10,2) AS mean_ms
FROM pg_stat_statements
ORDER BY calls DESC LIMIT 20;
```

---

## Consolidación parcial del PRD 7

Estado de las fases completadas hasta ahora:

| Fase | Tema | Estado |
|---|---|---|
| 1.4 | Queries cliente | 🟡 OBS — 104 escrituras dependen solo de RLS |
| 2.2 | Compresión fotos | 🔴 FAIL — sin compresión en ningún path |
| 4.1 | Realtime | 🟡 OBS — 1 canal global sin filtro ni dispose (`zones_repository.dart`) |
| 1A, 1B, 1C, 3 | Server-side | ⏳ Pendiente de tu run en Supabase |
| 2.1, 5 | VPS/Backups | ⏳ Pendiente — requieren SSH al VPS |
