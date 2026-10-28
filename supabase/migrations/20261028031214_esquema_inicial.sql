-- Esquema inicial de la app de finanzas (versión pública).
--
-- Reglas que aplican a todas las tablas:
-- - Cada fila es de una persona: `user_id` = `auth.uid()`, con RLS en todas.
--   La clave pública (anon) puede estar en el navegador porque RLS impide
--   leer o escribir filas de otro usuario.
-- - PK compuesta `(user_id, id)` con `id text`: los ids los genera el
--   cliente (la app funciona sin conexión y reintenta las escrituras; un id
--   propio las hace idempotentes) y las categorías del catálogo base usan
--   ids fijos `cat-*` que se repiten entre usuarios.
-- - Montos en numeric(15,2) y tasas en numeric(9,6): nunca float para dinero.
-- - Saldos y deudas no se guardan: se calculan en el cliente (`core/domain`).

-- `actualizado_en` lo pone la base, no el cliente.
create function public.tocar_actualizado_en()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.actualizado_en := now();
  return new;
end;
$$;

-- Cuentas y bolsillos en la misma tabla: un bolsillo tiene `cuenta_padre_id`.
create table public.cuentas (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  nombre text not null check (length(nombre) between 1 and 200),
  tipo text not null check (tipo in ('BANCO', 'BILLETERA', 'EFECTIVO', 'OTRO')),
  entidad text,
  ultimos4 text check (length(ultimos4) <= 4),
  color text not null,
  cuenta_padre_id text,
  saldo_inicial numeric(15, 2) not null default 0,
  suma_en_disponible boolean not null default true,
  reservado boolean not null default false,
  archivada boolean not null default false,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, cuenta_padre_id) references public.cuentas (user_id, id),
  check (cuenta_padre_id is null or cuenta_padre_id <> id)
);
create index cuentas_padre_idx on public.cuentas (user_id, cuenta_padre_id);

-- Una tabla ancha con `grupo` como discriminador; cada grupo usa sus columnas.
create table public.creditos (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  grupo text not null check (grupo in ('TARJETA', 'BANCO', 'PLATAFORMA', 'PERSONA')),
  nombre text not null check (length(nombre) between 1 and 200),
  entidad text,
  dia_pago smallint not null check (dia_pago between 1 and 31),
  archivado boolean not null default false,
  creado_en timestamptz,
  -- TARJETA
  ultimos4 text check (length(ultimos4) <= 4),
  dia_corte smallint check (dia_corte between 1 and 31),
  -- TARJETA y PLATAFORMA
  cupo numeric(15, 2) check (cupo >= 0),
  -- BANCO y PERSONA
  monto numeric(15, 2) check (monto >= 0),
  -- BANCO
  tasa_ea numeric(9, 6) check (tasa_ea >= 0),
  tipo_tasa text check (tipo_tasa in ('FIJA', 'VARIABLE')),
  plazo_meses smallint check (plazo_meses > 0),
  cuotas_pagadas_iniciales smallint check (cuotas_pagadas_iniciales >= 0),
  seguro_mensual numeric(15, 2) check (seguro_mensual >= 0),
  -- PERSONA
  fecha_acordada date,
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  check (grupo not in ('TARJETA', 'PLATAFORMA') or cupo is not null),
  check (grupo <> 'TARJETA' or dia_corte is not null),
  check (grupo not in ('BANCO', 'PERSONA') or monto is not null),
  check (
    grupo <> 'BANCO'
    or (tasa_ea is not null and tipo_tasa is not null and plazo_meses is not null)
  )
);

-- Valor real a pagar de una tarjeta en un periodo.
create table public.extractos (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  credito_id text not null,
  periodo text not null check (periodo ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  valor_a_pagar numeric(15, 2) not null check (valor_a_pagar >= 0),
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, credito_id) references public.creditos (user_id, id) on delete cascade
);
create index extractos_credito_idx on public.extractos (user_id, credito_id);

-- Historial de tasa de los créditos de banco con tasa variable.
create table public.cambios_tasa (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  credito_id text not null,
  fecha_desde date not null,
  tasa_ea numeric(9, 6) not null check (tasa_ea >= 0),
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, credito_id) references public.creditos (user_id, id) on delete cascade
);
create index cambios_tasa_credito_idx on public.cambios_tasa (user_id, credito_id);

-- Pagos fijos propios. Las cuotas de créditos no van aquí: se derivan de `creditos`.
create table public.pagos_fijos (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  nombre text not null check (length(nombre) between 1 and 200),
  -- Sin FK: puede ser una categoría del catálogo base (`cat-*`), que no tiene fila.
  categoria_id text not null,
  dia_limite smallint not null check (dia_limite between 1 and 31),
  monto numeric(15, 2) not null check (monto >= 0),
  es_variable boolean not null default false,
  frecuencia text not null check (frecuencia in ('MENSUAL', 'BIMESTRAL', 'ANUAL')),
  mes_inicio smallint not null check (mes_inicio between 1 and 12),
  cuenta_default_id text not null,
  activo boolean not null default true,
  periodos_pagados_sin_movimiento text[] not null default '{}',
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, cuenta_default_id) references public.cuentas (user_id, id)
);

