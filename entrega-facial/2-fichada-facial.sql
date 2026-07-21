-- ============================================================================
-- PASO 2 — FICHADA FACIAL (el motor de reconocimiento)
-- ----------------------------------------------------------------------------
-- Corré esto DESPUÉS del archivo 1 (necesita que exista planify.employees).
-- Pegá TODO esto en:  Supabase → SQL Editor → New query → Run.
--
-- Qué hace:
--   * Guarda SOLO el vector matemático de cada cara (128 números), NUNCA la foto.
--   * El reconocimiento (match) se hace en el servidor: la base de caras nunca
--     sale de Supabase.
--   * Toma el nombre de cada persona desde planify.employees (archivo 1).
--   * Todo protegido por una CLAVE DE DISPOSITIVO que se genera sola acá abajo.
--
-- Es seguro correrlo más de una vez (no borra datos ni duplica nada).
-- ============================================================================

-- Schema propio y aislado para lo del facial (no toca planify ni nada más).
create schema if not exists reconocimiento_facial;

-- pgvector: permite comparar caras por distancia dentro de la base.
create extension if not exists vector with schema extensions;

-- Rostros: N vectores por empleado (varias fotos = reconocimiento más robusto).
create table if not exists reconocimiento_facial.rostros (
  id        bigint generated always as identity primary key,
  legajo    text not null,
  embedding extensions.vector(128) not null,
  etiqueta  text,
  creado_en timestamptz not null default now()
);
create index if not exists rostros_legajo_idx
  on reconocimiento_facial.rostros (lower(btrim(legajo)));
create index if not exists rostros_embedding_l2_idx
  on reconocimiento_facial.rostros using hnsw (embedding extensions.vector_l2_ops);

-- Fichadas: 1 por día por persona (a prueba de dobles). Guarda el nombre para
-- que el reporte se lea solo.
create table if not exists reconocimiento_facial.fichadas (
  id        bigint generated always as identity primary key,
  legajo    text not null,
  nombre    text,
  fecha     date not null,
  creado_en timestamptz not null default now(),
  unique (legajo, fecha)
);

-- Config del kiosco: clave de dispositivo (se genera sola), umbral de match y si
-- exige "prueba de vida" (parpadeo) para no fichar con una foto.
create table if not exists reconocimiento_facial.config (
  id                integer primary key default 1,
  clave_dispositivo text not null,
  umbral_distancia  real not null default 0.55,   -- menor = más estricto
  requiere_liveness boolean not null default true, -- true = pide parpadear
  actualizado_en    timestamptz not null default now(),
  constraint reconfacial_config_fila_unica check (id = 1)
);
insert into reconocimiento_facial.config (id, clave_dispositivo)
values (1, substr(replace(gen_random_uuid()::text, '-', ''), 1, 20))
on conflict (id) do nothing;

alter table reconocimiento_facial.rostros   enable row level security;
alter table reconocimiento_facial.fichadas  enable row level security;
alter table reconocimiento_facial.config    enable row level security;

-- ===========================================================================
-- LÓGICA. Cada función exige la clave de dispositivo antes de hacer nada.
-- ===========================================================================

-- Datos del empleado por legajo -> los toma de TU planify (archivo 1).
create or replace function reconocimiento_facial.empleado_por_legajo(p_legajo text)
returns table (nombre text, activo boolean)
language sql stable set search_path = '' as $$
  select e.nombre, e.activo
  from planify.employees e
  where lower(btrim(e.legajo)) = lower(btrim(p_legajo))
  limit 1
$$;

-- Rostro enrolado más cercano a un vector dado (distancia L2).
create or replace function reconocimiento_facial.match_cercano(p_embedding extensions.vector)
returns table (legajo text, distancia real)
language sql stable set search_path = '' as $$
  select r.legajo,
         (r.embedding OPERATOR(extensions.<->) p_embedding)::real as distancia
  from reconocimiento_facial.rostros r
  order by r.embedding OPERATOR(extensions.<->) p_embedding
  limit 1
$$;

