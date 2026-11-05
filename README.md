# App de finanzas — base de datos (Supabase)

Esquema, políticas RLS y configuración de login de la versión pública. El
front está en `../frontend`.

- `supabase/migrations/` — migraciones SQL versionadas. Toda tabla nueva
  lleva `user_id`, RLS activado y su política `user_id = auth.uid()`.
- `supabase/config.toml` — configuración de Auth: anónimo, correo y Google
  activados, *manual linking* (para convertir la sesión anónima) y las
  URLs a las que se puede volver después del login.
- `pruebas/rls.sql` — prueba con dos usuarios de que nadie ve ni toca lo
  de otro. Corre en una transacción que se deshace.

## Aplicar cambios

Lo hace GitHub Actions (`.github/workflows/migraciones.yml`) al unir a
`main`. Secretos del repositorio: `SUPABASE_ACCESS_TOKEN`,
`SUPABASE_DB_PASSWORD` y `SUPABASE_PROJECT_REF`.

Regla: la migración sale antes que el front que la usa, y no rompe la
versión del front que está publicada (agregar columnas con valor por
defecto, no renombrar ni borrar en el mismo paso).

A mano:

```bash
npx supabase login
npx supabase link --project-ref <ref>
npx supabase migration new <nombre>   # crea el archivo en supabase/migrations
npx supabase db push                  # aplica las pendientes
```

## Configuración de Auth

`config.toml` se sube con:

```bash
SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID=... SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET=... npx supabase config push
```

El cliente OAuth de Google (Google Cloud → Credenciales) debe tener como
URI de redireccionamiento `https://<ref>.supabase.co/auth/v1/callback`.

La confirmación de correo está apagada (`enable_confirmations = false`),
Para producción conviene conectar
Brevo como SMTP y decidir si se activa.
