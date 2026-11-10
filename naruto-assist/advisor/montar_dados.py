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
def categoria(nome, tipo):
    if re.match(r"Battle (Kunai|Shuriken|Senbons) - Level", nome):
        return "arma_batalha"
    if tipo == "Weapon" and re.match(r"(Fire|Water|Wind|Earthen|Thunder|Yin|Yang) (Kunai|Shuriken|Senbons)", nome):
        return "arma_elemental"
    if nome.startswith("Legendary Weapon") or nome in ("True Raijin No Ken",):
        return "arma_lendaria"
    if tipo == "Weapon":
        return "arma_situacional"
    if re.search(r"Boots|Shoes|Sandals", nome):
        return "bota"
    if tipo == "Cloth":
        return "roupa"
    if nome.startswith("Spirit of"):
        return "espirito"
    if "Mask" in nome:
        return "mascara"
    if re.search(r"Stone of|Essence|Absorb", nome):
        return "pedra"
    return "suporte"


def parse_item(iid, jogo, skin, habs_item=None):
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
    nivel_item = None
    mn = re.search(r"Level\s*(\d+|MAX)", nome, re.I)
    if mn:
        nivel_item = 10 if mn.group(1).upper() == "MAX" else int(mn.group(1))
    if por_nivel:  # "+10 Taijutsu x Level": multiplica pelo nivel DO ITEM (Battle Kunai Level 3 = x3)
        for k, v in por_nivel.items():
            stats[k] = stats.get(k, 0) + v * (nivel_item or 1)
        por_nivel = {}
    if "evasao" not in stats and habs_item:
        for a in str(c.get("iabi", "")).split(","):
            ev = habs_item.get(a, {}).get("Eev1/1")
            ev = next(iter(ev.values())) if isinstance(ev, dict) else ev
            if isinstance(ev, (int, float)) and ev:
                stats["evasao"] = round(ev * 100) if ev <= 1 else int(ev)
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
    # item ativo com dano que escala com atributos (Ninja Weapon: Explosive Kunai, Fuuma Shuriken, Senbons Dance, Bomb)
    ativa = None
    dm, cdm = linha(desc, "Damage"), linha(desc, "Cooldown")
    if dm and cdm and "Ninja Weapon" in desc:
        fd, ap = formula(dm)
        fc, _ = formula(cdm)
        if fd and fc and not ap:
            ativa = {"dano": fd, "cooldown": fc, "tipo_dano": linha(desc, "Damage Type"),
                     "alcance": linha(desc, "Casting Range"), "area": linha(desc, "Area of Effect")}
    hks = re.findall(r"\[([A-Z0-9])\]", re.sub(r"\|c[0-9a-fA-F]{8}|\|[rR]", "", str(s.get("utip") or "")))
    hotkey = hks[-1] if hks else (s.get("uhot") or None)
    return {"id": iid, "nome": nome, "categoria": categoria(nome, tipo), "nivelItem": nivel_item,
            "ativa": ativa, "hotkey": hotkey,
            "icone": s.get("iico") or "", "ouro": c.get("igol"), "cristais": c.get("ilum", 0), "tipo": tipo, "familia": familia,
            "stats": stats, "porNivel": por_nivel, "extras": extras, "descricao": desc}


# ---------------------------------------------------------------- receitas
def norm(n):
    return re.sub(r"[^a-z0-9]", "", (n or "").lower())


