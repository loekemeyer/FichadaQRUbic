-- ============================================================================
-- Reconocimiento facial — Fase 1/2 — esquema aislado "reconocimiento_facial"
-- ----------------------------------------------------------------------------
-- Kiosco de fichada por CARA (ver FACIAL-PLAN.md). Reusa TODO lo de FichadaQR:
-- la tabla de fichadas (1/día atómico) y el resolutor de habilitados. Lo ÚNICO
-- nuevo que se agrega —los VECTORES de las caras— vive en su propio schema
-- "reconocimiento_facial", para no mezclarlo con el sistema QR ni con el de
-- producción (public).
--
-- Regla de naming (pedido del proyecto):
--   * lo que PUEDE ir en un schema  -> schema "reconocimiento_facial"
--     (tabla de rostros, config, helper de match).
--   * lo que NO puede (RPCs que PostgREST tiene que ver en public; edge fns)
--     -> prefijo recon_facial_ / recon-facial-.
--
-- Igual que FichadaQR: el schema NO se expone en PostgREST; las Edge Functions
-- entran con service_role (que ignora RLS) por RPC en public.
--
-- Privacidad (Ley 25.326 — dato biométrico sensible): se guarda SOLO el vector
-- (embedding), nunca la foto. El vector no reconstruye la cara. La base de
-- vectores NO se expone al cliente: el match se hace server-side (pgvector).
-- ============================================================================

create schema if not exists reconocimiento_facial;

-- pgvector: tipo `vector` + búsqueda por distancia (euclídea/coseno) server-side.
-- Se instala en `extensions` para seguir la misma convención que pgcrypto
-- (extensions.hmac) que ya usa FichadaQR.
create extension if not exists vector with schema extensions;

-- Enrolamiento: N embeddings por empleado (varias fotos = match más robusto).
-- face-api.js / MobileFaceNet -> descriptor de 128 dimensiones (float32).
create table if not exists reconocimiento_facial.rostros (
  id          bigint generated always as identity primary key,
  correo      text not null,                     -- linkea con la whitelist/fichadas
  embedding   extensions.vector(128) not null,   -- descriptor 128-D (face-api)
  etiqueta    text,                              -- opcional: "frente", "perfil izq", ...
  creado_en   timestamptz not null default now()
);

create index if not exists rostros_correo_idx
  on reconocimiento_facial.rostros (lower(correo));

-- Índice ANN para el match. HNSW no necesita entrenamiento (sirve con la tabla
-- casi vacía) y escala bien a medida que crece el enrolamiento. Distancia L2
-- (euclídea) = la métrica nativa de face-api (umbral típico < 0.55).
create index if not exists rostros_embedding_l2_idx
  on reconocimiento_facial.rostros
  using hnsw (embedding extensions.vector_l2_ops);

-- Config del kiosco facial (tunables propios del reconocimiento facial).
--   * clave_dispositivo: solo el equipo con esta clave puede fichar/enrolar
--     (misma idea que FichadaQR.config.clave_dispositivo, pero propia del kiosco
--     facial; puede ser un dispositivo distinto).
--   * umbral_distancia: match si distancia L2 < umbral (face-api ~0.55).
--   * requiere_liveness: exigir liveness_ok desde el MVP+1 (anti "foto de un
--     compañero"). true = seguro por defecto; poné false solo para pruebas.
create table if not exists reconocimiento_facial.config (
  id                integer primary key default 1,
  clave_dispositivo text not null,
  umbral_distancia  real not null default 0.55,
  requiere_liveness boolean not null default true,
  metrica           text not null default 'l2',   -- documental: l2 = euclídea face-api
  actualizado_en    timestamptz not null default now(),
  constraint reconfacial_config_fila_unica check (id = 1)
);

-- RLS activo por higiene: sin políticas => deny-all para anon/authenticated.
-- El service_role de las Edge Functions lo ignora; y el schema no está expuesto
-- en PostgREST, así que ningún cliente anon puede llegar de todos modos.
alter table reconocimiento_facial.rostros enable row level security;
alter table reconocimiento_facial.config  enable row level security;

-- Semilla de config: clave de dispositivo al azar (20 hex). gen_random_uuid()
-- es built-in (no requiere extensión).
insert into reconocimiento_facial.config (id, clave_dispositivo)
values (1, substr(replace(gen_random_uuid()::text, '-', ''), 1, 20))
on conflict (id) do nothing;
