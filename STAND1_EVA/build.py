#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gera o .rbz do EVA e atualiza o latest.json (auto-update).

Equivalente ao build.ps1, mas roda em qualquer sistema (Windows, macOS, Linux) e
também onde não há PowerShell — é o que permite publicar a atualização sem
depender da máquina do Tarcisio.

Uso:
    python build.py --notas "RENDER IA: ... MAPA DE ARTES: ..."
    python build.py --sem-manifesto        # só gera o .rbz (não mexe no latest.json)

O que faz (igual ao build.ps1):
  1. lê a versão de eva_ext.version no STAND1_EVA_loader.rb;
  2. move os outros .rbz da raiz para versoes_anteriores/;
  3. gera STAND1_EVA_v<versão>.rbz: loader na raiz + toda a pasta STAND1_EVA/, com
     barra normal (/) nos caminhos (o instalador do SketchUp exige);
  4. atualiza o latest.json (versao, rbz, notas) em UTF-8 SEM BOM — o JSON.parse do
     Ruby falha com BOM.

Extras: confere o pacote (loader na raiz, sem barra invertida, sintaxe Ruby de cada
.rb quando o ruby estiver instalado) e ABORTA antes de mexer no latest.json se algo
estiver errado — assim o auto-update nunca aponta para um pacote quebrado.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO_URL = 'https://raw.githubusercontent.com/tatazera/vibe-coding/main/STAND1_EVA'
IGNORAR = {'.DS_Store', 'Thumbs.db', 'desktop.ini'}


def ler_versao():
    txt = (ROOT / 'STAND1_EVA_loader.rb').read_text(encoding='utf-8')
    m = re.search(r"version\s*=\s*'([\d.]+)'", txt)
    if not m:
        sys.exit('ERRO: versão não encontrada no STAND1_EVA_loader.rb')
    return m.group(1)


def arquivos_do_plugin():
    src = ROOT / 'STAND1_EVA'
    itens = []
    for p in sorted(src.rglob('*')):
        if p.is_file() and p.name not in IGNORAR and '__pycache__' not in p.parts:
            itens.append(p)
    return itens


def montar_rbz(ver):
    out = ROOT / f'STAND1_EVA_v{ver}.rbz'
    arquivo = ROOT / 'versoes_anteriores'
    arquivo.mkdir(exist_ok=True)
    # Mantém só o .rbz atual na raiz (os anteriores vão para versoes_anteriores).
    for velho in ROOT.glob('STAND1_EVA_v*.rbz'):
        if velho.name != out.name:
            destino = arquivo / velho.name
            if destino.exists():
                destino.unlink()
            shutil.move(str(velho), str(destino))
            print(f'Arquivado: {velho.name} -> versoes_anteriores/')
    if out.exists():
        out.unlink()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(ROOT / 'STAND1_EVA_loader.rb', 'STAND1_EVA_loader.rb')
        for p in arquivos_do_plugin():
            z.write(p, p.relative_to(ROOT).as_posix())
    return out


def conferir(out):
    """Aborta se o pacote não servir para instalar."""
    problemas = []
    with zipfile.ZipFile(out) as z:
        nomes = z.namelist()
        if z.testzip() is not None:
            problemas.append('zip corrompido')
        if 'STAND1_EVA_loader.rb' not in nomes:
            problemas.append('loader fora da raiz do pacote')
        if any('\\' in n for n in nomes):
            problemas.append('caminho com barra invertida')
        for obrigatorio in ('STAND1_EVA/core.rb', 'STAND1_EVA/html/dialog.html'):
            if obrigatorio not in nomes:
                problemas.append(f'falta {obrigatorio}')
        ruby = shutil.which('ruby')
        if ruby:
            for n in nomes:
                if n.endswith('.rb'):
                    r = subprocess.run([ruby, '-c'], input=z.read(n), capture_output=True)
                    if r.returncode != 0:
                        problemas.append(f'sintaxe Ruby: {n}: {r.stderr.decode("utf-8", "replace").strip()[:120]}')
        else:
            print('Aviso: ruby não encontrado; sintaxe dos .rb não conferida.')
    if problemas:
        out.unlink()
        sys.exit('ERRO: pacote reprovado, nada foi publicado:\n  - ' + '\n  - '.join(problemas))
    print(f'Pacote conferido: {len(nomes)} arquivos, sintaxe ok.')


def notas_sem_versao(antigas, ver):
    """Tira das notas antigas o trecho 'v<ver>: ...' (para regerar a mesma versão sem duplicar)."""
    partes = re.split(r'\s(?=v\d+\.\d+\.\d+:)', ' ' + antigas.strip())
    partes = [p.strip() for p in partes if p.strip() and not p.strip().startswith(f'v{ver}:')]
    return ' '.join(partes)


def atualizar_manifesto(ver, notas_novas):
    manifesto = ROOT / 'latest.json'
    antigas = 'Atualizacao do EVA Stand1.'
    if manifesto.exists():
        try:
            antigas = json.loads(manifesto.read_text(encoding='utf-8-sig')).get('notas') or antigas
        except Exception:
            pass
    historico = notas_sem_versao(antigas, ver)
    if notas_novas:
        notas = f'v{ver}: {notas_novas.strip()} {historico}'.strip()
    else:
        notas = antigas
    obj = {'versao': ver, 'rbz': f'{REPO_URL}/STAND1_EVA_v{ver}.rbz', 'notas': notas}
    # Sem BOM: o JSON.parse do Ruby falha com BOM (EF BB BF) no início.
    manifesto.write_bytes(json.dumps(obj, ensure_ascii=False, indent=4).encode('utf-8'))
    print(f'Manifesto atualizado: latest.json (v{ver})')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--notas', default='', help='notas desta versão (entram no início das notas do latest.json)')
    ap.add_argument('--sem-manifesto', action='store_true', help='só gera o .rbz; não altera o latest.json')
    a = ap.parse_args()

    ver = ler_versao()
    out = montar_rbz(ver)
    print(f'Gerado: {out.name}')
    conferir(out)
    if a.sem_manifesto:
        print('latest.json NÃO foi alterado (--sem-manifesto).')
    else:
        atualizar_manifesto(ver, a.notas)


if __name__ == '__main__':
    main()
