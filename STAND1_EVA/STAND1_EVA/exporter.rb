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
            apply_settings(model, ro, mode, style_mode, bg_mode)

            safe_name = page.name.gsub(/[\\\/:\*\?"<>\|]/, '_')
            path      = File.join(folder, "#{safe_name}.png")

            opts = {
              filename:    path,
              width:       resolution[:width]  || 3840,
              height:      resolution[:height] || 2160,
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

      def self.snapshot_settings(model, view, ro)
        layer_vis = {}
        model.layers.each { |l| layer_vis[l.persistent_id] = l.visible? }
        {
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
      end

    end

  end
end
