-- =========================================================
-- Foster Obras · 2026-11-18 (b) · INTEGRIDADE DO RDO + LINK DE APROVAÇÃO
-- 1. Autoria: cada registro guarda quem lançou (autor_id) e quem alterou por último (alterado_por).
-- 2. Assinaturas recebem a hora do SERVIDOR (servidor_em), não a do celular.
-- 3. RDO assinado recebe um selo: hash SHA-256 do conteúdo + código de verificação de 12 caracteres.
--    Enquanto estiver assinado, o conteúdo não muda. Para editar é preciso reabrir (as assinaturas saem).
-- 4. RDO assinado não pode ser excluído — só cancelado, com justificativa (o cancelamento é definitivo).
-- 5. Histórico: toda alteração ou exclusão de RDO e de medição guarda a versão anterior.
-- 6. Link para o cliente: página pública que mostra o RDO e colhe aprovação (com assinatura) ou ressalva.
-- 7. Verificação pública pelo código impresso no PDF.
-- =========================================================

-- ---------- histórico ----------
create table if not exists public.obra_registros_hist (
  hid bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  registro_id text not null,
  tabela text not null,
  op text not null check (op in ('alterado','excluido')),
  dados jsonb not null,
  por uuid,
  em timestamptz not null default now()
);
create index if not exists obra_hist_registro on public.obra_registros_hist (user_id, registro_id, em desc);
create index if not exists obra_hist_codigo on public.obra_registros_hist ((dados->'integridade'->>'codigo')) where tabela = 'rdos';
alter table public.obra_registros_hist enable row level security;
drop policy if exists "obra_hist_ler" on public.obra_registros_hist;
create policy "obra_hist_ler" on public.obra_registros_hist for select to authenticated
  using (user_id = (select auth.uid()) or public.obra_papel_em(user_id) = 'engenheiro');
revoke all on public.obra_registros_hist from anon, authenticated;
grant select on public.obra_registros_hist to authenticated;

create index if not exists obra_registros_codigo on public.obra_registros ((dados->'integridade'->>'codigo')) where tabela = 'rdos';

-- ---------- hash do conteúdo ----------
-- campos de assinatura, aprovação, selo e controle ficam fora: o hash é do que foi registrado
create or replace function public.obra_rdo_hash(d jsonb)
returns text language sql immutable set search_path = public as $$
  select encode(extensions.digest(
    (d - array['ass_rt','ass_cli','integridade','aprovacao','cancelado','atualizado_em','criado_em','autor_id','alterado_por'])::text,
    'sha256'), 'hex');
$$;
revoke all on function public.obra_rdo_hash(jsonb) from public, anon;

