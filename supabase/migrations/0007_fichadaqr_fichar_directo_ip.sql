-- ============================================================================
-- FichadaQR — fichada por QR ESTÁTICO anclada a la IP del WiFi del trabajo.
-- ----------------------------------------------------------------------------
-- El QR deja de rotar (no vence). La prueba de presencia pasa a ser la IP:
-- la Edge Function lee la IP pública del que ficha (x-forwarded-for) y la pasa
-- acá; solo se acepta si coincide con config.ip_trabajo (lista separada por comas).
-- Sin token. SOLO service_role puede ejecutarla — el cliente no puede falsear la
-- IP porque la determina el servidor.
--
-- Config: cargar la IP pública del WiFi del trabajo en FichadaQR.config.ip_trabajo
--   update "FichadaQR".config set ip_trabajo = '<IP1>[, <IP2>]' where id = 1;
-- Para descubrir la IP: abrir la app en el WiFi del trabajo y hacer
--   POST a la Edge Function fichada-qr-fichar con body {"whoami": true}  -> {ip}
-- ============================================================================
create or replace function public.fichadaqr_fichar_directo(p_email text, p_ip text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_ip    text := trim(coalesce(p_ip, ''));
  v_allow text; v_ok boolean := false; v_item text;
  v_fecha date; v_hora text; v_ins bigint; v_prev timestamptz;
begin
  if v_email = '' then return json_build_object('error', 'faltan_datos'); end if;

  select ip_trabajo into v_allow from "FichadaQR".config where id = 1;
  if v_allow is null or btrim(v_allow) = '' then
    return json_build_object('error', 'ip_no_configurada', 'ip', v_ip);
  end if;

  foreach v_item in array string_to_array(v_allow, ',') loop
    if btrim(v_item) <> '' and btrim(v_item) = v_ip then v_ok := true; exit; end if;
  end loop;
  if not v_ok then
    return json_build_object('error', 'ip_no_permitida', 'ip', v_ip);
  end if;

  if not "FichadaQR".esta_habilitado(v_email) then
    return json_build_object('error', 'no_habilitado');
  end if;

  v_fecha := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_hora  := to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI');

  insert into "FichadaQR".fichadas (correo, fecha)
  values (v_email, v_fecha)
  on conflict (correo, fecha) do nothing
  returning id into v_ins;

  if v_ins is null then
    select creado_en into v_prev from "FichadaQR".fichadas where correo = v_email and fecha = v_fecha;
    return json_build_object('error', 'ya_ficho',
      'hora', to_char(v_prev at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'));
  end if;

  return json_build_object('ok', true, 'hora', v_hora);
end;
$$;

revoke all on function public.fichadaqr_fichar_directo(text, text) from public;
revoke execute on function public.fichadaqr_fichar_directo(text, text) from anon, authenticated;
grant execute on function public.fichadaqr_fichar_directo(text, text) to service_role;