create table public.movimientos (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  fecha date not null,
  tipo text not null check (tipo in ('INGRESO', 'GASTO', 'TRANSFERENCIA', 'INTERNO', 'AJUSTE')),
  monto numeric(15, 2) not null check (monto >= 0),
  descripcion text not null default '',
  -- Sin FK, igual que en `pagos_fijos`.
  categoria_id text,
  cuenta_origen_id text,
  cuenta_destino_id text,
  credito_origen_id text,
  credito_destino_id text,
  pago_fijo_id text,
  periodo text check (periodo ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, cuenta_origen_id) references public.cuentas (user_id, id),
  foreign key (user_id, cuenta_destino_id) references public.cuentas (user_id, id),
  foreign key (user_id, credito_origen_id) references public.creditos (user_id, id),
  foreign key (user_id, credito_destino_id) references public.creditos (user_id, id),
  foreign key (user_id, pago_fijo_id) references public.pagos_fijos (user_id, id)
);
create index movimientos_cuenta_origen_idx on public.movimientos (user_id, cuenta_origen_id);
create index movimientos_cuenta_destino_idx on public.movimientos (user_id, cuenta_destino_id);
create index movimientos_credito_origen_idx on public.movimientos (user_id, credito_origen_id);
create index movimientos_credito_destino_idx on public.movimientos (user_id, credito_destino_id);
create index movimientos_pago_fijo_idx on public.movimientos (user_id, pago_fijo_id);

-- Compras a cuotas con tarjeta o plataforma.
create table public.compras (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  credito_id text not null,
  -- La app borra el movimiento antes que su compra (`movimientos.page.ts`):
  -- al borrarlo, la compra queda sin movimiento en vez de bloquear el borrado.
  movimiento_id text,
  descripcion text not null default '',
  monto numeric(15, 2) not null check (monto >= 0),
  num_cuotas smallint not null check (num_cuotas > 0),
  valor_cuota numeric(15, 2) check (valor_cuota >= 0),
  fecha date not null,
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, credito_id) references public.creditos (user_id, id),
  foreign key (user_id, movimiento_id) references public.movimientos (user_id, id)
    on delete set null (movimiento_id)
);
create index compras_credito_idx on public.compras (user_id, credito_id);
create index compras_movimiento_idx on public.compras (user_id, movimiento_id);

-- Solo lo que la persona personalizó del catálogo base (id `cat-*`, cambios
-- parciales) o las categorías que creó (completas). En jsonb porque un
-- ajuste guarda únicamente los campos tocados, y `topeMensual: null`
-- ("quitó el tope") no es lo mismo que no tenerlo.
create table public.categorias (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  datos jsonb not null default '{}' check (jsonb_typeof(datos) = 'object'),
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id)
);

-- Preferencias de la app (no datos financieros). Una sola fila por persona, id 'app'.
create table public.preferencias (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null default 'app' check (id = 'app'),
  datos jsonb not null default '{}' check (jsonb_typeof(datos) = 'object'),
  actualizado_en timestamptz not null default now(),
  primary key (user_id, id)
);

-- Trigger, RLS, permisos y tiempo real: lo mismo para todas las tablas.
do $$
declare
  tabla text;
begin
  foreach tabla in array array[
    'cuentas', 'creditos', 'extractos', 'cambios_tasa', 'pagos_fijos',
    'movimientos', 'compras', 'categorias', 'preferencias'
  ]
  loop
    execute format(
      'create trigger tocar_actualizado_en before update on public.%I
         for each row execute function public.tocar_actualizado_en()',
      tabla
    );

    execute format('alter table public.%I enable row level security', tabla);

    -- `(select auth.uid())` se evalúa una vez por consulta, no por fila.
    execute format(
      'create policy "solo sus filas" on public.%I
         for all to authenticated
         using (user_id = (select auth.uid()))
         with check (user_id = (select auth.uid()))',
      tabla
    );

    -- El rol `anon` (sin sesión) no toca nada; toda sesión, incluso la
    -- anónima de la bienvenida, entra como `authenticated`.
    execute format('revoke all on public.%I from anon', tabla);
    execute format(
      'grant select, insert, update, delete on public.%I to authenticated',
      tabla
    );

    execute format('alter publication supabase_realtime add table public.%I', tabla);
  end loop;
end;
$$;

revoke execute on function public.tocar_actualizado_en() from public, anon, authenticated;
