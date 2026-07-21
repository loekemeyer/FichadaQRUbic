# SETUP — Poner en marcha tu propia copia

Esta es una copia lista para que **montes tu propio backend**. No apunta a ningún
proyecto ajeno: la URL y la clave pública de Supabase están en blanco y las cargás
vos con las tuyas.

## Qué NO viene en este repo (y está bien)

Nada secreto viaja en el código:

- El **secreto de firma del token** y las **claves de dispositivo** se generan solos,
  al azar, cuando corrés las migraciones (`gen_random_uuid()` en el SQL). No hay que
  copiarlos de ningún lado.
- La **anon key** que vas a pegar en los HTML es **pública por diseño** (va en el
  navegador). La seguridad real la dan las claves de dispositivo + los tokens firmados
  del lado del servidor, no la anon key.

Lo único que había que “desconectar” era la **URL** y la **anon key** del proyecto
original, que estaban escritas en los 5 HTML. Ya están reemplazadas por
`TU-PROYECTO` / `TU_ANON_KEY`.

## Pasos para que funcione

### 1. Crear tu proyecto Supabase
- Entrá a https://supabase.com → New project. Guardá la **Project URL** y la
  **anon/public key** (Project Settings → API).

### 2. Aplicar el backend (schema + funciones)
Desde la carpeta `supabase/`, con la [Supabase CLI](https://supabase.com/docs/guides/local-development):

```bash
supabase link --project-ref TU_REF
supabase db push          # aplica migrations/0001..0008
supabase functions deploy fichada-qr-emitir-token --no-verify-jwt
supabase functions deploy fichada-qr-fichar        --no-verify-jwt
# Reconocimiento facial (opcional, sólo si vas a usar el kiosco):
supabase functions deploy recon-facial-nombre      --no-verify-jwt
supabase functions deploy recon-facial-enrolar     --no-verify-jwt
supabase functions deploy recon-facial-resolver    --no-verify-jwt
supabase functions deploy recon-facial-fichar      --no-verify-jwt
```

(También podés pegar los `.sql` de `supabase/migrations/` en el SQL Editor del panel
y desplegar las Edge Functions desde ahí.)

### 3. Pegar TUS credenciales en los HTML
En estos archivos, reemplazá los dos placeholders por los tuyos:

`pantalla.html`, `fichar.html`, `kiosco.html`, `enrolar.html`, `enrolar-fotos.html`

```js
const SUPABASE_URL  = "https://TU-PROYECTO.supabase.co"; // → tu Project URL
const SUPABASE_ANON = "TU_ANON_KEY";                     // → tu anon/public key
```

### 4. Sacar tus claves de dispositivo
Se generaron solas al aplicar las migraciones. Vé a verlas en el SQL Editor:

```sql
select clave_dispositivo from "FichadaQR".config where id = 1;             -- para QR
select clave_dispositivo from reconocimiento_facial.config where id = 1;   -- para kiosco facial
```

Con esas claves abrís las pantallas (nunca van en el código):

```
pantalla.html#clave=TU_CLAVE_QR
kiosco.html#clave=TU_CLAVE_FACIAL
enrolar.html#clave=TU_CLAVE_FACIAL
```

### 5. Cargar a quién puede fichar
La lista de habilitados es configurable (ver `supabase/README.md` → “Lista de correos
habilitados”). El proyecto original la leía de un schema externo `planify`, **que vos
no tenés**: por defecto la app cae a la lista propia `FichadaQR.empleados`. Cargá los
tuyos ahí:

```sql
insert into "FichadaQR".empleados (correo, nombre) values
  ('nombre.apellido@empresa.com','Nombre Apellido')
on conflict (correo) do nothing;
```

Para el kiosco facial, el enrolamiento es por **legajo**; si no vas a usar la fuente
`planify`, revisá `recon_facial_nombre` / la config de fuente en `supabase/README.md`.

### 6. Servir los HTML
Son estáticos. Subilos a cualquier hosting (GitHub Pages, Netlify, Vercel, o incluso
`python3 -m http.server`). El kiosco y el enrolar necesitan **HTTPS** para que el
navegador dé acceso a la cámara.

## Checklist rápido
- [ ] Proyecto Supabase creado
- [ ] `db push` + Edge Functions desplegadas (`--no-verify-jwt`)
- [ ] `SUPABASE_URL` y `SUPABASE_ANON` reemplazados en los 5 HTML
- [ ] Claves de dispositivo leídas de `config` y usadas en las URLs
- [ ] Empleados cargados en `FichadaQR.empleados`
- [ ] HTML servidos por HTTPS

Más detalle de arquitectura y seguridad en `DISENO.md` y `supabase/README.md`.
