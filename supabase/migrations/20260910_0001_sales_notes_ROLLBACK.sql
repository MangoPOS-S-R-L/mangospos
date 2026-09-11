-- Rollback de 20260910_0001_sales_notes.sql
--
-- Devuelve los dos triggers de cierre a su cuerpo previo (sin el guard) y
-- borra la funcion de emision. Las columnas y la tabla NO se borran por
-- defecto: si el negocio ya emitio notas de venta, ese DROP tira documentos
-- entregados a clientes. Descomenta el bloque final solo si estas seguro de
-- que no se emitio ninguna (`select count(*) from public.sales_notes;`).
--
-- Con el guard fuera, una orden marcada `is_sales_note` vuelve a emitir NCF al
-- cerrarse. Si quedan ordenes abiertas marcadas, limpialas antes:
--   update public.orders set is_sales_note = false where closed_at is null;
--   update public.order_checks set is_sales_note = false where is_closed = false;

begin;

create or replace function public.trg_fn_issue_fd_on_check_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_closed = true
     and (old.is_closed is null or old.is_closed = false)
     and new.position > 1 then
    if exists (
      select 1 from public.payments
      where check_id = new.id and status = 'completed'
    ) then
      perform public.create_fiscal_document(new.order_id, new.id);
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.trg_fn_issue_fd_on_order_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_subchecks boolean;
begin
  if new.closed_at is not null
     and old.closed_at is null then

    select exists (
      select 1 from public.order_checks
      where order_id = new.id and position > 1
    ) into v_has_subchecks;

    if not v_has_subchecks then
      if exists (
        select 1 from public.payments
        where order_id = new.id and check_id is null and status = 'completed'
      ) then
        perform public.create_fiscal_document(new.id, null);
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop function if exists public.fn_issue_sales_note(uuid, uuid);

-- La vista `sales_documents` NO se borra aqui: es de solo lectura y el
-- historial la consulta con fallback a fiscal_documents, asi que dejarla no
-- hace dano. Sin notas emitidas devuelve exactamente lo mismo que antes.

-- Apaga la feature sin perder los documentos ya emitidos.
update public.business_settings set sales_note_enabled = false;

commit;

-- -- DESTRUCTIVO: borra las notas emitidas. Solo si nunca se uso.
-- begin;
-- drop view if exists public.sales_documents;
-- alter table public.payments drop column if exists sales_note_id;
-- drop table if exists public.sales_notes;
-- alter table public.orders drop column if exists is_sales_note;
-- alter table public.order_checks drop column if exists is_sales_note;
-- alter table public.business_settings drop column if exists sales_note_enabled;
-- alter table public.business_settings drop column if exists sales_note_prefix;
-- alter table public.business_settings drop column if exists sales_note_default;
-- commit;
