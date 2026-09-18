# encoding: UTF-8
# exporter.rb — Exportação de Scenes para PNG (render IA ou apresentação/plantas)

require 'tmpdir'

module STAND1
  module EVA

    module Exporter

      # config esperado (vindo do HTML via JSON):
      # {
      #   mode:       "render" | "presentation",
      #   scenes:     ["Scene 1", "Scene 3"],
      #   folder:     "C:/caminho/destino",
      #   resolution: { width: 3840, height: 2160 },
      #   style:      "flat" | "textured",          # só usado no modo render
      #   background: "black" | "white" | "transparent"
      # }
      #
      # MODO render        → sobrescreve estilo + fundo, desativa sombras, oculta
      #                      eixos e tags de anotação. Insumo para a IA.
      # MODO presentation  → exporta a cena COMO ESTÁ (estilo/sombras da própria
      #                      cena), aplicando apenas o fundo escolhido e a resolução.

      def self.run(config)
        model = Sketchup.active_model
        view  = model.active_view
        ro    = model.rendering_options

        mode           = (config[:mode] || 'render').to_s
        selected_names = config[:scenes] || []
        folder         = config[:folder].to_s
        resolution     = config[:resolution] || { width: 3840, height: 2160 }
        style_mode     = config[:style]      || 'flat'
        bg_mode        = config[:background] || 'black'

        return { ok: false, error: 'Nenhuma cena selecionada.' }     if selected_names.empty?
        return { ok: false, error: 'Pasta de destino não definida.' } if folder.empty?
        return { ok: false, error: 'Pasta de destino não existe.' }   unless File.directory?(folder)

        pages = model.pages.select { |p| selected_names.include?(p.name) }
        return { ok: false, error: 'Nenhuma cena encontrada no modelo.' } if pages.empty?

        saved = snapshot_settings(model, view, ro)

        exported = []
        failed   = []

        pages.each do |page|
          begin
            model.pages.selected_page = page
            # A transição animada entre cenas está desligada no snapshot, mas a
            # câmera da página é reaplicada direto para o enquadramento ser o da
            # cena, e não um estado intermediário do movimento.
            aplicar_camera(view, page) if page.use_camera?
            apply_settings(model, ro, mode, style_mode, bg_mode)

            safe_name = page.name.gsub(/[\\\/:\*\?"<>\|]/, '_')
            path      = File.join(folder, "#{safe_name}.png")

            larg_pedida  = resolution[:width] || 3840
            out_w, out_h = frame_content(view, larg_pedida) ||
                           fit_resolution(view, larg_pedida, resolution[:height] || 2160)

            opts = {
              filename:    path,
              width:       out_w,
              height:      out_h,
              antialias:   true,
              transparent: (bg_mode == 'transparent')
            }

            view.write_image(opts)
            if config[:crops]
              # crops é um Hash com chaves string (nome da cena)
              scene_crop = config[:crops].is_a?(Hash) ? config[:crops][page.name] : nil
              crop_png(path, scene_crop) if scene_crop
            end
            exported << page.name
          rescue => e
            failed << { name: page.name, error: e.message }
          end
        end

        restore_settings(model, ro, saved)

        { ok: true, exported: exported, failed: failed, folder: folder }
      end

      MAX_LADO = 8192
      MARGEM   = 0.04   # folga em volta do conteúdo, em fração do próprio conteúdo

      # Resolução de saída com a proporção do enquadramento da vista.
      #
      # O SketchUp preserva a ALTURA enquadrada pela câmera e estica a largura
      # até a proporção pedida. Pedir 16:9 num viewport de outra proporção faz
      # entrar conteúdo lateral que a cena não mostra.
      def self.fit_resolution(view, width, height)
        w  = width.to_i
        vw = view.vpwidth.to_i
        vh = view.vpheight.to_i
        return limitar(w, height.to_i > 0 ? height.to_i : (w * 9 / 16)) if vw <= 0 || vh <= 0

        limitar(w, (w * vh.to_f / vw).round)
      end

      # Cópia independente de uma câmera: o enquadramento é ajustado sobre ela e
      # nunca sobre a câmera guardada na página — exportar não pode alterar a
      # cena, e guardar a câmera da view para restaurar depois exige uma cópia.
      def self.clonar_camera(c)
        nova = Sketchup::Camera.new(c.eye, c.target, c.up, c.perspective?, c.fov)
        (nova.height = c.height) rescue nil unless c.perspective?
        nova
      rescue
        c
      end

      def self.aplicar_camera(view, page)
        view.camera = clonar_camera(page.camera)
      rescue
        (view.camera = page.camera) rescue nil
      end

      def self.limitar(w, h)
        h = 1 if h < 1
        if h > MAX_LADO
          w = (w * MAX_LADO.to_f / h).round
          h = MAX_LADO
        end
        [w, h]
      end

      # Enquadramento calculado a partir do conteúdo — não do viewport.
      #
      # O viewport que o SketchUp informa inclui a faixa coberta pela bandeja
      # padrão: a cena que você centraliza na área visível tem, para o SketchUp,
      # a câmera deslocada, e o PNG sai com o modelo fora do centro e com sobra
      # do lado da bandeja. Aqui a câmera é centralizada no conteúdo visível e,
      # em vista paralela (plantas, elevações, isométricas), o zoom é ajustado
      # para preenchê-la com margem uniforme — o resultado não depende do
      # tamanho da janela nem das bandejas abertas.
      #
      # Em perspectiva só a centralização é aplicada: mexer no zoom mudaria a
      # lente e a composição da cena.
      #
      # Devolve [largura, altura] da imagem, ou nil se não houver o que enquadrar.
      def self.frame_content(view, width)
        bb = visible_bounds(view.model)
        return nil unless bb && !bb.empty? && bb.diagonal > 0
        enquadrar(view, bb, width)
      end

      def self.enquadrar(view, bb, width)
        cam = view.camera
        larg, alt, cu, cv = extensao_na_camera(bb, cam)
        return nil if larg <= 0 || alt <= 0

        centralizar(cam, cu, cv)

        return fit_resolution(view, width, nil) if cam.perspective?

        # Paralela: a altura da câmera define o enquadramento. A folga é a mesma
        # nos dois eixos e a imagem sai na proporção do conteúdo mais a folga,
        # então a margem fica igual nos quatro lados.
        folga     = MARGEM * [larg, alt].max
        larg_tot  = larg + 2 * folga
        alt_tot   = alt  + 2 * folga
        cam.height = alt_tot
        limitar(width.to_i, (width.to_i * alt_tot / larg_tot).round)
      end

      # Bounding box do que está visível: entidades ocultas e tags desligadas
      # ficam de fora para não empurrarem o enquadramento.
      def self.visible_bounds(model)
        bb = Geom::BoundingBox.new
        model.entities.each do |e|
          next if e.respond_to?(:hidden?) && e.hidden?
          next if e.respond_to?(:layer) && e.layer && !e.layer.visible?
          bb.add(e.bounds) rescue nil
        end
        bb
      end

      # Extensão do bbox no plano da câmera e o quanto seu centro está fora do
      # centro do quadro: [largura, altura, desvio_horizontal, desvio_vertical].
      def self.extensao_na_camera(bb, cam)
        xa = cam.xaxis
        ya = cam.yaxis
        us = []
        vs = []
        8.times do |i|
          d = bb.corner(i) - cam.eye
          us << d.dot(xa)
          vs << d.dot(ya)
        end
        [us.max - us.min, vs.max - vs.min,
         (us.min + us.max) / 2.0, (vs.min + vs.max) / 2.0]
      end

      # Desloca a câmera no seu próprio plano (pan), sem girar nem aproximar.
      def self.centralizar(cam, cu, cv)
        return if cu.abs < 1e-6 && cv.abs < 1e-6
        alt_atual = (cam.height rescue nil)
        d = Geom::Vector3d.new(cam.xaxis.to_a.map { |c| c * cu })
        d = d + Geom::Vector3d.new(cam.yaxis.to_a.map { |c| c * cv })
        cam.set(cam.eye.offset(d), cam.target.offset(d), cam.up)
        # cam.set recalcula a altura da câmera paralela: repõe a que havia.
        (cam.height = alt_atual) rescue nil if alt_atual && !cam.perspective?
      end

      # Recorta o PNG exportado usando System.Drawing via PowerShell.
      # crop: { left:, top:, right:, bottom: } — percentual de cada borda a remover.
      def self.crop_png(path, crop)
        l = (crop[:left]   || crop['left']   || 0).to_f
        r = (crop[:right]  || crop['right']  || 0).to_f
        t = (crop[:top]    || crop['top']    || 0).to_f
        b = (crop[:bottom] || crop['bottom'] || 0).to_f
        return if l + r >= 100 || t + b >= 100
        return if [l, r, t, b].all? { |v| v == 0 }

        safe = path.gsub("'", "''")
        ps = <<~PS
          Add-Type -AssemblyName System.Drawing
          $orig = '#{safe}'
          $tmp  = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.png')
          $src  = [System.Drawing.Bitmap]::FromFile($orig)
          $w = $src.Width; $h = $src.Height
          $x  = [int]($w * #{l} / 100.0)
          $y  = [int]($h * #{t} / 100.0)
          $cw = $w - $x - [int]($w * #{r} / 100.0)
          $ch = $h - $y - [int]($h * #{b} / 100.0)
          if ($cw -gt 0 -and $ch -gt 0) {
            $rect = [System.Drawing.Rectangle]::new($x, $y, $cw, $ch)
            $dst  = $src.Clone($rect, $src.PixelFormat)
            $src.Dispose()
            $dst.Save($tmp)
            $dst.Dispose()
            [System.IO.File]::Copy($tmp, $orig, $true)
            [System.IO.File]::Delete($tmp)
          } else { $src.Dispose() }
        PS

        tmp_ps = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_crop_#{Process.pid}.ps1")
        File.write(tmp_ps, ps, encoding: 'UTF-8')
        system("powershell -NonInteractive -ExecutionPolicy Bypass -File \"#{tmp_ps}\"")
        File.delete(tmp_ps) rescue nil
      rescue => e
        # Crop falhou — mantém o PNG original sem erro
      end

      # Acesso tolerante a rendering_options: opções inexistentes nesta versão do
      # SketchUp são ignoradas em vez de derrubar o export inteiro.
      def self.safe_get(ro, key)
        ro[key]
      rescue
        nil
      end

      def self.safe_set(ro, key, value)
        ro[key] = value
      rescue
        # opção não suportada nesta versão — ignora
      end

      # ── Captura estado atual (para restaurar fielmente) ─────────────────────
      # Também desliga a transição entre cenas: restaurada em restore_settings.

      def self.snapshot_settings(model, view, ro)
        layer_vis = {}
        model.layers.each { |l| layer_vis[l.persistent_id] = l.visible? }

        # Transição animada entre cenas: com ela ligada, o write_image logo após
        # trocar de página captura um frame no meio do movimento.
        po = (model.options['PageOptions'] rescue nil)
        transition = nil
        if po
          transition = { show: (po['ShowTransition'] rescue nil),
                         time: (po['TransitionTime'] rescue nil) }
          (po['ShowTransition'] = false) rescue nil
          (po['TransitionTime'] = 0)     rescue nil
        end

        {
          camera:      clonar_camera(view.camera),
          transition:  transition,
          page:        model.pages.selected_page,
          shadows:     (model.shadow_info['DisplayShadows'] rescue nil),
          sky:         safe_get(ro, 'DisplaySky'),
          ground:      safe_get(ro, 'DisplayGround'),
          background:  safe_get(ro, 'BackgroundColor'),
          render_mode: safe_get(ro, 'RenderMode'),
          texture_on:  safe_get(ro, 'Textures'),
          color_layer: safe_get(ro, 'DisplayColorByLayer'),
          layer_vis:   layer_vis,
        }
      end

      # ── Aplica configurações conforme o modo ────────────────────────────────

      def self.apply_settings(model, ro, mode, style_mode, bg_mode)
        # Fundo (comum aos dois modos)
        safe_set(ro, 'DisplaySky', false)
        safe_set(ro, 'DisplayGround', false)
        case bg_mode
        when 'white'
          safe_set(ro, 'BackgroundColor', Sketchup::Color.new(255, 255, 255))
        when 'transparent'
          # tratado em write_image (transparent: true)
        else # black
          safe_set(ro, 'BackgroundColor', Sketchup::Color.new(0, 0, 0))
        end

        return unless mode == 'render'

        # ── Específico do modo RENDER ──
        (model.shadow_info['DisplayShadows'] = false) rescue nil

        # Oculta tags de anotação (nome contém annotation/texto/cota/tag)
        model.layers.each do |layer|
          n = layer.name.downcase
          if n.include?('annotation') || n.include?('texto') ||
             n.include?('cota') || n.include?('tag')
            layer.visible = false rescue nil
          end
        end

        case style_mode
        when 'flat'
          # Hidden Line: faces sólidas (cor do papel) + arestas, sem textura/sombra.
          safe_set(ro, 'RenderMode', 1)
          safe_set(ro, 'Textures', false)
          safe_set(ro, 'DisplayColorByLayer', false)
        when 'textured'
          # Shaded with Textures: mostra os materiais aplicados.
          safe_set(ro, 'RenderMode', 3)
          safe_set(ro, 'Textures', true)
          safe_set(ro, 'DisplayColorByLayer', false)
        end
      end

      # ── Restaura estado original (só o que foi alterado) ────────────────────

      def self.restore_settings(model, ro, saved)
        (model.shadow_info['DisplayShadows'] = saved[:shadows]) rescue nil unless saved[:shadows].nil?
        safe_set(ro, 'DisplaySky',          saved[:sky])         unless saved[:sky].nil?
        safe_set(ro, 'DisplayGround',       saved[:ground])      unless saved[:ground].nil?
        safe_set(ro, 'BackgroundColor',     saved[:background])  unless saved[:background].nil?
        safe_set(ro, 'RenderMode',          saved[:render_mode]) unless saved[:render_mode].nil?
        safe_set(ro, 'Textures',            saved[:texture_on])  unless saved[:texture_on].nil?
        safe_set(ro, 'DisplayColorByLayer', saved[:color_layer]) unless saved[:color_layer].nil?

        # Restaura visibilidade de cada tag ao estado original
        model.layers.each do |l|
          v = saved[:layer_vis][l.persistent_id]
          l.visible = v unless v.nil? || l.visible? == v
        end

        model.pages.selected_page = saved[:page] if saved[:page]
        (model.active_view.camera = saved[:camera]) rescue nil if saved[:camera]

        if saved[:transition]
          po = (model.options['PageOptions'] rescue nil)
          if po
            (po['ShowTransition'] = saved[:transition][:show]) rescue nil unless saved[:transition][:show].nil?
            (po['TransitionTime'] = saved[:transition][:time]) rescue nil unless saved[:transition][:time].nil?
          end
        end
      end

    end

  end
end
