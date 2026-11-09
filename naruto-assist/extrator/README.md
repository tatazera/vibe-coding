# Extrator de dados do mapa (.w3x)

Le o mapa do Warcraft III e gera um `.zip` pequeno (so texto) com itens, unidades,
habilidades e scripts, para montar o sugestor de builds. Nao precisa instalar nada
alem do Python 3.8+ (https://www.python.org, marque "Add Python to PATH").

## Usar (Windows)
1. Baixe `extrair_mapa.py`.
2. Abra o Prompt de Comando na pasta do arquivo e rode:

```
python extrair_mapa.py "C:\caminho\NarutoNinpouReforged.w3x"
```

   (ou rode `python extrair_mapa.py` e arraste o .w3x para a janela).
3. No fim ele mostra o caminho de `saida_naruto.zip` (poucos KB/MB). Envie esse zip no chat.

O mapa de 200 MB **nao precisa ser enviado**: so o zip.

## Se o mapa for protegido
Se o `resumo.txt` disser "Nada util foi lido", extraia os arquivos com o MPQ Editor do
Ladik (http://www.zezula.net/en/mpq/download.html), selecione tudo (ou so os `war3map.*`
e `*.txt`), extraia para uma pasta e rode:

```
python extrair_mapa.py --pasta "C:\mapa_extraido"
```

## O que sai no zip
`unidades.json`, `itens.json`, `habilidades.json`, `buffs.json`, `upgrades.json`,
`strings.json`, `scripts/` (war3map.j/lua, onde ficam as formulas de dano),
`pistas_atributos.txt` (linhas que citam Taijutsu/Ninjutsu/Genjutsu), `resumo.txt`.

Teste interno: `python teste_extrator.py`.
