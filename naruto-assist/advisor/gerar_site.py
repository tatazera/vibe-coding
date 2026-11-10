#!/usr/bin/env python3
"""Gera sugestor_builds.html (arquivo unico) a partir de dados.json + sugestor_template.html."""
import json
import sys
from pathlib import Path

aqui = Path(__file__).resolve().parent
dados = (aqui / "dados.json").read_text(encoding="utf-8")
json.loads(dados)  # valida
modelo = (aqui / "sugestor_template.html").read_text(encoding="utf-8")
if "/*DADOS*/null" not in modelo:
    sys.exit("marcador /*DADOS*/null nao encontrado no modelo")
html = modelo.replace("/*DADOS*/null", dados.replace("</", "<\\/"))
saida = aqui / "sugestor_builds.html"
saida.write_text(html, encoding="utf-8")
print("gerado:", saida, "(%.0f KB)" % (saida.stat().st_size / 1024))
