# EVA Stand1 — como publicar

Quando o Tarcisio pedir **"subir"**, **"publicar"** ou **"atualizar"**, ele quer a versão
disponível **direto no GitHub (branch `main`)**, pronta para o auto-update do plugin — não só o
código. Isso vale como autorização para dar push no `main`.

O plugin se atualiza lendo `STAND1_EVA/latest.json` do `main` e baixando o `.rbz` indicado nele.
Por isso o código, o `.rbz` e o `latest.json` precisam subir **juntos**.

## Passos (não dependem de PowerShell)

1. Se houve mudança, suba a versão em `STAND1_EVA/STAND1_EVA_loader.rb` (`eva_ext.version`).
2. Gere o pacote e o manifesto:
   ```bash
   python3 STAND1_EVA/build.py --notas "o que mudou, em português, direto ao ponto"
   ```
   O `build.py` faz o mesmo que o `build.ps1`: gera `STAND1_EVA_v<versão>.rbz`, move o `.rbz`
   anterior para `versoes_anteriores/`, atualiza `latest.json` (UTF-8 sem BOM, notas novas no início
   e histórico preservado) e **aborta, sem mexer no `latest.json`, se o pacote estiver quebrado**
   (loader fora da raiz, barra invertida, sintaxe Ruby inválida).
3. Commite tudo num commit só (código + `.rbz` novo + `.rbz` arquivado + `latest.json`). O
   `latest.json` nunca pode apontar para um `.rbz` que não está no `main`.
4. `git push origin HEAD:main` (se a branch de trabalho estiver à frente do `main`, é um avanço
   direto; confira com `git merge-base --is-ancestor origin/main HEAD`).
5. Confira no remoto: `git show origin/main:STAND1_EVA/latest.json`.

## Observações

- O auto-update é opt-in: o plugin mostra o banner "Atualizar" e ninguém recebe a versão sem clicar.
- Para desfazer uma publicação: `git revert` do commit de publicação (restaura o `latest.json`
  anterior) e novo push.
- Os testes de interface/Ruby usados no desenvolvimento não ficam no repositório (vivem no
  scratchpad da sessão); rode a bateria que existir antes de publicar e diga o que foi testado e o
  que só dá para conferir no SketchUp real.
- Respostas em português do Brasil, diretas e práticas.
