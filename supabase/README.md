# FichadaQR — Backend (Fase 1)

Backend de la fichada por QR rotativo. Vive en el proyecto Supabase
**`Control Partes Talleristas`** (`hrxfctzncixxqmpfhskv`), dentro de un **schema
aislado `FichadaQR`** para no tocar el sistema de fichada de producción que ya
existe en `public` (`Fichadas_Virgilio`, etc.).

## Qué hay desplegado

### Tablas (schema `FichadaQR`)

| Tabla | Para qué |
|-------|----------|
| `empleados` (`correo` PK, `nombre`, `activo`) | Lista blanca de quién puede fichar |
| `fichadas` (`correo`, `fecha`, `creado_en`) — `UNIQUE(correo, fecha)` | Registra la fichada y garantiza **1 por día** (atómico) |
| `tokens_usados` (`jti`, `correo`) | Auditoría de tokens canjeados |
| `config` (`token_secret`, `clave_dispositivo`, `token_ttl_seg`, `ip_trabajo`) | Secreto de firma + clave de dispositivo + vida del token |

### Lógica (funciones SQL, `SECURITY DEFINER`, solo `service_role`)

- **`public.fichadaqr_emitir_token(p_clave)`** — valida la clave de dispositivo
  y devuelve un token **firmado (HMAC-SHA256)** con `exp` corto.
- **`public.fichadaqr_fichar(p_token, p_email)`** — valida **firma +
  vencimiento**, correo habilitado y **1/día**, y registra. Devuelve
  `{ok, hora}` o `{error: ya_ficho|token_vencido|token_invalido|no_habilitado}`.

La firma usa `pgcrypto` (`extensions.hmac`). El **secreto de firma nunca sale al
navegador**: solo lo conocen estas funciones (service_role).

### Edge Functions (cáscara HTTP + CORS, `verify_jwt = false`)

- **`fichada-qr-emitir-token`** → llama a `fichadaqr_emitir_token`.
- **`fichada-qr-fichar`** → llama a `fichadaqr_fichar`.

Se despliegan con `verify_jwt = false` a propósito: la autenticación real es la
**clave de dispositivo** (emitir) y el **token firmado** (fichar), no un JWT de
Supabase.

## La pantalla y la clave de dispositivo

`pantalla.html` pide el token a `fichada-qr-emitir-token` mandando la **clave de
dispositivo**. Esa clave **no está en el código**: se pasa por la URL al abrir la
pantalla en el dispositivo fijo:

```
pantalla.html#clave=TU_CLAVE_DE_DISPOSITIVO
```

Solo quien conoce esa clave puede **emitir** tokens válidos → ata la emisión al
dispositivo físico del punto de trabajo.

**La clave se generó al azar y vive en `FichadaQR.config`.** Para verla o
rotarla (nunca la subas al repo):

```sql
-- ver la clave actual
select clave_dispositivo from "FichadaQR".config where id = 1;

-- rotarla (invalida la anterior)
update "FichadaQR".config
   set clave_dispositivo = substr(replace(gen_random_uuid()::text,'-',''),1,20)
 where id = 1;
```

## Modelo de seguridad (y una decisión de diseño)

- **Defensa principal contra la "foto a distancia":** el token **vence** rápido
  (`config.token_ttl_seg`, por defecto **75 s**). Una captura vieja del QR ya no
  sirve — el servidor la rechaza con `token_vencido`.
- **Garantía de 1 fichada por día:** la restricción `UNIQUE(correo, fecha)` de
  `fichadas` (a prueba de carreras).
- **Uso del token:** `tokens_usados` se lleva por `(jti, correo)`, no global. Es
  una decisión deliberada: si fuera *un solo uso global*, un mismo QR en pantalla
  serviría para **una sola** fichada y al inicio de turno se haría cuello de
  botella (varias personas escaneando el mismo código). Con `(jti, correo)` +
  1/día, cada persona ficha una vez y no se traban entre sí. Si preferís el
  esquema estricto (un token = una sola fichada global), es un cambio chico en
  `fichadaqr_fichar`.

> Ventana honesta: dentro de esos ~75 s, alguien podría pasarle el QR a un
> compañero por WhatsApp y que fiche. Se acota con el TTL corto + 1/día. Para el
> caso real (fichar a un amigo desde la casa con una foto **vieja**) ya no
> funciona.

