-- =========================================================
-- Foster Obras · 2026-11-18 (a) · EQUIPE E PAPÉIS
-- A conta de quem contrata o plano (o "dono") passa a ser o espaço da empresa.
-- O dono convida pessoas por e-mail, cada uma com um papel:
--   engenheiro  · vê e lança tudo (exceto dados da empresa); não exclui obras
--   encarregado · RDO, chamada/ponto, fotos e movimentação de estoque; não vê financeiro,
--                 orçamento nem medição; não assina como responsável técnico
--   cliente     · só consulta obra, RDOs, cronograma, fotos e medições
-- O acesso pode ser a todas as obras (obras = null) ou só a algumas (lista de ids).
-- O plano que vale é sempre o do dono. Membros com papel de cliente não contam no limite.
-- =========================================================

-- ---------- tabelas ----------
create table if not exists public.obra_membros (
  dono_id uuid not null references auth.users(id) on delete cascade,
  membro_id uuid not null references auth.users(id) on delete cascade,
  papel text not null check (papel in ('engenheiro','encarregado','cliente')),
  obras text[] check (obras is null or cardinality(obras) <= 200),
  nome text check (char_length(nome) <= 120),
  email text check (char_length(email) <= 200),
  criado_em timestamptz not null default now(),
  primary key (dono_id, membro_id),
  check (dono_id <> membro_id)
);
create index if not exists obra_membros_membro on public.obra_membros (membro_id);
alter table public.obra_membros enable row level security;
drop policy if exists "obra_membros_ver" on public.obra_membros;
drop policy if exists "obra_membros_remover" on public.obra_membros;
-- o dono vê a equipe; o membro vê a própria participação
create policy "obra_membros_ver" on public.obra_membros for select to authenticated
  using (dono_id = (select auth.uid()) or membro_id = (select auth.uid()));
-- o dono remove alguém; o membro pode sair sozinho
create policy "obra_membros_remover" on public.obra_membros for delete to authenticated
  using (dono_id = (select auth.uid()) or membro_id = (select auth.uid()));
revoke all on public.obra_membros from anon, authenticated;
grant select, delete on public.obra_membros to authenticated;

create table if not exists public.obra_convites (
  token text primary key default encode(extensions.gen_random_bytes(18), 'hex'),
  dono_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  email text not null check (char_length(email) between 3 and 200),
  papel text not null check (papel in ('engenheiro','encarregado','cliente')),
  obras text[] check (obras is null or cardinality(obras) <= 200),
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null default now() + interval '14 days',
  aceito_em timestamptz,
  aceito_por uuid
);
create index if not exists obra_convites_dono on public.obra_convites (dono_id);
alter table public.obra_convites enable row level security;
drop policy if exists "obra_convites_dono" on public.obra_convites;
create policy "obra_convites_dono" on public.obra_convites for select to authenticated
  using (dono_id = (select auth.uid()));
drop policy if exists "obra_convites_apagar" on public.obra_convites;
create policy "obra_convites_apagar" on public.obra_convites for delete to authenticated
  using (dono_id = (select auth.uid()));
revoke all on public.obra_convites from anon, authenticated;
grant select, delete on public.obra_convites to authenticated;

