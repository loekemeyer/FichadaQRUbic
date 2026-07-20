-- ============================================================================
-- FichadaQR — la fuente real es planify.employees (en inglés) y trae una columna
-- `activo`. El resolutor:
--   - autodetecta la columna de correo (Email/gmail/correo/mail),
--   - si hay columna de activo (activo/active/habilitado/enabled), filtra por ella
--     (solo correos activos),
--   - si planify.employees todavía no tiene columna de correo, usa el respaldo
--     FichadaQR.empleados.
-- ============================================================================

-- fuente vigente: planify.employees
alter table "FichadaQR".config alter column fuente_tabla set default 'employees';
update "FichadaQR".config
   set fuente_schema='planify', fuente_tabla='employees', fuente_columna=null
 where id = 1;

create or replace function "FichadaQR".esta_habilitado(p_email text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(trim(p_email));
  v_schema text; v_tabla text; v_col text; v_activo_col text; v_reg regclass;
  v_found boolean; v_sql text;
begin
  select fuente_schema, fuente_tabla, fuente_columna
    into v_schema, v_tabla, v_col
    from "FichadaQR".config where id = 1;

  if v_schema is not null and v_tabla is not null then
    v_reg := to_regclass(format('%I.%I', v_schema, v_tabla));
    if v_reg is not null then
      -- columna de correo
      if v_col is null then
        select column_name into v_col
        from information_schema.columns
        where table_schema = v_schema and table_name = v_tabla
          and lower(column_name) in ('email','gmail','correo','mail')
        order by array_position(array['email','gmail','correo','mail'], lower(column_name))
        limit 1;
      end if;

      if v_col is not null then
        -- columna de activo (opcional)
        select column_name into v_activo_col
        from information_schema.columns
        where table_schema = v_schema and table_name = v_tabla
          and lower(column_name) in ('activo','active','habilitado','enabled')
        order by array_position(array['activo','active','habilitado','enabled'], lower(column_name))
        limit 1;

        v_sql := format('select exists(select 1 from %I.%I where lower(%I::text) = $1',
                        v_schema, v_tabla, v_col);
        if v_activo_col is not null then
          v_sql := v_sql || format(' and %I is not false', v_activo_col);
        end if;
        v_sql := v_sql || ')';

        execute v_sql into v_found using v_email;
        return coalesce(v_found, false);
      end if;
    end if;
  end if;

  -- respaldo: lista propia FichadaQR.empleados
  return exists(select 1 from "FichadaQR".empleados
                where lower(correo) = v_email and activo is not false);
end;
$$;

revoke all on function "FichadaQR".esta_habilitado(text) from public;
