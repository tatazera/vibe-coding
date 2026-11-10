# Ninpou Reforged Builds (antigo "Sugestor de builds")

- `montar_dados.py <pasta saida_naruto>` -> `dados.json` (herois, skills com formulas, itens com bonus).
- `gerar_site.py` -> `Ninpou_Reforged_Builds_<versao>.html` (arquivo unico; abre com dois cliques, sem internet).

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
Arma: Battle Level 1 ate o MAX, depois a lendaria do elemento do heroi (tai = Fire, nin = Thunder, gen = Water). A arma elemental feita cedo (Weapon Lv1 + Spirit) e item SITUACIONAL para qualquer heroi que precise de dano com escala rapida de status (indicado na tela; interruptor nas regras forca no plano).
Loja lendaria (situacionais): Sanbi, Mirrored Shield, Kusanagi, Sword of Totsuka, Triple-Bladed, Executioner's Blade, Samehada, Chakra Blades, Stone of Gelel.
Ordem de skills: fase de farm (maior dano base inicial primeiro) e fase de escala (skills que escalam com Tai/Nin/Gen); ultimates assim que liberadas.

## Plano por checkpoints de nivel (sem ouro)
A build segue marcos de nivel (1, 10, 15, 35 = farm, 1o e 2o pico de poder da ult R, libera a skill T). Em `politica.json`:
`marcos` (niveis) e `linhas` (a forma de cada item em cada marco: arma Battle Lv1 -> Lv5 -> MAX -> lendaria com a orb do elemento;
roupa Genin -> Chunnin -> Jounin -> Kage Robe; botas; Bingo Book + Ninja Headband -> Anbu Mask -> Heaven Mirror; Jade of Susano'o; slot Extra
escolhido pelo heroi). O quadro mostra cada item na forma do checkpoint, as linhas de evolucao (inclusive upgrades intermediarios) e as orbs
(Soul Absorb Stone + Spirit) da combinacao. Os niveis e formas sao um RASCUNHO e podem ser editados no proprio site.

## Ninja Weapons ativas
Explosive Kunai (Tai, hotkey A), Fuuma Shuriken (Nin, S) e Senbons Dance (Gen, D): itens ativos, dano 7 x atributo, 50s de recarga, loja Ninja Weapons.
Entram na linha "Ninja Weapon (ativa)" da politica para todos os herois (familia pelo atributo principal) e no calculo de dano.
Com a arma elemental cedo, a versao (Explosive/Fuuma/Dance) consome o item no nivel final. O slot Extra so aparece se sobrar vaga.
Os hotkeys de cada item na loja (ex.: Upgrade Weapon = R) aparecem no detalhe do item.

## Itens core e vagas
`nucleo` (politica.json) = itens core: Jade of Susano'o, The Heaven Mirror e as Ninja Weapons (Explosive Kunai / Fuuma Shuriken / Senbons Dance).
Todas as Ninja Weapons, inclusive o Oil, ocupam vaga (linha "Ninja Weapon": Oil no nivel 1 -> arma core do heroi no nivel 10).
Se passar das vagas, sai primeiro o Extra e depois a Jade (`ordem_corte`); core nao sai antes. O Extra nunca e core nem Ninja Weapon.

## Layout (estilo Mobalytics)
Aba Build: cabecalho do heroi, checkpoints a esquerda, ORDEM DAS SKILLS no topo do centro (com atributos abaixo) e itens por checkpoint + situacionais
a direita (detalhe do item embaixo). A aba "Itens por nivel" concentra o quadro por checkpoints, linhas de evolucao, arvores de como fazer, lista de compras e kit de farm.
Linhas de evolucao incluem as formas intermediarias (ex.: Jounin -> Anbu -> Sannin -> Kage Robe; Shippu -> Super Boots Lv1 -> Lv2 -> Lv3).

## Regra de exibicao: mostrar tudo
O sugestor nao esconde informacao: todas as skills do heroi aparecem (faixa "Skills do heroi", grade de ordem e aba Skills), inclusive as fixas
(sem pontos para distribuir, linhas apagadas) e as sem hotkey definida no mapa (a tecla e inferida pelo tooltip ou pela primeira letra livre Q/W/E/R/T e marcada "tecla inferida").
Skills tecnicas (unidades de treino de atributos: Taijutsu, Armor, Damage...) sao marcadas `tecnica` e nao aparecem.
O catalogo lista todos os itens (armas de outra familia ficam marcadas "outra familia"); so entradas tecnicas de loja (Upgrade/Combine/Recipe/Mission) ficam fora, e aparecem nas arvores de "Como fazer".

## Versoes
A versao fica em `versao.txt` (r00, r01, r02...), aparece no titulo, no topo da pagina e no nome do arquivo. A cada atualizacao sobe um numero
e o `CHANGELOG.md` registra o que mudou.
