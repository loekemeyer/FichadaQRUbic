-- ============================================================================
-- Reconocimiento facial — lógica en Postgres.
-- ----------------------------------------------------------------------------
-- El match se hace SERVER-SIDE (pgvector): el kiosco manda SU embedding, el
-- servidor busca el más cercano y devuelve el empleado. Así la base de vectores
-- NUNCA se expone al cliente (privacidad + no se puede robar la galería).
--
-- Reusa FichadaQR:
--   * "FichadaQR".esta_habilitado(correo)  -> whitelist (planify.employees).
--   * "FichadaQR".fichadas UNIQUE(correo,fecha) -> 1 fichada por día (atómico).
--
-- Todas las RPC son SECURITY DEFINER + search_path='' y SOLO las ejecuta el
-- service_role (las Edge Functions). El schema reconocimiento_facial no se
-- expone en PostgREST; por eso las RPC llamables viven en public con el prefijo
-- recon_facial_. El helper interno de match sí vive en el schema.
-- ============================================================================

-- Helper interno: rostro enrolado más cercano al embedding dado (distancia L2).
-- Vive en el schema (no necesita estar en public). Se llama desde las RPC
-- SECURITY DEFINER, así que corre con los privilegios del owner y lee rostros.
create or replace function reconocimiento_facial.match_cercano(p_embedding extensions.vector)
returns table (correo text, distancia real)
language sql stable set search_path = '' as $$
  select r.correo,
         (r.embedding OPERATOR(extensions.<->) p_embedding)::real as distancia
  from reconocimiento_facial.rostros r
  order by r.embedding OPERATOR(extensions.<->) p_embedding
  limit 1
$$;

