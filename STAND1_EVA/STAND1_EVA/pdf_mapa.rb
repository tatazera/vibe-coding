# encoding: UTF-8
# =============================================================================
# EVA Stand1 — pdf_mapa.rb
# PDF do Mapa de Artes, escrito em Ruby puro (sem gem nem programa externo):
#   • página 1 (e seguintes, se precisar): RESUMO — todas as peças por ambiente, com
#     medida, material, quantidade, frente e verso e observação (em vermelho);
#   • uma página por ambiente com a prancha 16:9 (imagem JPEG exportada da cena).
# Página 16:9 (960 x 540 pt = 33,9 x 19,1 cm), igual à apresentação.
# Texto em Helvetica (WinAnsi): acentos do português saem certos.
# =============================================================================

require 'zlib'

module STAND1
  module EVA
    module PdfMapa

      PW = 960.0
      PH = 540.0
      MG = 36.0
      PRETO    = [0, 0, 0].freeze
      VERMELHO = [213, 0, 0].freeze
      CINZA    = [120, 120, 120].freeze
      LINHA    = [205, 205, 205].freeze

      # ── Dimensões de um JPEG (marcador SOF) ──────────────────────────────────
      def self.jpeg_info(bin)
        b = bin.b
        raise 'imagem não é JPEG' unless b.getbyte(0) == 0xFF && b.getbyte(1) == 0xD8
        i = 2
        while i < b.bytesize - 9
          i += 1 while b.getbyte(i) != 0xFF && i < b.bytesize
          i += 1 while b.getbyte(i) == 0xFF && i < b.bytesize
          m = b.getbyte(i); i += 1
          next if m == 0xD8 || m == 0x01 || (0xD0..0xD7).cover?(m)
          len = (b.getbyte(i) << 8) | b.getbyte(i + 1)
          if [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].include?(m)
            h = (b.getbyte(i + 3) << 8) | b.getbyte(i + 4)
            w = (b.getbyte(i + 5) << 8) | b.getbyte(i + 6)
            return { w: w, h: h, comp: b.getbyte(i + 7) }
          end
          i += len
        end
        raise 'JPEG sem cabeçalho de tamanho'
      end

      # ── Texto ────────────────────────────────────────────────────────────────
      TROCAS = { '⚠' => '!', '→' => '>', '✓' => 'v', '·' => "·", '–' => "–" }.freeze

      def self.win(s)
        t = s.to_s.dup.force_encoding('UTF-8').scrub('?')
        TROCAS.each { |a, b| t = t.gsub(a, b) }
        t.encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?')
      end

      def self.esc(s)
        win(s).b.gsub(/[\\()]/) { |c| "\\#{c}" }.gsub("\r", '').gsub("\n", ' ')
      end

      # Largura aproximada em Helvetica (pt).
      def self.largura(s, tam, negrito = false)
        w = s.to_s.each_char.sum do |c|
          if c == ' ' then 0.278
          elsif c =~ /[il.,:;'|!]/ then 0.24
          elsif c =~ /[mwMW]/ then 0.86
          elsif c =~ /[A-Z]/ then 0.68
          elsif c =~ /[0-9]/ then 0.556
          else 0.53
          end
        end
        w * tam * (negrito ? 1.07 : 1.0)
      end

      def self.cortar(s, tam, max, negrito = false)
        s = s.to_s
        return s if largura(s, tam, negrito) <= max
        s = s[0...-1] while s.size > 1 && largura(s + '…', tam, negrito) > max
        s + '…'
      end

      # Quebra em linhas que cabem em `max` (para a observação).
      def self.quebrar(s, tam, max, negrito = false)
        linhas = ['']
        s.to_s.split(/\s+/).each do |p|
          tent = linhas.last.empty? ? p : "#{linhas.last} #{p}"
          if largura(tent, tam, negrito) <= max || linhas.last.empty?
            linhas[-1] = tent
          else
            linhas << p
          end
        end
        linhas.map { |l| cortar(l, tam, max, negrito) }
      end

      # ── Página ───────────────────────────────────────────────────────────────
      class Pagina
        attr_reader :ops, :imagens
        def initialize; @ops = []; @imagens = []; end

        def cor(rgb, traco = false)
          r, g, b = rgb.map { |v| format('%.3f', v / 255.0) }
          @ops << "#{r} #{g} #{b} #{traco ? 'RG' : 'rg'}"
        end

        def texto(x, y, s, tam: 10, negrito: false, rgb: PRETO, alinhar: :esq)
          x -= PdfMapa.largura(s, tam, negrito) if alinhar == :dir
          x -= PdfMapa.largura(s, tam, negrito) / 2.0 if alinhar == :centro
          cor(rgb)
          @ops << "BT /#{negrito ? 'F2' : 'F1'} #{format('%.2f', tam)} Tf #{format('%.2f', x)} #{format('%.2f', y)} Td (#{PdfMapa.esc(s)}) Tj ET"
        end

        def linha(x1, y1, x2, y2, rgb: LINHA, esp: 0.6)
          cor(rgb, true)
          @ops << "#{format('%.2f', esp)} w #{format('%.2f', x1)} #{format('%.2f', y1)} m #{format('%.2f', x2)} #{format('%.2f', y2)} l S"
        end

        def retangulo(x, y, w, h, rgb)
          cor(rgb)
          @ops << "#{format('%.2f', x)} #{format('%.2f', y)} #{format('%.2f', w)} #{format('%.2f', h)} re f"
        end

        def imagem(idx, x, y, w, h)
          @imagens << idx
          @ops << "q #{format('%.2f', w)} 0 0 #{format('%.2f', h)} #{format('%.2f', x)} #{format('%.2f', y)} cm /Im#{idx} Do Q"
        end
      end

      # ── Montagem ─────────────────────────────────────────────────────────────
      #
      # dados = {
      #   titulo:, projeto:, rev:, data:,
      #   ambientes: [{ nome:, jpeg: caminho_ou_nil,
      #                 itens: [{ nome:, material:, w:, h: (texto em m), qtd:, fv:, obs:, notas: [texto] }] }]
      # }
      def self.gerar(caminho, dados)
        imgs    = []      # [{bin, w, h, comp}]
        paginas = []
        ambs    = dados[:ambientes] || []
        n_prancha = ambs.count { |a| a[:jpeg] && File.exist?(a[:jpeg]) }

        paginas.concat(paginas_resumo(dados))
        ambs.each do |a|
          next unless a[:jpeg] && File.exist?(a[:jpeg])
          bin  = File.binread(a[:jpeg])
          info = jpeg_info(bin)
          imgs << info.merge(bin: bin)
          paginas << pagina_prancha(a, imgs.size - 1, info, dados)
        end
        n_res = paginas.size - n_prancha
        total = paginas.size
        paginas.each_with_index { |pg, i| rodape(pg, dados, i + 1, total, i < n_res ? 'RESUMO DAS PEÇAS' : nil) }
        escrever(caminho, paginas, imgs, dados)
        { paginas: total, pranchas: n_prancha }
      end

      def self.cabecalho(pg, dados, cont = false)
        pg.texto(MG, PH - MG - 20, dados[:titulo] || 'MAPA DE ARTES', tam: 22, negrito: true)
        sub = ['RESUMO DAS PEÇAS', (cont ? '(continuação)' : nil)].compact.join(' ')
        pg.texto(MG, PH - MG - 38, sub, tam: 10)
        pg.texto(PW - MG, PH - MG - 16, dados[:projeto].to_s, tam: 10, negrito: true, alinhar: :dir)
        pg.texto(PW - MG, PH - MG - 31, [dados[:rev], dados[:data]].compact.join('  ·  '), tam: 9, alinhar: :dir)
        pg.linha(MG, PH - MG - 48, PW - MG, PH - MG - 48, rgb: PRETO, esp: 1.0)
      end

      # Colunas da tabela: [rótulo, x, largura, alinhamento]
      COLS = [
        ['Nº',             MG,         22,  :esq],
        ['PEÇA',           MG + 26,    250, :esq],
        ['MATERIAL',       MG + 284,   190, :esq],
        ['LARGURA x ALTURA', MG + 482, 110, :esq],
        ['QTD',            MG + 640,   40,  :dir],
        ['F/V',            MG + 652,   36,  :esq],
        ['OBSERVAÇÃO',     MG + 692,   196, :esq]
      ].freeze

      def self.paginas_resumo(dados)
        pags = []
        pg = nil; y = 0
        nova = lambda do
          pg = Pagina.new
          cabecalho(pg, dados, !pags.empty?)
          pags << pg
          y = PH - MG - 70
        end
        nova.call
        cab_tabela = lambda do
          COLS.each { |r, x, w, al| pg.texto(al == :dir ? x : x, y, r, tam: 7.5, negrito: true, rgb: CINZA, alinhar: al) }
          y -= 6
          pg.linha(MG, y, PW - MG, y)
          y -= 13
        end
        fim_y = MG + 26
        geral_p = 0; geral_u = 0
        ambs = dados[:ambientes] || []
        ambs.each_with_index do |a, ai|
          itens = a[:itens] || []
          nova.call if y < fim_y + 60
          und = itens.sum { |it| it[:qtd].to_i * (it[:fv] ? 2 : 1) }
          geral_p += itens.size; geral_u += und
          pg.texto(MG, y, a[:nome].to_s.upcase, tam: 12, negrito: true)
          pg.texto(PW - MG, y, "#{itens.size} peça(s) · #{und} impressão(ões)", tam: 9, alinhar: :dir)
          y -= 16
          cab_tabela.call
          itens.each_with_index do |it, i|
            obs = [it[:obs], *(it[:notas] || [])].compact.map(&:to_s).reject(&:empty?)
            obs_l = obs.flat_map { |o| quebrar(o, 8, COLS[6][2]) }
            alt = [obs_l.size, 1].max * 10 + 6
            if y - alt < fim_y
              nova.call
              pg.texto(MG, y, "#{a[:nome].to_s.upcase} (continuação)", tam: 12, negrito: true)
              y -= 16
              cab_tabela.call
            end
            pg.retangulo(MG, y - alt + 9, PW - 2 * MG, alt, [246, 246, 246]) if i.odd?
            pg.texto(COLS[0][1], y, format('%02d', i + 1), tam: 9)
            pg.texto(COLS[1][1], y, cortar(it[:nome], 9, COLS[1][2], true), tam: 9, negrito: true)
            pg.texto(COLS[2][1], y, cortar(it[:material], 9, COLS[2][2]), tam: 9)
            pg.texto(COLS[3][1], y, "#{it[:w]} x #{it[:h]} m", tam: 9)
            pg.texto(COLS[4][1], y, it[:qtd].to_i.to_s, tam: 9, negrito: true, alinhar: :dir)
            pg.texto(COLS[5][1], y, it[:fv] ? 'SIM' : '—', tam: 9)
            obs_l.each_with_index { |l, k| pg.texto(COLS[6][1], y - 10 * k, l, tam: 8, rgb: VERMELHO) }
            y -= alt
          end
          y -= 14
        end
        nova.call if y < fim_y + 20
        pg.linha(MG, y + 8, PW - MG, y + 8, rgb: PRETO, esp: 0.8)
        pg.texto(MG, y - 6, "TOTAL: #{ambs.size} ambiente(s) · #{geral_p} peça(s) · #{geral_u} impressão(ões)", tam: 10, negrito: true)
        pg.texto(PW - MG, y - 6, 'Frente e verso conta 2 impressões por unidade.', tam: 8, rgb: CINZA, alinhar: :dir)
        pags
      end

      def self.pagina_prancha(a, idx, info, dados)
        pg = Pagina.new
        aw = PW - 2 * 24.0
        ah = PH - 24.0 - 34.0
        esc = [aw / info[:w], ah / info[:h]].min
        w = info[:w] * esc; h = info[:h] * esc
        pg.imagem(idx, (PW - w) / 2.0, 34.0 + (ah - h) / 2.0, w, h)
        pg.instance_variable_set(:@rotulo, "ARTES - #{a[:nome].to_s.upcase}")
        pg
      end

      def self.rodape(pg, dados, n, total, rotulo)
        rot = rotulo || pg.instance_variable_get(:@rotulo).to_s
        pg.linha(MG, 26, PW - MG, 26)
        pg.texto(MG, 14, rot, tam: 8, negrito: true)
        pg.texto(PW / 2.0, 14, dados[:projeto].to_s, tam: 8, alinhar: :centro)
        pg.texto(PW - MG, 14, "#{dados[:rev]}  ·  página #{n}/#{total}", tam: 8, alinhar: :dir)
      end

      # ── Arquivo ──────────────────────────────────────────────────────────────
      def self.escrever(caminho, paginas, imgs, dados)
        objs = []                                   # índice 0 => objeto 1
        add  = ->(s) { objs << s; objs.size }
        cat_id   = add.call(nil)
        pages_id = add.call(nil)
        f1 = add.call('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>')
        f2 = add.call('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>')
        img_ids = imgs.map do |im|
          cs = im[:comp] == 1 ? '/DeviceGray' : (im[:comp] == 4 ? '/DeviceCMYK' : '/DeviceRGB')
          add.call([:stream, "<< /Type /XObject /Subtype /Image /Width #{im[:w]} /Height #{im[:h]} " \
                             "/ColorSpace #{cs} /BitsPerComponent 8 /Filter /DCTDecode", im[:bin]])
        end
        kids = paginas.map do |pg|
          conteudo = Zlib::Deflate.deflate(pg.ops.join("\n"))
          c_id = add.call([:stream, '<< /Filter /FlateDecode', conteudo])
          xo = pg.imagens.uniq.map { |i| "/Im#{i} #{img_ids[i]} 0 R" }.join(' ')
          add.call("<< /Type /Page /Parent #{pages_id} 0 R /MediaBox [0 0 #{PW.to_i} #{PH.to_i}] " \
                   "/Resources << /Font << /F1 #{f1} 0 R /F2 #{f2} 0 R >>#{xo.empty? ? '' : " /XObject << #{xo} >>"} >> " \
                   "/Contents #{c_id} 0 R >>")
        end
        objs[cat_id - 1]   = "<< /Type /Catalog /Pages #{pages_id} 0 R >>"
        objs[pages_id - 1] = "<< /Type /Pages /Kids [#{kids.map { |k| "#{k} 0 R" }.join(' ')}] /Count #{kids.size} >>"
        info_id = add.call("<< /Title (#{esc(dados[:titulo] || 'Mapa de Artes')} - #{esc(dados[:projeto])}) /Producer (EVA Stand1) >>")

        out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
        offs = []
        objs.each_with_index do |o, i|
          offs << out.bytesize
          out << "#{i + 1} 0 obj\n".b
          if o.is_a?(Array)
            out << "#{o[1]} /Length #{o[2].bytesize} >>\nstream\n".b << o[2].b << "\nendstream".b
          else
            out << o.b
          end
          out << "\nendobj\n".b
        end
        xref = out.bytesize
        out << "xref\n0 #{objs.size + 1}\n0000000000 65535 f \n".b
        offs.each { |o| out << format("%010d 00000 n \n", o).b }
        out << "trailer\n<< /Size #{objs.size + 1} /Root #{cat_id} 0 R /Info #{info_id} 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
        File.binwrite(caminho, out)
        caminho
      end

    end
  end
end