def parse_receita(item):
    """Interpreta o texto 'Requires:' de itens Combine/Upgrade/Recipe."""
    linhas = item["descricao"].split("\n")
    if not linhas or not linhas[0].lower().startswith("requires"):
        return None
    comps, atual, grupo, notas = [], None, None, []
    for ln in linhas[1:]:
        if not ln.strip():
            continue
        m = re.match(r"^(\s*)-\s*(.+?)\s*$", ln)
        if m:
            indent, txt = len(m.group(1)), re.sub(r"\s*OR\s*$", "", m.group(2))
            mm = re.match(r"^(.*?)\s*\[(.+?)\]?\s*$", txt)
            nome, loja = (mm.group(1).strip(), mm.group(2)) if mm else (txt.strip(), None)
            if indent <= 1 and re.search(r"\(Active\)|\(Passive\)", nome):
                notas.append(nome)
            elif indent <= 1:
                atual = {"nome": nome, "loja": loja, "opcoes": []}
                comps.append(atual)
                grupo = None
            elif atual is not None:
                atual["opcoes"].append({"nome": nome, "loja": loja, "grupo": grupo})
        elif ln.strip().startswith("("):
            grupo = ln.strip().strip("()")
        else:
            notas.append(ln.strip())
    if not comps:
        return None
    return {"componentes": comps, "notas": notas}


def montar_receitas(itens):
    por_nome = {}
    for i in itens:
        k = norm(i["nome"])
        if k and (k not in por_nome or (i["tipo"] and not itens[por_nome[k]]["tipo"])):
            por_nome[k] = itens.index(i)
    achar = lambda n: itens[por_nome[norm(n)]]["id"] if norm(n) in por_nome else None
    receitas = []
    for i in itens:
        r = parse_receita(i)
        if not r:
            continue
        m = re.match(r"^(Combine|Upgrade|Recipe|Mission)\s*:?\s*(.+)$", i["nome"], re.I)
        resultado = m.group(2).strip() if m else i["nome"]
        for c in r["componentes"]:
            c["id"] = achar(c["nome"])
            for o in c["opcoes"]:
                o["id"] = achar(o["nome"])
        receitas.append({"id": i["id"], "nome": i["nome"], "tipoReceita": (m.group(1).capitalize() if m else "Outro"),
                         "resultado": resultado, "resultadoId": achar(resultado) if m and m.group(1).lower() == "combine" else None,
                         "icone": i["icone"], "ouro": i["ouro"], **r})
    return receitas


# ---------------------------------------------------------------- criacao (como fazer cada item)
ELEMENTOS_SPIRIT = {"Fire": "Fire", "Water": "Water", "Wind": "Wind", "Earthen": "Earth", "Earth": "Earth",
                    "Thunder": "Thunder", "Yin": "Yin", "Yang": "Yang"}
FAMILIA_ARMA = {"tai": "Kunai", "nin": "Shuriken", "gen": "Senbons"}
SPIRITS_LENDARIA = {"Kunai": ["Fire", "Earth", "Light"], "Shuriken": ["Thunder", "Wind", "Light"],
                    "Senbons": ["Water", "Darkness", "Light"]}
LENDARIA_ESPIRITO = {   # inferido pelos nomes/elementos; marcado como "provavel" na tela
    "Legendary Weapon: Kyuubi's Chakra Cloak": "Fire", "Legendary Weapon: Adamantine Staff": "Earth",
    "Legendary Weapon: Perfect Battle Kunai": "Light", "Legendary Weapon: Raijin no Ken": "Thunder",
    "Legendary Weapon: Iron Fan": "Wind", "Legendary Weapon: Perfect Battle Shuriken": "Light",
    "Legendary Weapon: Haku's Senbons": "Water", "Legendary Weapon: Shinigami Mask": "Darkness",
    "Legendary Weapon: Perfect Battle Senbons": "Light"}
KAGE_ELEMENTO = {"Hokage Robe": "Fire", "Mizukage Robe": "Water", "Tsuchikage Robe": "Earth",
                 "Raikage Robe": "Thunder", "Kazekage Robe": "Wind"}
BOTA_VARIANTE = {"Boots of Teleportation": [], "Anbu Shoes": ["Ninja Headband"], "Cloning Boots": ["Scroll of Kage Bunshin"],
                 "Healing Boots": ["Scroll of Healing", "Scroll of Chakra"], "Invisibility Boots": ["Scroll of Invisibility"]}


