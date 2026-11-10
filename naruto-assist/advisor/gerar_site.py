#!/usr/bin/env python3
"""Gera sugestor_builds.html (arquivo unico) a partir de dados.json + sugestor_template.html.
Se existir icones.json (gerado por extrator/extrair_icones.py), os icones sao embutidos.

Uso: python gerar_site.py [icones.json]
"""
import json
import sys
from pathlib import Path

aqui = Path(__file__).resolve().parent
dados = (aqui / "dados.json").read_text(encoding="utf-8")
json.loads(dados)  # valida
modelo = (aqui / "sugestor_template.html").read_text(encoding="utf-8")
for marca in ("/*DADOS*/null", "/*ICONES*/{}"):
    if marca not in modelo:
        sys.exit("marcador %s nao encontrado no modelo" % marca)

arq_icones = Path(sys.argv[1]) if len(sys.argv) > 1 else aqui / "icones.json"
icones = "{}"
if arq_icones.exists():
    icones = arq_icones.read_text(encoding="utf-8")
    json.loads(icones)
    print("icones embutidos:", arq_icones, "(%.1f MB)" % (len(icones) / 1e6))
else:
    print("sem icones.json: usando icones simples (iniciais)")

seguro = lambda t: t.replace("</", "<\\/")
html = modelo.replace("/*DADOS*/null", seguro(dados)).replace("/*ICONES*/{}", seguro(icones))
saida = aqui / "sugestor_builds.html"
saida.write_text(html, encoding="utf-8")
print("gerado:", saida, "(%.0f KB)" % (saida.stat().st_size / 1024))