-- Enrolar un rostro (pantalla de admin). Guarda SOLO el vector. Requiere la
-- clave de dispositivo y que el correo esté habilitado (reusa el resolutor).
create or replace function public.recon_facial_enrolar(
  p_clave     text,
  p_correo    text,
  p_embedding real[],
  p_etiqueta  text default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_correo text := lower(trim(coalesce(p_correo, '')));
  v_clave  text;
  v_vec    extensions.vector;
  v_total  int;
begin
  select clave_dispositivo into v_clave from reconocimiento_facial.config where id = 1;
  if v_clave is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida');
  end if;

  if v_correo = '' or p_embedding is null then
    return json_build_object('error','faltan_datos');
  end if;
  if coalesce(array_length(p_embedding, 1), 0) <> 128 then
    return json_build_object('error','dim_invalida');
  end if;
  if not "FichadaQR".esta_habilitado(v_correo) then
    return json_build_object('error','no_habilitado');
  end if;

  v_vec := p_embedding::extensions.vector;

  insert into reconocimiento_facial.rostros (correo, embedding, etiqueta)
  values (v_correo, v_vec, nullif(trim(coalesce(p_etiqueta, '')), ''));

  select count(*) into v_total
    from reconocimiento_facial.rostros where lower(correo) = v_correo;

  return json_build_object('ok', true, 'correo', v_correo, 'total_rostros', v_total);
end;
$$;

-- Resolver "quién es" por la cara (preview "¿Sos vos, Juan?"). No ficha; solo
-- devuelve el candidato. Match server-side; NO expone la base de vectores.
create or replace function public.recon_facial_resolver(
  p_clave     text,
  p_embedding real[],
  p_umbral    real default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave  text;
  v_umbral real;
  v_vec    extensions.vector;
  v_correo text;
  v_dist   real;
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
  v_umbral := coalesce(p_umbral, v_umbral, 0.55);

  v_vec := p_embedding::extensions.vector;
  select correo, distancia into v_correo, v_dist
    from reconocimiento_facial.match_cercano(v_vec);

  if v_correo is null or v_dist > v_umbral then
    return json_build_object('error','no_match');
  end if;
  if not "FichadaQR".esta_habilitado(v_correo) then
    return json_build_object('error','no_habilitado');
  end if;

  return json_build_object('ok', true, 'correo', v_correo,
    'distancia', round(v_dist::numeric, 4));
end;
$$;

-- Fichar en el kiosco por cara. Flujo completo y seguro:
--   clave dispositivo -> liveness (client-asserted) -> match por embedding
--   -> habilitado -> 1/día -> INSERT en FichadaQR.fichadas.
-- Devuelve {ok, correo, hora} o {error: clave_invalida|liveness|no_match|
-- no_habilitado|ya_ficho|dim_invalida|faltan_datos}.
create or replace function public.recon_facial_fichar(
  p_clave       text,
  p_embedding   real[],
  p_liveness_ok boolean default false,
  p_umbral      real default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_clave        text;
  v_umbral       real;
  v_req_liveness boolean;
  v_vec          extensions.vector;
  v_correo       text;
  v_dist         real;
  v_fecha        date;
  v_hora         text;
  v_ins          bigint;
  v_prev         timestamptz;
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
  v_umbral := coalesce(p_umbral, v_umbral, 0.55);

  -- liveness: el chequeo real (parpadeo/giro) es client-side; acá se exige la
  -- afirmación. Con requiere_liveness=true, sin liveness no se ficha.
  if coalesce(v_req_liveness, true) and coalesce(p_liveness_ok, false) = false then
    return json_build_object('error','liveness');
  end if;

  v_vec := p_embedding::extensions.vector;
  select correo, distancia into v_correo, v_dist
    from reconocimiento_facial.match_cercano(v_vec);

  if v_correo is null or v_dist > v_umbral then
    return json_build_object('error','no_match');
  end if;
  if not "FichadaQR".esta_habilitado(v_correo) then
    return json_build_object('error','no_habilitado');
  end if;

  v_fecha := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_hora  := to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI');

  insert into "FichadaQR".fichadas (correo, fecha)
  values (v_correo, v_fecha)
  on conflict (correo, fecha) do nothing
  returning id into v_ins;

  if v_ins is null then
    select creado_en into v_prev
      from "FichadaQR".fichadas where correo = v_correo and fecha = v_fecha;
    return json_build_object('error','ya_ficho', 'correo', v_correo,
      'hora', to_char(v_prev at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'));
  end if;

  return json_build_object('ok', true, 'correo', v_correo, 'hora', v_hora,
    'distancia', round(v_dist::numeric, 4));
end;
$$;

-- Baja / derecho al olvido (Ley 25.326): borra TODOS los embeddings de un
-- correo (al desvincular a la persona). Admin: solo service_role, sin edge fn.
create or replace function public.recon_facial_baja(p_correo text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_correo text := lower(trim(coalesce(p_correo, '')));
  v_n      int;
begin
  if v_correo = '' then return json_build_object('error','faltan_datos'); end if;
  delete from reconocimiento_facial.rostros where lower(correo) = v_correo;
  get diagnostics v_n = row_count;
  return json_build_object('ok', true, 'correo', v_correo, 'borrados', v_n);
end;
$$;

-- Solo el service_role (las Edge Functions / admin) ejecuta esto.
revoke all on function reconocimiento_facial.match_cercano(extensions.vector) from public;
revoke all on function public.recon_facial_enrolar(text, text, real[], text)     from public;
revoke all on function public.recon_facial_resolver(text, real[], real)          from public;
revoke all on function public.recon_facial_fichar(text, real[], boolean, real)   from public;
revoke all on function public.recon_facial_baja(text)                            from public;

revoke execute on function public.recon_facial_enrolar(text, text, real[], text)   from anon, authenticated;
revoke execute on function public.recon_facial_resolver(text, real[], real)        from anon, authenticated;
revoke execute on function public.recon_facial_fichar(text, real[], boolean, real) from anon, authenticated;
revoke execute on function public.recon_facial_baja(text)                          from anon, authenticated;

grant execute on function public.recon_facial_enrolar(text, text, real[], text)   to service_role;
grant execute on function public.recon_facial_resolver(text, real[], real)        to service_role;
grant execute on function public.recon_facial_fichar(text, real[], boolean, real) to service_role;
grant execute on function public.recon_facial_baja(text)                          to service_role;
