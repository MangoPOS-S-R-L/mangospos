-- =============================================================================
-- VERIFICAR 20260915_0006 (precio especial) + mangopos_administrador 0043
--
-- Correr DESPUÉS de aplicar ambas migraciones. Los bloques 1–2 son solo
-- lectura. El bloque 3 prueba la regla sobre una membresía real DENTRO de una
-- transacción que termina en ROLLBACK: no deja cambios.
--
-- En Supabase Studio solo se ve el ÚLTIMO resultado y no se ven los NOTICE:
-- corriendo el archivo entero, lo que aparece es la fila `resultado` del
-- bloque 3 ("OK — …" o "SIN DATOS — …"). Si algo falla, aparece un error
-- "FALLA …" en su lugar. Para ver los bloques 1 y 2, correrlos por separado.
-- =============================================================================

-- 1. Columnas nuevas en memberships. Esperado: 3 filas.
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and table_name   = 'memberships'
   and column_name like 'price_override%'
 order by column_name;

-- 1b. UNA sola FK memberships → plans (la de plan_id). Con dos, PostgREST no
--     resuelve `plan:plans(*)` y el POS y mango_dashboard fallan al abrir.
--     Esperado: 1 fila, columna plan_id. Si sale price_override_plan_id,
--     falta aplicar 20260915_0008.
select a.attname as columna, con.conname as constraint_name
  from pg_constraint con
  join pg_attribute a
    on a.attrelid = con.conrelid
   and a.attnum = any(con.conkey)
 where con.conrelid = 'public.memberships'::regclass
   and con.contype = 'f'
   and con.confrelid = 'public.plans'::regclass;

-- 2. Funciones y permisos.
--    Esperado: las 3 de precio con authenticated=false / service_role=true;
--    las 2 admin_* con authenticated=true (se gatean por dentro).
select p.proname,
       pg_get_function_identity_arguments(p.oid)                    as args,
       has_function_privilege('authenticated', p.oid, 'execute')     as authenticated,
       has_function_privilege('service_role',  p.oid, 'execute')     as service_role
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in (
     'subscription_price_override_cents',
     'subscription_effective_price_cents',
     'business_price_override_cents',
     'admin_set_price_override',
     'admin_clear_price_override'
   )
 order by p.proname;

-- 3. Prueba funcional. Si algo falla, aborta con "FALLA ..." y no hay nada
--    que limpiar (ROLLBACK).
begin;

-- Acá se escribe el veredicto para que Studio lo muestre. Es temporal y se
-- va con el ROLLBACK.
create temp table _verificar (resultado text);

do $$
declare
  v_m    uuid;
  v_plan uuid;
  v_biz  uuid;
  v_code text;
  v_list int;
  v_got  int;
begin
  select m.id, m.plan_id, m.business_id, p.code, p.price_cents_monthly
    into v_m, v_plan, v_biz, v_code, v_list
    from public.memberships m
    join public.plans p on p.id = m.plan_id
   where m.is_billing_anchor
     and p.price_cents_monthly > 100
   limit 1;

  if v_m is null then
    raise notice 'No hay membresía ancla con plan de pago para probar.';
    insert into _verificar values
      ('SIN DATOS — no hay membresía ancla con plan de pago; la prueba funcional no corrió.');
    return;
  end if;

  -- a) Sin precio especial → lista.
  update public.memberships
     set price_override_cents = null, price_override_plan_id = null,
         price_override_ends_on = null
   where id = v_m;
  v_got := public.subscription_effective_price_cents(v_m, current_date);
  if v_got <> v_list then
    raise exception 'FALLA a) sin descuento: esperado %, obtuvo %', v_list, v_got;
  end if;

  -- b) Vigente → precio especial.
  update public.memberships
     set price_override_cents = v_list - 100, price_override_plan_id = v_plan
   where id = v_m;
  v_got := public.subscription_effective_price_cents(v_m, current_date);
  if v_got <> v_list - 100 then
    raise exception 'FALLA b) vigente: esperado %, obtuvo %', v_list - 100, v_got;
  end if;

  -- c) Misma regla por negocio + código de plan (facturas y MRR).
  v_got := public.business_price_override_cents(v_biz, v_code, current_date);
  if v_got is distinct from v_list - 100 then
    raise exception 'FALLA c) por negocio: esperado %, obtuvo %', v_list - 100, v_got;
  end if;
  if public.business_price_override_cents(v_biz, v_code || '_otro', current_date) is not null then
    raise exception 'FALLA c) aplicó a un plan que no es el suyo';
  end if;

  -- d) Venció antes del período → lista.
  update public.memberships set price_override_ends_on = current_date - 1 where id = v_m;
  v_got := public.subscription_effective_price_cents(v_m, current_date);
  if v_got <> v_list then
    raise exception 'FALLA d) vencido: esperado %, obtuvo %', v_list, v_got;
  end if;

  -- e) Vence el mismo día del período → aplica (inclusive).
  update public.memberships set price_override_ends_on = current_date where id = v_m;
  v_got := public.subscription_effective_price_cents(v_m, current_date);
  if v_got <> v_list - 100 then
    raise exception 'FALLA e) vence hoy: esperado %, obtuvo %', v_list - 100, v_got;
  end if;

  -- f) Acordado por encima de la lista → nunca cobra más que la lista.
  update public.memberships
     set price_override_cents = v_list + 5000, price_override_ends_on = null
   where id = v_m;
  v_got := public.subscription_effective_price_cents(v_m, current_date);
  if v_got <> v_list then
    raise exception 'FALLA f) tope de lista: esperado %, obtuvo %', v_list, v_got;
  end if;

  -- g) Constraint: monto sin plan es inválido.
  begin
    update public.memberships
       set price_override_cents = 1000, price_override_plan_id = null
     where id = v_m;
    raise exception 'FALLA g) aceptó precio especial sin plan';
  exception when check_violation then
    null; -- esperado
  end;

  raise notice 'OK — todas las verificaciones pasaron (membresía %, lista %).', v_m, v_list;
  insert into _verificar values (format(
    'OK — las 7 verificaciones pasaron (membresía %s, lista %s centavos).',
    v_m, v_list
  ));
end $$;

select resultado from _verificar;

rollback;
