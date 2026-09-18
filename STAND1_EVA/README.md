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
- Crop por cena com editor visual
- Export em lote; restaura as configurações originais do modelo ao final

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

---

## Instalação

1. Baixe o `.rbz` mais recente (`STAND1_EVA_v2.1.0.rbz`)
2. No SketchUp: **Extensions → Extension Manager → Install Extension**
3. Selecione o `.rbz` e reinicie o SketchUp
4. Menu: **Plugins → STAND1 → EVA Stand1** (ou o botão na toolbar)

Na toolbar há dois botões: **EVA Stand1** (abre o diálogo) e **Mapa de Artes**
(varredura automática, ícone com as cores invertidas para diferenciar).

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