def montar_criacao(itens, receitas, politica):
    """Para cada item: como obter (compra / upgrade / combinar), com componentes e taxas.
    Regras inferidas das receitas do mapa e dos precos (ver README)."""
    por_nome = {}
    for i in itens:
        k = norm(i["nome"])
        if k and (k not in por_nome or (i["tipo"] and not por_nome[k]["tipo"])):
            por_nome[k] = i
    idn = lambda n: por_nome[norm(n)]["id"] if norm(n) in por_nome else None
    lojas = {}
    for r in receitas:
        for c in r["componentes"]:
            if c.get("loja"):
                lojas.setdefault(norm(c["nome"]), c["loja"])
            for o in c["opcoes"]:
                if o.get("loja"):
                    lojas.setdefault(norm(o["nome"]), o["loja"])
    for loja, nomes in (politica.get("lojas") or {}).items():
        for n in nomes:
            lojas[norm(n)] = loja
    lojas.setdefault(norm("Soul Absorb Stone"), "Spirit Shop")

    def comp(nome, opcoes=None, nota=None, qtd=1):
        d = {"id": idn(nome), "nome": nome, "qtd": qtd, "loja": lojas.get(norm(nome))}
        if opcoes:
            d["opcoes"] = [{"id": idn(o), "nome": o, "loja": lojas.get(norm(o))} for o in opcoes]
        if nota:
            d["nota"] = nota
        return d

    taxa = {k: idn(n) for k, n in dict(
        arma="Upgrade Weapon", roupa="Upgrade Cloth", bota="Upgrade Super Boots", sapato="Upgrade Shoes",
        pedra="Upgrade Stone", sanbi="Upgrade Sanbi's Skin", lamina="Upgrade Chakra Blade",
        elem="Combine: Elemental Weapon", elem2="Combine: Elemental Ninja Weapon", lend="Legendary weapons here!",
        super="Combine: Super Boots", kage="Combine: Kage Robe", elemkage="Combine: Elemental Kage Robe",
        totsuka="Upgrade Sword of Totsuka", kusanagi="Upgrade Kusanagi Sword", lamina_elem="Combine: Elemental Chakra Blades").items()}
    cr = {}
    spirit = lambda e: "Spirit of " + ELEMENTOS_SPIRIT.get(e, e)
    nbat = lambda f, n: "Battle %s - Level %s" % (f, "MAX" if n >= 10 else n)
    evol = politica.get("evolucao_roupa") or []

    for i in itens:
        nome, iid = i["nome"], i["id"]
        # 1) armas Battle
        m = re.match(r"^Battle (Kunai|Shuriken|Senbons) - Level (\d+|MAX)$", nome)
        if m:
            f, n = m.group(1), (10 if m.group(2) == "MAX" else int(m.group(2)))
            cr[iid] = {"m": "compra", "loja": "Basic Item Shop"} if n == 1 else \
                {"m": "upgrade", "base": idn(nbat(f, n - 1)), "taxa": taxa["arma"]}
            continue
        # 2) Chakra Blades
        m = re.match(r"^Chakra Blades - Level (\d+|MAX)$", nome)
        if m:
            n = 4 if m.group(1) == "MAX" else int(m.group(1))
            prev = "Chakra Blades - Level %s" % (n - 1)
            cr[iid] = {"m": "compra", "loja": lojas.get(norm(nome)) or "Legendary Equipment Shop"} if n == 1 else \
                {"m": "upgrade", "base": idn(prev), "taxa": taxa["lamina"]}
            continue
        m = re.match(r"^(Fire|Water|Wind|Earthen|Thunder|Yin|Yang) Chakra Blades$", nome)
        if m:
            cr[iid] = {"m": "combinar", "taxa": taxa["lamina_elem"],
                       "comps": [comp("Chakra Blades - Level MAX"), comp("Soul Absorb Stone"), comp(spirit(m.group(1)))]}
            continue
        # 3) armas elementais (e suas versoes Explosive/Fuuma/Dance)
        m = re.match(r"^(Fire|Water|Wind|Earthen|Thunder|Yin|Yang) (Kunai|Shuriken|Senbons)$", nome)
        if m and i["tipo"] == "Weapon":
            e, f = m.groups()
            cr[iid] = {"m": "combinar", "taxa": taxa["elem"],
                       "comps": [comp(nbat(f, 1)), comp("Soul Absorb Stone"), comp(spirit(e))]}
            continue
        m = re.match(r"^(Fire|Water|Wind|Earthen|Thunder|Yin|Yang) (Kunai|Shuriken|Senbons) \((Explosive|Fuuma|Dance)\)$", nome)
        if m:
            e, f, _v = m.groups()
            acess = {"Kunai": "Explosive Kunai", "Shuriken": "Fuuma Shuriken", "Senbons": "Senbons Dance"}[f]
            cr[iid] = {"m": "combinar", "taxa": taxa["elem2"], "comps": [comp("%s %s" % (e, f)), comp(acess)]}
            continue
        # 4) armas lendarias: Battle MAX + pedra + spirit
        if i["categoria"] == "arma_lendaria":
            st = i["stats"]
            f = max(FAMILIA_ARMA, key=lambda k: st.get(k, 0)) if any(st.get(k) for k in FAMILIA_ARMA) else (i["familia"] or "tai")
            fam = FAMILIA_ARMA[f]
            esp = LENDARIA_ESPIRITO.get(nome)
            c3 = comp("Spirit of " + esp, nota="spirit provavel pelo nome da arma") if esp else \
                comp("Spirit (escolha)", opcoes=["Spirit of " + e for e in SPIRITS_LENDARIA[fam]],
                     nota="o espirito escolhido define qual arma lendaria sai")
            cr[iid] = {"m": "combinar", "taxa": taxa["lend"], "comps": [comp(nbat(fam, 10)), comp("Soul Absorb Stone"), c3]}
            continue
        # 5) roupas
        if nome in evol:
            k = evol.index(nome)
            if nome == "Kage Robe":
                cr[iid] = {"m": "combinar", "taxa": taxa["kage"], "comps": [comp("Sannin Cloth")]}
            elif k == 0:
                cr[iid] = {"m": "compra", "loja": lojas.get(norm(nome)) or "Basic Item Shop"}
            else:
                cr[iid] = {"m": "upgrade", "base": idn(evol[k - 1]), "taxa": taxa["roupa"]}
            continue
        if nome in KAGE_ELEMENTO or nome in ("Otokage Robe", "Sage Robe"):
            sp = KAGE_ELEMENTO.get(nome)
            c3 = comp(spirit(sp), nota="elemento provavel pelo nome do kage") if sp else \
                comp("Spirit (escolha)", opcoes=[spirit(e) for e in ("Fire", "Water", "Earth", "Thunder", "Wind", "Yin", "Yang")])
            cr[iid] = {"m": "combinar", "taxa": taxa["elemkage"], "comps": [comp("Kage Robe"), comp("Soul Absorb Stone"), c3]}
            continue
        m = re.match(r"^Sanbi's (Rough|Hardened|Impenetrable) Skin$", nome)
        if m or nome == "Sanbi's Skin":
            ordem = ["Sanbi's Skin", "Sanbi's Rough Skin", "Sanbi's Hardened Skin", "Sanbi's Impenetrable Skin"]
            k = ordem.index(nome)
            cr[iid] = {"m": "compra", "loja": lojas.get(norm(nome)) or "Legendary Equipment Shop"} if k == 0 else \
                {"m": "upgrade", "base": idn(ordem[k - 1]), "taxa": taxa["sanbi"]}
            continue
        # 6) botas
        if nome == "Ninja Shippu Boots":
            cr[iid] = {"m": "upgrade", "base": idn("Ninja Shoes"), "taxa": taxa["sapato"]}
            continue
        m = re.match(r"^(Boots of Teleportation|Anbu Shoes|Cloning Boots|Healing Boots|Invisibility Boots|Blink Boots|Akatsuki Shoes) - Level (\d)$", nome)
        if m:
            var, n = m.group(1), int(m.group(2))
            if n > 1:
                cr[iid] = {"m": "upgrade", "base": idn("%s - Level %d" % (var, n - 1)), "taxa": taxa["bota"]}
            elif var in BOTA_VARIANTE:
                extra = [comp(x) for x in BOTA_VARIANTE[var]]
                cr[iid] = {"m": "combinar", "taxa": taxa["super"], "comps": [comp("Ninja Shippu Boots")] + extra,
                           "nota": "Super Boots: variante %s" % var}
            else:
                cr[iid] = {"m": "compra", "loja": lojas.get(norm(nome)), "nota": "receita desta variante nao esta descrita no mapa"}
            continue
        # 7) pedras de vida / chakra
        for linha in (["Stone of Life", "Stone of Greater Life", "Stone of Immortality", "Ashura Essence"],
                      ["Stone of Chakra", "Stone of Greater Chakra", "Stone of Infinite Chakra", "Indra Essence"]):
            if nome in linha and nome != linha[0]:
                cr[iid] = {"m": "upgrade", "base": idn(linha[linha.index(nome) - 1]), "taxa": taxa["pedra"]}
                break
        if iid in cr:
            continue
        # 8) kusanagi / totsuka elementais
        m = re.match(r"^(Fire|Yin|Yang) Kusanagi$", nome)
        if m:
            cr[iid] = {"m": "combinar", "taxa": taxa["kusanagi"], "comps": [comp("Kusanagi Sword"), comp("Soul Absorb Stone"), comp(spirit(m.group(1)))]}
            continue
        m = re.match(r"^(Infernal|Chilling|True|Thundering|Purified) Sword of Totsuka$|^(True|Purified) Sword of Totsuka$", nome)
        if m:
            esp = {"Infernal": "Fire", "Chilling": "Water", "Thundering": "Thunder"}.get(m.group(1) or "")
            c3 = comp(spirit(esp), nota="elemento provavel pelo nome") if esp else \
                comp("Spirit (escolha)", opcoes=["Spirit of Yin", "Spirit of Yang"])
            cr[iid] = {"m": "combinar", "taxa": taxa["totsuka"], "comps": [comp("Soul Absorb Stone"), comp("Sword of Totsuka"), c3]}
            continue

    # 9) receitas Combine descritas no mapa (Jade, Heaven Mirror, Anbu Mask...)
    for r in receitas:
        rid = r.get("resultadoId")
        if rid and rid not in cr and r["tipoReceita"] == "Combine":
            cr[rid] = {"m": "combinar", "taxa": r["id"],
                       "comps": [{"id": c.get("id"), "nome": c["nome"], "qtd": 1, "loja": c.get("loja"),
                                  **({"opcoes": c["opcoes"]} if c.get("opcoes") else {})} for c in r["componentes"]],
                       **({"nota": " ".join(r["notas"])} if r["notas"] else {})}
    # 10) todo o resto: compra direta
    for i in itens:
        if i["id"] not in cr:
            cr[i["id"]] = {"m": "compra", "loja": lojas.get(norm(i["nome"]))}
    return cr, {k: v for k, v in lojas.items()}


