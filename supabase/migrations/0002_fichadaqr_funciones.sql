-- ============================================================================
-- FichadaQR — lógica en Postgres (firma HMAC + validaciones).
-- Las Edge Functions son solo una cáscara HTTP que llama a estas funciones.
-- SECURITY DEFINER + search_path='' ; solo service_role puede ejecutarlas.
-- ============================================================================

-- Helper: base64url de un bytea
create or replace function "FichadaQR".b64url(p bytea)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(translate(encode(p, 'base64'), '+/', '-_'), '[=\n\r]', '', 'g')
$$;

-- Emitir token firmado con vencimiento corto. Requiere la clave de dispositivo.
create or replace function public.fichadaqr_emitir_token(p_clave text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_secret text; v_clave text; v_ttl int;
  v_jti text; v_exp bigint; v_payload text; v_payload_b64 text; v_sig text;
begin
  select token_secret, clave_dispositivo, token_ttl_seg
    into v_secret, v_clave, v_ttl
    from "FichadaQR".config where id = 1;
  if v_secret is null then return json_build_object('error','sin_config'); end if;
  if p_clave is null or p_clave <> v_clave then
    return json_build_object('error','clave_invalida');
  end if;

  v_jti := substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
  v_exp := floor(extract(epoch from now())) + v_ttl;
  v_payload := '{"exp":' || v_exp::text || ',"jti":"' || v_jti || '"}';
  v_payload_b64 := "FichadaQR".b64url(convert_to(v_payload, 'utf8'));
  v_sig := "FichadaQR".b64url(extensions.hmac(v_payload_b64, v_secret, 'sha256'));

  return json_build_object('token', v_payload_b64 || '.' || v_sig, 'exp', v_exp);
end;
$$;

-- Validar token (firma + vencimiento) + correo habilitado + 1/dia, y registrar.
create or replace function public.fichadaqr_fichar(p_token text, p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_secret text; v_payload_b64 text; v_sig text; v_sig_calc text;
  v_payload_json json; v_exp bigint; v_jti text; v_b64std text;
  v_email text := lower(trim(p_email));
  v_activo boolean; v_fecha date; v_hora text; v_ins bigint; v_prev timestamptz;
begin
  if p_token is null or p_token = '' or v_email = '' then
    return json_build_object('error','faltan_datos');
  end if;

  select token_secret into v_secret from "FichadaQR".config where id = 1;
  if v_secret is null then return json_build_object('error','sin_config'); end if;

  v_payload_b64 := split_part(p_token, '.', 1);
  v_sig := split_part(p_token, '.', 2);
  if v_payload_b64 = '' or v_sig = '' or p_token like '%.%.%' then
    return json_build_object('error','token_invalido');
  end if;

  -- firma
  v_sig_calc := "FichadaQR".b64url(extensions.hmac(v_payload_b64, v_secret, 'sha256'));
  if v_sig <> v_sig_calc then return json_build_object('error','token_invalido'); end if;

  -- decodificar payload
  v_b64std := translate(v_payload_b64, '-_', '+/');
  v_b64std := v_b64std || repeat('=', (4 - (length(v_b64std) % 4)) % 4);
  begin
    v_payload_json := convert_from(decode(v_b64std, 'base64'), 'utf8')::json;
  exception when others then
    return json_build_object('error','token_invalido');
  end;
  v_exp := (v_payload_json->>'exp')::bigint;
  v_jti := v_payload_json->>'jti';
  if v_exp is null or v_jti is null then
    return json_build_object('error','token_invalido');
  end if;

  -- vencimiento
  if v_exp < floor(extract(epoch from now())) then
    return json_build_object('error','token_vencido');
  end if;

  -- correo habilitado
  select activo into v_activo from "FichadaQR".empleados where lower(correo) = v_email;
  if v_activo is null or v_activo = false then
    return json_build_object('error','no_habilitado');
  end if;

  v_fecha := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_hora  := to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI');

  insert into "FichadaQR".fichadas (correo, fecha)
  values (v_email, v_fecha)
  on conflict (correo, fecha) do nothing
  returning id into v_ins;

  if v_ins is null then
    select creado_en into v_prev from "FichadaQR".fichadas where correo = v_email and fecha = v_fecha;
    return json_build_object('error','ya_ficho',
      'hora', to_char(v_prev at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'));
  end if;

  insert into "FichadaQR".tokens_usados (jti, correo)
  values (v_jti, v_email) on conflict do nothing;

  return json_build_object('ok', true, 'hora', v_hora);
end;
$$;

-- Solo el service_role (las Edge Functions) puede ejecutar estas funciones.
revoke all on function public.fichadaqr_emitir_token(text) from public;
revoke all on function public.fichadaqr_fichar(text, text) from public;
revoke execute on function public.fichadaqr_emitir_token(text) from anon, authenticated;
revoke execute on function public.fichadaqr_fichar(text, text) from anon, authenticated;
grant execute on function public.fichadaqr_emitir_token(text) to service_role;
grant execute on function public.fichadaqr_fichar(text, text) to service_role;
