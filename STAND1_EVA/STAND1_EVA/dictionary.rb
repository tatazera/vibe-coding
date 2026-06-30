# encoding: UTF-8
# dictionary.rb — Dicionário PT→EN para prompts de render (Nano Banana 2)

module STAND1
  module EVA
    module Dictionary

    DICTIONARY = {

      # ─── REVESTIMENTOS ──────────────────────────────────────────────────────
      "napa branca"               => "matte white synthetic leather",
      "napa preta"                => "matte black synthetic leather",
      "napa cinza"                => "grey synthetic leather",
      "napa amadeirada"           => "wood-effect synthetic leather",
      "napa amarela"              => "yellow synthetic leather",
      "napa laranja"              => "orange synthetic leather",
      "napa vermelha"             => "red synthetic leather",
      "napa azul"                 => "blue synthetic leather",
      "napa verde"                => "green synthetic leather",
      "napa colorida"             => "colored synthetic leather",
      "lona impressa"             => "printed vinyl banner",
      "lona impressa com arte"    => "printed vinyl banner with custom artwork",
      "vinilico amadeirado"       => "wood-effect vinyl flooring",
      "piso vinilico amadeirado"  => "wood-effect vinyl flooring",
      "carpete"                   => "carpet flooring",
      "carpete amarelo"           => "yellow carpet flooring",
      "carpete laranja"           => "orange carpet flooring",
      "carpete vermelho"          => "red carpet flooring",
      "carpete cinza"             => "grey carpet flooring",
      "mdf pintado branco"        => "matte white painted MDF",
      "mdf pintado preto"         => "matte black painted MDF",
      "mdf pintado"               => "painted MDF panel",
      "vidro"                     => "glass",
      "acrilico"                  => "acrylic panel",
      "metalon pintado"           => "painted steel tube",

      # ─── ESTRUTURA ──────────────────────────────────────────────────────────
      "testeira"                  => "fascia",
      "testeira fachada"          => "main fascia",
      "sanca"                     => "coving",
      "coluna"                    => "column",
      "coluna diagonal"           => "diagonal column",
      "piso elevado"              => "raised floor platform",
      "estrutura metalica"        => "metal structure",
      "ripas"                     => "slats",
      "ripas coloridas"           => "colored decorative slats",
      "painel de vidro"           => "glass panel",
      "backdrop"                  => "backdrop panel",
      "painel triangular"         => "triangular panel",
      "fechamento lateral"        => "lateral enclosure panel",
      "sala de reuniao"           => "meeting room enclosure",
      "jardineira"                => "planter box",

      # ─── COMUNICAÇÃO VISUAL ─────────────────────────────────────────────────
      "logo retroiluminado"       => "backlit logo sign",
      "logo em pvc"               => "PVC logo sign",
      "logo pvc"                  => "PVC logo sign",
      "painel led"                => "LED video wall panel",
      "tv"                        => "smart TV screen",
      "tv touch"                  => "touch screen display",
      "painel grafico"            => "printed graphic panel",

      # ─── ILUMINAÇÃO ─────────────────────────────────────────────────────────
      "fita led branco quente"    => "warm white COB LED strip light",
      "fita led branco frio"      => "cold white COB LED strip light",
      "fita led laranja"          => "orange LED strip light",
      "fita led azul"             => "blue LED strip light",
      "fita led"                  => "LED strip light",
      "dicroica led"              => "LED spotlight",
      "refletor led"              => "LED floodlight",
      "backlit"                   => "backlit illuminated panel",

      # ─── MOBILIÁRIO ─────────────────────────────────────────────────────────
      "balcao"                    => "reception counter",
      "balcao em aluminio"        => "aluminum reception counter",
      "balcao mdf"                => "MDF reception counter",
      "bancada"                   => "workbench counter",
      "mesa bistro"               => "bistro table",
      "mesa de reuniao"           => "meeting table",
      "banqueta alta"             => "high stool",
      "cadeira reuniao"           => "meeting chair",
      "nicho mdf"                 => "MDF product display niche",
      "expositor"                 => "product display shelf",
      "estante"                   => "shelving unit",
      "cachepot"                  => "decorative plant pot",
      "plantas naturais"          => "natural plants",
      "plantas artificiais"       => "artificial plants",

    }.freeze

    def self.translate(term_pt)
      key = normalize(term_pt)
      DICTIONARY[key] || term_pt
    end

    def self.translate_list(terms_array)
      terms_array.map { |t| { original: t, translated: translate(t) } }
    end

    def self.unmapped(terms_array)
      terms_array.select { |t| translate(t) == t }
    end

    def self.normalize(str)
      str.encode('UTF-8', invalid: :replace, undef: :replace)
         .downcase
         .strip
         .gsub(/[áàãâä]/, 'a')
         .gsub(/[éèêë]/, 'e')
         .gsub(/[íìîï]/, 'i')
         .gsub(/[óòõôö]/, 'o')
         .gsub(/[úùûü]/, 'u')
         .gsub(/[ç]/, 'c')
    end

    end
  end
end
