#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gera o .rbz do EVA e atualiza o latest.json (auto-update).

Equivalente ao build.ps1, mas roda em qualquer sistema (Windows, macOS, Linux) e
também onde não há PowerShell — é o que permite publicar a atualização sem
depender da máquina do Tarcisio.

Uso:
    python build.py --notas "Resumo curto da versão (até 400 caracteres)" [--detalhe "texto completo"]
    python build.py --sem-manifesto        # só gera o .rbz (não mexe no latest.json)
    python build.py --so-manifesto --notas "..."   # só atualiza o latest.json (não refaz o .rbz)

IMPORTANTE sobre as notas: o plugin mostra o campo "notas" INTEIRO no banner de atualização,
então ele tem que ser curto (só o que mudou nesta versão). O texto completo e o histórico das
versões ficam no campo "historico" do latest.json, que o plugin ignora.

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
LIMITE_NOTAS = 400   # o banner do plugin mostra o campo "notas" inteiro


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


def conferir(out, remover_se_ruim=True):
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
        if remover_se_ruim:
            out.unlink()
        sys.exit('ERRO: pacote reprovado, nada foi publicado:\n  - ' + '\n  - '.join(problemas))
    print(f'Pacote conferido: {len(nomes)} arquivos, sintaxe ok.')


def historico_do_manifesto(j):
    """Lista [{versao, notas}] do manifesto. Migra o formato antigo (notas acumuladas
    "v2.6.4: ... v2.6.3: ...") para a lista, para não perder nada."""
    h = j.get('historico')
    if isinstance(h, list) and h:
        return [{'versao': str(e.get('versao', '')), 'notas': str(e.get('notas', ''))}
                for e in h if isinstance(e, dict) and e.get('versao')]
    antigas = (j.get('notas') or '').strip()
    out = []
    for parte in re.split(r'\s(?=v\d+\.\d+\.\d+:)', ' ' + antigas):
        m = re.match(r'\s*v(\d+\.\d+\.\d+):\s*(.*)', parte, re.S)
        if m:
            out.append({'versao': m.group(1), 'notas': m.group(2).strip()})
    return out


def atualizar_manifesto(ver, notas, detalhe):
    manifesto = ROOT / 'latest.json'
    atual = {}
    if manifesto.exists():
        try:
            atual = json.loads(manifesto.read_text(encoding='utf-8-sig'))
        except Exception:
            atual = {}
    hist = historico_do_manifesto(atual)
    anterior = next((e['notas'] for e in hist if e['versao'] == ver), '')
    hist = [e for e in hist if e['versao'] != ver]
    hist.insert(0, {'versao': ver, 'notas': (detalhe or anterior or notas or '').strip()})

    banner = (notas or '').strip()
    if not banner:                     # sem --notas: reaproveita as do manifesto, se forem curtas
        banner = '' if re.search(r'v\d+\.\d+\.\d+:', atual.get('notas') or '') else (atual.get('notas') or '')
    if not banner:
        banner = 'Atualização do EVA Stand1.'
    if len(banner) > LIMITE_NOTAS:
        sys.exit(f'ERRO: as notas do banner têm {len(banner)} caracteres (máximo {LIMITE_NOTAS}). '
                 'O plugin mostra o campo "notas" inteiro no banner: escreva curto e use --detalhe '
                 'para o texto completo. Nada foi alterado no latest.json.')

    obj = {'versao': ver, 'rbz': f'{REPO_URL}/STAND1_EVA_v{ver}.rbz', 'notas': banner, 'historico': hist}
    # Sem BOM: o JSON.parse do Ruby falha com BOM (EF BB BF) no início.
    manifesto.write_bytes(json.dumps(obj, ensure_ascii=False, indent=4).encode('utf-8'))
    print(f'Manifesto atualizado: latest.json (v{ver}; banner com {len(banner)} caracteres; '
          f'{len(hist)} versões no histórico)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--notas', default='', help=f'resumo CURTO desta versão, mostrado no banner (máx {LIMITE_NOTAS} caracteres)')
    ap.add_argument('--detalhe', default='', help='texto completo desta versão (vai só para o histórico do latest.json)')
    ap.add_argument('--sem-manifesto', action='store_true', help='só gera o .rbz; não altera o latest.json')
    ap.add_argument('--so-manifesto', action='store_true', help='só atualiza o latest.json; não refaz o .rbz')
    a = ap.parse_args()
    if a.sem_manifesto and a.so_manifesto:
        sys.exit('ERRO: --sem-manifesto e --so-manifesto não podem ser usados juntos.')

    ver = ler_versao()
    if a.so_manifesto:
        rbz = ROOT / f'STAND1_EVA_v{ver}.rbz'
        if not rbz.exists():
            sys.exit(f'ERRO: {rbz.name} não existe na pasta; gere o pacote antes (sem --so-manifesto).')
        conferir_existente = rbz
        conferir(conferir_existente, remover_se_ruim=False)
    else:
        out = montar_rbz(ver)
        print(f'Gerado: {out.name}')
        conferir(out)
    if a.sem_manifesto:
        print('latest.json NÃO foi alterado (--sem-manifesto).')
    else:
        atualizar_manifesto(ver, a.notas, a.detalhe)


if __name__ == '__main__':
    main()
