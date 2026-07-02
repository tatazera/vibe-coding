# encoding: UTF-8
# prompt_builder.rb — Fase 2: leitura de câmera/materiais e montagem do prompt

require 'set'

module STAND1
  module EVA

    module PromptBuilder

      # ── Descrição fixa do estande (independe do ambiente) ────────────────────

      # Intro enxuta: só a estética. A obrigação de "preservar o projeto" migrou para a
      # âncora (2º parágrafo) e para o CRITICAL de ancoragem — evita redundância.
      INTRO = <<~TXT.strip
        Contemporary exhibition booth with a clean architectural language, precise geometries, \
        balanced proportions and refined details.
      TXT

      # CRITICAL de ancoragem — reforça a descrição/projeto de referência (ponto forte p/ o modelo).
      ANCHOR_CRITICAL =
        'STRICTLY PRESERVE THE EXACT GEOMETRY, MATERIALS, PROPORTIONS, COLORS AND LAYOUT OF THE ' \
        'ORIGINAL PROJECT AS DESCRIBED AND SHOWN IN THE REFERENCE IMAGE — NO ALTERATIONS, ' \
        'ADDITIONS OR SUBSTITUTIONS.'

      # Bloco de pessoas — REAIS, fotografadas (combate o look de boneco/CGI).
      PEOPLE = <<~TXT.strip
        The people are real human beings captured in a candid street and documentary photograph — \
        genuinely photographed, never rendered, illustrated or computer-generated. Adults of mixed \
        gender, age and ethnicity, with believable body weight and bone structure, relaxed natural \
        muscles, asymmetric real faces and genuine micro-expressions, real skin with natural tone \
        variation, pores, freckles and minor blemishes, messy real hair, and ordinary casual \
        clothing with natural creases, folds and slight wear. They walk, talk, gesture and interact \
        spontaneously and mid-motion, with the imperfect, organic, slightly unposed quality of real \
        life — never stiff, never static, never aligned. Foreground people sharp; more distant \
        people with natural shallow depth of field and subtle motion blur. At least 4 people at \
        varying distances from the camera. They must be indistinguishable from real photographed \
        humans.
      TXT

      # Reforço como CRITICAL quando há público — mira direto no look de boneco/CGI.
      PEOPLE_CRITICAL =
        'PEOPLE MUST LOOK LIKE REAL PHOTOGRAPHED HUMANS WITH NATURAL SKIN, BODY WEIGHT, POSTURE ' \
        'AND GENUINE EXPRESSIONS. THEY ARE NOT 3D-RENDERED OR CGI CHARACTERS, NOT VIDEO-GAME OR ' \
        'POSER/DAZ FIGURES, NOT STIFF ARCHITECTURAL SCALE-FIGURE ENTOURAGE, NOT MANNEQUINS, ' \
        'DOLLS OR WAX FIGURES, AND NEVER PLASTIC OR SHINY.'

      # ── Ambientes selecionáveis (background do render) ───────────────────────
      # :env    => descrição do entorno; :people => inclui figuras humanas?

      # ── Tipo / configuração do estande ───────────────────────────────────────

      BOOTH_TYPES = {
        'ilha'     => 'The booth is configured as an island stand, open and accessible on all four sides.',
        'ponta'    => 'The booth is configured as a peninsula stand, open on three sides with one back wall.',
        'esquina'  => 'The booth is configured as a corner stand, open on two adjacent sides, with solid walls on the other two.',
        'corredor' => 'The booth is configured as an inline booth, open on the front side only, with solid side and back walls.'
      }.freeze

      ENVIRONMENTS = {
        'feira' => {
          people: true,
          env: 'Located in a large industrial international trade fair pavilion, standing out ' \
               'within the circulation flow. The surrounding environment reveals black-painted ' \
               'steel structures supporting the ceiling, exposed ceiling grids and suspended ' \
               'lighting systems, with other booths visible in the background, slightly out of ' \
               'focus but realistic. The pavilion floor is entirely covered in polished concrete.'
        },
        'feira_externa' => {
          people: true,
          env: 'Located in an open-air outdoor trade fair area, an event held outside under the ' \
               'open sky. The booth stands out along the pedestrian circulation flow, with other ' \
               'outdoor booths and event tents visible in the background, slightly out of focus ' \
               'but realistic. Natural daylight with a clear sky and soft clouds, real outdoor ' \
               'context with trees and landscaping in the distance. The ground is covered with ' \
               'outdoor event flooring or paved concrete.'
        },
        'neutro_claro' => {
          people: false,
          env: 'The booth is presented in isolation against a clean, seamless light off-white ' \
               'neutral studio background, with soft, even, diffuse lighting and a smooth subtle ' \
               'gradient. No surrounding structures, no other booths and no environmental context ' \
               '— only the booth on a neutral backdrop, emphasizing its form and materials.'
        },
        'neutro_cinza' => {
          people: false,
          env: 'The booth is presented in isolation against a clean, seamless medium neutral grey ' \
               'studio background, with soft, even, diffuse lighting and a smooth subtle gradient. ' \
               'No surrounding structures, no other booths and no environmental context — only the ' \
               'booth on a neutral backdrop, emphasizing its form and materials.'
        },
        'neutro_escuro' => {
          people: false,
          env: 'The booth is presented in isolation against a clean, seamless dark charcoal ' \
               'neutral studio background, with soft, even, diffuse lighting and a smooth subtle ' \
               'gradient. No surrounding structures, no other booths and no environmental context ' \
               '— only the booth on a neutral backdrop, emphasizing its form and materials.'
        }
      }.freeze

      CAMERA_TECH = <<~TXT.strip
        Photography taken with a Canon EOS R5, 35mm lens, aperture f/2.8, high dynamic range. \
        Ultra-realistic architectural photography. Sharp material definition, defined textures, \
        realistic reflections, precise shadow behavior.
      TXT

      LIGHTING = {
        'frio'   => 'cold white',
        'quente' => 'warm white'
      }.freeze

      # ── Ângulos de câmera para OVERRIDE manual ───────────────────────────────
      # Quando o usuário escolhe um destes por cena, a frase abaixo SUBSTITUI por
      # completo a leitura automática (camera_description). '' ou 'auto' = automático.
      CAMERA_OVERRIDES = {
        'centered'  => 'Perspective eye-level view of the booth, seen centered and head-on to its main facade, camera at approximately 1.6m height.',
        'tq_left'   => 'Perspective eye-level view of the booth, seen at a three-quarter corner angle from the left, camera at approximately 1.6m height.',
        'tq_right'  => 'Perspective eye-level view of the booth, seen at a three-quarter corner angle from the right, camera at approximately 1.6m height.',
        'lateral'   => 'Perspective eye-level view of the booth, seen from the side along its length, camera at approximately 1.6m height.',
        'iso'       => 'Isometric axonometric view of the booth, three-quarter angle showing two adjacent sides.',
        'plan'      => 'Top-down orthographic plan view of the booth, seen directly from above.',
        'aerial'    => 'High-angle aerial perspective view of the booth, looking down at a three-quarter angle.',
        'elevation' => 'Orthographic front elevation view of the booth, head-on and perfectly level.'
      }.freeze

      # A preservação de geometria/proporções ficou no ANCHOR_CRITICAL (evita duplicar).
      CRITICALS_FIXED = [
        'DO NOT ADD SUSPENDED BOXTRUSS STRUCTURES.',
        'DO NOT ADD NEW LOGOS OR GRAPHICS NOT PRESENT IN THE ORIGINAL PROJECT.'
      ].freeze

      # ── Leitura da PALETA do projeto (instantânea) ───────────────────────────
      #
      # Lê `model.materials` direto da memória — a paleta inteira do projeto, sem
      # percorrer geometria nem aplicar cenas. Estável entre todos os ângulos
      # (reforça a consistência, que é o objetivo do plugin). O usuário curadoria
      # a lista no painel de revisão (remove o que não interessa).

      def self.read_palette(model)
        model.materials.map { |m| safe_utf8(m.display_name).strip }
                       .reject(&:empty?)
                       .uniq
                       .sort_by(&:downcase)
      end

      # ── Eixo principal da planta (independente dos eixos do mundo) ───────────
      #
      # O bounding box do SketchUp é sempre alinhado ao mundo, então não revela a
      # orientação real de um estande modelado girado. Calculamos o eixo principal
      # via PCA (análise de componentes principais) dos vértices projetados no plano
      # XY — dá a direção dominante da geometria real, mesmo rotacionada.

      # Coleta pontos XY da geometria (recursivo em grupos/componentes), com teto.
      def self.collect_xy(model, cap = 4000)
        pts = []
        walk = nil
        walk = lambda do |entities, tr|
          entities.each do |e|
            return if pts.size >= cap
            if e.is_a?(Sketchup::Face)
              e.vertices.each do |v|
                p = v.position.transform(tr)
                pts << [p.x.to_f, p.y.to_f]
              end
            elsif e.is_a?(Sketchup::Group)
              walk.call(e.entities, tr * e.transformation)
            elsif e.is_a?(Sketchup::ComponentInstance)
              walk.call(e.definition.entities, tr * e.transformation)
            end
          end
        end
        walk.call(model.entities, Geom::Transformation.new)
        pts
      end

      # Ângulo (radianos) do eixo principal da planta, ou nil se degenerado.
      def self.footprint_axis(model)
        pts = collect_xy(model)
        return nil if pts.size < 3
        n  = pts.size.to_f
        mx = pts.reduce(0.0) { |s, p| s + p[0] } / n
        my = pts.reduce(0.0) { |s, p| s + p[1] } / n
        sxx = sxy = syy = 0.0
        pts.each do |x, y|
          dx = x - mx; dy = y - my
          sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        end
        return nil if sxx.abs < 1e-9 && syy.abs < 1e-9 && sxy.abs < 1e-9
        0.5 * Math.atan2(2 * sxy, sxx - syy)
      end

      # ── Converte câmera de uma Scene em descrição fotográfica ────────────────
      #
      # axis_rad = eixo principal da planta (de footprint_axis). Se presente, a
      # orientação horizontal é medida em relação à geometria REAL do estande
      # (frontal/centralizada x três-quartos de esquina x lateral), independente
      # de como o modelo está girado no mundo. Se nil, cai no eixo -Y do mundo.
      def self.camera_description(page, axis_rad = nil)
        cam = (page.respond_to?(:camera) && page.camera) ? page.camera : nil
        return 'Three-quarter eye-level perspective view of the booth.' unless cam

        eye    = cam.eye
        target = cam.target
        dir    = target - eye

        height_m = (eye.z.to_f * 0.0254).round(2)

        horiz = Math.sqrt(dir.x.to_f**2 + dir.y.to_f**2)
        pitch = horiz.zero? ? (dir.z.to_f >= 0 ? 90.0 : -90.0) :
                              Math.atan2(dir.z.to_f, horiz) * 180.0 / Math::PI

        perspective = cam.perspective?
        plan_view   = pitch <= -75

        view_type =
          if !perspective && plan_view          then 'Top-down orthographic plan view'
          elsif !perspective && pitch.abs < 15  then 'Orthographic elevation view'
          elsif !perspective                    then 'Isometric axonometric view'
          elsif plan_view                       then 'High-angle aerial perspective view'
          else                                       'Perspective view'
          end

        # Orientação horizontal relativa à geometria real (eixo principal da planta).
        orient = nil
        unless plan_view || horiz.zero?
          cam_ang = Math.atan2(dir.y.to_f, dir.x.to_f) * 180.0 / Math::PI
          ref     = axis_rad ? (axis_rad * 180.0 / Math::PI) : -90.0 # -90° = olhar p/ -Y (fallback mundo)
          rel     = cam_ang - ref
          rel -= 360.0 while rel > 180.0
          rel += 360.0 while rel <= -180.0
          # Dobra para o "facade" mais próximo (fachadas a cada 90°): offset em (-45,45].
          k        = (rel / 90.0).round
          face_off = rel - k * 90.0
          a        = face_off.abs
          side     = face_off >= 0 ? 'left' : 'right'
          orient =
            if a < 22.5 then 'seen centered and head-on to one facade'
            else             "seen at a three-quarter corner angle from the #{side}"
            end
        end

        parts = [view_type, 'of the booth']
        parts << orient if orient
        sentence = parts.join(' ')

        extra = []
        extra << "camera at approximately #{height_m}m height" unless plan_view
        extra << "#{cam.fov.round}mm-equivalent field of view" if perspective
        sentence += ', ' + extra.join(', ') unless extra.empty?
        sentence + '.'
      end

      # ── Monta o prompt completo de uma Scene ─────────────────────────────────
      #
      # opts:
      #   page          => Sketchup::Page
      #   lighting      => 'frio' | 'quente'
      #   environment   => 'feira' | 'feira_externa' | 'neutro_claro' | 'neutro_cinza' | 'neutro_escuro'
      #   criticals_pt  => array de strings em PT inseridas pelo usuário
      #   lang          => 'en' | 'pt'

      def self.build(opts)
        page         = opts[:page]
        lighting_key = opts[:lighting]     || 'frio'
        env_key      = opts[:environment]  || 'feira'
        booth_key    = opts[:booth_type]   || 'ilha'
        criticals_pt = opts[:criticals_pt] || []
        description  = opts[:description].to_s.strip   # âncora, igual em todos os ângulos
        axis_rad     = opts[:axis_rad]                 # eixo principal da planta (ou nil)
        cam_override = opts[:camera_override].to_s.strip # ângulo manual por cena ('' = auto)

        light_en   = LIGHTING[lighting_key] || 'cold white'
        env        = ENVIRONMENTS[env_key]  || ENVIRONMENTS['feira']
        booth_line = BOOTH_TYPES[booth_key] || BOOTH_TYPES['ilha']

        # Pessoas: toggle explícito; se não vier (nil), segue o padrão do ambiente.
        people = opts[:people].nil? ? env[:people] : opts[:people]

        # Ângulo: override manual (substitui a leitura automática) OU leitura da
        # câmera da cena relativa à geometria real. Só uma fonte entra no [SCENE].
        angle =
          if CAMERA_OVERRIDES.key?(cam_override)
            CAMERA_OVERRIDES[cam_override]
          elsif page
            camera_description(page, axis_rad)
          else
            'Three-quarter eye-level view of the booth.'
          end

        lighting_block = "Integrated architectural lighting is a key element: #{light_en} " \
          "artificial lighting creates a dramatic atmosphere with strong contrast and sculpted shadows, " \
          "creating a sharp luminous outline that enhances the volumetry."

        # SUBJECT = estética (INTRO) + âncora do projeto (2º parágrafo, alta atenção).
        subject = description.empty? ? INTRO : "#{INTRO} #{description}"

        # CRITICALs: âncora primeiro (reforço), depois fixos, pessoas e os do usuário.
        user_criticals = criticals_pt.reject { |c| c.to_s.strip.empty? }.map do |c|
          Dictionary.translate(c).upcase
        end
        all_criticals = []
        all_criticals << ANCHOR_CRITICAL unless description.empty?
        all_criticals += CRITICALS_FIXED
        all_criticals << PEOPLE_CRITICAL if people
        all_criticals += user_criticals
        criticals = all_criticals.map { |c| "CRITICAL: #{c}" }

        # Blocos rotulados (agrupados) — o modelo interpreta melhor e fica mais enxuto.
        blocks = []
        blocks << "[SCENE]\n#{angle}"
        blocks << "[SUBJECT]\n#{subject}"
        blocks << "[BOOTH TYPE]\n#{booth_line}"
        blocks << "[ENVIRONMENT]\n#{env[:env]}"
        blocks << "[PEOPLE]\n#{PEOPLE}" if people
        blocks << "[LIGHTING]\n#{lighting_block}"
        blocks << "[PHOTOGRAPHY]\n#{CAMERA_TECH}"
        blocks << "[CRITICALS]\n#{criticals.join("\n")}"

        safe_utf8(blocks.join("\n\n"))
      end

      # Garante UTF-8 válido (nomes de material no Windows costumam vir em Latin-1/
      # ASCII-8BIT; sem isso o to_json lança JSON::GeneratorError e a UI trava).
      def self.safe_utf8(str)
        str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      rescue
        str.to_s.force_encoding('UTF-8').scrub('')
      end

      # ── Monta prompts para várias Scenes ─────────────────────────────────────

      def self.build_all(model, scene_names, shared_opts)
        # Eixo principal da planta: calculado UMA vez por modelo (custo amortizado).
        axis_rad = (footprint_axis(model) rescue nil)
        pages = model.pages.select { |p| scene_names.include?(p.name) }
        pages.map do |page|
          # criticals por cena (se vierem no mapa), senão os gerais compartilhados.
          per_scene = shared_opts[:scene_criticals] && shared_opts[:scene_criticals][page.name]
          crit = (shared_opts[:criticals_pt] || []) + (per_scene || [])
          cam  = shared_opts[:scene_cameras] && shared_opts[:scene_cameras][page.name]
          {
            scene:  safe_utf8(page.name),
            prompt: build(shared_opts.merge(page: page, axis_rad: axis_rad, criticals_pt: crit, camera_override: cam))
          }
        end
      end

    end

  end
end
