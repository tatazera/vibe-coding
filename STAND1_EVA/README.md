# EVA Stand1

Plugin SketchUp 2026 da **Stand1 Produções**. Quatro abas, um fluxo: exportar as
Scenes, gerar os prompts de render com IA (**Nano Banana** / Google Gemini),
tratar as logos e diagramar o **Mapa de Artes**.

Substitui o fluxo manual: SketchUp → export → fundo no Canva → prompt manual → DeepL.

---

## Abas

### Render IA — gerador de prompts
Um prompt curto, em português, para colar no **Nano Banana** junto do PNG exportado da cena.
A câmera e a geometria vêm da imagem: o texto não descreve ângulo nem o estande. Todo estande
é tratado como **interno** (prompt externo é feito à parte).
- **Base fixa**, igual em todos os projetos: pavilhão tecnológico, teto em grid metálico preto,
  luminárias LED, sem estruturas aéreas, sem alterar a geometria
- **Alternâncias a cada render:** branco frio ou quente, com ou sem público
- **Ajustes gerais:** frases do projeto inteiro, uma por linha (piso, materiais...). Salvos por projeto
- **Ajustes da cena:** só daquela vista, somados aos gerais. Linhas "elemento → por" (ex.: *linhas
  amarelas das colunas → fita LED branco frio*) ou só a frase livre. Ficam salvos na própria cena,
  dentro do arquivo do SketchUp (os antigos CRITICALs por cena foram migrados para cá)
- O prompt se atualiza sozinho a cada mudança. Clique numa cena para editá-la; marque as cenas
  para **Copiar marcadas** (ou **Salvar .txt**). **Copiar** no card copia só a cena em edição

### Apresentação — exportador de Scenes
- Resolução 4K padrão (2K / FHD / HD ou customizada): você define a largura e a
  altura acompanha o enquadramento da vista, para o PNG sair exatamente como a cena mostra
- Fundo branco / preto / transparente
- Cenas com proporção própria (as pranchas 16:9 do Mapa de Artes) exportam exatamente em 16:9
- **Estilo do print:** *Como está na cena* (padrão) grava a cena exatamente como está no SketchUp.
  *Otimizado para IA* muda o estilo **só durante o export** (nada é salvo na cena): sombras off,
  texturas on, sem perfis, profundidade, extensão, pontas e tremido de linha, sem geometria oculta,
  guias, névoa, marca d'água, céu, chão e horizonte. Arestas finas ficam (separam planos de mesma
  cor); a opção *Sem linhas* esconde todas. A escolha fica salva
- Opções de estilo que não existirem na sua versão do SketchUp são ignoradas e listadas nos avisos
  ao fim do export
- Export em lote, uma cena por vez, com o nome do arquivo em andamento no rodapé
- Restaura as configurações originais do modelo ao final

### Logos — tratamento de imagem
- Remoção de fundo via API remove.bg (chave persistida em `%APPDATA%/STAND1_EVA`)
- Recolorir a logo com cor sólida preservando a transparência
- Conta-gotas global (captura a cor de qualquer pixel da tela, dentro ou fora do SketchUp)
- Drag-and-drop de PNG/JPEG e exportação do PNG final

### Mapa de Artes — pranchas 16:9 por ambiente, ligadas ao modelo
Você marca a arte; o EVA mede, cota, diagrama e acompanha as mudanças do projeto.
- **Marcação manual (nada é deduzido do nome do material):** selecione no SketchUp uma **face**
  (clique triplo pega as vizinhas), um **grupo** ou um **componente** — vários de uma vez, ou dentro
  de um grupo aberto. O painel mostra **ao vivo** a medida, a forma (com recortes) e avisa se a
  seleção já está na lista. Dê o nome (ou clique num nome rápido: TESTEIRA FRONTAL, PAREDE FUNDO,
  LOGO PVC...), a **quantidade** e **frente e verso** — digitados por você, o plugin não conta nada —
  e uma observação opcional. Cada grupo/componente e cada conjunto de faces coplanares vira uma peça
- **Ambientes:** você cria e nomeia (barra lateral); tudo que adicionar entra no ambiente ativo, e é
  esse vínculo (não a posição no modelo nem o nome) que separa o Credenciamento da Plenária: cada
  peça carrega o ambiente, e as alterações são lidas peça a peça e agrupadas por ambiente.
  Mover uma peça de ambiente é um clique. Funciona igual num arquivo com vários ambientes ou num só
