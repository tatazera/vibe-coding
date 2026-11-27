# encoding: UTF-8
# =============================================================================
# EVA Stand1 — mapa_artes.rb
# Aba "Mapa de Artes": monta o mapa de artes (peças de comunicação visual de
# frente, cotadas, com nome e quantidade) — uma prancha 16:9 por ambiente.
#
# IDEIA CENTRAL: a marcação é manual e a peça fica LIGADA ao modelo.
#   • Você seleciona no SketchUp (face, grupo ou componente) e adiciona a peça a um
#     ambiente. Nome, quantidade e "frente e verso" são digitados — nada é contado
#     ou deduzido pelo plugin.
#   • A peça guarda a REFERÊNCIA às faces de origem (não uma cópia da medida). A cada
#     atualização a medida é relida do modelo: o projeto muda, a peça acompanha.
#   • O que mudou desde a última REVISÃO emitida (R00, R01...) é detectado e vira
#     uma lista de alterações pronta para mandar à produção.
#   • Origem substituída? "Trocar pela seleção" mantém nome, quantidade e ambiente.
#     Face apagada numa edição? O plugin tenta reencontrar a arte pelo objeto que a
#     continha.
#
# Tudo é gravado no próprio .skp (e num arquivo ao lado, por projeto). O modelo real
# nunca é alterado: as pranchas ficam no grupo "KV - Mapa de Artes" (tag KV), à
# esquerda do modelo, e a cena 16:9 de cada ambiente é criada/atualizada no lugar.
# O desenho é feito em etapas (o SketchUp continua respondendo) e vale 1 Ctrl+Z.
# =============================================================================

require 'json'

