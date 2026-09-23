-- =============================================================================
-- Salida por limpieza — un motivo más para el ajuste de inventario
--
-- CONTEXTO: el catálogo de motivos (20260513_0017) tiene rotura, vencimiento,
-- robo, donación, corrección y conteo físico. Falta el que la cocina usa a
-- diario: lo que se bota al limpiar la nevera o la línea. Hoy eso entra como
-- «Otro» con nota libre, y por eso no se puede sacar un reporte de cuánto se
-- pierde limpiando — que es justo el número que el dueño quiere ver.
--
-- ENTREGA: `cleaning` dentro del CHECK de `inventory_movements.reason_code`.
--
-- ADITIVO Y SIN RIESGO: el CHECK se amplía, no se restringe. Ninguna fila
-- existente puede volverse inválida, así que la migración no puede fallar por
-- datos. Lo único que comparte con el resto es el bloqueo de la tabla, y va
-- con tope (abajo).
--
-- El catálogo de la app vive en `lib/presentation/inventory/state/
-- adjust_reasons.dart` y hay que mantenerlo a la par: el backend valida contra
-- este CHECK y la app dibuja los chips desde ese archivo.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK), siempre que no haya filas
-- con `reason_code = 'cleaning'`.
-- =============================================================================

-- ALTER TABLE pide bloqueo EXCLUSIVO de inventory_movements. Si una transacción
-- larga lo tiene tomado, sin tope esto se queda esperando y detrás se encolan
-- las lecturas de inventario de TODOS los negocios. Con el tope, si no lo
-- consigue en 5 s aborta limpio y se vuelve a correr en un momento tranquilo.
set local lock_timeout = '5s';

do $$
begin
  -- ¿ya está? entonces no hay nada que hacer
  if exists (
    select 1 from pg_constraint
     where conname = 'inventory_movements_reason_code_check'
       and conrelid = 'public.inventory_movements'::regclass
       and pg_get_constraintdef(oid) like '%cleaning%'
  ) then
    raise notice 'El CHECK ya acepta «cleaning». No se toco nada.';
    return;
  end if;

  alter table public.inventory_movements
    drop constraint if exists inventory_movements_reason_code_check;

  alter table public.inventory_movements
    add constraint inventory_movements_reason_code_check
    check (
      reason_code is null
      or reason_code in (
        'physical_count',
        'breakage',
        'expiration',
        'cleaning',     -- NUEVO: lo que se bota al limpiar nevera o línea
        'theft',
        'donation',
        'correction',
        'other'
      )
    );

  raise notice 'CHECK ampliado: «cleaning» aceptado.';
end
$$;

comment on column public.inventory_movements.reason_code is
  'Razón estructurada del ajuste (solo aplica a movimientos tipo '
  'adjustment / adjustment_in / adjustment_out). Permite reportes '
  'por causa: mermas por vencimiento, rotura, limpieza, robo, etc. '
  'El catálogo de la app es lib/presentation/inventory/state/adjust_reasons.dart '
  'y tiene que decir lo mismo que este CHECK.';

-- PostgREST: refrescar el caché de esquema para que la app vea el cambio sin
-- reiniciar el servicio.
notify pgrst, 'reload schema';
