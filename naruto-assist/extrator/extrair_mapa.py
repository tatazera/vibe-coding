#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Extrator de dados de mapas de Warcraft III (.w3x / .w3m).

Le o mapa (formato MPQ) sem precisar instalar nada (so Python 3.8+) e gera uma
pasta + um .zip pequeno com:
  - unidades.json, itens.json, habilidades.json, buffs.json, upgrades.json ...
  - strings.json (textos do mapa, para resolver TRIGSTR_xxx)
  - scripts/ (war3map.j / war3map.lua e outros arquivos de texto: la ficam as
    formulas de dano que usam Taijutsu/Ninjutsu/Genjutsu)
  - pistas_atributos.txt (linhas do script/textos que citam os atributos)
  - resumo.txt (o que foi lido, o que faltou)

Uso:
  python extrair_mapa.py "C:\\caminho\\mapa.w3x"
  python extrair_mapa.py                      (pergunta o caminho)
  python extrair_mapa.py --pasta "C:\\mapa_extraido"   (arquivos ja extraidos
                                               com MPQ Editor, se o mapa for protegido)
"""
import argparse
import bz2
import json
import os
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

M = 0xFFFFFFFF

# --------------------------------------------------------------------------
# Leitor de MPQ (somente leitura)
# --------------------------------------------------------------------------

def _tabela_crypt():
    tabela = [0] * 0x500
    seed = 0x00100001
    for i in range(256):
        idx = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            tabela[idx] = t1 | t2
            idx += 0x100
    return tabela


CRYPT = _tabela_crypt()


def hash_str(nome, tipo):
    s1, s2 = 0x7FED7FED, 0xEEEEEEEE
    for c in nome.replace("/", "\\").upper().encode("utf-8", "replace"):
        s1 = CRYPT[(tipo << 8) + c] ^ ((s1 + s2) & M)
        s2 = (c + s1 + s2 + (s2 << 5) + 3) & M
    return s1


def decifrar(dados, chave):
    n = len(dados) // 4
    if n == 0:
        return dados
    vals = list(struct.unpack("<%dI" % n, dados[: n * 4]))
    s2 = 0xEEEEEEEE
    chave &= M
    for i in range(n):
        s2 = (s2 + CRYPT[0x400 + (chave & 0xFF)]) & M
        v = vals[i] ^ ((chave + s2) & M)
        chave = (((((~chave) & M) << 21) + 0x11111111) & M) | (chave >> 11)
        s2 = (v + s2 + (s2 << 5) + 3) & M
        vals[i] = v
    return struct.pack("<%dI" % n, *vals) + dados[n * 4:]


F_IMPLODE, F_COMPRESS, F_ENC, F_FIXKEY = 0x100, 0x200, 0x10000, 0x20000
F_SINGLE, F_DELETE, F_CRC, F_EXISTS = 0x1000000, 0x2000000, 0x4000000, 0x80000000


class MPQ:
    def __init__(self, caminho):
        self.f = open(caminho, "rb")
        self.f.seek(0, 2)
        self.tamanho = self.f.tell()
        self.off = self._achar_cabecalho()
        self._ler_cabecalho()
        self._ler_tabelas()

    def fechar(self):
        self.f.close()

    def _achar_cabecalho(self):
        off = 0
        limite = min(self.tamanho, 64 * 1024 * 1024)
        while off < limite:
            self.f.seek(off)
            magia = self.f.read(4)
            if magia == b"MPQ\x1a":
                return off
            if magia == b"MPQ\x1b":  # bloco de "user data" que aponta para o cabecalho
                self.f.seek(off + 8)
                (desloc,) = struct.unpack("<I", self.f.read(4))
                return off + desloc
            off += 512
        raise ValueError("Cabecalho MPQ nao encontrado (o arquivo e mesmo um .w3x/.w3m?)")

    def _ler_cabecalho(self):
        self.f.seek(self.off)
        h = self.f.read(0x2C)
        (_m, tam_cab, _tam_arq, ver, shift, hash_pos, block_pos,
         hash_n, block_n) = struct.unpack("<4sIIHHIIII", h[:32])
        if ver >= 1 and tam_cab >= 0x2C and len(h) >= 0x2C:
            _hi_block, hash_hi, block_hi = struct.unpack("<QHH", h[0x20:0x2C])
            hash_pos |= hash_hi << 32
            block_pos |= block_hi << 32
        self.setor = 512 << shift
        self.hash_pos, self.block_pos = hash_pos, block_pos
        self.hash_n, self.block_n = hash_n, block_n

    def _ler_tabelas(self):
        self.f.seek(self.off + self.hash_pos)
        bruto = self.f.read(self.hash_n * 16)
        bruto = decifrar(bruto, hash_str("(hash table)", 3))
        self.hash = [struct.unpack("<IIHHI", bruto[i * 16:(i + 1) * 16])
                     for i in range(len(bruto) // 16)]
        self.f.seek(self.off + self.block_pos)
        bruto = self.f.read(self.block_n * 16)
        bruto = decifrar(bruto, hash_str("(block table)", 3))
        self.block = [struct.unpack("<IIII", bruto[i * 16:(i + 1) * 16])
                      for i in range(len(bruto) // 16)]

    def _achar(self, nome):
        n = len(self.hash)
        if n == 0:
            return None
        a, b = hash_str(nome, 1), hash_str(nome, 2)
        h0 = hash_str(nome, 0)
        i = (h0 & (n - 1)) if (n & (n - 1)) == 0 else h0 % n
        achado = None
        for _ in range(n):
            ha, hb, loc, _plat, blk = self.hash[i]
            if blk == 0xFFFFFFFF:
                break
            if ha == a and hb == b and blk != 0xFFFFFFFE and blk < len(self.block):
                if loc == 0:
                    return blk
                if achado is None:
                    achado = blk
            i = (i + 1) % n
        return achado

    def existe(self, nome):
        blk = self._achar(nome)
        return blk is not None and bool(self.block[blk][3] & F_EXISTS)

    @staticmethod
    def _descomprimir(raw, flags):
        if flags & F_COMPRESS:
            mascara, dados = raw[0], raw[1:]
            if mascara == 0x02:
                return zlib.decompress(dados)
            if mascara == 0x10:
                return bz2.decompress(dados)
            if mascara == 0x00:
                return dados
            raise NotImplementedError("compressao MPQ 0x%02X nao suportada" % mascara)
        raise NotImplementedError("compressao PKWARE (implode) nao suportada")

    def ler(self, nome):
        blk = self._achar(nome)
        if blk is None:
            raise KeyError(nome)
        pos, csize, fsize, flags = self.block[blk]
        if not (flags & F_EXISTS) or (flags & F_DELETE):
            raise KeyError(nome)
        chave = 0
        if flags & F_ENC:
            base = nome.replace("/", "\\").split("\\")[-1]
            chave = hash_str(base, 3)
            if flags & F_FIXKEY:
                chave = (((chave + pos) & M) ^ fsize) & M
        comprimido = bool(flags & (F_COMPRESS | F_IMPLODE))
        self.f.seek(self.off + pos)
        if flags & F_SINGLE:
            raw = self.f.read(csize)
            if flags & F_ENC:
                raw = decifrar(raw, chave)
            if comprimido and csize < fsize:
                raw = self._descomprimir(raw, flags)
            return raw[:fsize]
        n = (fsize + self.setor - 1) // self.setor
        saida = bytearray()
        if comprimido:
            extra = 1 if flags & F_CRC else 0
            tab = self.f.read((n + 1 + extra) * 4)
            if flags & F_ENC:
                tab = decifrar(tab, (chave - 1) & M)
            offs = struct.unpack("<%dI" % (n + 1 + extra), tab)[: n + 1]
            for i in range(n):
                self.f.seek(self.off + pos + offs[i])
                raw = self.f.read(offs[i + 1] - offs[i])
                esperado = min(self.setor, fsize - i * self.setor)
                if flags & F_ENC:
                    raw = decifrar(raw, (chave + i) & M)
                if len(raw) < esperado:
                    raw = self._descomprimir(raw, flags)
                saida += raw
        else:
            raw = self.f.read(csize)
            for i in range(n):
                parte = raw[i * self.setor:(i + 1) * self.setor]
                if flags & F_ENC:
                    parte = decifrar(parte, (chave + i) & M)
                saida += parte
        return bytes(saida[:fsize])

    def lista(self):
        try:
            txt = self.ler("(listfile)").decode("utf-8", "replace")
        except Exception:
            return []
        return [l.strip() for l in txt.splitlines() if l.strip()]


# --------------------------------------------------------------------------
# Fontes de arquivos (mapa .w3x ou pasta ja extraida)
# --------------------------------------------------------------------------

class FonteMapa:
    def __init__(self, mpq):
        self.mpq = mpq

    def lista(self):
        return self.mpq.lista()

    def existe(self, nome):
        return self.mpq.existe(nome)

    def ler(self, nome):
        return self.mpq.ler(nome)


class FontePasta:
    def __init__(self, pasta):
        self.pasta = Path(pasta)

    def lista(self):
        return [str(p.relative_to(self.pasta)).replace("/", "\\")
                for p in self.pasta.rglob("*") if p.is_file()]

    def _caminho(self, nome):
        return self.pasta / nome.replace("\\", os.sep)

    def existe(self, nome):
        return self._caminho(nome).is_file()

    def ler(self, nome):
        p = self._caminho(nome)
        if not p.is_file():
            raise KeyError(nome)
        return p.read_bytes()


# --------------------------------------------------------------------------
# Textos do mapa (war3map.wts) e dados de objetos (w3u/w3t/w3a/...)
# --------------------------------------------------------------------------

def decodificar(dados):
    return dados.decode("utf-8-sig", "replace")


def parse_wts(texto):
    textos = {}
    for m in re.finditer(r"STRING\s+(\d+)\s*\r?\n(?:\s*//[^\n]*\n)?\s*\{\r?\n(.*?)\r?\n\}",
                         texto, re.S):
        textos[int(m.group(1))] = m.group(2).replace("\r\n", "\n")
    return textos


class Leitor:
    def __init__(self, dados):
        self.d, self.p = dados, 0

    def u32(self):
        v = struct.unpack_from("<I", self.d, self.p)[0]
        self.p += 4
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.p)[0]
        self.p += 4
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.d, self.p)[0]
        self.p += 4
        return round(v, 6)

    def id4(self):
        b = self.d[self.p:self.p + 4]
        self.p += 4
        return None if b == b"\x00\x00\x00\x00" else b.decode("latin-1")

    def cstr(self):
        fim = self.d.index(b"\x00", self.p)
        s = self.d[self.p:fim].decode("utf-8", "replace")
        self.p = fim + 1
        return s


NOME_CAMPO = {"u": "unam", "t": "unam", "a": "anam", "h": "fnam", "q": "gnam",
              "b": "bnam", "d": "dnam"}


def parse_objetos(dados, com_nivel):
    """Le um arquivo de dados de objetos (formato do Object Editor)."""
    r = Leitor(dados)
    versao = r.u32()
    objetos = []
    for origem in ("original", "custom"):
        qtd = r.u32()
        for _ in range(qtd):
            base = r.id4()
            novo = r.id4()
            # Versao 3+ (Reforged): cada objeto tem "sets" de modificacoes.
            sets = r.u32() if versao >= 3 else 1
            campos = {}
            for s_i in range(sets):
                flag = r.u32() if versao >= 3 else 0
                n_mods = r.u32()
                prefixo = "" if flag == 0 else "set%d:" % flag
                for _ in range(n_mods):
                    campo = r.id4()
                    tipo = r.u32()
                    nivel = ptr = 0
                    if com_nivel:
                        nivel = r.u32()
                        ptr = r.u32()
                    if tipo == 0:
                        valor = r.i32()
                    elif tipo in (1, 2):
                        valor = r.f32()
                    elif tipo == 3:
                        valor = r.cstr()
                    elif tipo == 4:  # booleano
                        valor = r.i32()
                    else:
                        raise ValueError("tipo de campo desconhecido: %d (posicao %d, campo %s)"
                                         % (tipo, r.p, campo))
                    r.u32()  # marcador de fim da modificacao
                    chave = prefixo + campo + ("/%d" % ptr if ptr else "")
                    if com_nivel:
                        campos.setdefault(chave, {})[str(nivel)] = valor
                    else:
                        campos[chave] = valor
            objetos.append({"id": novo or base, "base": base if novo else None,
                            "origem": origem, "campos": campos})
    return versao, objetos, len(dados) - r.p


def parse_secoes_txt(texto):
    """Le arquivos .txt de perfil: [ID] / Chave=Valor."""
    secoes, atual = {}, None
    for linha in texto.splitlines():
        l = linha.strip()
        if not l or l.startswith("//"):
            continue
        m = re.fullmatch(r"\[(.+?)\]", l)
        if m:
            atual = secoes.setdefault(m.group(1), {})
        elif atual is not None and "=" in l:
            k, v = l.split("=", 1)
            atual[k.strip()] = v.strip()
    return secoes


def resolver_strings(valor, wts):
    if isinstance(valor, str):
        m = re.fullmatch(r"TRIGSTR_(\d+)", valor.strip())
        if m and int(m.group(1)) in wts:
            return wts[int(m.group(1))]
        return valor
    if isinstance(valor, dict):
        return {k: resolver_strings(v, wts) for k, v in valor.items()}
    return valor


def primeiro_valor(v):
    if isinstance(v, dict):
        return next(iter(v.values()), None)
    return v


# --------------------------------------------------------------------------
# Programa principal
# --------------------------------------------------------------------------

ARQUIVOS_OBJETOS = [
    ("war3map.w3u", "unidades.json", "u", False),
    ("war3map.w3t", "itens.json", "t", False),
    ("war3map.w3a", "habilidades.json", "a", True),
    ("war3map.w3h", "buffs.json", "h", False),
    ("war3map.w3q", "upgrades.json", "q", True),
    ("war3map.w3b", "destrutiveis.json", "b", False),
    ("war3map.w3d", "doodads.json", "d", True),
]

CANDIDATOS = [
    "war3map.j", "war3map.lua", "Scripts\\war3map.j", "Scripts\\war3map.lua",
    "war3map.wts", "war3map.wtg", "war3map.wct", "war3map.w3i", "war3map.imp",
    "war3map.doo", "war3mapUnits.doo", "war3mapMisc.txt", "war3mapSkin.txt",
    "war3mapExtra.txt", "war3campaign.w3u", "war3map.w3s", "war3map.w3r",
    "war3map.w3c", "war3map.shd", "war3map.mmp",
] + [a[0] for a in ARQUIVOS_OBJETOS]

_RACAS = ["Campaign", "Common", "Human", "NightElf", "Orc", "Undead", "Neutral", "Item"]
_TIPOS = ["AbilityFunc", "AbilityStrings", "UnitFunc", "UnitStrings", "UpgradeFunc",
          "UpgradeStrings", "Func", "Strings", "AbilityProfile"]
CANDIDATOS += ["Units\\%s%s.txt" % (r, t) for r in _RACAS for t in _TIPOS]
CANDIDATOS += ["Units\\CommandFunc.txt", "Units\\CommandStrings.txt",
               "Units\\UnitGlobalStrings.txt", "Units\\ItemFunc.txt", "Units\\ItemStrings.txt",
               "Units\\ItemAbilityFunc.txt", "Units\\ItemAbilityStrings.txt"]
CANDIDATOS += ["Units\\%s.slk" % n for n in (
    "UnitData", "UnitBalance", "UnitUI", "UnitAbilities", "UnitWeapons", "ItemData",
    "AbilityData", "UpgradeData", "UnitMetaData", "AbilityMetaData")]
CANDIDATOS += ["Doodads\\Doodads.slk", "Units\\DestructableData.slk"]

EXT_TEXTO = {".j", ".lua", ".txt", ".slk", ".wts", ".wtg", ".wct", ".w3i", ".imp",
             ".ini", ".json", ".fdf", ".toc", ".w3u", ".w3t", ".w3a", ".w3h", ".w3q",
             ".w3b", ".w3d", ".doo", ".w3s", ".w3r", ".w3c"}
LIMITE_TEXTO = 12 * 1024 * 1024


def salvar_json(caminho, obj):
    caminho.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")


def extrair(fonte, saida, log):
    saida.mkdir(parents=True, exist_ok=True)
    (saida / "scripts").mkdir(exist_ok=True)
    lista = fonte.lista()
    log("Arquivos listados no mapa: %d%s" % (
        len(lista), "" if lista else " (sem (listfile): tentando nomes conhecidos)"))
    if lista:
        (saida / "todos_arquivos.txt").write_text("\n".join(lista), encoding="utf-8")
        exts = {}
        for n in lista:
            e = os.path.splitext(n)[1].lower() or "(sem ext)"
            exts[e] = exts.get(e, 0) + 1
        log("Tipos mais comuns: " + ", ".join(
            "%s=%d" % kv for kv in sorted(exts.items(), key=lambda x: -x[1])[:12]))

    nomes = []
    vistos = set()
    for n in CANDIDATOS + lista:
        k = n.lower().replace("/", "\\")
        if k in vistos:
            continue
        vistos.add(k)
        nomes.append(n)

    brutos = {}   # nome minusculo -> bytes
    faltaram, erros = [], []
    for n in nomes:
        ext = os.path.splitext(n)[1].lower()
        eh_wc3 = os.path.basename(n).lower().startswith(("war3map", "war3campaign"))
        if not (eh_wc3 or ext in EXT_TEXTO):
            continue
        if not fonte.existe(n):
            if n in CANDIDATOS:
                faltaram.append(n)
            continue
        try:
            dados = fonte.ler(n)
        except Exception as e:  # noqa: BLE001
            erros.append("%s: %s" % (n, e))
            continue
        brutos[n.lower().replace("/", "\\")] = dados
        if ext in (".w3u", ".w3t", ".w3a", ".w3h", ".w3q", ".w3b", ".w3d", ".w3i") \
                and len(dados) <= LIMITE_TEXTO:
            (saida / "brutos").mkdir(exist_ok=True)
            (saida / "brutos" / n.replace("\\", "__").replace("/", "__")).write_bytes(dados)
        if ext in (".j", ".lua", ".txt", ".slk", ".wts", ".wtg", ".wct", ".imp",
                   ".ini", ".json", ".fdf", ".toc") and len(dados) <= LIMITE_TEXTO:
            destino = saida / "scripts" / n.replace("\\", "__").replace("/", "__")
            destino.write_bytes(dados)

    def pegar(nome):
        return brutos.get(nome.lower())

    # textos
    wts = {}
    if pegar("war3map.wts"):
        wts = parse_wts(decodificar(pegar("war3map.wts")))
        salvar_json(saida / "strings.json", {str(k): v for k, v in wts.items()})
        log("Textos (wts): %d" % len(wts))

    # textos dos objetos (nomes, tooltips, icones) em arquivos Units\\*.txt
    textos_obj = {}
    for nome, dados in brutos.items():
        if nome.startswith("units\\") and nome.endswith(".txt"):
            for oid, campos in parse_secoes_txt(decodificar(dados)).items():
                textos_obj.setdefault(oid, {}).update(
                    {k: resolver_strings(v, wts) for k, v in campos.items()})
    if textos_obj:
        salvar_json(saida / "textos_objetos.json", textos_obj)
        log("Textos de objetos (Units\\*.txt): %d ids" % len(textos_obj))

    # objetos
    contagens = {}
    for arq, saida_json, tipo, com_nivel in ARQUIVOS_OBJETOS:
        dados = pegar(arq)
        if not dados:
            continue
        try:
            versao, objs, sobra = parse_objetos(dados, com_nivel)
        except Exception as e:  # noqa: BLE001
            erros.append("%s: falha ao interpretar (%s)" % (arq, e))
            continue
        for o in objs:
            o["campos"] = {k: resolver_strings(v, wts) for k, v in o["campos"].items()}
            nome = primeiro_valor(o["campos"].get(NOME_CAMPO[tipo]))
            if not nome:
                nome = textos_obj.get(o["id"], {}).get("Name")
            if nome:
                o["nome"] = nome
            if o["id"] in textos_obj:
                o["textos"] = textos_obj[o["id"]]
        salvar_json(saida / saida_json, objs)
        contagens[saida_json] = len(objs)
        log("%s: %d objetos (versao %d)%s" % (
            saida_json, len(objs), versao,
            "" if sobra == 0 else " [AVISO: %d bytes nao lidos]" % sobra))

    # pistas sobre os atributos (onde a logica de dano mora)
    padrao = re.compile(r"taijutsu|ninjutsu|genjutsu", re.I)
    pistas = []
    for nome, dados in list(brutos.items()):
        if os.path.splitext(nome)[1] in (".j", ".lua", ".wts", ".txt"):
            for i, linha in enumerate(decodificar(dados).splitlines(), 1):
                if padrao.search(linha):
                    pistas.append("%s:%d: %s" % (nome, i, linha.strip()[:300]))
    if pistas:
        (saida / "pistas_atributos.txt").write_text(
            "\n".join(pistas[:1500]), encoding="utf-8")
    log("Linhas que citam Taijutsu/Ninjutsu/Genjutsu: %d" % len(pistas))

    scripts = [n for n in brutos if n.endswith((".j", ".lua"))]
    resumo = ["RESUMO DA EXTRACAO", "=" * 40,
              "Arquivos lidos: %d" % len(brutos),
              "Objetos: " + (", ".join("%s=%d" % kv for kv in contagens.items()) or "nenhum"),
              "Scripts: " + (", ".join(scripts) or "NENHUM (mapa protegido?)"),
              "Textos (wts): %d" % len(wts),
              "Textos de objetos: %d" % len(textos_obj),
              "Pistas de atributos: %d" % len(pistas), ""]
    if faltaram:
        resumo.append("Nao encontrados (normal se o mapa nao usa): " + ", ".join(faltaram))
    if erros:
        resumo.append("ERROS:")
        resumo += ["  - " + e for e in erros]
    if not contagens and not scripts:
        resumo.append("\nNada util foi lido. Se o mapa for protegido, extraia os arquivos com o "
                      "MPQ Editor e rode: python extrair_mapa.py --pasta <pasta>")
    (saida / "resumo.txt").write_text("\n".join(resumo), encoding="utf-8")
    log("")
    log("\n".join(resumo[-(len(erros) + 3):]) if erros else "Concluido.")
    return erros


def zipar(saida, destino):
    with zipfile.ZipFile(destino, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in sorted(saida.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(saida))


def main():
    ap = argparse.ArgumentParser(description="Extrai dados de mapas .w3x do Warcraft III")
    ap.add_argument("mapa", nargs="?", help="arquivo .w3x/.w3m")
    ap.add_argument("--pasta", help="usar uma pasta com arquivos ja extraidos")
    ap.add_argument("-o", "--saida", default="saida_naruto", help="pasta de saida")
    args = ap.parse_args()

    interativo = not (args.mapa or args.pasta)
    caminho = args.mapa
    if interativo:
        caminho = input("Arraste o arquivo .w3x para esta janela e aperte Enter:\n> ").strip().strip('"')
    log = print
    try:
        if args.pasta:
            fonte = FontePasta(args.pasta)
        else:
            fonte = FonteMapa(MPQ(caminho))
        saida = Path(args.saida)
        extrair(fonte, saida, log)
        zip_path = saida.with_suffix(".zip") if saida.suffix == "" else Path(str(saida) + ".zip")
        zipar(saida, zip_path)
        print("\nPronto! Envie este arquivo no chat: %s (%.1f KB)" % (
            zip_path.resolve(), zip_path.stat().st_size / 1024))
        codigo = 0
    except Exception as e:  # noqa: BLE001
        print("\nERRO: %s" % e)
        codigo = 1
    if interativo:
        input("\nAperte Enter para fechar.")
    sys.exit(codigo)


if __name__ == "__main__":
    main()
