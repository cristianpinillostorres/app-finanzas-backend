-- Prueba de RLS con dos usuarios. Corre todo dentro de una transacción y la
-- deshace al final: no deja nada en la base. Si algo falla, lanza un error
-- que dice qué. Se corre como `postgres` (SQL editor, conector o psql).
begin;

insert into auth.users (id, aud, role, email)
values
  ('00000000-0000-0000-0000-00000000000a', 'authenticated', 'authenticated', 'a@prueba.test'),
  ('00000000-0000-0000-0000-00000000000b', 'authenticated', 'authenticated', 'b@prueba.test');

-- Como A: crea una cuenta y un movimiento.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

insert into public.cuentas (id, nombre, tipo, color) values ('c1', 'Cuenta de A', 'BANCO', '#000');
insert into public.movimientos (id, fecha, tipo, monto, cuenta_origen_id)
values ('m1', '2026-10-27', 'GASTO', 1000, 'c1');

do $$
begin
  if (select count(*) from public.cuentas) <> 1 then
    raise exception 'A no ve su propia cuenta';
  end if;
end $$;

-- Como B: no ve, no cambia, no borra ni se hace pasar por A.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

do $$
declare
  filas int;
begin
  if (select count(*) from public.cuentas) <> 0 or (select count(*) from public.movimientos) <> 0 then
    raise exception 'B puede leer filas de A';
  end if;

  update public.cuentas set nombre = 'hackeada' where id = 'c1';
  get diagnostics filas = row_count;
  if filas <> 0 then raise exception 'B puede modificar filas de A'; end if;

  delete from public.movimientos where id = 'm1';
  get diagnostics filas = row_count;
  if filas <> 0 then raise exception 'B puede borrar filas de A'; end if;

  begin
    insert into public.cuentas (user_id, id, nombre, tipo, color)
    values ('00000000-0000-0000-0000-00000000000a', 'c2', 'Falsa', 'BANCO', '#000');
    raise exception 'B puede crear filas a nombre de A';
  exception when insufficient_privilege then
    null; -- RLS la rechazó: correcto.
  end;
end $$;

-- Sin sesión (rol anon): nada.
reset role;
set local role anon;
do $$
begin
  perform 1 from public.cuentas;
  raise exception 'anon puede leer cuentas';
exception when insufficient_privilege then
  null;
end $$;

reset role;
rollback;

select 'RLS OK: B no ve ni toca lo de A, y anon no lee nada' as resultado;