-- Buscar nombre por legajo (feedback al escribir en la pantalla de enrolar).
create or replace function public.recon_facial_nombre(p_clave text, p_legajo text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave  text;
  v_legajo text := btrim(coalesce(p_legajo, ''));
  v_nombre text; v_activo boolean;
begin
  select clave_dispositivo into v_clave from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida'); end if;
  if v_legajo = '' then return json_build_object('error','faltan_datos'); end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null then return json_build_object('error','no_existe'); end if;

  return json_build_object('ok', true, 'legajo', v_legajo,
    'nombre', v_nombre, 'activo', coalesce(v_activo, true));
end;
$$;

-- Enrolar un rostro. Si el legajo no existe en planify, lo crea con el nombre
-- que se pasa (así podés registrar empleados desde la pantalla, sin cargar SQL).
create or replace function public.recon_facial_enrolar(
  p_clave     text,
  p_legajo    text,
  p_nombre    text,
  p_embedding real[],
  p_etiqueta  text default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave   text;
  v_legajo  text := btrim(coalesce(p_legajo, ''));
  v_nombre  text := btrim(coalesce(p_nombre, ''));
  v_exist   text; v_vec extensions.vector; v_total int;
begin
  select clave_dispositivo into v_clave from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida'); end if;
  if v_legajo = '' or p_embedding is null then
    return json_build_object('error','faltan_datos'); end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida'); end if;

  select nombre into v_exist
    from reconocimiento_facial.empleado_por_legajo(v_legajo);

  if v_exist is null then
    -- empleado nuevo: se agrega a planify (hace falta el nombre)
    if v_nombre = '' then return json_build_object('error','falta_nombre'); end if;
    insert into planify.employees (legajo, nombre, activo)
    values (v_legajo, v_nombre, true)
    on conflict (lower(btrim(legajo)))
      do update set nombre = excluded.nombre, activo = true;
  else
    -- existente: si mandaron un nombre distinto, lo actualiza en planify
    if v_nombre <> '' and v_nombre <> v_exist then
      update planify.employees
         set nombre = v_nombre
       where lower(btrim(legajo)) = lower(btrim(v_legajo));
    else
      v_nombre := v_exist;
    end if;
  end if;

  v_vec := p_embedding::extensions.vector;
  insert into reconocimiento_facial.rostros (legajo, embedding, etiqueta)
  values (v_legajo, v_vec, nullif(btrim(coalesce(p_etiqueta, '')), ''));

  select count(*) into v_total
    from reconocimiento_facial.rostros
   where lower(btrim(legajo)) = lower(btrim(v_legajo));

  return json_build_object('ok', true, 'legajo', v_legajo,
    'nombre', v_nombre, 'total_rostros', v_total);
end;
$$;

-- Resolver quién es por la cara (preview "¿Sos vos?", sin fichar).
create or replace function public.recon_facial_resolver(
  p_clave     text,
  p_embedding real[],
  p_umbral    real default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave text; v_umbral real; v_vec extensions.vector;
  v_legajo text; v_dist real; v_nombre text; v_activo boolean;
begin
  select clave_dispositivo, umbral_distancia into v_clave, v_umbral
    from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida'); end if;
  if p_embedding is null then return json_build_object('error','faltan_datos'); end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida'); end if;
  -- El cliente solo puede endurecer el umbral, nunca aflojarlo (techo = config).
  v_umbral := least(coalesce(p_umbral, v_umbral, 0.55), coalesce(v_umbral, 0.55));

  v_vec := p_embedding::extensions.vector;
  select legajo, distancia into v_legajo, v_dist
    from reconocimiento_facial.match_cercano(v_vec);
  if v_legajo is null or v_dist > v_umbral then
    return json_build_object('error','no_match'); end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null or v_activo is false then
    return json_build_object('error','no_habilitado'); end if;

  return json_build_object('ok', true, 'legajo', v_legajo, 'nombre', v_nombre,
    'distancia', round(v_dist::numeric, 4));
end;
$$;

-- Fichar por cara: clave -> parpadeo -> match -> 1/día -> registra.
create or replace function public.recon_facial_fichar(
  p_clave       text,
  p_embedding   real[],
  p_liveness_ok boolean default false,
  p_umbral      real default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave text; v_umbral real; v_req_liveness boolean; v_vec extensions.vector;
  v_legajo text; v_dist real; v_nombre text; v_activo boolean;
  v_fecha date; v_hora text; v_ins bigint; v_prev timestamptz;
begin
  select clave_dispositivo, umbral_distancia, requiere_liveness
    into v_clave, v_umbral, v_req_liveness
    from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida'); end if;
  if p_embedding is null then return json_build_object('error','faltan_datos'); end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida'); end if;
  v_umbral := least(coalesce(p_umbral, v_umbral, 0.55), coalesce(v_umbral, 0.55));

  if coalesce(v_req_liveness, true) and coalesce(p_liveness_ok, false) = false then
    return json_build_object('error','liveness'); end if;

  v_vec := p_embedding::extensions.vector;
  select legajo, distancia into v_legajo, v_dist
    from reconocimiento_facial.match_cercano(v_vec);
  if v_legajo is null or v_dist > v_umbral then
    return json_build_object('error','no_match'); end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null or v_activo is false then
    return json_build_object('error','no_habilitado'); end if;

  -- Zona horaria Argentina; cambiala si hace falta.
  v_fecha := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_hora  := to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI');

  insert into reconocimiento_facial.fichadas (legajo, nombre, fecha)
  values (v_legajo, v_nombre, v_fecha)
  on conflict (legajo, fecha) do nothing
  returning id into v_ins;

  if v_ins is null then
    select creado_en into v_prev
      from reconocimiento_facial.fichadas where legajo = v_legajo and fecha = v_fecha;
    return json_build_object('error','ya_ficho', 'legajo', v_legajo, 'nombre', v_nombre,
      'hora', to_char(v_prev at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'));
  end if;

  return json_build_object('ok', true, 'legajo', v_legajo, 'nombre', v_nombre,
    'hora', v_hora, 'distancia', round(v_dist::numeric, 4));
end;
$$;

-- Borrar todos los rostros de un legajo (derecho al olvido / dar de baja).
-- Se corre a mano desde el SQL Editor:  select public.recon_facial_baja('1');
create or replace function public.recon_facial_baja(p_legajo text)
returns json language plpgsql security definer set search_path = '' as $$
declare v_legajo text := btrim(coalesce(p_legajo, '')); v_n int;
begin
  if v_legajo = '' then return json_build_object('error','faltan_datos'); end if;
  delete from reconocimiento_facial.rostros
   where lower(btrim(legajo)) = lower(btrim(v_legajo));
  get diagnostics v_n = row_count;
  return json_build_object('ok', true, 'legajo', v_legajo, 'borrados', v_n);
end;
$$;

-- ===========================================================================
-- PERMISOS
-- La clave pública (anon) solo puede LLAMAR estas 4 funciones — y cada una pide
-- la clave de dispositivo. NO puede leer las tablas ni la lista directamente.
-- ===========================================================================
revoke all on function reconocimiento_facial.match_cercano(extensions.vector)  from public;
revoke all on function reconocimiento_facial.empleado_por_legajo(text)         from public;

grant execute on function public.recon_facial_nombre(text, text)                    to anon, authenticated;
grant execute on function public.recon_facial_enrolar(text, text, text, real[], text) to anon, authenticated;
grant execute on function public.recon_facial_resolver(text, real[], real)          to anon, authenticated;
grant execute on function public.recon_facial_fichar(text, real[], boolean, real)   to anon, authenticated;

revoke all on function public.recon_facial_baja(text) from public, anon, authenticated;

-- ===========================================================================
-- LISTO. Corré esto para ver TU clave de dispositivo (la vas a necesitar):
-- ===========================================================================
select clave_dispositivo as tu_clave_de_dispositivo
from reconocimiento_facial.config where id = 1;
