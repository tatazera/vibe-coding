#Requires AutoHotkey v2.0
#SingleInstance Force
; Naruto Ninpou Reforged - Assistente de selecao do heroi
; Reseleciona o heroi (F1) depois que uma skill e ativada.
; Configuracao: config.ini (mesma pasta). Veja o README.md.

SendMode "Event"
SetKeyDelay 10, 10
CoordMode "ToolTip", "Screen"

cfg := A_ScriptDir "\config.ini"

exe          := IniRead(cfg, "geral", "janela_exe", "Warcraft III.exe")
teclaHeroi   := IniRead(cfg, "geral", "tecla_selecionar_heroi", "F1")
teclaToggle  := IniRead(cfg, "geral", "tecla_liga_desliga", "^!h")
mostrarAviso := Integer(IniRead(cfg, "geral", "mostrar_aviso", "1"))
delayMs      := Integer(IniRead(cfg, "tempo", "atraso_apos_skill_ms", "60"))
janelaClique := Integer(IniRead(cfg, "tempo", "janela_do_clique_ms", "2500"))
minIntervalo := Integer(IniRead(cfg, "tempo", "intervalo_minimo_entre_f1_ms", "300"))
listaInst    := IniRead(cfg, "teclas", "skills_instantaneas", "q,w,e,r,t,d,x")
listaAlvo    := IniRead(cfg, "teclas", "skills_com_alvo", "")

global ligado := true
global ultimoF1 := 0
global armadoAte := 0
global mapaInst := Map()
global mapaAlvo := Map()

for k in StrSplit(listaInst, ",", " ")
    if (k != "")
        mapaInst[StrLower(k)] := true
for k in StrSplit(listaAlvo, ",", " ")
    if (k != "")
        mapaAlvo[StrLower(k)] := true

HotIfWinActive("ahk_exe " exe)
for k, _ in mapaInst
    Hotkey("~*" k, AoUsarSkill)
for k, _ in mapaAlvo
    if !mapaInst.Has(k)
        Hotkey("~*" k, AoUsarSkill)
Hotkey("~LButton", AoClicar)
Hotkey("~" teclaHeroi, AoApertarF1Manual)
HotIfWinActive()
Hotkey(teclaToggle, AlternarLigado)

Aviso("Naruto Helper ativo (" teclaToggle " liga/desliga)")

AoUsarSkill(hk) {
    global armadoAte
    if !ligado
        return
    k := StrLower(StrReplace(StrReplace(hk, "~", ""), "*", ""))
    if mapaInst.Has(k)
        SetTimer(Reselecionar, -delayMs)
    else if mapaAlvo.Has(k)
        armadoAte := A_TickCount + janelaClique
}

AoClicar(hk) {
    global armadoAte
    if (!ligado || armadoAte = 0)
        return
    if (A_TickCount <= armadoAte)
        SetTimer(Reselecionar, -delayMs)
    armadoAte := 0
}

AoApertarF1Manual(hk) {
    global ultimoF1
    ultimoF1 := A_TickCount
}

Reselecionar() {
    global ultimoF1
    if !ligado
        return
    if !WinActive("ahk_exe " exe)
        return
    ; Dois F1 seguidos centralizam a camera no heroi; evitamos isso.
    if (A_TickCount - ultimoF1 < minIntervalo)
        return
    ultimoF1 := A_TickCount
    SendEvent "{" teclaHeroi "}"
}

AlternarLigado(*) {
    global ligado, armadoAte
    ligado := !ligado
    armadoAte := 0
    Aviso(ligado ? "Naruto Helper: LIGADO" : "Naruto Helper: DESLIGADO")
}

Aviso(texto) {
    if !mostrarAviso
        return
    ToolTip(texto, 20, 20)
    SetTimer(() => ToolTip(), -1500)
}
