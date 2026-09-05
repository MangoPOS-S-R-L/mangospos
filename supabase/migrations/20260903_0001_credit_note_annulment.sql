-- =============================================================================
-- Anulacion con NOTA DE CREDITO automatica (e-CF 34 / NCF B04)
-- =============================================================================
-- PROBLEMA: anular una venta solo ponia fiscal_documents.status = 'cancelled'.
-- Eso vale para un comprobante que nunca salio del POS, pero NO para uno que
-- la DGII ya acepto: un e-CF aceptado no se "descancela" — la unica forma de
-- reversarlo es emitir una NOTA DE CREDITO que lo referencie. Sin ella el
-- negocio declara (y paga) ITBIS de una venta que devolvio.
--
-- QUE HACE ESTA MIGRACION:
--   1. Agrega B03/B04 al enum ncf_type (la serie de papel no tenia notas).
--   2. fiscal_documents.modification_code / modification_reason: el
--      CodigoModificacion de la DGII y su razon, que viajan en el e-CF 34.
--   3. fn_issue_credit_note(): emite la nota (E34 si el original es
--      electronico, B04 si es de papel) copiando montos EXACTOS del original.
--      El trigger tg_alanube_enqueue_emission la manda sola a la DGII.
--   4. v_fiscal_docs_pending_credit_note: las anuladas que se quedaron SIN
--      nota (tipico: el negocio no tiene secuencia E34 cargada todavia).
--
-- REGLA DE PRODUCTO: la funcion NUNCA tumba la anulacion. Si no hay secuencia
-- devuelve 'no_sequence' y la venta se anula igual; la nota queda pendiente y
-- se reintenta despues. Trancar al cajero con el cliente delante es peor que
-- emitir la nota diez minutos mas tarde.
-- =============================================================================

-- 1) Enum: la serie de papel necesita B04 (nota de credito) y de paso B03.
--    Va FUERA de la transaccion: Postgres no deja usar un valor de enum en la
--    misma transaccion donde se agrega. Por eso TODAS las comparaciones de
--    mas abajo van por `ncf_type::text` y no por literal de enum: asi el
--    archivo corre de una sola vez aunque el editor de Supabase lo mande
--    todo en una transaccion implicita.
alter type public.ncf_type add value if not exists 'B03';
alter type public.ncf_type add value if not exists 'B04';

begin;

-- 2) Columnas de la nota -------------------------------------------------
alter table public.fiscal_documents
  add column if not exists modification_code smallint,
  add column if not exists modification_reason text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fiscal_documents_modification_code_check'
  ) then
    alter table public.fiscal_documents
      add constraint fiscal_documents_modification_code_check
      check (modification_code is null or modification_code between 1 and 5);
  end if;
end $$;

comment on column public.fiscal_documents.modification_code is
  'CodigoModificacion DGII de una nota de credito/debito: 1 anula el e-CF de '
  'referencia, 2 corrige texto, 3 corrige montos, 4 reemplaza uno emitido en '
  'contingencia, 5 referencia un e-CF de consumo. Solo aplica a E33/E34/B03/B04.';
comment on column public.fiscal_documents.modification_reason is
  'RazonModificacion: el motivo de anulacion que tecleo el cajero.';

create index if not exists idx_fiscal_documents_related_document
  on public.fiscal_documents (related_document_id)
  where related_document_id is not null;

