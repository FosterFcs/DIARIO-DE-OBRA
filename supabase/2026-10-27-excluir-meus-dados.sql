-- =========================================================
-- Foster Obras · 2026-10-27 · exclusão de dados pelo próprio usuário (LGPD / Google Play)
-- Apaga todos os registros e os dados pessoais da conta. Mantém só o id e as datas do
-- teste/plano (sem dado pessoal) para o período grátis não recomeçar a cada exclusão.
-- As fotos são apagadas pelo app antes (API de Storage). O login, compartilhado com o
-- Foster Calc, é removido mediante pedido por e-mail.
-- =========================================================
create or replace function public.obra_excluir_meus_dados()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  delete from public.obra_registros where user_id = auth.uid();
  get diagnostics n = row_count;
  update public.obra_contas set nome = null, crea = null, tel = null where user_id = auth.uid();
  return n;
end;
$$;
revoke all on function public.obra_excluir_meus_dados() from public, anon;
grant execute on function public.obra_excluir_meus_dados() to authenticated;
