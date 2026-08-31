# API de lectura para clientes (MangoPOS)

Acceso permanente de **solo lectura** para que un cliente consulte y analice sus propios datos
en vivo, restringido a **un** negocio. Primer consumidor: **Penda Express**
(`35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6`).

## Por qué está construido así

La opción obvia —crear un usuario de Supabase para el cliente— **no sirve**: las policies del POS
son `TO authenticated` con permisos de escritura, así que ese usuario podría modificar datos.

Los dos intentos naturales de arreglarlo fallan, y esto se comprobó ejecutándolo en Postgres,
no en teoría:

| Rol miembro de `authenticated` | ¿Ve filas? | ¿Puede escribir? |
|---|---|---|
| `NOINHERIT` | **no, 0 filas** — las policies `TO authenticated` se evalúan con `has_privs_of_role()`, que respeta `NOINHERIT` | no |
| `INHERIT` | sí | **sí** — hereda los `GRANT` de escritura de `authenticated` |

La solución que sí cumple las dos cosas: **vistas sin `security_invoker` en un esquema aparte,
cuyo *owner* sí es miembro de `authenticated`**. Postgres evalúa la RLS de `public.*` con los
privilegios del owner de la vista, mientras que el rol que usa la API key (`analytics_ro`) no
tiene **ningún** grant sobre `public.*` y solo tiene `SELECT` sobre las vistas.

```
API key (JWT role=analytics_ro)
        │
        ▼
  analytics_ro ──SELECT──► analytics.*  (vistas, owner = mango_analytics_view_owner)
        │                        │
        │                        ▼  RLS evaluada como el owner (sí es `authenticated`)
        └──✗ sin grants──►  public.*   + pin de analytics.api_clients
```

## Doble candado de alcance

1. **RLS de `public.*`** vía `auth.uid()` — el usuario analítico pertenece a un solo negocio.
2. **`analytics.api_clients`** — pin explícito de `business_id`, con PK por `user_id`
   (un usuario analítico ⇒ exactamente un negocio). Toda vista sobre una tabla con `business_id`
   filtra **además** por este pin, así que queda protegida aunque a esa tabla le faltara la RLS.

Regla que aplica el generador de vistas, por relación:

| Situación de la tabla | Qué hace |
|---|---|
| tiene `business_id` | filtra por el pin (protegida aunque no tenga RLS) |
| sin `business_id`, con RLS | publica; el alcance lo da la RLS |
| sin `business_id`, **sin RLS** | **se omite** y se reporta por `NOTICE` |

Esa última regla no es hipotética: en el repo hay 20 tablas sin `ENABLE ROW LEVEL SECURITY`,
incluidas las de respaldo `*_backup_*` con documentos fiscales **de todos los negocios**. Un
`GRANT SELECT ON ALL TABLES` habría filtrado datos de otros clientes.

## Qué NO se publica, a propósito

Respaldos (`*_backup_*`), `azul_*` (tokens de tarjeta), `agent_nodes` (hash de API key),
`device_*`, `memberships`, `user_businesses`, `profiles`, `plans`, `platform_access_policy`,
`business_alanube_settings`, `alanube_*`, `business_sales_export_config` (credenciales SFTP),
`dgii_logs`, `accounting_*`, `payment_duplicate_audit`.

## Archivos

| Archivo | Qué es |
|---|---|
| `supabase/migrations/20260829_0002_analytics_readonly_api.sql` | esquema `analytics`, roles, 85 vistas, el feed de documentos y 2 índices |
| `supabase/migrations/20260829_0002_analytics_readonly_api_ROLLBACK.sql` | deshace todo; deja los dos índices |
| `supabase/migrations/20260830_0001_analytics_perf.sql` (+ ROLLBACK) | pin escalar + los índices; **obligatoria**, sin ella el feed hace Seq Scan |
| `supabase/ACTIVAR_API_LECTURA_PENDA.sql` | runbook de alta de Penda + verificación |
| `scripts/mint_analytics_api_key.sh` | genera la API key (JWT HS256) |

## Puesta en marcha

```bash
# 1. aplicar la migración (Studio SQL Editor o psql)
#    si algún GRANT falla por privilegios, ejecutarla como supabase_admin en vez de postgres

# 2. crear el usuario analítico en Studio > Authentication > Add user
#    correo bajo control de MangoPOS, NO del cliente  (ver ACTIVAR_..._PENDA.sql, bloque 1)

# 3. correr supabase/ACTIVAR_API_LECTURA_PENDA.sql

# 4. generar la key
export SUPABASE_JWT_SECRET='<JWT_SECRET del stack en Coolify>'
./scripts/mint_analytics_api_key.sh <user_id_analitico> 365

# 5. Exponer el esquema (bloque 6 de ACTIVAR). NO se toca Coolify:
alter role authenticator set pgrst.db_schemas = 'public,storage,graphql_public,analytics';
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
```

