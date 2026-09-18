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

      # O export corre em passos — uma cena por chamada de `passo` — para o
      # diálogo continuar respondendo e o status andar junto com os arquivos.
      # `preparar` valida e guarda o estado, `passo` grava um PNG, `finalizar`
      # devolve o modelo ao estado original.

      def self.preparar(config)
        model = Sketchup.active_model
        view  = model.active_view
        ro    = model.rendering_options

        selected_names = config[:scenes] || []
        folder         = config[:folder].to_s

        return { ok: false, error: 'Nenhuma cena selecionada.' }      if selected_names.empty?
        return { ok: false, error: 'Pasta de destino não definida.' } if folder.empty?
        return { ok: false, error: 'Pasta de destino não existe.' }   unless File.directory?(folder)

        pages = model.pages.select { |p| selected_names.include?(p.name) }
        return { ok: false, error: 'Nenhuma cena encontrada no modelo.' } if pages.empty?

        @sessao = {
          model:      model,
          view:       view,
          ro:         ro,
          pages:      pages,
          folder:     folder,
          mode:       (config[:mode] || 'render').to_s,
          style:      config[:style]      || 'flat',
          bg:         config[:background] || 'black',
          resolution: config[:resolution] || { width: 3840, height: 2160 },
          replace:    config[:replace],
          saved:      snapshot_settings(model, view, ro),
          exported:   [],
          failed:     [],
          i:          0
        }
        { ok: true, total: pages.length }
      end

      def self.passo
        s = @sessao
        return { fim: true } unless s
        page = s[:pages][s[:i]]
        return { fim: true } unless page

        erro = nil
        begin
          s[:model].pages.selected_page = page
          # A transição animada entre cenas está desligada no snapshot, mas a
          # câmera da página é reaplicada direto para o enquadramento ser o da
          # cena, e não um estado intermediário do movimento.
          aplicar_camera(s[:view], page) if page.use_camera?
          apply_settings(s[:model], s[:ro], s[:mode], s[:style], s[:bg])

          path = caminho_saida(s, page)

          larg         = s[:resolution][:width] || 3840
          out_w, out_h = fit_resolution(s[:view], larg, s[:resolution][:height] || 2160)

          s[:view].write_image(filename:    path,
                               width:       out_w,
                               height:      out_h,
                               antialias:   true,
                               transparent: (s[:bg] == 'transparent'))
          s[:exported] << page.name
        rescue => e
          erro = e.message
          s[:failed] << { name: page.name, error: e.message }
        end

        s[:i] += 1
        { fim: false, feito: s[:i], total: s[:pages].length, nome: page.name, erro: erro }
      end

      def self.finalizar
        s = @sessao
        return { ok: false, error: 'Nenhum export em andamento.' } unless s
        restore_settings(s[:model], s[:ro], s[:saved])
        @sessao = nil
        { ok: true, exported: s[:exported], failed: s[:failed], folder: s[:folder] }
      end

      # Com uma cena só e um arquivo escolhido para substituir, grava por cima
      # dele (o formato segue a extensão: .jpg sai JPEG). Com várias cenas cada
      # uma grava com o próprio nome — um arquivo só não comporta várias cenas.
      def self.caminho_saida(s, page)
        alvo = s[:replace].to_s
        if !alvo.empty? && s[:pages].length == 1
          return File.join(s[:folder], File.basename(alvo))
        end
        safe_name = page.name.gsub(/[\\\/:\*\?"<>\|]/, '_')
        File.join(s[:folder], "#{safe_name}.png")
      end

      MAX_LADO = 8192

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

        if saved[:page]
          model.pages.selected_page = saved[:page]
        else
          # Não havia cena ativa: sai sem nenhuma selecionada, senão o modelo
          # fica parado na última cena exportada.
          (model.pages.selected_page = nil) rescue nil
        end
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
