-- =====================================================================
-- OSIRIS · 01_estructura.sql
-- Estructura EDIFICIO → UNIDAD (torre/dispositivo) → GUARDIA → REGISTROS.
--
-- Es ADITIVA y se puede ejecutar más de una vez:
--   · no borra ni modifica datos existentes;
--   · a `eventos` y `presencia` solo les AGREGA columnas (las versiones
--     anteriores de la app siguen funcionando igual);
--   · las tablas nuevas nacen con RLS activo (solo las usa la app nueva).
--
-- ANTES de ejecutar: Authentication → Sign In / Providers → activar
-- "Allow anonymous sign-ins" (cada celular inicia sesión solo, sin
-- contraseña, y se vincula con un código de activación).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. EDIFICIOS
-- ---------------------------------------------------------------------
create table if not exists public.buildings (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,          -- el texto usado hasta hoy en eventos.edificio
  name        text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. UNIDADES OPERATIVAS (torre / dispositivo). Un edificio de un solo
--    celular tiene una unidad ("Principal"); uno de dos torres, dos.
-- ---------------------------------------------------------------------
create table if not exists public.units (
  id           uuid primary key default gen_random_uuid(),
  building_id  uuid not null references public.buildings(id),
  name         text not null,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (building_id, name),
  unique (id, building_id)                   -- para claves compuestas (misma unidad = mismo edificio)
);

-- ---------------------------------------------------------------------
-- 3. DISPOSITIVOS (celulares vinculados). user_id = sesión de Supabase del
--    celular. Un guardia/celular pertenece a UN edificio y UNA unidad; el
--    administrador puede ver todos.
-- ---------------------------------------------------------------------
create table if not exists public.devices (
  device_id     text primary key,            -- id de instalación de la app
  user_id       uuid unique references auth.users(id) on delete set null,
  building_id   uuid references public.buildings(id),
  unit_id       uuid,
  role          text not null default 'guardia' check (role in ('guardia', 'admin')),
  label         text,
  active        boolean not null default true,
  activated_at  timestamptz not null default now(),
  foreign key (unit_id, building_id) references public.units(id, building_id),
  check (role = 'admin' or (building_id is not null and unit_id is not null))
);

-- ---------------------------------------------------------------------
-- 4. CÓDIGOS DE ACTIVACIÓN (los genera el administrador desde la app)
-- ---------------------------------------------------------------------
create table if not exists public.activation_codes (
  code         text primary key,
  building_id  uuid references public.buildings(id),
  unit_id      uuid,
  role         text not null default 'guardia' check (role in ('guardia', 'admin')),
  max_uses     int not null default 1 check (max_uses > 0),
  uses         int not null default 0,
  expires_at   timestamptz not null default now() + interval '7 days',
  created_at   timestamptz not null default now(),
  foreign key (unit_id, building_id) references public.units(id, building_id),
  check (role = 'admin' or (building_id is not null and unit_id is not null))
);

-- ---------------------------------------------------------------------
-- 5. GUARDIAS. Cada guardia tiene un id ÚNICO que nunca se reutiliza.
--    No se borran: se desactivan (active = false + end_date) y conservan
--    su historial. Un reemplazo crea un guardia NUEVO que empieza en cero.
-- ---------------------------------------------------------------------
create table if not exists public.guards (
  id                 uuid primary key default gen_random_uuid(),
  building_id        uuid not null references public.buildings(id),
  unit_id            uuid not null,
  full_name          text not null check (length(trim(full_name)) > 0),
  document           text,
  phone              text,
  shift              text not null check (shift in ('DIURNO', 'NOCTURNO')),
  role               text not null default 'guardia'
                     check (role in ('guardia', 'franquero', 'supervisor', 'conserje', 'limpieza')),
  start_date         date not null default current_date,
  end_date           date,
  active             boolean not null default true,
  replaced_guard_id  uuid references public.guards(id),
  created_at         timestamptz not null default now(),
  unique (id, building_id),
  foreign key (unit_id, building_id) references public.units(id, building_id),
  check (active or end_date is not null),
  check (end_date is null or end_date >= start_date)
);
-- Regla: por unidad, UN guardia diurno y UN nocturno activos (el franquero,
-- supervisor, etc. no cuentan para esta regla).
create unique index if not exists guards_un_turno_activo
  on public.guards (unit_id, shift) where active and role = 'guardia';
create index if not exists guards_building on public.guards (building_id, active);

-- ---------------------------------------------------------------------
-- 6. ADVERTENCIAS por guardia
-- ---------------------------------------------------------------------
create table if not exists public.guard_warnings (
  id           uuid primary key default gen_random_uuid(),
  guard_id     uuid not null,
  building_id  uuid not null references public.buildings(id),
  occurred_at  timestamptz not null default now(),
  reason       text not null,
  description  text,
  created_by   text,
  status       text not null default 'ACTIVA' check (status in ('ACTIVA', 'RESUELTA')),
  notes        text,
  resolved_at  timestamptz,
  uid          text unique,                  -- id del celular: evita duplicados al reintentar
  created_at   timestamptz not null default now(),
  foreign key (guard_id, building_id) references public.guards(id, building_id)
);
create index if not exists guard_warnings_guard on public.guard_warnings (guard_id, occurred_at);

-- ---------------------------------------------------------------------
-- 7. EVENTOS y PRESENCIA: columnas nuevas (los registros viejos quedan
--    con NULL = archivo histórico; no se tocan).
-- ---------------------------------------------------------------------
alter table public.eventos   add column if not exists building_id uuid;
alter table public.eventos   add column if not exists unit_id uuid;
alter table public.eventos   add column if not exists guard_id uuid;
alter table public.presencia add column if not exists building_id uuid;
alter table public.presencia add column if not exists unit_id uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'eventos_building_fk') then
    alter table public.eventos add constraint eventos_building_fk
      foreign key (building_id) references public.buildings(id);
  end if;
  -- La unidad y el guardia deben ser del MISMO edificio del evento.
  if not exists (select 1 from pg_constraint where conname = 'eventos_unit_fk') then
    alter table public.eventos add constraint eventos_unit_fk
      foreign key (unit_id, building_id) references public.units(id, building_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'eventos_guard_fk') then
    alter table public.eventos add constraint eventos_guard_fk
      foreign key (guard_id, building_id) references public.guards(id, building_id);
  end if;
