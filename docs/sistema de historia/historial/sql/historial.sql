-- =========================================================
-- Cambio 4: Historial de cambios (quién creó, cambió o borró qué, y cuándo)
-- Pegar completo en Supabase → SQL Editor → Run.
-- =========================================================

create table if not exists historial (
  id bigserial primary key,
  negocio_id uuid not null references negocios(id) on delete cascade,
  tabla text not null,                 -- facturas, cotizaciones, pagos, productos, clientes, miembros, negocios
  fila_id text not null,               -- id de lo que cambió
  accion text not null,                -- crear | editar | borrar
  etiqueta text not null default '',   -- F-00012, COT-2026-0004, nombre del producto o cliente…
  quien uuid,
  quien_nombre text not null default '',
  cuando timestamptz not null default now(),
  cambios jsonb not null default '{}'::jsonb  -- editar: {campo: [antes, después]} · crear/borrar: la fila completa
);
create index if not exists historial_neg on historial(negocio_id, cuando desc);
create index if not exists historial_fila on historial(negocio_id, fila_id);

-- Solo el dueño y los administradores lo ven. Nadie lo puede editar ni borrar desde la app.
alter table historial enable row level security;
drop policy if exists hist_ver on historial;
create policy hist_ver on historial for select using (es_admin(negocio_id));
revoke insert, update, delete on historial from authenticated, anon;
grant select on historial to authenticated;

create or replace function registrar_historial() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_neg uuid; v_id text; v_etq text; v_quien text;
  v_cambios jsonb := '{}'::jsonb; k text;
  v_co jsonb; v_cn jsonb;
begin
  if tg_table_name = 'negocios' then v_neg := (v_row->>'id')::uuid; v_id := v_row->>'id';
  elsif tg_table_name = 'miembros' then v_neg := (v_row->>'negocio_id')::uuid; v_id := v_row->>'user_id';
  else v_neg := (v_row->>'negocio_id')::uuid; v_id := v_row->>'id'; end if;

  -- Si se está borrando el negocio completo, no hay nada que registrar
  if not exists (select 1 from negocios where id = v_neg) then return null; end if;

  v_etq := coalesce(nullif(v_row->>'numero', ''), nullif(v_row->>'nombre', ''), nullif(v_row->>'email', ''), '');

  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      continue when k in ('actualizado', 'creado', 'config');
      if v_old->k is distinct from v_new->k then
        v_cambios := v_cambios || jsonb_build_object(k, jsonb_build_array(v_old->k, v_new->k));
      end if;
    end loop;
    -- Configuración: solo los datos que cambiaron (el logo no se copia, solo se anota)
    if tg_table_name = 'negocios' and v_old->'config' is distinct from v_new->'config' then
      v_co := coalesce(v_old->'config', '{}'::jsonb); v_cn := coalesce(v_new->'config', '{}'::jsonb);
      for k in select jsonb_object_keys(v_co || v_cn) loop
        if v_co->k is distinct from v_cn->k then
          v_cambios := v_cambios || jsonb_build_object('config.' || k,
            case when k = 'logo' then jsonb_build_array(case when coalesce(v_co->>k, '') = '' then null else 'imagen' end, case when coalesce(v_cn->>k, '') = '' then null else 'imagen nueva' end)
            else jsonb_build_array(v_co->k, v_cn->k) end);
        end if;
      end loop;
    end if;
    if v_cambios = '{}'::jsonb then return null; end if;
  else
    v_cambios := v_row - 'config';
  end if;

  if auth.uid() is null then v_quien := 'Sistema';
  else
    select nombre into v_quien from miembros where negocio_id = v_neg and user_id = auth.uid();
    if v_quien is null then v_quien := case when exists (select 1 from superadmins where user_id = auth.uid()) then 'Administración de la plataforma' else '' end; end if;
    if v_quien = '' then select coalesce(email, '') into v_quien from auth.users where id = auth.uid(); end if;
  end if;

  insert into historial(negocio_id, tabla, fila_id, accion, etiqueta, quien, quien_nombre, cambios)
  values (v_neg, tg_table_name, v_id, case tg_op when 'INSERT' then 'crear' when 'UPDATE' then 'editar' else 'borrar' end,
          v_etq, auth.uid(), coalesce(v_quien, ''), v_cambios);
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['facturas','cotizaciones','pagos','productos','clientes','miembros'] loop
    execute format('drop trigger if exists %I_historial on %I', t, t);
    execute format('create trigger %I_historial after insert or update or delete on %I for each row execute function registrar_historial()', t, t);
  end loop;
end $$;
drop trigger if exists negocios_historial on negocios;
create trigger negocios_historial after update on negocios for each row execute function registrar_historial();

select 'Listo: el historial ya está guardando los cambios' as resultado;