- **Ambiente sugerido pela cena ativa:** se a cena ativa do SketchUp tem o nome de um ambiente (acento,
  caixa e pontuação não contam; "01 CREDENCIAMENTO - vista 2" e "ARTES - 01 CREDENCIAMENTO" servem), o
  destino já vem marcado ("→ 08 PLENÁRIA · pela cena") e a lista pula para ele ao adicionar. Cena que
  cabe em mais de um ambiente não sugere nada. Dá para desligar em "seguir a cena ativa"
- **Nomes rápidos editáveis:** a lista de botões (padrão: o vocabulário do mapa do BTX) é sua — **✎ Nomes**
  edita um por linha (sem repetidos, até 40), **＋ Salvar nome** guarda o que você digitou, **Restaurar
  padrão** volta ao original. Ficam salvos neste computador e valem para todos os projetos
- **Peça ligada ao modelo:** ela guarda a *referência* das faces de origem, não uma cópia da medida.
  **Atualizar do modelo** (e a abertura da aba, e o Gerar) relê as medidas: esticou a testeira, a peça
  acompanha. O painel avisa "modelo alterado" quando o projeto muda
- **Substituir sem refazer:** **⟳ Trocar origem** (selecione a arte nova e clique) mantém nome,
  quantidade e ambiente. Se a face for apagada numa edição, o EVA reencontra a arte pelo objeto que
  a continha; se não achar, a peça fica marcada como *origem perdida* e usa a última medida lida
- **Revisões (R00, R01...):** **Emitir** congela as medidas e quantidades como a revisão enviada.
  Dali em diante cada peça mostra *nova* ou *alterada (antes → depois)*, e a **lista de alterações**
  sai pronta para copiar e mandar à produção, por ambiente ("altura 3,20 → 3,40 m (+0,20)",
  "quantidade 1 → 3 und.", "REMOVIDA"...). Voltar à medida antiga apaga a alteração da lista
- **Gerar:** uma **prancha 16:9 por ambiente** no grupo "KV - Mapa de Artes" (tag KV), à esquerda do
  modelo: título "ARTES - AMBIENTE" e rótulo da revisão, cada peça de frente com largura no topo,
  altura à esquerda, **cotas em corrente dos recortes** e a etiqueta *NOME – 03 und.* /
  *material · L x A m* (+ observação e, em vermelho, o que mudou desde a revisão — opcional). As
  peças são encaixadas no enquadramento 16:9 mais justo, com texto proporcional à prancha
- **Cores do texto:** títulos, etiquetas e rótulo de revisão em **preto**; observações e destaques
  (alteração desde a revisão, origem perdida) em **vermelho**. A cor das cotas segue o estilo de
  dimensões do modelo
- **Cena 16:9 por ambiente:** câmera paralela de frente, proporção 16:9, enquadrando a prancha. Gerar
  de novo atualiza a cena **no lugar** (mesmo nome e posição na lista). A aba Apresentação exporta
  essas cenas exatamente em 16:9
- **Não trava:** a leitura roda só sobre o que você marcou (nunca varre o arquivo inteiro), e o
  desenho é feito em etapas, com progresso e **Cancelar**. Um Ctrl+Z desfaz a geração inteira
- Tudo fica salvo no `.skp` (e num arquivo ao lado, por projeto). O modelo real nunca é alterado
- Ainda não faz: apliques em PVC desenhados sobre o painel com cotas de posição até o piso

### Planta — projeções, grid, elétrica e DXF (aba Apresentação)
Seção **Planta · cenas de topo**, no mesmo fluxo do export. O EVA lê a câmera de cada cena:
topo paralelo = planta; vista paralela horizontal = elevação; isométrica e perspectiva são
ignoradas por essas funções. Cena inclinada mais de 2° avisa em vez de gerar torto.
- **Projeções acima do corte:** contorno tracejado só da tag **ESTRUTURAS** que fica inteira
  acima do plano de corte (testeira, travessas). Mobiliário, equipamentos e comunicação visual
  não entram. Cor configurável
- **Grid 1 m:** só dentro do perímetro do piso (achado na tag ESTRUTURAS), alinhado ao canto e
  à orientação do piso. Cor configurável
- **Elétrica + legenda:** simbologia ABNT (NBR 5444) — refletor = arandela, dicroica = ponto de
  luz no teto, plafon = luminária no teto, tomadas baixa/média/dupla/220 V, ponto de rede, ponto de TV (legenda com h = 1,60 m), quadro
  e caixa de passagem (fita
  LED em traço e ponto, com cor própria) e legenda com quantidades. A fita é lida pelo material
  (como no Memorial), em metros pela mesma conta (área ÷ largura configurada lá). Símbolos com
  miolo branco, todos na mesma escala