end $$;

-- Un evento con guardia o unidad SIEMPRE dice de qué edificio es (así las
-- claves compuestas de arriba se verifican siempre). Solo para filas nuevas.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'eventos_ctx_chk') then
    alter table public.eventos add constraint eventos_ctx_chk
      check ((guard_id is null and unit_id is null) or building_id is not null) not valid;
  end if;
end $$;

create index if not exists eventos_building_created on public.eventos (building_id, created_at);
-- Búsqueda "¿este envío ya llegó?" de la app (reintentos sin duplicar).
create index if not exists eventos_uid on public.eventos ((detalle->>'uid'));
create index if not exists eventos_guard_created    on public.eventos (guard_id, created_at);

-- Un mismo evento (mismo uid del celular) no puede quedar dos veces.
-- Si ya hay repetidos en el historial, NO se crea el índice y se avisa
-- (ver 00_diagnostico.sql, consulta 10); la app igual descarta repetidos.
do $$ begin
  if not exists (select 1 from pg_indexes where indexname = 'eventos_uid_unico') then
    if exists (select 1 from public.eventos where detalle ? 'uid'
               group by detalle->>'uid' having count(*) > 1) then
      raise notice 'Hay eventos con uid repetido: no se creó eventos_uid_unico.';
    else
      create unique index eventos_uid_unico on public.eventos ((detalle->>'uid')) where detalle ? 'uid';
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. FUNCIONES DE CONTEXTO (quién es el que pregunta)
-- ---------------------------------------------------------------------
create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' and active from public.devices where user_id = auth.uid()), false)
$$;

create or replace function public.mi_edificio() returns uuid
language sql stable security definer set search_path = public as $$
  select building_id from public.devices where user_id = auth.uid() and active
$$;

create or replace function public.mi_unidad() returns uuid
language sql stable security definer set search_path = public as $$
  select unit_id from public.devices where user_id = auth.uid() and active
$$;

create or replace function public.mi_dispositivo() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'device_id', d.device_id, 'role', d.role, 'active', d.active,
    'building_id', d.building_id, 'building_code', b.code, 'building_name', b.name,
    'unit_id', d.unit_id, 'unit_name', u.name)
  from public.devices d
  left join public.buildings b on b.id = d.building_id
  left join public.units u on u.id = d.unit_id
  where d.user_id = auth.uid()
$$;

-- ---------------------------------------------------------------------
-- 9. SEGURIDAD EN EL SERVIDOR: el edificio y la unidad de lo que escribe un
--    celular de guardia los pone la BASE (según el celular), no la app.
-- ---------------------------------------------------------------------
create or replace function public.forzar_contexto() returns trigger
language plpgsql security definer set search_path = public as $$
declare d public.devices;
begin
  select * into d from public.devices where user_id = auth.uid() and active;
  if found and d.role = 'guardia' then
    new.building_id := d.building_id;
    new.unit_id := d.unit_id;
  end if;
  return new;
end $$;

drop trigger if exists eventos_contexto on public.eventos;
create trigger eventos_contexto before insert on public.eventos
  for each row execute function public.forzar_contexto();
drop trigger if exists presencia_contexto on public.presencia;
create trigger presencia_contexto before insert or update on public.presencia
  for each row execute function public.forzar_contexto();

