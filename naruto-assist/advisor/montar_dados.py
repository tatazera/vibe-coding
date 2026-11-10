#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Junta os dados extraidos do mapa (pasta saida_naruto do extrator) em um unico
dados.json para o sugestor de builds.

Uso:  python montar_dados.py <pasta_saida_naruto> [-o dados.json]
"""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "extrator"))
import extrair_mapa as X  # noqa: E402

ATRIB = {"STR": "tai", "AGI": "nin", "INT": "gen"}   # Taijutsu=Forca, Ninjutsu=Agilidade, Genjutsu=Inteligencia
NOME_ATRIB = {"tai": "Taijutsu", "nin": "Ninjutsu", "gen": "Genjutsu"}


def limpar(t):
    if t is None:
        return ""
    t = re.sub(r"\|c[0-9a-fA-F]{8}|\|[rR]", "", str(t))
    return t.replace("|n", "\n").replace("|N", "\n").strip()


def primeiro(v):
    if isinstance(v, dict):
        return next(iter(v.values()), None)
    return v


def valores(v):
    return list(v.values()) if isinstance(v, dict) else [v]


# ---------------------------------------------------------------- leitura
def carregar_tabelas(pasta):
    """Devolve dict com tabelas de jogo e de 'skin' (nomes/tooltips), pelo conteudo."""
    wts = {}
    for p in [pasta / "scripts" / "war3map.wts"] + sorted((pasta / "blocos").glob("*.txt")):
        if p.exists():
            txt = p.read_bytes().decode("utf-8-sig", "replace")
            if txt.lstrip().startswith("STRING"):
                wts = X.parse_wts(txt)
                break
    if not wts:
        raise SystemExit("war3map.wts nao encontrado na pasta")

    def ler(arq, com_nivel):
        v, objs, sobra = X.parse_objetos(arq.read_bytes(), com_nivel)
        if sobra:
            raise ValueError("sobra")
        return {o["id"]: {k: X.resolver_strings(val, wts) for k, val in o["campos"].items()}
                for o in objs}

    jogo = {}
    for letra, nivel in (("u", False), ("t", False), ("a", True)):
        jogo[letra] = ler(pasta / "brutos" / ("war3map.w3" + letra), nivel)

    skin = {}
    for arq in sorted((pasta / "blocos").glob("*.bin")):
        for nivel in (False, True):
            try:
                tab = ler(arq, nivel)
            except Exception:  # noqa: BLE001
                continue
            chaves = {k.split("/")[0] for c in tab.values() for k in c}
            if "anam" in chaves and "atp1" in chaves:
                skin["a"] = tab
            elif "unam" in chaves and "umdl" in chaves:
                skin["u"] = tab
            elif "unam" in chaves and "ides" in chaves and "iico" in chaves:
                skin["t"] = tab
            break
    faltam = [k for k in "uta" if k not in skin]
    if faltam:
        raise SystemExit("tabelas de textos nao encontradas: %s (rode o extrator v5)" % faltam)
    return jogo, skin


# ---------------------------------------------------------------- formulas
_VARS = [(r"\bskill\s+level\b", "L"), (r"\bgenju[st]{1,2}u\b|\bgen\b|\bint\b", "G"),
         (r"\bninjutsu\b|\bnin\b|\bagi\b", "N"), (r"\btaijutsu\b|\btai\b|\bstr\b", "T")]


def _balanceada(t):
    n = 0
    for ch in t:
        n += (ch == "(") - (ch == ")")
        if n < 0:
            return False
    return n == 0


def formula(texto):
    """Converte 'Damage: 30 x skill level + (1 + 0.2 x skill level) x Gen' em
    uma expressao segura ('30*L+(1+0.2*L)*G'; L=nivel da skill, T/N/G=Tai/Nin/Gen).
    Devolve (expr, aproximada). 'aproximada' = o texto tinha complementos
    (ex.: 'at max', 'to buildings') que foram ignorados.
    Devolve (None, False) se nao for aritmetica simples."""
    t = texto.lower().strip()
    t = re.sub(r"(?<=\d)s\b", "", t)            # 16s -> 16
    for padrao, var in _VARS:
        t = re.sub(padrao, var, t)
    t = re.sub(r"\bx\b|×", "*", t)
    t = re.sub(r"(?<=\d)\s*(?=[LTNG(])", "*", t)  # 2G -> 2*G
    m = re.match(r"^[0-9.+\-*/()LTNG\s]+", t)
    if not m:
        return None, False
    pref = m.group(0)
    aprox = pref.strip() != t.strip()
    # tira operador/parenteses abertos soltos no fim e fecha o que sobrou
    pref = re.sub(r"[\s+\-*/(]+$", "", pref)
    while pref and not _balanceada(pref):
        pref = pref[:-1] if pref.endswith(")") and pref.count(")") > pref.count("(") else pref + ")"
        if len(pref) > 200:
            return None, False
    pref = pref.replace(" ", "")
    if not pref or not re.search(r"[LTNG\d]", pref):
        return None, False
    if aprox and not re.search(r"[TNG]", pref):
        return None, False
    try:
        eval(pref, {"__builtins__": {}}, {"L": 1, "T": 1, "N": 1, "G": 1})
    except Exception:  # noqa: BLE001
        return None, False
    return pref, aprox


def linha(desc, rotulo):
    m = re.search(r"^\s*%s\s*:\s*(.+)$" % rotulo, desc, re.I | re.M)
    return m.group(1).strip() if m else None


def atributos_da(expr):
    return sorted({{"T": "tai", "N": "nin", "G": "gen"}[c] for c in expr if c in "TNG"}) if expr else []


# ---------------------------------------------------------------- itens
def parse_item(iid, jogo, skin):
    c, s = jogo.get(iid, {}), skin.get(iid, {})
    desc = limpar(s.get("utub") or s.get("ides") or "")
    nome = limpar(s.get("unam"))
    tipo = None
    m = re.search(r"Item Type:\s*(\w+)", desc, re.I)
    if m:
        tipo = m.group(1).capitalize()
    stats, por_nivel, extras = {}, {}, []
    for ln in desc.split("\n"):
        ln = ln.strip()
        m = re.match(r"^\+\s*(\d+(?:\.\d+)?)\s*(%?)\s*(?:to\s+)?(All\s*(?:Stats|Atats)|Taijutsu|Ninjutsu|Genjutsu|Damage|HP|Chakra|Armor|Movement\s*Speed|Movespeed)\b(.*)$", ln, re.I)
        if not m:
            if ln.startswith(("-", "+")):
                extras.append(ln)
            continue
        valor = float(m.group(1)) if "." in m.group(1) else int(m.group(1))
        rot = re.sub(r"\s+", " ", m.group(3).lower())
        resto = m.group(4)
        alvo = por_nivel if re.search(r"x\s*level", resto, re.I) else stats
        if m.group(2) == "%" and rot.startswith("movement"):
            alvo = alvo  # +N% Movement Speed: guardado como mov_pct
            chave = ["mov_pct"]
        elif rot.startswith("all"):
            chave = ["tai", "nin", "gen"]
        else:
            chave = [{"taijutsu": "tai", "ninjutsu": "nin", "genjutsu": "gen", "damage": "dano", "hp": "hp",
                      "chakra": "chakra", "armor": "armadura", "movement speed": "mov",
                      "movespeed": "mov"}[rot]]
        for k in chave:
            alvo[k] = alvo.get(k, 0) + valor
        if re.search(r"\(.*set.*\)|per kill|from bijuu|doesn't stack", resto, re.I):
            extras.append(ln)
    reducao = sum(int(x) for x in re.findall(r"reduce[sd]?\s+(?:the\s+)?damage\s+taken[^%\n]*?by\s*(\d+)\s*%", desc, re.I))
    m_ev = re.search(r"\+\s*(\d+)\s*%\s*evasion", desc, re.I)
    if m_ev:
        stats["evasao"] = int(m_ev.group(1))
    if reducao:
        stats["reducao"] = reducao
    familia = None
    d = (nome + " " + desc).lower()
    if tipo == "Weapon":
        for chave_f, at in (("kunai", "tai"), ("shuriken", "nin"), ("senbon", "gen")):
            if chave_f in d:
                familia = at
                break
        m = re.search(r"used by (taijutsu|ninjutsu|genjutsu) heroes", d)
        if m:
            familia = {"taijutsu": "tai", "ninjutsu": "nin", "genjutsu": "gen"}[m.group(1)]
    return {"id": iid, "nome": nome, "ouro": c.get("igol"), "cristais": c.get("ilum", 0), "tipo": tipo, "familia": familia,
            "stats": stats, "porNivel": por_nivel, "extras": extras, "descricao": desc}


# ---------------------------------------------------------------- herois
def parse_skill(aid, jogo, skin):
    s, c = skin.get(aid, {}), jogo.get(aid, {})
    nome = limpar(primeiro(s.get("anam")))
    if not nome:
        return None
    tecla = primeiro(s.get("ahky")) or ""
    ub = limpar(primeiro(s.get("aub1")))
    niveis = primeiro(c.get("alev")) or 1
    dano = linha(ub, "Damage")
    cd = linha(ub, "Cooldown")
    custo = linha(ub, "Chakra Cost")
    f_dano, aprox = formula(dano) if dano else (None, False)
    f_cd = formula(cd)[0] if cd else None
    f_custo = formula(custo)[0] if custo else None
    return {"id": aid, "nome": nome, "tecla": tecla, "niveis": niveis, "descricao": ub,
            "dano_txt": dano, "dano": f_dano, "dano_aprox": aprox, "atributos": atributos_da(f_dano),
            "tipo_dano": linha(ub, "Damage Type"), "cooldown_txt": cd, "cooldown": f_cd,
            "chakra_txt": custo, "chakra": f_custo}


def montar(pasta):
    jogo, skin = carregar_tabelas(pasta)
    herois = []
    for uid, c in jogo["u"].items():
        if not ("ustr" in c or "uagi" in c or "uint" in c) or not c.get("uhab"):
            continue
        nome = limpar(skin["u"].get(uid, {}).get("unam"))
        if not nome:
            continue
        habs = [a for a in str(c.get("uhab", "")).split(",") if a]
        extra = [a for a in str(c.get("uabi", "")).split(",") if a]
        skills = [x for x in (parse_skill(a, jogo["a"], skin["a"]) for a in habs + extra) if x]
        primario = ATRIB.get(c.get("upra", "STR"), "tai")
        herois.append({
            "id": uid, "nome": nome, "primario": primario,
            "base": {"tai": c.get("ustr", 0), "nin": c.get("uagi", 0), "gen": c.get("uint", 0)},
            "cresc": {"tai": c.get("ustp", 0), "nin": c.get("uagp", 0), "gen": c.get("uinp", 0)},
            "mov": c.get("umvs", 300),
            "ataque": {"base": c.get("ua1b"), "dados": c.get("ua1d"), "lados": c.get("ua1s"),
                       "cd": c.get("ua1c")},
            "skills": skills})
    herois.sort(key=lambda h: h["nome"].lower())
    itens = [parse_item(i, jogo["t"], skin["t"]) for i in jogo["t"] if i in skin["t"]]
    itens = [i for i in itens if i["nome"]]
    itens.sort(key=lambda i: (i["tipo"] or "z", i["ouro"] or 0))
    return {"constantes": {"hp_base": 100, "hp_por_tai": 24, "chakra_por_gen": 15,
                           "armadura_base": 2, "armadura_por_nin": 0.15, "vel_ataque_por_nin": 0.05,
                           "dano_por_primario": 1.0, "dano_base_padrao": [2, 24], "cd_ataque_padrao": 1.5,
                           "fonte": "war3mapMisc.txt do mapa; conferido com Yamato nivel 9 (964 HP, 705 chakra, armadura 7, dano 49-71)"},
            "atributos": {"tai": "Taijutsu (Forca)", "nin": "Ninjutsu (Agilidade)",
                          "gen": "Genjutsu (Inteligencia)"},
            "herois": herois, "itens": itens}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pasta")
    ap.add_argument("-o", "--saida", default="dados.json")
    a = ap.parse_args()
    d = montar(Path(a.pasta))
    Path(a.saida).write_text(json.dumps(d, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    sk = [s for h in d["herois"] for s in h["skills"]]
    print("herois:", len(d["herois"]), "| itens:", len(d["itens"]), "| skills:", len(sk),
          "| com formula de dano:", sum(1 for s in sk if s["dano"]),
          "(aprox:", sum(1 for s in sk if s["dano"] and s["dano_aprox"]), ")",
          "| com dano em texto:", sum(1 for s in sk if s["dano_txt"]))


if __name__ == "__main__":
    main()
