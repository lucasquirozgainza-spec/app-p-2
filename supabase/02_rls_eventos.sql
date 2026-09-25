-- =====================================================================
-- OSIRIS · 02_rls_eventos.sql  (ejecutar AL FINAL)
--
-- Cierra `eventos` y `presencia` para que cada celular SOLO lea y escriba
-- su edificio, y solo el administrador pueda borrar.
--
-- ⚠️ Ejecutar ÚNICAMENTE cuando TODOS los celulares tengan la versión 12 y
--    estén vinculados con su código (Configuración → Vincular celular).
--    Un celular con la versión anterior dejará de sincronizar desde ese
--    momento (seguirá guardando en el propio celular).
--
-- No borra datos. Los eventos antiguos (sin building_id) quedan visibles
-- solo para el administrador, como archivo histórico.
-- =====================================================================

begin;

-- Quitar las políticas anteriores (acceso abierto con la clave pública).
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('eventos', 'presencia') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

alter table public.eventos   enable row level security;
alter table public.presencia enable row level security;

-- Completar el edificio en filas que lo necesitan para seguir visibles:
-- la configuración publicada y la presencia de cada celular vinculado.
update public.eventos e set building_id = b.id from public.buildings b
 where e.tipo = 'Config' and e.building_id is null and trim(e.edificio) = b.code;
update public.presencia p set building_id = d.building_id, unit_id = d.unit_id
  from public.devices d where d.device_id = p.device_id and d.role = 'guardia';

-- EVENTOS
create policy eventos_ver on public.eventos for select to authenticated
  using (public.es_admin() or building_id = public.mi_edificio()
         or (tipo = 'AdminPass' and building_id is null));   -- contraseña de admin (global)
create policy eventos_crear on public.eventos for insert to authenticated
  with check (public.es_admin() or building_id = public.mi_edificio());
create policy eventos_borrar on public.eventos for delete to authenticated
  using (public.es_admin());
-- (sin UPDATE: los registros no se modifican; las correcciones son eventos nuevos)

-- PRESENCIA
create policy presencia_ver on public.presencia for select to authenticated
  using (public.es_admin() or building_id = public.mi_edificio()
         or device_id in (select public.mis_dispositivos()));
create policy presencia_crear on public.presencia for insert to authenticated
  with check (public.es_admin() or building_id = public.mi_edificio());
-- Cada celular solo actualiza SU fila (aunque lo hayan cambiado de edificio).
create policy presencia_editar on public.presencia for update to authenticated
  using (public.es_admin() or device_id in (select public.mis_dispositivos()))
  with check (public.es_admin() or building_id = public.mi_edificio());

-- Sin sesión (clave pública sola) ya no se puede leer ni escribir.
revoke all on public.eventos, public.presencia from anon;
grant select, insert, update, delete on public.eventos, public.presencia to authenticated;
grant usage, select on all sequences in schema public to authenticated;

commit;

-- Para volver atrás (solo si algo sale mal):
--   alter table public.eventos disable row level security;
--   alter table public.presencia disable row level security;
--   grant select, insert, update, delete on public.eventos, public.presencia to anon;
