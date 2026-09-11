# encoding: UTF-8
# =============================================================================
# EVA Stand1 — mapa_artes.rb
# Aba "Mapa de Artes": diagrama + cota a comunicação visual do modelo.
#
# TRÊS ENTRADAS, UM MESMO PIPELINE:
#   1. Varredura  — a aba lista os materiais de CV encontrados no modelo
#                   (adesivo / lona / PVC / letra caixa e correlatos) e o
#                   usuário marca quais quer diagramar.
#   2. Seleção    — o usuário seleciona no SketchUp faces, GRUPOS e/ou
#                   COMPONENTES (vários de uma vez) e diagrama o que estiver
#                   dentro deles.
#   3. Toolbar    — atalho para a varredura automática de todos os materiais.
#
# Cada face é COPIADA (o modelo real nunca muda) para o grupo "KV - Mapa de
# Artes", orientada de frente, arranjada (peças à esquerda, paredes em
# fileiras), COTADA com cotas nativas L×A e etiquetada com o nome do material.
# O quadro é posicionado à ESQUERDA do modelo, alinhado ao eixo do estande —
# pronto para você enquadrar e salvar a cena manualmente.
#
# Tudo roda em start_operation/commit_operation (1 Ctrl+Z desfaz).
# =============================================================================

require 'json'

