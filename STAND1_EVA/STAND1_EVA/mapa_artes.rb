# encoding: UTF-8
# =============================================================================
# EVA Stand1 — mapa_artes.rb
# Aba "Mapa de Artes": diagrama + cota a comunicação visual numa cena KV.
#
# FLUXO: o usuário seleciona faces (lonas/logos/balcões) no modelo e aciona
# "Diagramar KV". Cada face é COPIADA (não move o original) para um grupo
# dedicado "KV - Mapa de Artes" (fora do modelo real), orientada de frente,
# arranjada em 2 zonas (peças pequenas em coluna à esquerda, paredes grandes
# em fileiras) e COTADA com cotas nativas L×A. Uma cena "KV AUTO" é criada.
#
# ISOLADO: capacidade nova, não altera nenhum fluxo existente. Tudo roda em
# start_operation/commit_operation (1 Ctrl+Z desfaz).
# =============================================================================

require 'json'

module STAND1
  module EVA
    module MapaArtes

      ATTR_NS   = 'EVA'          # namespace de atributos
      KV_TAG    = 'KV'          # tag/layer do grupo KV
      KV_SCENE  = 'KV AUTO'      # nome da cena gerada (não usa 'KV' p/ não
                                 # sobrescrever a cena manual do usuário)
      POL_M     = 0.0254         # polegada -> metro

      # ── Entradas públicas ───────────────────────────────────────────────────

      # Chamado pela aba (recebe o limite parede×peça em metros, como string).
      def self.diagramar_from_dialog(thr, dlg = nil)
        thr_m = thr.to_s.strip.tr(',', '.').to_f
        thr_m = 2.0 if thr_m <= 0
        diagramar(thr_m, dlg)
      end

      # Chamado pela toolbar (sem diálogo) — usa limite padrão de 2 m.
      def self.diagramar_selecao
        diagramar(2.0, nil)
      end

      # ── Núcleo ──────────────────────────────────────────────────────────────

      def self.diagramar(threshold_m, dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model

        faces = model.selection.grep(Sketchup::Face)
        if faces.empty?
          return notify('Selecione ao menos uma face de comunicação visual.', false, dlg)
        end

        tw = model.edit_transform

        items = []
        faces.each do |f|
          begin
            info = face_info(f, tw)
            items << info if info
          rescue => e
          end
        end
        if items.empty?
          return notify('Nenhuma face válida na seleção.', false, dlg)
        end

        model.start_operation('EVA — Mapa de Artes (KV)', true)
        begin
          kv     = ensure_kv_group(model)
          kv_ent = kv.entities
          kv_ent.clear!   # rebuild — re-rodar re-diagrama do zero

          walls  = items.select { |it| [it[:w_m], it[:h_m]].max >= threshold_m }
          pieces = items - walls

          pack(pieces, walls).each do |pl|
            begin
              place_item(kv_ent, pl[:item], pl[:x], pl[:z])
            rescue => e
            end
          end

          make_scene(model, kv)
          model.commit_operation
          notify("KV gerado: #{walls.size} parede(s) + #{pieces.size} peça(s).", true, dlg)
        rescue => e
          model.abort_operation
          notify("Erro: #{e.message}", false, dlg)
        end
      end

      # Gira 90° (no plano do quadro) os itens/grupos selecionados dentro do KV.
      def self.girar_90(dlg = nil)
        model = Sketchup.active_model
        return notify('Nenhum modelo aberto.', false, dlg) unless model

        groups = model.selection.grep(Sketchup::Group)
        if groups.empty?
          return notify('Selecione um item do KV (grupo) para girar.', false, dlg)
        end

        model.start_operation('EVA — girar 90° KV', true)
        begin
          groups.each do |g|
            next unless g.valid?
            c = g.bounds.center
            t = Geom::Transformation.rotation(c, Geom::Vector3d.new(0, 1, 0), 90.degrees)
            g.transform!(t)
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
          face:     f,
          uv:       verts.each_index.map { |i| [us[i] - minu, vs[i] - minv] },
          w_in:     w_in,
          h_in:     h_in,
          w_m:      w_in * POL_M,
          h_m:      h_in * POL_M
        }
      end

      # ── Arranjo (2 zonas: peças à esquerda, paredes em fileiras) ────────────

      def self.pack(pieces, walls)
        gap   = 0.5.m
        cotag = 0.5.m          # espaço extra p/ a cota entre itens
        out   = []

        # Coluna de peças (empilhadas de baixo p/ cima)
        col_w = (pieces.map { |it| it[:w_in] }.max || 0.0)
        z = 0.0
        pieces.each do |it|
          out << { item: it, x: 0.0, z: z }
          z += it[:h_in] + gap + cotag
        end

        # Área das paredes (fileiras), à direita da coluna de peças
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

      # ── Coloca 1 item (cópia da face + cotas) num sub-grupo ─────────────────

      def self.place_item(kv_ent, it, x0, z0)
        ig  = kv_ent.add_group
        e   = ig.entities
        pts = it[:uv].map { |p| Geom::Point3d.new(x0 + p[0], 0.0, z0 + p[1]) }

        newf = e.add_face(pts)
        return unless newf && newf.valid?
        # Garante a frente virada para +Y (lado da câmera do KV).
        newf.reverse! if newf.normal.to_a[1] < 0
        apply_texture(newf, it[:face], pts)
        add_cotas(e, x0, z0, it[:w_in], it[:h_in])
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
          rescue => e
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
        e.add_dimension_linear(bl, tl, Geom::Vector3d.new(-off, 0, 0)) # altura
      rescue => e
      end

      # ── Grupo KV (isolado, tag própria, deslocado do modelo) ────────────────

      def self.ensure_kv_group(model)
        kv = model.entities.grep(Sketchup::Group).find do |g|
          g.valid? && (g.get_attribute(ATTR_NS, 'kv', nil) == '1')
        end
        return kv if kv

        kv = model.entities.add_group
        kv.set_attribute(ATTR_NS, 'kv', '1')
        kv.name  = 'KV - Mapa de Artes'
        kv.layer = (model.layers[KV_TAG] || model.layers.add(KV_TAG))

        bb = Geom::BoundingBox.new
        model.entities.each { |ent| next if ent == kv; (bb.add(ent.bounds) rescue nil) }
        unless bb.empty?
          kv.transformation = Geom::Transformation.translation(
            Geom::Vector3d.new(bb.max.x + 2.m, bb.min.y, bb.min.z)
          )
        end
        kv
      end

      # ── Cena KV (projeção paralela, enquadrando o quadro) ───────────────────

      def self.make_scene(model, kv)
        view   = model.active_view
        gb     = kv.bounds
        center = gb.center
        dist   = [gb.width, gb.height, gb.depth].max * 2 + 5.m
        eye    = Geom::Point3d.new(center.x, gb.max.y + dist, center.z)
        cam    = Sketchup::Camera.new(eye, center, Geom::Vector3d.new(0, 0, 1))
        cam.perspective = false
        view.camera = cam
        view.zoom(kv)

        old = model.pages[KV_SCENE]
        model.pages.erase(old) if old
        model.pages.add(KV_SCENE)
      rescue => e
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
        v = vec.clone
        v = v.transform(tr)
        v.to_a
      end

    end
  end
end
