-- =========================================================
-- Foster Obras · Ponto do funcionário por GPS (cerca virtual) · 2026-11-25
-- Cada unidade/obra pode ter um link de ponto (ponto.html?t=TOKEN). O funcionário abre no celular,
-- escolhe o nome, digita o PIN e registra entrada ou saída. O servidor só aceita se o GPS estiver
-- dentro do raio da unidade. A presença vai para obra_registros (tabela 'presencas') da conta do dono,
-- com o mesmo id da chamada do dia (pres_<funcionário>_<data>), então aparece na aba Equipe.
-- =========================================================

create table if not exists public.obra_ponto_links (
  token text primary key default encode(extensions.gen_random_bytes(18), 'hex'),
  user_id uuid not null references auth.users(id) on delete cascade,
  obra_id text not null,
  criado_por uuid,
  criado_em timestamptz not null default now(),
  revogado_em timestamptz
);
create index if not exists obra_ponto_links_obra on public.obra_ponto_links (user_id, obra_id);
alter table public.obra_ponto_links enable row level security;
drop policy if exists "obra_ponto_links_ler" on public.obra_ponto_links;
create policy "obra_ponto_links_ler" on public.obra_ponto_links for select to authenticated
  using (user_id = (select auth.uid()) or public.obra_papel_em(user_id) in ('engenheiro','encarregado'));
revoke all on public.obra_ponto_links from anon, authenticated;
grant select on public.obra_ponto_links to authenticated;

-- tentativas de PIN errado (trava 15 min depois de 5 erros por funcionário)
create table if not exists public.obra_ponto_tentativas (
  token text not null,
  func_id text not null,
  em timestamptz not null default now()
);
create index if not exists obra_ponto_tentativas_idx on public.obra_ponto_tentativas (token, func_id, em);
alter table public.obra_ponto_tentativas enable row level security;
revoke all on public.obra_ponto_tentativas from anon, authenticated;

-- cria (ou devolve) o link de ponto da unidade
create or replace function public.obra_ponto_link(p_dono uuid, p_obra text, p_novo boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  if coalesce(public.obra_papel_em(p_dono), '') not in ('dono','engenheiro','encarregado') then
    raise exception 'sem permissão para gerar link' using errcode = '42501';
  end if;
  if not exists (select 1 from public.obra_registros where user_id = p_dono and id = p_obra and tabela = 'obras') then
    raise exception 'Unidade/obra não encontrada na nuvem. Aguarde sincronizar e tente de novo.' using errcode = '22023';
  end if;
  if p_novo then
    update public.obra_ponto_links set revogado_em = now() where user_id = p_dono and obra_id = p_obra and revogado_em is null;
  end if;
  select token into v_token from public.obra_ponto_links
   where user_id = p_dono and obra_id = p_obra and revogado_em is null order by criado_em desc limit 1;
  if v_token is null then
    insert into public.obra_ponto_links (user_id, obra_id, criado_por) values (p_dono, p_obra, auth.uid()) returning token into v_token;
  end if;
  return v_token;
end;
$$;
revoke all on function public.obra_ponto_link(uuid, text, boolean) from public, anon;
grant execute on function public.obra_ponto_link(uuid, text, boolean) to authenticated;

-- página pública: dados da unidade e lista de funcionários (sem PIN)
create or replace function public.obra_ponto_ver(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l public.obra_ponto_links; o jsonb; p jsonb; v_hoje text; v_func jsonb;
begin
  select * into l from public.obra_ponto_links where token = p_token;
  if not found or l.revogado_em is not null then return jsonb_build_object('erro', 'invalido'); end if;
  select dados into o from public.obra_registros where user_id = l.user_id and id = l.obra_id and tabela = 'obras';
  if o is null then return jsonb_build_object('erro', 'invalido'); end if;
  select dados into p from public.obra_registros where user_id = l.user_id and id = 'perfil' and tabela = 'perfil';
  v_hoje := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD');
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'nome', f.dados->>'nome', 'cargo', f.dados->>'cargo',
           'tem_pin', coalesce(f.dados->>'pin_hash', '') <> '',
           'entrada', pr.dados->>'entrada', 'saida', pr.dados->>'saida') order by f.dados->>'nome'), '[]'::jsonb)
    into v_func
    from public.obra_registros f
    left join public.obra_registros pr on pr.user_id = f.user_id and pr.tabela = 'presencas' and pr.id = 'pres_' || f.id || '_' || v_hoje
   where f.user_id = l.user_id and f.tabela = 'funcionarios' and f.dados->>'obra_id' = l.obra_id
     and coalesce(f.dados->>'ativo', 'true') <> 'false';
  return jsonb_build_object(
    'unidade', jsonb_build_object('nome', o->>'nome', 'endereco', o->>'endereco'),
    'empresa', jsonb_build_object('empresa', p->>'empresa', 'logo', p->>'logo', 'segmento', p->>'segmento'),
    'tem_local', (o->>'lat') is not null and (o->>'lng') is not null,
    'raio', coalesce((o->>'raio')::numeric, 150),
    'ativo', public.obra_ponto_conta_ativa(l.user_id),
    'hoje', v_hoje,
    'funcionarios', v_func);
end;
$$;
revoke all on function public.obra_ponto_ver(text) from public;
grant execute on function public.obra_ponto_ver(text) to anon, authenticated;

-- registra entrada ou saída com GPS
create or replace function public.obra_ponto_registrar(p_token text, p_func text, p_pin text, p_tipo text,
                                                      p_lat double precision, p_lng double precision, p_prec double precision)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.obra_ponto_links; o jsonb; f jsonb; pr jsonb; v_raio double precision; v_dist double precision;
        v_agora timestamp; v_data text; v_hora text; v_id text; v_gps jsonb; olat double precision; olng double precision;