def validar_criacao(itens, cr):
    """Compara o preco de tabela com a soma dos passos (taxa + precos de tabela dos componentes).
    Grava 'soma' e 'dif' em cada regra; 'taxaIncluida' quando o preco ja cobre so os componentes."""
    I = {i["id"]: i for i in itens}

    def preco_comp(c):
        if c.get("opcoes") and not c.get("id"):
            ps = [I[o["id"]]["ouro"] for o in c["opcoes"] if o.get("id") and I[o["id"]]["ouro"]]
            return ps[0] if ps else None
        return I[c["id"]]["ouro"] if c.get("id") and I[c["id"]]["ouro"] is not None else None

    for iid, r in cr.items():
        it = I[iid]
        if r["m"] == "compra" or it["ouro"] is None:
            continue
        fee = (I[r["taxa"]]["ouro"] or 0) if r.get("taxa") else 0
        if r["m"] == "upgrade":
            b = I[r["base"]]["ouro"] if r.get("base") else None
            if b is None:
                continue
            comps_soma = b
        else:
            ps = [preco_comp(c) for c in r["comps"]]
            if any(p is None for p in ps):
                continue
            comps_soma = sum(ps)
        est = comps_soma + fee
        if fee and abs(comps_soma - it["ouro"]) <= 1 and r["m"] == "combinar":
            r["taxaIncluida"], est = True, comps_soma
        r["soma"], r["dif"] = est, it["ouro"] - est


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
    return {"id": aid, "nome": nome, "tecla": tecla, "niveis": niveis,
            "icone": primeiro(s.get("aart")) or "",
            "req": {"arlv": primeiro(c.get("arlv")), "alsk": primeiro(c.get("alsk"))},
            "descricao": ub,
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
        skills = []
        for a in habs + extra:
            x = parse_skill(a, jogo["a"], skin["a"])
            if x:
                x["heroica"] = a in habs   # gasta pontos de skill ao subir de nivel
                skills.append(x)
        if not any(sk["tecla"] for sk in skills):
            continue  # unidade auxiliar do mapa (sem skills jogaveis)
        primario = ATRIB.get(c.get("upra", "STR"), "tai")
        herois.append({
            "id": uid, "nome": nome, "primario": primario,
            "icone": skin["u"].get(uid, {}).get("uico") or "",
            "base": {"tai": c.get("ustr", 0), "nin": c.get("uagi", 0), "gen": c.get("uint", 0)},
            "cresc": {"tai": c.get("ustp", 0), "nin": c.get("uagp", 0), "gen": c.get("uinp", 0)},
            "mov": c.get("umvs", 300),
            "ataque": {"base": c.get("ua1b"), "dados": c.get("ua1d"), "lados": c.get("ua1s"),
                       "cd": c.get("ua1c")},
            "skills": skills})
    herois.sort(key=lambda h: h["nome"].lower())
    itens = [parse_item(i, jogo["t"], skin["t"], jogo["a"]) for i in jogo["t"] if i in skin["t"]]
    itens = [i for i in itens if i["nome"]]
    itens.sort(key=lambda i: (i["tipo"] or "z", i["ouro"] or 0))
    receitas = montar_receitas(itens)
    arq_pol = Path(__file__).resolve().parent / "politica.json"
    politica = json.loads(arq_pol.read_text(encoding="utf-8")) if arq_pol.exists() else {}
    for it in itens:   # Soul Absorb Stone nao tem preco no mapa; 1000 e o valor que faz as somas das receitas fecharem
        if norm(it["nome"]) == "soulabsorbstone" and it["ouro"] is None:
            it["ouro"], it["precoInferido"] = 1000, True
    criacao, lojas_map = montar_criacao(itens, receitas, politica)
    validar_criacao(itens, criacao)
    for it in itens:
        it["loja"] = (criacao[it["id"]].get("loja") if criacao[it["id"]]["m"] == "compra" else None)
    return {"politica": politica, "criacao": criacao, "receitas": receitas, "constantes": {"hp_base": 100, "hp_por_tai": 24, "chakra_por_gen": 15,
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
          "| receitas:", len(d["receitas"]), "| criacao:", len(d["criacao"]), "| com formula de dano:", sum(1 for s in sk if s["dano"]),
          "(aprox:", sum(1 for s in sk if s["dano"] and s["dano_aprox"]), ")",
          "| com dano em texto:", sum(1 for s in sk if s["dano_txt"]))


if __name__ == "__main__":
    main()
