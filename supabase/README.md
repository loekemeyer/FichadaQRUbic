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
podía leer los PINs de todos los empleados. Se cerró así:

- Se creó la vista **`planify.employees_publica`** (sin `password` / `telefono` /
  `fecha_nacimiento`) para lecturas públicas.
- Se **revocó `SELECT` sobre `planify.employees` al rol `anon`** (la clave pública
  ya no lee la tabla base). Los usuarios logueados (`authenticated`) no se tocaron.
- La fichada no se ve afectada: lee `planify.employees` como `service_role` (server-side).

Rollback si hiciera falta: `grant select on planify.employees to anon;`

Pendiente (fuera del alcance de la fichada): los usuarios `authenticated` todavía
pueden leer los PIN de todos (misma política `USING (true)`), y los PIN están en
texto plano — conviene restringir por usuario/rol y hashearlos.

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

## Archivos

- `migrations/0001_fichadaqr_schema.sql` — schema, tablas, RLS, semilla de config.
- `functions/fichada-qr-emitir-token/index.ts` — Edge Function (emitir).
- `functions/fichada-qr-fichar/index.ts` — Edge Function (fichar).

> Las funciones SQL (`fichadaqr_emitir_token`, `fichadaqr_fichar`, `b64url`) se
> aplicaron como migración en Supabase (`fichadaqr_funciones`,
> `fichadaqr_revoke_anon_rpc`).
