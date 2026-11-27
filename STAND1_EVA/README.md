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

### Mapa de Artes — um quadro por ambiente, cotado e com quantidade
No formato do mapa de artes de conferência e produção: cada peça de comunicação visual de
frente, com as medidas e a quantidade.
- **Ler ambientes** (botão; abrir a aba não lê nada): acha as peças de adesivo, lona, PVC,
  letra caixa e correlatos e separa os **ambientes pela distância** entre elas (*Distância
  entre ambientes*, padrão 3 m; estande único num arquivo vira um ambiente só). O nome de
  cada ambiente vem da **cena que olha para ele** (vista geral distante não conta) e pode ser
  editado; sem cena, "AMBIENTE N"
- **Não trava:** componente repetido é lido uma vez só (150 estandes iguais = 1 leitura),
  grupos sem arte são pulados sem abrir, e a leitura tem limite de tempo e de peças: passou,
  para e avisa. O desenho é feito em etapas, com progresso e **Cancelar**
- **Peças:** faces vizinhas no mesmo plano e do mesmo material viram **uma peça** (módulos
  aparecem como linhas); recortes (porta, nicho de TV) entram como furo; faces mais estreitas
  que a *Largura mínima* (padrão 3 cm) são espessura e ficam de fora; chapa de PVC/ACM conta
  uma vez; placa impressa dos dois lados (3 a 30 cm) vira **FRENTE E VERSO**; peças iguais
  (nome, material, medida ±1 cm) viram um desenho **"– N und."**. Face sem material herda o
  material do grupo; ocultos e tags desligadas não entram
- **Nome da peça:** o grupo/componente com nome mais próximo da face (ex.: "BACKDROP
  CREDENCIAMENTO"); sem nome, o material
- **Desenho:** grupo "KV - Mapa de Artes" (tag KV), um quadro por ambiente à esquerda do
  modelo, lido pela vista **Frente**: título, largura no topo, altura à esquerda, **cotas em
  corrente dos recortes** (vertical à esquerda, horizontal na base) e etiqueta
  *NOME – N und.* / *material · L x A m*, com texto proporcional ao quadro. Refeito a cada
  geração; um Ctrl+Z desfaz tudo
- **Diagramar seleção:** um quadro só com o que está selecionado (sem arte na seleção, vale
  qualquer material). **Girar 90°** gira o item do KV selecionado
- Ainda não faz: apliques em PVC desenhados sobre o painel com cotas de posição até o piso
  (próxima etapa)

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
    ├── mapa_artes.rb         # mapa de artes: leitura, peças, ambientes, quadros e cotas
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

---

© 2025 Stand1 Produções
