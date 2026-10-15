# encoding: UTF-8
# planta.rb — Planta: projeções acima do corte, grid, elétrica + legenda, tomadas e DXF.
#
# Tudo aqui só roda quando o usuário pede (export ou botões da aba Apresentação):
# nada fica escutando o modelo e nada é lido na abertura do plugin.
#
# A classificação de peças segue a do Memorial: tag própria do componente (ou a do
# grupo pai se "Untagged"), tags auxiliares KV/OCULTAR/OCULTO ignoradas, e a seção
# vem do nome da tag (ESTRUTURAS / ELÉTRICA).
#
# Trabalha sempre em coordenadas (u, v) da câmera da cena: u = direita da tela,
# v = cima da tela. Na planta isso é o plano do piso; nas vistas, o plano da fachada.

module STAND1
  module EVA
    module Planta

      ATTR     = 'STAND1_EVA'
      TAG_NOME = 'EVA - Planta'
      OV_FLAG  = 'eva_planta'

      M  = 1.0 / 0.0254      # 1 m em polegadas (unidade interna do SketchUp)
      MM = M / 1000.0        # 1 mm em polegadas

      MAX_FACES = 6000       # teto de faces lidas por peça (acima disso usa a caixa)

      CFG_PADRAO = {
        'proj' => false, 'grid' => false, 'ele' => false, 'dxf' => false,
        'corProj' => '#d62828', 'corGrid' => '#ffffff', 'corEle' => '#0a5bd6', 'corFita' => '#ffb000',
        'corTexto' => '#ffffff', 'escSimb' => 1.0
      }.freeze

      FITA_AFASTAMENTO = 0.04  # m — a linha da fita sai um pouco para dentro do estande,
                               # para não sumir sob o tracejado da peça onde ela está

      # Larguras das linhas desenhadas (m)
      W_PROJ = 0.005
      W_GRID = 0.003
      W_ELE  = 0.006
      W_FITA = 0.012

      PALAVRAS_FITA = ['fita led', 'fita_led', 'led cob', 'led fita'].freeze
      PALAVRAS_PISO = /piso|tablado|deck|plataforma|palco|carpete|vinilic/i

      # ── Config ────────────────────────────────────────────────────────────────

      def self.normalizar_cfg(cfg)
        h = {}
        (cfg || {}).each { |k, v| h[k.to_s] = v }
        CFG_PADRAO.merge(h) { |_k, padrao, v| v.nil? ? padrao : v }
      end

      def self.cfg_ativa?(cfg)
        !!(cfg['proj'] || cfg['grid'] || cfg['ele'])
      end

      # ── Cena: planta, vista, isométrica ou perspectiva ────────────────────────

      # { tipo: :planta | :planta_torta | :vista | :vista_torta | :iso | :persp, graus: n }
      def self.tipo_camera(cam)
        return { tipo: :persp } if cam.perspective?
        d = cam.direction
        z = [[d.z, 1.0].min, -1.0].max
        graus_baixo = Math.acos(-z) * 180.0 / Math::PI      # 0 = olhando reto p/ baixo
        graus_horiz = Math.asin(z.abs) * 180.0 / Math::PI   # 0 = olhando na horizontal
        if z < 0 && graus_baixo <= 2.0
          { tipo: :planta }
        elsif z < 0 && graus_baixo <= 10.0
          { tipo: :planta_torta, graus: graus_baixo.round(1) }
        elsif graus_horiz <= 2.0
          { tipo: :vista }
        elsif graus_horiz <= 10.0
          { tipo: :vista_torta, graus: graus_horiz.round(1) }
        else
          { tipo: :iso }
        end
      end

      # Base ortonormal da tela: direção do olhar, direita e cima.
      def self.frame(cam)
        d = cam.direction
        r = d.cross(cam.up)
        r.normalize!
        u = r.cross(d)
        u.normalize!
        { dx: d.x, dy: d.y, dz: d.z, rx: r.x, ry: r.y, rz: r.z, ux: u.x, uy: u.y, uz: u.z }
      end

      def self.proj(p, fr)
        [p.x * fr[:rx] + p.y * fr[:ry] + p.z * fr[:rz],
         p.x * fr[:ux] + p.y * fr[:uy] + p.z * fr[:uz]]
      end

      # ── Plano de corte (horizontal) ───────────────────────────────────────────

      # Altura Z do plano de corte ativo, ou nil se não há corte horizontal.
      def self.corte_z(model)
        sp = (model.entities.active_section_plane rescue nil)
        sp ||= model.entities.grep(Sketchup::SectionPlane).find { |s| (s.active? rescue false) }
        return nil unless sp
        a, b, c, d = sp.get_plane
        return nil if c.abs < 0.99
        -d / c
      rescue
        nil
      end

      # ── Coleta de peças (mesma lógica de tags do Memorial) ────────────────────

      def self.norm_tag(nome)
        nome.to_s.upcase.sub(/\A\d+\.\s*/, '').tr('ÉÈÊÁÀÃÂÍÓÔÕÚÇ', 'EEEAAAAIOOOUC').strip
      end

      def self.coletar(entities, tr, tag_herdada, out, raiz = nil)
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          next if e.hidden?
          lay   = e.layer ? e.layer.name : ''
          prop  = (lay == '' || lay == 'Untagged' || lay == 'Layer0') ? nil : lay
          tag   = prop || tag_herdada
          base  = norm_tag(tag)
          next if %w[KV OCULTAR OCULTO].include?(base)
          next if e.layer && !e.layer.visible?
          next if base == norm_tag(TAG_NOME)
          next if ignorada?(e)
          etr = tr * e.transformation
          rz  = raiz || e
          if e.is_a?(Sketchup::ComponentInstance)
            sec = { 'ESTRUTURAS' => :est, 'ELETRICA' => :ele }[base]
            if sec
              out[sec] << leaf(e, etr, tag, rz)
              # Luminária presa dentro de uma peça de estrutura (refletor na testeira):
              # o Memorial para na peça, mas na planta ela precisa aparecer.
              buscar_luz(e.definition.entities, etr, tag, out) if sec == :est
            elsif luz?(e.definition.name)
              out[:ele_extra] << leaf(e, etr, tag, rz)
            else
              coletar(e.definition.entities, etr, tag, out, rz)
            end
          else
            coletar(e.entities, etr, tag, out, rz)
          end
        end
      end

      # Peça marcada pelo botão "Ignorar seleção" (fica de fora da planta e do DXF).
      def self.ignorada?(e)
        !!(e.get_attribute(ATTR, 'ignorar_planta') rescue false)
      end

      # Alterna a marca nas peças selecionadas. Se todas já estão ignoradas, devolve-as.
      def self.alternar_ignorar(model)
        sel = model.selection.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
        return { ok: false, msg: 'Selecione no SketchUp a(s) peça(s) que não devem entrar na planta.' } if sel.empty?
        voltar = sel.all? { |e| ignorada?(e) }
        model.start_operation('EVA ignorar na planta', true)
        sel.each { |e| voltar ? e.delete_attribute(ATTR, 'ignorar_planta') : e.set_attribute(ATTR, 'ignorar_planta', true) }
        model.commit_operation
        nomes = sel.map { |e| e.is_a?(Sketchup::ComponentInstance) ? e.definition.name : (e.name.to_s.empty? ? 'Grupo' : e.name) }.uniq
        { ok: true, msg: (voltar ? 'Voltaram para a planta: ' : 'Ignoradas na planta: ') + nomes.join(', ') }
      end

      # Iluminação reconhecida pelo nome (dicroica, refletor, plafon...).
      def self.luz?(nome)
        [:dicroica, :refletor, :plafon].include?(tipo_ele(nome))
      end

      def self.buscar_luz(entities, tr, tag_pai, out)
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          next unless visivel?(e)
          next if ignorada?(e)
          lay  = e.layer ? e.layer.name : ''
          prop = (lay == '' || lay == 'Untagged' || lay == 'Layer0') ? nil : lay
          etr  = tr * e.transformation
          if e.is_a?(Sketchup::ComponentInstance) && (norm_tag(prop) == 'ELETRICA' || luz?(e.definition.name))
            out[:ele_extra] << leaf(e, etr, prop || tag_pai)
          else
            buscar_luz(e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities, etr, prop || tag_pai, out)
          end
        end
      end

      def self.leaf(inst, tr, tag = nil, raiz = nil)
        db  = inst.definition.bounds
        pts = (0..7).map { |i| db.corner(i).transform(tr) }
        nome = inst.definition.name.to_s.sub(/#\d+\z/, "").strip
        nome = 'Componente sem nome' if nome.empty?
        { inst: inst, tr: tr, nome: nome, pts: pts, tag: tag.to_s, raiz: raiz || inst,
          minz: pts.map(&:z).min, maxz: pts.map(&:z).max }
      end

      def self.coletar_modelo(model)
        out = { est: [], ele: [], ele_extra: [] }
        coletar(model.entities, Geom::Transformation.new, nil, out)
        out
      end

      # ── Geometria 2D das peças ────────────────────────────────────────────────

      def self.shoelace(poly)
        s = 0.0
        n = poly.length
        n.times { |i| a = poly[i]; b = poly[(i + 1) % n]; s += a[0] * b[1] - b[0] * a[1] }
        s / 2.0
      end

      def self.area_loops(loops)
        return 0.0 if loops.empty?
        shoelace(loops[0]).abs - loops[1..-1].to_a.sum { |l| shoelace(l).abs }
      end

      # modo :planta → só faces paralelas à vista (topo/fundo); :vista → faces voltadas p/ câmera.
      def self.varrer(ents, tr, fr, modo, acc, cnt)
        ents.each do |e|
          return if cnt[0] > MAX_FACES
          next unless visivel?(e)
          if e.is_a?(Sketchup::Face)
            n = e.normal.transform(tr)
            next if n.length < 1e-9
            n.normalize!
            dd = n.x * fr[:dx] + n.y * fr[:dy] + n.z * fr[:dz]   # < 0 = voltada p/ a câmera
            ok = modo == :planta ? dd.abs > 0.98 : dd < -0.02
            next unless ok
            cnt[0] += 1
            loops = e.loops.sort_by { |l| l.outer? ? 0 : 1 }
            p3    = loops.map { |l| l.vertices.map { |v| v.position.transform(tr) } }
            polys = p3.map { |l| l.map { |p| proj(p, fr) } }
            p0    = p3[0][0]
            off   = ((n.x * p0.x + n.y * p0.y + n.z * p0.z) / MM).round
            acc << { loops: polys, dd: dd, z: p3[0].map(&:z).max,
                     area: area_loops(polys),
                     plano: [n.x.round(2), n.y.round(2), n.z.round(2), off] }
          elsif e.is_a?(Sketchup::Group)
            varrer(e.entities, tr * e.transformation, fr, modo, acc, cnt)
          elsif e.is_a?(Sketchup::ComponentInstance)
            varrer(e.definition.entities, tr * e.transformation, fr, modo, acc, cnt)
          end
        end
      end

      # Oculta (entidade escondida ou tag desligada, mesmo dentro do componente) não entra.
      def self.visivel?(e)
        return false if e.respond_to?(:hidden?) && e.hidden?
        return false if e.respond_to?(:layer) && e.layer && !e.layer.visible?
        true
      end

      # Arestas "deitadas" em relação à vista (na planta: horizontais), projetadas.
      # Serve a peças sem face de topo: chapa curva, testeira só com faces verticais.
      def self.varrer_arestas(ents, tr, fr, acc, vistos, cnt)
        ents.each do |e|
          return if cnt[0] > MAX_FACES * 3
          next unless visivel?(e)
          if e.is_a?(Sketchup::Edge)
            cnt[0] += 1
            p = e.start.position.transform(tr)
            q = e.end.position.transform(tr)
            dx = q.x - p.x; dy = q.y - p.y; dz = q.z - p.z
            len = Math.sqrt(dx * dx + dy * dy + dz * dz)
            next if len < 1e-6
            next if ((dx * fr[:dx] + dy * fr[:dy] + dz * fr[:dz]) / len).abs > 0.2
            a = proj(p, fr); b = proj(q, fr)
            k = chave_seg(a, b)
            next if k.nil? || vistos[k]
            vistos[k] = true
            acc << [a, b]
          elsif e.is_a?(Sketchup::Group)
            varrer_arestas(e.entities, tr * e.transformation, fr, acc, vistos, cnt)
          elsif e.is_a?(Sketchup::ComponentInstance)
            varrer_arestas(e.definition.entities, tr * e.transformation, fr, acc, vistos, cnt)
          end
        end
      end

      def self.faces_leaf(lf, fr, modo)
        acc = []
        varrer(lf[:inst].definition.entities, lf[:tr], fr, modo, acc, [0])
        acc
      end

      def self.chave_seg(a, b)
        ra = [(a[0] / MM * 10).round, (a[1] / MM * 10).round]
        rb = [(b[0] / MM * 10).round, (b[1] / MM * 10).round]
        return nil if ra == rb
        [ra, rb].sort
      end

      # Contorno de um conjunto de faces: arestas que aparecem uma única vez dentro do
      # próprio plano (some a divisória entre faces coplanares vizinhas).
      def self.contornos(faces, vistos = {})
        out = []
        faces.group_by { |f| f[:plano] }.each_value do |fs|
          cont = Hash.new(0)
          segs = {}
          fs.each do |f|
            f[:loops].each do |lp|
              n = lp.length
              n.times do |i|
                a = lp[i]; b = lp[(i + 1) % n]
                k = chave_seg(a, b)
                next unless k
                cont[k] += 1
                segs[k] = [a, b]
              end
            end
          end
          cont.each do |k, c|
            next if c > 1 || vistos[k]
            vistos[k] = true
            out << segs[k]
          end
        end
        out
      end

      def self.hull(pts)
        pts = pts.uniq.sort
        return pts if pts.length < 3
        cruz = ->(o, a, b) { (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]) }
        low = []
        pts.each { |p| low.pop while low.length >= 2 && cruz.call(low[-2], low[-1], p) <= 0; low << p }
        up = []
        pts.reverse_each { |p| up.pop while up.length >= 2 && cruz.call(up[-2], up[-1], p) <= 0; up << p }
        low[0...-1] + up[0...-1]
      end

      def self.segs_do_poligono(poly)
        n = poly.length
        (0...n).map { |i| [poly[i], poly[(i + 1) % n]] }
      end

      # Contorno 2D da peça: faces de topo → arestas deitadas → caixa (último recurso).
      # `metodo` (opcional) recebe :faces, :arestas ou :caixa.
      #
      # A escolha do método olha só a própria peça; a remoção de linhas repetidas com as
      # peças anteriores vem depois. (Antes, uma peça com o mesmo contorno de outra — faixa
      # vermelha sob a testeira — ficava sem linha nova e caía na caixa: o retângulo fantasma.)
      def self.contorno_leaf(lf, fr, modo, vistos, metodo = nil)
        faces = faces_leaf(lf, fr, modo)
        segs  = faces.empty? ? [] : contornos(faces)
        tipo  = :faces
        if segs.empty?
          tipo = :arestas
          varrer_arestas(lf[:inst].definition.entities, lf[:tr], fr, segs, {}, [0])
        end
        if segs.empty?
          tipo = :caixa
          segs = segs_do_poligono(hull(lf[:pts].map { |p| proj(p, fr) }))
        end
        metodo << tipo if metodo
        segs.select do |a, b|
          k = chave_seg(a, b)
          next false if k.nil? || vistos[k]
          vistos[k] = true
        end
      end

      # Junta segmentos que se tocam em polilinhas, para o tracejado correr contínuo
      # por curvas (arcos de muitos lados pequenos saíam como linha cheia).
      def self.encadear(segs)
        pt   = ->(p) { [(p[0] / MM * 10).round, (p[1] / MM * 10).round] }
        adj  = Hash.new { |h, k| h[k] = [] }
        segs.each_with_index { |(a, b), i| adj[pt.call(a)] << i; adj[pt.call(b)] << i }
        usado = Array.new(segs.length, false)
        polis = []
        andar = lambda do |poli, ponta|
          loop do
            prox = adj[pt.call(ponta)].find { |i| !usado[i] }
            break unless prox
            usado[prox] = true
            a, b = segs[prox]
            ponta = pt.call(a) == pt.call(ponta) ? b : a
            poli << ponta
          end
        end
        segs.each_with_index do |(a, b), i|
          next if usado[i]
          usado[i] = true
          poli = [a, b]
          andar.call(poli, b)
          poli.reverse!
          andar.call(poli, a)
          polis << poli
        end
        polis
      end

      TRACO       = [0.12, 0.06].freeze               # projeção: traço
      TRACO_PONTO = [0.14, 0.05, 0.02, 0.05].freeze   # fita LED: traço e ponto

      # Tracejado ao longo de uma polilinha (o padrão continua de um trecho ao outro).
      # `padrao` em metros: [ligado, desligado, ligado, desligado, ...].
      def self.tracejar_poli(pts, padrao = TRACO)
        pad   = padrao.map { |x| x * M }
        ciclo = pad.sum
        fins  = pad.each_with_index.map { |_, i| pad[0..i].sum }   # fim de cada pedaço no ciclo
        out = []
        s = 0.0
        pts.each_cons(2) do |a, b|
          len = Math.hypot(b[0] - a[0], b[1] - a[1])
          next if len < 1e-6
          ux = (b[0] - a[0]) / len; uy = (b[1] - a[1]) / len
          t = 0.0
          while t < len
            fase = (s + t) % ciclo
            i    = fins.index { |f| fase < f } || 0
            t2   = [t + (fins[i] - fase), len].min
            if i.even? && t2 - t > 0.003 * M
              out << [[a[0] + ux * t, a[1] + uy * t], [a[0] + ux * t2, a[1] + uy * t2]]
            end
            t2 = t + 1e-4 if t2 <= t   # arredondamento de ponto flutuante: nunca parar no lugar
            t = t2
          end
          s += len
        end
        out
      end

      # Desloca uma polilinha `dist_m` para o lado de `centro` (normal média em cada vértice).
      def self.afastar_poli(pts, centro, dist_m)
        return pts unless centro && pts.length >= 2
        d = dist_m * M
        normais = pts.each_cons(2).map do |a, b|
          len = Math.hypot(b[0] - a[0], b[1] - a[1])
          next nil if len < 1e-6
          nx = -(b[1] - a[1]) / len; ny = (b[0] - a[0]) / len
          mx = (a[0] + b[0]) / 2; my = (a[1] + b[1]) / 2
          nx * (centro[0] - mx) + ny * (centro[1] - my) < 0 ? [-nx, -ny] : [nx, ny]
        end
        pts.each_with_index.map do |p, i|
          ns = [normais[i - 1], normais[i]].compact
          ns = [normais[i]].compact if i.zero?
          next p if ns.empty?
          nx = ns.sum { |n| n[0] }; ny = ns.sum { |n| n[1] }
          l = Math.hypot(nx, ny)
          next p if l < 1e-9
          [p[0] + nx / l * d, p[1] + ny / l * d]
        end
      end

      # ── Tracejado ─────────────────────────────────────────────────────────────

      def self.tracejar(seg, dash_m = 0.12, gap_m = 0.06)
        a, b = seg
        dx = b[0] - a[0]; dy = b[1] - a[1]
        len = Math.sqrt(dx * dx + dy * dy)
        return [] if len < 1e-6
        ux = dx / len; uy = dy / len
        dash = dash_m * M; gap = gap_m * M
        out = []
        t = 0.0
        while t < len
          t2 = [t + dash, len].min
          out << [[a[0] + ux * t, a[1] + uy * t], [a[0] + ux * t2, a[1] + uy * t2]] if t2 - t > 0.02 * M
          t += dash + gap
        end
        out
      end

      # ── Piso e grid ───────────────────────────────────────────────────────────

      # Faces de topo do piso: peças com "piso"/"tablado"/... no nome (todas) ou, na falta,
      # a peça de estrutura com a maior face de topo.
      def self.achar_piso(est, fr, cut)
        cand = est.reject { |lf| cut && lf[:minz] >= cut - 0.5 * MM }
        info = cand.map do |lf|
          topo = faces_leaf(lf, fr, :planta).select { |f| f[:dd] < 0 }
          next nil if topo.empty?
          { lf: lf, topo: topo, maior: topo.map { |f| f[:area] }.max }
        end.compact
        return nil if info.empty?
        escolhidos = info.select { |i| i[:lf][:nome] =~ PALAVRAS_PISO }
        escolhidos = [info.max_by { |i| i[:maior] }] if escolhidos.empty?
        faces = []
        escolhidos.each do |i|
          zt = i[:topo].map { |f| f[:z] }.max
          faces.concat(i[:topo].select { |f| (f[:z] - zt).abs < 3 * MM })
        end
        return nil if faces.empty?
        { faces: faces, z: faces.map { |f| f[:z] }.max }
      end

      def self.angulo_dominante(loop2d)
        melhor = 0.0; ang = 0.0
        n = loop2d.length
        n.times do |i|
          a = loop2d[i]; b = loop2d[(i + 1) % n]
          l = Math.hypot(b[0] - a[0], b[1] - a[1])
          if l > melhor
            melhor = l
            ang = Math.atan2(b[1] - a[1], b[0] - a[0])
          end
        end
        ang %= Math::PI / 2
        ang < 0.0087 || ang > Math::PI / 2 - 0.0087 ? 0.0 : ang
      end

      # Linhas de grid de `passo_m` metros, recortadas no perímetro do piso (regra par-ímpar,
      # serve a piso em L ou com recorte) e alinhadas ao canto/orientação do próprio piso.
      def self.grid_segs(faces, passo_m = 1.0, folga_m = W_GRID)
        loops = faces.flat_map { |f| f[:loops] }
        return [] if loops.empty?
        maior = faces.max_by { |f| f[:area] }
        th = angulo_dominante(maior[:loops][0])
        c = Math.cos(th); s = Math.sin(th)
        rot = ->(p) { [p[0] * c + p[1] * s, -p[0] * s + p[1] * c] }
        inv = ->(p) { [p[0] * c - p[1] * s, p[0] * s + p[1] * c] }
        rl  = loops.map { |lp| lp.map(&rot) }
        todos = rl.flatten(1)
        umin, umax = todos.map { |p| p[0] }.minmax
        vmin, vmax = todos.map { |p| p[1] }.minmax
        passo = passo_m * M
        borda = 0.02 * M
        pos = lambda do |lo, hi|
          out = []
          k = 1
          while lo + k * passo < hi - borda
            out << lo + k * passo
            k += 1
          end
          out
        end
        us = pos.call(umin, umax)
        vs = pos.call(vmin, vmax)
        cruzar = lambda do |eixo, cc|
          outro = 1 - eixo
          cs = []
          rl.each do |lp|
            n = lp.length
            n.times do |i|
              a = lp[i]; b = lp[(i + 1) % n]
              da = a[eixo] - cc; db = b[eixo] - cc
              next unless da * db < 0
              cs << a[outro] + (cc - a[eixo]) / (b[eixo] - a[eixo]) * (b[outro] - a[outro])
            end
          end
          cs.sort
        end
        hw = folga_m * M
        segs = []
        # horizontais (v constante) contínuas
        vs.each do |v|
          cs = cruzar.call(1, v + 1e-4)
          cs.each_slice(2) { |a, b| segs << [inv.call([a, v]), inv.call([b, v])] if b }
        end
        # verticais (u constante) interrompidas nos cruzamentos para não sobrepor faixas
        us.each do |u|
          cs = cruzar.call(0, u + 1e-4)
          cs.each_slice(2) do |a, b|
            next unless b
            pedacos = [[a, b]]
            vs.each do |v|
              pedacos = pedacos.flat_map do |lo, hi|
                if v + hw <= lo || v - hw >= hi
                  [[lo, hi]]
                else
                  r = []
                  r << [lo, v - hw] if v - hw > lo
                  r << [v + hw, hi] if v + hw < hi
                  r
                end
              end
            end
            pedacos.each { |lo, hi| segs << [inv.call([u, lo]), inv.call([u, hi])] if hi - lo > 0.005 * M }
          end
        end
        segs
      end

      # ── Elétrica: classificação, símbolos, quantidades ────────────────────────

      def self.fita?(nome)
        n = nome.to_s.downcase
        PALAVRAS_FITA.any? { |k| n.include?(k) }
      end

      def self.tipo_ele(nome)
        n = nome.to_s.downcase
        return :fita    if fita?(n)
        return :quadro  if n =~ /quadro|\bqd\b|qdc/
        return :caixa   if n =~ /caixa de passagem|cx\.? ?de passagem/
        return :rede    if n =~ /\brede\b|telefone|dados|internet|rj ?45|logica|lógica/
        if n.include?('tomada')
          return :tomada_220   if n =~ /220|bivolt|ar cond/
          return :tomada_dupla if n =~ /dupla|2 ?x|duas|2p/
          return :tomada_media if n =~ /m[eé]dia|130/
          return :tomada
        end
        return :refletor if n =~ /refletor|projetor|spot ?light|arandela/
        return :dicroica if n =~ /dicroica|dicr|spot|embutid/
        return :plafon   if n =~ /plafon|plafo|luminaria|luminária|pendente|fluorescente/
        :outro
      end

      ORDEM_ELE = [:fita, :dicroica, :refletor, :plafon, :tomada, :tomada_media, :tomada_dupla,
                   :tomada_220, :rede, :quadro, :caixa, :outro].freeze

      def self.arco(cx, cy, r, a0, a1, n = 12)
        (0..n).map { |i| a = a0 + (a1 - a0) * i / n.to_f; [cx + r * Math.cos(a), cy + r * Math.sin(a)] }
      end

      # Símbolo (simbologia ABNT, NBR 5444) como primitivas em metros, centrado na origem e
      # já girado por `rot`:
      #   [:c, [cx,cy], raio]          círculo (contorno, miolo branco)
      #   [:l, [[x,y],...], fechado]   polilinha (fechada = miolo branco)
      #   [:f, [[x,y],...]]            área cheia na cor da elétrica
      # Pontos de tomada entram por uma "perninha" à esquerda (−x), como na norma.
      def self.simbolo(tipo, rot = 0.0, esc = 1.0)
        tri  = [[-0.03, -0.04], [0.05, 0.0], [-0.03, 0.04]]    # tomada: triângulo ▷
        pern = [:l, [[-0.08, 0], [-0.03, 0]], false]
        prim =
          case tipo
          when :dicroica   # ponto de luz no teto
            [[:c, [0, 0], 0.05]]
          when :refletor   # arandela: perninha + meia-lua (facho para +v)
            [[:l, [[0, -0.08], [0, -0.03]], false],
             [:l, arco(0, -0.03, 0.05, 0, Math::PI), true]]
          when :plafon     # luminária / fluorescente no teto
            [[:l, [[-0.08, -0.04], [0.08, -0.04], [0.08, 0.04], [-0.08, 0.04]], true],
             [:c, [0, 0], 0.025]]
          when :tomada     # tomada baixa
            [pern, [:l, tri, true]]
          when :tomada_media  # tomada média (130 cm): metade cheia
            [pern, [:l, tri, true], [:f, [[-0.03, -0.04], [0.05, 0.0], [-0.03, 0.0]]]]
          when :tomada_220    # tomada de força (220 V / ar-condicionado): cheia
            [pern, [:l, tri, true], [:f, tri]]
          when :tomada_dupla  # dois pontos no mesmo lugar: dois triângulos
            t1 = [[-0.03, 0.0], [0.03, 0.03], [-0.03, 0.06]]
            t2 = [[-0.03, -0.06], [0.03, -0.03], [-0.03, 0.0]]
            [pern, [:l, t1, true], [:l, t2, true]]
          when :rede       # ponto de rede/telefone: barra + triângulo cheio
            [[:l, [[-0.08, 0], [-0.03, 0]], false], [:l, [[-0.03, -0.035], [-0.03, 0.035]], false],
             [:f, [[-0.03, 0.0], [0.05, 0.04], [0.05, -0.04]]]]
          when :quadro     # quadro de distribuição: retângulo com metade cheia na diagonal
            [[:l, [[-0.09, -0.04], [0.09, -0.04], [0.09, 0.04], [-0.09, 0.04]], true],
             [:f, [[-0.09, -0.04], [0.09, -0.04], [0.09, 0.04]]]]
          when :caixa      # caixa de passagem: quadrado com X
            [[:l, [[-0.045, -0.045], [0.045, -0.045], [0.045, 0.045], [-0.045, 0.045]], true],
             [:l, [[-0.045, -0.045], [0.045, 0.045]], false], [:l, [[-0.045, 0.045], [0.045, -0.045]], false]]
          when :fita
            [[:l, [[-0.15, 0], [0.15, 0]], false]]
          else
            [[:c, [0, 0], 0.05], [:l, [[-0.035, -0.035], [0.035, 0.035]], false]]
          end
        return prim if rot.zero? && esc == 1.0
        c = Math.cos(rot) * esc; s = Math.sin(rot) * esc
        g = ->(q) { [q[0] * c - q[1] * s, q[0] * s + q[1] * c] }
        prim.map do |pr|
          case pr[0]
          when :c then [:c, g.call(pr[1]), pr[2] * esc]
          when :f then [:f, pr[1].map(&g)]
          else [:l, pr[1].map(&g), pr[2]]
          end
        end
      end

      # Áreas cheias do símbolo (desenhadas na cor da elétrica).
      def self.cheios(prims)
        prims.select { |pr| pr[0] == :f }.map { |pr| pr[1] }
      end

      # Primitivas → segmentos [[u,v],[u,v]] em metros (círculo vira polígono de 20 lados).
      def self.simbolo_segs(prims, cx, cy)
        segs = []
        prims.each do |pr|
          next if pr[0] == :f
          if pr[0] == :c
            (px, py), r = pr[1], pr[2]
            pts = (0...20).map { |i| a = 2 * Math::PI * i / 20; [cx + px + r * Math.cos(a), cy + py + r * Math.sin(a)] }
            segs.concat(segs_do_poligono(pts))
          else
            pts = pr[1].map { |p| [cx + p[0], cy + p[1]] }
            pts.each_cons(2) { |a, b| segs << [a, b] }
            segs << [pts[-1], pts[0]] if pr[2]
          end
        end
        segs
      end

      # Metros lineares de fita LED, como no Memorial: área do material (uma face por plano) ÷ largura.
      def self.largura_fita
        v = (Sketchup.read_default('STAND1_Memorial', 'largura_fita_led', nil) rescue nil)
        l = v ? v.to_f : 0.02
        l > 0 ? l : 0.02
      end

      def self.area_poligono_3d(pts)
        n = pts.length
        return 0.0 if n < 3
        nx = ny = nz = 0.0
        n.times do |i|
          p = pts[i]; q = pts[(i + 1) % n]
          nx += (p.y - q.y) * (p.z + q.z)
          ny += (p.z - q.z) * (p.x + q.x)
          nz += (p.x - q.x) * (p.y + q.y)
        end
        Math.sqrt(nx * nx + ny * ny + nz * nz) / 2.0
      end

      def self.assinatura_plano(pts)
        a, b, c = pts[0], pts[1], pts[2]
        ux = b.x - a.x; uy = b.y - a.y; uz = b.z - a.z
        vx = c.x - a.x; vy = c.y - a.y; vz = c.z - a.z
        nx = uy * vz - uz * vy; ny = uz * vx - ux * vz; nz = ux * vy - uy * vx
        len = Math.sqrt(nx * nx + ny * ny + nz * nz)
        return [0, 0, 0, 0] if len < 1e-9
        nx /= len; ny /= len; nz /= len
        [nx.round(3), ny.round(3), nz.round(3), (nx * a.x + ny * a.y + nz * a.z).round(2)]
      end

      def self.acumular_area_material(ents, tr, planos, cnt)
        ents.each do |e|
          return if cnt[0] > MAX_FACES
          if e.is_a?(Sketchup::Face)
            next unless e.material || e.back_material
            cnt[0] += 1
            pts = e.outer_loop.vertices.map { |v| v.position.transform(tr) }
            area = area_poligono_3d(pts)
            next if area <= 1e-9
            k = assinatura_plano(pts)
            planos[k] = area if area > (planos[k] || 0.0)
          elsif e.is_a?(Sketchup::Group)
            acumular_area_material(e.entities, tr * e.transformation, planos, cnt)
          elsif e.is_a?(Sketchup::ComponentInstance)
            acumular_area_material(e.definition.entities, tr * e.transformation, planos, cnt)
          end
        end
      end

      def self.metros_fita(lf)
        planos = {}
        acumular_area_material(lf[:inst].definition.entities, lf[:tr], planos, [0])
        (planos.values.sum * 0.0254 * 0.0254 / largura_fita)
      end

      # Faixas da fita: cada face com material vira uma linha ao longo da sua maior extensão
      # (face vertical ou fita fina) ou o seu contorno (face larga).
      def self.fita_segs(lf, fr, vistos = {})
        faces = []
        varrer_material(lf[:inst].definition.entities, lf[:tr], fr, faces, [0])
        fita_faces_segs(faces, vistos)
      end

      def self.fita_faces_segs(faces, vistos)
        out = []
        faces.each do |f|
          lp = f[:loops][0]
          next if lp.length < 2
          pts = lp.length > 16 ? hull(lp) : lp
          melhor = 0.0; par = nil
          pts.combination(2) do |a, b|
            d = Math.hypot(a[0] - b[0], a[1] - b[1])
            (melhor = d; par = [a, b]) if d > melhor
          end
          next unless par && melhor > 0.005 * M
          area = f[:area].abs
          if area / melhor < 0.03 * M
            k = chave_seg(par[0], par[1])
            next if k.nil? || vistos[k]
            vistos[k] = true
            out << par
          else
            contornos([f], vistos).each { |s| out << s }
          end
        end
        out
      end

      # ── Fita LED como MATERIAL (é assim que o Memorial lê) ──────────────────
      # Qualquer face pintada com material cujo nome tem "fita led"/"led cob"/...,
      # em qualquer peça do modelo. Metros = área ÷ largura, com a mesma conta e o
      # mesmo arredondamento do Memorial (área da face, material da face, do verso
      # ou herdado da peça), para os números baterem.
      def self.nome_mat(m)
        m.respond_to?(:display_name) ? m.display_name : m.name
      end

      def self.fitas_material(model, fr)
        areas = Hash.new(0.0)
        faces = []
        model.entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if (e.get_attribute(ATTR, OV_FLAG) rescue false)
          ents = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
          varrer_fita_mat(ents, e.transformation, e.material, fr, faces, areas, visivel?(e) && !ignorada?(e), [0])
        end
        larg = largura_fita
        metros = {}
        areas.each { |n, a| m2 = (a * 0.0254 * 0.0254).round(2); metros[n] = (m2 / larg).round(2) if m2 > 0 }
        { faces: faces, metros: metros }
      end

      def self.varrer_fita_mat(ents, tr, herdado, fr, faces, areas, vis, cnt)
        ents.each do |e|
          if e.is_a?(Sketchup::Face)
            mat = e.material || e.back_material || herdado
            next unless mat.is_a?(Sketchup::Material) && fita?(nome_mat(mat))
            areas[nome_mat(mat)] += e.area
            next unless vis && visivel?(e) && cnt[0] < MAX_FACES
            cnt[0] += 1
            polys = e.loops.sort_by { |l| l.outer? ? 0 : 1 }
                     .map { |l| l.vertices.map { |v| proj(v.position.transform(tr), fr) } }
            faces << { loops: polys, area: area_loops(polys), plano: [0] }
          elsif e.is_a?(Sketchup::Group)
            varrer_fita_mat(e.entities, tr * e.transformation, e.material || herdado, fr, faces, areas,
                            vis && visivel?(e) && !ignorada?(e), cnt)
          elsif e.is_a?(Sketchup::ComponentInstance)
            varrer_fita_mat(e.definition.entities, tr * e.transformation, e.material || herdado, fr, faces, areas,
                            vis && visivel?(e) && !ignorada?(e), cnt)
          end
        end
      end

      def self.varrer_material(ents, tr, fr, acc, cnt)
        ents.each do |e|
          return if cnt[0] > MAX_FACES
          if e.is_a?(Sketchup::Face)
            next unless e.material || e.back_material
            cnt[0] += 1
            polys = e.loops.sort_by { |l| l.outer? ? 0 : 1 }
                     .map { |l| l.vertices.map { |v| proj(v.position.transform(tr), fr) } }
            acc << { loops: polys, area: area_loops(polys), plano: [0] }
          elsif e.is_a?(Sketchup::Group)
            varrer_material(e.entities, tr * e.transformation, fr, acc, cnt)
          elsif e.is_a?(Sketchup::ComponentInstance)
            varrer_material(e.definition.entities, tr * e.transformation, fr, acc, cnt)
          end
        end
      end

      # Posição do símbolo e direção (refletor) de um componente elétrico.
      def self.centro_leaf(lf, fr)
        ps = lf[:pts].map { |p| proj(p, fr) }
        [(ps.map { |p| p[0] }.minmax.sum) / 2.0, (ps.map { |p| p[1] }.minmax.sum) / 2.0]
      end

      # Giro (no plano da vista) e escala do eixo X do componente.
      def self.giro_escala(lf, fr)
        x = Geom::Vector3d.new(1, 0, 0).transform(lf[:tr])
        vu = x.x * fr[:rx] + x.y * fr[:ry] + x.z * fr[:rz]
        vv = x.x * fr[:ux] + x.y * fr[:uy] + x.z * fr[:uz]
        [Math.atan2(vv, vu), [x.length, 0.05].max]
      end

      def self.rotacao_leaf(lf, fr)
        y = lf[:tr].yaxis
        vu = y.x * fr[:rx] + y.y * fr[:ry] + y.z * fr[:rz]
        vv = y.x * fr[:ux] + y.y * fr[:uy] + y.z * fr[:uz]
        Math.atan2(vv, vu) - Math::PI / 2   # símbolo é desenhado com o facho para +v
      end

      # Linhas da legenda: [{tipo:, nome:, qtd:, metros:}] agrupadas pelo nome do componente.
      def self.legenda_linhas(ele, fr)
        g = {}
        ele.each do |lf|
          tipo = tipo_ele(lf[:nome])
          r = (g[lf[:nome]] ||= { tipo: tipo, nome: lf[:nome], qtd: 0, metros: 0.0 })
          r[:qtd] += 1
          r[:metros] += metros_fita(lf) if tipo == :fita
        end
        g.values.sort_by { |r| [ORDEM_ELE.index(r[:tipo]) || 99, r[:nome].downcase] }
      end

      def self.texto_legenda(r)
        if r[:tipo] == :fita
          "#{r[:nome]}  #{format('%.2f', r[:metros]).tr('.', ',')} m"
        else
          "#{r[:nome]}  x #{r[:qtd]}"
        end
      end

      # ── Cálculo comum a overlay e DXF ─────────────────────────────────────────

      # Reúne tudo que a cena de planta precisa, em coordenadas (u, v).
      def self.calcular_planta(model, cam, cfg, avisos, nome)
        fr  = frame(cam)
        col = coletar_modelo(model)
        cut = corte_z(model)
        r   = { fr: fr, cut: cut, est: col[:est], ele: col[:ele],
                vista: [], proj: [], grid: [], piso: nil, simbolos: [], fitas: [], legenda: [] }

        acima, vista = col[:est].partition { |lf| cut && lf[:minz] >= cut - 0.5 * MM }
        vistos = {}
        vista.each { |lf| r[:vista].concat(contorno_leaf(lf, fr, :planta, vistos)) }

        r[:proj_pecas] = Hash.new(0)
        r[:proj_raizes] = []
        if cfg['proj']
          if cut
            vp = {}
            caixa = []
            acima.each do |lf|
              met = []
              r[:proj].concat(contorno_leaf(lf, fr, :planta, vp, met))
              r[:proj_pecas][lf[:nome]] += 1
              r[:proj_raizes] << lf[:raiz]
              caixa << lf[:nome] if met.first == :caixa
            end
            avisos << "#{nome}: nada de estrutura acima do corte." if acima.empty?
            unless caixa.empty?
              avisos << "#{nome}: contorno aproximado pela caixa em #{caixa.uniq.join(', ')} (sem faces/arestas legíveis)."
            end
          else
            avisos << "#{nome}: sem plano de corte horizontal ativo — projeção ignorada."
          end
        end

        if cfg['grid']
          r[:piso] = achar_piso(col[:est], fr, cut)
          if r[:piso]
            r[:grid] = grid_segs(r[:piso][:faces], 1.0)
          else
            avisos << "#{nome}: piso não encontrado na tag ESTRUTURAS — grid ignorado."
          end
        end

        if cfg['ele']
          vf = {}
          esc_padrao = [[cfg['escSimb'].to_f, ESC_MIN].max, ESC_MAX].min
          esc_padrao = 1.0 unless cfg['escSimb'].to_f > 0
          unless col[:ele_extra].empty?
            fora = col[:ele_extra].map { |lf| "#{lf[:nome]} (#{lf[:tag].empty? ? 'sem tag' : lf[:tag]})" }.uniq
            avisos << "#{nome}: iluminação achada pelo nome, fora da leitura do Memorial: #{fora.join(', ')}."
          end
          (col[:ele] + col[:ele_extra]).each do |lf|
            tipo = tipo_ele(lf[:nome])
            if tipo == :fita
              r[:fitas].concat(fita_segs(lf, fr, vf))
            else
              if ponto_tomada?(lf[:inst])
                # ponto do EVA: origem, giro e escala do próprio componente
                cx, cy = proj(lf[:tr].origin, fr)
                rot, esc = giro_escala(lf, fr)
              else
                cx, cy = centro_leaf(lf, fr)
                rot = tipo == :refletor ? rotacao_leaf(lf, fr) : 0.0
                esc = esc_padrao
              end
              r[:simbolos] << { tipo: tipo, u: cx, v: cy, rot: rot, esc: esc }
            end
          end
          r[:legenda] = legenda_linhas(col[:ele] + col[:ele_extra], fr)
          fm = fitas_material(model, fr)
          r[:fitas].concat(fita_faces_segs(fm[:faces], vf))
          fm[:metros].each do |n, m|
            next if r[:legenda].any? { |l| l[:tipo] == :fita && l[:nome] == n }
            r[:legenda] << { tipo: :fita, nome: n, qtd: 1, metros: m }
          end
          r[:legenda].sort_by! { |l| [ORDEM_ELE.index(l[:tipo]) || 99, l[:nome].downcase] }
          avisos << "#{nome}: nenhum item de elétrica (tag ELÉTRICA ou material de fita LED)." if r[:legenda].empty?
        end
        r
      end

      def self.centro_ref(r)
        lim = limites_ref(r)
        lim && [(lim[:umin] + lim[:umax]) / 2.0, (lim[:vmin] + lim[:vmax]) / 2.0]
      end

      # Limites (u,v) da peça de referência: piso se achado, senão todas as estruturas.
      def self.limites_ref(r)
        pts = if r[:piso]
                r[:piso][:faces].flat_map { |f| f[:loops].flatten(1) }
              else
                r[:est].flat_map { |lf| lf[:pts].map { |p| proj(p, r[:fr]) } }
              end
        return nil if pts.empty?
        us = pts.map { |p| p[0] }; vs = pts.map { |p| p[1] }
        { umin: us.min, umax: us.max, vmin: vs.min, vmax: vs.max }
      end

      # Canto superior-esquerdo da legenda (u,v): ao lado do piso, no lado com folga dentro
      # do enquadramento; devolve também se coube.
      def self.posicao_legenda(lim, larg_m, alt_m, visivel)
        w = larg_m * M; h = alt_m * M; gap = 0.4 * M
        return [[0.0, h], false] unless lim
        opcoes = {
          direita:  [lim[:umax] + gap, lim[:vmax]],
          esquerda: [lim[:umin] - gap - w, lim[:vmax]],
          baixo:    [lim[:umin], lim[:vmin] - gap],
          cima:     [lim[:umin], lim[:vmax] + gap + h]
        }
        if visivel
          opcoes.each do |lado, (u, v)|
            ok = u >= visivel[:umin] && u + w <= visivel[:umax] && v <= visivel[:vmax] && v - h >= visivel[:vmin]
            return [[u, v], true] if ok
          end
        end
        [opcoes[:direita], visivel.nil?]
      end

      def self.area_visivel(cam, view)
        return nil if cam.perspective?
        h = cam.height
        asp = view.vpwidth.to_f / view.vpheight
        fr = frame(cam)
        tu, tv = proj(cam.target, fr)
        { umin: tu - h * asp / 2, umax: tu + h * asp / 2, vmin: tv - h / 2, vmax: tv + h / 2 }
      rescue
        nil
      end

      # Medidas da tabela da legenda (m).
      LEG = { linha: 0.26, txt: 0.085, titulo: 0.10, col_simb: 0.40, col_qtd: 0.70,
              char: 0.055, pad: 0.10, simb: 0.17 }.freeze

      def self.qtd_legenda(r)
        r[:tipo] == :fita ? format('%.2f m', r[:metros]).tr('.', ',') : r[:qtd].to_s
      end

      # Tabela da legenda em metros, origem no canto superior esquerdo (y desce negativo).
      # Colunas: símbolo | nome | quantidade. Todo símbolo cabe no mesmo quadrado de
      # LEG[:simb], centrado na célula — mesmo tamanho e mesmo espaçamento em todas as linhas.
      # → { w:, h:, linhas: [[a, b, :borda|:simb|:fita|:proj]], textos: [{s:, x:, cy:, h:, alinha:}] }
      def self.layout_legenda(linhas, usar_proj)
        itens = []
        itens << { tipo: :proj, nome: 'Projeção acima do corte', qtd: '' } if usar_proj
        linhas.each { |l| itens << { tipo: l[:tipo], nome: l[:nome], qtd: qtd_legenda(l) } }
        return nil if itens.empty?

        rh = LEG[:linha]; pad = LEG[:pad]
        nome_w = [itens.map { |i| i[:nome].length }.max * LEG[:char] + 2 * pad, 1.6].max
        x1 = LEG[:col_simb]; x2 = x1 + nome_w; w = x2 + LEG[:col_qtd]
        h = rh * (itens.length + 1)
        segs = []
        borda = ->(a, b) { segs << [a, b, :borda] }
        borda.call([0, 0], [w, 0]); borda.call([w, 0], [w, -h])
        borda.call([w, -h], [0, -h]); borda.call([0, -h], [0, 0])
        borda.call([0, -rh], [w, -rh])
        borda.call([x1, -rh], [x1, -h]); borda.call([x2, -rh], [x2, -h])
        (2..itens.length).each { |k| borda.call([0, -rh * k], [w, -rh * k]) }

        textos = [
          { s: 'LEGENDA', x: pad, cy: -rh / 2, h: LEG[:titulo], alinha: :esq },
          { s: 'QTD', x: w - pad, cy: -rh / 2, h: LEG[:txt], alinha: :dir }
        ]
        cx = x1 / 2.0
        meia = LEG[:simb] / 2.0
        # Uma escala só para todos os símbolos (a do maior), como na planta: nenhum
        # parece maior que o outro.
        maior = itens.reject { |it| [:proj, :fita].include?(it[:tipo]) }.map do |it|
          pts = simbolo_segs(simbolo(it[:tipo]), 0, 0).flatten(1)
          [pts.map { |q| q[0] }.minmax.reduce(:-).abs, pts.map { |q| q[1] }.minmax.reduce(:-).abs].max
        end.max
        esc = maior && maior > 0 ? LEG[:simb] / maior : 1.0
        miolos_leg = []
        cheios_leg = []
        itens.each_with_index do |it, i|
          cy = -rh * (i + 1) - rh / 2
          case it[:tipo]
          when :proj
            t = -meia
            while t < meia
              segs << [[cx + t, cy], [cx + [t + 0.05, meia].min, cy], :proj]
              t += 0.08
            end
          when :fita
            tracejar_poli([[(cx - meia) * M, cy * M], [(cx + meia) * M, cy * M]], TRACO_PONTO.map { |x| x * 0.5 }).each do |a, b|
              segs << [[a[0] / M, a[1] / M], [b[0] / M, b[1] / M], :fita]
            end
          else
            prims = simbolo(it[:tipo])
            ss = simbolo_segs(prims, 0, 0)
            xs = ss.flatten(1).map { |q| q[0] }; ys = ss.flatten(1).map { |q| q[1] }
            mx = (xs.max + xs.min) / 2; my = (ys.max + ys.min) / 2
            tf = ->(q) { [cx + (q[0] - mx) * esc, cy + (q[1] - my) * esc] }
            ss.each { |a, b| segs << [tf.call(a), tf.call(b), :simb] }
            miolos(prims).each { |poly| miolos_leg << poly.map(&tf) }
            cheios(prims).each { |poly| cheios_leg << poly.map(&tf) }
          end
          textos << { s: it[:nome], x: x1 + pad, cy: cy, h: LEG[:txt], alinha: :esq }
          textos << { s: it[:qtd], x: w - pad, cy: cy, h: LEG[:txt], alinha: :dir } unless it[:qtd].empty?
        end
        { w: w, h: h, linhas: segs, textos: textos, miolos: miolos_leg, cheios: cheios_leg }
      end

      # ── Construção no SketchUp ────────────────────────────────────────────────

      def self.cor_hex(hex)
        h = hex.to_s.sub('#', '')
        h = '000000' unless h =~ /\A\h{6}\z/
        Sketchup::Color.new(h[0, 2].hex, h[2, 2].hex, h[4, 2].hex)
      end

      def self.material(model, nome, hex, alpha = 1.0)
        m = model.materials[nome] || model.materials.add(nome)
        m.color = cor_hex(hex)
        m.alpha = alpha
        m
      end

      # Faixa fina (retângulo) entre dois pontos 2D. `mp` converte (u,v,z) → Point3d.
      def self.faixa(ents, a, b, w_m, z, mat, mp)
        dx = b[0] - a[0]; dy = b[1] - a[1]
        len = Math.sqrt(dx * dx + dy * dy)
        return if len < 1e-6
        nx = -dy / len * w_m * M / 2; ny = dx / len * w_m * M / 2
        pts = [mp.call(a[0] + nx, a[1] + ny, z), mp.call(b[0] + nx, b[1] + ny, z),
               mp.call(b[0] - nx, b[1] - ny, z), mp.call(a[0] - nx, a[1] - ny, z)]
        f = ents.add_face(pts)
        return unless f
        f.reverse! if f.normal.z < 0
        f.material = mat
        f.back_material = mat
        f.edges.each { |e| e.hidden = true rescue nil }
      rescue
      end

      def self.get_tag(model)
        model.layers[TAG_NOME] || model.layers.add(TAG_NOME)
      end

      def self.nome_tag_ele(model)
        model.layers.find { |l| norm_tag(l.name) == 'ELETRICA' }
      end

      # Desenha tudo no grupo `ov`. Camadas verticais: grid < projeção < elétrica.
      def self.desenhar(model, ov, r, cfg, cam, avisos, nome)
        fr  = r[:fr]
        ents = ov.entities
        mp = lambda do |u, v, z|
          Geom::Point3d.new(fr[:rx] * u + fr[:ux] * v, fr[:ry] * u + fr[:uy] * v, fr[:rz] * u + fr[:uz] * v + z)
        end
        cut = r[:cut]
        topo = model.bounds.max.z
        # Com o corte isolado num grupo (export), tudo vai ACIMA do corte e fica por cima
        # das paredes cortadas. Sem isso (Aplicar na cena), logo abaixo do corte: por cima
        # de móveis e piso, mas sob o preenchimento das paredes cortadas.
        base = if cut && r[:isolado] then cut + 2 * MM
               elsif cut then cut - 4 * MM
               else topo + 5 * MM
               end
        z_grid = base
        z_proj = base + 1 * MM
        z_fita = base + 2 * MM
        z_fill = base + 2.5 * MM
        z_ele  = base + 3 * MM

        if cfg['grid'] && r[:piso]
          mat = material(model, 'EVA Planta Grid', cfg['corGrid'], 0.7)
          r[:grid].each { |s| faixa(ents, s[0], s[1], W_GRID, z_grid, mat, mp) }
        end

        if cfg['proj'] && !r[:proj].empty?
          mat = material(model, 'EVA Planta Projecao', cfg['corProj'])
          encadear(r[:proj]).each { |pl| tracejar_poli(pl).each { |d| faixa(ents, d[0], d[1], W_PROJ, z_proj, mat, mp) } }
        end

        if cfg['ele']
          mat    = material(model, 'EVA Planta Eletrica', cfg['corEle'])
          matf   = material(model, 'EVA Planta Fita', cfg['corFita'])
          branco = material(model, 'EVA Planta Branco', '#ffffff')
          centro = centro_ref(r)
          encadear(r[:fitas]).each do |pl|
            tracejar_poli(afastar_poli(pl, centro, FITA_AFASTAMENTO), TRACO_PONTO).each do |d|
              faixa(ents, d[0], d[1], W_FITA, z_fita, matf, mp)
            end
          end
          r[:simbolos].each do |s|
            prims = simbolo(s[:tipo], s[:rot], s[:esc] || 1.0)
            # miolo branco: o símbolo cobre o que estiver embaixo (placa da tomada etc.)
            miolos(prims).each do |poly|
              preencher(ents, poly.map { |p| [s[:u] + p[0] * M, s[:v] + p[1] * M] }, z_fill, branco, mp)
            end
            cheios(prims).each do |poly|
              preencher(ents, poly.map { |p| [s[:u] + p[0] * M, s[:v] + p[1] * M] }, z_fill + 0.25 * MM, mat, mp)
            end
            simbolo_segs(prims, 0, 0).each do |a, b|
              faixa(ents, [s[:u] + a[0] * M, s[:v] + a[1] * M], [s[:u] + b[0] * M, s[:v] + b[1] * M], W_ELE, z_ele, mat, mp)
            end
          end
          desenhar_legenda(model, ov, r, cfg, cam, mat, z_ele, avisos, nome)
        end
      end

      # Polígonos fechados do símbolo (o maior de cada círculo/caixa), em metros.
      def self.miolos(prims)
        prims.map do |pr|
          if pr[0] == :f
            nil
          elsif pr[0] == :c
            (px, py), rr = pr[1], pr[2]
            (0...24).map { |i| a = 2 * Math::PI * i / 24; [px + rr * Math.cos(a), py + rr * Math.sin(a)] }
          elsif pr[2]
            pr[1]
          end
        end.compact
      end

      def self.preencher(ents, poly2d, z, mat, mp)
        f = ents.add_face(poly2d.map { |p| mp.call(p[0], p[1], z) })
        return unless f
        f.reverse! if f.normal.z < 0
        f.material = mat
        f.back_material = mat
        f.edges.each { |e| e.hidden = true rescue nil }
      rescue
      end

      # Export: move o modelo para um grupo temporário que leva o corte junto. Assim o
      # corte só recorta o modelo, e a planta (no nível de cima) pode ficar acima dele —
      # por cima das paredes cortadas. Roda dentro da operação que é desfeita no fim.
      def self.isolar_corte(model)
        return false unless model.active_path.nil?
        sp = (model.entities.active_section_plane rescue nil)
        return false unless sp
        plano = sp.get_plane
        itens = model.entities.to_a.reject { |e| e == sp }
        return false if itens.empty?
        g = model.entities.add_group(itens)
        novo = g.entities.add_section_plane(plano)
        g.entities.active_section_plane = novo
        model.entities.active_section_plane = nil
        true
      rescue
        false
      end

      FONTE_LEGENDA = 'Barlow'

      # Texto 3D centrado verticalmente em `cy` (pela altura de referência de "H", então
      # todas as linhas ficam na mesma base) e alinhado à esquerda ou à direita de `x`.
      def self.texto_3d(ents, str, x, cy, h_m, alinha, z, mat, ref_h)
        tg = ents.add_group
        begin
          tg.entities.add_3d_text(str, TextAlignLeft, FONTE_LEGENDA, false, false, h_m * M, 0.0, 0.0, true, 0.0)
        rescue
          tg.entities.add_3d_text(str, TextAlignLeft, 'Arial', false, false, h_m * M, 0.0, 0.0, true, 0.0)
        end
        tg.entities.grep(Sketchup::Face).each { |f| f.material = mat; f.back_material = mat }
        bb = tg.bounds
        x0 = alinha == :dir ? x - bb.max.x : x - bb.min.x
        y0 = cy - ref_h / 2.0
        tg.transformation = Geom::Transformation.translation(Geom::Vector3d.new(x0, y0, z))
      end

      def self.desenhar_legenda(model, ov, r, cfg, cam, mat, z, avisos, nome)
        usar_proj = cfg['proj'] && !r[:proj].empty?
        lay = layout_legenda(r[:legenda], usar_proj)
        return unless lay
        (u0, v0), coube = posicao_legenda(limites_ref(r), lay[:w], lay[:h], area_visivel(cam, model.active_view))
        avisos << "#{nome}: a legenda não cabe no enquadramento — afaste a câmera da cena." unless coube

        g = ov.entities.add_group
        g.name = 'Legenda'
        ents = g.entities
        ident = ->(u, v, zz) { Geom::Point3d.new(u, v, zz) }
        fr = r[:fr]
        mats = {
          borda: material(model, 'EVA Planta Legenda', cfg['corTexto']),
          simb:  mat,
          fita:  material(model, 'EVA Planta Fita', cfg['corFita']),
          proj:  material(model, 'EVA Planta Projecao', cfg['corProj'])
        }
        larg = { borda: 0.004, simb: W_ELE, fita: W_FITA, proj: W_PROJ }
        branco = material(model, 'EVA Planta Branco', '#ffffff')
        lay[:miolos].each { |poly| preencher(ents, poly.map { |q| [q[0] * M, q[1] * M] }, z - 0.5 * MM, branco, ident) }
        lay[:cheios].each { |poly| preencher(ents, poly.map { |q| [q[0] * M, q[1] * M] }, z - 0.25 * MM, mat, ident) }
        lay[:linhas].each do |a, b, k|
          faixa(ents, [a[0] * M, a[1] * M], [b[0] * M, b[1] * M], larg[k], z, mats[k], ident)
        end

        # altura real de uma maiúscula na fonte, para alinhar todas as linhas pela mesma base
        ref = {}
        [LEG[:titulo], LEG[:txt]].uniq.each do |h|
          tmp = ents.add_group
          (tmp.entities.add_3d_text('H', TextAlignLeft, FONTE_LEGENDA, false, false, h * M, 0.0, 0.0, true, 0.0) rescue
            tmp.entities.add_3d_text('H', TextAlignLeft, 'Arial', false, false, h * M, 0.0, 0.0, true, 0.0))
          ref[h] = tmp.bounds.height
          tmp.erase!
        end
        lay[:textos].each do |t|
          texto_3d(ents, t[:s], t[:x] * M, t[:cy] * M, t[:h], t[:alinha], z, mats[:borda], ref[t[:h]] || t[:h] * M)
        end
        o = mp_world(fr, u0, v0)
        rx = Geom::Vector3d.new(fr[:rx], fr[:ry], fr[:rz])
        ux = Geom::Vector3d.new(fr[:ux], fr[:uy], fr[:uz])
        g.transformation = Geom::Transformation.axes(o, rx, ux, rx.cross(ux))
      end

      def self.mp_world(fr, u, v)
        Geom::Point3d.new(fr[:rx] * u + fr[:ux] * v, fr[:ry] * u + fr[:uy] * v, fr[:rz] * u + fr[:uz] * v)
      end

      def self.construir(model, cam, cfg, avisos, nome, isolar = false)
        r  = calcular_planta(model, cam, cfg, avisos, nome)
        # isola depois de ler: a leitura precisa do corte ainda no nível de cima
        r[:isolado] = isolar && r[:cut] ? isolar_corte(model) : false
        ov = model.entities.add_group
        ov.name = 'EVA Planta'
        ov.set_attribute(ATTR, OV_FLAG, '1')
        tag = get_tag(model)
        tag.visible = true
        ov.layer = tag
        desenhar(model, ov, r, cfg, cam, avisos, nome)
        r
      end

      # Gera o overlay, deixa o bloco usar a cena (ex.: gravar o PNG) e desfaz tudo em
      # seguida, sem deixar rastro no modelo nem no histórico de desfazer.
      def self.com_overlay(model, cam, cfg, avisos, nome)
        cfg = normalizar_cfg(cfg)
        model.start_operation('EVA planta', true)
        begin
          begin
            construir(model, cam, cfg, avisos, nome, true)
          rescue => e
            avisos << "#{nome}: falha na planta (#{e.message})."
          end
          yield
        ensure
          model.abort_operation
        end
      end

      def self.limpar(model)
        grupos = model.entities.grep(Sketchup::Group).select { |g| g.valid? && g.get_attribute(ATTR, OV_FLAG) }
        return 0 if grupos.empty?
        model.start_operation('EVA limpar planta', true)
        grupos.each { |g| g.erase! }
        model.commit_operation
        grupos.length
      end

      # Mantém o overlay no modelo (botão "Aplicar na cena atual").
      def self.aplicar_na_cena(cfg)
        model = Sketchup.active_model
        cfg   = normalizar_cfg(cfg)
        cam   = model.active_view.camera
        info  = tipo_camera(cam)
        nome  = (model.pages.selected_page ? model.pages.selected_page.name : 'Cena atual')
        return { ok: false, msg: 'Esta cena não é uma planta de topo paralelo.' } unless info[:tipo] == :planta
        return { ok: false, msg: 'Marque Projeções, Grid ou Elétrica.' } unless cfg_ativa?(cfg)
        avisos = []
        limpar(model)
        model.start_operation('EVA planta', true)
        begin
          r = construir(model, cam, cfg, avisos, nome)
          model.commit_operation
        rescue => e
          model.abort_operation
          return { ok: false, msg: "Falha: #{e.message}" }
        end
        # Deixa selecionadas as peças que geraram projeção: numa vista 3D dá para ver
        # na hora de onde vem cada linha (e usar "Ignorar seleção" se for o caso).
        raizes = r[:proj_raizes].uniq.select { |e| e.valid? }
        unless raizes.empty?
          model.selection.clear
          model.selection.add(raizes)
        end
        # Resumo do que entrou, para achar de onde vem cada linha.
        resumo = []
        resumo << "#{raizes.length} peça(s) que geram projeção ficaram selecionadas" unless raizes.empty?
        unless r[:proj_pecas].empty?
          resumo << 'Projetado: ' + r[:proj_pecas].map { |n, q| q > 1 ? "#{n} ×#{q}" : n }.join(', ')
        end
        unless r[:legenda].empty?
          resumo << 'Elétrica: ' + r[:legenda].map { |l| texto_legenda(l).gsub(/\s+/, ' ') }.join(', ')
        end
        { ok: true, msg: (['Planta aplicada (Limpar remove).'] + resumo + avisos).join(' | ') }
      end

      # ── DXF ───────────────────────────────────────────────────────────────────

      def self.mm(v) ; v / MM ; end

      # entidades: [[:linha, camada, [u,v], [u,v]], [:texto, camada, [u,v], altura_mm, str]]
      DXF_CAMADAS = {
        'ESTRUTURA' => [7, 'CONTINUOUS'], 'PROJECAO' => [1, 'DASHED'], 'GRID' => [8, 'CONTINUOUS'],
        'ELETRICA'  => [5, 'CONTINUOUS'], 'LEGENDA'  => [7, 'CONTINUOUS'], 'FITA_LED' => [2, 'DASHDOT']
      }.freeze

      def self.dxf_texto(entidades)
        usadas = entidades.map { |e| e[1] }.uniq
        f = lambda { |x| format('%.3f', x) }
        l = []
        l.concat(['0', 'SECTION', '2', 'HEADER', '9', '$ACADVER', '1', 'AC1009', '0', 'ENDSEC'])
        l.concat(['0', 'SECTION', '2', 'TABLES', '0', 'TABLE', '2', 'LTYPE', '70', '3'])
        l.concat(['0', 'LTYPE', '2', 'CONTINUOUS', '70', '0', '3', 'Solid line', '72', '65', '73', '0', '40', '0.0'])
        l.concat(['0', 'LTYPE', '2', 'DASHED', '70', '0', '3', 'Dashed', '72', '65', '73', '2', '40', '150.0', '49', '100.0', '49', '-50.0'])
        l.concat(['0', 'LTYPE', '2', 'DASHDOT', '70', '0', '3', 'Dash dot', '72', '65', '73', '4', '40', '260.0', '49', '140.0', '49', '-50.0', '49', '20.0', '49', '-50.0'])
        l.concat(['0', 'ENDTAB', '0', 'TABLE', '2', 'LAYER', '70', usadas.length.to_s])
        usadas.each do |nome|
          cor, lt = DXF_CAMADAS[nome] || [7, 'CONTINUOUS']
          l.concat(['0', 'LAYER', '2', nome, '70', '0', '62', cor.to_s, '6', lt])
        end
        l.concat(['0', 'ENDTAB', '0', 'ENDSEC', '0', 'SECTION', '2', 'ENTITIES'])
        entidades.each do |e|
          if e[0] == :solido
            # SOLID do R12: triângulos em leque; o 4º vértice repete o 3º
            pts = e[2]
            (1...pts.length - 1).each do |k|
              a, b, c = pts[0], pts[k], pts[k + 1]
              l.concat(['0', 'SOLID', '8', e[1], '10', f.call(a[0]), '20', f.call(a[1]), '30', '0.0',
                        '11', f.call(b[0]), '21', f.call(b[1]), '31', '0.0',
                        '12', f.call(c[0]), '22', f.call(c[1]), '32', '0.0',
                        '13', f.call(c[0]), '23', f.call(c[1]), '33', '0.0'])
            end
          elsif e[0] == :linha
            l.concat(['0', 'LINE', '8', e[1], '10', f.call(e[2][0]), '20', f.call(e[2][1]), '30', '0.0',
                      '11', f.call(e[3][0]), '21', f.call(e[3][1]), '31', '0.0'])
          else
            l.concat(['0', 'TEXT', '8', e[1], '10', f.call(e[2][0]), '20', f.call(e[2][1]), '30', '0.0',
                      '40', f.call(e[3]), '1', e[4].to_s])
            # alinhado à direita: o CAD posiciona pelo segundo ponto (11/21)
            l.concat(['72', '2', '11', f.call(e[2][0]), '21', f.call(e[2][1]), '31', '0.0']) if e[5] == :dir
          end
        end
        l.concat(['0', 'ENDSEC', '0', 'EOF'])
        l.join("\r\n") + "\r\n"
      end

      # Monta as entidades do DXF (em mm, origem no canto inferior esquerdo do desenho).
      def self.entidades_dxf(model, cam, cfg, tipo, avisos, nome)
        fr  = frame(cam)
        out = []
        if tipo == :planta
          r = calcular_planta(model, cam, cfg, avisos, nome)
          r[:vista].each { |s| out << [:linha, 'ESTRUTURA', s[0], s[1]] }
          r[:proj].each  { |s| out << [:linha, 'PROJECAO', s[0], s[1]] }
          r[:grid].each  { |s| out << [:linha, 'GRID', s[0], s[1]] }
          r[:fitas].each { |s| out << [:linha, 'FITA_LED', s[0], s[1]] }
          r[:simbolos].each do |s|
            prims = simbolo(s[:tipo], s[:rot], s[:esc] || 1.0)
            simbolo_segs(prims, 0, 0).each do |a, b|
              out << [:linha, 'ELETRICA', [s[:u] + a[0] * M, s[:v] + a[1] * M], [s[:u] + b[0] * M, s[:v] + b[1] * M]]
            end
            cheios(prims).each do |poly|
              out << [:solido, 'ELETRICA', poly.map { |q| [s[:u] + q[0] * M, s[:v] + q[1] * M] }]
            end
          end
          lay = cfg['ele'] ? layout_legenda(r[:legenda], cfg['proj'] && !r[:proj].empty?) : nil
          if lay
            lim = limites_ref(r)
            u0 = lim ? lim[:umax] + 1.0 * M : 0.0
            v0 = lim ? lim[:vmax] : 0.0
            camada = { borda: 'LEGENDA', simb: 'ELETRICA', fita: 'FITA_LED', proj: 'PROJECAO' }
            lay[:linhas].each do |a, b, k|
              out << [:linha, camada[k], [u0 + a[0] * M, v0 + a[1] * M], [u0 + b[0] * M, v0 + b[1] * M]]
            end
            lay[:cheios].each do |poly|
              out << [:solido, 'ELETRICA', poly.map { |q| [u0 + q[0] * M, v0 + q[1] * M] }]
            end
            lay[:textos].each do |t|
              # base da linha de texto = centro da célula − meia altura de maiúscula
              out << [:texto, 'LEGENDA', [u0 + t[:x] * M, v0 + (t[:cy] - t[:h] / 2) * M], t[:h] * 1000.0, t[:s], t[:alinha]]
            end
          end
        else
          col = coletar_modelo(model)
          vistos = {}
          col[:est].each { |lf| contorno_leaf(lf, fr, :vista, vistos).each { |s| out << [:linha, 'ESTRUTURA', s[0], s[1]] } }
          avisos << "#{nome}: sem peças na tag ESTRUTURAS para a vista." if col[:est].empty?
        end
        # origem em 0,0 e unidades em mm
        pts = out.flat_map { |e| e[0] == :linha ? [e[2], e[3]] : (e[0] == :solido ? e[2] : [e[2]]) }
        return [] if pts.empty?
        u0 = pts.map { |p| p[0] }.min; v0 = pts.map { |p| p[1] }.min
        out.map do |e|
          if e[0] == :linha
            [:linha, e[1], [mm(e[2][0] - u0), mm(e[2][1] - v0)], [mm(e[3][0] - u0), mm(e[3][1] - v0)]]
          elsif e[0] == :solido
            [:solido, e[1], e[2].map { |q| [mm(q[0] - u0), mm(q[1] - v0)] }]
          else
            [:texto, e[1], [mm(e[2][0] - u0), mm(e[2][1] - v0)], e[3], e[4], e[5]]
          end
        end
      end

      def self.exportar_dxf(model, cam, cfg, tipo, caminho, avisos, nome)
        cfg  = normalizar_cfg(cfg)
        ents = entidades_dxf(model, cam, cfg, tipo, avisos, nome)
        if ents.empty?
          avisos << "#{nome}: DXF vazio (nada a exportar)."
          return false
        end
        txt = dxf_texto(ents).encode('Windows-1252', undef: :replace, replace: '?')
        File.open(caminho, 'wb') { |f| f.write(txt) }
        true
      end

      # ── Ferramenta de tomadas ─────────────────────────────────────────────────

      # Pontos que a ferramenta coloca (nome do componente → símbolo ABNT). O nome é o que
      # aparece na legenda e no Memorial (tag ELÉTRICA).
      TOMADAS = [
        ['Tomada',             :tomada,       'Tomada baixa (piso / 30 cm)'],
        ['Tomada média',       :tomada_media, 'Tomada média (130 cm, balcão)'],
        ['Tomada dupla',       :tomada_dupla, 'Tomada dupla (2 no mesmo ponto)'],
        ['Tomada 220V',        :tomada_220,   'Tomada de força 220 V'],
        ['Ponto de rede',      :rede,         'Ponto de rede / telefone'],
        ['Quadro elétrico',    :quadro,       'Quadro de distribuição'],
        ['Caixa de passagem',  :caixa,        'Caixa de passagem']
      ].freeze

      VERSAO_TOMADA = 4

      # Placa da tomada com o mesmo contorno do símbolo (disco; caixa na dupla), branca.
      # Definições de versões anteriores (placa quadrada azul) são refeitas no lugar, e
      # todas as tomadas já colocadas se atualizam juntas.
      def self.definicao_tomada(model, idx)
        nome, tipo = TOMADAS[idx]
        d = model.definitions[nome]
        return d if d && d.get_attribute(ATTR, 'versao_tomada').to_i >= VERSAO_TOMADA
        # componente "Tomada" feito pelo usuário (não pelo EVA) não é apagado: o EVA cria o seu ao lado
        d = nil if d && !def_eva?(d)
        d ||= model.definitions.add(nome)
        d.entities.clear!
        # O componente É o símbolo ABNT: miolo branco, cheios e traço na cor da elétrica do
        # projeto (material único: trocar a cor no EVA recolore todas as tomadas). Cada camada
        # num grupo próprio, para as faces não se fundirem.
        prims  = simbolo(tipo)
        ident  = ->(u, v, z) { Geom::Point3d.new(u, v, z) }
        branco = material(model, 'EVA Planta Branco', '#ffffff')
        cor    = material(model, 'EVA Planta Eletrica', cfg_projeto(model)['corEle'])
        camada = lambda do |z|
          g = d.entities.add_group
          g.entities
        end
        e1 = camada.call(0)
        miolos(prims).each { |poly| preencher(e1, poly.map { |q| [q[0] * M, q[1] * M] }, 0.5 * MM, branco, ident) }
        e2 = camada.call(0)
        cheios(prims).each { |poly| preencher(e2, poly.map { |q| [q[0] * M, q[1] * M] }, 0.8 * MM, cor, ident) }
        e3 = camada.call(0)
        simbolo_segs(prims, 0, 0).each { |a, b| faixa(e3, [a[0] * M, a[1] * M], [b[0] * M, b[1] * M], W_ELE, 1.0 * MM, cor, ident) }
        d.set_attribute(ATTR, 'versao_tomada', VERSAO_TOMADA)
        d
      end

      # Config de planta do projeto (cores), lida do mesmo lugar que o painel grava.
      def self.cfg_projeto(model)
        raw = (STAND1::EVA.read_project_text(model, 'planta_cfg') rescue '')
        normalizar_cfg(raw.to_s.empty? ? {} : (JSON.parse(raw) rescue {}))
      end

      ESC_MIN = 0.3
      ESC_MAX = 4.0

      # Tamanho padrão dos símbolos de elétrica do projeto (1,0 = 100%).
      def self.escala_global(model)
        e = cfg_projeto(model)['escSimb'].to_f
        e > 0 ? [[e, ESC_MIN].max, ESC_MAX].min : 1.0
      end

      def self.escala_inst(inst)
        Geom::Vector3d.new(1, 0, 0).transform(inst.transformation).length
      end

      # Grava o tamanho padrão e leva TODAS as tomadas do EVA já inseridas a ele (posição e giro
      # mantidos). Refletores e dicroicas acompanham na planta/DXF pelo mesmo valor.
      def self.definir_escala_global(model, esc)
        esc = [[esc.to_f, ESC_MIN].max, ESC_MAX].min
        cfg = cfg_projeto(model)
        cfg['escSimb'] = esc.round(4)
        STAND1::EVA.write_project_text(model, 'planta_cfg', cfg.to_json)
        insts = TOMADAS.flat_map { |nome, *| (d = model.definitions[nome]) ? d.instances.to_a : [] }
        return esc if insts.empty?
        model.start_operation('EVA tamanho dos símbolos', true)
        insts.each do |inst|
          next unless inst.valid?
          atual = escala_inst(inst)
          next if atual <= 0 || (atual - esc).abs < 1e-4
          k = esc / atual
          inst.transformation = inst.transformation * Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), k, k, 1.0)
        end
        model.commit_operation
        esc
      end

      # Cor da elétrica mudou no painel: recolore os símbolos já colocados.
      def self.atualizar_cor(model, cfg)
        m = model.materials['EVA Planta Eletrica']
        return unless m
        m.color = cor_hex(normalizar_cfg(cfg)['corEle'])
      rescue
      end

      # Definição criada pelo EVA (com marca de versão, ou placa antiga com material "EVA Tomada").
      def self.def_eva?(d)
        return true if d.get_attribute(ATTR, 'versao_tomada')
        d.entities.grep(Sketchup::Face).any? { |f| f.material && f.material.name.to_s.start_with?('EVA ') }
      rescue
        false
      end

      NOMES_TOMADA = TOMADAS.map(&:first).freeze

      # Componente de ponto elétrico (do EVA ou de nome equivalente, ex. "Tomada#2").
      def self.ponto_tomada?(e)
        e.is_a?(Sketchup::ComponentInstance) && NOMES_TOMADA.include?(e.definition.name.to_s.sub(/#\d+\z/, ''))
      end

      # Atualiza as placas antigas já existentes no modelo (chamado ao abrir a ferramenta).
      def self.atualizar_tomadas(model)
        precisa = TOMADAS.each_index.select do |i|
          d = model.definitions[TOMADAS[i][0]]
          d && def_eva?(d) && d.get_attribute(ATTR, 'versao_tomada').to_i < VERSAO_TOMADA
        end
        return if precisa.empty?
        model.start_operation('EVA atualizar tomadas', true)
        precisa.each { |i| definicao_tomada(model, i) }
        model.commit_operation
      rescue
        model.abort_operation rescue nil
      end

      # Ferramenta de clique. ↑/↓ trocam o tipo (o SketchUp segura o Tab), ←/→ giram.
      # Seletor: enquanto a ferramenta está ativa, o canto da tela mostra a lista dos pontos
      # com o símbolo ABNT de cada um, mais "Sair"; dá para clicar direto na linha.
      # Teclado: o foco costuma ficar no painel do EVA (onde está o botão); por isso o painel
      # repassa ↑↓←→ e Esc para a ferramenta (Planta.tecla_tomada). Clique direito = menu.
      # Guias: distância até a tomada mais próxima e o ponto equidistante da sequência
      # (mesmo passo das duas últimas), com imã de 15 cm nesse ponto.
      class TomadaTool
        IMA = 0.15  # m
        MENU_X = 16; MENU_Y = 16; MENU_W = 270; MENU_LH = 30; MENU_TOPO = 26
        ATALHOS = [['↑ ↓', 'trocar o tipo'], ['← →', 'girar 90°'], ['+  −', 'tamanho de todas (PgUp/PgDn)'],
                   ['+  −', 'com marcadas: só elas'],
                   ['F8', 'ortogonal liga/desliga'], ['Clique', 'na tomada = editar'], ['Esc', 'sair']].freeze
        MENU_AT_LH = 15                                  # altura de cada linha de atalho
        TECLA_ORTO = 119                                 # F8, como no AutoCAD

        def initialize(dlg = nil)
          @tipo = 0
          @rot  = 0.0
          @pt   = nil
          @dlg  = dlg
          @colocadas = []
          @marcadas  = []
          @escala    = 1.0
          @orto      = false
        end

        def activate
          model = Sketchup.active_model
          Planta.atualizar_tomadas(model)
          @existentes = Planta.posicoes_tomadas(model)
          @escala = Planta.escala_global(model)
          # tomadas já selecionadas no SketchUp entram marcadas para edição
          @marcadas = model.selection.select { |e| Planta.ponto_tomada?(e) }.map { |e| [e, e.transformation.origin] }
          dica
          mostrar_menu(model.active_view)
        end

        # ── Editar tomadas existentes ──
        # Clique numa tomada = marca/desmarca. Com tomadas marcadas, o tipo escolhido (lista,
        # ↑↓, clique direito) e o giro (←→) valem para elas. Clique no vazio desmarca.
        def tomada_em(x, y, view)
          ph = view.pick_helper
          ph.do_pick(x, y)
          ph.count.times do |i|
            caminho = ph.path_at(i) || []
            tr = Geom::Transformation.new
            caminho.each do |e|
              break unless e.respond_to?(:transformation)
              tr = tr * e.transformation
              return [e, tr.origin] if Planta.ponto_tomada?(e)
            end
          end
          nil
        end

        def aplicar_tipo_marcadas
          return if @marcadas.empty?
          model = Sketchup.active_model
          model.start_operation('EVA trocar tipo de tomada', true)
          d = Planta.definicao_tomada(model, @tipo)
          @marcadas.each { |inst, _| inst.definition = d if inst.valid? }
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("Tomada: #{e.message}")
        end

        # Tamanho: + / − (teclado numérico ou fileira de cima) e Page Up / Page Down, 10% por
        # toque, entre 30% e 400%. Com tomadas marcadas muda elas (e as próximas saem do mesmo
        # tamanho); sem nada marcado, muda o tamanho das próximas. (A rodinha fica só no zoom:
        # o SketchUp não a entrega de forma confiável para a ferramenta.)
        TECLAS_MAIS  = [107, 187, 33].freeze   # + numérico, = / + , Page Up
        TECLAS_MENOS = [109, 189, 34].freeze   # − numérico, − , Page Down

        # Sem nada marcado: muda o tamanho PADRÃO — todas as tomadas já inseridas, as próximas e
        # (na planta) refletores e dicroicas. Com tomadas marcadas: só elas, como exceção.
        def redimensionar(f, view)
          if @marcadas.empty?
            @escala = Planta.definir_escala_global(Sketchup.active_model, @escala * f)
          else
            model = Sketchup.active_model
            model.start_operation('EVA tamanho da tomada', true)
            @marcadas.each do |inst, _|
              next unless inst.valid?
              atual = Geom::Vector3d.new(1, 0, 0).transform(inst.transformation).length
              novo  = [[atual * f, 0.3].max, 4.0].min
              k = novo / atual
              inst.transformation = inst.transformation * Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), k, k, 1.0)
              @escala = novo
            end
            model.commit_operation
          end
          Sketchup.status_text = @marcadas.empty? ? "EVA: todos os símbolos em #{(@escala * 100).round}%  (+/− ou PgUp/PgDn)" : "EVA: tomadas marcadas em #{(@escala * 100).round}%"
          view.invalidate
        end

        def padronizar(view)
          @escala = Planta.definir_escala_global(Sketchup.active_model, Planta.escala_global(Sketchup.active_model))
          Sketchup.status_text = "EVA: todas as tomadas no tamanho padrão (#{(@escala * 100).round}%)"
          view.invalidate
        end

        def girar_marcadas(ang)
          model = Sketchup.active_model
          model.start_operation('EVA girar tomada', true)
          giro = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), ang)
          @marcadas.each { |inst, _| inst.transformation = inst.transformation * giro if inst.valid? }
          model.commit_operation
        end

        # ── Seletor na tela ──
        def mostrar_menu(view)
          view.invalidate
        end

        def menu_visivel?
          true
        end

        # Linhas clicáveis: 0..n-1 = tipos; n = ortogonal; n+1 = "Sair". Abaixo, a tabela de atalhos.
        def linha_menu(x, y)
          return nil unless x >= MENU_X && x <= MENU_X + MENU_W
          i = ((y - MENU_Y - MENU_TOPO) / MENU_LH).floor
          i >= 0 && i <= Planta::TOMADAS.length + 2 ? i : nil
        end

        def altura_menu
          MENU_TOPO + MENU_LH * (Planta::TOMADAS.length + 3) + 10 + MENU_AT_LH * ATALHOS.length + 6
        end

        def dentro_menu?(x, y)
          x >= MENU_X && x <= MENU_X + MENU_W && y >= MENU_Y && y <= MENU_Y + altura_menu
        end

        # ── Ortogonal (F8): prende o cursor na horizontal/vertical a partir da referência ──
        # Referência: última tomada solta nesta sessão; sem ela, a tomada mais próxima.
        def alternar_orto(view)
          @orto = !@orto
          Sketchup.status_text = "EVA Tomada: ortogonal #{@orto ? 'LIGADO' : 'DESLIGADO'} (F8)"
          view.invalidate
        end

        def referencia_orto(p)
          @colocadas[-1] || vizinha(p)
        end

        def ortogonalizar(p)
          @eixo_orto = nil
          return p unless @orto
          ref = referencia_orto(p)
          return p unless ref
          if (p.x - ref.x).abs >= (p.y - ref.y).abs
            @eixo_orto = [:x, ref]
            Geom::Point3d.new(p.x, ref.y, p.z)
          else
            @eixo_orto = [:y, ref]
            Geom::Point3d.new(ref.x, p.y, p.z)
          end
        end

        def sair
          Sketchup.active_model.select_tool(nil)
        end

        # Mesmo efeito das teclas, vindo do painel do EVA (que costuma estar com o foco).
        def tecla(key, view)
          return sair if key == 27
          onKeyDown(key, false, 0, view)
        end

        def getMenu(menu, _flags = nil, _x = nil, _y = nil, _view = nil)
          Planta::TOMADAS.each_with_index do |(_, _, rotulo), i|
            item = menu.add_item(rotulo) { @tipo = i; aplicar_tipo_marcadas; dica; Sketchup.active_model.active_view.invalidate }
            menu.set_validation_proc(item) { i == @tipo ? MF_CHECKED : MF_ENABLED }
          end
          menu.add_separator
          menu.add_item('Girar 90°') { @rot += Math::PI / 2; Sketchup.active_model.active_view.invalidate }
          menu.add_item('Aumentar (+)') { redimensionar(1.1, Sketchup.active_model.active_view) }
          menu.add_item('Diminuir (−)') { redimensionar(1 / 1.1, Sketchup.active_model.active_view) }
          menu.add_item('Padronizar todas no tamanho atual') { padronizar(Sketchup.active_model.active_view) }
          orto = menu.add_item('Ortogonal (F8)') { alternar_orto(Sketchup.active_model.active_view) }
          menu.set_validation_proc(orto) { @orto ? MF_CHECKED : MF_ENABLED }
          menu.add_item('Sair (Esc)') { sair }
          true
        end

        def desenhar_menu(view)
          n   = Planta::TOMADAS.length
          alt = altura_menu
          pt  = ->(x, y) { Geom::Point3d.new(x, y, 0) }
          ret = ->(x0, y0, x1, y1) { [pt.call(x0, y0), pt.call(x1, y0), pt.call(x1, y1), pt.call(x0, y1)] }
          view.line_stipple = ''
          view.drawing_color = Sketchup::Color.new(255, 255, 255)
          view.draw2d(GL_QUADS, ret.call(MENU_X, MENU_Y, MENU_X + MENU_W, MENU_Y + alt))
          view.drawing_color = Sketchup::Color.new(10, 91, 214)
          view.line_width = 1
          view.draw2d(GL_LINE_LOOP, ret.call(MENU_X, MENU_Y, MENU_X + MENU_W, MENU_Y + alt))
          view.draw_text(pt.call(MENU_X + 10, MENU_Y + 6, ), 'Ponto elétrico   ↑↓ ou clique',
                         size: 10, bold: true, color: Sketchup::Color.new(10, 91, 214))
          esc = 26.0 / 0.18   # px por metro: o maior símbolo cabe em 26 px; todos na mesma escala
          Planta::TOMADAS.each_with_index do |(_, tipo, rotulo), i|
            y0 = MENU_Y + MENU_TOPO + i * MENU_LH
            if i == @tipo
              view.drawing_color = Sketchup::Color.new(220, 233, 252)
              view.draw2d(GL_QUADS, ret.call(MENU_X + 1, y0, MENU_X + MENU_W - 1, y0 + MENU_LH))
            end
            cx = MENU_X + 26; cy = y0 + MENU_LH / 2.0
            prims = Planta.simbolo(tipo)
            view.drawing_color = Sketchup::Color.new(10, 91, 214)
            Planta.cheios(prims).each do |poly|
              view.draw2d(GL_POLYGON, poly.map { |q| pt.call(cx + q[0] * esc, cy - q[1] * esc) })
            end
            linhas = Planta.simbolo_segs(prims, 0, 0).flat_map do |a, b|
              [pt.call(cx + a[0] * esc, cy - a[1] * esc), pt.call(cx + b[0] * esc, cy - b[1] * esc)]
            end
            view.line_width = 1.5
            view.draw2d(GL_LINES, linhas)
            view.draw_text(pt.call(MENU_X + 52, y0 + 8), rotulo, size: 10,
                           bold: i == @tipo, color: Sketchup::Color.new(40, 40, 40))
          end
          cinza = Sketchup::Color.new(200, 200, 200)
          # ortogonal (liga/desliga)
          y0 = MENU_Y + MENU_TOPO + n * MENU_LH
          view.drawing_color = cinza
          view.draw2d(GL_LINES, [pt.call(MENU_X + 8, y0), pt.call(MENU_X + MENU_W - 8, y0)])
          if @orto
            view.drawing_color = Sketchup::Color.new(220, 245, 228)
            view.draw2d(GL_QUADS, ret.call(MENU_X + 1, y0 + 1, MENU_X + MENU_W - 1, y0 + MENU_LH))
          end
          cx = MENU_X + 26; cy = y0 + MENU_LH / 2.0
          view.line_width = 2
          view.drawing_color = Sketchup::Color.new(220, 40, 40)
          view.draw2d(GL_LINES, [pt.call(cx - 9, cy + 6), pt.call(cx + 9, cy + 6)])
          view.drawing_color = Sketchup::Color.new(20, 160, 70)
          view.draw2d(GL_LINES, [pt.call(cx - 9, cy + 6), pt.call(cx - 9, cy - 9)])
          view.draw_text(pt.call(MENU_X + 52, y0 + 8), "Ortogonal (F8):  #{@orto ? 'LIGADO' : 'desligado'}",
                         size: 10, bold: !!@orto, color: Sketchup::Color.new(@orto ? 20 : 90, @orto ? 130 : 90, @orto ? 60 : 90))
          # tamanho padrão (clicar = padronizar todas)
          y0 += MENU_LH
          view.drawing_color = cinza
          view.draw2d(GL_LINES, [pt.call(MENU_X + 8, y0), pt.call(MENU_X + MENU_W - 8, y0)])
          view.drawing_color = Sketchup::Color.new(10, 91, 214)
          view.line_width = 1.5
          cx = MENU_X + 26; cy = y0 + MENU_LH / 2.0
          view.draw2d(GL_LINES, [pt.call(cx - 8, cy + 6), pt.call(cx + 8, cy - 6), pt.call(cx + 2, cy - 6), pt.call(cx + 8, cy - 6),
                                 pt.call(cx + 8, cy - 6), pt.call(cx + 8, cy)])
          view.draw_text(pt.call(MENU_X + 52, y0 + 8), "Tamanho #{(@escala * 100).round}%  ·  padronizar todas",
                         size: 10, color: Sketchup::Color.new(40, 40, 40))
          # sair
          y0 += MENU_LH
          view.drawing_color = cinza
          view.draw2d(GL_LINES, [pt.call(MENU_X + 8, y0), pt.call(MENU_X + MENU_W - 8, y0)])
          view.draw_text(pt.call(MENU_X + 52, y0 + 8), '✕  Sair (Esc)', size: 10,
                         color: Sketchup::Color.new(200, 40, 40))
          # tabela de atalhos
          y0 += MENU_LH
          view.drawing_color = cinza
          view.draw2d(GL_LINES, [pt.call(MENU_X + 8, y0), pt.call(MENU_X + MENU_W - 8, y0)])
          view.draw_text(pt.call(MENU_X + 10, y0 + 4), 'ATALHOS', size: 8, bold: true,
                         color: Sketchup::Color.new(10, 91, 214))
          ATALHOS.each_with_index do |(tecla, acao), k|
            yy = y0 + 18 + k * MENU_AT_LH
            view.draw_text(pt.call(MENU_X + 14, yy), tecla, size: 9, bold: true, color: Sketchup::Color.new(40, 40, 40))
            view.draw_text(pt.call(MENU_X + 70, yy), acao, size: 9, color: Sketchup::Color.new(90, 90, 90))
          end
        end

        def deactivate(view)
          view.invalidate
          Sketchup.status_text = ''
          Planta.tomada_ativa = nil
          Planta.avisar_painel(false)
        end

        def dica
          nome = Planta::TOMADAS[@tipo][0]
          if @marcadas && !@marcadas.empty?
            Sketchup.status_text = "EVA Tomada: #{@marcadas.length} marcada(s) — tipo: lista ou ↑↓ | tamanho: + − | ←→ gira | clique no vazio desmarca | Esc sai"
          else
            Sketchup.status_text = "EVA Tomada: #{nome} — clique no piso | clique numa tomada para editar | ↑↓ tipo | + − tamanho | ←→ gira | Esc sai"
          end
        end

        def onMouseMove(_flags, x, y, view)
          @hover_menu = menu_visivel? && dentro_menu?(x, y)
          @pt = ajustar(view.inputpoint(x, y).position) unless @hover_menu
          view.invalidate
        end

        def onKeyDown(key, _repeat, _flags, view)
          case key
          when 9, 40 then @tipo = (@tipo + 1) % Planta::TOMADAS.length; aplicar_tipo_marcadas  # Tab / ↓
          when 38    then @tipo = (@tipo - 1) % Planta::TOMADAS.length; aplicar_tipo_marcadas  # ↑
          when 39, 37
            ang = key == 39 ? Math::PI / 2 : -Math::PI / 2                                    # → / ←
            @marcadas.empty? ? (@rot += ang) : girar_marcadas(ang)
          when TECLA_ORTO    then alternar_orto(view); return true
          when *TECLAS_MAIS  then redimensionar(1.1, view); return true
          when *TECLAS_MENOS then redimensionar(1 / 1.1, view); return true
          else return false
          end
          dica
          view.invalidate
          true
        end

        def onLButtonDown(_flags, x, y, view)
          if menu_visivel? && dentro_menu?(x, y)
            i = linha_menu(x, y)
            return sair if i == Planta::TOMADAS.length + 2
            return padronizar(view) if i == Planta::TOMADAS.length + 1
            return alternar_orto(view) if i == Planta::TOMADAS.length
            if i && i < Planta::TOMADAS.length
              @tipo = i
              aplicar_tipo_marcadas
            end
            dica
            view.invalidate
            return
          end
          alvo = tomada_em(x, y, view)
          if alvo
            ja = @marcadas.index { |inst, _| inst == alvo[0] }
            ja ? @marcadas.delete_at(ja) : @marcadas << alvo
            dica
            view.invalidate
            return
          end
          unless @marcadas.empty?
            @marcadas = []
            dica
            view.invalidate
            return
          end
          pt = ajustar(view.inputpoint(x, y).position)
          colocar(pt)
          @colocadas << pt
          @existentes << pt
          view.invalidate
        end

        # Ponto sugerido: última + passo (passo das duas últimas colocadas, ou da última
        # até a tomada vizinha mais próxima).
        def sugestao
          ult = @colocadas[-1]
          return nil unless ult
          ant = @colocadas[-2] || vizinha(ult, [ult])
          return nil unless ant
          Geom::Point3d.new(2 * ult.x - ant.x, 2 * ult.y - ant.y, ult.z)
        end

        def vizinha(p, ignorar = [])
          (@existentes || []).reject { |q| ignorar.any? { |i| d2(i, q) < 1e-6 } }.min_by { |q| d2(p, q) }
        end

        def d2(a, b)
          (a.x - b.x)**2 + (a.y - b.y)**2
        end

        def ajustar(p)
          p = ortogonalizar(p)
          s = sugestao
          @imantado = s && Math.sqrt(d2(p, s)) < IMA * Planta::M
          @imantado ? Geom::Point3d.new(s.x, s.y, p.z) : p
        end

        def fmt_m(polegadas)
          format('%.2f m', polegadas * 0.0254).tr('.', ',')
        end

        def getExtents
          bb = Geom::BoundingBox.new
          bb.add(Sketchup.active_model.bounds)
          @marcadas.each { |_, o| bb.add(o) }
          bb.add(@pt) if @pt
          s = sugestao
          bb.add(s) if s
          bb
        end

        def onCancel(_reason, _view)
          Sketchup.active_model.select_tool(nil)
        end

        def colocar(pt)
          model = Sketchup.active_model
          model.start_operation('EVA tomada', true)
          d  = Planta.definicao_tomada(model, @tipo)
          tr = Geom::Transformation.translation(Geom::Vector3d.new(pt.x, pt.y, pt.z + 1 * Planta::MM)) *
               Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), @rot) *
               Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), @escala, @escala, 1.0)
          inst = model.active_entities.add_instance(d, tr)
          tag = Planta.nome_tag_ele(model) || model.layers.add('ELÉTRICA')
          inst.layer = tag
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("Tomada: #{e.message}")
        end

        def draw(view)
          desenhar_menu(view) if menu_visivel?
          # tomadas marcadas para edição: anel verde
          unless @marcadas.empty?
            view.drawing_color = Sketchup::Color.new(20, 160, 70)
            view.line_width = 3
            view.line_stipple = ''
            r = 0.11 * Planta::M
            @marcadas.each do |_, o|
              anel = (0..28).map { |i| a = 2 * Math::PI * i / 28; Geom::Point3d.new(o.x + r * Math.cos(a), o.y + r * Math.sin(a), o.z + 2 * Planta::MM) }
              view.draw(GL_LINE_STRIP, anel)
            end
          end
          return unless @pt
          prims = Planta.simbolo(Planta::TOMADAS[@tipo][1], @rot, @escala)
          segs  = Planta.simbolo_segs(prims, 0, 0)
          pts = []
          segs.each do |a, b|
            pts << Geom::Point3d.new(@pt.x + a[0] * Planta::M, @pt.y + a[1] * Planta::M, @pt.z)
            pts << Geom::Point3d.new(@pt.x + b[0] * Planta::M, @pt.y + b[1] * Planta::M, @pt.z)
          end
          azul  = Sketchup::Color.new(10, 91, 214)
          verde = Sketchup::Color.new(20, 160, 70)
          view.drawing_color = @imantado ? verde : azul
          view.line_width = 2
          view.line_stipple = ''
          view.draw(GL_LINES, pts)
          Planta.cheios(prims).each do |poly|
            view.draw(GL_POLYGON, poly.map { |q| Geom::Point3d.new(@pt.x + q[0] * Planta::M, @pt.y + q[1] * Planta::M, @pt.z) })
          end

          if @orto && @eixo_orto
            eixo, ref = @eixo_orto
            view.drawing_color = eixo == :x ? Sketchup::Color.new(220, 40, 40) : Sketchup::Color.new(20, 160, 70)
            view.line_width = 2
            view.line_stipple = ''
            view.draw(GL_LINES, [ref, @pt])
          end

          # Distância até a tomada mais próxima
          viz = vizinha(@pt)
          if viz
            view.drawing_color = azul
            view.line_width = 1
            view.line_stipple = '-'
            view.draw(GL_LINES, [@pt, viz])
            meio = Geom::Point3d.new((@pt.x + viz.x) / 2, (@pt.y + viz.y) / 2, @pt.z)
            view.draw_text(view.screen_coords(meio), fmt_m(Math.sqrt(d2(@pt, viz))), color: azul, size: 12)
          end

          # Ponto equidistante da sequência
          s = sugestao
          if s
            ult = @colocadas[-1]
            view.drawing_color = verde
            view.line_stipple = '.'
            view.line_width = 1
            view.draw(GL_LINES, [ult, s])
            r = 0.06 * Planta::M
            circ = (0..24).map { |i| a = 2 * Math::PI * i / 24; Geom::Point3d.new(s.x + r * Math.cos(a), s.y + r * Math.sin(a), s.z) }
            view.line_stipple = ''
            view.draw(GL_LINE_STRIP, circ)
            view.draw_text(view.screen_coords(s), "  = #{fmt_m(Math.sqrt(d2(ult, s)))}", color: verde, size: 12)
          end
          view.line_stipple = ''
        end
      end

      # Posições (mundo) das tomadas já existentes no modelo.
      def self.posicoes_tomadas(model)
        TOMADAS.flat_map do |nome, *|
          d = model.definitions[nome]
          d ? d.instances.map { |i| i.transformation.origin } : []
        end
      rescue
        []
      end

      class << self
        attr_accessor :tomada_ativa
      end

      def self.ativar_tomada(dlg = nil)
        if tomada_ativa
          Sketchup.active_model.select_tool(nil)   # o botão funciona como liga/desliga
          return
        end
        t = TomadaTool.new(dlg)
        Sketchup.active_model.select_tool(t)
        self.tomada_ativa = t
        avisar_painel(true)
      end

      # O botão do painel do EVA acompanha o estado (também quando ligado pela toolbar).
      def self.avisar_painel(on)
        d = STAND1::EVA.dialog_aberto
        d.execute_script("window.plantaTomadaAtiva(#{on ? 'true' : 'false'})") if d
      rescue
      end

      # Tecla vinda do painel do EVA (37–40 setas, 27 Esc).
      def self.tecla_tomada(key)
        t = tomada_ativa
        return unless t
        t.tecla(key.to_i, Sketchup.active_model.active_view)
      end

    end
  end
end
