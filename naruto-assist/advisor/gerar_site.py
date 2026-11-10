#!/usr/bin/env python3
"""Gera o site "Ninpou Reforged Builds" (arquivo unico) a partir de dados.json + sugestor_template.html.

A versao vem de versao.txt (r00, r01, r02...): aparece no titulo, no topo da pagina e no nome do arquivo.
  - Sem icones.json:  Ninpou_Reforged_Builds_<versao>_sem-icones.html  (pode ir para o repositorio)
  - Com icones.json:  Ninpou_Reforged_Builds_<versao>.html             (uso pessoal; nao publicar)

Uso: python gerar_site.py [icones.json]
"""
import json
import sys
from pathlib import Path

aqui = Path(__file__).resolve().parent
versao = (aqui / "versao.txt").read_text(encoding="utf-8").strip() or "r00"
dados = (aqui / "dados.json").read_text(encoding="utf-8")
json.loads(dados)  # valida
modelo = (aqui / "sugestor_template.html").read_text(encoding="utf-8")
for marca in ("/*DADOS*/null", "/*ICONES*/{}", "/*VERSAO*/"):
    if marca not in modelo:
        sys.exit("marcador %s nao encontrado no modelo" % marca)

arq_icones = Path(sys.argv[1]) if len(sys.argv) > 1 else aqui / "icones.json"
icones, com_icones = "{}", False
if arq_icones.exists():
    icones = arq_icones.read_text(encoding="utf-8")
    json.loads(icones)
    com_icones = True
    print("icones embutidos:", arq_icones, "(%.1f MB)" % (len(icones) / 1e6))
else:
    print("sem icones.json: usando icones simples (iniciais)")

seguro = lambda t: t.replace("</", "<\\/")
html = (modelo.replace("/*DADOS*/null", seguro(dados)).replace("/*ICONES*/{}", seguro(icones))
        .replace("/*VERSAO*/", versao))
nome = "Ninpou_Reforged_Builds_%s%s.html" % (versao, "" if com_icones else "_sem-icones")
saida = aqui / nome
saida.write_text(html, encoding="utf-8")
print("gerado:", saida, "(%.0f KB)" % (saida.stat().st_size / 1024))
