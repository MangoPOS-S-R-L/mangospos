# Guía de Administración y Monitoreo de Negocios — MangoPOS

**Versión:** 1.0  
**Fecha:** 2026-04-20  
**Audiencia:** Operador / dueño de la plataforma MangoPOS

---

## Índice

1. [Arquitectura multi-negocio](#1-arquitectura-multi-negocio)
2. [Panel de control de negocios activos](#2-panel-de-control-de-negocios-activos)
3. [Métricas clave por negocio](#3-métricas-clave-por-negocio)
4. [Monitoreo de facturación fiscal](#4-monitoreo-de-facturación-fiscal)
5. [Monitoreo de impresoras y agente local](#5-monitoreo-de-impresoras-y-agente-local)
6. [Logs y auditoría](#6-logs-y-auditoría)
7. [Detección de fallas comunes](#7-detección-de-fallas-comunes)
8. [Consultas SQL de monitoreo](#8-consultas-sql-de-monitoreo)
9. [Alertas recomendadas](#9-alertas-recomendadas)
10. [Checklist diario del operador](#10-checklist-diario-del-operador)

---

## 1. Arquitectura multi-negocio

Cada negocio en MangoPOS es un **tenant** completamente aislado. El aislamiento se garantiza en tres capas:

### Identificadores clave

| Campo | Tabla | Descripción |
|-------|-------|-------------|
| `businesses.id` | `businesses` | UUID único del negocio. Es el eje de todo. |
| `businesses.domain` | `businesses` | Subdominio propio (`[slug].mangopos.do`) |
| `businesses.status` | `businesses` | `active` / `inactive` |
| `memberships.plan_type` | `memberships` | `trial` / `free` / `basic` / `pro` |
| `memberships.status` | `memberships` | `active` / `canceled` / `expired` |

### Roles de usuarios en cada negocio

| Rol | Acceso |
|-----|--------|
| `owner` | Control total |
| `admin` | Gestión operacional completa |
| `manager` | Reportes y configuración parcial |
| `cashier` | Solo POS/caja |
| `waiter` | Solo toma de pedidos |
| `cook` / `chef` | Solo KDS/cocina |

### Cómo está asegurado el aislamiento

Todas las tablas operativas tienen columna `business_id`. Las **Row Level Security (RLS)** en Supabase usan funciones como `fn_user_in_business()` para que un usuario solo vea datos de los negocios a los que pertenece. Como operador de la plataforma necesitarás acceso directo a la base de datos (Service Role key o acceso al proyecto Supabase).

---

## 2. Panel de control de negocios activos

### Ver todos los negocios registrados

```sql
SELECT
  b.id,
  b.business_name,
  b.business_type,
  b.status,
  b.created_at::date AS fecha_registro,
  m.plan_type,
  m.status AS plan_status,
  m.end_date,
  COUNT(DISTINCT ub.user_id) AS total_usuarios
FROM businesses b
LEFT JOIN memberships m ON m.business_id = b.id
LEFT JOIN user_businesses ub ON ub.business_id = b.id
GROUP BY b.id, b.business_name, b.business_type, b.status, b.created_at, m.plan_type, m.status, m.end_date
ORDER BY b.created_at DESC;
```

### Negocios con planes vencidos o por vencer

```sql
SELECT
  b.business_name,
  m.plan_type,
  m.end_date,
  (m.end_date - CURRENT_DATE) AS dias_restantes
FROM memberships m
JOIN businesses b ON b.id = m.business_id
WHERE m.status = 'active'
  AND m.end_date IS NOT NULL
  AND m.end_date <= CURRENT_DATE + INTERVAL '7 days'
ORDER BY m.end_date ASC;
```

### Negocios inactivos (sin ventas en los últimos 7 días)

```sql
SELECT
  b.id,
  b.business_name,
  MAX(p.created_at) AS ultima_venta,
  COUNT(p.id) AS ventas_7_dias
FROM businesses b
LEFT JOIN payments p
  ON p.business_id = b.id
  AND p.created_at >= NOW() - INTERVAL '7 days'
  AND p.status = 'completed'
WHERE b.status = 'active'
GROUP BY b.id, b.business_name
HAVING COUNT(p.id) = 0
ORDER BY ultima_venta DESC NULLS FIRST;
```

---

## 3. Métricas clave por negocio

Reemplaza `'[BUSINESS_ID]'` con el UUID del negocio a revisar.

### Resumen de ventas del día

```sql
SELECT
  COUNT(p.id) AS total_transacciones,
  SUM(p.amount - COALESCE(p.change_amount, 0)) AS ingresos_netos,
  AVG(p.amount - COALESCE(p.change_amount, 0)) AS ticket_promedio,
  COUNT(DISTINCT p.order_id) AS ordenes_completadas
FROM payments p
WHERE p.business_id = '[BUSINESS_ID]'
  AND p.status = 'completed'
  AND (p.created_at AT TIME ZONE 'America/Santo_Domingo')::date = CURRENT_DATE;
```

### Ventas por método de pago (hoy)

```sql
SELECT
  pm.name AS metodo,
  COUNT(p.id) AS transacciones,
  SUM(p.amount - COALESCE(p.change_amount, 0)) AS total
FROM payments p
JOIN payment_methods pm ON pm.id = p.payment_method_id
WHERE p.business_id = '[BUSINESS_ID]'
  AND p.status = 'completed'
  AND (p.created_at AT TIME ZONE 'America/Santo_Domingo')::date = CURRENT_DATE
GROUP BY pm.name
ORDER BY total DESC;
```

### Cajas abiertas actualmente

```sql
SELECT
  cr.name AS caja,
  crs.opened_at,
  crs.opening_amount,
  crs.expected_amount,
  EXTRACT(EPOCH FROM (NOW() - crs.opened_at))/3600 AS horas_abierta
FROM cash_register_sessions crs
JOIN cash_registers cr ON cr.id = crs.cash_register_id
WHERE crs.business_id = '[BUSINESS_ID]'
  AND crs.closed_at IS NULL
ORDER BY crs.opened_at DESC;
```

### Sesiones de mesa activas

```sql
SELECT
  z.name AS zona,
  dt.name AS mesa,
  ts.created_at AS abierta_desde,
  SUM(o.total) AS total_acumulado
FROM table_sessions ts
JOIN dining_tables dt ON dt.id = ts.table_id
JOIN zones z ON z.id = dt.zone_id
LEFT JOIN orders o ON o.session_id = ts.id AND o.status_ext NOT IN ('cancelled', 'void')
WHERE ts.business_id = '[BUSINESS_ID]'
  AND ts.closed_at IS NULL
GROUP BY z.name, dt.name, ts.created_at
ORDER BY ts.created_at;
```

### Top 10 productos vendidos (últimos 30 días)

```sql
SELECT
  oi.product_name,
  SUM(COALESCE(oi.qty, oi.quantity, 1)) AS unidades,
  SUM(oi.total) AS ingresos
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
JOIN payments p ON p.order_id = o.id
WHERE p.business_id = '[BUSINESS_ID]'
  AND p.status = 'completed'
  AND p.created_at >= NOW() - INTERVAL '30 days'
GROUP BY oi.product_name
ORDER BY unidades DESC
LIMIT 10;
```

---

## 4. Monitoreo de facturación fiscal

Los comprobantes fiscales son el registro oficial para la DGII. Se almacenan en `fiscal_documents`.

### Estado de comprobantes del día

```sql
SELECT
  fd.ncf_type,
  COUNT(*) AS emitidos,
  COUNT(*) FILTER (WHERE fd.status = 'void') AS anulados,
  SUM(fd.itbis_amount) AS itbis_total,
  SUM(fd.service_fee) AS propina_total,
  SUM(fd.total) AS monto_total
FROM fiscal_documents fd
WHERE fd.business_id = '[BUSINESS_ID]'
  AND (fd.issued_at AT TIME ZONE 'America/Santo_Domingo')::date = CURRENT_DATE
GROUP BY fd.ncf_type
ORDER BY emitidos DESC;
```

### Secuencias NCF disponibles (alertar cuando queden pocas)

```sql
SELECT
  ns.ncf_type,
  ns.prefix,
  ns.current_sequence,
  ns.max_sequence,
  (ns.max_sequence - ns.current_sequence) AS disponibles,
  CASE
    WHEN (ns.max_sequence - ns.current_sequence) < 50 THEN 'CRITICO'
    WHEN (ns.max_sequence - ns.current_sequence) < 200 THEN 'ADVERTENCIA'
    ELSE 'OK'
  END AS estado
FROM ncf_sequences ns
WHERE ns.business_id = '[BUSINESS_ID]'
  AND ns.is_active = true
ORDER BY disponibles ASC;
```

### Comprobantes sin número NCF asignado (posible falla)

```sql
SELECT
  fd.id,
  fd.created_at,
  fd.total,
  fd.status,
  fd.ncf_type
FROM fiscal_documents fd
WHERE fd.business_id = '[BUSINESS_ID]'
  AND (fd.ncf_number IS NULL OR fd.ncf_number = '')
  AND fd.created_at >= NOW() - INTERVAL '24 hours'
ORDER BY fd.created_at DESC;
```

---

## 5. Monitoreo de impresoras y agente local

El agente local (desktop o móvil) conecta las impresoras térmicas con el sistema. Su estado es crítico para la operación.

### Estado de agentes por negocio

```sql
SELECT
  an.name AS agente,
  an.site_code,
  an.is_active,
  an.last_seen,
  EXTRACT(EPOCH FROM (NOW() - an.last_seen))/60 AS minutos_sin_reporte,
  CASE
    WHEN an.last_seen >= NOW() - INTERVAL '5 minutes' THEN 'EN LINEA'
    WHEN an.last_seen >= NOW() - INTERVAL '30 minutes' THEN 'TARDIO'
    ELSE 'DESCONECTADO'
  END AS estado_conexion
FROM agent_nodes an
WHERE an.business_id = '[BUSINESS_ID]'
ORDER BY an.last_seen DESC;
```

### Trabajos de impresión fallidos (últimas 24 horas)

```sql
SELECT
  pj.id,
  pj.created_at,
  pj.status,
  pj.error,
  pj.ip AS impresora_ip,
  pj.port
FROM print_jobs pj
WHERE pj.business_id = '[BUSINESS_ID]'
  AND pj.status = 'failed'
  AND pj.created_at >= NOW() - INTERVAL '24 hours'
ORDER BY pj.created_at DESC;
```

### Tasa de éxito de impresión (últimas 24 horas)

```sql
SELECT
  COUNT(*) AS total_jobs,
  COUNT(*) FILTER (WHERE status = 'printed') AS exitosos,
  COUNT(*) FILTER (WHERE status = 'failed') AS fallidos,
  COUNT(*) FILTER (WHERE status = 'pending') AS pendientes,
  ROUND(
    COUNT(*) FILTER (WHERE status = 'printed') * 100.0 / NULLIF(COUNT(*), 0), 1
  ) AS pct_exito
FROM print_jobs
WHERE business_id = '[BUSINESS_ID]'
  AND created_at >= NOW() - INTERVAL '24 hours';
```

### Impresoras registradas por negocio

```sql
SELECT
  p.name,
  p.type,
  p.ip_address,
  p.port,
  p.device_path,
  (
    SELECT COUNT(*) FROM print_jobs pj
    WHERE pj.business_id = p.business_id
      AND pj.ip = p.ip_address
      AND pj.status = 'failed'
      AND pj.created_at >= NOW() - INTERVAL '7 days'
  ) AS fallas_7_dias
FROM printers p
WHERE p.business_id = '[BUSINESS_ID]'
ORDER BY p.name;
```

### Log del agente local (archivo en disco)

El agente de escritorio escribe en:
- **Windows:** `C:\Users\[usuario]\AppData\Roaming\mangopos-agent\agent.log`
- **macOS:** `~/Library/Application Support/mangopos-agent/agent.log`
- **Linux:** `~/.config/mangopos-agent/agent.log`

Para revisar errores recientes en el log:

```bash
# Ver últimas 100 líneas de errores
tail -100 ~/Library/Application\ Support/mangopos-agent/agent.log | grep -i error

# Buscar errores de conexión
grep -i "connect\|timeout\|refused" agent.log | tail -50

# Ver toda la actividad de hoy
grep "$(date +%Y-%m-%d)" agent.log
```

---

## 6. Logs y auditoría

### Ver todas las acciones de un negocio (últimas 24 horas)

```sql
SELECT
  al.created_at,
  al.action,
  al.reason,
  al.ref_table,
  al.ref_id,
  ub.user_id
FROM audit_logs al
LEFT JOIN user_businesses ub ON ub.business_id = al.business_id
WHERE al.business_id = '[BUSINESS_ID]'
  AND al.created_at >= NOW() - INTERVAL '24 hours'
ORDER BY al.created_at DESC
LIMIT 200;
```

### Acciones sospechosas o críticas (anulaciones, eliminaciones)

```sql
SELECT
  al.created_at,
  al.action,
  al.reason,
  al.ref_table,
  al.ref_id
FROM audit_logs al
WHERE al.business_id = '[BUSINESS_ID]'
  AND al.action ILIKE ANY (ARRAY['%delete%','%void%','%cancel%','%anul%','%eliminat%'])
  AND al.created_at >= NOW() - INTERVAL '7 days'
ORDER BY al.created_at DESC;
```

### Actividad de usuarios (quién hizo qué)

```sql
SELECT
  ub.user_id,
  COUNT(*) AS acciones_hoy,
  STRING_AGG(DISTINCT al.action, ', ') AS tipos_de_acciones
FROM audit_logs al
JOIN user_businesses ub ON ub.business_id = al.business_id
WHERE al.business_id = '[BUSINESS_ID]'
  AND (al.created_at AT TIME ZONE 'America/Santo_Domingo')::date = CURRENT_DATE
GROUP BY ub.user_id
ORDER BY acciones_hoy DESC;
```

---

## 7. Detección de fallas comunes

### Falla 1 — Pagos sin orden asociada

```sql
SELECT id, created_at, amount, status, order_id
FROM payments
WHERE business_id = '[BUSINESS_ID]'
  AND (order_id IS NULL OR order_id = '')
  AND created_at >= NOW() - INTERVAL '7 days';
```

### Falla 2 — Comprobantes fiscales sin pago vinculado

```sql
SELECT fd.id, fd.ncf_number, fd.total, fd.created_at
FROM fiscal_documents fd
WHERE fd.business_id = '[BUSINESS_ID]'
  AND fd.payment_id IS NULL
  AND fd.status != 'void'
  AND fd.created_at >= NOW() - INTERVAL '7 days';
```

### Falla 3 — Sesiones de caja sin cerrar por más de 24 horas

```sql
SELECT
  crs.id,
  cr.name AS caja,
  crs.opened_at,
  EXTRACT(EPOCH FROM (NOW() - crs.opened_at))/3600 AS horas_abierta
FROM cash_register_sessions crs
JOIN cash_registers cr ON cr.id = crs.cash_register_id
WHERE crs.business_id = '[BUSINESS_ID]'
  AND crs.closed_at IS NULL
  AND crs.opened_at < NOW() - INTERVAL '24 hours';
```

### Falla 4 — Órdenes abiertas sin actividad (posible orden fantasma)

```sql
SELECT
  o.id,
  o.created_at,
  o.total,
  o.status_ext,
  ts.created_at AS sesion_inicio
FROM orders o
JOIN table_sessions ts ON ts.id = o.session_id
WHERE o.business_id = '[BUSINESS_ID]'
  AND ts.closed_at IS NULL
  AND o.created_at < NOW() - INTERVAL '8 hours'
  AND o.status_ext NOT IN ('paid', 'cancelled', 'void')
ORDER BY o.created_at ASC;
```

### Falla 5 — Discrepancias en cierre de caja

```sql
SELECT
  crs.id,
  cr.name AS caja,
  crs.opened_at,
  crs.closed_at,
  crs.opening_amount,
  crs.expected_amount,
  crs.closing_amount,
  (crs.closing_amount - crs.expected_amount) AS diferencia
FROM cash_register_sessions crs
JOIN cash_registers cr ON cr.id = crs.cash_register_id
WHERE crs.business_id = '[BUSINESS_ID]'
  AND crs.closed_at IS NOT NULL
  AND ABS(crs.closing_amount - crs.expected_amount) > 50
  AND crs.closed_at >= NOW() - INTERVAL '30 days'
ORDER BY ABS(crs.closing_amount - crs.expected_amount) DESC;
```

### Falla 6 — Impresora con alta tasa de errores

```sql
SELECT
  ip AS impresora_ip,
  COUNT(*) AS total_jobs,
  COUNT(*) FILTER (WHERE status = 'failed') AS fallidos,
  ROUND(COUNT(*) FILTER (WHERE status = 'failed') * 100.0 / COUNT(*), 1) AS pct_falla,
  MAX(created_at) AS ultimo_job,
  MAX(error) AS ultimo_error
FROM print_jobs
WHERE business_id = '[BUSINESS_ID]'
  AND created_at >= NOW() - INTERVAL '24 hours'
GROUP BY ip
HAVING COUNT(*) FILTER (WHERE status = 'failed') > 0
ORDER BY pct_falla DESC;
```

---

## 8. Consultas SQL de monitoreo

### Vista global de todos los negocios (resumen ejecutivo del día)

Esta es la consulta principal para monitorear toda la plataforma de un vistazo:

```sql
SELECT
  b.business_name,
  b.business_type,
  m.plan_type,
  -- Ventas hoy
  COUNT(DISTINCT p.id) AS ventas_hoy,
  COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)) FILTER (
    WHERE (p.created_at AT TIME ZONE 'America/Santo_Domingo')::date = CURRENT_DATE
  ), 0) AS ingresos_hoy,
  -- Comprobantes
  COUNT(DISTINCT fd.id) FILTER (
    WHERE (fd.issued_at AT TIME ZONE 'America/Santo_Domingo')::date = CURRENT_DATE
  ) AS ncf_hoy,
  -- Print jobs fallidos
  COUNT(DISTINCT pj.id) FILTER (
    WHERE pj.status = 'failed'
    AND pj.created_at >= NOW() - INTERVAL '24 hours'
  ) AS print_fallas,
  -- Agente conectado
  MAX(an.last_seen) AS agente_ultimo_ping,
  CASE
    WHEN MAX(an.last_seen) >= NOW() - INTERVAL '5 minutes' THEN 'EN LINEA'
    WHEN MAX(an.last_seen) >= NOW() - INTERVAL '30 minutes' THEN 'TARDIO'
    WHEN MAX(an.last_seen) IS NULL THEN 'SIN AGENTE'
    ELSE 'DESCONECTADO'
  END AS estado_agente
FROM businesses b
LEFT JOIN memberships m ON m.business_id = b.id AND m.status = 'active'
LEFT JOIN payments p ON p.business_id = b.id AND p.status = 'completed'
LEFT JOIN fiscal_documents fd ON fd.business_id = b.id
LEFT JOIN print_jobs pj ON pj.business_id = b.id
LEFT JOIN agent_nodes an ON an.business_id = b.id AND an.is_active = true
WHERE b.status = 'active'
GROUP BY b.id, b.business_name, b.business_type, m.plan_type
ORDER BY ingresos_hoy DESC;
```

### Comparativo semana actual vs semana anterior (por negocio)

```sql
SELECT
  b.business_name,
  COALESCE(SUM(p.amount - COALESCE(p.change_amount,0)) FILTER (
    WHERE p.created_at >= date_trunc('week', NOW())
  ), 0) AS ventas_esta_semana,
  COALESCE(SUM(p.amount - COALESCE(p.change_amount,0)) FILTER (
    WHERE p.created_at >= date_trunc('week', NOW()) - INTERVAL '7 days'
      AND p.created_at < date_trunc('week', NOW())
  ), 0) AS ventas_semana_pasada
FROM businesses b
LEFT JOIN payments p ON p.business_id = b.id AND p.status = 'completed'
WHERE b.status = 'active'
GROUP BY b.id, b.business_name
ORDER BY ventas_esta_semana DESC;
```

---

## 9. Alertas recomendadas

Configura estas alertas en Supabase (via Edge Functions + cron) o en una herramienta externa como Grafana, Datadog, o un simple script Node.js con cron.

| Alerta | Condición | Prioridad | Acción |
|--------|-----------|-----------|--------|
| Agente desconectado | `last_seen < NOW() - 30min` | Alta | Notificar al negocio |
| NCF secuencias bajas | `disponibles < 50` | Alta | Alertar al dueño para renovar |
| Membresía vencida | `end_date < CURRENT_DATE` | Alta | Email + bloqueo de acceso |
| Print fallas > 20% | Tasa de fallo en 1h > 20% | Media | Revisar impresora/red |
| Caja abierta > 24h | `opened_at < NOW() - 24h` | Media | Verificar con el negocio |
| Orden fantasma | Orden sin pago > 8h abierta | Baja | Auditoría manual |
| Discrepancia de caja | `|diferencia| > 500 RD$` | Media | Notificar al manager |
| Sin ventas en 24h | Negocio activo, 0 pagos | Baja | Verificar si cerrado |

### Implementación básica de alerta via Supabase Edge Function

```typescript
// supabase/functions/health-check/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

Deno.serve(async () => {
  // Verificar agentes desconectados
  const { data: offlineAgents } = await supabase
    .from('agent_nodes')
    .select('business_id, name, last_seen')
    .eq('is_active', true)
    .lt('last_seen', new Date(Date.now() - 30 * 60 * 1000).toISOString())

  // Verificar secuencias NCF críticas
  const { data: lowNcf } = await supabase
    .from('ncf_sequences')
    .select('business_id, ncf_type, current_sequence, max_sequence')
    .eq('is_active', true)
    .filter('max_sequence - current_sequence', 'lt', 50)

  // TODO: enviar notificaciones (email, Slack, WhatsApp) con los resultados
  
  return new Response(JSON.stringify({ offlineAgents, lowNcf }), {
    headers: { 'Content-Type': 'application/json' }
  })
})
```

---

## 10. Checklist diario del operador

Realiza estas revisiones cada mañana antes de las 9:00 AM:

### Revisión rápida (5 minutos)

- [ ] Ejecutar la **vista global** (sección 8) para ver estado general de todos los negocios
- [ ] Verificar que todos los **agentes activos** están en línea (`estado_agente = 'EN LINEA'`)
- [ ] Confirmar que no hay **print_fallas > 5** en ningún negocio
- [ ] Revisar si hay **membresías próximas a vencer** (próximos 7 días)

### Revisión de facturación (10 minutos)

- [ ] Verificar que las **secuencias NCF** tienen disponibilidad > 100 en todos los negocios activos
- [ ] Confirmar que no hay **comprobantes sin NCF asignado** del día anterior
- [ ] Revisar **discrepancias de cierre de caja** del día anterior > RD$100

### Revisión de incidencias (5 minutos)

- [ ] Revisar la tabla `audit_logs` buscando acciones de **anulación o eliminación** inusuales
- [ ] Confirmar que no hay **sesiones de caja abiertas** de más de 24 horas
- [ ] Revisar si hay **órdenes fantasma** (abiertas > 8 horas sin pago)

### Revisión semanal (lunes)

- [ ] Comparar ventas semana actual vs anterior por negocio
- [ ] Revisar tasa de éxito de impresión semanal por negocio
- [ ] Auditar usuarios con roles elevados (`owner`/`admin`) añadidos recientemente
- [ ] Verificar integridad: pagos sin orden, comprobantes sin pago

---

## Apéndice — Tablas de referencia rápida

### Tablas principales por dominio

| Dominio | Tablas clave |
|---------|-------------|
| Ventas | `orders`, `order_items`, `payments` |
| Fiscal | `fiscal_documents`, `ncf_sequences`, `fiscal_settings` |
| Caja | `cash_registers`, `cash_register_sessions`, `cash_transactions` |
| Impresión | `print_jobs`, `printers`, `agent_nodes`, `discovery_jobs` |
| Auditoría | `audit_logs` |
| Acceso | `user_businesses`, `memberships`, `user_roles` |
| Inventario | `inventory_items`, `inventory_stock`, `inventory_movements` |
| Clientes | `customers`, `customer_credits`, `customer_points` |

### Estados de documentos fiscales

| Estado | Significado |
|--------|-------------|
| `active` | Comprobante válido emitido |
| `void` | Anulado |
| `pending` | En proceso de emisión |

### Estados de trabajos de impresión

| Estado | Significado |
|--------|-------------|
| `pending` | En cola, esperando agente |
| `printed` | Impreso correctamente |
| `failed` | Error al imprimir (ver campo `error`) |

---

*Documento generado para operadores de la plataforma MangoPOS. Actualizar conforme se agreguen nuevas funcionalidades.*
