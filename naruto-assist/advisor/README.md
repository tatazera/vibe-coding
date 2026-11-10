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

## Politica de compra (politica.json)
Define o padrao do jogo: itens iniciais (Ninja Headband, Bingo Book), consumiveis de farm (Oil, Bomb, Edo Tensei Scroll),
nucleo (Jade of Susano'o, The Heaven Mirror), linha de evolucao da roupa (Genin -> ... -> Sannin -> Kage Robe),
itens situacionais (Akatsuki*, armas da Legendary Equipment Shop) e herois com bota essencial / arma elemental.
Pode ser editada dentro do proprio site (caixa "Editar a politica de compra") ou no arquivo antes de gerar o site.

## Correcao importante
"+10 Taijutsu x Level" nas armas Battle e o nivel DA ARMA (Level 3 = x3), nao o nivel do heroi.

## Como fazer cada item (criacao)
`montar_dados.py` gera `criacao` para os 307 itens (compra / upgrade / combinar) a partir das receitas do mapa e de regras inferidas:
Battle Level n = Level n-1 + Upgrade Weapon; elemental = Weapon Lv1 + Soul Absorb Stone + Spirit + taxa; lendaria = Battle MAX + pedra + spirit;
roupa = Genin + Upgrade Cloth; botas = Shippu + variante + Upgrade Super Boots. Validacao: 117 regras fecham exatamente com o preco de tabela;
as demais divergem por valor fixo (ex.: Explosive/Fuuma/Dance -1500; Totsuka +3000) e a tela mostra as duas contas.
Soul Absorb Stone nao tem preco no mapa; 1000 e o valor que faz as somas fecharem (marcado como inferido).

## Padroes de jogo informados (politica.json)
Arma elemental padrao: Tai = Fire, Nin = Thunder, Gen = Water (outros elementos = situacionais).
Loja lendaria (situacionais): Sanbi, Mirrored Shield, Kusanagi, Sword of Totsuka, Triple-Bladed, Executioner's Blade, Samehada, Chakra Blades, Stone of Gelel.
Ordem de skills: fase de farm (maior dano base inicial primeiro) e fase de escala (skills que escalam com Tai/Nin/Gen); ultimates assim que liberadas.