Endurecimiento futuro ya preparado: `config.ip_trabajo` (aceptar fichadas solo
desde la IP pública del trabajo) — falta el chequeo en la función y cargar la IP.

## Probar de punta a punta (desde una máquina con internet)

> El test HTTP no se puede correr desde el entorno de desarrollo de Claude porque
> su red bloquea la salida a `*.supabase.co`. La **lógica** ya se probó vía SQL
> (todos los casos OK, incluido el código vencido). Este script valida además la
> capa HTTP/Edge Functions.

```bash
BASE="https://hrxfctzncixxqmpfhskv.supabase.co/functions/v1"
CLAVE="<pegar clave_dispositivo de FichadaQR.config>"

# 1) emitir token (con la clave)
TOK=$(curl -s -X POST "$BASE/fichada-qr-emitir-token" \
  -H "Content-Type: application/json" -H "x-clave-dispositivo: $CLAVE" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
echo "token: $TOK"

# 2) fichar (debe dar {"ok":true,"hora":"HH:MM"})
curl -s -X POST "$BASE/fichada-qr-fichar" -H "Content-Type: application/json" \
  -d "{\"token\":\"$TOK\",\"email\":\"martina.gomez@fabrica.com\"}"; echo

# 3) fichar de nuevo (debe dar {"error":"ya_ficho",...})
curl -s -X POST "$BASE/fichada-qr-fichar" -H "Content-Type: application/json" \
  -d "{\"token\":\"$TOK\",\"email\":\"martina.gomez@fabrica.com\"}"; echo
```

Después de probar, limpiá las fichadas de prueba:

```sql
truncate "FichadaQR".fichadas, "FichadaQR".tokens_usados;
```

## Lista de correos habilitados (fuente configurable)

La validación de "correo habilitado" la resuelve `FichadaQR.esta_habilitado(correo)`,
que lee de una **fuente configurable** en `FichadaQR.config`:

- Por defecto: **`planify.employees`** (en inglés). Autodetecta la columna de
  correo (`Email` / `gmail` / `correo` / `mail`) y, si hay columna de activo
  (`activo` / `active` / …), **filtra solo los activos**.
- **Estado actual:** `planify.employees` ya existe pero **todavía no tiene columna
  de email** — hasta que la agreguen, la fichada usa como **respaldo** la lista
  propia `FichadaQR.empleados` (8 correos de ejemplo).
- Apenas `planify.employees` tenga la columna de email, la fichada **pasa a usarla
  sola** (y aplica el filtro de `activo`), sin tocar ni redeployar nada.

Cambiar la fuente (si el schema/tabla/columna fueran otros):

```sql
update "FichadaQR".config
   set fuente_schema  = 'planify',
       fuente_tabla   = 'employees',
       fuente_columna = null   -- null = autodetectar Email/gmail/correo/mail
 where id = 1;
```

> `activo` se interpreta permisivo: `true` o `null` = habilitado; solo `false`
> queda afuera (igual criterio que la lista propia).

### Nota de seguridad sobre `planify.employees` (hallazgo de esta fase)

Al conectar la fuente se detectó que `planify.employees` estaba **expuesta en la
Data API** con una política `emp_select USING (true)` para `public` y una columna
`password` (PIN de 4 dígitos en **texto plano**): cualquiera con la clave pública
podía leer los PINs de todos los empleados.

**Solución final (column-level):** se quitó el `SELECT` a nivel tabla a `anon` y
`authenticated`, y se re-otorgó `SELECT` **por columna en todas menos `password`**.
Resultado:

- `password` **no** es legible por API (ni `anon` ni `authenticated`) — verificado:
  `select password` → `42501 permission denied`.
- El resto de columnas (`id, nombre, email, activo, …`) sigue legible → el QR/lista
  y la app admin funcionan.
- **Login** (empleado y maestro) intacto: va por RPC `SECURITY DEFINER`
  (`planify_employee_login`, `planify_maestro_login`) que leen `password`
  server-side, no por lectura directa con la clave pública.
- La fichada no se ve afectada: lee `planify.employees` como `service_role`.
- Cambio de app necesario y ya aplicado por el equipo de planify:
  `loadAllEmployees` pasó de `select=*` a columnas explícitas (sin `password`).

> Nota: `information_schema.role_column_grants` puede seguir listando `password`
> (ruido por múltiples grantors); el privilegio **efectivo** es el que vale y da
> denegado (`has_column_privilege(...,'password') = false`).

