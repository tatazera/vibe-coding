# encoding: UTF-8
# =============================================================================
# EVA Stand1 — mapa_artes.rb
# Aba "Mapa de Artes": um quadro por ambiente com as peças de comunicação visual
# de frente, cotadas e com quantidade — no formato do mapa de artes que vai
# para conferência e produção (impressão / confecção).
#
# FLUXO
#   1. Ler      — varre o modelo UMA vez, rápido e com limite (não trava):
#                 componentes repetidos são lidos uma vez só, o que não tem arte
#                 é pulado inteiro, e passou do limite de tempo/peças, para e avisa.
#   2. Peças    — faces vizinhas no mesmo plano e do mesmo material viram UMA
#                 peça (com recortes e linhas de módulo); frente e verso viram
#                 uma peça só; peças iguais viram "N und.".
#   3. Ambientes — peças próximas formam um ambiente (num arquivo com vários
#                 espaços, cada espaço é um ambiente; num estande só, um só).
#                 O nome vem da cena que olha para ele.
#   4. Desenho  — um quadro por ambiente no grupo "KV - Mapa de Artes": título,
#                 peças de frente (leitura pela vista Frente), cota de largura no
#                 topo, altura à esquerda, cotas em corrente dos recortes e a
#                 etiqueta "NOME – N und.". Desenha em etapas (o SketchUp continua
#                 respondendo) e tudo sai num Ctrl+Z só.
#
# O modelo real nunca é alterado: as peças são cópias.
# =============================================================================

require 'json'