-- assinatura sem os carimbos do servidor (para comparar se é a mesma)
create or replace function public.obra_sem_carimbo(a jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select case when jsonb_typeof(a) = 'object' then a - 'servidor_em' - 'hash_assinado' else null end;
$$;
revoke all on function public.obra_sem_carimbo(jsonb) from public, anon;

-- ---------- guarda dos registros ----------
create or replace function public.obra_registros_guarda()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  novo jsonb; antigo jsonb; h text; k text; papel text;
begin
  -- exclusão total da conta (LGPD) ou remoção feita pelo painel/servidor: sem travas
  if current_setting('foster.excluindo_tudo', true) = 'on' then return coalesce(new, old); end if;

  if tg_op = 'DELETE' then
    if uid is null then return old; end if;
    if old.tabela = 'rdos' and (jsonb_typeof(old.dados->'ass_rt') = 'object' or jsonb_typeof(old.dados->'ass_cli') = 'object') then
      raise exception 'rdo_assinado: RDO assinado não pode ser excluído. Use "Cancelar RDO" com a justificativa.' using errcode = '23514';
    end if;
    if old.tabela in ('rdos','medicoes') then
      insert into public.obra_registros_hist (user_id, registro_id, tabela, op, dados, por)
      values (old.user_id, old.id, old.tabela, 'excluido', old.dados, uid);
    end if;
    return old;
  end if;

  novo := new.dados;
  antigo := case when tg_op = 'UPDATE' then old.dados end;

  -- autoria (o app não decide isso)
  if uid is not null then
    if antigo is null then novo := novo || jsonb_build_object('autor_id', uid);
    else
      novo := case when antigo ? 'autor_id' then jsonb_set(novo, '{autor_id}', antigo->'autor_id') else novo - 'autor_id' end;
      novo := novo || jsonb_build_object('alterado_por', uid);
    end if;
  end if;

  if new.tabela = 'rdos' then
    h := public.obra_rdo_hash(novo);

    -- assinatura do RT: só o dono da conta ou um engenheiro da equipe
    if jsonb_typeof(novo->'ass_rt') = 'object' and uid is not null and uid <> new.user_id
       and public.obra_sem_carimbo(novo->'ass_rt') is distinct from public.obra_sem_carimbo(antigo->'ass_rt') then
      papel := public.obra_papel_em(new.user_id);
      if papel is distinct from 'engenheiro' then
        raise exception 'assinatura_rt: só o responsável técnico ou um engenheiro da equipe assina como RT' using errcode = '23514';
      end if;
    end if;

    -- retirar a assinatura do RT (reabrir o RDO): também só o dono ou um engenheiro
    if antigo is not null and jsonb_typeof(antigo->'ass_rt') = 'object' and jsonb_typeof(novo->'ass_rt') is distinct from 'object'
       and uid is not null and uid <> new.user_id and public.obra_papel_em(new.user_id) is distinct from 'engenheiro' then
      raise exception 'assinatura_rt: só o responsável técnico ou um engenheiro da equipe pode reabrir um RDO assinado' using errcode = '23514';
    end if;

    if antigo is not null then
      -- aprovação feita pelo link do cliente não se perde se outro aparelho regravar uma cópia antiga
      -- sem ela (campo ausente). Reabrir o RDO manda o campo como null de propósito: aí ela sai.
      if not (novo ? 'ass_cli') and antigo->'ass_cli'->>'via' = 'link'
         and public.obra_rdo_hash(antigo) = h then
        novo := novo || jsonb_build_object('ass_cli', antigo->'ass_cli');
        if not (novo ? 'aprovacao') and antigo ? 'aprovacao' then novo := novo || jsonb_build_object('aprovacao', antigo->'aprovacao'); end if;
      end if;
      if not (novo ? 'aprovacao') and antigo->'aprovacao'->>'via' = 'link'
         and public.obra_rdo_hash(antigo) = h then
        novo := novo || jsonb_build_object('aprovacao', antigo->'aprovacao');
      end if;

      -- conteúdo travado enquanto a mesma assinatura estiver no RDO
      foreach k in array array['ass_rt','ass_cli'] loop
        if jsonb_typeof(antigo->k) = 'object' and jsonb_typeof(novo->k) = 'object'
           and public.obra_sem_carimbo(antigo->k) = public.obra_sem_carimbo(novo->k)
           and public.obra_rdo_hash(antigo) <> h then
          raise exception 'rdo_assinado: RDO assinado não pode ser alterado. Reabra o RDO (as assinaturas serão removidas) para editar.' using errcode = '23514';
        end if;
      end loop;

      -- cancelamento é definitivo
      if jsonb_typeof(antigo->'cancelado') = 'object' then
        novo := jsonb_set(novo, '{cancelado}', antigo->'cancelado');
      end if;
    end if;

    -- carimbo do servidor em cada assinatura nova
    foreach k in array array['ass_rt','ass_cli'] loop
      if jsonb_typeof(novo->k) = 'object' then
        if antigo is not null and jsonb_typeof(antigo->k) = 'object'
           and public.obra_sem_carimbo(antigo->k) = public.obra_sem_carimbo(novo->k) and antigo->k ? 'servidor_em' then
          novo := jsonb_set(novo, array[k], (novo->k) || jsonb_build_object('servidor_em', antigo->k->'servidor_em', 'hash_assinado', antigo->k->'hash_assinado'));
        else
          novo := jsonb_set(novo, array[k], (novo->k) || jsonb_build_object('servidor_em', now(), 'hash_assinado', h));
        end if;
      elsif novo ? k then
        novo := novo - k;
      end if;
    end loop;

    -- cancelamento novo: carimbo do servidor
    if jsonb_typeof(novo->'cancelado') = 'object' and (antigo is null or jsonb_typeof(antigo->'cancelado') is distinct from 'object') then
      if coalesce(trim(novo->'cancelado'->>'motivo'), '') = '' then
        raise exception 'cancelamento: informe o motivo' using errcode = '23514';
      end if;
      novo := jsonb_set(novo, '{cancelado}', (novo->'cancelado') || jsonb_build_object('servidor_em', now(), 'por', uid));
    end if;

    -- selo de integridade
    if jsonb_typeof(novo->'ass_rt') = 'object' or jsonb_typeof(novo->'ass_cli') = 'object' then
      novo := novo || jsonb_build_object('integridade', jsonb_build_object(
        'hash', h, 'codigo', upper(substr(h, 1, 12)),
        'selado_em', case when antigo->'integridade'->>'hash' = h then antigo->'integridade'->'selado_em' else to_jsonb(now()) end));
    else
      novo := novo - 'integridade';
    end if;
  end if;

  -- histórico da versão anterior (ignora regravações idênticas)
  if antigo is not null and new.tabela in ('rdos','medicoes')
     and (antigo - 'atualizado_em' - 'alterado_por') is distinct from (novo - 'atualizado_em' - 'alterado_por') then
    insert into public.obra_registros_hist (user_id, registro_id, tabela, op, dados, por)
    values (old.user_id, old.id, old.tabela, 'alterado', antigo, uid);
  end if;

  new.dados := novo;
  return new;
end;
$$;
revoke all on function public.obra_registros_guarda() from public, anon, authenticated;
drop trigger if exists obra_registros_guarda on public.obra_registros;
create trigger obra_registros_guarda before insert or update or delete on public.obra_registros
  for each row execute function public.obra_registros_guarda();

-- ---------- links para o cliente ----------
create table if not exists public.obra_links (
  token text primary key default encode(extensions.gen_random_bytes(18), 'hex'),
  user_id uuid not null references auth.users(id) on delete cascade,
  registro_id text not null,
  hash text not null,
  snapshot jsonb not null check (octet_length(snapshot::text) <= 600000),
  criado_por uuid,
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  revogado_em timestamptz,
  resposta jsonb
);
create index if not exists obra_links_registro on public.obra_links (user_id, registro_id);
alter table public.obra_links enable row level security;
drop policy if exists "obra_links_ler" on public.obra_links;
create policy "obra_links_ler" on public.obra_links for select to authenticated
  using (user_id = (select auth.uid()) or public.obra_papel_em(user_id) in ('engenheiro','encarregado'));
revoke all on public.obra_links from anon, authenticated;
grant select (token, user_id, registro_id, hash, criado_por, criado_em, expira_em, revogado_em, resposta) on public.obra_links to authenticated;

-- cria o link de um RDO. O conteúdo vem do servidor (não do aparelho); o app só manda os links
-- temporários das fotos. Links anteriores sem resposta do mesmo RDO são revogados.
create or replace function public.obra_link_criar(p_dono uuid, p_registro text, p_fotos jsonb default '[]', p_dias integer default 30)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; o jsonb; p jsonb; v_token text; v_expira timestamptz;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  if coalesce(public.obra_papel_em(p_dono), '') not in ('dono','engenheiro','encarregado') then
    raise exception 'sem permissão para gerar link' using errcode = '42501';
  end if;
  if not public.obra_conta_ativa_de(p_dono) then raise exception 'plano_inativo' using errcode = '42501'; end if;
  select dados into r from public.obra_registros where user_id = p_dono and id = p_registro and tabela = 'rdos';
  if r is null then raise exception 'RDO não encontrado na nuvem. Aguarde sincronizar e tente de novo.' using errcode = '22023'; end if;
  if jsonb_typeof(r->'cancelado') = 'object' then raise exception 'RDO cancelado' using errcode = '22023'; end if;
  select dados into o from public.obra_registros where user_id = p_dono and id = r->>'obra_id' and tabela = 'obras';
  select dados into p from public.obra_registros where user_id = p_dono and id = 'perfil' and tabela = 'perfil';
  if jsonb_typeof(p_fotos) is distinct from 'array' then p_fotos := '[]'; end if;
  p_dias := least(greatest(coalesce(p_dias, 30), 1), 60);
  v_expira := now() + make_interval(days => p_dias);

  update public.obra_links set revogado_em = now()
  where user_id = p_dono and registro_id = p_registro and resposta is null and revogado_em is null;

  insert into public.obra_links (user_id, registro_id, hash, snapshot, criado_por, expira_em)
  values (p_dono, p_registro, public.obra_rdo_hash(r),
    jsonb_build_object(
      'rdo', r - 'autor_id' - 'alterado_por',
      'obra', jsonb_build_object('nome', o->'nome', 'cliente', o->'cliente', 'endereco', o->'endereco', 'art', o->'art',
                                 'rt', o->'rt', 'inicio', o->'inicio', 'fim', o->'fim'),
      'empresa', jsonb_build_object('empresa', p->'empresa', 'cnpj', p->'cnpj', 'nome', p->'nome', 'crea', p->'crea',
                                    'tel', p->'tel', 'email', p->'email', 'endereco', p->'endereco', 'logo', p->'logo', 'rodape', p->'rodape'),
      'fotos', p_fotos),
    auth.uid(), v_expira)
  returning token into v_token;
  return jsonb_build_object('token', v_token, 'expira_em', v_expira);
end;
$$;
revoke all on function public.obra_link_criar(uuid, text, jsonb, integer) from public, anon;
grant execute on function public.obra_link_criar(uuid, text, jsonb, integer) to authenticated;

create or replace function public.obra_link_revogar(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.obra_links l set revogado_em = now()
  where l.token = p_token and l.revogado_em is null
    and coalesce(public.obra_papel_em(l.user_id), '') in ('dono','engenheiro','encarregado');
end;
$$;
revoke all on function public.obra_link_revogar(text) from public, anon;
grant execute on function public.obra_link_revogar(text) to authenticated;

-- página pública: mostra o RDO do link
create or replace function public.obra_link_ver(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l public.obra_links; atual jsonb;
begin
  select * into l from public.obra_links where token = p_token;
  if not found then return jsonb_build_object('erro', 'nao_encontrado'); end if;
  if l.revogado_em is not null and l.resposta is null then return jsonb_build_object('erro', 'revogado'); end if;
  if l.expira_em < now() and l.resposta is null then return jsonb_build_object('erro', 'vencido'); end if;
  select dados into atual from public.obra_registros where user_id = l.user_id and id = l.registro_id and tabela = 'rdos';
  return jsonb_build_object(
    'snapshot', l.snapshot,
    'resposta', l.resposta - 'ip_hash' - 'ua',
    'expira_em', l.expira_em,
    'atual', atual is not null and public.obra_rdo_hash(atual) = l.hash and jsonb_typeof(atual->'cancelado') is distinct from 'object',
    'cancelado', atual is not null and jsonb_typeof(atual->'cancelado') = 'object',
    'integridade', atual->'integridade');
end;
$$;
revoke all on function public.obra_link_ver(text) from public;
grant execute on function public.obra_link_ver(text) to anon, authenticated;

-- página pública: o cliente/fiscal aprova (com assinatura) ou registra ressalva
create or replace function public.obra_link_responder(p_token text, p_decisao text, p_nome text, p_doc text default null,
                                                     p_comentario text default null, p_img text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.obra_links; atual jsonb; v_ip text; v_ua text; resp jsonb; hdr jsonb;
begin
  p_nome := trim(coalesce(p_nome, '')); p_doc := nullif(trim(coalesce(p_doc, '')), ''); p_comentario := nullif(trim(coalesce(p_comentario, '')), '');
  if p_decisao not in ('aprovado','ressalva') then raise exception 'decisão inválida' using errcode = '22023'; end if;
  if char_length(p_nome) < 3 or char_length(p_nome) > 120 then raise exception 'informe o nome completo' using errcode = '22023'; end if;
  if char_length(coalesce(p_doc, '')) > 40 or char_length(coalesce(p_comentario, '')) > 2000 then raise exception 'texto grande demais' using errcode = '22023'; end if;
  if p_decisao = 'ressalva' and p_comentario is null then raise exception 'descreva a ressalva' using errcode = '22023'; end if;
  if p_decisao = 'aprovado' and (p_img is null or p_img !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$' or char_length(p_img) > 150000) then
    raise exception 'faça a assinatura no quadro' using errcode = '22023';
  end if;

  select * into l from public.obra_links where token = p_token for update;
  if not found or l.revogado_em is not null or l.expira_em < now() then raise exception 'link_invalido: link vencido ou cancelado' using errcode = '22023'; end if;
  if l.resposta is not null then raise exception 'link_respondido: este RDO já foi respondido por este link' using errcode = '22023'; end if;
  select dados into atual from public.obra_registros where user_id = l.user_id and id = l.registro_id and tabela = 'rdos' for update;
  if atual is null or public.obra_rdo_hash(atual) <> l.hash or jsonb_typeof(atual->'cancelado') = 'object' then
    raise exception 'rdo_alterado: o RDO foi alterado ou cancelado depois do envio. Peça um link novo.' using errcode = '22023';
  end if;

  begin hdr := nullif(current_setting('request.headers', true), '')::jsonb; exception when others then hdr := null; end;
  v_ip := split_part(coalesce(hdr->>'x-forwarded-for', hdr->>'x-real-ip', ''), ',', 1);
  v_ua := left(coalesce(hdr->>'user-agent', ''), 200);
  resp := jsonb_build_object('decisao', p_decisao, 'nome', p_nome, 'doc', p_doc, 'comentario', p_comentario, 'em', now(),
    'ip_hash', case when v_ip <> '' then encode(extensions.digest(v_ip || l.token, 'sha256'), 'hex') end, 'ua', v_ua);
  update public.obra_links set resposta = resp where token = p_token;

  if p_decisao = 'aprovado' then
    atual := atual || jsonb_build_object(
      'ass_cli', jsonb_build_object('img', p_img, 'nome', p_nome, 'doc', p_doc, 'em', now(), 'via', 'link'),
      'aprovacao', jsonb_build_object('decisao', 'aprovado', 'nome', p_nome, 'comentario', p_comentario, 'em', now(), 'via', 'link'));
  else
    atual := atual || jsonb_build_object(
      'aprovacao', jsonb_build_object('decisao', 'ressalva', 'nome', p_nome, 'doc', p_doc, 'comentario', p_comentario, 'em', now(), 'via', 'link'));
  end if;
  update public.obra_registros set dados = atual, atualizado_em = now() where user_id = l.user_id and id = l.registro_id;
  return jsonb_build_object('ok', true, 'decisao', p_decisao, 'em', now());
end;
$$;
revoke all on function public.obra_link_responder(text, text, text, text, text, text) from public;
grant execute on function public.obra_link_responder(text, text, text, text, text, text) to anon, authenticated;

-- verificação pública pelo código impresso no PDF
create or replace function public.obra_rdo_verificar(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c text := upper(regexp_replace(coalesce(p_codigo, ''), '[^0-9A-Fa-f]', '', 'g'));
        r record; o jsonb; p jsonb;
begin
  if char_length(c) <> 12 then return jsonb_build_object('status', 'invalido'); end if;
  select user_id, dados into r from public.obra_registros where tabela = 'rdos' and dados->'integridade'->>'codigo' = c limit 1;
  if found then
    select dados into o from public.obra_registros where user_id = r.user_id and id = r.dados->>'obra_id' and tabela = 'obras';
    select dados into p from public.obra_registros where user_id = r.user_id and id = 'perfil' and tabela = 'perfil';
    return jsonb_build_object(
      'status', case when jsonb_typeof(r.dados->'cancelado') = 'object' then 'cancelado' else 'valido' end,
      'codigo', c, 'hash', r.dados->'integridade'->'hash', 'selado_em', r.dados->'integridade'->'selado_em',
      'numero', r.dados->'numero', 'data', r.dados->'data',
      'obra', o->'nome', 'empresa', coalesce(nullif(p->>'empresa', ''), p->>'nome'),
      'rt', case when jsonb_typeof(r.dados->'ass_rt') = 'object' then jsonb_build_object('nome', r.dados->'ass_rt'->'nome', 'doc', r.dados->'ass_rt'->'doc', 'em', r.dados->'ass_rt'->'servidor_em') end,
      'cliente', case when jsonb_typeof(r.dados->'ass_cli') = 'object' then jsonb_build_object('nome', r.dados->'ass_cli'->'nome', 'em', r.dados->'ass_cli'->'servidor_em', 'via', r.dados->'ass_cli'->'via') end,
      'cancelado', case when jsonb_typeof(r.dados->'cancelado') = 'object' then jsonb_build_object('motivo', r.dados->'cancelado'->'motivo', 'em', r.dados->'cancelado'->'servidor_em') end);
  end if;
  select h.dados, h.em, h.op into r from public.obra_registros_hist h
  where h.tabela = 'rdos' and h.dados->'integridade'->>'codigo' = c order by h.em desc limit 1;
  if found then
    return jsonb_build_object('status', case when r.op = 'excluido' then 'excluido' else 'substituido' end, 'codigo', c,
      'numero', r.dados->'numero', 'data', r.dados->'data', 'alterado_em', r.em, 'selado_em', r.dados->'integridade'->'selado_em');
  end if;
  return jsonb_build_object('status', 'nao_encontrado', 'codigo', c);
end;
$$;
revoke all on function public.obra_rdo_verificar(text) from public;
grant execute on function public.obra_rdo_verificar(text) to anon, authenticated;

-- ---------- exclusão de dados (LGPD) passa a levar equipe, links e histórico ----------
create or replace function public.obra_excluir_meus_dados()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  perform set_config('foster.excluindo_tudo', 'on', true);
  delete from public.obra_links where user_id = auth.uid();
  delete from public.obra_registros_hist where user_id = auth.uid();
  delete from public.obra_convites where dono_id = auth.uid();
  delete from public.obra_membros where dono_id = auth.uid() or membro_id = auth.uid();
  delete from public.obra_registros where user_id = auth.uid();
  get diagnostics n = row_count;
  update public.obra_contas set nome = null, crea = null, tel = null where user_id = auth.uid();
  perform set_config('foster.excluindo_tudo', 'off', true);
  return n;
end;
$$;
revoke all on function public.obra_excluir_meus_dados() from public, anon;
grant execute on function public.obra_excluir_meus_dados() to authenticated;

-- ---------- RDOs já assinados antes desta versão recebem o selo ----------
-- (a hora do servidor desses fica sendo a desta atualização)
update public.obra_registros set dados = dados
where tabela = 'rdos' and (jsonb_typeof(dados->'ass_rt') = 'object' or jsonb_typeof(dados->'ass_cli') = 'object');
