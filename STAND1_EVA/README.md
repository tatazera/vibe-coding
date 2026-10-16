# EVA Stand1

Plugin SketchUp 2026 da **Stand1 Produções**. Quatro abas, um fluxo: exportar as
Scenes, gerar os prompts de render com IA (**Nano Banana** / Google Gemini),
tratar as logos e diagramar o **Mapa de Artes**.

Substitui o fluxo manual: SketchUp → export → fundo no Canva → prompt manual → DeepL.

---

## Abas

### Render IA — gerador de prompts
- Um prompt por Scene marcada, ancorado no PNG exportado (imagem + texto no Nano Banana)
- Leitura automática da câmera de cada Scene (altura, ângulo, FOV) e da paleta do projeto
- Tipo de estande, ambiente do render, iluminação e público
- CRITICALs gerais (todas as cenas) e por cena, salvos por projeto
- Override manual do ângulo, quando a leitura automática erra
- Copiar individual, copiar todos ou salvar em `.txt`

### Apresentação — exportador de Scenes
- Resolução 4K padrão (2K / FHD / HD ou customizada): você define a largura e a
  altura acompanha o enquadramento da vista, para o PNG sair exatamente como a cena mostra
- Fundo branco / preto / transparente, sombras desativadas, eixos e anotações ocultos
- Export em lote, uma cena por vez, com o nome do arquivo em andamento no rodapé
- Restaura as configurações originais do modelo ao final

### Logos — tratamento de imagem
- Remoção de fundo via API remove.bg (chave persistida em `%APPDATA%/STAND1_EVA`)
- Recolorir a logo com cor sólida preservando a transparência
- Conta-gotas global (captura a cor de qualquer pixel da tela, dentro ou fora do SketchUp)
- Drag-and-drop de PNG/JPEG e exportação do PNG final

### Mapa de Artes — diagramação + cotas
- **Varredura:** lista os materiais de arte do modelo (adesivo, lona, PVC, letra caixa e
  correlatos) com nº de faces e área em m²; você marca o que quer diagramar
- **Seleção:** reconhece faces, **grupos e componentes** selecionados no SketchUp, vários de
  uma vez
- Cada face é **copiada** (o modelo real não muda), posta de frente, arranjada (peças à
  esquerda, paredes em fileiras), cotada L×A com cotas nativas e etiquetada com nome e medida
- O quadro nasce à **esquerda do modelo**, alinhado ao eixo do estande; nenhuma cena é criada
  automaticamente — você enquadra e salva a cena do seu jeito
- Um Ctrl+Z desfaz tudo

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
  instalada; senão Arial) e cor do texto configurável
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
    ├── prompt_builder.rb     # leitura de câmera/materiais + montagem do prompt
    ├── mapa_artes.rb         # varredura, diagramação e cotas do KV
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
