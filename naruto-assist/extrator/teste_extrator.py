"""Teste do extrator com um mapa .w3x sintetico (rodar: python teste_extrator.py)."""
import bz2, json, os, struct, tempfile, zlib
from pathlib import Path
import extrair_mapa as X

M = X.M


def cifrar(dados, chave):
    n = len(dados) // 4
    vals = struct.unpack("<%dI" % n, dados[: n * 4])
    s2, out = 0xEEEEEEEE, []
    for v in vals:
        s2 = (s2 + X.CRYPT[0x400 + (chave & 0xFF)]) & M
        out.append(v ^ ((chave + s2) & M))
        chave = (((((~chave) & M) << 21) + 0x11111111) & M) | (chave >> 11)
        s2 = (v + s2 + (s2 << 5) + 3) & M
    return struct.pack("<%dI" % n, *out) + dados[n * 4:]


def construir_mpq(arquivos, shift=1):
    """arquivos: nome -> (bytes, modo) com modo em plain/zlib/bz2/zlib_enc/single"""
    setor = 512 << shift
    corpo = bytearray()
    blocos, nomes = [], []
    base = 32  # logo apos o cabecalho
    for nome, (dados, modo) in arquivos.items():
        pos = base + len(corpo)
        flags = X.F_EXISTS
        enc = modo.endswith("_enc")
        modo_base = modo.replace("_enc", "")
        chave = X.hash_str(nome.split("\\")[-1], 3) if enc else 0
        if enc:
            flags |= X.F_ENC
        if modo_base == "single":
            flags |= X.F_SINGLE | X.F_COMPRESS
            raw = b"\x02" + zlib.compress(dados)
            if enc:
                raw = cifrar(raw, chave)
            corpo += raw
            blocos.append((pos, len(raw), len(dados), flags))
        elif modo_base in ("zlib", "bz2"):
            flags |= X.F_COMPRESS
            n = (len(dados) + setor - 1) // setor
            partes = []
            for i in range(n):
                p = dados[i * setor:(i + 1) * setor]
                c = (b"\x02" + zlib.compress(p)) if modo_base == "zlib" else (b"\x10" + bz2.compress(p))
                if len(c) >= len(p):
                    c = p
                partes.append(c)
            offs, o = [], (n + 1) * 4
            for c in partes:
                offs.append(o)
                o += len(c)
            offs.append(o)
            tab = struct.pack("<%dI" % (n + 1), *offs)
            if enc:
                tab = cifrar(tab, (chave - 1) & M)
                partes = [cifrar(c, (chave + i) & M) if len(c) >= 4 else c
                          for i, c in enumerate(partes)]
            raw = tab + b"".join(partes)
            corpo += raw
            blocos.append((pos, len(raw), len(dados), flags))
        else:  # plain
            raw = dados
            if enc:
                raw = b"".join(cifrar(dados[i:i + setor], (chave + k) & M) if len(dados[i:i + setor]) % 4 == 0
                               else dados[i:i + setor]
                               for k, i in enumerate(range(0, len(dados), setor)))
            corpo += raw
            blocos.append((pos, len(raw), len(dados), flags))
        nomes.append(nome)
    hash_n = 16
    ht = [(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFF, 0xFFFF, 0xFFFFFFFF)] * hash_n
    ht = list(ht)
    for idx, nome in enumerate(nomes):
        i = X.hash_str(nome, 0) & (hash_n - 1)
        while ht[i][4] != 0xFFFFFFFF:
            i = (i + 1) % hash_n
        ht[i] = (X.hash_str(nome, 1), X.hash_str(nome, 2), 0, 0, idx)
    hbytes = b"".join(struct.pack("<IIHHI", *e) for e in ht)
    bbytes = b"".join(struct.pack("<IIII", *b) for b in blocos)
    hash_pos = base + len(corpo)
    block_pos = hash_pos + len(hbytes)
    hbytes = cifrar(hbytes, X.hash_str("(hash table)", 3))
    bbytes = cifrar(bbytes, X.hash_str("(block table)", 3))
    total = block_pos + len(bbytes)
    cab = struct.pack("<4sIIHHIIII", b"MPQ\x1a", 32, total, 0, shift, hash_pos, block_pos,
                      hash_n, len(blocos))
    return b"HM3W" + b"\x00" * 508 + cab + bytes(corpo) + hbytes + bbytes