-- ---------- funções de apoio ----------
-- papel de quem está logado no espaço de p_dono: 'dono', o papel do convite, ou null
create or replace function public.obra_papel_em(p_dono uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when p_dono = auth.uid() then 'dono'
    else (select m.papel from public.obra_membros m where m.dono_id = p_dono and m.membro_id = auth.uid()) end;
$$;
revoke all on function public.obra_papel_em(uuid) from public, anon;
grant execute on function public.obra_papel_em(uuid) to authenticated;

-- a conta de p_uid está com teste ou plano ativo? (só para a própria conta ou para quem é da equipe dela)
create or replace function public.obra_conta_ativa_de(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (p_uid = auth.uid() or exists (select 1 from public.obra_membros m where m.dono_id = p_uid and m.membro_id = auth.uid()))
    and exists (
      select 1 from public.obra_contas c
      where c.user_id = p_uid
        and ((c.plano_ate is not null and c.plano_ate > now())
             or (c.plano = 'trial' and c.trial_inicio > now() - interval '7 days'))
    );
$$;
revoke all on function public.obra_conta_ativa_de(uuid) from public, anon;
grant execute on function public.obra_conta_ativa_de(uuid) to authenticated;

-- quantas pessoas (sem contar clientes) cada plano aceita na equipe; null = ilimitado
create or replace function public.obra_limite_membros(p_uid uuid)
returns integer language sql stable security definer set search_path = public as $$
  select case c.plano when 'basico' then 1 when 'profissional' then 5 when 'trial' then 2 else null end
  from public.obra_contas c where c.user_id = p_uid;
$$;
revoke all on function public.obra_limite_membros(uuid) from public, anon, authenticated;

-- o que cada papel pode fazer em cada tipo de registro
--   p_acao: 'ler' | 'gravar' | 'apagar'
create or replace function public.obra_permite(p_dono uuid, p_tabela text, p_obra text, p_id text, p_acao text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.obra_membros m
    where m.dono_id = p_dono and m.membro_id = auth.uid()
      -- recorte por obra (dados da empresa aparecem para todos, só para leitura)
      and (m.obras is null
           or (case when p_tabela = 'obras' then p_id else p_obra end) = any (m.obras)
           or (p_tabela = 'perfil' and p_acao = 'ler'))
      and case m.papel
        when 'engenheiro' then
          case p_acao when 'ler' then true
                      when 'gravar' then p_tabela <> 'perfil'
                      else p_tabela not in ('obras','perfil') end
        when 'encarregado' then
          case p_acao when 'ler' then p_tabela in ('obras','rdos','etapas','funcionarios','presencas','materiais','movimentos','fotos','perfil')
                      when 'gravar' then p_tabela in ('rdos','presencas','fotos','movimentos')
                      else p_tabela in ('presencas','fotos','movimentos') end
        when 'cliente' then
          p_acao = 'ler' and p_tabela in ('obras','rdos','etapas','fotos','medicoes','perfil')
        else false end
  );
$$;
revoke all on function public.obra_permite(uuid, text, text, text, text) from public, anon;
grant execute on function public.obra_permite(uuid, text, text, text, text) to authenticated;

-- ---------- registros: dono ou equipe ----------
drop policy if exists "obra_registros_ler" on public.obra_registros;
drop policy if exists "obra_registros_apagar" on public.obra_registros;
drop policy if exists "obra_registros_inserir" on public.obra_registros;
drop policy if exists "obra_registros_alterar" on public.obra_registros;
create policy "obra_registros_ler" on public.obra_registros for select to authenticated
  using (user_id = (select auth.uid()) or public.obra_permite(user_id, tabela, obra_id, id, 'ler'));
create policy "obra_registros_apagar" on public.obra_registros for delete to authenticated
  using (user_id = (select auth.uid()) or public.obra_permite(user_id, tabela, obra_id, id, 'apagar'));
create policy "obra_registros_inserir" on public.obra_registros for insert to authenticated
  with check ((user_id = (select auth.uid()) and (select public.obra_conta_ativa()))
           or (public.obra_permite(user_id, tabela, obra_id, id, 'gravar') and public.obra_conta_ativa_de(user_id)));
create policy "obra_registros_alterar" on public.obra_registros for update to authenticated
  using (user_id = (select auth.uid()) or public.obra_permite(user_id, tabela, obra_id, id, 'gravar'))
  with check ((user_id = (select auth.uid()) and (select public.obra_conta_ativa()))
           or (public.obra_permite(user_id, tabela, obra_id, id, 'gravar') and public.obra_conta_ativa_de(user_id)));

-- ---------- fotos: a pasta é a do dono; a equipe lê, engenheiro/encarregado enviam ----------
-- (pastas que não são id de usuário são ignoradas sem erro, para não afetar outros buckets/apps)
create or replace function public.obra_papel_pasta(p_pasta text)
returns text language sql stable security definer set search_path = public as $$
  select case when p_pasta ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then public.obra_papel_em(p_pasta::uuid) end;
$$;
revoke all on function public.obra_papel_pasta(text) from public, anon;
grant execute on function public.obra_papel_pasta(text) to authenticated;
create or replace function public.obra_conta_ativa_pasta(p_pasta text)
returns boolean language sql stable security definer set search_path = public as $$
  select case when p_pasta ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then public.obra_conta_ativa_de(p_pasta::uuid) else false end;
$$;
revoke all on function public.obra_conta_ativa_pasta(text) from public, anon;
grant execute on function public.obra_conta_ativa_pasta(text) to authenticated;
drop policy if exists "obra_fotos_dono_ler" on storage.objects;
drop policy if exists "obra_fotos_dono_enviar" on storage.objects;
drop policy if exists "obra_fotos_dono_trocar" on storage.objects;
drop policy if exists "obra_fotos_dono_apagar" on storage.objects;
create policy "obra_fotos_dono_ler" on storage.objects for select to authenticated
  using (bucket_id = 'obra-fotos' and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or public.obra_papel_pasta((storage.foldername(name))[1]) is not null));
create policy "obra_fotos_dono_enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'obra-fotos' and (
    ((storage.foldername(name))[1] = (select auth.uid())::text and (select public.obra_conta_ativa()))
    or (public.obra_papel_pasta((storage.foldername(name))[1]) in ('engenheiro','encarregado')
        and public.obra_conta_ativa_pasta((storage.foldername(name))[1]))));
