# encoding: UTF-8
# prompt_builder.rb — monta o prompt de render (Nano Banana) a partir de blocos fixos
# curtos + os ajustes do usuário.
#
# A câmera e a geometria vêm do PNG anexado, então o texto NÃO descreve ângulo nem o
# estande. Ele só diz o que a imagem não sabe: ambiente, luz, pessoas e as
# substituições de material/elemento (gerais e por cena).

require 'set'

module STAND1
  module EVA

    module PromptBuilder

      # ── Blocos fixos (iguais em todo prompt; todo estande é interno) ─────────
      # Prompt externo é feito à parte, fora do plugin.

      BASE = 'Imagem foto-realística interna de stand em pavilhão tecnológico de feiras, ' \
             'teto em grid metálico preto e luminárias LED, sem estruturas aéreas, ' \
             'sem alterar a geometria.'.freeze

      LIGHT = 'Luz geral do pavilhão em branco %s.'.freeze

      LIGHT_TONE = { 'frio' => 'frio', 'quente' => 'quente' }.freeze

      PEOPLE = 'Adicionar pessoas foto-realísticas circulando.'.freeze

      # ── Frases ───────────────────────────────────────────────────────────────

      # Texto do usuário limpo: espaços colapsados, sem ponto final solto.
      def self.clean(txt)
        safe_utf8(txt).gsub(/\s+/, ' ').sub(/[.\s]+\z/, '').strip
      end

      # Vira frase: 1ª letra maiúscula e ponto final.
      def self.sentence(txt)
        t = clean(txt)
        return nil if t.empty?
        t[0].upcase + t[1..-1].to_s + '.'
      end

      # { 'de' => elemento no modelo, 'para' => como deve ficar }.
      #   de + para  => "Substituir <de> por <para>."
      #   só para    => "<para>."  (frase livre: "O painel branco tem contorno LED")
      #   sem para   => ignorado
      def self.substitution_sentence(item)
        return nil unless item.is_a?(Hash)
        de   = clean(item['de']   || item[:de])
        para = clean(item['para'] || item[:para])
        return nil if para.empty?
        de.empty? ? sentence(para) : sentence("Substituir #{de} por #{para}")
      end

      # ── Monta o prompt de UMA cena ───────────────────────────────────────────
      #
      # Ordem: base → luz → [pessoas] → ajustes gerais → ajustes da cena.
      #
      # opts:
      #   lighting => 'frio' | 'quente'
      #   people   => true | false   (padrão true)
      #   general  => array de textos (ajustes de TODAS as cenas do projeto)
      #   subs     => array de { 'de', 'para' } (ajustes desta cena)

      def self.build(opts)
        tone   = LIGHT_TONE[opts[:lighting].to_s] || 'frio'
        people = opts[:people].nil? ? true : !!opts[:people]

        parts = [BASE, format(LIGHT, tone)]
        parts << PEOPLE if people
        (opts[:general] || []).each { |l| s = sentence(l); parts << s if s }
        (opts[:subs]    || []).each { |i| s = substitution_sentence(i); parts << s if s }

        safe_utf8(parts.join(' '))
      end

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

      # Garante UTF-8 válido (nomes de material no Windows costumam vir em Latin-1/
      # ASCII-8BIT; sem isso o to_json lança JSON::GeneratorError e a UI trava).
      def self.safe_utf8(str)
        str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      rescue
        str.to_s.force_encoding('UTF-8').scrub('')
      end

      # ── Monta prompts para várias Scenes ─────────────────────────────────────
      # shared_opts[:scene_subs] => { nome_da_cena => [ {de, para}, ... ] }

      def self.build_all(model, scene_names, shared_opts)
        pages = model.pages.select { |p| scene_names.include?(p.name) }
        pages.map do |page|
          subs = (shared_opts[:scene_subs] || {})[page.name] || []
          { scene: safe_utf8(page.name), prompt: build(shared_opts.merge(subs: subs)) }
        end
      end

    end

  end
end