-- 3) fn_issue_credit_note ------------------------------------------------
create or replace function public.fn_issue_credit_note(
  p_fiscal_document_id uuid,
  p_reason text default null,
  p_modification_code smallint default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_doc public.fiscal_documents%rowtype;
  v_existing public.fiscal_documents%rowtype;
  v_note_type public.ncf_type;
  v_sequence_id uuid;
  v_ncf text;
  v_note_id uuid;
  v_attempts integer := 0;
  v_constraint_name text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into v_doc
  from public.fiscal_documents
  where id = p_fiscal_document_id
  for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  -- auth.uid() es null cuando corre service_role (cron/edge): ahi no hay
  -- usuario contra quien validar acceso y el llamador ya es de confianza.
  if auth.uid() is not null
     and not public.user_has_business_access(auth.uid(), v_doc.business_id) then
    raise exception 'Sin acceso al negocio del comprobante'
      using errcode = '42501';
  end if;

  if coalesce(btrim(v_doc.ncf_number), '') = '' then
    return jsonb_build_object('status', 'not_applicable', 'reason', 'sin_ncf');
  end if;

  -- Una nota no se anula con otra nota.
  if v_doc.ncf_type::text in ('E33', 'E34', 'B03', 'B04') then
    return jsonb_build_object('status', 'not_applicable', 'reason', 'es_nota');
  end if;

  -- e-CF RECHAZADO: no existe ante la DGII, no hay nada que reversar. Alanube
  -- ademas devuelve AP3012 si la nota referencia un documento rechazado.
  if v_doc.is_electronic and coalesce(v_doc.ecf_status, '') = 'rejected' then
    return jsonb_build_object('status', 'not_applicable', 'reason', 'rechazado');
  end if;

  -- Idempotencia: el mismo comprobante no se anula dos veces. Se reintenta
  -- desde la UI y desde el barrido de pendientes, y ambos caen aca.
  select * into v_existing
  from public.fiscal_documents
  where related_document_id = v_doc.id
    and ncf_type::text in ('E34', 'B04')
    and status = 'active'
  order by created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'status', 'already_issued',
      'credit_note_id', v_existing.id,
      'ncf_number', v_existing.ncf_number,
      'ncf_type', v_existing.ncf_type,
      'is_electronic', v_existing.is_electronic
    );
  end if;

  -- El cast va explicito por texto: 'E34'/'B04' recien pueden existir en el
  -- enum y Postgres no deja usarlos como literal en la misma transaccion.
  v_note_type := (case when v_doc.is_electronic then 'E34' else 'B04' end)::text::public.ncf_type;

  -- Sin secuencia utilizable no se emite NADA: se avisa y la anulacion sigue.
  -- Mismo predicado que generate_ncf para no prometer un numero que la
  -- funcion no va a poder dar.
  select s.id into v_sequence_id
  from public.ncf_sequences s
  where s.business_id = v_doc.business_id
    and s.ncf_type = v_note_type
    and s.is_active = true
    and s.current_number < s.range_end
    and (s.expiration_date is null or s.expiration_date > current_date)
  order by s.created_at desc, s.id desc
  limit 1;

  if v_sequence_id is null then
    return jsonb_build_object(
      'status', 'no_sequence',
      'ncf_type', v_note_type,
      'business_id', v_doc.business_id
    );
  end if;

  loop
    begin
      v_ncf := public.generate_ncf(v_doc.business_id, v_note_type);

      insert into public.fiscal_documents (
        business_id,
        order_id,
        check_id,
        payment_id,
        customer_id,
        ncf_type,
        ncf_number,
        ncf_sequence_id,
        customer_rnc,
        customer_name,
        customer_address,
        subtotal,
        discount,
        tax_exempt,
        taxable_amount,
        itbis_amount,
        service_fee,
        tip,
        total,
        is_electronic,
        related_document_id,
        modification_code,
        modification_reason,
        issued_by
      ) values (
        v_doc.business_id,
        v_doc.order_id,
        v_doc.check_id,
        -- Sin payment_id a proposito: la nota no cobra nada, y colgarla de un
        -- pago la metaria en el recalculo de totales por pago.
        null,
        v_doc.customer_id,
        v_note_type,
        v_ncf,
        v_sequence_id,
        v_doc.customer_rnc,
        v_doc.customer_name,
        v_doc.customer_address,
        -- Montos EXACTOS del original: con CodigoModificacion = 1 la DGII
        -- exige que el total de la nota sea igual al del comprobante que
        -- anula (Alanube AP3014).
        v_doc.subtotal,
        v_doc.discount,
        v_doc.tax_exempt,
        v_doc.taxable_amount,
        v_doc.itbis_amount,
        v_doc.service_fee,
        v_doc.tip,
        v_doc.total,
        v_doc.is_electronic,
        v_doc.id,
        coalesce(p_modification_code, 1),
        v_reason,
        auth.uid()
      )
      returning id into v_note_id;

      exit;
    exception
      when unique_violation then
        get stacked diagnostics v_constraint_name = CONSTRAINT_NAME;
        if v_constraint_name not in (
          'fiscal_documents_business_id_ncf_number_key',
          'fiscal_documents_ncf_number_key'
        ) then
          raise;
        end if;

        v_attempts := v_attempts + 1;
        if v_attempts >= 20 then
          raise exception 'Demasiadas colisiones de NCF al emitir la nota de credito'
            using errcode = 'P0001';
        end if;
    end;
  end loop;

  -- El original queda marcado y enlazado. Se respeta lo que ya haya escrito
  -- la app (motivo/usuario) en su propio paso de anulacion.
  update public.fiscal_documents
  set status              = 'cancelled',
      cancelled_at        = coalesce(cancelled_at, now()),
      cancelled_by        = coalesce(cancelled_by, auth.uid()),
      cancellation_reason = coalesce(cancellation_reason, v_reason),
      related_document_id = v_note_id
  where id = v_doc.id;

  return jsonb_build_object(
    'status', 'issued',
    'credit_note_id', v_note_id,
    'ncf_number', v_ncf,
    'ncf_type', v_note_type,
    'is_electronic', v_doc.is_electronic,
    'original_ncf', v_doc.ncf_number
  );
