# =============================================================================
# Stand1 Memorial — dimensoes.rb
# Módulo puro de cálculo de dimensões (sem dependência do SketchUp).
# Testável fora do SketchUp: ruby tests/test_dimensoes.rb
# =============================================================================

module STAND1_Memorial
  module Dimensoes

    POLEGADA_PARA_METRO = 0.0254

    def self.metro(pol)
      (pol.to_f * POLEGADA_PARA_METRO).round(2)
    end

    # Núcleo da correção de dimensões.
    #
    # eixos:       [[x],[y],[z]] — colunas da matriz de transformação composta
    #              (mundo), COM escala embutida (não normalizadas)
    # dims_locais: [dx, dy, dz] — extensão do definition.bounds em cada eixo local
    #
    # Retorna { largura:, profund:, altura: } nas MESMAS unidades de dims_locais.
    #
    # Regras:
    # - Dimensão real por eixo = extensão local × norma do eixo (acumula escala
    #   de pais, ignora rotação — dimensões da peça, não da caixa do mundo)
    # - Altura = dimensão do eixo local mais alinhado ao Z do mundo (decisão 2A);
    #   empate → menor dimensão (decisão do desempate)
    # - Espelhamento (escala negativa) → valor absoluto (decisão 3)
    # - Largura = maior das 2 restantes; profundidade = menor (regra universal)
    def self.calcular(eixos, dims_locais)
      reais = []
      verts = []
      3.times do |i|
        v = eixos[i]
        norma = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
        if norma < 1e-9
          reais << 0.0
          verts << 0.0
        else
          reais << (dims_locais[i] * norma).abs
          verts << (v[2] / norma).abs
        end
      end

      max_v      = verts.max
      candidatos = (0..2).select { |i| (verts[i] - max_v).abs < 1e-6 }
      idx_alt    = candidatos.min_by { |i| reais[i] }

      altura = reais[idx_alt]
      horiz  = ((0..2).to_a - [idx_alt]).map { |i| reais[i] }

      { largura: horiz.max, profund: horiz.min, altura: altura }
    end

    # Regra 7B — M linear: maior × segunda maior dimensão, em qualquer eixo.
    # Coluna em pé (0.3 × 0.3 × 2.5) → [2.5, 0.3]; viga deitada (3.0 × 0.15 × 0.15) → [3.0, 0.15]
    def self.dims_lineares(l, p, a)
      tres = [l, p, a].sort.reverse
      [tres[0], tres[1]]
    end

    # Chave de agrupamento: dims ordenadas (d1≥d2≥d3) — mesma peça em qualquer
    # orientação ou espelhada gera a mesma chave.
    def self.chave_dims(l, p, a)
      d = [l, p, a].sort.reverse
      "#{d[0]}__#{d[1]}__#{d[2]}"
    end

  end
end