- **No export, a planta fica por cima de tudo** (inclusive das paredes cortadas): o corte é
  isolado num grupo temporário, desfeito logo após gravar o PNG. No "Aplicar na cena" ela fica
  logo abaixo do corte (sobre móveis e piso)
- **Pontos elétricos (botão do raio na toolbar, ou ＋ Tomada no painel):** liga/desliga a
  ferramenta sem abrir o EVA. Clique no piso solta um ponto; clique numa tomada existente marca
  para editar (trocar o tipo pela lista/↑↓, girar com ←→, F8 liga o ortogonal). Tamanho: + / − (ou PgUp / PgDn) sem nada marcado muda o
  tamanho padrão de todos os símbolos — tomadas já inseridas, próximas, refletores e dicroicas;
  com tomadas marcadas, só elas. "Padronizar todas" no seletor desfaz as exceções. O
  componente é o próprio símbolo ABNT, na cor da elétrica do projeto. Seletor visual no canto da
  tela, clique direito com os tipos, Esc sai. Guia de
  distância até a tomada vizinha e ponto equidistante com imã; cria
  componentes na tag ELÉTRICA que o Memorial já conta
- **Exportar DXF:** marcado, grava um `.dxf` por cena de topo/vista, em mm e 1:1, com camadas
  `ESTRUTURA`, `PROJECAO` (tracejada), `GRID`, `ELETRICA`, `FITA_LED` (traço e ponto) e `LEGENDA`
- **Legenda em tabela:** símbolo | nome | QTD, símbolos no mesmo tamanho, fonte Barlow (se
  instalada; senão Arial) e cor do texto configurável. Posição escolhida no painel: automática,
  ao lado da planta (direita, esquerda, acima, abaixo) ou num canto da imagem
- **Espessura e tamanho:** linhas, tracejados, símbolos e legenda crescem sozinhos com a altura
  do enquadramento (1× até 4 m, no máximo 8×); o painel multiplica por cima (50% a 300%). Vale
  só para o PNG — o DXF sai em tamanho real
- **Aplicar na cena / Limpar:** mostra o resultado na cena atual e deixa selecionadas as peças
  que geraram projeção
- **Ignorar seleção:** tira (ou devolve) da planta e do DXF as peças selecionadas no SketchUp
- As opções ficam salvas por projeto. Nada roda na abertura do plugin

---

## Instalação

1. Baixe o `.rbz` mais recente (`STAND1_EVA_v2.1.0.rbz`)
2. No SketchUp: **Extensions → Extension Manager → Install Extension**
3. Selecione o `.rbz` e reinicie o SketchUp
4. Menu: **Plugins → STAND1 → EVA Stand1** (ou o botão na toolbar)

Na toolbar há três botões: **EVA Stand1** (abre o diálogo), **Mapa de Artes**
(varredura automática, ícone com as cores invertidas para diferenciar) e **Pontos elétricos**
(ícone branco com raio; fica aceso enquanto a ferramenta está ativa).

O plugin checa atualizações automaticamente ao abrir (via GitHub).

---

## Desenvolvimento

Estrutura:

```
STAND1_EVA/
├── build.ps1                 # empacota o .rbz e atualiza latest.json
├── latest.json               # manifesto de auto-update
├── STAND1_EVA_loader.rb      # registra a extension (fonte da versão)
└── STAND1_EVA/
    ├── core.rb               # dialog + callbacks + menu/toolbar
    ├── dictionary.rb         # dicionário PT→EN
    ├── exporter.rb           # export padronizado de Scenes
    ├── prompt_builder.rb     # montagem do prompt (blocos fixos + ajustes e substituições)
    ├── mapa_artes.rb         # mapa de artes: peças ligadas ao modelo, revisões, pranchas 16:9 e cenas
    ├── planta.rb             # projeções, grid, elétrica, tomadas e DXF
    ├── autoupdate.rb         # checagem/instalação de update via GitHub
    ├── icons/                # ícones da toolbar (EVA e Mapa de Artes)
    └── html/
        └── dialog.html       # interface (identidade visual Stand1)
```

**Build:**

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Gera o `.rbz` versionado e atualiza o `latest.json`. A versão é lida de
`eva_ext.version` no loader.

Sem PowerShell (macOS, Linux ou publicação pelo Claude), use o equivalente em Python — faz o
mesmo e ainda confere o pacote antes de mexer no `latest.json`:

```bash
python3 STAND1_EVA/build.py --notas "o que mudou nesta versão"
```

O passo a passo completo de publicação (build, commit e push no `main`) está no `CLAUDE.md`.

---

© 2025 Stand1 Produções
