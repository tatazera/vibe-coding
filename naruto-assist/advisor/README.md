# Sugestor de builds

- `montar_dados.py <pasta saida_naruto>` -> `dados.json` (herois, skills com formulas, itens com bonus).
- `gerar_site.py` -> `sugestor_builds.html` (arquivo unico; abre com dois cliques, sem internet).

## Modelo (calibrado com o jogo)
Taijutsu = Forca, Ninjutsu = Agilidade, Genjutsu = Inteligencia.
Atributo = base + crescimento x (nivel - 1). Vida = 100 + 24 x Tai. Chakra max = 15 x Gen.
Armadura = 2 + 0,15 x Nin. Dano = base (2-24) + atributo principal. Conferido com Yamato nivel 9
(36/34/47, 964 HP, 705 chakra, armadura 7, dano 49-71).

## Limites conhecidos
- Vagas de item, limites por tipo e nivel das skills por nivel do heroi sao suposicoes editaveis.
- ~18% das skills tem dano descrito em texto livre e ficam sem calculo; ~15% sao aproximadas (marcadas com "≈").
- Efeitos ativos de itens (auras, escudos, stuns) aparecem como texto, nao entram na pontuacao.
