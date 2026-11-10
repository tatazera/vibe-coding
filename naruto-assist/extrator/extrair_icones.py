#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Extrai os ICONES usados pelo sugestor de builds direto do mapa (.w3x) e gera
icones.json (PNG pequeno em base64, um por caminho). Uso pessoal: nao publique.

Requer: Python 3.8+ e Pillow  ->  pip install pillow

Uso:
  python extrair_icones.py "C:\\mapa.w3x" dados.json
  python extrair_icones.py                 (pergunta os caminhos)
"""
import argparse
import base64
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extrair_mapa as X  # noqa: E402


def coletar_caminhos(d):
    caminhos = set()
    for h in d.get("herois", []):
        caminhos.add(h.get("icone", ""))
        for s in h.get("skills", []):
            caminhos.add(s.get("icone", ""))
    for i in d.get("itens", []):
        caminhos.add(i.get("icone", ""))
    for r in d.get("receitas", []):
        caminhos.add(r.get("icone", ""))
    return sorted(c for c in caminhos if c)


def variantes(caminho):
    base = caminho.replace("/", "\\")
    v = [base]
    if "." not in base.split("\\")[-1]:
        v.append(base + ".blp")
    if base.lower().endswith(".blp"):
        v.append(base[:-4] + ".tga")
    return v


def converter(dados, tam):
    from PIL import Image  # noqa: WPS433
    img = Image.open(io.BytesIO(dados))
    img.load()
    img = img.convert("RGBA").resize((tam, tam), Image.LANCZOS)
    saida = io.BytesIO()
    img.save(saida, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(saida.getvalue()).decode("ascii")


def extrair(mpq, caminhos, tam, log=print):
    icones, ausentes, falhas = {}, [], []
    for c in caminhos:
        dados = None
        for v in variantes(c):
            if mpq.existe(v):
                try:
                    dados = mpq.ler(v)
                    break
                except Exception as e:  # noqa: BLE001
                    falhas.append("%s: leitura (%s)" % (c, e))
        if dados is None:
            ausentes.append(c)
            continue
        try:
            icones[c] = converter(dados, tam)
        except Exception as e:  # noqa: BLE001
            falhas.append("%s: imagem (%s)" % (c, e))
    log("Icones: %d de %d extraidos | %d fora do mapa | %d com falha"
        % (len(icones), len(caminhos), len(ausentes), len(falhas)))
    return icones, ausentes, falhas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mapa", nargs="?")
    ap.add_argument("dados", nargs="?", help="dados.json gerado por montar_dados.py")
    ap.add_argument("-o", "--saida", default="icones.json")
    ap.add_argument("--tam", type=int, default=56)
    a = ap.parse_args()
    interativo = not (a.mapa and a.dados)
    try:
        import PIL  # noqa: F401
    except ImportError:
        print("Falta o Pillow. Rode:  pip install pillow")
        if interativo:
            input("Enter para fechar.")
        sys.exit(1)
    try:
        mapa = a.mapa or input("Arraste o .w3x aqui e aperte Enter:\n> ").strip().strip('"')
        dados = a.dados or input("Arraste o dados.json aqui e aperte Enter:\n> ").strip().strip('"')
        d = json.loads(Path(dados).read_text(encoding="utf-8"))
        mpq = X.MPQ(mapa)
        icones, ausentes, falhas = extrair(mpq, coletar_caminhos(d), a.tam)
        Path(a.saida).write_text(json.dumps(icones, separators=(",", ":")), encoding="utf-8")
        if ausentes:
            Path(a.saida).with_name("icones_ausentes.txt").write_text("\n".join(ausentes), encoding="utf-8")
        if falhas:
            Path(a.saida).with_name("icones_falhas.txt").write_text("\n".join(falhas), encoding="utf-8")
            print("Primeiras falhas:", *falhas[:5], sep="\n  ")
        print("\nPronto! Envie no chat: %s (%.1f MB)" % (Path(a.saida).resolve(), Path(a.saida).stat().st_size / 1e6))
    except Exception as e:  # noqa: BLE001
        print("\nERRO:", e)
    if interativo:
        input("\nAperte Enter para fechar.")


if __name__ == "__main__":
    main()
