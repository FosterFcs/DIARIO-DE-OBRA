<img width="180" height="180" alt="apple-touch-icon" src="https://github.com/user-attachments/assets/02fe087d-b40e-4227-b9d1-367ea33af7e3" />

# Foster Obras — Gestão de Obras Digital

PWA (arquivo único) para engenheiros, arquitetos e construtoras. Publicado em **fosterfcs.github.io/DIARIO-DE-OBRA**.

## Módulos
- **Obras** — painel com alertas (etapas atrasadas, contas a vencer, estoque baixo, RDO do dia, orçamento estourado).
- **RDO** — clima manhã/tarde, condição de trabalho, efetivo (preenchido pelo ponto), fotos com carimbo de data/hora/GPS, assinatura digital do RT e do cliente, PDF e WhatsApp.
  - **Link de aprovação** (`aprovar.html`): o cliente/fiscal abre no celular, sem login, e aprova com assinatura ou registra ressalva.
  - **Selo de integridade**: ao assinar, o servidor grava a hora oficial e um hash SHA-256 do conteúdo; o PDF traz código + QR para `verificar.html`. RDO assinado não muda (é preciso reabrir) e não é excluído (só cancelado, com motivo). Histórico de versões no servidor.
  - **Estruturado**: avanço por etapa (vai para o cronograma e a curva S), materiais aplicados (baixa no estoque) e equipamentos com horas.
  - **Clima automático** (Open-Meteo, pelo local da obra), **copiar o último RDO**, **ditado por voz** e **texto livre** com IA, **resumo semanal com IA**.
- **Qualidade e SST** — FVS/FVM com 15 modelos de referência (e modelos próprios da empresa), não conformidades com correção, DDS com lista de presença, acidentes/quase-acidentes com ação corretiva e prazo, dias sem acidente.
- **Lembretes** — RDO do dia pendente e alertas urgentes no celular (com o app instalado ou aberto).
- **Equipe** (aba Conta) — o titular convida engenheiro, encarregado ou cliente por e-mail, para todas ou algumas obras. O plano que vale é o do titular.
- **Financeiro** — despesas e receitas, a pagar/a receber com vencimento, comprovante em foto, custo por etapa, fluxo de 6 meses, planilha CSV.
- **Cronograma** — etapas, Gantt, curva S (previsto × realizado), avanço ponderado, cronograma padrão.
- **Medição** — boletim por item do orçamento (anterior, período, acumulado, saldo, retenção), aprovação com assinatura e lançamento a receber.
- **Orçamento** — grupos, código SINAPI/próprio, BDI, colar do Excel, proposta em PDF com a marca do usuário.
- **Equipe** — chamada do dia, ponto, horas extras, folha de diaristas, EPIs, CPF validado.
- **Estoque** — saldo calculado pelas movimentações, alerta de mínimo, entrada lançada no financeiro.
- **Fotos / Relatórios / Conta** — relatório fotográfico, relatório de obra por período, dados da empresa (logo nos PDFs), plano com PIX, backup JSON/CSV.

## Técnico
- `index.html` — app completo. Dados: Supabase (projeto **foster-calc**, tabela `obra_registros`), cópia local + fila offline; fotos em IndexedDB até enviar.
- `sw.js` — service worker: o app abre sem internet.
- `qrcode.min.js` — gerador de QR Code (MIT) para o PIX.
- `aprovar.html` / `verificar.html` — páginas públicas (aprovação do RDO pelo link e verificação do código).
- `supabase/` — migrações. O plano é validado no servidor (RLS): sem teste/plano ativo a conta só lê.
  - `2026-11-18a-equipe.sql` — equipe e papéis (`obra_membros`, `obra_convites`, `obra_permite`), políticas por papel nos registros e nas fotos.
  - `2026-11-19-qualidade-seguranca.sql` — tipos `checklists`, `modelos_check`, `dds`, `seguranca` e permissões por papel.
  - `functions/obra-ia` — Edge Function da IA (Groq: Whisper + Llama), exige login e plano ativo da conta aberta.
  - `2026-11-18b-rdo-integridade.sql` — gatilho `obra_registros_guarda` (autoria, hora do servidor, selo, trava, cancelamento, histórico), `obra_links`, `obra_rdo_verificar`.

### Papéis da equipe
| Papel | Vê | Lança |
|---|---|---|
| Engenheiro | tudo | tudo, menos dados da empresa; assina como RT; não exclui obras |
| Encarregado | obras, RDO, cronograma, equipe, estoque, fotos | RDO, chamada/ponto, fotos, movimentação de estoque (não assina como RT) |
| Cliente/fiscal | obras, RDO, cronograma, fotos, medições | nada (aprova pelo link) — não conta no limite do plano |

Limite de pessoas na equipe (sem contar clientes): teste 2 · Básico 1 · Profissional 5 · Empresa ilimitado.

### Liberar um cliente manualmente (o PIX via Asaas já libera sozinho — use só em exceções)
```sql
update public.obra_contas c set plano = 'profissional', plano_ate = now() + interval '1 month'
from auth.users u where u.id = c.user_id and lower(u.email) = 'email@do.cliente';
-- planos: basico (3 obras) · profissional (10) · empresa (ilimitado)
```
