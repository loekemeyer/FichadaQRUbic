-- ============================================================================
-- Reconocimiento facial — legajo case-insensitive.
-- En planify.employees los legajos vienen con mayúsculas/minúsculas mezcladas
-- (C5, c8, c19, c91, C122…). Para que enrolar/fichar no dependa de cómo se
-- escriba, el lookup por legajo se hace ignorando mayúsculas.
-- ============================================================================
create or replace function reconocimiento_facial.empleado_por_legajo(p_legajo text)
returns table (nombre text, activo boolean)
language sql stable set search_path = '' as $$
  select e.nombre, e.activo
  from planify.employees e
  where e.legajo is not null and lower(btrim(e.legajo)) = lower(btrim(p_legajo))
  limit 1
$$;
