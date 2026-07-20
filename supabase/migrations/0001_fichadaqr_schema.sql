-- ============================================================================
-- FichadaQR — Fase 1 (MVP) — esquema aislado dentro de "Control Partes Talleristas"
-- ----------------------------------------------------------------------------
-- Todo vive en el schema "FichadaQR" para NO tocar el sistema de fichada de
-- producción que ya existe en public (Fichadas_Virgilio, Empleados, etc.).
-- El schema NO se expone en PostgREST; las Edge Functions entran por conexión
-- directa a Postgres con service_role (que ignora RLS).
-- ============================================================================

create schema if not exists "FichadaQR";

-- Lista blanca de correos habilitados para fichar
create table if not exists "FichadaQR".empleados (
  correo     text primary key,
  nombre     text,
  activo     boolean not null default true,
  creado_en  timestamptz not null default now()
);

-- Registro de fichadas. UNIQUE(correo, fecha) => 1 fichada por día (garantía atómica)
create table if not exists "FichadaQR".fichadas (
  id         bigint generated always as identity primary key,
  correo     text not null,
  fecha      date not null,
  creado_en  timestamptz not null default now(),
  unique (correo, fecha)
);

-- Auditoría de tokens canjeados. Clave (jti, correo): un código no se puede
-- reusar para la MISMA persona, pero SÍ lo pueden usar varias personas distintas
-- (evita el cuello de botella al inicio de turno). El tope real de 1/día lo da
-- la tabla fichadas; la defensa contra "foto a distancia" es el vencimiento corto.
create table if not exists "FichadaQR".tokens_usados (
  jti       text not null,
  correo    text not null,
  usado_en  timestamptz not null default now(),
  primary key (jti, correo)
);

-- Configuración: secreto de firma + clave de dispositivo (para emitir tokens) +
-- vida del token en segundos + IP del trabajo (opcional, para más adelante).
create table if not exists "FichadaQR".config (
  id                 integer primary key default 1,
  token_secret       text not null,
  clave_dispositivo  text not null,
  token_ttl_seg      integer not null default 75,
  ip_trabajo         text,
  constraint config_fila_unica check (id = 1)
);

-- RLS activo por higiene (el service_role de las Edge Functions lo ignora;
-- ningún cliente anon puede llegar porque el schema no está expuesto).
alter table "FichadaQR".empleados     enable row level security;
alter table "FichadaQR".fichadas      enable row level security;
alter table "FichadaQR".tokens_usados enable row level security;
alter table "FichadaQR".config        enable row level security;

-- Semilla de config: secreto de firma (64 hex) y clave de dispositivo (20 hex),
-- generados al azar. gen_random_uuid() es built-in (no requiere extensión).
insert into "FichadaQR".config (id, token_secret, clave_dispositivo)
values (
  1,
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  substr(replace(gen_random_uuid()::text, '-', ''), 1, 20)
)
on conflict (id) do nothing;
