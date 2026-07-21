-- ============================================================================
-- PASO 1 — CREAR TU "PLANIFY" (la lista de empleados)
-- ----------------------------------------------------------------------------
-- "planify" es simplemente un schema (una carpeta dentro de la base) con una
-- tabla `employees`: la lista de tu gente. El sistema de fichada facial saca de
-- acá el NOMBRE de cada persona a partir de su legajo/ID. Nada más.
--
-- No es una app aparte ni hay que instalar nada: se crea con este SQL.
--
-- Pegá TODO esto en:  Supabase → SQL Editor → New query → Run.
-- (Corré este archivo ANTES que el 2.)
-- ============================================================================

create schema if not exists planify;

-- La lista de empleados. Para la fichada facial alcanza con legajo + nombre.
--   * legajo: cualquier identificador único (un número, un apodo, lo que uses).
--   * activo: false = no puede fichar (lo dejás sin borrar su historial).
--   * email: opcional, por si más adelante querés otros usos.
create table if not exists planify.employees (
  legajo    text not null,
  nombre    text not null,
  email     text,
  activo    boolean not null default true,
  creado_en timestamptz not null default now()
);

-- Legajo único ignorando mayúsculas/espacios ("Juan " y "juan" son el mismo).
create unique index if not exists employees_legajo_ci
  on planify.employees (lower(btrim(legajo)));

-- La lista no se puede leer con la clave pública: solo la usan las funciones de
-- fichada (que exigen la clave de dispositivo).
alter table planify.employees enable row level security;

-- ---------------------------------------------------------------------------
-- (OPCIONAL) Cargar empleados de una vez.
-- No es obligatorio: también se crean solos cuando los enrolás desde la pantalla
-- de Enrolar (escribís legajo + nombre y se agregan acá). Pero si ya tenés la
-- lista, editá/duplicá estas filas y listo:
-- ---------------------------------------------------------------------------
insert into planify.employees (legajo, nombre) values
  ('1', 'Juan Pérez'),
  ('2', 'María Gómez')
  -- ('3', 'Otro Empleado'),
on conflict (lower(btrim(legajo))) do nothing;

-- Ver la lista cargada:
select legajo, nombre, activo from planify.employees order by legajo;