-- ---------------------------------------------------------------------
-- 10. ACCIONES (RPC)
-- ---------------------------------------------------------------------

-- Vincula ESTE celular (sesión actual) con el edificio/unidad del código.
create or replace function public.activar_dispositivo(p_codigo text, p_device_id text, p_label text default null)
returns json language plpgsql security definer set search_path = public as $$
declare c public.activation_codes;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  if coalesce(trim(p_device_id), '') = '' then raise exception 'Celular sin identificador'; end if;
  select * into c from public.activation_codes where code = upper(trim(p_codigo)) for update;
  if not found then raise exception 'Código no válido'; end if;
  if c.expires_at < now() then raise exception 'Código vencido'; end if;
  if c.uses >= c.max_uses then raise exception 'Código ya utilizado'; end if;
  update public.activation_codes set uses = uses + 1 where code = c.code;
  -- La sesión anterior de este usuario en otro id de celular deja de valer.
  update public.devices set user_id = null, active = false
    where user_id = auth.uid() and device_id <> p_device_id;
  insert into public.devices (device_id, user_id, building_id, unit_id, role, label, active, activated_at)
  values (p_device_id, auth.uid(), c.building_id, c.unit_id, c.role, p_label, true, now())
  on conflict (device_id) do update
    set user_id = excluded.user_id, building_id = excluded.building_id, unit_id = excluded.unit_id,
        role = excluded.role, label = coalesce(excluded.label, public.devices.label),
        active = true, activated_at = now();
  return public.mi_dispositivo();
end $$;

-- El administrador crea un código para vincular un celular.
create or replace function public.crear_codigo(p_building uuid, p_unit uuid, p_role text default 'guardia',
                                               p_usos int default 1)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  -- 12 caracteres al azar (48 bits): no se puede adivinar probando.
  v := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6) || '-' ||
             substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into public.activation_codes (code, building_id, unit_id, role, max_uses)
  values (v, p_building, p_unit, coalesce(p_role, 'guardia'), greatest(coalesce(p_usos, 1), 1));
  return v;
end $$;

-- Reemplazo de guardia en UNA operación: desactiva al anterior (conserva su
-- historial) y crea uno NUEVO (id nuevo, horas en cero, sin advertencias).
create or replace function public.reemplazar_guardia(p_guard uuid, p_nombre text, p_documento text,
                                                     p_telefono text, p_inicio date default current_date)
returns json language plpgsql security definer set search_path = public as $$
declare g public.guards; n public.guards;
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  select * into g from public.guards where id = p_guard for update;
  if not found then raise exception 'Guardia no encontrado'; end if;
  if not g.active then raise exception 'Ese guardia ya está inactivo'; end if;
  update public.guards set active = false,
         end_date = greatest(coalesce(p_inicio, current_date), start_date)
   where id = g.id;
  insert into public.guards (building_id, unit_id, full_name, document, phone, shift, role,
                             start_date, replaced_guard_id)
  values (g.building_id, g.unit_id, trim(p_nombre), nullif(trim(p_documento), ''), nullif(trim(p_telefono), ''),
          g.shift, g.role, coalesce(p_inicio, current_date), g.id)
  returning * into n;
  return row_to_json(n);
end $$;

revoke all on function public.activar_dispositivo(text, text, text) from public, anon;
revoke all on function public.crear_codigo(uuid, uuid, text, int) from public, anon;
revoke all on function public.reemplazar_guardia(uuid, text, text, text, date) from public, anon;
grant execute on function public.activar_dispositivo(text, text, text) to authenticated;
grant execute on function public.crear_codigo(uuid, uuid, text, int) to authenticated;
grant execute on function public.reemplazar_guardia(uuid, text, text, text, date) to authenticated;
grant execute on function public.mi_dispositivo() to authenticated;
grant execute on function public.es_admin() to authenticated;
grant execute on function public.mi_edificio() to authenticated;
grant execute on function public.mi_unidad() to authenticated;

-- ---------------------------------------------------------------------
-- 11. RLS de las tablas NUEVAS (activo desde ya)
-- ---------------------------------------------------------------------
alter table public.buildings        enable row level security;
alter table public.units            enable row level security;
alter table public.devices          enable row level security;
alter table public.activation_codes enable row level security;
alter table public.guards           enable row level security;
alter table public.guard_warnings   enable row level security;

drop policy if exists buildings_ver on public.buildings;
create policy buildings_ver on public.buildings for select to authenticated
  using (public.es_admin() or id = public.mi_edificio());
drop policy if exists buildings_admin on public.buildings;
create policy buildings_admin on public.buildings for insert to authenticated
  with check (public.es_admin());