module STAND1
  module EVA
    module MapaArtes

      ATTR_NS  = 'EVA'    # namespace de atributos
      KV_TAG   = 'KV'     # tag/layer do grupo KV
      POL_M    = 0.0254   # polegada -> metro
      FACE_CAP = 4000     # teto de faces por varredura (proteção)

      # ── Reconhecimento de materiais de comunicação visual ───────────────────
      #
      # Casa por "contém", sobre o nome normalizado (minúsculo, sem acento). A
      # lista cobre adesivo, lona, PVC, letra caixa e correlatos — o suficiente
      # para não trazer todas as texturas aleatórias do modelo.
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

      # ── Entradas públicas ───────────────────────────────────────────────────

      # Aba: varre o modelo e devolve os materiais de CV encontrados.
      def self.scan_from_dialog(dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        mats = scan_materials(model)
        dlg.execute_script("window.setMapaMats(#{mats.to_json})") if dlg && dlg.visible?
        mats
      rescue => e
        notify("Erro na varredura: #{e.message}", false, dlg)
      end

      # Aba: diagrama as faces dos materiais marcados na lista.
      def self.diagramar_from_dialog_mats(msg, dlg = nil)
        cfg   = (JSON.parse(msg) rescue {})
        names = (cfg['mats'] || []).map { |n| normalize(n) }
        thr   = parse_thr(cfg['thr'])
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        return notify('Marque ao menos um material na lista.', false, dlg) if names.empty?

        items = []
        collect_faces(model.entities, Geom::Transformation.new, items) do |f|
          face_material_names(f).any? { |n| names.include?(n) }
        end
        return notify('Nenhuma face encontrada para os materiais marcados.', false, dlg) if items.empty?
        build_kv(model, items, thr, cfg['labels'] != false, dlg)
      end

      # Aba: diagrama a SELEÇÃO do SketchUp (faces, grupos e componentes).
      def self.diagramar_from_dialog(msg, dlg = nil)
        cfg = (JSON.parse(msg) rescue nil)
        cfg = { 'thr' => msg } unless cfg.is_a?(Hash)   # compat: payload antigo era só o limite
        diagramar_selecao(parse_thr(cfg['thr']), cfg['labels'] != false, dlg)
      end

      # Toolbar (sem diálogo): varredura automática de todos os materiais de CV.
      def self.diagramar_auto(threshold_m = 2.0, dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model
        items = []
        collect_faces(model.entities, Geom::Transformation.new, items) { |f| face_matches?(f) }
        if items.empty?
          return notify('Nenhuma face de comunicação visual encontrada (adesivo / lona / PVC / letra caixa).', false, dlg)
        end
        build_kv(model, items, threshold_m, true, dlg)
      end

      # ── Varredura de materiais (alimenta a lista da aba) ────────────────────

      def self.scan_materials(model)
        acc = {}
        tally_materials(model.entities, Geom::Transformation.new, acc)
        acc.values.sort_by { |m| [-m[:area_m2], m[:name].downcase] }
      end

      def self.tally_materials(entities, tr, acc, depth = 0)
        return if depth > 12
        entities.each do |e|
          if e.is_a?(Sketchup::Face)
            next unless face_matches?(e)
            name = display_material_name(e)
            next unless name
            key = normalize(name)
            acc[key] ||= { name: name, key: key, faces: 0, area_m2: 0.0 }
            acc[key][:faces]   += 1
            acc[key][:area_m2] += face_area_m2(e, tr)
          elsif e.is_a?(Sketchup::Group)
            next if kv_group?(e)
            tally_materials(e.entities, tr * e.transformation, acc, depth + 1)
          elsif e.is_a?(Sketchup::ComponentInstance)
            tally_materials(e.definition.entities, tr * e.transformation, acc, depth + 1)
          end
        end
      rescue
      end

      def self.face_area_m2(f, tr)
        (f.area(tr) * POL_M * POL_M).round(3)
      rescue
        (f.area * POL_M * POL_M).round(3)
      end

      # ── Coleta genérica de faces (com filtro opcional) ──────────────────────

      def self.collect_faces(entities, tr, items, depth = 0, &filter)
        return if depth > 12 || items.size >= FACE_CAP
        entities.each do |e|
          break if items.size >= FACE_CAP
          if e.is_a?(Sketchup::Face)
            next if filter && !filter.call(e)
            info = (face_info(e, tr) rescue nil)
            items << info if info
          elsif e.is_a?(Sketchup::Group)
            next if kv_group?(e)
            collect_faces(e.entities, tr * e.transformation, items, depth + 1, &filter)
          elsif e.is_a?(Sketchup::ComponentInstance)
            collect_faces(e.definition.entities, tr * e.transformation, items, depth + 1, &filter)
          end
        end
      rescue
      end

      # ── Seleção rica: faces + grupos + componentes, vários de uma vez ───────
      #
      # Regra por container selecionado: pega as faces de CV de dentro dele; se
      # não houver nenhuma, o usuário claramente escolheu aquele objeto de
      # propósito, então pega todas as faces com material.
      def self.diagramar_selecao(threshold_m, labels = true, dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model

        sel = model.selection.to_a
        if sel.empty?
          return notify('Selecione faces, grupos ou componentes no SketchUp.', false, dlg)
        end

        tw    = model.edit_transform
        items = []
        sel.each do |e|
          begin
            if e.is_a?(Sketchup::Face)
              info = face_info(e, tw)
              items << info if info
            elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
              ents = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
              sub  = []
              collect_faces(ents, tw * e.transformation, sub) { |f| face_matches?(f) }
              if sub.empty?
                collect_faces(ents, tw * e.transformation, sub) { |f| !display_material_name(f).nil? }
              end
              items.concat(sub)
            end
          rescue
          end
        end

        if items.empty?
          return notify('Nada diagramável na seleção (sem faces com material).', false, dlg)
        end
        build_kv(model, items, threshold_m, labels, dlg)
      end

      # ── Pipeline compartilhado — monta o quadro KV ──────────────────────────

      def self.build_kv(model, items, threshold_m, labels, dlg)
        items = dedup(items)
        model.start_operation('EVA — Mapa de Artes (KV)', true)
        begin
          bb     = model_bounds(model)        # antes de mexer no grupo KV
          kv     = ensure_kv_group(model)
          kv_ent = kv.entities
          kv_ent.clear!                       # rebuild — re-rodar re-diagrama do zero
          # Eixo do estande com o quadro JÁ vazio: senão as peças recém-criadas
          # entrariam no cálculo e enviesariam a orientação.
          ang = (PromptBuilder.footprint_axis(model) rescue nil) || 0.0

          walls  = items.select { |it| [it[:w_m], it[:h_m]].max >= threshold_m }
          pieces = items - walls

          pack(pieces, walls).each do |pl|
            (place_item(kv_ent, pl[:item], pl[:x], pl[:z], labels) rescue nil)
          end

          place_board(kv, bb, ang)
          model.commit_operation
          notify("KV gerado: #{walls.size} parede(s) + #{pieces.size} peça(s). " \
                 'Enquadre e salve a cena manualmente.', true, dlg)
        rescue => e
          model.abort_operation
          notify("Erro: #{e.message}", false, dlg)
        end
      end

      # A mesma face pode ser alcançada por caminhos diferentes (ex.: face solta
      # também coberta por um grupo selecionado). Descarta repetições.
      def self.dedup(items)
        seen = {}
        items.select do |it|
          k = [it[:face].entityID, it[:w_in].round(3), it[:h_in].round(3)]
          seen[k] ? false : (seen[k] = true)
        end
      rescue
        items
      end

      # ── Reconhecimento de material ──────────────────────────────────────────

      def self.kv_group?(g)
        g.get_attribute(ATTR_NS, 'kv', nil) == '1'
      rescue
        false
      end

      def self.face_material_names(face)
        [face.material, face.back_material].compact.map { |m| normalize(m.name.to_s) }
      rescue
        []
      end

      # Nome "bonito" (como aparece na paleta) do material da face.
      def self.display_material_name(face)
        m = face.material || face.back_material
        return nil unless m
        n = m.display_name.to_s
        n.strip.empty? ? nil : n
      rescue
        nil
      end

      def self.face_matches?(face)
        names = face_material_names(face)
        return false if names.empty?
        return false if names.any? { |n| EXCLUDE.any? { |x| n.include?(x) } }
        names.any? { |n| KEYWORDS.any? { |k| n.include?(k) } }
      rescue
        false
      end

      def self.normalize(s)
        s.to_s.downcase.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').gsub(/\s+/, ' ').strip
      rescue
        s.to_s.downcase.strip
      end

      def self.parse_thr(thr)
        v = thr.to_s.strip.tr(',', '.').to_f
        v <= 0 ? 2.0 : v
      end

      # Gira 90° (no plano do quadro) os itens/grupos selecionados dentro do KV.
      def self.girar_90(dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model

        groups = model.selection.grep(Sketchup::Group)
        return notify('Selecione um item do KV (grupo) para girar.', false, dlg) if groups.empty?

        model.start_operation('EVA — girar 90° KV', true)
        begin
          groups.each do |g|
            next unless g.valid?
            c = g.bounds.center
            g.transform!(Geom::Transformation.rotation(c, Geom::Vector3d.new(0, 1, 0), 90.degrees))
          end
          model.commit_operation
          notify('Item girado 90°.', true, dlg)
        rescue => e
          model.abort_operation
          notify("Erro ao girar: #{e.message}", false, dlg)
        end
      end

      # ── Medição da face (L×A no plano + UV local p/ recortar a arte) ────────

      def self.face_info(f, tw)
        z  = [0.0, 0.0, 1.0]
        na = vnorm(vtransform(f.normal, tw))
        return nil if vlen(na) < 1e-6

        up = vnorm(vsub(z, vscl(na, vdot(z, na))))
        if vlen(up) < 1e-6                       # face ~horizontal: usa Y como ref
          y  = [0.0, 1.0, 0.0]
          up = vnorm(vsub(y, vscl(na, vdot(y, na))))
        end
        return nil if vlen(up) < 1e-6
        right = vnorm(vcross(up, na))
        return nil if vlen(right) < 1e-6

        verts = f.outer_loop.vertices
        wpts  = verts.map { |v| v.position.transform(tw).to_a }
        o     = wpts[0]
        us    = wpts.map { |p| vdot(vsub(p, o), right) }
        vs    = wpts.map { |p| vdot(vsub(p, o), up) }
        minu  = us.min; minv = vs.min
        w_in  = us.max - minu
        h_in  = vs.max - minv
        return nil if w_in < 1e-3 || h_in < 1e-3

        {
          face:  f,
          label: display_material_name(f),
          uv:    verts.each_index.map { |i| [us[i] - minu, vs[i] - minv] },
          w_in:  w_in,
          h_in:  h_in,
          w_m:   w_in * POL_M,
          h_m:   h_in * POL_M
        }
      end

      # ── Arranjo (2 zonas: peças à esquerda, paredes em fileiras) ────────────

      def self.pack(pieces, walls)
        gap   = 0.5.m
        cotag = 0.6.m          # espaço extra p/ cota + etiqueta entre itens
        out   = []

        col_w = (pieces.map { |it| it[:w_in] }.max || 0.0)
        z = 0.0
        pieces.each do |it|
          out << { item: it, x: 0.0, z: z }
          z += it[:h_in] + gap + cotag
        end

        wx0        = pieces.empty? ? 0.0 : (col_w + gap + 1.0.m)
        total_area = walls.reduce(0.0) { |s, it| s + it[:w_in] * it[:h_in] }
        widest     = (walls.map { |it| it[:w_in] }.max || 0.0)
        target_w   = [Math.sqrt(total_area * 1.414), widest].max

        rx = 0.0; rz = 0.0; row_h = 0.0
        walls.sort_by { |it| -it[:h_in] }.each do |it|
          if rx > 0 && (rx + it[:w_in]) > target_w
            rz += row_h + gap + cotag
            rx = 0.0; row_h = 0.0
          end
          out << { item: it, x: wx0 + rx, z: rz }
          rx += it[:w_in] + gap
          row_h = [row_h, it[:h_in]].max
        end

        out
      end

      # ── Coloca 1 item (cópia da face + cotas + etiqueta) num sub-grupo ──────

      def self.place_item(kv_ent, it, x0, z0, labels)
        ig  = kv_ent.add_group
        e   = ig.entities
        pts = it[:uv].map { |p| Geom::Point3d.new(x0 + p[0], 0.0, z0 + p[1]) }

        newf = e.add_face(pts)
        return unless newf && newf.valid?
        newf.reverse! if newf.normal.to_a[1] < 0    # frente virada p/ +Y
        apply_texture(newf, it[:face], pts)
        add_cotas(e, x0, z0, it[:w_in], it[:h_in])
        add_label(e, it, x0, z0) if labels
        ig.name = it[:label].to_s unless it[:label].to_s.empty?
        ig
      end

      # Mapeia a textura por POSIÇÃO (pts que calculei) e não pela ordem de
      # vértices do add_face — o SketchUp pode reordenar os vértices da nova face.
      def self.apply_texture(newf, origf, pts)
        mat = origf.material || origf.back_material
        return unless mat
        if mat.respond_to?(:texture) && mat.texture
          begin
            tw    = Sketchup.create_texture_writer
            uvh   = origf.get_UVHelper(true, false, tw)
            verts = origf.outer_loop.vertices
            n     = [verts.size, pts.size, 4].min
            mapping = []
            n.times do |i|
              q  = uvh.get_front_UVQ(verts[i].position)
              uv = Geom::Point3d.new(q.x / q.z, q.y / q.z, 0.0)
              mapping << pts[i] << uv
            end
            if newf.position_material(mat, mapping, true)
              newf.back_material = mat
              return
            end
          rescue
          end
        end
        newf.material      = mat
        newf.back_material = mat
      end

      def self.add_cotas(e, x0, z0, w, h)
        off = 0.35.m
        bl  = Geom::Point3d.new(x0,     0.0, z0)
        br  = Geom::Point3d.new(x0 + w, 0.0, z0)
        tl  = Geom::Point3d.new(x0,     0.0, z0 + h)
        e.add_dimension_linear(bl, br, Geom::Vector3d.new(0, 0, -off))  # largura
        e.add_dimension_linear(bl, tl, Geom::Vector3d.new(-off, 0, 0))  # altura
      rescue
      end

      # Etiqueta abaixo da peça: nome do material + medida em metros. O texto 3D
      # nasce no plano XY, então o sub-grupo é girado 90° em X para o plano do quadro.
      def self.add_label(e, it, x0, z0)
        txt = it[:label].to_s.strip
        dim = format('%.2f x %.2f m', it[:w_m], it[:h_m]).tr('.', ',')
        txt = txt.empty? ? dim : "#{txt}  —  #{dim}"

        g = e.add_group
        g.entities.add_3d_text(txt, TextAlignLeft, 'Arial', false, false, 0.10.m, 0.0, 0.0, true, 0.0)
        g.transform!(Geom::Transformation.rotation(ORIGIN, Geom::Vector3d.new(1, 0, 0), 90.degrees))
        g.transform!(Geom::Transformation.translation(Geom::Vector3d.new(x0, 0.0, z0 - 0.60.m)))
        g.name = 'etiqueta'
      rescue
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

      # Bounding box do modelo IGNORANDO o próprio quadro KV.
      def self.model_bounds(model)
        bb = Geom::BoundingBox.new
        model.entities.each do |ent|
          next if ent.is_a?(Sketchup::Group) && kv_group?(ent)
          (bb.add(ent.bounds) rescue nil)
        end
        bb
      end

      # ── Posiciona o quadro à ESQUERDA do modelo, alinhado ao eixo do estande ─
      #
      # O quadro é desenhado em coordenadas locais no plano XZ (x p/ a direita,
      # z p/ cima). Aqui ele é girado para acompanhar o eixo principal da planta
      # (o estande pode estar modelado torto em relação aos eixos do mundo) e
      # encostado à esquerda do modelo, com a base na mesma cota.
      def self.place_board(kv, bb, ang)
        gap = 2.0.m
        w   = kv.bounds.width.to_f
        return if w <= 0

        dx  = Geom::Vector3d.new(Math.cos(ang), Math.sin(ang), 0)
        dy  = Geom::Vector3d.new(-Math.sin(ang), Math.cos(ang), 0)

        if bb.empty?
          kv.transformation = Geom::Transformation.axes(
            Geom::Point3d.new(-(w + gap), 0, 0), dx, dy, Z_AXIS
          )
          return
        end

        corners = (0..7).map { |i| bb.corner(i).to_a }
        u_min   = corners.map { |p| p[0] * dx.x + p[1] * dx.y }.min
        v_min   = corners.map { |p| p[0] * dy.x + p[1] * dy.y }.min

        u = u_min - gap - w
        v = v_min
        origin = Geom::Point3d.new(
          dx.x * u + dy.x * v,
          dx.y * u + dy.y * v,
          bb.min.z
        )
        kv.transformation = Geom::Transformation.axes(origin, dx, dy, Z_AXIS)
      rescue
      end

      # ── Status → diálogo (ou barra/messagebox se acionado pela toolbar) ─────

      def self.notify(msg, ok, dlg = nil)
        if dlg && dlg.visible?
          dlg.execute_script("window.mapaStatus(#{msg.to_json}, #{(!!ok).to_json})")
        else
          Sketchup.status_text = "EVA Mapa de Artes: #{msg}"
          UI.messagebox("EVA Mapa de Artes: #{msg}") unless ok
        end
      rescue
      end

      # ── Vetores (arrays [x,y,z], em polegadas) ──────────────────────────────

      def self.vdot(a, b);   a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; end
      def self.vsub(a, b);   [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; end
      def self.vscl(a, s);   [a[0]*s, a[1]*s, a[2]*s]; end
      def self.vlen(a);      Math.sqrt(vdot(a, a)); end
      def self.vcross(a, b)
        [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]]
      end
      def self.vnorm(a)
        m = vlen(a); m < 1e-9 ? [0.0, 0.0, 0.0] : vscl(a, 1.0 / m)
      end
      def self.vtransform(vec, tr)
        vec.clone.transform(tr).to_a
      end

    end
  end
end
