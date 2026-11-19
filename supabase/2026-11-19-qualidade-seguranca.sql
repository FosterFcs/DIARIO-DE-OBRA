-- =========================================================
-- Foster Obras · 2026-11-19 · QUALIDADE E SEGURANÇA
-- Novos tipos de registro:
--   checklists     · FVS (verificação de serviço) e FVM (recebimento de material)
--   modelos_check  · modelos de checklist da empresa (sem obra: valem para todas)
--   dds            · Diálogo Diário de Segurança com participantes
--   seguranca      · acidentes, quase-acidentes e condições inseguras, com ação corretiva
-- Permissões:
--   engenheiro  · tudo
--   encarregado · lança checklists, DDS e ocorrências de segurança; lê os modelos
--   cliente     · consulta os checklists (qualidade) — não vê DDS nem ocorrências
-- =========================================================

alter table public.obra_registros drop constraint if exists obra_registros_tabela_check;
alter table public.obra_registros add constraint obra_registros_tabela_check
  check (tabela in ('obras','rdos','despesas','etapas','funcionarios','presencas','materiais','movimentos','fotos','orcamentos','medicoes','perfil',
                    'checklists','modelos_check','dds','seguranca'));

create or replace function public.obra_permite(p_dono uuid, p_tabela text, p_obra text, p_id text, p_acao text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.obra_membros m
    where m.dono_id = p_dono and m.membro_id = auth.uid()
      -- recorte por obra (dados da empresa e modelos de checklist aparecem para todos, só para leitura)
      and (m.obras is null
           or (case when p_tabela = 'obras' then p_id else p_obra end) = any (m.obras)
           or (p_tabela in ('perfil','modelos_check') and p_acao = 'ler'))
      and case m.papel
        when 'engenheiro' then
          case p_acao when 'ler' then true
                      when 'gravar' then p_tabela <> 'perfil'
                      else p_tabela not in ('obras','perfil') end
        when 'encarregado' then
          case p_acao when 'ler' then p_tabela in ('obras','rdos','etapas','funcionarios','presencas','materiais','movimentos','fotos','perfil',
                                                   'checklists','modelos_check','dds','seguranca')
                      when 'gravar' then p_tabela in ('rdos','presencas','fotos','movimentos','checklists','dds','seguranca')
                      else p_tabela in ('presencas','fotos','movimentos') end
        when 'cliente' then
          p_acao = 'ler' and p_tabela in ('obras','rdos','etapas','fotos','medicoes','perfil','checklists')
        else false end
  );
$$;
revoke all on function public.obra_permite(uuid, text, text, text, text) from public, anon;
grant execute on function public.obra_permite(uuid, text, text, text, text) to authenticated;
