-- =============================================================================
-- LA PENDA EXPRESS — el nombre de cada conteo
--
-- El nombre del área vive en `physical_count_sessions.notes`. Es lo que sale
-- en la columna «area» de todos los exports. Si está vacío, el archivo del
-- auditor dice «(sin nombre de área)» y las cinco hojas son indistinguibles.
-- =============================================================================

-- ── 1. Cómo se llaman hoy ──────────────────────────────────────────────────
select
  s.code,
  coalesce(s.notes, '⚠ SIN NOMBRE')                        as nombre_del_conteo,
  w.name                                                   as bodega,
  coalesce(e.first_name || ' ' || e.last_name, '(sin empleado)') as abrio,
  (s.frozen_at at time zone 'America/Santo_Domingo')       as congelada,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id and l.counted_quantity is not null) as contados
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.employees e
       on e.user_id = s.started_by and e.business_id = s.business_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
order by s.code;


-- ── 2. Ponerles nombre ─────────────────────────────────────────────────────
-- Ajustar los textos a como se llaman de verdad y correr.
-- El nombre es lo que va a leer el auditor en cada hoja, así que conviene que
-- diga el ÁREA y QUIÉN contó: si mañana un número no cuadra, eso es lo que
-- permite ir a preguntarle a la persona correcta.

begin;

update public.physical_count_sessions s
   set notes = v.nombre
  from (values
    ('PC-2026-000002', 'Furgón y Almacén Principal · Diego'),
    ('PC-2026-000003', 'Almacén de Cocina · Robinson'),
    ('PC-2026-000004', 'Food Shop · Winnifer'),
    ('PC-2026-000005', 'Food Shop · Rosayra'),
    ('PC-2026-000006', 'Bar · DH')
  ) as v(code, nombre)
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.code = v.code
   and s.status = 'in_progress';

commit;
-- 5 filas.


-- ── 3. Verificar ───────────────────────────────────────────────────────────
-- Correr otra vez la consulta 1: ninguna debe decir «SIN NOMBRE».
-- Después, la 2b del archivo de exportación ya sale con el nombre en cada
-- fila, y la portada (consulta 1 de ese archivo) también.
