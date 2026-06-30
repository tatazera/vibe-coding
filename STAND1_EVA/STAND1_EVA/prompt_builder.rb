# encoding: UTF-8
# prompt_builder.rb — Fase 2: leitura de câmera/materiais e montagem do prompt

require 'set'

module STAND1
  module EVA

    module PromptBuilder

      # ── Descrição fixa do estande (independe do ambiente) ────────────────────

      INTRO = <<~TXT.strip
        Contemporary exhibition booth with clean and contemporary architectural language, \
        precise geometries, balanced proportions and refined details. The structure rigorously \
        preserves the exact materials and geometry of the original reference image, without \
        alterations or substitutions.
      TXT

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

      CRITICALS_FIXED = [
        'DO NOT ADD SUSPENDED BOXTRUSS STRUCTURES.',
        'PRESERVE EXACT GEOMETRY AND PROPORTIONS OF THE ORIGINAL PROJECT.',
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

      # ── Converte câmera de uma Scene em descrição fotográfica ────────────────

      # Converte a câmera da cena em descrição fotográfica. Detecta:
      #   - projeção: perspectiva / isométrica (paralela) / planta / elevação
      #   - orientação horizontal: frontal / três-quartos / lateral / traseira
      #     (relativa à FRENTE do modelo = eixo -Y / "Front" padrão do SketchUp)
      #   - altura da câmera e FOV
      def self.camera_description(page)
        cam = (page.respond_to?(:camera) && page.camera) ? page.camera : nil
        return 'Three-quarter eye-level perspective view of the booth.' unless cam

        eye    = cam.eye
        target = cam.target
        dir    = target - eye

        height_m = (eye.z.to_f * 0.0254).round(2)

        # Pitch: inclinação vertical do olhar
        horiz = Math.sqrt(dir.x.to_f**2 + dir.y.to_f**2)
        pitch = horiz.zero? ? (dir.z.to_f >= 0 ? 90.0 : -90.0) :
                              Math.atan2(dir.z.to_f, horiz) * 180.0 / Math::PI

        # Azimute da câmera relativo à frente (-Y): 0 = frontal, + = direita
        to_cam = eye - target
        az = Math.atan2(to_cam.x.to_f, -to_cam.y.to_f) * 180.0 / Math::PI

        perspective = cam.perspective?
        plan_view   = pitch <= -75   # olhando quase reto para baixo

        view_type =
          if !perspective && plan_view          then 'Top-down orthographic plan view'
          elsif !perspective && pitch.abs < 15  then 'Orthographic front elevation view'
          elsif !perspective                    then 'Isometric axonometric view'
          elsif plan_view                       then 'High-angle aerial perspective view'
          else                                       'Perspective view'
          end

        # Orientação horizontal (não se aplica a planta pura)
        orient =
          if plan_view
            nil
          else
            a    = az.abs
            side = az >= 0 ? 'right' : 'left'
            if a < 22.5      then 'seen from the front'
            elsif a < 67.5   then "seen at three-quarter angle from the front-#{side}"
            elsif a < 112.5  then "seen from the #{side} side"
            elsif a < 157.5  then "seen at three-quarter angle from the rear-#{side}"
            else                  'seen from the rear'
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
      #   environment   => 'feira' | 'neutro_claro' | 'neutro_cinza' | 'neutro_escuro'
      #   criticals_pt  => array de strings em PT inseridas pelo usuário
      #   lang          => 'en' | 'pt'

      def self.build(opts)
        page         = opts[:page]
        lighting_key = opts[:lighting]     || 'frio'
        env_key      = opts[:environment]  || 'feira'
        booth_key    = opts[:booth_type]   || 'ilha'
        criticals_pt = opts[:criticals_pt] || []
        description  = opts[:description].to_s.strip   # âncora, igual em todos os ângulos

        light_en   = LIGHTING[lighting_key] || 'cold white'
        env        = ENVIRONMENTS[env_key]  || ENVIRONMENTS['feira']
        booth_line = BOOTH_TYPES[booth_key] || BOOTH_TYPES['ilha']

        # Pessoas: toggle explícito; se não vier (nil), segue o padrão do ambiente.
        people = opts[:people].nil? ? env[:people] : opts[:people]

        # Descrição do ângulo (lida da câmera da cena)
        angle = page ? camera_description(page) : 'Three-quarter eye-level view of the booth.'

        lighting_block = "Integrated architectural lighting is a key element: #{light_en} " \
          "artificial lighting creates a dramatic atmosphere with strong contrast and sculpted shadows, " \
          "creating a sharp luminous outline that enhances the volumetry."

        # CRITICALs (fixos + pessoas, se houver + usuário traduzidos)
        user_criticals = criticals_pt.reject { |c| c.strip.empty? }.map do |c|
          Dictionary.translate(c).upcase
        end
        all_criticals = CRITICALS_FIXED.dup
        all_criticals << PEOPLE_CRITICAL if people
        all_criticals += user_criticals
        criticals = all_criticals.map { |c| "CRITICAL: #{c}" }

        blocks = []
        blocks << angle
        blocks << INTRO
        blocks << description unless description.empty?
        blocks << booth_line
        blocks << env[:env]
        blocks << PEOPLE if people
        blocks << lighting_block
        blocks << CAMERA_TECH
        blocks << criticals.join("\n")

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
        pages = model.pages.select { |p| scene_names.include?(p.name) }
        pages.map do |page|
          {
            scene:  safe_utf8(page.name),
            prompt: build(shared_opts.merge(page: page))
          }
        end
      end

    end

  end
end
