-- =====================================================================
-- OSIRIS · 00_diagnostico.sql  (SOLO LECTURA: no modifica nada)
-- Ejecutar en Supabase → SQL Editor ANTES de la migración y guardar los
-- resultados. Sirven para saber qué datos están mezclados o son ambiguos.
-- =====================================================================

-- 1. Tablas existentes
select table_name from information_schema.tables
where table_schema = 'public' order by 1;

-- 2. Columnas de eventos y presencia
select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name in ('eventos', 'presencia')
order by table_name, ordinal_position;

-- 3. ¿RLS activo? y políticas existentes
select tablename, rowsecurity from pg_tables where schemaname = 'public';
select tablename, policyname, roles, cmd, qual, with_check from pg_policies where schemaname = 'public';

-- 4. Edificios que aparecen en los eventos (con cantidad)
select coalesce(edificio, '(vacío)') as edificio, count(*) as eventos,
       min(created_at) as desde, max(created_at) as hasta
from eventos group by 1 order by 2 desc;

-- 5. Guardias por edificio según ingresos/salidas (identificados solo por NOMBRE)
select edificio, guardia, count(*) filter (where tipo = 'Ingreso de turno') as ingresos,
       count(*) filter (where tipo = 'Salida de turno') as salidas,
       count(distinct device_id) as celulares, min(created_at) as primero, max(created_at) as ultimo
from eventos where tipo in ('Ingreso de turno', 'Salida de turno')
group by 1, 2 order by 1, 2;

-- 6. El MISMO nombre de guardia en más de un edificio (datos que podrían mezclarse)
select guardia, array_agg(distinct edificio) as edificios
from eventos where tipo in ('Ingreso de turno', 'Salida de turno', 'Guardia')
group by guardia having count(distinct edificio) > 1;

-- 7. Registros ambiguos (sin edificio, o con el id genérico de celular "device")
select tipo, count(*) as cantidad,
       count(*) filter (where edificio is null or edificio in ('', 'Sin edificio')) as sin_edificio,
       count(*) filter (where device_id = 'device' or device_id is null) as sin_celular_real
from eventos
where edificio is null or edificio in ('', 'Sin edificio') or device_id = 'device' or device_id is null
group by tipo order by 2 desc;

-- 8. Celulares por edificio (cuántos dispositivos distintos escribieron)
select edificio, device_id, count(*) as eventos, max(created_at) as ultimo,
       max(detalle->>'bloque') as bloque
from eventos group by 1, 2 order by 1, 4 desc;

-- 9. Altas y bajas de guardias (el historial de "eliminados")
select edificio, tipo, detalle->>'nombre' as nombre, created_at
from eventos where tipo in ('Guardia', 'GuardiaBaja') order by edificio, created_at;

-- 10. uid repetidos (un mismo evento subido dos veces)
select detalle->>'uid' as uid, count(*) from eventos
where detalle ? 'uid' group by 1 having count(*) > 1;
