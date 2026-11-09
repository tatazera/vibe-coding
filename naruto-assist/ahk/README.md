# Naruto Helper (AutoHotkey v2)

Reseleciona o heroi automaticamente depois de usar skills no mapa Naruto Ninpou Reforged,
para nao perder o combo quando a skill tira a selecao do personagem.

## Instalar
1. Instale o AutoHotkey v2: https://www.autohotkey.com (versao 2.x).
2. Baixe `naruto_helper.ahk` e `config.ini` e deixe na mesma pasta.
3. De dois cliques em `naruto_helper.ahk` (abre um icone verde "H" na bandeja).
4. Abra o jogo em **modo janela sem bordas** (recomendado). Se o jogo rodar como administrador, rode o script como administrador tambem.

## Como funciona
- So age quando a janela do Warcraft III esta em foco.
- A tecla da skill passa normalmente para o jogo (1 tecla = 1 acao do jogador); o script
  apenas manda `F1` logo depois para reselecionar o heroi.
- `Ctrl+Alt+H` liga/desliga.

## Calibrar (importante: depende de como cada skill se comporta)
- Skill que **nao pede alvo** e perde a selecao: deixe em `skills_instantaneas`.
- Skill que **pede alvo** (cursor de mira): coloque a tecla em `skills_com_alvo`; o F1
  so e enviado apos o clique que lanca a skill (senao o F1 poderia cancelar a mira).
- Se ainda perder a selecao, aumente `atraso_apos_skill_ms` (ex.: 100 ou 150).
- Se a camera pular para o heroi sem querer, aumente `intervalo_minimo_entre_f1_ms`.

## Aviso
A Blizzard nao permite automacao que de vantagem desleal. Este modo manda uma acao
extra por tecla, entao use em partidas custom com amigos e avise o host se houver regra
contra macros. Nao use em partidas ranqueadas.