create policy "obra_fotos_dono_trocar" on storage.objects for update to authenticated
  using (bucket_id = 'obra-fotos' and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or public.obra_papel_pasta((storage.foldername(name))[1]) in ('engenheiro','encarregado')))
  with check (bucket_id = 'obra-fotos' and (
    ((storage.foldername(name))[1] = (select auth.uid())::text and (select public.obra_conta_ativa()))
    or (public.obra_papel_pasta((storage.foldername(name))[1]) in ('engenheiro','encarregado')
        and public.obra_conta_ativa_pasta((storage.foldername(name))[1]))));
create policy "obra_fotos_dono_apagar" on storage.objects for delete to authenticated
  using (bucket_id = 'obra-fotos' and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or public.obra_papel_pasta((storage.foldername(name))[1]) in ('engenheiro','encarregado')));

-- ---------- convites ----------
-- cria (ou refaz) o convite para um e-mail; devolve o código que vai no link
create or replace function public.obra_convidar(p_email text, p_papel text, p_obras text[] default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(p_email)); lim integer; qtd integer; v_token text;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  if not public.obra_conta_ativa() then raise exception 'plano_inativo: ative um plano para convidar a equipe' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'e-mail inválido' using errcode = '22023'; end if;
  if p_papel not in ('engenheiro','encarregado','cliente') then raise exception 'papel inválido' using errcode = '22023'; end if;
  if v_email = (select lower(email) from auth.users where id = auth.uid()) then raise exception 'use outro e-mail: este é o seu' using errcode = '22023'; end if;
  if p_obras is not null and cardinality(p_obras) = 0 then p_obras := null; end if;
  delete from public.obra_convites where dono_id = auth.uid() and lower(email) = v_email and aceito_em is null;
  if p_papel <> 'cliente' then
    lim := public.obra_limite_membros(auth.uid());
    if lim is not null then
      select (select count(*) from public.obra_membros m where m.dono_id = auth.uid() and m.papel <> 'cliente'
                and lower(coalesce(m.email, '')) <> v_email)
           + (select count(*) from public.obra_convites c where c.dono_id = auth.uid() and c.papel <> 'cliente'
                and c.aceito_em is null and c.expira_em > now())
        into qtd;
      if qtd >= lim then
        raise exception 'limite_equipe: seu plano permite % pessoa(s) na equipe (clientes não contam)', lim using errcode = '23514';
      end if;
    end if;
  end if;
  insert into public.obra_convites (dono_id, email, papel, obras) values (auth.uid(), v_email, p_papel, p_obras)
  returning token into v_token;
  return v_token;
end;
$$;
revoke all on function public.obra_convidar(text, text, text[]) from public, anon;
grant execute on function public.obra_convidar(text, text, text[]) to authenticated;

