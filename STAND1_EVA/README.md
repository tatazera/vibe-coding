# EVA Stand1

Plugin SketchUp 2026 da **Stand1 Produções** que padroniza o export de Scenes e gera prompts para render com IA (**Nano Banana 2** / Google Gemini).

Substitui o fluxo manual: SketchUp → export → fundo no Canva → prompt manual → DeepL.

---

## Funcionalidades

### Fase 1 — Exportador de Scenes
- Lista todas as Scenes do modelo com seleção por checkbox
- Resolução 4K padrão (2K / FHD / HD ou customizada)
- Estilo: **Flat puro** ou **Com texturas**
- Fundo: **Preto sólido** ou **Transparente**
- Export em lote, sombras desativadas, eixos/anotações ocultos
- Restaura automaticamente as configurações originais do modelo

### Fase 2 — Gerador de Prompts
- Leitura automática dos materiais aplicados (traduzidos PT→EN via dicionário)
- Câmera de cada Scene convertida em linguagem fotográfica (altura, ângulo, FOV)
- Seletor de iluminação: Branco Frio / Branco Quente
- Campo de CRITICALs em PT (traduzidos automaticamente)
- Toggle de idioma EN / PT
- Um prompt por Scene, com botão Copiar individual

---

## Instalação

1. Baixe o arquivo `STAND1_EVA_v1.0.0.rbz`
2. No SketchUp: **Extensions → Extension Manager → Install Extension**
3. Selecione o `.rbz` e reinicie o SketchUp
4. Menu: **Plugins → STAND1 → EVA — Render (Export / Prompts)**

O plugin checa atualizações automaticamente ao abrir (via GitHub).

---

## Desenvolvimento

Estrutura:

```
STAND1_EVA/
├── build.ps1                 # empacota o .rbz e atualiza latest.json
├── latest.json               # manifesto de auto-update
├── STAND1_EVA_loader.rb      # registra a extension
└── STAND1_EVA/
    ├── core.rb               # dialog + callbacks
    ├── dictionary.rb         # dicionário PT→EN
    ├── exporter.rb           # export padronizado de Scenes
    ├── prompt_builder.rb     # leitura de câmera/materiais + montagem do prompt
    ├── autoupdate.rb         # checagem/instalação de update via GitHub
    └── html/
        └── dialog.html       # interface (identidade visual Stand1)
```

**Build:**

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Gera o `.rbz` versionado e atualiza o `latest.json`. A versão é lida de `PLUGIN_VERSION` no loader.

---

© 2025 Stand1 Produções
