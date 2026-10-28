-- Ajustes que pidió el asesor de Supabase tras el esquema inicial.

-- `rls_auto_enable()` la crea Supabase al marcar "Enable automatic RLS": la
-- usa un event trigger, no la app. Como SECURITY DEFINER en `public`,
-- quedaba expuesta como RPC (`/rest/v1/rpc/rls_auto_enable`) para cualquiera.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end;
$$;

-- La FK de `pagos_fijos` hacia `cuentas` no tenía índice.
create index pagos_fijos_cuenta_default_idx on public.pagos_fijos (user_id, cuenta_default_id);
