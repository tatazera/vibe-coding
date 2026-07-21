# encoding: UTF-8
# autoupdate.rb — Checagem e instalação de atualização via GitHub público
# (mesmo mecanismo do plugin STAND1_Memorial)

require 'json'

module STAND1
  module EVA

    module AutoUpdate

      VERSION       = '1.4.8'
      URL_MANIFESTO = 'https://raw.githubusercontent.com/tatazera/vibe-coding/main/STAND1_EVA/latest.json'

      # Compara "a.b.c" numericamente: remota > local?
      def self.maior?(remota, local)
        r = remota.to_s.split('.').map(&:to_i)
        l = local.to_s.split('.').map(&:to_i)
        n = [r.size, l.size].max
        r += [0] * (n - r.size)
        l += [0] * (n - l.size)
        (r <=> l) > 0
      end

      # GET assíncrono. Prioriza Sketchup::Http (pilha nativa do Windows — respeita
      # proxy/TLS do sistema, sem depender do OpenSSL do SketchUp). Fallback Net::HTTP.
      # Chama on_body.call(corpo_ou_nil, ok_booleano).
      def self.http_async(url, &on_body)
        if defined?(Sketchup::Http) && defined?(Sketchup::Http::Request)
          req = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
          # Retém a requisição: sem isso o GC a coleta antes do callback disparar.
          (@http_reqs ||= []) << req
          req.start do |request, response|
            (@http_reqs ||= []).delete(request) rescue nil
            code = response.respond_to?(:status_code) ? response.status_code.to_i : 0
            body = response.respond_to?(:body) ? response.body : nil
            if code >= 200 && code < 400 && body && !body.empty?
              on_body.call(body, true)
            else
              on_body.call(nil, false)
            end
          end
        else
          body = http_get_net(url) rescue nil
          on_body.call(body, !body.nil?)
        end
      rescue
        on_body.call(nil, false)
      end

      # Fallback síncrono: Net::HTTP com cert tolerante.
      def self.http_get_net(url, limite = 4)
        require 'net/http'
        require 'openssl'
        raise 'muitos redirecionamentos' if limite <= 0
        uri  = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == 'https')
        http.verify_mode  = OpenSSL::SSL::VERIFY_NONE
        http.open_timeout = 8
        http.read_timeout = 60
        resp = http.get(uri.request_uri)
        case resp
        when Net::HTTPSuccess     then resp.body
        when Net::HTTPRedirection then http_get_net(resp['location'], limite - 1)
        else raise "HTTP #{resp.code}"
        end
      end

      # Verifica versão e sinaliza o diálogo. manual=true mostra também "sem update".
      def self.check(dialog, manual = false)
        return unless dialog
        http_async(URL_MANIFESTO) do |body, ok|
          next (dialog.execute_script('updateErro()') rescue nil) if (!ok || body.nil?) && manual
          next unless ok && body
          begin
            # Remove BOM (UTF-8) eventual no início — senão JSON.parse falha.
            # IMPORTANTE: usar o escape \uFEFF (regexp UTF-8), NUNCA a forma
            # regexp binária (/n) lança Encoding::CompatibilityError se o corpo
            # tiver qualquer caractere não-ASCII (ex.: um travessão nas notas).
            limpo = body.to_s.dup.force_encoding('UTF-8').scrub('').sub(/\A\uFEFF/, '')
            info  = JSON.parse(limpo)
            nova  = info['versao'].to_s
            if maior?(nova, VERSION)
              payload = { versao: nova, notas: info['notas'].to_s, rbz: info['rbz'].to_s }.to_json
              dialog.execute_script("mostrarUpdate(#{payload})") rescue nil
            elsif manual
              dialog.execute_script("semUpdate(#{VERSION.to_json})") rescue nil
            end
          rescue
            dialog.execute_script('updateErro()') rescue nil if manual
          end
        end
      end

      # Baixa o .rbz e instala via API nativa; fallback abre a URL no navegador.
      def self.install(url)
        http_async(url) do |body, ok|
          if !ok || body.nil?
            UI.messagebox("Não foi possível baixar a atualização.\nAbrindo o download no navegador.")
            UI.openURL(url) rescue nil
            next
          end
          begin
            destino = File.join(Dir.tmpdir, 'STAND1_EVA_update.rbz')
            File.open(destino, 'wb') { |f| f.write(body) }
            if Sketchup.respond_to?(:install_from_archive)
              Sketchup.install_from_archive(destino)
              UI.messagebox("✅ Atualização instalada!\n\nReinicie o SketchUp para concluir.")
            else
              UI.openURL(url)
            end
          rescue => e
            UI.messagebox("Falha ao instalar a atualização:\n#{e.message}\n\nAbrindo o download no navegador.")
            UI.openURL(url) rescue nil
          end
        end
      end

    end

  end
end