end;
$function$;

comment on function public.fn_issue_credit_note(uuid, text, smallint) is
  'Emite la nota de credito que reversa un comprobante fiscal: E34 si el '
  'original es electronico (la manda sola a la DGII via el trigger de Alanube) '
  'o B04 si es de papel. Copia los montos EXACTOS del original porque con '
  'CodigoModificacion = 1 la DGII exige que cuadren. Idempotente por '
  'related_document_id. NUNCA lanza por falta de secuencia: devuelve '
  'no_sequence para que la anulacion no se trabe.';

revoke all on function public.fn_issue_credit_note(uuid, text, smallint) from public;
grant execute on function public.fn_issue_credit_note(uuid, text, smallint) to authenticated;
grant execute on function public.fn_issue_credit_note(uuid, text, smallint) to service_role;

-- 4) Pendientes: anuladas SIN su nota de credito --------------------------
-- Es la lista que hay que perseguir. Un comprobante anulado que nunca genero
-- nota es ITBIS que el negocio va a pagar por una venta que devolvio.
create or replace view public.v_fiscal_docs_pending_credit_note as
select fd.id,
       fd.business_id,
       fd.order_id,
       fd.ncf_type,
       fd.ncf_number,
       fd.is_electronic,
       fd.ecf_status,
       fd.total,
       fd.cancelled_at,
       fd.cancellation_reason
from public.fiscal_documents fd
where fd.status = 'cancelled'
  and coalesce(btrim(fd.ncf_number), '') <> ''
  and fd.ncf_type::text not in ('E33', 'E34', 'B03', 'B04')
  and (fd.is_electronic is not true or coalesce(fd.ecf_status, '') <> 'rejected')
  and not exists (
    select 1 from public.fiscal_documents n
    where n.related_document_id = fd.id
      and n.ncf_type::text in ('E34', 'B04')
      and n.status = 'active'
  );

comment on view public.v_fiscal_docs_pending_credit_note is
  'Comprobantes anulados que todavia NO tienen nota de credito. Casi siempre '
  'es que falta cargar la secuencia E34/B04 del negocio.';

alter view public.v_fiscal_docs_pending_credit_note set (security_invoker = true);

grant select on public.v_fiscal_docs_pending_credit_note to authenticated;

commit;
