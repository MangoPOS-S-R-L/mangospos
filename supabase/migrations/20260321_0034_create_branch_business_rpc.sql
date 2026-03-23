begin;

create extension if not exists pgcrypto;

create or replace function public.create_branch_business(
  p_business_name text,
  p_branch_name text,
  p_address text default null,
  p_phone text default null,
  p_business_type text default null,
  p_country text default null,
  p_domain text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_business_id uuid;
  v_business_name text;
  v_branch_name text;
  v_domain text;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_business_name := nullif(trim(p_business_name), '');
  v_branch_name := nullif(trim(p_branch_name), '');

  if v_business_name is null then
    raise exception 'BUSINESS_NAME_REQUIRED';
  end if;

  if v_branch_name is null then
    raise exception 'BRANCH_NAME_REQUIRED';
  end if;

  v_domain := nullif(lower(trim(coalesce(p_domain, ''))), '');

  if v_domain is null then
    v_domain := regexp_replace(lower(v_business_name || '-' || v_branch_name), '[^a-z0-9]+', '-', 'g');
    v_domain := regexp_replace(v_domain, '-{2,}', '-', 'g');
    v_domain := regexp_replace(v_domain, '(^-+|-+$)', '', 'g');
    v_domain := v_domain || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10) || '.mangopos.do';
  elsif v_domain !~ '\.mangopos\.do$' then
    v_domain := v_domain || '.mangopos.do';
  end if;

  insert into public.businesses (
    owner_id,
    business_name,
    branch_name,
    business_type,
    country,
    address,
    phone,
    domain,
    status
  )
  values (
    v_user_id,
    v_business_name,
    v_branch_name,
    nullif(trim(p_business_type), ''),
    nullif(trim(p_country), ''),
    nullif(trim(p_address), ''),
    nullif(trim(p_phone), ''),
    v_domain,
    'active'
  )
  returning id into v_business_id;

  insert into public.user_businesses (user_id, business_id, role, permissions, created_at)
  values (
    v_user_id,
    v_business_id,
    'owner',
    array['all']::text[],
    now()
  )
  on conflict (user_id, business_id) do update
    set role = excluded.role,
        permissions = excluded.permissions;

  perform public.fn_seed_business_rbac_defaults(v_business_id);

  begin
    insert into public.memberships (
      user_id,
      business_id,
      plan_type,
      status,
      start_date,
      created_at
    )
    values (
      v_user_id,
      v_business_id,
      'pro',
      'active',
      now(),
      now()
    );
  exception
    when undefined_table then
      null;
    when others then
      null;
  end;

  return jsonb_build_object(
    'business_id', v_business_id,
    'business_name', v_business_name,
    'branch_name', v_branch_name,
    'domain', v_domain,
    'status', 'active'
  );
end;
$$;

grant execute on function public.create_branch_business(text, text, text, text, text, text, text) to authenticated;

commit;
