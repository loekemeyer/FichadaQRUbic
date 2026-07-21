-- ============================================================================
-- Reconocimiento facial — pasar de CORREO a LEGAJO como identificador.
-- ----------------------------------------------------------------------------
-- En planify.employees el email no está cargado para todos, pero el LEGAJO sí
-- (43/44, todos únicos). Así que el sistema facial identifica por legajo:
--   * `rostros` guarda legajo en vez de correo.
--   * las fichadas faciales van a SU PROPIA tabla `reconocimiento_facial.fichadas`
--     (legajo, nombre, fecha) — independiente del QR (que sigue por correo).
--   * al enrolar/fichar se resuelve el NOMBRE desde planify.employees por legajo,
--     y se muestra ("¿Sos vos, Pérez Juan?").
--
-- QR intacto: fichadaqr_* y "FichadaQR".fichadas no se tocan.
-- ============================================================================

-- 1) rostros: correo -> legajo (la tabla está vacía, es seguro).
alter table reconocimiento_facial.rostros rename column correo to legajo;
drop index if exists reconocimiento_facial.rostros_correo_idx;
create index if not exists rostros_legajo_idx on reconocimiento_facial.rostros (legajo);

-- 2) Fichadas faciales: propias, por legajo. UNIQUE(legajo,fecha) => 1/día atómico.
--    Se guarda el nombre desnormalizado para reportes simples.
create table if not exists reconocimiento_facial.fichadas (
  id        bigint generated always as identity primary key,
  legajo    text not null,
  nombre    text,
  fecha     date not null,
  creado_en timestamptz not null default now(),
  unique (legajo, fecha)
);
alter table reconocimiento_facial.fichadas enable row level security;

-- 3) Helper: datos del empleado por legajo (desde planify.employees).
--    Devuelve nombre + activo, o ninguna fila si el legajo no existe.
create or replace function reconocimiento_facial.empleado_por_legajo(p_legajo text)
returns table (nombre text, activo boolean)
language sql stable set search_path = '' as $$
  select e.nombre, e.activo
  from planify.employees e
  where e.legajo is not null and btrim(e.legajo) = btrim(p_legajo)
  limit 1
$$;

-- 4) Reemplazar funciones que cambian de correo->legajo. Se DROPEA porque cambian
--    nombres de parámetros / columnas de retorno (CREATE OR REPLACE no lo permite).
drop function if exists reconocimiento_facial.match_cercano(extensions.vector);
drop function if exists public.recon_facial_enrolar(text, text, real[], text);
drop function if exists public.recon_facial_resolver(text, real[], real);
drop function if exists public.recon_facial_fichar(text, real[], boolean, real);
drop function if exists public.recon_facial_baja(text);

-- Helper de match: rostro enrolado más cercano (distancia L2) -> legajo.
create function reconocimiento_facial.match_cercano(p_embedding extensions.vector)
returns table (legajo text, distancia real)
language sql stable set search_path = '' as $$
  select r.legajo,
         (r.embedding OPERATOR(extensions.<->) p_embedding)::real as distancia
  from reconocimiento_facial.rostros r
  order by r.embedding OPERATOR(extensions.<->) p_embedding
  limit 1
$$;

