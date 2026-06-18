# STAND1_Memorial — Plugin SketchUp

Gera o **Memorial Descritivo** (PDF e cópia de texto) a partir dos componentes de um
modelo SketchUp, com a identidade visual da Stand1 Produções.

## Instalação
1. No SketchUp: **Janela → Extension Manager → Install Extension**.
2. Selecione `STAND1_Memorial_v6.0.0.rbz`.
3. O comando aparece no menu **Extensões/Plugins** e na barra de ferramentas.

## Estrutura
- `STAND1_Memorial_loader.rb` — registrador da extensão.
- `STAND1_Memorial/core.rb` — lógica principal (coleta, dimensões, áreas, export).
- `STAND1_Memorial/dialog.html` — interface (HtmlDialog) e geração do PDF.
- `STAND1_Memorial/dimensoes.rb` — módulo puro de cálculo de dimensões (testável).
- `STAND1_Memorial/tests/test_dimensoes.rb` — testes (`ruby tests/test_dimensoes.rb`).
- `STAND1_Memorial_v6.0.0.rbz` — pacote pronto para instalar.

## Principais recursos
- Dimensões reais por peça (escala acumulada, rotação ignorada; altura no eixo Z).
- Áreas por seção: piso (L×P), comunicação visual, paredes/sancas em L
  (área real das faces revestidas, uma por plano), etc.
- Listas de palavras-chave editáveis (M Linear, Mobiliário, Revestimentos, Linear×Altura).
- Exportação de PDF (modelo cotação Stand1, fonte Lato embutida) e botão **Copiar**.
- Estado salvo por projeto, dark mode, edição inline, arrastar-e-soltar.
