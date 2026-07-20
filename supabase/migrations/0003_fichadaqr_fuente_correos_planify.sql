-- ============================================================================
-- FichadaQR — fuente de correos habilitados configurable.
-- Por defecto lee de planify.empleados (columna autodetectada entre
-- Email/gmail/correo/mail). Mientras esa tabla no exista, usa como respaldo la
-- lista propia FichadaQR.empleados. La fuente se cambia en FichadaQR.config sin
-- tocar el código.
-- ============================================================================
alter table "FichadaQR".config
  add column if not exists fuente_schema  text default 'planify',
  add column if not exists fuente_tabla   text default 'empleados',
  add column if not exists fuente_columna text;  -- null = autodetectar

update "FichadaQR".config
   set fuente_schema = coalesce(fuente_schema,'planify'),
       fuente_tabla  = coalesce(fuente_tabla,'empleados')
 where id = 1;

-- Resolutor: true si el correo esta habilitado segun la fuente vigente.
create or replace function "FichadaQR".esta_habilitado(p_email text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(trim(p_email));
  v_schema text; v_tabla text; v_col text; v_reg regclass; v_found boolean;
begin
  select fuente_schema, fuente_tabla, fuente_columna
    into v_schema, v_tabla, v_col
    from "FichadaQR".config where id = 1;

  -- 1) fuente externa (ej. planify.empleados) si existe
  if v_schema is not null and v_tabla is not null then
    v_reg := to_regclass(format('%I.%I', v_schema, v_tabla));
    if v_reg is not null then
      if v_col is null then
        select column_name into v_col
        from information_schema.columns
        where table_schema = v_schema and table_name = v_tabla
          and lower(column_name) in ('email','gmail','correo','mail')
        order by array_position(array['email','gmail','correo','mail'], lower(column_name))
        limit 1;
      end if;
      if v_col is not null then
        execute format('select exists(select 1 from %I.%I where lower(%I::text) = $1)',
                       v_schema, v_tabla, v_col)
          into v_found using v_email;
        return coalesce(v_found, false);
      end if;
    end if;
  end if;

  -- 2) respaldo: lista propia FichadaQR.empleados
  return exists(select 1 from "FichadaQR".empleados
                where lower(correo) = v_email and activo is not false);
end;
$$;

revoke all on function "FichadaQR".esta_habilitado(text) from public;

-- fichar: usar el resolutor en vez de la consulta directa a empleados.
-- (cuerpo identico a 0002 salvo el chequeo de habilitado)
create or replace function public.fichadaqr_fichar(p_token text, p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_secret text; v_payload_b64 text; v_sig text; v_sig_calc text;
  v_payload_json json; v_exp bigint; v_jti text; v_b64std text;
  v_email text := lower(trim(p_email));
  v_fecha date; v_hora text; v_ins bigint; v_prev timestamptz;
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

  v_sig_calc := "FichadaQR".b64url(extensions.hmac(v_payload_b64, v_secret, 'sha256'));
  if v_sig <> v_sig_calc then return json_build_object('error','token_invalido'); end if;

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

  if v_exp < floor(extract(epoch from now())) then
    return json_build_object('error','token_vencido');
  end if;

  -- correo habilitado (fuente configurable: planify.empleados o respaldo propio)
  if not "FichadaQR".esta_habilitado(v_email) then
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

revoke all on function public.fichadaqr_fichar(text, text) from public;
revoke execute on function public.fichadaqr_fichar(text, text) from anon, authenticated;
grant execute on function public.fichadaqr_fichar(text, text) to service_role;