def str_obj(texto):
    return texto.encode() + b"\x00"


def campo(id4, tipo, valor, nivel=None):
    b = id4.encode() + struct.pack("<I", tipo)
    if nivel is not None:
        b += struct.pack("<II", nivel, 0)
    if tipo == 0:
        b += struct.pack("<i", valor)
    elif tipo in (1, 2):
        b += struct.pack("<f", valor)
    else:
        b += str_obj(valor)
    return b + b"\x00\x00\x00\x00"


def objeto(base, novo, campos):
    return (base.encode() + (novo.encode() if novo else b"\x00" * 4)
            + struct.pack("<I", len(campos)) + b"".join(campos))


def main():
    w3u = (struct.pack("<I", 1) + struct.pack("<I", 0) + struct.pack("<I", 2)
           + objeto("Hpal", "H001", [campo("unam", 3, "TRIGSTR_001"), campo("ustr", 0, 20),
                                      campo("ua1b", 0, 49)])
           + objeto("hfoo", "u002", [campo("unam", 3, "Genin")]))
    w3t = (struct.pack("<I", 1) + struct.pack("<I", 0) + struct.pack("<I", 1)
           + objeto("rat6", "I001", [campo("unam", 3, "Kunai"), campo("igol", 0, 350)]))
    w3a = (struct.pack("<I", 2) + struct.pack("<I", 0) + struct.pack("<I", 1)
           + objeto("AHbz", "A001", [campo("anam", 3, "Rasengan", 0),
                                     campo("Hbz1", 1, 1.5, 1), campo("Hbz1", 1, 2.5, 2)]))
    wts = "STRING 1\n{\nYamato\n}\n\nSTRING 2\n// comentario\n{\nOutro texto\n}\n"
    script = "\n".join("// linha %d ninjutsu * %d" % (i, i) for i in range(400)).encode()
    arquivos = {
        "(listfile)": (b"war3map.w3u\r\nwar3map.w3t\r\nwar3map.w3a\r\nwar3map.wts\r\nwar3map.j\r\n", "plain"),
        "war3map.w3u": (w3u, "zlib_enc"),
        "war3map.w3t": (w3t, "single"),
        "war3map.w3a": (w3a, "bz2"),
        "war3map.wts": (wts.encode(), "plain"),
        "war3map.j": (script, "zlib"),
        "Units\\ItemStrings.txt": (b"[I001]\r\nName=TRIGSTR_002\r\nTip=Comprar\r\n", "plain"),
    }
    with tempfile.TemporaryDirectory() as tmp:
        mapa = Path(tmp) / "teste.w3x"
        mapa.write_bytes(construir_mpq(arquivos))
        mpq = X.MPQ(str(mapa))
        for nome, (dados, _) in arquivos.items():
            assert mpq.ler(nome) == dados, "conteudo diferente: " + nome
        saida = Path(tmp) / "saida"
        erros = X.extrair(X.FonteMapa(mpq), saida, lambda *_: None)
        assert not erros, erros
        assert json.loads((saida / "textos_objetos.json").read_text(encoding="utf-8"))["I001"]["Name"] == "Outro texto"
        un = json.loads((saida / "unidades.json").read_text(encoding="utf-8"))
        assert un[0]["id"] == "H001" and un[0]["nome"] == "Yamato" and un[0]["campos"]["ustr"] == 20
        it = json.loads((saida / "itens.json").read_text(encoding="utf-8"))
        assert it[0]["nome"] == "Kunai" and it[0]["textos"]["Tip"] == "Comprar" and it[0]["campos"]["igol"] == 350
        ha = json.loads((saida / "habilidades.json").read_text(encoding="utf-8"))
        assert ha[0]["campos"]["Hbz1"] == {"1": 1.5, "2": 2.5} and ha[0]["nome"] == "Rasengan"
        assert (saida / "pistas_atributos.txt").exists()
        assert (saida / "scripts" / "war3map.j").exists()
        # modo pasta
        saida2 = Path(tmp) / "saida2"
        X.extrair(X.FontePasta(saida / "scripts"), saida2, lambda *_: None)
    print("TODOS OS TESTES PASSARAM")


if __name__ == "__main__":
    main()