drop policy if exists buildings_editar on public.buildings;
create policy buildings_editar on public.buildings for update to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists units_ver on public.units;
create policy units_ver on public.units for select to authenticated
  using (public.es_admin() or building_id = public.mi_edificio());
drop policy if exists units_admin on public.units;
create policy units_admin on public.units for insert to authenticated
  with check (public.es_admin());
drop policy if exists units_editar on public.units;
create policy units_editar on public.units for update to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists devices_ver on public.devices;
create policy devices_ver on public.devices for select to authenticated
  using (user_id = auth.uid() or public.es_admin());
drop policy if exists devices_editar on public.devices;
create policy devices_editar on public.devices for update to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists codes_admin on public.activation_codes;
create policy codes_admin on public.activation_codes for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- Un celular de guardia SOLO ve los guardias de SU unidad (torre 1 no ve a
-- los de torre 2). El administrador ve todos.
drop policy if exists guards_ver on public.guards;
create policy guards_ver on public.guards for select to authenticated
  using (public.es_admin() or (building_id = public.mi_edificio() and unit_id = public.mi_unidad()));
drop policy if exists guards_admin on public.guards;
create policy guards_admin on public.guards for insert to authenticated
  with check (public.es_admin());
drop policy if exists guards_editar on public.guards;
create policy guards_editar on public.guards for update to authenticated
  using (public.es_admin()) with check (public.es_admin());
-- (sin política de DELETE: los guardias no se borran)

drop policy if exists warnings_ver on public.guard_warnings;
create policy warnings_ver on public.guard_warnings for select to authenticated
  using (public.es_admin() or (building_id = public.mi_edificio()
         and guard_id in (select id from public.guards where unit_id = public.mi_unidad())));
drop policy if exists warnings_crear on public.guard_warnings;
create policy warnings_crear on public.guard_warnings for insert to authenticated
  with check (public.es_admin() or (building_id = public.mi_edificio()
              and guard_id in (select id from public.guards where unit_id = public.mi_unidad() and active)));
drop policy if exists warnings_editar on public.guard_warnings;
create policy warnings_editar on public.guard_warnings for update to authenticated
  using (public.es_admin()) with check (public.es_admin());

grant select, insert, update on public.buildings, public.units, public.guards,
  public.guard_warnings, public.activation_codes to authenticated;
grant select, update on public.devices to authenticated;

-- ---------------------------------------------------------------------
-- 11b. TRANSICIÓN: la app nueva ya envía la sesión del celular (rol
--      "authenticated"). Hasta ejecutar 02, eventos y presencia siguen
--      abiertos como hoy, también para ese rol.
-- ---------------------------------------------------------------------
grant select, insert, update, delete on public.eventos, public.presencia to authenticated;
grant usage, select on all sequences in schema public to authenticated;
do $$ begin
  if (select relrowsecurity from pg_class where oid = 'public.eventos'::regclass)
     and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'eventos'
                     and ('authenticated' = any(roles) or 'public' = any(roles))) then
    create policy eventos_transicion on public.eventos for all to authenticated using (true) with check (true);
  end if;
  if (select relrowsecurity from pg_class where oid = 'public.presencia'::regclass)
     and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'presencia'
                     and ('authenticated' = any(roles) or 'public' = any(roles))) then
    create policy presencia_transicion on public.presencia for all to authenticated using (true) with check (true);
  end if;
end $$;

-- Celulares de la sesión actual (para que cada uno solo toque su presencia).
create or replace function public.mis_dispositivos() returns setof text
language sql stable security definer set search_path = public as $$
  select device_id from public.devices where user_id = auth.uid() and active
$$;
grant execute on function public.mis_dispositivos() to authenticated;

-- ---------------------------------------------------------------------
-- 12. DATOS INICIALES: edificios que ya aparecen en los eventos + una
--     unidad "Principal" en cada uno. (No se crean guardias: cada guardia
--     activo se registra de nuevo desde la app y empieza en cero.)
-- ---------------------------------------------------------------------
insert into public.buildings (code, name)
select distinct trim(edificio), trim(edificio) from public.eventos
where edificio is not null and trim(edificio) not in ('', '*', 'Sin edificio')
on conflict (code) do nothing;

insert into public.units (building_id, name)
select b.id, 'Principal' from public.buildings b
where not exists (select 1 from public.units u where u.building_id = b.id);

commit;

-- ---------------------------------------------------------------------
-- 13. CÓDIGO DEL ADMINISTRADOR (ejecutar APARTE, una vez). Anota el código
--     que devuelve: se ingresa en la app, en Configuración → Vincular
--     celular, en el celular del administrador.
-- ---------------------------------------------------------------------
-- insert into public.activation_codes (code, role, max_uses, expires_at)
-- values (upper('ADM-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)), 'admin', 2,
--         now() + interval '30 days')
-- returning code;
