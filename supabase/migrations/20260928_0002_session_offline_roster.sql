-- Download offline PIN access using an existing business session. No manual
-- terminal registration is required. Keep fn_sync_roster(text) for old clients.
begin;

create or replace function public.fn_sync_business_roster(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_roster jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501';
  end if;
  if p_business_id is null or not exists (
    select 1 from public.user_businesses
     where user_id = auth.uid() and business_id = p_business_id
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', ub.user_id,
    'employee_id', e.id,
    'name', coalesce(nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), ''),
                     p.full_name, p.email, ''),
    'first_name', e.first_name,
    'last_name', e.last_name,
    'email', coalesce(e.email, p.email),
    'pin_hash', e.pin_hash,
    'role', coalesce(ub.role, ''),
    'permissions', coalesce(perms.granted, '[]'::jsonb),
    'is_active', coalesce(e.status, 'active') = 'active'
  )), '[]'::jsonb)
  into v_roster
  from (select * from public.user_businesses where business_id = p_business_id) ub
  full join (select * from public.employees where business_id = p_business_id) e
    on e.user_id = ub.user_id
  left join public.profiles p on p.id = ub.user_id
  left join lateral (
    select jsonb_agg(ep.code order by ep.code) as granted
    from public.fn_user_effective_permissions(ub.user_id, p_business_id) ep
    where ep.allowed = true
  ) perms on ub.user_id is not null
  -- Employees without a login may identify themselves as waiters, but an
  -- employee whose business membership was removed must lose PIN access.
  where ub.user_id is not null or e.user_id is null;

  return jsonb_build_object(
    'business_id', p_business_id,
    'synced_at', now(),
    'roster', v_roster
  );
end;
$$;

revoke all on function public.fn_sync_business_roster(uuid) from public, anon;
grant execute on function public.fn_sync_business_roster(uuid) to authenticated;

commit;