PostgREST lee su configuración también desde la base (`db-config`, activo por defecto) y **eso
tiene prioridad sobre la variable de entorno `PGRST_DB_SCHEMAS`**. Verificado contra PostgREST
16.2: con `db-schemas = "public"` en el archivo, ese `ALTER ROLE` + `NOTIFY` expuso `analytics`
al instante y `public` siguió respondiendo. Así que **no hay que editar Coolify ni reiniciar el
servicio `rest`** — cero interrupción para el POS.

El precio es que a partir de ahí la variable de Coolify queda inerte. Para devolverle el mando:
`alter role authenticator reset pgrst.db_schemas;` seguido de `notify pgrst, 'reload config';`.

## El feed de documentos

`analytics.documentos` entrega
`TIPO_DOC, NUMERO, FECHA, NOMBRE, BRUTO, ITBIS, LEY, TOTAL`, con
**`BRUTO + ITBIS + LEY = TOTAL`** e `ITBIS = 18% de BRUTO`.

**Los impuestos NO salen de `fiscal_documents`.** Ni de `itbis_amount` —la propia app se niega a
usarlo, ver [reports_repository.dart:1807](../lib/data/repositories/reports_repository.dart#L1807)—
ni de `service_fee`, que es un parámetro heredado que no debe usarse. Ambos se derivan de
`order_item_tax_lines`, o sea de lo que la configuración (`menu_item_taxes` + `taxes`) hizo
cobrar en cada línea. Sin nombres cableados: ITBIS es la línea del impuesto llamado ITBIS y LEY
es **todo el resto** de impuestos configurados, así ninguno se pierde si mañana se agrega otro.
En cuentas divididas se agrupa por `check_id`, así cada comprobante lleva solo su porción.

Medido en LA PENDA EXPRESS: `subtotal + itbis_amount + service_fee + tip` daba RD$8,666,003.62
contra un TOTAL de RD$10,051,370 — **RD$1,386,226.43 sin representar en ningún campo**. Eso es
exactamente el ITBIS (≈894k) más la LEY (≈497k) de los ítems al 28%, que el documento fiscal no
guardaba.

| TIPO_DOC | Origen en MangoPOS |
|---|---|
| `Venta Contado` | `fiscal_documents` sin `customer_credits` asociado |
| `Venta Crédito` | `fiscal_documents` con `customer_credits` asociado |
| `Devolución Contado` / `Devolución Crédito` | `fiscal_documents` con `status='cancelled'`, como fila **adicional** a la venta |
| `Recibo Pago` | `credit_payments` (abonos a CxC); `BRUTO=0`, `ITBIS=0` |

`analytics.documentos_detalle` trae lo mismo con el desglose completo (NCF, tipo de NCF,
descuento, Ley 10%, propina, RNC, motivo de anulación).

### Decisiones que conviene confirmar con el cliente

- **`BRUTO = total - itbis`.** Es la única definición que mantiene `BRUTO + ITBIS = TOTAL`, pero
  mete la **Ley 10% y la propina dentro de BRUTO**. Si su contabilidad las quiere separadas, hay
  que usar `documentos_detalle` (columnas `ley_10` y `propina`).
- **`NUMERO` de las ventas** = parte numérica completa del NCF (`B0200001250` → `200001250`), para
  que sea único. La muestra del cliente traía `1250`; si prefieren solo la secuencia, es cambiar
  `regexp_replace(ncf_number, '\D', '', 'g')` por `right(ncf_number, 8)` en
  `analytics.documentos_detalle`. **Ojo:** así dos NCF de tipos distintos pueden colisionar.
- **`NUMERO` de devoluciones y recibos** es un contador propio por negocio: MangoPOS no emite NCF
  de nota de crédito (el enum `ncf_type` no tiene `B04`), la anulación solo marca
  `status='cancelled'`.
- **Ventas sin documento fiscal** no aparecen en el feed. `analytics.ventas_sin_documento_fiscal`
  las lista; si trae filas, el feed está por debajo de la venta real.

## Rendimiento

Medido contra el volumen real de LA PENDA EXPRESS: **124.909 documentos fiscales en la base, de
los cuales 10.851 son suyos**.

**El pin tiene que ser escalar.** La primera versión usaba
`business_id in (select analytics.allowed_business_ids())`. Como esa función devuelve un
*conjunto*, el planificador no puede usarla como llave de índice: lo resolvía con un Hash Join
y para eso recorría `fiscal_documents` **entera**, evaluando la RLS fila por fila.

```
Seq Scan on fiscal_documents  ...  Rows Removed by Filter: 114058
```

`analytics.allowed_business_id()` (singular, `STABLE`) devuelve un `uuid`, así que Postgres la
evalúa una vez y la usa como condición de índice sobre `idx_fiscal_docs_business_created`.
`api_clients` ya tenía PK por `user_id`, o sea que un cliente = un negocio: el escalar siempre
fue el modelo correcto.

| | Antes | Después |
|---|---|---|
| Plan sobre `fiscal_documents` | Seq Scan, 114.058 filas descartadas | Index Scan |
| Un mes de `/documentos` | 356 ms | ~55 ms |
| Feed completo | 363 ms | 65 ms |

(Medido en el mismo equipo y con el mismo volumen. En el VPS, con caché fría, el antes eran
1.531 ms **para cero filas**.)

**Dos índices en `customer_credits`.** Es lo único que la migración crea dentro de `public.*`
(`fiscal_document_id` y `order_id`, parciales). Sin ellos el `EXISTS` que separa Contado de
Crédito hace un Seq Scan de `customer_credits` por cada documento fiscal.

## Límites conocidos

- La garantía de solo lectura depende de que el acceso sea **por PostgREST**. Con la API key el
  cliente no puede ejecutar `SET ROLE`; si alguna vez se le diera una conexión Postgres directa
  con este rol, sí podría cambiar de rol, porque `authenticator` es miembro de `authenticated`.
  **No entregar un login de base de datos para este rol.**
- No hay límite de tasa configurado.
- La key expira según los días con que se generó (365 por defecto). Renovar = volver a correr el
  script; no hay que tocar la base.
- Para revocar: `update analytics.api_clients set is_active = false where ...` (efecto inmediato,
  sin esperar a que expire el JWT).

## Grants sobre `public` que necesitan las policies

El POS tiene dos estilos de policy. Las que llaman a un helper `SECURITY DEFINER`
(`user_has_business_access`, `current_user_business_ids`, `fn_user_in_business`,
`user_has_business_permission`) funcionan sin más: el helper lee como su dueño. Las que hacen el
`SELECT` **inline** dentro de la policy necesitan que el *invocador* tenga acceso a esas tablas —
y `analytics_ro`, por ser `NOINHERIT`, no tiene nada.

Eso rompía **20 de las 90 vistas**. Postgres reporta una tabla por vez, así que hizo falta un
barrido por HTTP con la key real para encontrarlas todas:

| Migración | Otorga | Vistas que desbloquea |
|---|---|---|
| `20260830_0002` | `usage on schema auth` | `cash_register_sessions` y las que llaman `auth.uid()` en la policy |
| `20260830_0003` | `select` en `user_businesses`, `memberships` | 20 |
| `20260830_0004` | `select` en `employees`, `businesses` | 3 |
| `20260830_0005` | `select` en la cadena de permisos (`employee_roles`, `role_permissions`, `permissions`, `roles`, `user_roles`, `user_permission_overrides`) | 2 |

**Estos grants no abren una vía de lectura.** Medido contra producción: pidiendo esas mismas
tablas con `Accept-Profile: public` la API devuelve `[]`. Las policies son `TO authenticated` y,
evaluadas directamente como `analytics_ro`, no aplican — sin policy que dé acceso, cero filas.
Dentro de las vistas definer sí aplican, porque allí la RLS se evalúa como el owner de la vista.
El `NOINHERIT` es lo que hace que ambas cosas sean ciertas a la vez.

## Verificado sobre HTTP

Probado contra PostgREST 16.2 real (no solo SQL), con el JWT emitido por
`scripts/mint_analytics_api_key.sh`:

| Prueba | Resultado |
|---|---|
| `GET /documentos` con `Accept-Profile: analytics` | 8 filas, los 5 `TIPO_DOC` |
| filtros `FECHA=gte./lte.`, `TIPO_DOC=eq.`, `order`, `limit/offset` | funcionan con columnas en mayúscula |
| `Accept: text/csv` | CSV directo para Excel |
| venta de 9:30 PM hora RD | queda en el día correcto, no en el siguiente |
| documento de otro negocio | no aparece (0 filas) |
| `POST` / `PATCH` / `DELETE` | **403** `permission denied`, datos sin cambios |
| leer el esquema `public` | **403** |
| firma alterada · `role=service_role` forjado · token expirado | **401** |
| `GET /api_clients` (tabla del pin) | **403** |
| **Barrido de las 90 vistas contra producción** | **90 OK, 0 fallos** |
| `Accept-Profile: public` sobre tablas con grant | `[]` vacío |
| `Accept-Profile: public` sobre tablas sin grant | **403** |
| `PATCH`/`DELETE` en el esquema `public` | **403** |

Ojo con una prueba engañosa: alterar el **último** carácter de la firma devuelve 200, porque en
base64url sin padding varios caracteres finales decodifican a los mismos bytes. Hay que alterar
el medio de la firma para probar de verdad; ahí sí devuelve 401.
