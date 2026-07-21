-- ============================================================================
-- FichadaQR — el gate de ingreso puede consultar por CORREO y/o por LEGAJO.
-- ----------------------------------------------------------------------------
-- fichadas guarda el correo, pero el operario suele entrar sólo con el legajo.
-- Resolvemos el legajo tipeado contra planify.employees (la MISMA lista contra
-- la que se valida la fichada) para obtener el correo real habilitado, y lo
-- devolvemos para que la app fiche con él. Si no hay legajo o no resuelve, se
-- usa el correo que vino. Overload de 1 arg (email) se mantiene por compat.
-- ============================================================================
create or replace function public.fichadaqr_ficho_hoy(p_email text, p_legajo text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_leg   text := trim(coalesce(p_legajo, ''));
  v_fecha date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_prev  timestamptz;
  v_res   text;
begin
  -- Preferir resolver por el LEGAJO tipeado contra planify.employees.
  if v_leg <> '' then
    select lower(trim(email)) into v_res
      from planify.employees
     where legajo::text = v_leg and email is not null and email <> ''
     order by (activo is not false) desc
     limit 1;
    if v_res is not null and v_res <> '' then v_email := v_res; end if;
  end if;

  if v_email = '' then
    return json_build_object('ficho', false, 'hora', null, 'correo', null);
  end if;

  select creado_en into v_prev
    from "FichadaQR".fichadas
   where lower(correo) = v_email and fecha = v_fecha
   limit 1;

  return json_build_object(
    'ficho',  v_prev is not null,
    'hora',   case when v_prev is not null
                then to_char(v_prev at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI')
                else null end,
    'correo', v_email
  );
end;
$$;

-- 1-arg (compat con la migración 0005): delega al de 2-args sin legajo.
create or replace function public.fichadaqr_ficho_hoy(p_email text)
returns json language sql security definer set search_path = '' as $$
  select public.fichadaqr_ficho_hoy(p_email, null::text);
$$;

revoke all on function public.fichadaqr_ficho_hoy(text, text) from public;
grant execute on function public.fichadaqr_ficho_hoy(text, text) to anon, authenticated, service_role;
revoke all on function public.fichadaqr_ficho_hoy(text) from public;
grant execute on function public.fichadaqr_ficho_hoy(text) to anon, authenticated, service_role;
