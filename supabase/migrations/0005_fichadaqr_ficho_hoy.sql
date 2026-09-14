-- ============================================================================
-- FichadaQR — consulta "¿esta persona ya fichó HOY?" para el gate de ingreso de
-- las apps de producción (Producción Virgilio / Cervantes).
-- ----------------------------------------------------------------------------
-- El schema FichadaQR NO está expuesto a PostgREST; esta función SECURITY
-- DEFINER es la única puerta de SOLO-LECTURA que puede usar la anon key. Revela
-- lo mínimo: para un correo dado, si fichó hoy y a qué hora. No lista correos,
-- no permite escribir. La fichada real sigue pasando por la Edge Function
-- fichada-qr-fichar (service_role); esta RPC solo evita que el operario tenga
-- que re-escanear si ya fichó.
-- ============================================================================
create or replace function public.fichadaqr_ficho_hoy(p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(trim(p_email));
  v_fecha date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_prev timestamptz;
begin
  if v_email = '' then
    return json_build_object('ficho', false, 'hora', null);
  end if;

  select creado_en into v_prev
    from "FichadaQR".fichadas
   where lower(correo) = v_email and fecha = v_fecha
   limit 1;

  if v_prev is null then
    return json_build_object('ficho', false, 'hora', null);
  end if;

  return json_build_object(
    'ficho', true,
    'hora', to_char(v_prev at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI')
  );
end;
$$;

-- La anon key (apps de producción) puede consultar; nadie puede escribir por acá.
revoke all on function public.fichadaqr_ficho_hoy(text) from public;
grant execute on function public.fichadaqr_ficho_hoy(text) to anon, authenticated, service_role;
