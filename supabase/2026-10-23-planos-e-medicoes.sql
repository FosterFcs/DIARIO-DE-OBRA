-- =========================================================
-- Foster Obras · 2026-10-23
-- 1. O plano passa a valer no servidor: sem teste (7 dias) ou plano ativo,
--    a conta continua vendo e baixando os dados, mas não grava nada novo.
-- 2. Limite de obras por plano (Básico 3, Profissional 10, Empresa ilimitado).
-- 3. Novas tabelas lógicas: medicoes (boletim de medição) e perfil (dados que saem nos PDFs).
-- 4. Fotos: permite substituir arquivo (upsert) e só envia com plano ativo.
-- =========================================================

-- quais tipos de registro o app pode guardar
alter table public.obra_registros drop constraint if exists obra_registros_tabela_check;
alter table public.obra_registros add constraint obra_registros_tabela_check
  check (tabela in ('obras','rdos','despesas','etapas','funcionarios','presencas','materiais','movimentos','fotos','orcamentos','medicoes','perfil'));

-- planos aceitos
alter table public.obra_contas drop constraint if exists obra_contas_plano_check;
alter table public.obra_contas add constraint obra_contas_plano_check
  check (plano in ('trial','basico','profissional','empresa'));

-- a conta pode gravar? (teste de 7 dias ou plano pago dentro da validade)
create or replace function public.obra_conta_ativa()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.obra_contas c
    where c.user_id = auth.uid()
      and ((c.plano_ate is not null and c.plano_ate > now())
           or (c.plano = 'trial' and c.trial_inicio > now() - interval '7 days'))
  );
$$;
revoke all on function public.obra_conta_ativa() from public, anon;
grant execute on function public.obra_conta_ativa() to authenticated;

-- limite de obras do plano (null = ilimitado)
create or replace function public.obra_limite_obras(uid uuid default auth.uid())
returns integer language sql stable security definer set search_path = public as $$
  select case c.plano when 'basico' then 3 when 'profissional' then 10 when 'trial' then 10 else null end
  from public.obra_contas c where c.user_id = uid;
$$;
-- usado só pelo gatilho abaixo
revoke all on function public.obra_limite_obras(uuid) from public, anon, authenticated;

-- leitura e exclusão continuam sempre liberadas para o dono; gravar exige conta ativa
drop policy if exists "obra_registros_dono" on public.obra_registros;
drop policy if exists "obra_registros_ler" on public.obra_registros;
drop policy if exists "obra_registros_apagar" on public.obra_registros;
drop policy if exists "obra_registros_inserir" on public.obra_registros;
drop policy if exists "obra_registros_alterar" on public.obra_registros;
create policy "obra_registros_ler" on public.obra_registros for select to authenticated
  using (user_id = (select auth.uid()));
create policy "obra_registros_apagar" on public.obra_registros for delete to authenticated
  using (user_id = (select auth.uid()));
create policy "obra_registros_inserir" on public.obra_registros for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.obra_conta_ativa()));
create policy "obra_registros_alterar" on public.obra_registros for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and (select public.obra_conta_ativa()));

-- bloqueia obra acima do limite do plano (erro 23514 = registro recusado)
create or replace function public.obra_checa_limite()
returns trigger language plpgsql security definer set search_path = public as $$
declare lim integer; qtd integer;
begin
  if new.tabela <> 'obras' then return new; end if;
  if exists (select 1 from public.obra_registros where user_id = new.user_id and id = new.id) then return new; end if;
  lim := public.obra_limite_obras(new.user_id);
  if lim is null then return new; end if;
  select count(*) into qtd from public.obra_registros where user_id = new.user_id and tabela = 'obras';
  if qtd >= lim then
    raise exception 'limite_obras: seu plano permite % obra(s)', lim using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function public.obra_checa_limite() from public, anon, authenticated;
drop trigger if exists obra_registros_limite on public.obra_registros;
create trigger obra_registros_limite before insert on public.obra_registros
  for each row execute function public.obra_checa_limite();

-- fotos: enviar e substituir só com conta ativa
drop policy if exists "obra_fotos_dono_enviar" on storage.objects;
drop policy if exists "obra_fotos_dono_trocar" on storage.objects;
create policy "obra_fotos_dono_enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'obra-fotos' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.obra_conta_ativa()));
create policy "obra_fotos_dono_trocar" on storage.objects for update to authenticated
  using (bucket_id = 'obra-fotos' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'obra-fotos' and (storage.foldername(name))[1] = (select auth.uid())::text and (select public.obra_conta_ativa()));

-- conta do administrador (Wilson) com plano Empresa sem vencimento
update public.obra_contas c set plano = 'empresa', plano_ate = '2099-12-31'
from auth.users u where u.id = c.user_id and lower(u.email) = 'comercial@fosterconstrucoes.com.br';

-- Para liberar um cliente depois do PIX (rodar no SQL Editor do Supabase):
--   update public.obra_contas c set plano = 'profissional', plano_ate = now() + interval '1 month'
--   from auth.users u where u.id = c.user_id and lower(u.email) = 'email@do.cliente';