-- aceita o convite: precisa estar logado com o mesmo e-mail convidado
create or replace function public.obra_aceitar_convite(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cv public.obra_convites; v_email text; v_nome text;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  select * into cv from public.obra_convites where token = p_token for update;
  if not found or cv.aceito_em is not null or cv.expira_em < now() then
    raise exception 'convite_invalido: o convite não existe, já foi usado ou venceu' using errcode = '22023';
  end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is distinct from lower(cv.email) then
    raise exception 'convite_outro_email: este convite foi enviado para %', cv.email using errcode = '42501';
  end if;
  if cv.dono_id = auth.uid() then raise exception 'convite_invalido' using errcode = '22023'; end if;
  select nome into v_nome from public.obra_contas where user_id = auth.uid();
  insert into public.obra_membros (dono_id, membro_id, papel, obras, nome, email)
  values (cv.dono_id, auth.uid(), cv.papel, cv.obras, v_nome, v_email)
  on conflict (dono_id, membro_id) do update set papel = excluded.papel, obras = excluded.obras, email = excluded.email,
    nome = coalesce(excluded.nome, obra_membros.nome);
  update public.obra_convites set aceito_em = now(), aceito_por = auth.uid() where token = p_token;
  return jsonb_build_object('dono_id', cv.dono_id, 'papel', cv.papel);
end;
$$;
revoke all on function public.obra_aceitar_convite(text) from public, anon;
grant execute on function public.obra_aceitar_convite(text) to authenticated;

-- o dono muda o papel ou as obras de alguém da equipe
create or replace function public.obra_membro_alterar(p_membro uuid, p_papel text, p_obras text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare lim integer; qtd integer; atual text;
begin
  select papel into atual from public.obra_membros where dono_id = auth.uid() and membro_id = p_membro;
  if not found then raise exception 'membro não encontrado' using errcode = '22023'; end if;
  if p_papel not in ('engenheiro','encarregado','cliente') then raise exception 'papel inválido' using errcode = '22023'; end if;
  if atual = 'cliente' and p_papel <> 'cliente' then
    lim := public.obra_limite_membros(auth.uid());
    select count(*) into qtd from public.obra_membros where dono_id = auth.uid() and papel <> 'cliente';
    if lim is not null and qtd >= lim then
      raise exception 'limite_equipe: seu plano permite % pessoa(s) na equipe (clientes não contam)', lim using errcode = '23514';
    end if;
  end if;
  if p_obras is not null and cardinality(p_obras) = 0 then p_obras := null; end if;
  update public.obra_membros set papel = p_papel, obras = p_obras where dono_id = auth.uid() and membro_id = p_membro;
end;
$$;
revoke all on function public.obra_membro_alterar(uuid, text, text[]) from public, anon;
grant execute on function public.obra_membro_alterar(uuid, text, text[]) to authenticated;

-- contas que o usuário pode abrir: a própria e as empresas em que está na equipe
create or replace function public.obra_minhas_contas()
returns table (dono_id uuid, papel text, obras text[], nome text, empresa text, ativo boolean)
language sql stable security definer set search_path = public as $$
  select auth.uid(), 'dono', null::text[], c.nome,
         (select r.dados->>'empresa' from public.obra_registros r where r.user_id = auth.uid() and r.id = 'perfil'),
         public.obra_conta_ativa()
  from (select 1) x left join public.obra_contas c on c.user_id = auth.uid()
  where auth.uid() is not null
  union all
  select m.dono_id, m.papel, m.obras, c.nome,
         (select r.dados->>'empresa' from public.obra_registros r where r.user_id = m.dono_id and r.id = 'perfil'),
         exists (select 1 from public.obra_contas a where a.user_id = m.dono_id
                   and ((a.plano_ate is not null and a.plano_ate > now()) or (a.plano = 'trial' and a.trial_inicio > now() - interval '7 days')))
  from public.obra_membros m left join public.obra_contas c on c.user_id = m.dono_id
  where m.membro_id = auth.uid();
$$;
revoke all on function public.obra_minhas_contas() from public, anon;
grant execute on function public.obra_minhas_contas() to authenticated;
