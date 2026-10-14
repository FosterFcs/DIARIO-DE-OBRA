-- =========================================================
-- Foster Obras · dados na nuvem (projeto foster-calc) · 2026-10-14
-- Uma conta serve para Foster Calc e Foster Obras. Cada registro do app (obra, RDO, despesa,
-- etapa, funcionário, ponto, material, movimento, foto, orçamento) é uma linha de obra_registros,
-- visível só para o dono. Fotos no bucket privado obra-fotos, pasta = id do usuário.
-- =========================================================

create table if not exists public.obra_registros (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null check (char_length(id) between 1 and 80),
  tabela text not null check (tabela in ('obras','rdos','despesas','etapas','funcionarios','presencas','materiais','movimentos','fotos','orcamentos')),
  obra_id text,
  dados jsonb not null check (octet_length(dados::text) <= 200000),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists obra_registros_tabela on public.obra_registros (user_id, tabela);
alter table public.obra_registros enable row level security;
drop policy if exists "obra_registros_dono" on public.obra_registros;
create policy "obra_registros_dono" on public.obra_registros for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.obra_registros from anon;

-- conta no Foster Obras: dados do profissional e período de teste (o plano só muda pelo servidor)
create table if not exists public.obra_contas (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  nome text check (char_length(nome) <= 120),
  crea text check (char_length(crea) <= 60),
  tel text check (char_length(tel) <= 30),
  plano text not null default 'trial',
  trial_inicio timestamptz not null default now(),
  plano_ate timestamptz,
  criado_em timestamptz not null default now()
);
alter table public.obra_contas enable row level security;
drop policy if exists "obra_contas_dono" on public.obra_contas;
create policy "obra_contas_dono" on public.obra_contas for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.obra_contas from anon, authenticated;
grant select on public.obra_contas to authenticated;
grant insert (user_id, nome, crea, tel) on public.obra_contas to authenticated;
grant update (nome, crea, tel) on public.obra_contas to authenticated;

-- fotos: bucket privado, cada usuário só na própria pasta
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('obra-fotos', 'obra-fotos', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "obra_fotos_dono_ler" on storage.objects;
drop policy if exists "obra_fotos_dono_enviar" on storage.objects;
drop policy if exists "obra_fotos_dono_apagar" on storage.objects;
create policy "obra_fotos_dono_ler" on storage.objects for select to authenticated
  using (bucket_id = 'obra-fotos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "obra_fotos_dono_enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'obra-fotos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "obra_fotos_dono_apagar" on storage.objects for delete to authenticated
  using (bucket_id = 'obra-fotos' and (storage.foldername(name))[1] = auth.uid()::text);