-- Buscar nombre por legajo (para mostrar en la pantalla de enrolar mientras se
-- escribe el legajo). {ok, legajo, nombre, activo} o {error: no_existe|...}.
create function public.recon_facial_nombre(p_clave text, p_legajo text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave  text;
  v_legajo text := btrim(coalesce(p_legajo, ''));
  v_nombre text; v_activo boolean;
begin
  select clave_dispositivo into v_clave from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida');
  end if;
  if v_legajo = '' then return json_build_object('error','faltan_datos'); end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null then return json_build_object('error','no_existe'); end if;

  return json_build_object('ok', true, 'legajo', v_legajo,
    'nombre', v_nombre, 'activo', coalesce(v_activo, true));
end;
$$;

-- Enrolar un rostro por LEGAJO. Valida clave + que el legajo exista y esté activo.
create function public.recon_facial_enrolar(
  p_clave     text,
  p_legajo    text,
  p_embedding real[],
  p_etiqueta  text default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave  text;
  v_legajo text := btrim(coalesce(p_legajo, ''));
  v_nombre text; v_activo boolean; v_vec extensions.vector; v_total int;
begin
  select clave_dispositivo into v_clave from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida');
  end if;
  if v_legajo = '' or p_embedding is null then
    return json_build_object('error','faltan_datos');
  end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida');
  end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null then return json_build_object('error','no_existe'); end if;
  if v_activo is false then return json_build_object('error','inactivo'); end if;

  v_vec := p_embedding::extensions.vector;
  insert into reconocimiento_facial.rostros (legajo, embedding, etiqueta)
  values (v_legajo, v_vec, nullif(btrim(coalesce(p_etiqueta, '')), ''));

  select count(*) into v_total from reconocimiento_facial.rostros where legajo = v_legajo;
  return json_build_object('ok', true, 'legajo', v_legajo,
    'nombre', v_nombre, 'total_rostros', v_total);
end;
$$;

-- Resolver quién es por la cara (preview). Devuelve legajo + nombre.
create function public.recon_facial_resolver(
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
    return json_build_object('error','clave_invalida');
  end if;
  if p_embedding is null then return json_build_object('error','faltan_datos'); end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida');
  end if;
  -- El cliente solo puede ENDURECER el umbral, nunca aflojarlo (techo = config).
  v_umbral := least(coalesce(p_umbral, v_umbral, 0.55), coalesce(v_umbral, 0.55));

  v_vec := p_embedding::extensions.vector;
  select legajo, distancia into v_legajo, v_dist
    from reconocimiento_facial.match_cercano(v_vec);
  if v_legajo is null or v_dist > v_umbral then
    return json_build_object('error','no_match');
  end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null or v_activo is false then
    return json_build_object('error','no_habilitado');
  end if;

  return json_build_object('ok', true, 'legajo', v_legajo, 'nombre', v_nombre,
    'distancia', round(v_dist::numeric, 4));
end;
$$;

-- Fichar por cara. clave -> liveness -> match -> legajo activo -> 1/día ->
-- INSERT en reconocimiento_facial.fichadas. Devuelve legajo + nombre + hora.
create function public.recon_facial_fichar(
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
    return json_build_object('error','clave_invalida');
  end if;
  if p_embedding is null then return json_build_object('error','faltan_datos'); end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida');
  end if;
  v_umbral := least(coalesce(p_umbral, v_umbral, 0.55), coalesce(v_umbral, 0.55));

  if coalesce(v_req_liveness, true) and coalesce(p_liveness_ok, false) = false then
    return json_build_object('error','liveness');
  end if;

  v_vec := p_embedding::extensions.vector;
  select legajo, distancia into v_legajo, v_dist
    from reconocimiento_facial.match_cercano(v_vec);
  if v_legajo is null or v_dist > v_umbral then
    return json_build_object('error','no_match');
  end if;

  select nombre, activo into v_nombre, v_activo
    from reconocimiento_facial.empleado_por_legajo(v_legajo);
  if v_nombre is null or v_activo is false then
    return json_build_object('error','no_habilitado');
  end if;

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

-- Baja / olvido por legajo.
create function public.recon_facial_baja(p_legajo text)
returns json language plpgsql security definer set search_path = '' as $$
declare v_legajo text := btrim(coalesce(p_legajo, '')); v_n int;
begin
  if v_legajo = '' then return json_build_object('error','faltan_datos'); end if;
  delete from reconocimiento_facial.rostros where legajo = v_legajo;
  get diagnostics v_n = row_count;
  return json_build_object('ok', true, 'legajo', v_legajo, 'borrados', v_n);
end;
$$;

-- 5) Grants: solo service_role ejecuta las RPC.
revoke all on function reconocimiento_facial.match_cercano(extensions.vector)      from public;
revoke all on function reconocimiento_facial.empleado_por_legajo(text)             from public;
revoke all on function public.recon_facial_nombre(text, text)                      from public;
revoke all on function public.recon_facial_enrolar(text, text, real[], text)       from public;
revoke all on function public.recon_facial_resolver(text, real[], real)            from public;
revoke all on function public.recon_facial_fichar(text, real[], boolean, real)     from public;
revoke all on function public.recon_facial_baja(text)                              from public;

revoke execute on function public.recon_facial_nombre(text, text)                    from anon, authenticated;
revoke execute on function public.recon_facial_enrolar(text, text, real[], text)     from anon, authenticated;
revoke execute on function public.recon_facial_resolver(text, real[], real)          from anon, authenticated;
revoke execute on function public.recon_facial_fichar(text, real[], boolean, real)   from anon, authenticated;
revoke execute on function public.recon_facial_baja(text)                            from anon, authenticated;

grant execute on function public.recon_facial_nombre(text, text)                    to service_role;
grant execute on function public.recon_facial_enrolar(text, text, real[], text)     to service_role;
grant execute on function public.recon_facial_resolver(text, real[], real)          to service_role;
grant execute on function public.recon_facial_fichar(text, real[], boolean, real)   to service_role;
grant execute on function public.recon_facial_baja(text)                            to service_role;
