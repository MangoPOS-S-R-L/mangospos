-- 20260225_0001_sprint1_p0_fiscal_roles.sql
-- Scope: Sprint 1 P0 blockers (fiscal + role constraint)
-- Status: Draft for approval

begin;

-- =====================================================
-- A) Fiscal: reemplazar create_fiscal_document mock
-- =====================================================
create or replace function public.create_fiscal_document(
  p_order_id uuid,
  p_payment_id uuid,
  p_customer_id uuid,
  p_customer_rnc text
)
returns public.fiscal_documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc public.fiscal_documents;
  v_doc_id uuid;
begin
  -- Idempotencia: si ya existe documento para el pago/orden, retornarlo.
  select *
    into v_doc
  from public.fiscal_documents fd
  where (p_payment_id is not null and fd.payment_id = p_payment_id)
     or (fd.order_id = p_order_id and fd.status = 'active')
  order by fd.created_at desc
  limit 1;

  if found then
    return v_doc;
  end if;

  -- Emisión real usando secuencia NCF.
  v_doc_id := public.issue_fiscal_document(p_order_id, p_payment_id);

  select * into v_doc
  from public.fiscal_documents
  where id = v_doc_id;

  -- Completar datos de cliente si fueron provistos.
  if p_customer_id is not null or p_customer_rnc is not null then
    update public.fiscal_documents
       set customer_id = coalesce(customer_id, p_customer_id),
           customer_rnc = coalesce(customer_rnc, p_customer_rnc)
     where id = v_doc_id
     returning * into v_doc;
  end if;

  return v_doc;
end;
$$;

comment on function public.create_fiscal_document(uuid, uuid, uuid, text)
  is 'Sprint1 P0: emision fiscal real e idempotente, sin NCF hardcodeado.';

-- =====================================================
-- B) Roles: alinear constraint de user_businesses.role
-- =====================================================
alter table public.user_businesses
  drop constraint if exists user_businesses_role_check;

alter table public.user_businesses
  add constraint user_businesses_role_check
  check (
    role = any (
      array[
        'owner'::text,
        'admin'::text,
        'manager'::text,
        'cashier'::text,
        'waiter'::text,
        'cook'::text,
        'chef'::text,
        'delivery'::text
      ]
    )
  );

commit;

-- Rollback guide (manual):
-- 1) Restaurar create_fiscal_document previo desde snapshot/tag.
-- 2) Restaurar constraint anterior user_businesses_role_check.