module STAND1
  module EVA
    module MapaArtes

      ATTR_NS = 'EVA'    # namespace de atributos
      KV_TAG  = 'KV'     # tag do grupo KV
      POL_M   = 0.0254   # polegada -> metro
      M       = 1.0 / POL_M

      # ── Reconhecimento de materiais de comunicação visual ───────────────────
      # Casa por "contém", sobre o nome normalizado (minúsculo, sem acento).
      KEYWORDS = [
        'adesivo', 'adesivado', 'vinil', 'plotter', 'plotagem', 'decalque', 'sticker',
        'lona', 'banner', 'tecido impresso', 'backdrop', 'front light', 'back light',
        'pvc', 'acm', 'acrilico', 'mdf impresso',
        'letra caixa', 'letracaixa', 'letra-caixa',
        'impress',                 # impresso / impressa / impressão
        'comunicacao visual', 'logo', 'testeira', 'painel grafico'
      ].freeze

      # Falsos positivos comuns — se o nome casar com algo daqui, não é arte.
      EXCLUDE = ['pvc branco liso', 'pvc estrutural'].freeze

      # Nomes que não dizem nada (o nome da peça cai no material).
      NOME_GENERICO = /\A\s*(grupo|group|componente|component|ret[aâ]ngulo|rectangle|face|sem nome|untitled|copy|c[oó]pia)?\s*(#\s*\d+)?\s*\z/i

      # ── Limites (o SketchUp não pode travar) ────────────────────────────────
      LER_MAX_NOS   = 80_000   # grupos/componentes visitados por leitura
      LER_MAX_SEG   = 25.0     # segundos por leitura
      LER_MAX_FACES = 25_000   # faces de arte lidas
      LOTE_SEG      = 0.15     # tempo de desenho por etapa (depois devolve o controle)

      # Padrões da aba
      GAP_PADRAO_M  = 3.0      # distância que separa dois ambientes
      MIN_LADO_CM   = 3.0      # peça mais estreita que isso = espessura (borda de PVC/ACM de até 2 cm, perfil)

      # Tolerâncias (polegadas)
      TOL_PLANO = 0.04         # ~1 mm entre planos
      TOL_TOQUE = 0.08         # ~2 mm para faces vizinhas
      FV_MIN    = 0.03 * M     # mais perto que isso = a mesma chapa (PVC, ACM): conta uma vez
      FV_MAX    = 0.30 * M     # frente e verso: placas a até 30 cm uma da outra

      # ══════════════════════════════════════════════════════════════════════
      # ENTRADAS PÚBLICAS (callbacks do diálogo e toolbar)
      # ══════════════════════════════════════════════════════════════════════

      # Aba → "Ler ambientes". cfg: { gap, min_cm }.
      def self.ler_from_dialog(msg, dlg = nil)
        cfg   = parse_cfg(msg)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        t0 = Time.now
        @leitura = ler_modelo(model, cfg)
        res = resumo(@leitura)
        res[:segundos] = (Time.now - t0).round(1)
        dlg.execute_script("window.mapaAmbientes(#{res.to_json})") if dlg && dlg.visible?
        res
      rescue => e
        notify("Erro na leitura: #{e.message}", false, dlg)
      end

      # Aba → "Gerar mapa". cfg: { ambientes: [ids], nomes: {id=>nome}, mats: [keys], labels }.
      def self.gerar_from_dialog(msg, dlg = nil)
        cfg   = parse_cfg(msg)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        return notify('Já existe um mapa sendo desenhado.', false, dlg) if @job

        lt = @leitura
        unless lt && lt[:model] == model && leitura_valida?(lt)
          lt = @leitura = ler_modelo(model, cfg)
          if dlg && dlg.visible?
            dlg.execute_script("window.mapaAmbientes(#{resumo(lt).to_json})")
            return notify('O modelo mudou desde a leitura: a lista foi atualizada, confira e gere de novo.', false, dlg)
          end
        end

        ids  = (cfg['ambientes'] || []).map(&:to_i)
        envs = lt[:ambientes].select { |a| ids.include?(a[:id]) }
        return notify('Marque ao menos um ambiente.', false, dlg) if envs.empty?

        nomes = cfg['nomes'].is_a?(Hash) ? cfg['nomes'] : {}
        mats  = cfg['mats'].is_a?(Array) ? cfg['mats'].map(&:to_s) : nil
        quadros = envs.map do |a|
          nome  = nomes[a[:id].to_s].to_s.strip
          nome  = a[:nome] if nome.empty?
          pecas = mats ? a[:pecas].select { |p| mats.include?(p[:mat_key]) } : a[:pecas]
          { nome: nome, itens: agrupar_iguais(pecas) }
        end.reject { |q| q[:itens].empty? }
        return notify('Nenhuma peça nos ambientes/materiais marcados.', false, dlg) if quadros.empty?

        iniciar_desenho(model, quadros, cfg['labels'] != false, dlg)
      rescue => e
        @job = nil
        notify("Erro: #{e.message}", false, dlg)
      end

      # Aba → "Diagramar seleção": o que está selecionado vira um quadro só.
      def self.diagramar_from_dialog(msg, dlg = nil)
        cfg   = parse_cfg(msg)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        return notify('Já existe um mapa sendo desenhado.', false, dlg) if @job
        sel = model.selection.to_a
        return notify('Selecione faces, grupos ou componentes no SketchUp.', false, dlg) if sel.empty?

        lt = ler_selecao(model, sel, cfg)
        # Nada de comunicação visual na seleção: o usuário escolheu aquilo de
        # propósito, então vale qualquer face com material.
        lt = ler_selecao(model, sel, cfg.merge('qualquer' => true)) if lt[:pecas].empty?
        return notify('Nada diagramável na seleção (sem faces com material).', false, dlg) if lt[:pecas].empty?

        iniciar_desenho(model, [{ nome: 'SELEÇÃO', itens: agrupar_iguais(lt[:pecas]) }],
                        cfg['labels'] != false, dlg)
      rescue => e
        @job = nil
        notify("Erro: #{e.message}", false, dlg)
      end

      # Toolbar (sem diálogo): lê e desenha todos os ambientes.
      def self.diagramar_auto(_threshold_m = nil, dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        return notify('Já existe um mapa sendo desenhado.', false, dlg) if @job
        lt = @leitura = ler_modelo(model, {})
        if lt[:pecas].empty?
          return notify('Nenhuma peça de comunicação visual encontrada (adesivo / lona / PVC / letra caixa).', false, dlg)
        end
        quadros = lt[:ambientes].map { |a| { nome: a[:nome], itens: agrupar_iguais(a[:pecas]) } }
        iniciar_desenho(model, quadros, true, dlg)
      rescue => e
        @job = nil
        notify("Erro: #{e.message}", false, dlg)
      end

      def self.cancelar(dlg = nil)
        if @job
          @job[:cancelar] = true
        else
          notify('Nada sendo desenhado.', true, dlg)
        end
      end

      def self.parse_cfg(msg)
        c = msg.is_a?(Hash) ? msg : (JSON.parse(msg.to_s) rescue {})
        c.is_a?(Hash) ? c : {}
      end

      # ══════════════════════════════════════════════════════════════════════
      # LEITURA
      # ══════════════════════════════════════════════════════════════════════

      def self.novo_estado(cfg)
        @mat_cache  = {}
        @memo_faces = {}
        @memo_tem   = {}
        {
          t0: Time.now, nos: 0, faces: 0, unit_seq: 0, estourou: nil,
          qualquer: !!cfg['qualquer'],
          min_lado: ((cfg['min_cm'] || MIN_LADO_CM).to_s.tr(',', '.').to_f.then { |v| v > 0 ? v : MIN_LADO_CM }) / 100.0 * M,
          gap: ((cfg['gap'] || GAP_PADRAO_M).to_s.tr(',', '.').to_f.then { |v| v > 0 ? v : GAP_PADRAO_M }) * M
        }
      end

      # Modelo inteiro → { pecas, ambientes, avisos, model }.
      def self.ler_modelo(model, cfg)
        st    = novo_estado(cfg)
        faces = []
        # Geometria solta na raiz: uma unidade só (não há definição para memorizar).
        raiz = model.entities.grep(Sketchup::Face).select { |f| visivel?(f) }
                    .map { |f| face_local(f, nil, st) }.compact
        ler_nivel(model.entities, raiz, IDENT, nil, 0, nil, faces, st, true)
        pecas = montar_pecas(faces, st)
        ambientes = separar_ambientes(pecas, st[:gap])
        nomear_ambientes(ambientes, cameras_das_cenas(model))
        { model: model, pecas: pecas, ambientes: ambientes, avisos: avisos(st) }
      end

      # Seleção → as peças de dentro dela (sem separar ambientes).
      def self.ler_selecao(model, sel, cfg)
        st    = novo_estado(cfg)
        faces = []
        tw    = (model.edit_transform.to_a rescue IDENT)
        sel.each do |e|
          if e.is_a?(Sketchup::Face)
            fi = face_local(e, nil, st)
            emitir(fi, tw, 0, nil, faces, st) if fi
          elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
            next if kv_group?(e)
            h  = herdar(e, nil)
            em = mmul(tw, e.transformation.to_a)
            st[:unit_seq] += 1
            ler_nivel(e.definition.entities, faces_da_def(e.definition, h, st), em, h,
                      st[:unit_seq], nome_de(e), faces, st)
          end
        end
        { model: model, pecas: montar_pecas(faces, st), avisos: avisos(st) }
      end

      # Um nível: emite as faces de arte dele e desce nos grupos/componentes que
      # têm arte (os que não têm são pulados sem abrir).
      def self.ler_nivel(ents, faces_info, m, herdado, unit, nome, out, st, raiz = false)
        faces_info.each { |fi| emitir(fi, m, unit, nome, out, st) }
        ents.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          return if estourou?(st)
          next if kv_group?(e) || !visivel?(e)
          h = herdar(e, herdado)
          d = e.definition
          next unless def_tem_arte?(d, h, st)
          em = mmul(m, e.transformation.to_a)
          # Unidade = cada objeto da raiz e cada componente (uma cópia de estande);
          # grupos internos continuam na mesma unidade (módulos de um mesmo painel).
          u = (raiz || e.is_a?(Sketchup::ComponentInstance)) ? (st[:unit_seq] += 1) : unit
          ler_nivel(d.entities, faces_da_def(d, h, st), em, h, u, nome_de(e) || nome, out, st)
        end
      end

      def self.estourou?(st)
        return true if st[:estourou]
        st[:nos] += 1
        if st[:nos] > LER_MAX_NOS
          st[:estourou] = "a leitura passou de #{LER_MAX_NOS} grupos/componentes"
        elsif st[:faces] > LER_MAX_FACES
          st[:estourou] = "a leitura passou de #{LER_MAX_FACES} faces de arte"
        elsif st[:nos] % 200 == 0 && Time.now - st[:t0] > LER_MAX_SEG
          st[:estourou] = "a leitura passou de #{LER_MAX_SEG.round} s"
        end
        !st[:estourou].nil?
      end

      def self.avisos(st)
        st[:estourou] ? ["Leitura parcial: #{st[:estourou]}. Use \"Diagramar seleção\" para um ambiente específico."] : []
      end

      # Faces de arte DIRETAS de uma definição (coordenadas locais), memorizadas
      # por definição + material herdado: 150 estandes iguais = 1 leitura.
      def self.faces_da_def(defn, herdado, st)
        k = [defn, herdado && herdado[:key]]
        @memo_faces[k] ||= defn.entities.grep(Sketchup::Face)
                                        .select { |f| visivel?(f) }
                                        .map { |f| face_local(f, herdado, st) }.compact
      end

      def self.def_tem_arte?(defn, herdado, st)
        k = [defn, herdado && herdado[:key]]
        return @memo_tem[k] if @memo_tem.key?(k)
        @memo_tem[k] = false # trava recursão circular
        tem = !faces_da_def(defn, herdado, st).empty? ||
              defn.entities.any? do |e|
                (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
                  !kv_group?(e) && visivel?(e) && def_tem_arte?(e.definition, herdar(e, herdado), st)
              end
        @memo_tem[k] = tem
      end

      # Material do grupo/componente vale para as faces sem material dentro dele.
      def self.herdar(e, herdado)
        mat_info(e.material) || herdado
      rescue
        herdado
      end

      # Qual lado da face tem a arte: { face, info, lado, outer, holes } ou nil.
      def self.face_local(f, herdado, st)
        fm = mat_info(f.material)
        bm = mat_info(f.back_material)
        info, lado =
          if aceito?(fm, st)                then [fm, :front]
          elsif aceito?(bm, st)             then [bm, :back]
          elsif fm.nil? && aceito?(herdado, st) then [herdado, :herdado]
          end
        return nil unless info
        outer = f.outer_loop.vertices.map { |v| v.position.to_a }
        holes = f.loops.reject(&:outer?).map { |l| l.vertices.map { |v| v.position.to_a } }
        { face: f, info: info, lado: lado, outer: outer, holes: holes }
      rescue
        nil
      end

      def self.aceito?(info, st)
        return false unless info
        st[:qualquer] || info[:cv]
      end

      def self.mat_info(m)
        return nil unless m
        @mat_cache[m] ||= begin
          key = normalize(m.name.to_s)
          nome = (m.display_name.to_s rescue m.name.to_s).strip
          cv = !key.empty? && EXCLUDE.none? { |x| key.include?(x) } && KEYWORDS.any? { |k| key.include?(k) }
          { cv: cv, key: key, nome: nome.empty? ? m.name.to_s : nome, mat: m }
        end
      end

      def self.nome_de(e)
        n = e.name.to_s.strip
        n = e.definition.name.to_s.sub(/#\d+\z/, '').strip if n.empty? && e.is_a?(Sketchup::ComponentInstance)
        (n.empty? || n =~ NOME_GENERICO) ? nil : n
      rescue
        nil
      end

      def self.visivel?(e)
        return false if e.respond_to?(:hidden?) && e.hidden?
        l = e.respond_to?(:layer) ? e.layer : nil
        l.nil? || !l.respond_to?(:visible?) || l.visible?
      rescue
        true
      end

      def self.kv_group?(g)
        g.get_attribute(ATTR_NS, 'kv', nil) == '1'
      rescue
        false
      end

      # Face local → face no mundo, no referencial de quem OLHA a arte:
      # n = normal do lado com arte; right/up = eixos da peça vista de frente
      # (sem espelhar, mesmo quando a arte está no verso da face).
      def self.emitir(fi, m, unit, nome, out, st)
        st[:faces] += 1
        ow = fi[:outer].map { |p| mpt(m, p) }
        n  = newell(ow)
        return if vlen(n) < 1e-9
        n  = vnorm(n)
        n  = vscl(n, -1.0) if mdet3(m) < 0          # cópia espelhada inverte o giro do loop
        n  = vscl(n, -1.0) if fi[:lado] == :back
        up = vnorm(vsub([0.0, 0.0, 1.0], vscl(n, n[2])))
        up = vnorm(vsub([0.0, 1.0, 0.0], vscl(n, n[1]))) if vlen(up) < 1e-6
        return if vlen(up) < 1e-6
        right = vnorm(vcross(up, n))

        uv    = ->(p) { [vdot(p, right), vdot(p, up)] }
        ouv   = ow.map(&uv)
        huv   = fi[:holes].map { |h| h.map { |p| uv.call(mpt(m, p)) } }
        us = ouv.map(&:first); vs = ouv.map(&:last)
        return if us.max - us.min < 1e-3 || vs.max - vs.min < 1e-3
        xs = ow.map { |p| p[0] }; ys = ow.map { |p| p[1] }; zs = ow.map { |p| p[2] }

        out << {
          src: fi[:face], info: fi[:info], lado: fi[:lado], local: fi[:outer],
          unit: unit, nome: nome, n: n, right: right, up: up, d: vdot(ow[0], n),
          nk: n.map { |c| (c * 50).round },
          ouv: ouv, huv: huv,
          umin: us.min, umax: us.max, vmin: vs.min, vmax: vs.max,
          area: poly_area(ouv) - huv.sum { |h| poly_area(h) },
          bb: [xs.min, ys.min, zs.min, xs.max, ys.max, zs.max]
        }
      end

      # ══════════════════════════════════════════════════════════════════════
      # PEÇAS (Ruby puro)
      # ══════════════════════════════════════════════════════════════════════

      # Faces → peças: mesma unidade, mesmo material, mesmo plano e encostadas.
      def self.montar_pecas(faces, st)
        pecas = []
        faces.group_by { |f| [f[:unit], f[:info][:key], f[:nk], (f[:d] / TOL_PLANO).round] }.each_value do |grupo|
          uf = UnionFind.new(grupo.size)
          grupo.each_with_index do |a, i|
            (i + 1...grupo.size).each do |j|
              b = grupo[j]
              uf.unir(i, j) if a[:umin] <= b[:umax] + TOL_TOQUE && b[:umin] <= a[:umax] + TOL_TOQUE &&
                               a[:vmin] <= b[:vmax] + TOL_TOQUE && b[:vmin] <= a[:vmax] + TOL_TOQUE
            end
          end
          uf.grupos.each { |idx| pecas << nova_peca(idx.map { |i| grupo[i] }) }
        end
        pecas.reject! { |p| [p[:w], p[:h]].min < st[:min_lado] }   # borda/espessura, não arte
        juntar_frente_verso(pecas)
      end

      def self.nova_peca(fs)
        umin = fs.map { |f| f[:umin] }.min; umax = fs.map { |f| f[:umax] }.max
        vmin = fs.map { |f| f[:vmin] }.min; vmax = fs.map { |f| f[:vmax] }.max
        bb = fs.map { |f| f[:bb] }.transpose
        f0 = fs.first
        nome = fs.map { |f| f[:nome] }.compact.first
        {
          faces: fs, mat_key: f0[:info][:key], material: f0[:info][:nome],
          nome: nome || f0[:info][:nome], unit: f0[:unit], n: f0[:n], d: f0[:d], lado: f0[:lado],
          umin: umin, vmin: vmin, w: umax - umin, h: vmax - vmin,
          area: fs.sum { |f| f[:area] },
          furos: fs.sum { |f| f[:huv].size },
          bb: [bb[0].min, bb[1].min, bb[2].min, bb[3].max, bb[4].max, bb[5].max],
          fv: false
        }
      end

      # Duas faces opostas, mesmo material e mesma medida:
      #   a menos de FV_MIN  -> é a mesma chapa (logo em PVC com espessura): fica uma,
      #                         a que tem a arte do lado da frente da face;
      #   até FV_MAX         -> placa impressa dos dois lados: uma peça FRENTE E VERSO.
      def self.juntar_frente_verso(pecas)
        fora = {}
        # Só compara peças do mesmo material na mesma unidade (estande/objeto).
        pecas.each_with_index.group_by { |p, _| [p[:mat_key], p[:unit]] }.each_value do |grupo|
          grupo.each_with_index do |(a, _), gi|
            next if a[:fv] || fora[a.object_id]
            grupo[(gi + 1)..-1].each do |b, _|
              next if fora[b.object_id] || b[:fv]
              next unless vdot(a[:n], b[:n]) < -0.99
              next unless (a[:w] - b[:w]).abs < 0.4 && (a[:h] - b[:h]).abs < 0.4   # ~1 cm
              next unless bb_perto?(a[:bb], b[:bb], FV_MAX)
              dist = (a[:d] + b[:d]).abs               # normais opostas: soma = distância entre planos
              next if dist > FV_MAX
              if dist < FV_MIN
                fica, sai = (a[:lado] == :back && b[:lado] != :back) ? [b, a] : [a, b]
                fora[sai.object_id] = true
                break if sai.equal?(a)
              else
                a[:fv] = true
                fora[b.object_id] = true
              end
              break
            end
          end
        end
        pecas.reject { |p| fora[p.object_id] }
      end

      def self.bb_perto?(a, b, tol)
        3.times.all? { |k| a[k] <= b[k + 3] + tol && b[k] <= a[k + 3] + tol }
      end

      # Peças iguais (mesmo nome, material e recortes; medida a ±1 cm e área a ±1%)
      # → 1 item com qtd. Comparação com tolerância, não arredondamento: arredondar
      # separa cópias idênticas que caem dos dois lados de uma casa decimal.
      def self.agrupar_iguais(pecas)
        out = []
        pecas.group_by { |p| [p[:nome], p[:mat_key], p[:furos], p[:fv]] }.each_value do |ps|
          grupos = []
          ps.each do |p|
            g = grupos.find do |g0|
              q = g0[:peca]
              (q[:w] - p[:w]).abs < 0.4 && (q[:h] - p[:h]).abs < 0.4 &&
                (q[:area] - p[:area]).abs <= 0.01 * [q[:area], p[:area]].max + 1.0
            end
            g ? g[:qtd] += 1 : grupos << { peca: p, qtd: 1 }
          end
          out.concat(grupos)
        end
        out
      end

      def self.cm(inches)
        (inches * POL_M * 100).round
      end

      # ══════════════════════════════════════════════════════════════════════
      # AMBIENTES (Ruby puro)
      # ══════════════════════════════════════════════════════════════════════

      # Peças a menos de `gap` umas das outras (em planta) = mesmo ambiente.
      # Grade espacial: cada peça só é comparada com as vizinhas.
      def self.separar_ambientes(pecas, gap)
        return [] if pecas.empty?
        half = gap / 2.0
        cel  = [gap, 1.0 * M].max
        grade = Hash.new { |h, k| h[k] = [] }
        uf = UnionFind.new(pecas.size)
        pecas.each_with_index do |p, i|
          x0 = p[:bb][0] - half; y0 = p[:bb][1] - half
          x1 = p[:bb][3] + half; y1 = p[:bb][4] + half
          ((x0 / cel).floor..(x1 / cel).floor).each do |cx|
            ((y0 / cel).floor..(y1 / cel).floor).each do |cy|
              grade[[cx, cy]].each do |j|
                q = pecas[j]
                if x0 <= q[:bb][3] + half && q[:bb][0] - half <= x1 &&
                   y0 <= q[:bb][4] + half && q[:bb][1] - half <= y1
                  uf.unir(i, j)
                end
              end
              grade[[cx, cy]] << i
            end
          end
        end
        uf.grupos.map do |idx|
          ps = idx.map { |i| pecas[i] }
          bb = ps.map { |p| p[:bb] }.transpose
          { pecas: ps, bb: [bb[0].min, bb[1].min, bb[2].min, bb[3].max, bb[4].max, bb[5].max] }
        end
      end

      # Câmeras das cenas: [{ nome, ordem, eye, dir }].
      def self.cameras_das_cenas(model)
        model.pages.to_a.each_with_index.map do |pg, i|
          c = pg.camera
          next nil unless c
          eye = c.eye.to_a
          dir = vnorm(vsub(c.target.to_a, eye))
          next nil if vlen(dir) < 1e-9
          { nome: pg.name.to_s, ordem: i, eye: eye, dir: dir }
        end.compact
      rescue
        []
      end

      # Cada cena aponta para o ambiente que o raio da câmera atravessa primeiro.
      # Nome do ambiente = a cena mais próxima dele (vista aérea geral fica longe
      # e perde para a cena do próprio ambiente). Sem cena: "AMBIENTE N".
      def self.nomear_ambientes(ambs, cams)
        folga = 1.0 * M
        cams.each do |c|
          melhor = nil
          ambs.each do |a|
            t = raio_caixa(c[:eye], c[:dir], a[:bb], folga)
            melhor = [t, a] if t && (melhor.nil? || t < melhor[0])
          end
          next unless melhor
          (melhor[1][:cenas] ||= []) << c.merge(dist: melhor[0])
        end
        ambs.each do |a|
          cs = a[:cenas] || []
          # Cenas próximas do ambiente (descarta vistas gerais lá de longe); entre
          # elas vale a primeira da lista de cenas ("01 CREDENCIAMENTO" e não "... 2").
          dmin  = cs.map { |c| c[:dist] }.min
          perto = dmin && cs.select { |c| c[:dist] <= [2 * dmin, dmin + 10.0 * M].max }.min_by { |c| c[:ordem] }
          a[:nome]  = perto ? perto[:nome] : nil
          a[:ordem] = perto ? perto[:ordem] : nil
          a[:cenas] = cs.sort_by { |c| c[:ordem] }.map { |c| c[:nome] }
        end
        ambs.sort_by! { |a| [a[:ordem] ? 0 : 1, a[:ordem] || 0, a[:bb][0], a[:bb][1]] }
        sem = 0
        ambs.each_with_index do |a, i|
          a[:id] = i
          a[:nome] ||= "AMBIENTE #{sem += 1}"
        end
        ambs
      end

      # Distância ao longo do raio até entrar na caixa (0 se o olho está dentro), ou nil.
      def self.raio_caixa(o, d, bb, folga)
        tmin = 0.0; tmax = Float::INFINITY
        3.times do |k|
          lo = bb[k] - folga; hi = bb[k + 3] + folga
          if d[k].abs < 1e-12
            return nil if o[k] < lo || o[k] > hi
          else
            t1 = (lo - o[k]) / d[k]; t2 = (hi - o[k]) / d[k]
            t1, t2 = t2, t1 if t1 > t2
            tmin = t1 if t1 > tmin
            tmax = t2 if t2 < tmax
            return nil if tmin > tmax
          end
        end
        tmin
      end

      # Lista para a aba.
      def self.resumo(lt)
        mats = Hash.new { |h, k| h[k] = { key: k, nome: '', pecas: 0, m2: 0.0 } }
        lt[:pecas].each do |p|
          m = mats[p[:mat_key]]
          m[:nome] = p[:material]
          m[:pecas] += 1
          m[:m2] += p[:area] * POL_M * POL_M * (p[:fv] ? 2 : 1)
        end
        {
          ambientes: lt[:ambientes].map do |a|
            itens = agrupar_iguais(a[:pecas])
            { id: a[:id], nome: a[:nome], cenas: a[:cenas] || [],
              pecas: a[:pecas].size, desenhos: itens.size,
              m2: (a[:pecas].sum { |p| p[:area] * (p[:fv] ? 2 : 1) } * POL_M * POL_M).round(2) }
          end,
          materiais: mats.values.sort_by { |m| -m[:m2] }.map { |m| m.merge(m2: m[:m2].round(2)) },
          avisos: lt[:avisos] || []
        }
      end

      def self.leitura_valida?(lt)
        lt[:pecas].all? { |p| p[:faces].first[:src].valid? }
      rescue
        false
      end

      # ══════════════════════════════════════════════════════════════════════
      # DIAGRAMAÇÃO (Ruby puro): posição de cada peça no quadro
      # ══════════════════════════════════════════════════════════════════════

      # Texto das etiquetas proporcional ao quadro: ~1% da largura, entre 8 e 22 cm.
      # (Fixo, sumia num backdrop de 12 m e sobrava num balcão de 1 m.)
      LBL_MIN = 0.08 * M
      LBL_MAX = 0.22 * M
      CHAR_W  = 0.62          # largura média de um caractere Arial / altura

      def self.linhas_etiqueta(item)
        p = item[:peca]
        ["#{p[:nome]} – #{format('%02d', item[:qtd])} und.#{p[:fv] ? ' · FRENTE E VERSO' : ''}",
         "#{p[:material]} · #{metros(p[:w])} x #{metros(p[:h])} m"]
      end

      # Distância da base da peça até o topo da etiqueta (abaixo das cotas da base).
      def self.recuo_etiqueta(p, lbl)
        (p[:furos] > 0 ? 0.45 * M : 0.0) + 0.6 * lbl
      end

      # Folgas em volta da peça (polegadas): cotas à esquerda/topo/base e etiqueta.
      def self.folgas(item, labels, lbl)
        p = item[:peca]
        base = labels ? recuo_etiqueta(p, lbl) + 2.4 * lbl + 0.6 * lbl : (p[:furos] > 0 ? 0.45 * M : 0.10 * M)
        texto_w = labels ? linhas_etiqueta(item).map(&:size).max * CHAR_W * lbl : 0.0
        esq = (p[:furos] > 0 ? 0.75 : 0.45) * M
        dir = 0.35 * M
        {
          esq: esq, topo: 0.45 * M, base: base,
          # a etiqueta começa no x da peça: a vaga tem que caber ela também
          dir: [dir, texto_w - p[:w] + 0.3 * M].max
        }
      end

      # Prateleiras: peças mais altas primeiro, linhas até a largura-alvo do quadro.
      # Devolve { itens: [{item, x, z}], w, h, lbl } com (x,z) = canto inferior esquerdo
      # da peça; o quadro cresce para baixo a partir do título.
      def self.diagramar(itens, labels)
        ordem = itens.sort_by { |it| [-it[:peca][:h], -it[:peca][:w]] }
        area0 = ordem.sum { |it| (it[:peca][:w] + 0.8 * M) * (it[:peca][:h] + 0.9 * M) }
        larg0 = ordem.map { |it| it[:peca][:w] + 0.8 * M }.max || 0.0
        lbl   = ([Math.sqrt(area0 * 1.6), larg0].max * 0.01).clamp(LBL_MIN, LBL_MAX)

        slots = ordem.map do |it|
          f = folgas(it, labels, lbl)
          { item: it, f: f, w: it[:peca][:w] + f[:esq] + f[:dir], h: it[:peca][:h] + f[:topo] + f[:base] }
        end
        area   = slots.sum { |sl| sl[:w] * sl[:h] }
        largo  = slots.map { |sl| sl[:w] }.max || 0.0
        alvo   = [Math.sqrt(area * 1.6), largo].max

        linhas = [[]]; x = 0.0
        slots.each do |sl|
          if x > 0 && x + sl[:w] > alvo
            linhas << []
            x = 0.0
          end
          linhas.last << sl.merge(x: x)
          x += sl[:w]
        end

        out = []; topo = 0.0; w = 0.0
        linhas.each do |ln|
          alt = ln.map { |sl| sl[:h] }.max || 0.0
          ln.each do |sl|
            out << { item: sl[:item], x: sl[:x] + sl[:f][:esq], z: topo - sl[:f][:topo] - sl[:item][:peca][:h] }
          end
          w = [w, ln.sum { |sl| sl[:w] }].max
          topo -= alt
        end
        { itens: out, w: w, h: -topo, lbl: lbl }
      end

      # Quadros lado a lado, à esquerda do modelo: [{ quadro, lay, x0 }].
      def self.posicionar_quadros(quadros, labels)
        gap = 3.0 * M
        lays = quadros.map { |q| diagramar(q[:itens], labels) }
        total = lays.sum { |l| l[:w] } + gap * [lays.size - 1, 0].max
        x = -total
        quadros.each_with_index.map do |q, i|
          r = { quadro: q, lay: lays[i], x0: x }
          x += lays[i][:w] + gap
          r
        end
      end

      # ══════════════════════════════════════════════════════════════════════
      # DESENHO NO SKETCHUP (em etapas)
      # ══════════════════════════════════════════════════════════════════════

      TITULO_H = 0.30 * M

      def self.iniciar_desenho(model, quadros, labels, dlg)
        bb   = model_bounds(model)
        pos  = posicionar_quadros(quadros, labels)
        base = bb.empty? ? [0.0, 0.0, 0.0] : [bb.min.x - 3.0 * M, bb.min.y, bb.min.z]

        jobs = [[:limpar]]
        pos.each do |q|
          jobs << [:quadro, q]
          q[:lay][:itens].each { |li| jobs << [:item, q, li] }
        end
        @job = { model: model, dlg: dlg, labels: labels, jobs: jobs, i: 0, base: base,
                 primeiro: true, cancelar: false, grupos: {}, t0: Time.now,
                 total_itens: pos.sum { |q| q[:lay][:itens].size }, feitos: 0,
                 n_quadros: pos.size }
        progresso
        UI.start_timer(0.05, false) { passo }
      end

      def self.passo
        j = @job
        return unless j
        model = j[:model]
        if j[:cancelar]
          @job = nil
          return notify("Cancelado: #{j[:feitos]} peça(s) desenhadas. Ctrl+Z desfaz.", true, j[:dlg])
        end
        # Etapas seguintes entram na mesma operação: um Ctrl+Z desfaz o mapa inteiro.
        model.start_operation('EVA — Mapa de Artes', true, false, !j[:primeiro])
        j[:primeiro] = false
        t = Time.now
        loop do                       # pelo menos uma tarefa por etapa: sempre avança
          executar(j, j[:jobs][j[:i]])
          j[:i] += 1
          break if j[:i] >= j[:jobs].size || (Time.now - t) >= LOTE_SEG
        end
        model.commit_operation

        if j[:i] >= j[:jobs].size
          @job = nil
          seg = (Time.now - j[:t0]).round(1)
          notify("Mapa gerado: #{j[:n_quadros]} quadro(s), #{j[:feitos]} desenho(s) em #{seg} s. " \
                 'Quadros à esquerda do modelo, lidos pela vista Frente. Ctrl+Z desfaz.', true, j[:dlg])
        else
          progresso
          UI.start_timer(0.05, false) { passo }
        end
      rescue => e
        (model.abort_operation rescue nil)
        @job = nil
        notify("Erro ao desenhar: #{e.message}", false, j && j[:dlg])
      end

      def self.progresso
        j = @job
        return unless j
        msg = "Desenhando #{j[:feitos]}/#{j[:total_itens]} peça(s)..."
        if j[:dlg] && j[:dlg].visible?
          j[:dlg].execute_script("window.mapaProgresso(#{j[:feitos]}, #{j[:total_itens]})")
        else
          Sketchup.status_text = "EVA Mapa de Artes: #{msg}"
        end
      rescue
      end

      def self.executar(j, job)
        case job[0]
        when :limpar
          kv = ensure_kv_group(j[:model])
          kv.entities.clear!
          kv.transformation = Geom::Transformation.new
          j[:kv] = kv
        when :quadro
          q  = job[1]
          g  = j[:kv].entities.add_group
          g.name = q[:quadro][:nome]
          b = j[:base]
          g.transformation = Geom::Transformation.translation(Geom::Vector3d.new(b[0] + q[:x0], b[1], b[2] + q[:lay][:h] + 0.0))
          th = [TITULO_H, 2.5 * q[:lay][:lbl]].max
          texto(g.entities, q[:quadro][:nome], 0.0, 0.5 * th, th)
          j[:grupos][q.object_id] = g
        when :item
          g = j[:grupos][job[1].object_id]
          li = job[2]
          (desenhar_item(g.entities, li[:item], li[:x], li[:z], j[:labels], job[1][:lay][:lbl]) rescue nil)
          j[:feitos] += 1
        end
      end

      # Uma peça: cópia das faces (de frente para -Y), recortes, cotas e etiqueta.
      def self.desenhar_item(ents, it, x0, z0, labels, lbl = LBL_MIN)
        p  = it[:peca]
        ig = ents.add_group
        e  = ig.entities
        ponto = ->(u, v) { Geom::Point3d.new(x0 + u - p[:umin], 0.0, z0 + v - p[:vmin]) }

        p[:faces].each do |f|
          pts = f[:ouv].map { |u, v| ponto.call(u, v) }
          nf = (e.add_face(pts) rescue nil)
          next unless nf && nf.valid?
          nf.reverse! if nf.normal.y > 0                       # frente para quem olha da vista Frente
          aplicar_material(nf, f, pts)
          f[:huv].each do |h|
            hf = (e.add_face(h.map { |u, v| ponto.call(u, v) }) rescue nil)
            hf.erase! if hf && hf.valid?
          end
        end

        cotas(e, p, x0, z0)
        etiqueta(e, it, x0, z0, lbl) if labels
        ig.name = p[:nome].to_s
        ig
      end

      # Textura na posição certa: os pontos novos correspondem, na ordem, aos
      # vértices da face original (local), então o UV de cada um vale para o novo.
      def self.aplicar_material(nf, f, pts)
        mat = f[:info][:mat]
        if f[:lado] != :herdado && mat.respond_to?(:texture) && mat.texture
          begin
            tw  = Sketchup.create_texture_writer
            uvh = f[:src].get_UVHelper(true, true, tw)
            mapping = []
            [f[:local].size, 4].min.times do |i|
              q = f[:lado] == :back ? uvh.get_back_UVQ(Geom::Point3d.new(*f[:local][i])) :
                                      uvh.get_front_UVQ(Geom::Point3d.new(*f[:local][i]))
              mapping << pts[i] << Geom::Point3d.new(q.x / q.z, q.y / q.z, 0.0)
            end
            if nf.position_material(mat, mapping, true)
              nf.back_material = mat
              return
            end
          rescue
          end
        end
        nf.material = mat
        nf.back_material = mat
      end

      # Largura no topo; à esquerda a altura (ou a corrente dos recortes); na base
      # a corrente dos recortes na horizontal — como no mapa de referência.
      def self.cotas(e, p, x0, z0)
        w = p[:w]; h = p[:h]
        off = 0.25 * M
        pt = ->(u, v) { Geom::Point3d.new(x0 + u, 0.0, z0 + v) }
        cima  = Geom::Vector3d.new(0, 0, off)
        esq   = Geom::Vector3d.new(-off, 0, 0)
        baixo = Geom::Vector3d.new(0, 0, -off)

        (e.add_dimension_linear(pt.call(0, h), pt.call(w, h), cima) rescue nil)
        us, vs = quebras_dos_furos(p)
        if vs.size > 2
          vs.each_cons(2) { |a, b| (e.add_dimension_linear(pt.call(0, a), pt.call(0, b), esq) rescue nil) }
        else
          (e.add_dimension_linear(pt.call(0, 0), pt.call(0, h), esq) rescue nil)
        end
        if us.size > 2
          us.each_cons(2) { |a, b| (e.add_dimension_linear(pt.call(a, 0), pt.call(b, 0), baixo) rescue nil) }
        end
      end

      # Pontos de quebra (relativos à peça) das bordas dos recortes, em u e em v.
      def self.quebras_dos_furos(p)
        us = [0.0, p[:w]]; vs = [0.0, p[:h]]
        p[:faces].each do |f|
          f[:huv].each do |hl|
            hu = hl.map(&:first); hv = hl.map(&:last)
            us << hu.min - p[:umin] << hu.max - p[:umin]
            vs << hv.min - p[:vmin] << hv.max - p[:vmin]
          end
        end
        [unicos(us), unicos(vs)]
      end

      def self.unicos(vals)
        vals.sort.each_with_object([]) { |v, acc| acc << v if acc.empty? || v - acc.last > TOL_TOQUE }
      end

      # Duas linhas, cada uma um texto (posição exata, sem depender de como o
      # SketchUp empilha texto de várias linhas): NOME – N und. / material · L x A.
      def self.etiqueta(e, it, x0, z0, lbl)
        l1, l2 = linhas_etiqueta(it)
        topo = z0 - recuo_etiqueta(it[:peca], lbl)
        texto(e, l1, x0, topo - lbl, lbl)
        texto(e, l2, x0, topo - 2.3 * lbl, 0.8 * lbl)
      end

      def self.metros(inches)
        format('%.2f', inches * POL_M).tr('.', ',')
      end

      # Texto 3D no plano do quadro, legível pela vista Frente (olhando para +Y).
      def self.texto(e, txt, x, z, altura)
        g = e.add_group
        g.entities.add_3d_text(txt.to_s, TextAlignLeft, 'Arial', false, false, altura, 0.0, 0.0, true, 0.0)
        g.transform!(Geom::Transformation.rotation(ORIGIN, Geom::Vector3d.new(1, 0, 0), 90.degrees))
        g.transform!(Geom::Transformation.translation(Geom::Vector3d.new(x, 0.0, z)))
        g.name = 'texto'
        g
      rescue
        nil
      end

      # ── Grupo KV (isolado, tag própria) ─────────────────────────────────────

      def self.ensure_kv_group(model)
        kv = model.entities.grep(Sketchup::Group).find { |g| g.valid? && kv_group?(g) }
        return kv if kv
        kv = model.entities.add_group
        kv.set_attribute(ATTR_NS, 'kv', '1')
        kv.name  = 'KV - Mapa de Artes'
        kv.layer = (model.layers[KV_TAG] || model.layers.add(KV_TAG))
        kv
      end

      # Caixa do modelo IGNORANDO o próprio quadro KV.
      def self.model_bounds(model)
        bb = Geom::BoundingBox.new
        model.entities.each do |ent|
          next if ent.is_a?(Sketchup::Group) && kv_group?(ent)
          (bb.add(ent.bounds) rescue nil)
        end
        bb
      end

      # Gira 90° (no plano do quadro) os grupos selecionados dentro do KV.
      def self.girar_90(dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        groups = model.selection.grep(Sketchup::Group)
        return notify('Selecione um item do KV (grupo) para girar.', false, dlg) if groups.empty?
        model.start_operation('EVA — girar 90° KV', true)
        begin
          groups.each do |g|
            next unless g.valid?
            g.transform!(Geom::Transformation.rotation(g.bounds.center, Geom::Vector3d.new(0, 1, 0), 90.degrees))
          end
          model.commit_operation
          notify('Item girado 90°.', true, dlg)
        rescue => e
          model.abort_operation
          notify("Erro ao girar: #{e.message}", false, dlg)
        end
      end

      # ── Status → diálogo (ou barra/messagebox se acionado pela toolbar) ─────

      def self.notify(msg, ok, dlg = nil)
        if dlg && dlg.visible?
          dlg.execute_script("window.mapaStatus(#{msg.to_json}, #{(!!ok).to_json})")
        else
          Sketchup.status_text = "EVA Mapa de Artes: #{msg}"
          UI.messagebox("EVA Mapa de Artes: #{msg}") unless ok
        end
        nil
      rescue
        nil
      end

      def self.normalize(s)
        s.to_s.downcase.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').gsub(/\s+/, ' ').strip
      rescue
        s.to_s.downcase.strip
      end

      # ══════════════════════════════════════════════════════════════════════
      # MATEMÁTICA (arrays; matriz 4×4 em coluna, como Transformation#to_a)
      # ══════════════════════════════════════════════════════════════════════

      IDENT = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0].freeze

      def self.mmul(a, b)
        r = Array.new(16, 0.0)
        4.times do |c|
          4.times do |rw|
            s = 0.0
            4.times { |k| s += a[k * 4 + rw] * b[c * 4 + k] }
            r[c * 4 + rw] = s
          end
        end
        r
      end

      def self.mpt(m, p)
        x, y, z = p
        w = m[3] * x + m[7] * y + m[11] * z + m[15]
        w = 1.0 if w.abs < 1e-12
        [(m[0] * x + m[4] * y + m[8] * z + m[12]) / w,
         (m[1] * x + m[5] * y + m[9] * z + m[13]) / w,
         (m[2] * x + m[6] * y + m[10] * z + m[14]) / w]
      end

      def self.mdet3(m)
        m[0] * (m[5] * m[10] - m[9] * m[6]) -
          m[4] * (m[1] * m[10] - m[9] * m[2]) +
          m[8] * (m[1] * m[6] - m[5] * m[2])
      end

      # Normal pelo método de Newell (robusta para polígono côncavo).
      def self.newell(pts)
        nx = ny = nz = 0.0
        pts.each_with_index do |a, i|
          b = pts[(i + 1) % pts.size]
          nx += (a[1] - b[1]) * (a[2] + b[2])
          ny += (a[2] - b[2]) * (a[0] + b[0])
          nz += (a[0] - b[0]) * (a[1] + b[1])
        end
        [nx, ny, nz]
      end

      def self.poly_area(uv)
        s = 0.0
        uv.each_with_index do |a, i|
          b = uv[(i + 1) % uv.size]
          s += a[0] * b[1] - b[0] * a[1]
        end
        (s / 2.0).abs
      end

      def self.vdot(a, b);   a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; end
      def self.vsub(a, b);   [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; end
      def self.vscl(a, s);   [a[0] * s, a[1] * s, a[2] * s]; end
      def self.vlen(a);      Math.sqrt(vdot(a, a)); end
      def self.vcross(a, b)
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
      end
      def self.vnorm(a)
        m = vlen(a)
        m < 1e-12 ? [0.0, 0.0, 0.0] : vscl(a, 1.0 / m)
      end

      # União-busca simples (agrupar faces em peças e peças em ambientes).
      class UnionFind
        def initialize(n); @p = (0...n).to_a; end
        def achar(i)
          i = (@p[i] = @p[@p[i]]) while @p[i] != i
          i
        end
        def unir(a, b)
          ra = achar(a); rb = achar(b)
          @p[ra] = rb if ra != rb
        end
        def grupos
          @p.each_index.group_by { |i| achar(i) }.values
        end
      end

    end
  end
end
