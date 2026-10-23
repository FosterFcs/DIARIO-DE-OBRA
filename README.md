<img width="180" height="180" alt="apple-touch-icon" src="https://github.com/user-attachments/assets/02fe087d-b40e-4227-b9d1-367ea33af7e3" />

# Foster Obras — Gestão de Obras Digital

PWA (arquivo único) para engenheiros, arquitetos e construtoras. Publicado em **fosterfcs.github.io/DIARIO-DE-OBRA**.

## Módulos
- **Obras** — painel com alertas (etapas atrasadas, contas a vencer, estoque baixo, RDO do dia, orçamento estourado).
- **RDO** — clima manhã/tarde, condição de trabalho, efetivo (preenchido pelo ponto), fotos com carimbo de data/hora/GPS, assinatura digital do RT e do cliente, PDF e WhatsApp.
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
- `supabase/` — migrações. O plano é validado no servidor (RLS): sem teste/plano ativo a conta só lê.

### Liberar um cliente após o PIX (SQL Editor do Supabase)
```sql
update public.obra_contas c set plano = 'profissional', plano_ate = now() + interval '1 month'
from auth.users u where u.id = c.user_id and lower(u.email) = 'email@do.cliente';
-- planos: basico (3 obras) · profissional (10) · empresa (ilimitado)
```
