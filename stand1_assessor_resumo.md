
# Stand1 — Assessor Pessoal & Dashboard de Projetos
**Resumo de desenvolvimento — sessão Claude**
Data: 11/06/2026

---

## 1. Visão geral do sistema

Sistema de gestão de entrada de projetos para a Stand1 Produções, com duas camadas:

- **Dashboard web** — interface visual de controle manual de projetos
- **Automação WhatsApp** — captura de mensagens de um grupo específico e criação automática de projetos

O sistema funciona **perfeitamente nos dois modos**: uso 100% manual ou com automação via WhatsApp ativada. A decisão de conectar a API pode ser feita posteriormente sem precisar refazer o dashboard.

---

## 2. Contexto da empresa

- **Empresa:** Stand1 Produções
- **Segmento:** Montadora de stands, cenografia e backstage
- **Localização:** Lauro de Freitas / Salvador, BA
- **Site:** https://www.stand1.com.br
- **Cor primária:** `#2B6DB8` (azul)
- **Tagline:** "Do projeto ao espetáculo"

### Equipe de projetos
| Código | Nome | Avatar |
|--------|------|--------|
| 1. TARCISIO | Tarcisio Vieira | TC |
| 2. FAGNER | Fagner | FG |
| 3. GABRIEL | Gabriel | GB |

### Responsáveis pelo desenho técnico
Júnior, Tay, Francine, Júnior-ALT, Francine-2

---

## 3. Sistema atual (referência)

O sistema atual usado é o **Monsi ERP**, aba Gerenciador de Projetos.

### Estrutura de campos identificada
| Campo | Descrição |
|-------|-----------|
| Projeto | Nome do cliente + evento + ano (ex: CHOCOLAT BAHIA ILHEÚS 2026) |
| Serviço | Número + nome do projetista (ex: 1. TARCISIO) |
| Status | Na Fila / Em andamento |
| Prioridade | Nula / Média / Alta |
| Observação | Campo livre — responsável pelo desenho técnico |

---

## 4. Estrutura do dashboard

### 4.1 Campos por projeto
- **Nome do projeto**
- **Projetista responsável** (seletor: Tarcisio / Fagner / Gabriel)
- **Solicitante** (quem pediu o projeto)
- **Status** (Na fila / Em andamento / Concluído)
- **Prioridade** (Nula / Média / Alta)
- **Responsável pelo desenho técnico**
- **Observações** (campo livre, texto longo)
- **Origem** (manual ou WhatsApp — badge identificador)
- **Log de movimentações** (automático: data/hora de cada alteração)

### 4.2 Abas
1. **Projetos** — lista de projetos ativos (Na fila + Em andamento)
2. **Concluídos** — histórico com ficha completa e log de movimentações
3. **Entradas WhatsApp** — mensagens pendentes para virar projetos

### 4.3 Modos de visualização
- **Cards** — visual com badge de status colorido e barra de acento por status
- **Tabela/Lista** — colunas compactas para visualização densa

### 4.4 Filtros disponíveis
- Todos / Na fila / Em andamento / Alta prioridade
- Busca por nome do projeto ou solicitante

### 4.5 Ações por projeto
| Status atual | Ações disponíveis |
|---|---|
| Na fila | Iniciar → Em andamento / Editar / Excluir |
| Em andamento | Concluir / Pausar (volta pra fila) / Editar / Excluir |
| Concluído (aba histórico) | Reabrir (volta pra fila) / Remover do histórico |

### 4.6 Entradas WhatsApp
Cada entrada exibe:
- Nome do remetente + badge "WhatsApp"
- Mensagem original
- Dados extraídos: projeto, prioridade, responsável pelo desenho
- Ações: **Criar projeto** (rodízio automático) / **Editar antes** (abre modal) / **Ignorar**

---

## 5. Distribuição automática de projetos

Projetos criados via WhatsApp são distribuídos em **rodízio igualitário**:
```
1. TARCISIO → 2. FAGNER → 3. GABRIEL → 1. TARCISIO → ...
```

Evolução prevista: distribuição por **balanceamento de carga real** (quem tem menos projetos ativos recebe o próximo).

---

## 6. Histórico e rastreabilidade

Todo projeto possui um **log automático** com registro de:
- Criação (com solicitante)
- Alterações de status
- Edições
- Conclusão
- Reabertura

Projetos concluídos ficam na aba **Concluídos** com ficha completa. Podem ser reabertos a qualquer momento — o log preserva todo o histórico incluindo após a reabertura.

---

## 7. Stack técnica planejada

### Para uso manual apenas
- Dashboard em **HTML/CSS/JS puro** — sem dependências externas
- Pode ser hospedado em qualquer servidor ou aberto como arquivo local

### Para automação com WhatsApp
| Componente | Ferramenta | Função |
|---|---|---|
| Captura WhatsApp | Evolution API (gratuita) ou Z-API (paga) | Lê mensagens do grupo e dispara webhook |
| Orquestrador | n8n (self-hosted, gratuito) | Recebe webhook, processa, chama IA |
| Inteligência | Claude API | Extrai dados da mensagem: nome, prioridade, responsável |
| Dashboard | HTML/JS hospedado | Recebe os projetos e exibe |
| Notificação | WhatsApp (via mesma API) | Confirma entrada e responsável designado |

### Custo estimado (automação completa)
- R$ 80–150/mês (hospedagem + Z-API ou Evolution)
- n8n: gratuito em self-hosted

---

## 8. Identidade visual

### Cores definidas (Stand1)
```css
--s1-blue: #2B6DB8;
--s1-blue-hover: #185FA5;
--s1-blue-light: #E6F1FB;
--wpp-green: #25D366;
```

### Badges de status
```css
/* Na fila */
background: #F1EFE8; color: #5F5E5A;

/* Em andamento */
background: #E6F1FB; color: #185FA5;

/* Concluído */
background: #EAF3DE; color: #3B6D11;

/* Alta prioridade */
background: #FAECE7; color: #993C1D;

/* Média prioridade */
background: #FAEEDA; color: #854F0B;

/* WhatsApp badge */
background: #25D366; color: #fff;
```

### Avatares da equipe
```css
/* Tarcisio */
background: #E6F1FB; color: #185FA5;

/* Fagner */
background: #EAF3DE; color: #3B6D11;

/* Gabriel */
background: #FAECE7; color: #993C1D;
```

> **Pendente:** aplicar CSS da identidade visual do plugin SketchUp desenvolvido anteriormente. Tarcisio vai enviar o arquivo CSS para integração.

---

## 9. Próximos passos

- [ ] Tarcisio envia o CSS do plugin SketchUp com a identidade visual
- [ ] Aplicar identidade visual no dashboard
- [ ] Definir hospedagem (servidor próprio ou domínio stand1.com.br)
- [ ] Decidir rota WhatsApp: Evolution API (self-hosted) ou Z-API (gerenciado)
- [ ] Montar fluxo n8n para automação completa
- [ ] Implementar balanceamento de carga real na distribuição de projetos
- [ ] Adicionar campo de prazo/deadline nos projetos
- [ ] Avaliar integração com Monsi ERP ou substituição completa

---

## 10. Arquivos gerados nessa sessão

| Arquivo | Descrição |
|---|---|
| `stand1_dashboard_v4` | Dashboard completo em HTML/JS — versão final da sessão |
| `stand1_assessor_resumo.md` | Este arquivo |

---

*Gerado por Claude Sonnet 4.6 — Stand1 Produções / Tarcisio Vieira*