begin
  if p_tipo not in ('entrada', 'saida') then return jsonb_build_object('erro', 'tipo'); end if;
  select * into l from public.obra_ponto_links where token = p_token;
  if not found or l.revogado_em is not null then return jsonb_build_object('erro', 'invalido'); end if;
  if not public.obra_ponto_conta_ativa(l.user_id) then return jsonb_build_object('erro', 'plano_inativo'); end if;
  select dados into o from public.obra_registros where user_id = l.user_id and id = l.obra_id and tabela = 'obras';
  select dados into f from public.obra_registros where user_id = l.user_id and id = p_func and tabela = 'funcionarios';
  if o is null or f is null or f->>'obra_id' is distinct from l.obra_id or coalesce(f->>'ativo', 'true') = 'false' then
    return jsonb_build_object('erro', 'funcionario');
  end if;
  if coalesce(f->>'pin_hash', '') = '' then return jsonb_build_object('erro', 'sem_pin'); end if;
  if (select count(*) from public.obra_ponto_tentativas t where t.token = p_token and t.func_id = p_func and t.em > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('erro', 'bloqueado');
  end if;
  if encode(extensions.digest(p_func || ':' || coalesce(p_pin, ''), 'sha256'), 'hex') <> f->>'pin_hash' then
    insert into public.obra_ponto_tentativas (token, func_id) values (p_token, p_func);
    perform pg_sleep(0.8);
    return jsonb_build_object('erro', 'pin');
  end if;
  delete from public.obra_ponto_tentativas t where t.token = p_token and t.func_id = p_func;

  olat := (o->>'lat')::double precision; olng := (o->>'lng')::double precision;
  if olat is null or olng is null then return jsonb_build_object('erro', 'sem_local'); end if;
  if p_lat is null or p_lng is null then return jsonb_build_object('erro', 'sem_gps'); end if;
  if coalesce(p_prec, 9999) > 200 then return jsonb_build_object('erro', 'precisao', 'prec', round(coalesce(p_prec, 9999))); end if;
  v_raio := coalesce((o->>'raio')::double precision, 150);
  v_dist := 2 * 6371000 * asin(sqrt(power(sin(radians(p_lat - olat) / 2), 2)
            + cos(radians(olat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - olng) / 2), 2)));
  if v_dist > v_raio + least(coalesce(p_prec, 0), 50) then
    return jsonb_build_object('erro', 'fora', 'distancia', round(v_dist), 'raio', round(v_raio));
  end if;

  v_agora := now() at time zone 'America/Sao_Paulo';
  v_data := to_char(v_agora, 'YYYY-MM-DD'); v_hora := to_char(v_agora, 'HH24:MI');
  v_id := 'pres_' || p_func || '_' || v_data;
  v_gps := jsonb_build_object('lat', round(p_lat::numeric, 5), 'lng', round(p_lng::numeric, 5), 'prec', round(p_prec::numeric), 'dist', round(v_dist::numeric), 'hora', v_hora);
  select dados into pr from public.obra_registros where user_id = l.user_id and id = v_id and tabela = 'presencas';
  if pr is null then
    pr := jsonb_build_object('id', v_id, 'obra_id', l.obra_id, 'func_id', p_func, 'data', v_data, 'status', 'presente');
  end if;
  pr := pr || jsonb_build_object('status', 'presente', 'obra_id', l.obra_id, 'origem', 'gps');
  if p_tipo = 'entrada' then
    if coalesce(pr->>'gps_entrada', '') = '' then pr := pr || jsonb_build_object('entrada', v_hora, 'gps_entrada', v_gps); end if;
  else
    pr := pr || jsonb_build_object('saida', v_hora, 'gps_saida', v_gps);
  end if;
  insert into public.obra_registros (user_id, id, tabela, obra_id, dados, atualizado_em)
  values (l.user_id, v_id, 'presencas', l.obra_id, pr, now())
  on conflict (user_id, id) do update set dados = excluded.dados, obra_id = excluded.obra_id, atualizado_em = now();
  return jsonb_build_object('ok', true, 'nome', f->>'nome', 'tipo', p_tipo, 'hora', pr->>(case when p_tipo = 'entrada' then 'entrada' else 'saida' end),
                            'distancia', round(v_dist), 'data', v_data);
end;
$$;
revoke all on function public.obra_ponto_registrar(text, text, text, text, double precision, double precision, double precision) from public;
grant execute on function public.obra_ponto_registrar(text, text, text, text, double precision, double precision, double precision) to anon, authenticated;

-- ---------- correção aplicada em seguida (ponto_gps_conta_ativa) ----------
-- obra_conta_ativa_de exige que quem chama seja o dono ou da equipe; o link do ponto é aberto sem login,
-- então a situação do plano é conferida pelo dono do link.
create or replace function public.obra_ponto_conta_ativa(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.obra_contas c
    where c.user_id = p_uid
      and ((c.plano_ate is not null and c.plano_ate > now())
           or (c.plano = 'trial' and c.trial_inicio > now() - interval '7 days')));
$$;
revoke all on function public.obra_ponto_conta_ativa(uuid) from public, anon, authenticated;
-- em obra_ponto_ver e obra_ponto_registrar, public.obra_conta_ativa_de(l.user_id) foi trocado por
-- public.obra_ponto_conta_ativa(l.user_id) (mesmas funções acima, recriadas com essa troca).