module STAND1
  module EVA
    module MapaArtes

      ATTR_NS = 'EVA'
      KV_TAG  = 'KV'
      POL_M   = 0.0254        # polegada -> metro
      M       = 1.0 / POL_M   # polegadas por metro

      # ── Limites (o SketchUp não pode travar) ────────────────────────────────
      LER_MAX_NOS   = 80_000
      LER_MAX_SEG   = 15.0
      LER_MAX_FACES = 25_000
      SEL_MAX_NOS   = 4_000   # pré-visualização ao vivo da seleção
      SEL_MAX_SEG   = 1.5
      CLUSTER_MAX   = 800     # faces coplanares comparadas duas a duas
      LOTE_SEG      = 0.15    # tempo de desenho por etapa; depois devolve o controle
      SEL_MAX_PECAS = 40      # seleção com mais peças que isso: sem prévia

      MIN_LADO_CM = 3.0       # face mais estreita que isso = espessura (borda de PVC/ACM)
      TOL_PLANO   = 0.04      # ~1 mm entre planos
      TOL_TOQUE   = 0.08      # ~2 mm para faces vizinhas
      TOL_MEDIDA  = 0.4       # ~1 cm: medidas "iguais" / medida que mudou
      FV_MAX      = 0.30 * M  # faces opostas até 30 cm = a mesma chapa

      BOARD_ASPECT = 16.0 / 9.0
      SEM_MATERIAL = { key: '', nome: 'Sem material', name: '', mat: nil, tex: false }.freeze

      # ══════════════════════════════════════════════════════════════════════
      # ESTADO (persistido por projeto: .skp + arquivo ao lado)
      # ══════════════════════════════════════════════════════════════════════
      #
      # { ambientes: [{id,nome}], ativo, n_p,
      #   pecas: [{ id, amb, nome, qtd, fv, obs, fontes, ger, st, aviso }],
      #   rev_n (nil = nenhuma emitida), base { id => valores na última revisão }, hist [] }
      #
      #   fontes = referências às faces de origem: { ip: [ids das instâncias do caminho],
      #            pid: id da face, cont: id do objeto selecionado, cip: caminho dele }
      #   ger    = última geometria lida (medidas, contorno, recortes, textura)

      def self.estado_vazio
        { 'v' => 1, 'ambientes' => [{ 'id' => 'a1', 'nome' => 'AMBIENTE 1' }], 'ativo' => 'a1',
          'pecas' => [], 'n_p' => 0, 'rev_n' => nil, 'base' => {}, 'hist' => [] }
      end

      def self.carregar(model)
        return @estado if @estado && @estado_model.equal?(model)
        raw = begin
          if STAND1::EVA.respond_to?(:read_project_text)
            STAND1::EVA.read_project_text(model, 'mapa_artes')
          else
            model.get_attribute(ATTR_NS, 'mapa_artes', '').to_s
          end
        rescue
          ''
        end
        h = raw.to_s.empty? ? nil : (JSON.parse(raw) rescue nil)
        h = estado_vazio unless h.is_a?(Hash) && h['ambientes'].is_a?(Array) && !h['ambientes'].empty?
        h['pecas'] = [] unless h['pecas'].is_a?(Array)
        h['base']  = {} unless h['base'].is_a?(Hash)
        h['hist']  = [] unless h['hist'].is_a?(Array)
        h['n_p']   = h['pecas'].map { |p| p['id'].to_s[/\d+/].to_i }.push(h['n_p'].to_i).max
        h['ativo'] = h['ambientes'][0]['id'] unless h['ambientes'].any? { |a| a['id'] == h['ativo'] }
        @estado = h
        @estado_model = model
        h
      end

      def self.persistir(model)
        @ignorar_ate = Time.now + 1.5          # gravar atributo não é "alteração do projeto"
        json = @estado.to_json
        if STAND1::EVA.respond_to?(:write_project_text)
          STAND1::EVA.write_project_text(model, 'mapa_artes', json)
        else
          model.set_attribute(ATTR_NS, 'mapa_artes', json)
        end
      rescue
      end

      def self.parse_cfg(msg)
        c = msg.is_a?(Hash) ? msg : (JSON.parse(msg.to_s) rescue {})
        c.is_a?(Hash) ? c : {}
      end

      # ══════════════════════════════════════════════════════════════════════
      # LEITURA
      # ══════════════════════════════════════════════════════════════════════

      def self.novo_st(selecao = false)
        @mat_cache = {}
        { t0: Time.now, nos: 0, faces: 0, unit_seq: 0, estourou: nil,
          max_nos: selecao ? SEL_MAX_NOS : LER_MAX_NOS,
          max_seg: selecao ? SEL_MAX_SEG : LER_MAX_SEG,
          min_lado: MIN_LADO_CM / 100.0 * M }
      end

      def self.estourou?(st)
        return true if st[:estourou]
        st[:nos] += 1
        if st[:nos] > st[:max_nos]
          st[:estourou] = "passou de #{st[:max_nos]} grupos/componentes"
        elsif st[:faces] > LER_MAX_FACES
          st[:estourou] = "passou de #{LER_MAX_FACES} faces"
        elsif st[:nos] % 100 == 0 && Time.now - st[:t0] > st[:max_seg]
          st[:estourou] = "passou de #{st[:max_seg].round(1)} s"
        end
        !st[:estourou].nil?
      end

      # Resolve ids persistentes em entidades. Tenta o caminho rápido da API; o que
      # não achar procura numa varredura única (com limite) do modelo.
      class Resolvedor
        def initialize(model); @model = model; @mapa = nil; end

        def [](pid)
          return nil if pid.nil?
          e = (@model.find_entity_by_persistent_id(pid) rescue nil)
          e = e.first if e.is_a?(Array)
          return e if e && (e.respond_to?(:valid?) ? e.valid? : true)
          mapa[pid]
        end

        def mapa
          return @mapa if @mapa
          @mapa = {}
          t0 = Time.now; n = 0; vistos = {}
          pilha = [@model.entities]
          until pilha.empty?
            ents = pilha.pop
            ents.each do |e|
              n += 1
              return @mapa if n > 200_000 || (n % 500 == 0 && Time.now - t0 > 10.0)
              if e.is_a?(Sketchup::Face)
                @mapa[(e.persistent_id rescue nil)] = e
              elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
                @mapa[(e.persistent_id rescue nil)] = e
                d = e.definition
                next if vistos[d]
                vistos[d] = true
                pilha << d.entities
              end
            end
          end
          @mapa
        end
      end

      def self.mat_info(m)
        return nil unless m
        @mat_cache ||= {}
        @mat_cache[m] ||= begin
          nome = (m.display_name.to_s rescue m.name.to_s).strip
          { key: normalize(m.name.to_s), nome: nome.empty? ? m.name.to_s : nome, name: m.name.to_s,
            mat: m, tex: !!(m.respond_to?(:texture) && m.texture) }
        end
      end

      # Material do grupo/componente vale para as faces sem material dentro dele.
      def self.herdar(e, herdado)
        mat_info(e.material) || herdado
      rescue
        herdado
      end

      def self.nome_de(e)
        n = e.name.to_s.strip
        n = e.definition.name.to_s.sub(/#\d+\z/, '').strip if n.empty? && e.is_a?(Sketchup::ComponentInstance)
        (n.empty? || n =~ /\A\s*(grupo|group|componente|component|ret[aâ]ngulo|rectangle|face|sem nome|untitled|copy|c[oó]pia)?\s*(#\s*\d+)?\s*\z/i) ? nil : n
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

      def self.normalize(s)
        s.to_s.downcase.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').gsub(/\s+/, ' ').strip
      rescue
        s.to_s.downcase.strip
      end

      # Lado com a arte: frente com material; senão verso; senão o material herdado
      # do grupo; senão a face sem material (o usuário escolheu, então vale).
      def self.face_local(f, herdado, _st)
        fm = mat_info(f.material)
        bm = mat_info(f.back_material)
        info, lado =
          if fm then [fm, :front]
          elsif bm then [bm, :back]
          elsif herdado then [herdado, :herdado]
          else [SEM_MATERIAL, :none]
          end
        outer = f.outer_loop.vertices.map { |v| v.position.to_a }
        holes = f.loops.reject(&:outer?).map { |l| l.vertices.map { |v| v.position.to_a } }
        { face: f, info: info, lado: lado, outer: outer, holes: holes }
      rescue
        nil
      end

      def self.fonte_de(ip, pid, cont, cip)
        { 'ip' => ip, 'pid' => pid, 'cont' => cont, 'cip' => cip }
      end

      # Face -> mundo. A normal é a do lado COM a arte (quem olha a arte está nela),
      # sem espelhar: nem a cópia espelhada de um componente, nem a arte no verso.
      def self.emitir(fi, m, unit, nome, out, st, fonte)
        st[:faces] += 1
        ow = fi[:outer].map { |p| mpt(m, p) }
        n  = vnorm(newell(ow))
        return if vlen(n) < 1e-9
        ref = mdir(m, fi[:face].normal.to_a)
        n = vscl(n, -1.0) if vdot(n, ref) < 0
        n = vscl(n, -1.0) if fi[:lado] == :back
        hw = fi[:holes].map { |h| h.map { |p| mpt(m, p) } }
        xs = ow.map { |p| p[0] }; ys = ow.map { |p| p[1] }; zs = ow.map { |p| p[2] }
        out << {
          face: fi[:face], info: fi[:info], lado: fi[:lado], fonte: fonte, nome: nome, unit: unit,
          ow: ow, hw: hw, n: n, d: vdot(ow[0], n),
          area: [vlen(newell(ow)) / 2.0 - hw.sum { |h| vlen(newell(h)) / 2.0 }, 0.0].max,
          bb: [xs.min, ys.min, zs.min, xs.max, ys.max, zs.max]
        }
      end

      # Percorre um grupo/componente e emite as faces de dentro (recursivo).
      def self.coletar(inst, mp, herdado, ipc, unit, out, st, top, topip, nome_pai = nil, prof = 0)
        return if prof > 12 || estourou?(st)
        m     = mmul(mp, inst.transformation.to_a)
        h     = herdar(inst, herdado)
        chain = ipc + [inst.persistent_id]
        nome  = nome_de(inst) || nome_pai
        inst.definition.entities.each do |e|
          if e.is_a?(Sketchup::Face)
            next unless visivel?(e)
            fi = face_local(e, h, st)
            emitir(fi, m, unit, nome, out, st, fonte_de(chain, e.persistent_id, top, topip)) if fi
          elsif (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && !kv_group?(e) && visivel?(e)
            coletar(e, m, h, chain, unit, out, st, top, topip, nome, prof + 1)
          end
        end
      end

      # Seleção do SketchUp -> peças (cada grupo/componente selecionado é uma unidade;
      # faces soltas coplanares e encostadas formam uma peça só).
      def self.capturar_selecao(model, st)
        sel  = model.selection.to_a
        path = (model.active_path || []) rescue []
        ip   = path.map(&:persistent_id)
        tw   = (model.edit_transform.to_a rescue IDENT)
        h0   = nil
        path.each { |i| h0 = herdar(i, h0) }
        faces = []
        sel.each do |e|
          break if estourou?(st)
          if e.is_a?(Sketchup::Face)
            fi = face_local(e, h0, st)
            emitir(fi, tw, 0, nil, faces, st, fonte_de(ip, e.persistent_id, nil, nil)) if fi
          elsif (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && !kv_group?(e)
            st[:unit_seq] += 1
            coletar(e, tw, h0, ip, st[:unit_seq], faces, st, e.persistent_id, ip)
          end
        end
        [montar_pecas(faces, st), sel.size]
      end

      # ══════════════════════════════════════════════════════════════════════
      # PEÇAS (Ruby puro)
      # ══════════════════════════════════════════════════════════════════════

      def self.frame_de(n)
        up = vnorm(vsub([0.0, 0.0, 1.0], vscl(n, n[2])))
        up = vnorm(vsub([0.0, 1.0, 0.0], vscl(n, n[1]))) if vlen(up) < 1e-6
        [vnorm(vcross(up, n)), up]
      end

      # Faces -> peças: mesma unidade, mesmo plano e encostadas.
      def self.montar_pecas(faces, st)
        clusters = []
        faces.each do |f|
          c = clusters.find { |k| k[:unit] == f[:unit] && vdot(k[:n], f[:n]) > 0.9998 && (k[:d] - f[:d]).abs < TOL_PLANO }
          c ? c[:fs] << f : clusters << { unit: f[:unit], n: f[:n], d: f[:d], fs: [f] }
        end

        pecas = []
        clusters.each do |c|
          right, up = frame_de(c[:n])
          fs = c[:fs].each do |f|
            f[:ouv] = f[:ow].map { |p| [vdot(p, right), vdot(p, up)] }
            f[:huv] = f[:hw].map { |h| h.map { |p| [vdot(p, right), vdot(p, up)] } }
            us = f[:ouv].map(&:first); vs = f[:ouv].map(&:last)
            f[:umin] = us.min; f[:umax] = us.max; f[:vmin] = vs.min; f[:vmax] = vs.max
          end.reject { |f| f[:umax] - f[:umin] < 1e-3 || f[:vmax] - f[:vmin] < 1e-3 }
          next if fs.empty?

          uf = UnionFind.new(fs.size)
          if fs.size <= CLUSTER_MAX
            fs.each_with_index do |a, i|
              (i + 1...fs.size).each do |j|
                b = fs[j]
                uf.unir(i, j) if a[:umin] <= b[:umax] + TOL_TOQUE && b[:umin] <= a[:umax] + TOL_TOQUE &&
                                 a[:vmin] <= b[:vmax] + TOL_TOQUE && b[:vmin] <= a[:vmax] + TOL_TOQUE
              end
            end
          else
            (1...fs.size).each { |i| uf.unir(0, i) }
          end
          uf.grupos.each { |idx| pecas << nova_peca(idx.map { |i| fs[i] }, c) }
        end
        pecas.reject! { |p| [p[:w], p[:h]].min < st[:min_lado] }   # borda/espessura, não arte
        unir_opostas(pecas)
      end

      def self.nova_peca(fs, c)
        umin = fs.map { |f| f[:umin] }.min; umax = fs.map { |f| f[:umax] }.max
        vmin = fs.map { |f| f[:vmin] }.min; vmax = fs.map { |f| f[:vmax] }.max
        bb   = fs.map { |f| f[:bb] }.transpose
        dom  = fs.max_by { |f| f[:area] }
        {
          faces: fs, fontes: fs.map { |f| f[:fonte] }.compact, n: c[:n], d: c[:d], unit: c[:unit],
          umin: umin, vmin: vmin, w: umax - umin, h: vmax - vmin,
          area: fs.sum { |f| f[:area] }, furos: fs.sum { |f| f[:huv].size },
          info: dom[:info], material: dom[:info][:nome], tex: fs.any? { |f| f[:info][:tex] },
          nome: fs.map { |f| f[:nome] }.compact.first,
          bb: [bb[0].min, bb[1].min, bb[2].min, bb[3].max, bb[4].max, bb[5].max]
        }
      end

      # Faces opostas, mesma medida, até 30 cm: é a mesma chapa (logo em PVC com
      # espessura, placa de dois lados). Fica UMA — frente e verso é decidido por
      # você ("frente e verso" na peça), não deduzido.
      def self.unir_opostas(pecas)
        fora = {}
        pecas.group_by { |p| p[:unit] }.each_value do |g|
          g.each_with_index do |a, i|
            next if fora[a.object_id]
            g[(i + 1)..-1].each do |b|
              next if fora[b.object_id]
              next unless vdot(a[:n], b[:n]) < -0.9998
              next unless (a[:w] - b[:w]).abs < TOL_MEDIDA && (a[:h] - b[:h]).abs < TOL_MEDIDA
              next unless bb_perto?(a[:bb], b[:bb], FV_MAX)
              next if (a[:d] + b[:d]).abs > FV_MAX
              pa = [a[:tex] ? 1 : 0, a[:n][1] < 0 ? 1 : 0]
              pb = [b[:tex] ? 1 : 0, b[:n][1] < 0 ? 1 : 0]
              perde = (pb <=> pa) > 0 ? a : b
              fora[perde.object_id] = true
              break if perde.equal?(a)
            end
          end
        end
        pecas.reject { |p| fora[p.object_id] }
      end

      def self.bb_perto?(a, b, tol)
        3.times.all? { |k| a[k] <= b[k + 3] + tol && b[k] <= a[k + 3] + tol }
      end

      # ── Peça <-> registro persistido ────────────────────────────────────────

      def self.uv4_de(f)
        return nil unless f[:info][:tex] && f[:lado] != :herdado && f[:lado] != :none
        tw  = Sketchup.create_texture_writer
        uvh = f[:face].get_UVHelper(true, true, tw)
        vs  = f[:face].outer_loop.vertices
        [vs.size, 4].min.times.map do |i|
          pos = vs[i].position
          q = f[:lado] == :back ? uvh.get_back_UVQ(pos) : uvh.get_front_UVQ(pos)
          [q.x / q.z, q.y / q.z]
        end
      rescue
        nil
      end

      # Geometria guardada: contorno e recortes relativos ao canto da peça.
      def self.geometria(p)
        u0 = p[:umin]; v0 = p[:vmin]
        rel = ->(pts) { pts.map { |u, v| [(u - u0).round(3), (v - v0).round(3)] } }
        {
          'w' => p[:w].round(3), 'h' => p[:h].round(3), 'area' => p[:area].round(2),
          'furos' => p[:furos], 'material' => p[:material], 'n' => p[:n].map { |c| c.round(4) },
          'faces' => p[:faces].map do |f|
            { 'ouv' => rel.call(f[:ouv]), 'huv' => f[:huv].map { |h| rel.call(h) },
              'mat' => (f[:info][:name].to_s.empty? ? nil : f[:info][:name]), 'uv4' => uv4_de(f) }
          end
        }
      end

      def self.novo_registro(est, p, amb, nome, qtd, fv)
        est['n_p'] += 1
        { 'id' => "p#{est['n_p']}", 'amb' => amb, 'nome' => nome, 'qtd' => qtd, 'fv' => fv, 'obs' => '',
          'fontes' => p[:fontes], 'ger' => geometria(p), 'st' => 'ok', 'aviso' => nil }
      end

      # Registro -> peça pronta para desenhar.
      def self.peca_de(rec, model)
        g = rec['ger']
        { nome: rec['nome'], material: g['material'], w: g['w'], h: g['h'], umin: 0.0, vmin: 0.0,
          furos: g['furos'], fv: rec['fv'],
          faces: g['faces'].map do |f|
            { ouv: f['ouv'], huv: f['huv'], uv4: f['uv4'], mat: (f['mat'] ? (model.materials[f['mat']] rescue nil) : nil) }
          end }
      end

      # ══════════════════════════════════════════════════════════════════════
      # ATUALIZAR DO MODELO (o projeto mudou → a peça acompanha)
      # ══════════════════════════════════════════════════════════════════════

      # Relê as faces de origem de UMA peça. Atualiza 'ger' e 'st'. Devolve o status.
      def self.reler(model, rec, rv, st)
        faces = []
        invalidas = 0
        rec['fontes'].each do |fo|
          face  = rv[fo['pid']]
          chain = (fo['ip'] || []).map { |pid| rv[pid] }
          if !face.is_a?(Sketchup::Face) || chain.any? { |c| c.nil? || (c.respond_to?(:valid?) && !c.valid?) }
            invalidas += 1
            next
          end
          m = IDENT; h = nil
          chain.each { |i| m = mmul(m, i.transformation.to_a); h = herdar(i, h) }
          fi = face_local(face, h, st)
          fi ? emitir(fi, m, 0, nil, faces, st, fo) : (invalidas += 1)
        end

        pecas = faces.empty? ? [] : montar_pecas(faces, st)
        if pecas.empty?
          p = relinkar(model, rec, rv, st)
          if p
            aplicar_leitura(rec, p, 'ok', 'Origem refeita: a face antiga sumiu e a arte foi reencontrada no mesmo objeto.')
            return 'ok'
          end
          rec['st'] = 'perdida'
          rec['aviso'] = 'Origem perdida — selecione a arte no modelo e clique em "Trocar pela seleção". Usando a última medida lida.'
          return 'perdida'
        end

        p   = pecas.max_by { |q| q[:area] }
        avs = []
        avs << "#{invalidas} face(s) da origem não existem mais" if invalidas > 0
        avs << "a origem agora tem #{pecas.size} peças (usada a maior)" if pecas.size > 1
        aplicar_leitura(rec, p, invalidas > 0 ? 'parcial' : 'ok', avs.empty? ? nil : avs.join('; ').capitalize + '.')
        rec['st']
      end

      def self.aplicar_leitura(rec, p, status, aviso)
        rec['fontes'] = p[:fontes]
        rec['ger']    = geometria(p)
        rec['st']     = status
        rec['aviso']  = aviso
      end

      # Face apagada na edição: reencontra a arte pelo objeto que a continha.
      def self.relinkar(model, rec, rv, st)
        ref = rec['ger'] && rec['ger']['n']
        return nil unless ref
        rec['fontes'].map { |f| [f['cont'], f['cip']] }.uniq.each do |cont, cip|
          next unless cont
          inst  = rv[cont]
          chain = (cip || []).map { |pid| rv[pid] }
          next unless inst && inst.valid? && chain.none?(&:nil?)
          m = IDENT; h = nil
          chain.each { |i| m = mmul(m, i.transformation.to_a); h = herdar(i, h) }
          faces = []
          st[:unit_seq] += 1
          coletar(inst, m, h, cip || [], st[:unit_seq], faces, st, cont, cip)
          cand = montar_pecas(faces, st).select { |p| vdot(p[:n], ref) > 0.98 }
          best = cand.min_by { |p| (p[:area] - rec['ger']['area'].to_f).abs }
          return best if best
        end
        nil
      end

      def self.atualizar_pecas(model, ids = nil)
        est = carregar(model)
        rv  = Resolvedor.new(model)
        st  = novo_st(false)
        est['pecas'].each do |rec|
          next if ids && !ids.include?(rec['id'])
          (reler(model, rec, rv, st) rescue (rec['st'] = 'perdida'))
        end
        est
      end

      # ══════════════════════════════════════════════════════════════════════
      # REVISÕES: o que mudou desde a última emitida
      # ══════════════════════════════════════════════════════════════════════

      def self.nome_amb(est, id)
        (est['ambientes'].find { |a| a['id'] == id } || {})['nome'].to_s
      end

      def self.valores(est, rec)
        g = rec['ger']
        { 'nome' => rec['nome'].to_s, 'amb' => rec['amb'], 'amb_nome' => nome_amb(est, rec['amb']),
          'qtd' => rec['qtd'].to_i, 'fv' => !!rec['fv'], 'obs' => rec['obs'].to_s,
          'w' => (g['w'] * POL_M * 100).round, 'h' => (g['h'] * POL_M * 100).round,
          'furos' => g['furos'].to_i, 'material' => g['material'].to_s }
      end

      def self.cm_txt(cm)
        format('%.2f', cm / 100.0).tr('.', ',')
      end

      def self.delta_txt(de, para)
        d = para - de
        "#{d >= 0 ? '+' : '−'}#{cm_txt(d.abs)}"
      end

      def self.comparar(b, c)
        it = []
        it << "renomeada: #{b['nome']} → #{c['nome']}" if b['nome'] != c['nome']
        it << "largura #{cm_txt(b['w'])} → #{cm_txt(c['w'])} m (#{delta_txt(b['w'], c['w'])})" if (b['w'] - c['w']).abs >= 1
        it << "altura #{cm_txt(b['h'])} → #{cm_txt(c['h'])} m (#{delta_txt(b['h'], c['h'])})" if (b['h'] - c['h']).abs >= 1
        it << "quantidade #{b['qtd']} → #{c['qtd']} und." if b['qtd'] != c['qtd']
        it << (c['fv'] ? 'passou a FRENTE E VERSO' : 'deixou de ser FRENTE E VERSO') if b['fv'] != c['fv']
        it << "recortes #{b['furos']} → #{c['furos']}" if b['furos'] != c['furos']
        it << "material #{b['material']} → #{c['material']}" if b['material'] != c['material']
        it << "movida de #{b['amb_nome']} para #{c['amb_nome']}" if b['amb'] != c['amb']
        it << 'observação alterada' if b['obs'] != c['obs']
        it
      end

      def self.med_txt(v)
        "#{cm_txt(v['w'])} x #{cm_txt(v['h'])} m"
      end

      # Lista de diferenças (vazia até a primeira revisão ser emitida).
      def self.diferencas(est)
        return [] if est['rev_n'].nil?
        out = []
        est['pecas'].each do |r|
          cur = valores(est, r)
          b   = est['base'][r['id']]
          if b.nil?
            out << { id: r['id'], tipo: 'nova', amb: cur['amb_nome'], nome: cur['nome'],
                     itens: ["NOVA — #{med_txt(cur)} · #{cur['qtd']} und."] }
          else
            it = comparar(b, cur)
            out << { id: r['id'], tipo: 'alterada', amb: cur['amb_nome'], nome: cur['nome'], itens: it } unless it.empty?
          end
        end
        est['base'].each do |id, b|
          next if est['pecas'].any? { |r| r['id'] == id }
          out << { id: id, tipo: 'removida', amb: b['amb_nome'], nome: b['nome'], itens: ['REMOVIDA'] }
        end
        out
      end

      def self.rev_rotulo(n)
        format('R%02d', n)
      end

      def self.texto_alteracoes(est, difs)
        return nil if est['rev_n'].nil?
        proxima = est['rev_n'] + 1
        linhas = ["ARTES — REVISÃO #{rev_rotulo(proxima)} (alterações desde #{rev_rotulo(est['rev_n'])})"]
        if difs.empty?
          linhas << '' << 'Nenhuma alteração.'
        else
          difs.group_by { |d| d[:amb].to_s }.each do |amb, ds|
            linhas << '' << amb.upcase
            ds.each { |d| linhas << " • #{d[:nome]} — #{d[:itens].join('; ')}" }
          end
        end
        linhas.join("\n")
      end

      # Congela os valores atuais como a revisão emitida (R00, R01...).
      def self.emitir_revisao(model)
        est  = carregar(model)
        difs = diferencas(est)
        texto = texto_alteracoes(est, difs)
        est['rev_n'] = est['rev_n'].nil? ? 0 : est['rev_n'] + 1
        est['base'] = est['pecas'].each_with_object({}) { |r, h| h[r['id']] = valores(est, r) }
        est['hist'] << { 'n' => est['rev_n'], 'em' => Time.now.strftime('%d/%m/%Y %H:%M'),
                         'alteracoes' => difs.size,
                         'texto' => texto || "ARTES — REVISÃO #{rev_rotulo(est['rev_n'])} (primeira emissão)" }
        est['hist'] = est['hist'].last(30)
        persistir(model)
        est
      end

      # ══════════════════════════════════════════════════════════════════════
      # ESTADO PARA A TELA
      # ══════════════════════════════════════════════════════════════════════

      def self.prev_de(ger)
        total = ger['faces'].sum { |f| f['ouv'].size + f['huv'].sum(&:size) }
        if total > 800
          return [{ 'o' => [[0, 0], [ger['w'], 0], [ger['w'], ger['h']], [0, ger['h']]].map { |u, v| [(u * POL_M).round(2), (v * POL_M).round(2)] }, 'h' => [] }]
        end
        mt = ->(pts) { pts.map { |u, v| [(u * POL_M).round(3), (v * POL_M).round(3)] } }
        ger['faces'].map { |f| { 'o' => mt.call(f['ouv']), 'h' => f['huv'].map { |h| mt.call(h) } } }
      end

      def self.ui_peca(rec, dif)
        g = rec['ger']
        { id: rec['id'], amb: rec['amb'], nome: rec['nome'], qtd: rec['qtd'], fv: !!rec['fv'], obs: rec['obs'].to_s,
          w_m: (g['w'] * POL_M).round(3), h_m: (g['h'] * POL_M).round(3), furos: g['furos'], material: g['material'],
          st: rec['st'], aviso: rec['aviso'], prev: prev_de(g),
          dif: dif ? { tipo: dif[:tipo], itens: dif[:itens] } : nil }
      end

      def self.ui_estado(model)
        est  = carregar(model)
        difs = diferencas(est)
        idx  = difs.each_with_object({}) { |d, h| h[d[:id]] = d unless d[:tipo] == 'removida' }
        {
          ambientes: est['ambientes'], ativo: est['ativo'],
          pecas: est['pecas'].map { |r| ui_peca(r, idx[r['id']]) },
          rev: { n: est['rev_n'], rotulo: (est['rev_n'].nil? ? nil : rev_rotulo(est['rev_n'])),
                 proxima: rev_rotulo((est['rev_n'] || -1) + 1),
                 pendentes: difs.size, texto: texto_alteracoes(est, difs),
                 removidas: difs.count { |d| d[:tipo] == 'removida' }, hist: est['hist'].last(10) }
        }
      end

      def self.enviar_estado(model, dlg, extra = {})
        return unless dlg && dlg.visible?
        dlg.execute_script("window.mapaEstado(#{ui_estado(model).merge(extra).to_json})")
      end

      def self.sel_payload(model)
        est = carregar(model)
        st  = novo_st(true)
        pecas, n = capturar_selecao(model, st)
        usados = est['pecas'].flat_map { |r| r['fontes'].map { |f| [f['pid'], r['id']] } }.to_h
        lista = pecas.first(SEL_MAX_PECAS).map do |p|
          g = geometria(p)
          dono = p[:fontes].map { |f| usados[f['pid']] }.compact.first
          dup = dono && (est['pecas'].find { |r| r['id'] == dono } || {})['nome']
          { w_m: (g['w'] * POL_M).round(3), h_m: (g['h'] * POL_M).round(3), furos: g['furos'], material: g['material'],
            sugerido: p[:nome], dup: dup, prev: pecas.size > 12 ? nil : prev_de(g) }
        end
        { n: n, pecas: lista, total: pecas.size, grande: pecas.size > SEL_MAX_PECAS, parcial: st[:estourou] }
      end

      # ══════════════════════════════════════════════════════════════════════
      # ENTRADAS DO DIÁLOGO
      # ══════════════════════════════════════════════════════════════════════

      class SelObs < Sketchup::SelectionObserver
        def onSelectionBulkChange(_s); MapaArtes.selecao_mudou; end
        def onSelectionCleared(_s);    MapaArtes.selecao_mudou; end
        def onSelectionAdded(_s, _e);  MapaArtes.selecao_mudou; end
        def onSelectionRemoved(_s, _e); MapaArtes.selecao_mudou; end
      end

      class ModObs < Sketchup::ModelObserver
        def onTransactionCommit(_m); MapaArtes.modelo_mudou; end
        def onTransactionUndo(_m);   MapaArtes.modelo_mudou; end
        def onTransactionRedo(_m);   MapaArtes.modelo_mudou; end
      end

      def self.dialogo_aberto(dlg)
        @dlg = dlg
        @ativo = false
        model = Sketchup.active_model
        @obs_model = model
        @sel_obs = SelObs.new
        @mod_obs = ModObs.new
        model.selection.add_observer(@sel_obs)
        model.add_observer(@mod_obs)
      rescue
      end

      def self.dialogo_fechado
        (@obs_model.selection.remove_observer(@sel_obs)) rescue nil
        (@obs_model.remove_observer(@mod_obs)) rescue nil
        @dlg = nil
        @ativo = false
      end

      def self.aba_ativa(v)
        @ativo = (v.to_s == '1')
        empurrar_selecao if @ativo
      end

      def self.selecao_mudou
        return if @sel_pendente || !@dlg || !@ativo
        @sel_pendente = true
        UI.start_timer(0.25, false) { @sel_pendente = false; empurrar_selecao }
      end

      def self.empurrar_selecao
        return unless @dlg && @dlg.visible? && @ativo && !@job
        @dlg.execute_script("window.mapaSelecao(#{sel_payload(Sketchup.active_model).to_json})")
      rescue
      end

      # O projeto mudou: avisa a tela (sem reler nada sozinho).
      def self.modelo_mudou
        return if @job || !@dlg || @mudou_pendente
        return if @ignorar_ate && Time.now < @ignorar_ate
        @mudou_pendente = true
        UI.start_timer(0.6, false) do
          @mudou_pendente = false
          (@dlg.execute_script('window.mapaSujo()') if @dlg && @dlg.visible?) rescue nil
        end
      end

      def self.estado_from_dialog(msg, dlg)
        model = Sketchup.active_model
        return unless model
        cfg = parse_cfg(msg)
        if cfg['atualizar']
          atualizar_pecas(model)
          persistir(model)
        end
        enviar_estado(model, dlg)
      rescue => e
        notify("Erro: #{e.message}", false, dlg)
      end

      # Campos editados na tela. Exclusões são explícitas (removidos), para uma
      # gravação atrasada nunca apagar uma peça recém-adicionada.
      def self.salvar_from_dialog(msg, dlg = nil)
        model = Sketchup.active_model
        cfg   = parse_cfg(msg)
        est   = carregar(model)
        if cfg['ambientes'].is_a?(Array) && !cfg['ambientes'].empty?
          est['ambientes'] = cfg['ambientes'].map { |a| { 'id' => a['id'].to_s, 'nome' => a['nome'].to_s.strip } }
          est['ativo'] = cfg['ativo'].to_s if est['ambientes'].any? { |a| a['id'] == cfg['ativo'].to_s }
        end
        remov = (cfg['removidos'] || []).map(&:to_s)
        # Removidas vão para a lixeira da sessão: "Desfazer" devolve a peça inteira
        # (com a referência ao modelo), no mesmo lugar da lista.
        @lixeira ||= {}
        est['pecas'].each_with_index { |r, i| @lixeira[r['id']] = { rec: r, idx: i } if remov.include?(r['id']) }
        @lixeira.shift while @lixeira.size > 30
        est['pecas'].reject! { |r| remov.include?(r['id']) }
        por_id = est['pecas'].each_with_object({}) { |r, h| h[r['id']] = r }
        (cfg['pecas'] || []).each do |c|
          r = por_id[c['id'].to_s] or next
          r['nome'] = c['nome'].to_s.strip unless c['nome'].to_s.strip.empty?
          r['qtd']  = [c['qtd'].to_i, 1].max
          r['fv']   = !!c['fv']
          r['obs']  = c['obs'].to_s.strip
          r['amb']  = c['amb'].to_s if est['ambientes'].any? { |a| a['id'] == c['amb'].to_s }
        end
        ordem = (cfg['ordem'] || []).map(&:to_s)
        est['pecas'].sort_by!.with_index { |r, i| [ordem.index(r['id']) || ordem.size + i, i] } unless ordem.empty?
        persistir(model)
      rescue => e
        notify("Erro ao salvar: #{e.message}", false, dlg)
      end

      def self.sel_from_dialog(dlg)
        empurrar_selecao if dlg
      end

      # Desfazer da remoção de uma peça (dentro da sessão).
      def self.restaurar_from_dialog(msg, dlg)
        model = Sketchup.active_model
        id    = parse_cfg(msg)['id'].to_s
        est   = carregar(model)
        item  = (@lixeira || {}).delete(id)
        return notify('Não há mais o que desfazer.', false, dlg) unless item
        return enviar_estado(model, dlg) if est['pecas'].any? { |r| r['id'] == id }
        est['ambientes'].any? { |a| a['id'] == item[:rec]['amb'] } or item[:rec]['amb'] = est['ativo']
        est['pecas'].insert([item[:idx], est['pecas'].size].min, item[:rec])
        persistir(model)
        enviar_estado(model, dlg, novos: [id])
      rescue => e
        notify("Erro: #{e.message}", false, dlg)
      end

      def self.add_from_dialog(msg, dlg)
        model = Sketchup.active_model
        cfg   = parse_cfg(msg)
        est   = carregar(model)
        pecas, = capturar_selecao(model, novo_st(false))
        return notify('Selecione no SketchUp a face, o grupo ou o componente da arte.', false, dlg) if pecas.empty?
        if pecas.size > SEL_MAX_PECAS
          return notify("A seleção tem #{pecas.size} peças. Selecione só a arte (face, grupo ou componente).", false, dlg)
        end

        amb  = est['ambientes'].any? { |a| a['id'] == cfg['amb'] } ? cfg['amb'] : est['ativo']
        nome = cfg['nome'].to_s.strip
        qtd  = [cfg['qtd'].to_i, 1].max
        fv   = !!cfg['fv']
        obs  = cfg['obs'].to_s.strip
        novas = pecas.each_with_index.map do |p, i|
          nm = if !nome.empty? then (pecas.size > 1 ? "#{nome} #{i + 1}" : nome)
               else p[:nome] || "PEÇA #{est['n_p'] + 1}"
               end
          rec = novo_registro(est, p, amb, nm, qtd, fv)
          rec['obs'] = obs
          est['pecas'] << rec
          rec
        end
        persistir(model)
        enviar_estado(model, dlg, novos: novas.map { |r| r['id'] })
        notify("#{novas.size == 1 ? 'Peça adicionada' : "#{novas.size} peças adicionadas"} a #{nome_amb(est, amb)}.", true, dlg)
      rescue => e
        notify("Erro: #{e.message}", false, dlg)
      end

      # Substitui a ORIGEM da peça pela seleção atual (nome, quantidade e ambiente ficam).
      def self.trocar_from_dialog(msg, dlg)
        model = Sketchup.active_model
        cfg   = parse_cfg(msg)
        est   = carregar(model)
        rec   = est['pecas'].find { |r| r['id'] == cfg['id'].to_s }
        return notify('Peça não encontrada.', false, dlg) unless rec
        pecas, = capturar_selecao(model, novo_st(false))
        return notify('Selecione no SketchUp a nova arte desta peça.', false, dlg) if pecas.empty?
        return notify("A seleção tem #{pecas.size} peças; selecione só a que substitui \"#{rec['nome']}\".", false, dlg) if pecas.size > 1
        aplicar_leitura(rec, pecas[0], 'ok', nil)
        persistir(model)
        enviar_estado(model, dlg, novos: [rec['id']])
        notify("Origem de \"#{rec['nome']}\" substituída pela seleção.", true, dlg)
      rescue => e
        notify("Erro: #{e.message}", false, dlg)
      end

      def self.atualizar_from_dialog(dlg)
        model = Sketchup.active_model
        est   = atualizar_pecas(model)
        persistir(model)
        enviar_estado(model, dlg)
        pend  = diferencas(est).size
        ruins = est['pecas'].count { |r| r['st'] != 'ok' }
        msg = 'Medidas atualizadas do modelo.'
        msg += " #{pend} alteração(ões) desde #{rev_rotulo(est['rev_n'])}." if est['rev_n'] && pend > 0
        msg += " #{ruins} peça(s) pedem atenção." if ruins > 0
        notify(msg, ruins == 0, dlg)
      rescue => e
        notify("Erro: #{e.message}", false, dlg)
      end

      def self.emitir_from_dialog(dlg)
        model = Sketchup.active_model
        atualizar_pecas(model)
        est = emitir_revisao(model)
        enviar_estado(model, dlg, emitida: true)
        notify("Revisão #{rev_rotulo(est['rev_n'])} emitida: é a nova referência para as próximas alterações.", true, dlg)
      rescue => e
        notify("Erro: #{e.message}", false, dlg)
      end

      # ══════════════════════════════════════════════════════════════════════
      # PRANCHA 16:9 (Ruby puro): posição de cada peça
      # ══════════════════════════════════════════════════════════════════════

      LBL_MIN = 0.08 * M
      LBL_MAX = 0.22 * M
      CHAR_W  = 0.62

      def self.metros(inches)
        format('%.2f', inches * POL_M).tr('.', ',')
      end

      def self.linhas_etiqueta(item)
        p = item[:peca]
        ["#{p[:nome]} – #{format('%02d', item[:qtd])} und.#{p[:fv] ? ' · FRENTE E VERSO' : ''}",
         "#{p[:material]} · #{metros(p[:w])} x #{metros(p[:h])} m"]
      end

      # Linhas da etiqueta: [{texto, h, y, cor}], y = distância do topo da etiqueta.
      def self.etiqueta_linhas(item, lbl)
        l1, l2 = linhas_etiqueta(item)
        ls = [[l1, lbl, :normal], [l2, 0.8 * lbl, :cinza]]
        (item[:notas] || []).each { |t, k| ls << [t, 0.8 * lbl, k] }
        y = 0.0
        ls.map { |t, h, k| y += 1.35 * h; { texto: t, h: h, y: y, cor: k } }
      end

      def self.recuo_etiqueta(p, lbl)
        (p[:furos] > 0 ? 0.45 * M : 0.0) + 0.5 * lbl
      end

      # Folgas em volta da peça: cotas à esquerda/topo/base e a etiqueta inteira.
      def self.folgas(item, labels, lbl)
        p = item[:peca]
        esq = (p[:furos] > 0 ? 0.75 : 0.45) * M
        if labels
          ls   = etiqueta_linhas(item, lbl)
          base = recuo_etiqueta(p, lbl) + ls.last[:y] + 0.6 * lbl
          tw   = ls.map { |l| l[:texto].size * CHAR_W * l[:h] }.max
          dir  = [0.35 * M, tw - p[:w] + 0.3 * M].max
        else
          base = p[:furos] > 0 ? 0.45 * M : 0.10 * M
          dir  = 0.35 * M
        end
        { esq: esq, topo: 0.45 * M, base: base, dir: dir }
      end

      # Empacota em prateleiras e devolve o enquadramento 16:9 mais justo.
      # Retorna { itens: [{item, x, z}], w, h, lbl, titulo:{x,z,h}, rev:{x,z,h} } com
      # (x,z) = canto inferior esquerdo da peça; origem no canto inferior esquerdo da prancha.
      def self.encaixar(itens, labels, lbl, titulo, rev)
        ordem = itens.each_with_index.sort_by { |it, i| [-it[:peca][:h], -it[:peca][:w], i] }.map(&:first)
        slots = ordem.map do |it|
          f = folgas(it, labels, lbl)
          { item: it, f: f, w: it[:peca][:w] + f[:esq] + f[:dir], h: it[:peca][:h] + f[:topo] + f[:base] }
        end
        th  = 2.4 * lbl
        tbl = th + 1.6 * lbl           # bloco do título
        mg  = 2.0 * lbl
        largo = slots.map { |s| s[:w] }.max
        total = slots.sum { |s| s[:w] }
        cands = if slots.size == 1 then [largo]
                else (0..27).map { |k| largo * (total / largo)**(k / 27.0) }.uniq
                end

        melhor = nil
        cands.each do |cw|
          linhas = [[]]; x = 0.0
          slots.each do |s|
            if x > 0 && x + s[:w] > cw + 1e-6
              linhas << []
              x = 0.0
            end
            linhas.last << s
            x += s[:w]
          end
          wu = linhas.map { |l| l.sum { |s| s[:w] } }.max
          hu = linhas.sum { |l| l.map { |s| s[:h] }.max }
          wf = [wu + 2 * mg, (hu + tbl + 2 * mg) * BOARD_ASPECT].max
          cand = { linhas: linhas, wu: wu, hu: hu, wf: wf }
          melhor = cand if melhor.nil? || wf < melhor[:wf] - 1e-6 || (wf - melhor[:wf]).abs <= 1e-6 && linhas.size < melhor[:linhas].size
        end

        wf = melhor[:wf]; hf = wf / BOARD_ASPECT
        topo_conteudo = hf - mg - tbl
        sobra = (topo_conteudo - mg) - melhor[:hu]
        cursor = topo_conteudo - [sobra, 0.0].max / 2.0
        out = []
        melhor[:linhas].each do |ln|
          alt = ln.map { |s| s[:h] }.max
          lw  = ln.sum { |s| s[:w] }
          x   = (wf - lw) / 2.0
          ln.each do |s|
            out << { item: s[:item], x: x + s[:f][:esq], z: cursor - s[:f][:topo] - s[:item][:peca][:h] }
            x += s[:w]
          end
          cursor -= alt
        end
        rh = 1.2 * lbl
        { itens: out, w: wf, h: hf, lbl: lbl,
          titulo: { x: mg, z: hf - mg - th, h: th, texto: titulo },
          rev: { x: wf - mg - rev.size * CHAR_W * rh, z: hf - mg - rh, h: rh, texto: rev } }
      end

      # Tamanho do texto proporcional à prancha (~1,1% da largura): converge em 2-3 voltas.
      def self.diagramar(itens, labels, titulo, rev)
        area0 = itens.sum { |it| (it[:peca][:w] + 0.8 * M) * (it[:peca][:h] + 0.9 * M) }
        larg0 = itens.map { |it| it[:peca][:w] + 0.8 * M }.max
        lbl   = ([Math.sqrt(area0 * 1.8), larg0].max * 0.011).clamp(LBL_MIN, LBL_MAX)
        lay   = nil
        3.times do
          lay = encaixar(itens, labels, lbl, titulo, rev)
          novo = (lay[:w] * 0.011).clamp(LBL_MIN, LBL_MAX)
          break if (novo - lbl).abs < 0.02 * lbl
          lbl = novo
        end
        lay
      end

      # Pranchas lado a lado, à esquerda do modelo: [{ quadro, lay, x0 }].
      def self.posicionar_quadros(quadros, labels, rev)
        gap  = 3.0 * M
        lays = quadros.map { |q| diagramar(q[:itens], labels, "ARTES - #{q[:nome].to_s.upcase}", rev) }
        total = lays.sum { |l| l[:w] } + gap * [lays.size - 1, 0].max
        x = -total
        quadros.each_with_index.map do |q, i|
          r = { quadro: q, lay: lays[i], x0: x }
          x += lays[i][:w] + gap
          r
        end
      end

      # ══════════════════════════════════════════════════════════════════════
      # GERAR (desenho em etapas + cenas)
      # ══════════════════════════════════════════════════════════════════════

      def self.gerar_from_dialog(msg, dlg)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        return notify('Já existe um mapa sendo desenhado.', false, dlg) if @job
        cfg = parse_cfg(msg)
        est = atualizar_pecas(model)           # o mapa sempre sai com as medidas atuais do modelo
        persistir(model)
        ids = (cfg['ambientes'] || []).map(&:to_s)
        labels  = cfg['labels'] != false
        destaque = cfg['destaque'] != false
        difs = diferencas(est).each_with_object({}) { |d, h| h[d[:id]] = d unless d[:tipo] == 'removida' }
        prox = rev_rotulo((est['rev_n'] || -1) + 1)

        quadros = est['ambientes'].select { |a| ids.include?(a['id']) }.map do |a|
          itens = est['pecas'].select { |r| r['amb'] == a['id'] }.map do |r|
            notas = []
            notas << [r['obs'], :normal] unless r['obs'].to_s.empty?
            if destaque && (d = difs[r['id']])
              notas << ["#{prox} — #{d[:tipo] == 'nova' ? 'NOVA' : 'ALTERADA: ' + d[:itens].join('; ')}", :alerta]
            end
            notas << ['⚠ ORIGEM PERDIDA — medida da última leitura', :alerta] if r['st'] == 'perdida'
            { peca: peca_de(r, model), qtd: r['qtd'].to_i, notas: notas }
          end
          { nome: a['nome'], itens: itens }
        end.reject { |q| q[:itens].empty? }
        return notify('Nenhuma peça nos ambientes marcados.', false, dlg) if quadros.empty?

        iniciar_desenho(model, quadros, labels, cfg['cenas'] != false, est['rev_n'].nil? ? 'REV 00' : "REV #{format('%02d', est['rev_n'])}", dlg)
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

      def self.iniciar_desenho(model, quadros, labels, cenas, rev, dlg)
        bb   = model_bounds(model)
        pos  = posicionar_quadros(quadros, labels, rev)
        base = bb.empty? ? [0.0, 0.0, 0.0] : [bb.min.x - 3.0 * M, bb.min.y, bb.min.z]
        jobs = [[:limpar]]
        pos.each do |q|
          jobs << [:quadro, q]
          q[:lay][:itens].each { |li| jobs << [:item, q, li] }
        end
        pos.each { |q| jobs << [:cena, q] } if cenas
        @job = { model: model, dlg: dlg, labels: labels, jobs: jobs, i: 0, base: base, primeiro: true,
                 cancelar: false, grupos: {}, t0: Time.now, feitos: 0, cenas: [],
                 total: pos.sum { |q| q[:lay][:itens].size }, n_quadros: pos.size }
        @ignorar_ate = Time.now + 3600
        progresso
        UI.start_timer(0.05, false) { passo }
      end

      def self.passo
        j = @job
        return unless j
        model = j[:model]
        if j[:cancelar]
          @ignorar_ate = Time.now + 1.5
          @job = nil
          return notify("Cancelado: #{j[:feitos]} peça(s) desenhadas. Ctrl+Z desfaz.", true, j[:dlg])
        end
        # Etapas seguintes entram na mesma operação: um Ctrl+Z desfaz o mapa inteiro.
        model.start_operation('EVA — Mapa de Artes', true, false, !j[:primeiro])
        j[:primeiro] = false
        t = Time.now
        loop do                      # pelo menos uma tarefa por etapa: sempre avança
          executar(j, j[:jobs][j[:i]])
          j[:i] += 1
          break if j[:i] >= j[:jobs].size || (Time.now - t) >= LOTE_SEG
        end
        model.commit_operation

        if j[:i] >= j[:jobs].size
          @ignorar_ate = Time.now + 1.5
          @job = nil
          seg = (Time.now - j[:t0]).round(1)
          cs  = j[:cenas].empty? ? '' : " Cena(s): #{j[:cenas].join(', ')}."
          enviar_estado(model, j[:dlg])
          notify("Mapa gerado: #{j[:n_quadros]} prancha(s), #{j[:feitos]} peça(s) em #{seg} s.#{cs} Ctrl+Z desfaz.", true, j[:dlg])
        else
          progresso
          UI.start_timer(0.05, false) { passo }
        end
      rescue => e
        (model.abort_operation rescue nil)
        @ignorar_ate = Time.now + 1.5
        @job = nil
        notify("Erro ao desenhar: #{e.message}", false, j && j[:dlg])
      end

      def self.progresso
        j = @job
        return unless j
        if j[:dlg] && j[:dlg].visible?
          j[:dlg].execute_script("window.mapaProgresso(#{j[:feitos]}, #{j[:total]})")
        else
          Sketchup.status_text = "EVA Mapa de Artes: desenhando #{j[:feitos]}/#{j[:total]}..."
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
          g.name = "ARTES - #{q[:quadro][:nome]}"
          b  = j[:base]
          g.transformation = Geom::Transformation.translation(Geom::Vector3d.new(b[0] + q[:x0], b[1], b[2]))
          desenhar_moldura(g.entities, q[:lay])
          j[:grupos][q.object_id] = g
        when :item
          g  = j[:grupos][job[1].object_id]
          li = job[2]
          (desenhar_item(g.entities, li[:item], li[:x], li[:z], j[:labels], job[1][:lay][:lbl], j[:model]) rescue nil)
          j[:feitos] += 1
        when :cena
          q = job[1]
          g = j[:grupos][q.object_id]
          t = g.transformation.to_a
          centro = [t[12] + q[:lay][:w] / 2.0, t[13], t[14] + q[:lay][:h] / 2.0]
          nome = criar_cena(j[:model], "ARTES - #{q[:quadro][:nome]}", centro, q[:lay][:h])
          j[:cenas] << nome if nome
        end
      end

      # Fundo branco (1 cm atrás das peças), título e rótulo de revisão.
      def self.desenhar_moldura(e, lay)
        y = 0.01 * M
        pts = [[0, y, 0], [lay[:w], y, 0], [lay[:w], y, lay[:h]], [0, y, lay[:h]]].map { |p| Geom::Point3d.new(*p) }
        bg = (e.add_face(pts) rescue nil)
        if bg && bg.valid?
          branco = Sketchup::Color.new(255, 255, 255)
          bg.material = branco
          bg.back_material = branco
        end
        t = lay[:titulo]; r = lay[:rev]
        texto(e, t[:texto], t[:x], t[:z], t[:h])
        texto(e, r[:texto], r[:x], r[:z], r[:h], :cinza)
      end

      # Cena 16:9 enquadrando a prancha (câmera paralela, vista Frente). Se a cena já
      # existe, é atualizada NO LUGAR (mantém nome e posição na lista de cenas).
      def self.criar_cena(model, nome, centro, altura)
        view = model.active_view
        eye  = Geom::Point3d.new(centro[0], centro[1] - 40.0 * M, centro[2])
        cam  = Sketchup::Camera.new(eye, Geom::Point3d.new(*centro), Geom::Vector3d.new(0, 0, 1), false)
        (cam.height = altura) rescue nil
        (cam.aspect_ratio = BOARD_ASPECT) rescue nil
        (model.layers[KV_TAG].visible = true) rescue nil
        pg = (model.pages[nome] rescue nil)
        if pg
          model.pages.selected_page = pg
          view.camera = cam
          pg.update(33)          # câmera + visibilidade das tags
        else
          view.camera = cam
          pg = model.pages.add(nome, 33)
        end
        nome
      rescue
        nil
      end

      # Uma peça: faces de frente (olhando pela vista Frente), recortes, cotas e etiqueta.
      def self.desenhar_item(ents, it, x0, z0, labels, lbl, model)
        p  = it[:peca]
        ig = ents.add_group
        e  = ig.entities
        ponto = ->(u, v) { Geom::Point3d.new(x0 + u - p[:umin], 0.0, z0 + v - p[:vmin]) }

        p[:faces].each do |f|
          pts = f[:ouv].map { |u, v| ponto.call(u, v) }
          nf = (e.add_face(pts) rescue nil)
          next unless nf && nf.valid?
          nf.reverse! if nf.normal.y > 0                       # frente para quem olha pela vista Frente
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

      # Textura pelos 4 primeiros cantos: ponto novo ↔ UV guardado do vértice original.
      def self.aplicar_material(nf, f, pts)
        mat = f[:mat]
        return unless mat
        if f[:uv4] && mat.respond_to?(:texture) && mat.texture
          begin
            n = [f[:uv4].size, pts.size, 4].min
            mapping = []
            n.times { |i| mapping << pts[i] << Geom::Point3d.new(f[:uv4][i][0], f[:uv4][i][1], 0.0) }
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

      # Largura no topo; à esquerda a altura (ou a corrente dos recortes); na base a
      # corrente dos recortes na horizontal — como no mapa de referência.
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

      # NOME – N und. / material · L x A m / observações e marcas de revisão.
      def self.etiqueta(e, it, x0, z0, lbl)
        topo = z0 - recuo_etiqueta(it[:peca], lbl)
        etiqueta_linhas(it, lbl).each { |l| texto(e, l[:texto], x0, topo - l[:y], l[:h], l[:cor]) }
      end

      # Texto 3D no plano da prancha, legível pela vista Frente (olhando para +Y).
      def self.texto(e, txt, x, z, altura, cor = :normal)
        g = e.add_group
        g.entities.add_3d_text(txt.to_s, TextAlignLeft, 'Arial', false, false, altura, 0.0, 0.0, true, 0.0)
        g.transform!(Geom::Transformation.rotation(ORIGIN, Geom::Vector3d.new(1, 0, 0), 90.degrees))
        g.transform!(Geom::Transformation.translation(Geom::Vector3d.new(x, 0.0, z)))
        g.name = 'texto'
        case cor
        when :alerta then (g.material = Sketchup::Color.new(200, 30, 30)) rescue nil
        when :cinza  then (g.material = Sketchup::Color.new(110, 110, 110)) rescue nil
        end
        g
      rescue
        nil
      end

      def self.ensure_kv_group(model)
        kv = model.entities.grep(Sketchup::Group).find { |g| g.valid? && kv_group?(g) }
        return kv if kv
        kv = model.entities.add_group
        kv.set_attribute(ATTR_NS, 'kv', '1')
        kv.name  = 'KV - Mapa de Artes'
        kv.layer = (model.layers[KV_TAG] || model.layers.add(KV_TAG))
        kv
      end

      def self.model_bounds(model)
        bb = Geom::BoundingBox.new
        model.entities.each do |ent|
          next if ent.is_a?(Sketchup::Group) && kv_group?(ent)
          (bb.add(ent.bounds) rescue nil)
        end
        bb
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

      def self.mdir(m, v)
        [m[0] * v[0] + m[4] * v[1] + m[8] * v[2],
         m[1] * v[0] + m[5] * v[1] + m[9] * v[2],
         m[2] * v[0] + m[6] * v[1] + m[10] * v[2]]
      end

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