Rollback si hiciera falta (revierte a acceso completo por tabla):
`grant select on planify.employees to anon, authenticated;`

Pendiente fase 2 (opcional): los PIN siguen en **texto plano** en la tabla (aunque
ya no se leen por API). Hashearlos requiere tocar `planify_*_login` para comparar
hash.

Cargar/editar la lista de respaldo propia (opcional):

```sql
insert into "FichadaQR".empleados (correo, nombre) values
  ('nombre.apellido@empresa.com','Nombre Apellido')
on conflict (correo) do nothing;
```

> Nota UX pendiente: el selector de correos de `fichar.html` todavía tiene una
> lista de ejemplo hardcodeada. La validación real ya es server-side (un correo
> fuera de la fuente da `no_habilitado`), pero para que cada persona pueda
> **elegirse** conviene que ese selector también salga de `planify.empleados`
> (falta un endpoint de solo-lectura para listarlos).

## Reconocimiento facial (backend)

Backend del **kiosco de fichada por cara** (ver `FACIAL-PLAN.md`). Es un agregado
**aislado**: reusa TODO lo de FichadaQR (la tabla `fichadas` con 1/día atómico y
el resolutor `esta_habilitado`), y lo único nuevo —los **vectores de las caras**—
vive en su **propio schema `reconocimiento_facial`**, para no mezclarlo con el
sistema QR ni con producción (`public`).

**Convención de naming (pedido del proyecto):** lo que puede ir en un schema va en
`reconocimiento_facial`; lo que no (RPCs que PostgREST tiene que ver en `public`,
y las Edge Functions) lleva el prefijo `recon_facial_` / `recon-facial-`.

### Cómo funciona (match server-side)

El kiosco calcula el **embedding** (descriptor de 128-D, face-api.js) **en el
navegador** y manda solo el vector. El match contra los rostros enrolados se hace
**server-side con pgvector**, así la galería de vectores **nunca sale del server**
(privacidad + no se puede robar). Se guarda **solo el vector, nunca la foto** (dato
biométrico sensible, Ley 25.326).

### Tablas (schema `reconocimiento_facial`)

| Tabla | Para qué |
|-------|----------|
| `rostros` (`correo`, `embedding vector(128)`, `etiqueta`, `creado_en`) | N embeddings por empleado (varias fotos = match más robusto). Índice **HNSW** (L2). |
| `config` (`clave_dispositivo`, `umbral_distancia`, `requiere_liveness`, `metrica`) | Clave del kiosco + tunables del match |

`pgvector` se instala en el schema `extensions` (misma convención que `pgcrypto`).

### Lógica (RPC en `public`, `SECURITY DEFINER`, solo `service_role`)

- **`recon_facial_enrolar(p_clave, p_correo, p_embedding, p_etiqueta)`** — valida
  clave + correo habilitado y guarda un embedding. `{ok, correo, total_rostros}`.
- **`recon_facial_resolver(p_clave, p_embedding, p_umbral)`** — preview "¿Sos vos,
  Juan?": match server-side, devuelve el candidato **sin fichar**. `{ok, correo,
  distancia}` o `{error: sin_config|clave_invalida|faltan_datos|dim_invalida|no_match|no_habilitado}`.
- **`recon_facial_fichar(p_clave, p_embedding, p_liveness_ok, p_umbral)`** — flujo
  completo: clave → **liveness** → match por embedding → habilitado → **1/día** →
  INSERT en `FichadaQR.fichadas`. `{ok, correo, hora}` o `{error: sin_config|
  clave_invalida|faltan_datos|dim_invalida|liveness|no_match|no_habilitado|ya_ficho}`.
- **`recon_facial_baja(p_correo)`** — derecho al olvido (Ley 25.326): borra TODOS
  los embeddings de un correo al desvincular a la persona. Admin (solo `service_role`,
  sin Edge Function; se corre por SQL). `{ok, correo, borrados}`.

El helper interno del match vive en el schema: `reconocimiento_facial.match_cercano`.

### Edge Functions (cáscara HTTP + CORS, `verify_jwt = false`)

- **`recon-facial-fichar`** → `recon_facial_fichar`. Body `{embedding:number[128],
  liveness_ok:boolean, umbral?}` + header `x-clave-dispositivo`.
- **`recon-facial-resolver`** → `recon_facial_resolver`. Preview "¿Sos vos?" (no
  ficha). Body `{embedding:number[128], umbral?}` + header `x-clave-dispositivo`.
- **`recon-facial-enrolar`** → `recon_facial_enrolar`. Body `{correo, embedding, etiqueta?}`
  + header `x-clave-dispositivo`.

### Frontend (páginas)

En la raíz del repo, **separado del QR** (se elige uno u otro desde `index.html`):

- **`kiosco.html`** — dispositivo fijo con cámara. Usa **face-api.js** en el navegador:
  detecta la cara → **liveness por parpadeo** (EAR) → calcula el embedding 128-D →
  `recon-facial-resolver` ("¿Sos vos?") → `recon-facial-fichar`. La foto nunca sale
  del dispositivo. Abrir con `kiosco.html#clave=…`.
