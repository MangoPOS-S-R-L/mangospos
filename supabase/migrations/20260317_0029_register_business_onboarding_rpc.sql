-- Register business onboarding RPC for MangoPOS
-- Creates the auth user, business, RBAC defaults and stores onboarding/commercial metadata.

create table if not exists public.business_onboarding (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  plan_code text not null check (plan_code in ('base', 'pro', 'enterprise')),
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly', 'yearly')),
  trial_days integer not null default 14 check (trial_days >= 0 and trial_days <= 365),
  source text,
  campaign text,
  created_at timestamptz not null default now()
);

alter table public.business_onboarding enable row level security;

drop policy if exists "business_onboarding_select_own" on public.business_onboarding;
create policy "business_onboarding_select_own"
on public.business_onboarding
for select
to authenticated
using (
  exists (
    select 1
    from public.user_businesses ub
    where ub.business_id = business_onboarding.business_id
      and ub.user_id = auth.uid()
  )
);

create or replace function public.register_business_onboarding(
  p_full_name text,
  p_email text,
  p_phone text,
  p_password text,
  p_business_name text,
  p_business_type text,
  p_country text,
  p_business_phone text,
  p_domain text,
  p_plan_code text default 'base',
  p_billing_cycle text default 'monthly',
  p_trial_days integer default 14,
  p_source text default null,
  p_campaign text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid;
  v_business_id uuid;
  v_domain text;
begin
  if p_email is null or trim(p_email) = '' then
    raise exception 'EMAIL_REQUIRED';
  end if;

  if p_password is null or length(p_password) < 8 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  if p_business_name is null or trim(p_business_name) = '' then
    raise exception 'BUSINESS_NAME_REQUIRED';
  end if;

  if p_domain is null or trim(p_domain) = '' then
    raise exception 'DOMAIN_REQUIRED';
  end if;

  if p_plan_code not in ('base', 'pro', 'enterprise') then
    raise exception 'INVALID_PLAN';
  end if;

  if p_billing_cycle not in ('monthly', 'yearly') then
    raise exception 'INVALID_BILLING_CYCLE';
  end if;

  v_domain := lower(trim(p_domain));

  -- If only a slug is sent, complete the MangoPOS domain.
  if v_domain !~ '\.mangopos\.do$' then
    v_domain := v_domain || '.mangopos.do';
  end if;

  -- Create auth user + profile.
  v_user_id := public.create_new_user(
    p_email,
    p_password,
    jsonb_build_object(
      'full_name', p_full_name,
      'phone', p_phone
    )
  );

  -- Create business. Existing trigger should seed defaults and attach owner to user_businesses.
  insert into public.businesses (
    owner_id,
    business_name,
    business_type,
    country,
    phone,
    domain,
    status
  )
  values (
    v_user_id,
    trim(p_business_name),
    nullif(trim(p_business_type), ''),
    nullif(trim(p_country), ''),
    nullif(trim(p_business_phone), ''),
    v_domain,
    'active'
  )
  returning id into v_business_id;

  -- Ensure RBAC defaults exist for this business.
  perform public.fn_seed_business_rbac_defaults(v_business_id);

  -- Store commercial/onboarding context.
  insert into public.business_onboarding (
    business_id,
    plan_code,
    billing_cycle,
    trial_days,
    source,
    campaign
  )
  values (
    v_business_id,
    p_plan_code,
    p_billing_cycle,
    coalesce(p_trial_days, 14),
    nullif(trim(p_source), ''),
    nullif(trim(p_campaign), '')
  )
  on conflict (business_id) do update
  set
    plan_code = excluded.plan_code,
    billing_cycle = excluded.billing_cycle,
    trial_days = excluded.trial_days,
    source = excluded.source,
    campaign = excluded.campaign;

  return jsonb_build_object(
    'user_id', v_user_id,
    'business_id', v_business_id,
    'domain', v_domain,
    'plan_code', p_plan_code
  );
end;
$$;

grant execute on function public.register_business_onboarding(
  text, text, text, text, text, text, text, text, text, text, text, integer, text, text
) to anon, authenticated;
