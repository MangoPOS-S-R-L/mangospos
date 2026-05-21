-- =============================================================================
-- Fase 1 — Printing v2 fix: autofill de printers.transport en INSERT.
--
-- PROBLEMA detectado en runtime:
--   Después de aplicar 20260521_0001_printers_extend_v2 (que hace
--   `transport` NOT NULL después del backfill), los INSERT que vienen
--   del código legacy `PrintingRepository.createPrinter` fallan porque
--   ese código no setea `transport` en el insert. Solo manda `type`
--   (legacy enum), no `transport` (v2 text).
--
--   Error en producción:
--     PostgrestException: null value in column "transport" of relation
--     "printers" violates not-null constraint (code 23502)
--
-- FIX:
--   Trigger BEFORE INSERT que deriva `transport` desde `type` si llega
--   NULL. Defensa total: cubre el flujo legacy + cualquier código que
--   inserte sin pasar por el wrapper Dart.
--
--   En UPDATE NO se hace nada — si el usuario cambia `type`
--   explícitamente, el código Dart debe encargarse de mantener
--   `transport` coherente. La lógica de "auto-sync en update" se
--   considera invasiva y fuera de scope.
--
-- COMPATIBILIDAD:
--   100% seguro. Solo aplica cuando `transport` es NULL al insertar.
--   Los INSERTs nuevos que SÍ mandan `transport` (vía orchestrator v2)
--   conservan el valor explícito.
-- =============================================================================

begin;

create or replace function public.fn_printer_autofill_transport()
returns trigger
language plpgsql
as $$
begin
  if new.transport is null then
    new.transport := case new.type::text
      when 'network'   then 'lan'
      when 'bluetooth' then 'bluetooth'
      when 'usb'       then 'usb'
      else 'lan'  -- fallback seguro
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_printer_autofill_transport on public.printers;
create trigger trg_printer_autofill_transport
  before insert on public.printers
  for each row
  execute function public.fn_printer_autofill_transport();

comment on function public.fn_printer_autofill_transport is
  'Deriva printers.transport desde printers.type cuando el INSERT no '
  'lo provee. Fix para createPrinter legacy que no fue actualizado a v2. '
  'En UPDATE no hace nada — se asume que quien edita type también '
  'actualiza transport (o lo deja igual).';

commit;