- **`enrolar.html`** — pantalla de admin: correo del empleado + 3–5 capturas →
  `recon-facial-enrolar`. Abrir con `enrolar.html#clave=…`.

> Los modelos de face-api se cargan del CDN (`@vladmandic/face-api`). Para uso
> offline, self-hostear los ~6 MB de pesos en el repo (pendiente, ver FACIAL-PLAN.md).

### Modelo de seguridad

- **Clave de dispositivo** (`reconocimiento_facial.config.clave_dispositivo`, al
  azar): solo el equipo que la conoce puede **fichar/enrolar** — ata la operación
  al kiosco físico (igual idea que la clave del QR, pero propia del kiosco facial).
- **Liveness** (`requiere_liveness`, por defecto **`true`**): el chequeo real
  (parpadeo/giro con landmarks) es client-side; el server exige la afirmación
  `liveness_ok`. Sin liveness no ficha. Frena la "foto de un compañero".
- **Umbral** (`umbral_distancia`, por defecto **0.55**, L2/euclídea de face-api):
  match si distancia < umbral. Falso positivo = fichás a otro (grave) → preferir
  umbral estricto + confirmación "¿Sos vos?" (`recon-facial-resolver`). El
  `umbral` del request **solo puede endurecer**, nunca aflojar: el server lo topea
  al valor de `config` (`least(...)`), así ni con la clave se puede mandar un
  umbral gigante para forzar un match.
- **La galería no se expone:** match server-side; `rostros` con RLS y schema no
  publicado en PostgREST. `service_role` (Edge Functions) es el único que entra.

Ver / rotar la clave del kiosco facial (nunca subir al repo):

```sql
-- ver
select clave_dispositivo from reconocimiento_facial.config where id = 1;
-- rotar (invalida la anterior)
update reconocimiento_facial.config
   set clave_dispositivo = substr(replace(gen_random_uuid()::text,'-',''),1,20),
       actualizado_en = now()
 where id = 1;

-- ajustar umbral / liveness sin redeployar
update reconocimiento_facial.config
   set umbral_distancia = 0.55, requiere_liveness = true, actualizado_en = now()
 where id = 1;
```

> **Aplicar:** el schema y las funciones están en `migrations/0005_*` y
> `migrations/0006_*` (aún **sin aplicar** al proyecto — se aplican con
> `supabase db push` o desde el panel/MCP). Las Edge Functions se despliegan con
> `verify_jwt = false`.

## Archivos

- `migrations/0001_fichadaqr_schema.sql` — schema, tablas, RLS, semilla de config.
- `functions/fichada-qr-emitir-token/index.ts` — Edge Function (emitir).
- `functions/fichada-qr-fichar/index.ts` — Edge Function (fichar).
- `migrations/0005_reconfacial_schema.sql` — schema `reconocimiento_facial`, pgvector, `rostros` (+HNSW), `config`, RLS.
- `migrations/0006_reconfacial_funciones.sql` — RPC `recon_facial_*` + helper de match + grants.
- `functions/recon-facial-fichar/index.ts` — Edge Function (fichar por cara).
- `functions/recon-facial-resolver/index.ts` — Edge Function (preview "¿Sos vos?").
- `functions/recon-facial-enrolar/index.ts` — Edge Function (enrolar rostro).

> Las funciones SQL de QR (`fichadaqr_emitir_token`, `fichadaqr_fichar`, `b64url`)
> se aplicaron como migración en Supabase (`fichadaqr_funciones`,
> `fichadaqr_revoke_anon_rpc`).
