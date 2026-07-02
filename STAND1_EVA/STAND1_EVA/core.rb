# encoding: UTF-8
# core.rb — EVA Stand1: núcleo principal

require 'sketchup'
require 'json'
require 'tmpdir'

require_relative 'dictionary'
require_relative 'exporter'
require_relative 'prompt_builder'
require_relative 'autoupdate'

module STAND1
  module EVA

    DIALOG_HTML  = File.join(File.dirname(__FILE__), 'html', 'dialog.html')
    SETTINGS_KEY = 'STAND1_EVA'

    def self.open_dialog
      unless Sketchup.active_model
        UI.messagebox('Nenhum modelo aberto no SketchUp.')
        return
      end

      # Instância única: se já está aberto, traz para frente.
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title:    'EVA Stand1',
        scrollable:      false,
        resizable:       true,
        width:           820,
        height:          620,
        min_width:       600,
        min_height:      400,
        style:           UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.set_file(DIALOG_HTML)
      @dialog.add_action_callback('get_scenes')     { |_, _|   send_scenes      }
      @dialog.add_action_callback('choose_folder')  { |_, tgt| choose_folder(tgt) }
      @dialog.add_action_callback('export_scenes')  { |_, msg| handle_export(msg) }
      @dialog.add_action_callback('get_materials')  { |_, msg| send_materials(msg) }
      @dialog.add_action_callback('build_prompts')  { |_, msg| handle_build(msg) }
      @dialog.add_action_callback('check_update')   { |_, _|   AutoUpdate.check(@dialog, true) }
      @dialog.add_action_callback('install_update') { |_, url| AutoUpdate.install(url) }
      @dialog.add_action_callback('get_settings')    { |_, _|   send_settings        }
      @dialog.add_action_callback('save_settings')  { |_, msg| save_settings(msg)   }
      @dialog.add_action_callback('capture_preview')  { |_, msg| send_preview(msg)          }
      @dialog.add_action_callback('choose_logo_file') { |_, _|   choose_logo_file            }
      @dialog.add_action_callback('remove_bg')        { |_, msg| handle_remove_bg(msg)       }
      @dialog.add_action_callback('import_material')  { |_, msg| handle_import_material(msg) }
      @dialog.add_action_callback('pick_color')       { |_, _|   start_color_pick           }
      @dialog.add_action_callback('tint_logo')        { |_, msg| handle_tint_logo(msg)       }
      @dialog.add_action_callback('save_api_key')     { |_, key| save_api_key(key)           }
      @dialog.add_action_callback('open_url')         { |_, url| UI.openURL(url)             }
      @dialog.add_action_callback('save_scene_criticals') { |_, msg| save_scene_criticals(msg) }
      @dialog.add_action_callback('get_scene_thumbs')     { |_, msg| send_scene_thumbs(msg)    }
      @dialog.add_action_callback('export_prompts_txt')   { |_, msg| export_prompts_txt(msg)   }
      @dialog.show

      # Checagem silenciosa de atualização ao abrir (não bloqueia a UI).
      UI.start_timer(2.0, false) { AutoUpdate.check(@dialog, false) } rescue nil
    end

    # ── Envia lista de Scenes para o HTML ─────────────────────────────────────

    def self.send_scenes
      model  = Sketchup.active_model
      scenes = model.pages.map { |p| { name: p.name, sid: scene_sid(p) } }
      @dialog.execute_script("window.setScenes(#{scenes.to_json})")
    end

    # ID estável por cena, gravado na própria Page (sobrevive a renomear a cena).
    def self.scene_sid(page)
      sid = (page.get_attribute(SETTINGS_KEY, 'sid', nil) rescue nil)
      if sid.nil? || sid.to_s.empty?
        sid = "s#{Time.now.to_i}#{rand(100000)}"
        page.set_attribute(SETTINGS_KEY, 'sid', sid) rescue nil
      end
      sid.to_s
    end

    # ── Store por cena: { sid => { "criticals" => "...", "prompt" => "..." } } ──
    # Gravado no modelo (.skp) + fallback global (registro), como os demais campos.
    def self.read_scene_store(model)
      raw = (model && model.get_attribute(SETTINGS_KEY, 'scene_store', nil) rescue nil)
      raw = (Sketchup.read_default(SETTINGS_KEY, 'last_scene_store', '') rescue '') if raw.nil? || raw.to_s.empty?
      h = (raw.nil? || raw.to_s.empty?) ? {} : (JSON.parse(raw) rescue {})
      h.is_a?(Hash) ? h : {}
    end

    def self.write_scene_store(model, store)
      json = store.to_json
      model.set_attribute(SETTINGS_KEY, 'scene_store', json) if model
      Sketchup.write_default(SETTINGS_KEY, 'last_scene_store', json) rescue nil
    end

    # Salva os criticals de UMA cena (por sid). msg = { sid, criticals }.
    def self.save_scene_criticals(msg)
      data  = JSON.parse(msg) rescue nil
      return unless data && data['sid']
      model = Sketchup.active_model
      store = read_scene_store(model)
      entry = store[data['sid']] || {}
      entry['criticals'] = data['criticals'].to_s
      store[data['sid']] = entry
      write_scene_store(model, store)
    rescue
    end

    # ── Persistência de preferências (entre sessões) ──────────────────────────

    # Pasta de backup fora do plugin (sobrevive a reinstalação do .rbz e a
    # eventuais problemas de gravação no registro do Windows).
    def self.backup_dir
      d = File.join(ENV['APPDATA'] || Dir.home, 'STAND1_EVA')
      Dir.mkdir(d) unless File.directory?(d)
      d
    rescue
      ENV['TEMP'] || Dir.tmpdir
    end

    def self.api_key_backup_file
      File.join(backup_dir, 'rbg_api_key.txt')
    end

    # Lê um campo por-projeto do modelo; se vazio, cai no último valor global
    # (write_default). Assim o dado sobrevive mesmo se o .skp não foi salvo.
    def self.read_project_field(model, attr, global_key)
      val = (model && model.get_attribute(SETTINGS_KEY, attr, nil) rescue nil)
      if val.nil? || val.to_s.empty?
        val = (Sketchup.read_default(SETTINGS_KEY, global_key, '').to_s rescue '')
      end
      val.to_s
    end

    def self.send_settings
      raw = Sketchup.read_default(SETTINGS_KEY, 'settings', '')
      obj = (raw.nil? || raw.to_s.empty?) ? {} : (JSON.parse(raw) rescue {})
      model = Sketchup.active_model
      # Descrição e CRITICALs são por-projeto (modelo .skp), com fallback ao
      # último valor global — não some mesmo se o usuário não salvou o .skp.
      obj['description'] = read_project_field(model, 'description', 'last_description')
      obj['criticals']   = read_project_field(model, 'criticals',   'last_criticals')
      # API key: registro dedicado + fallback em arquivo (robusto contra reset).
      key = (Sketchup.read_default(SETTINGS_KEY, 'rbg_api_key', '').to_s rescue '')
      if key.empty? && File.file?(api_key_backup_file)
        key = (File.read(api_key_backup_file).to_s.strip rescue '')
        # recuperou do arquivo → regrava no registro
        Sketchup.write_default(SETTINGS_KEY, 'rbg_api_key', key) unless key.empty?
      end
      obj['rbgApiKey'] = key
      # Store por cena (criticals + últimos prompts), chaveado por sid.
      obj['sceneStore'] = read_scene_store(model)
      @dialog.execute_script("window.applySettings(#{obj.to_json})")
    end

    def self.save_settings(json)
      return if json.nil? || json.to_s.empty?
      parsed = JSON.parse(json) rescue nil
      return unless parsed
      model = Sketchup.active_model
      # Descrição e CRITICALs: gravam no modelo (.skp) E no registro global como
      # "último valor", garantindo persistência mesmo sem salvar o .skp.
      save_project_field(model, parsed.delete('description'), 'description', 'last_description')
      save_project_field(model, parsed.delete('criticals'),   'criticals',   'last_criticals')
      # API key: NUNCA sobrescreve com vazio aqui (evita apagar a chave numa
      # gravação geral disparada por outro campo). Limpar só pelo onApiKeyInput.
      api_key = parsed.delete('rbgApiKey')
      save_api_key(api_key) unless api_key.nil? || api_key.to_s.strip.empty?
      Sketchup.write_default(SETTINGS_KEY, 'settings', parsed.to_json)
    end

    def self.save_project_field(model, val, attr, global_key)
      return if val.nil?
      if model
        cur = (model.get_attribute(SETTINGS_KEY, attr, '').to_s rescue '')
        # Só grava (e "suja" o .skp) se realmente mudou.
        model.set_attribute(SETTINGS_KEY, attr, val.to_s) if cur != val.to_s
      end
      Sketchup.write_default(SETTINGS_KEY, global_key, val.to_s) rescue nil
    end

    # Grava a API key imediatamente em registro dedicado + backup em arquivo.
    # Desacoplado de save_settings: persiste mesmo se outro campo falhar.
    def self.save_api_key(key)
      k = key.to_s
      Sketchup.write_default(SETTINGS_KEY, 'rbg_api_key', k)
      File.open(api_key_backup_file, 'w:UTF-8') { |f| f.write(k) } rescue nil
    rescue => e
      # silencioso — não derruba a UI
    end

    # ── Captura preview da viewport atual para o editor visual de crop ────────

    def self.send_preview(scene_name = nil)
      model = Sketchup.active_model
      # Muda para a cena solicitada (se fornecida e existir)
      if scene_name && !scene_name.empty?
        page = model.pages.find { |p| p.name == scene_name }
        model.pages.selected_page = page if page
      end
      view = model.active_view
      tmp  = File.join(ENV['TEMP'] || Dir.tmpdir, 'eva_crop_preview.png')
      view.write_image(filename: tmp, width: 1280, height: 720, antialias: false)
      @dialog.execute_script("window.showCropEditor(#{tmp.to_json})")
    rescue => e
      @dialog.execute_script("window.cropPreviewError(#{e.message.to_json})")
    end

    # ── Abre diálogo de pasta e retorna path ──────────────────────────────────

    def self.choose_folder(target = 'render')
      folder = UI.select_directory(title: 'Selecione a pasta de destino')
      return unless folder
      tgt = (target.nil? || target.to_s.empty?) ? 'render' : target.to_s
      @dialog.execute_script("window.setFolder(#{tgt.to_json}, #{folder.to_json})")
    end

    # ── Recebe configuração do HTML e dispara export ───────────────────────────

    def self.handle_export(msg)
      config = JSON.parse(msg, symbolize_names: true)
      # crops usa nomes de cena como chaves — preserva strings para lookup correto
      raw = JSON.parse(msg)
      config[:crops] = raw['crops'] if raw['crops']
      result = Exporter.run(config)
      @dialog.execute_script("window.exportDone(#{result.to_json})")
    rescue => e
      @dialog.execute_script("window.exportDone(#{ { ok: false, error: e.message }.to_json })")
    end

    # ── Fase 2: envia materiais detectados para o HTML ────────────────────────

    def self.send_materials(_msg = nil)
      model = Sketchup.active_model
      mats  = PromptBuilder.read_palette(model)
      data  = mats.map do |m|
        t = Dictionary.translate(m)
        { original: m, translated: t, mapped: (t != m) }
      end
      # Reconhecidos (paleta Stand1) primeiro; demais por ordem alfabética.
      data = data.sort_by { |d| [d[:mapped] ? 0 : 1, d[:original].downcase] }
      @dialog.execute_script("window.setMaterials(#{data.to_json})")
    rescue => e
      @dialog.execute_script("window.setMaterials([]); window.buildError(#{e.message.to_json})")
    end

    # ── Fase 2: recebe config e monta prompts ─────────────────────────────────

    def self.handle_build(msg)
      model  = Sketchup.active_model
      config = JSON.parse(msg, symbolize_names: true)

      scene_names = config[:scenes] || []
      store       = read_scene_store(model)

      # Mapa nome-da-cena => criticals específicos (do store, por sid), em linhas.
      scene_crit = {}
      model.pages.each do |p|
        next unless scene_names.include?(p.name)
        entry = store[scene_sid(p)]
        txt   = entry && entry['criticals']
        next if txt.nil? || txt.to_s.strip.empty?
        scene_crit[p.name] = txt.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)
      end

      shared = {
        lighting:        config[:lighting]     || 'frio',
        environment:     config[:environment]  || 'feira',
        booth_type:      config[:booth_type]   || 'ilha',
        people:          config[:people],
        description:     config[:description]   || '',
        criticals_pt:    config[:criticals_pt] || [], # gerais (todas as cenas)
        scene_criticals: scene_crit                    # específicos por cena
      }

      results = PromptBuilder.build_all(model, scene_names, shared)

      # Persiste o prompt gerado de cada cena no store (por sid) + devolve sid ao JS.
      results.each do |r|
        page = model.pages.find { |p| p.name == r[:scene] }
        next unless page
        sid = scene_sid(page)
        entry = store[sid] || {}
        entry['prompt'] = r[:prompt]
        store[sid] = entry
        r[:sid] = sid
      end
      write_scene_store(model, store)

      @dialog.execute_script("window.promptsDone(#{results.to_json})")
    rescue => e
      @dialog.execute_script("window.buildError(#{e.message.to_json})")
    end

    # ── U2: exporta os prompts para um .txt (savepanel) ───────────────────────
    def self.export_prompts_txt(msg)
      data = JSON.parse(msg) rescue nil
      items = data && data['prompts']
      return unless items.is_a?(Array) && !items.empty?
      default = (data['name'].to_s.strip.empty? ? 'prompts_EVA' : data['name'].to_s) + '.txt'
      path = UI.savepanel('Salvar prompts', '', default)
      return unless path
      path += '.txt' unless path.downcase.end_with?('.txt')
      body = items.map do |it|
        "=== #{it['scene']} ===\n#{it['prompt']}\n"
      end.join("\n")
      File.open(path, 'w:UTF-8') { |f| f.write(body) }
      @dialog.execute_script("window.promptsTxtDone(#{path.to_json})")
    rescue => e
      @dialog.execute_script("window.promptsTxtDone(#{ { error: e.message }.to_json })")
    end

    # ── U4: miniaturas das cenas (sem trocar de página, restaura a câmera) ─────
    def self.send_scene_thumbs(msg)
      model = Sketchup.active_model
      view  = model.active_view
      names = (JSON.parse(msg)['scenes'] rescue nil)
      pages = model.pages.select { |p| names.nil? || names.include?(p.name) }
      orig  = view.camera
      out   = {}
      tmp   = File.join(ENV['TEMP'] || Dir.tmpdir, 'eva_thumb.png')
      pages.each do |p|
        begin
          view.camera = p.camera
          view.write_image(filename: tmp, width: 160, height: 96, antialias: true)
          out[scene_sid(p)] = image_data_url(tmp)
        rescue
        end
      end
      view.camera = orig
      view.invalidate
      @dialog.execute_script("window.setSceneThumbs(#{out.to_json})")
    rescue => e
      @dialog.execute_script("window.setSceneThumbs({})")
    end

    # ── Aba Logos: seleção de arquivo (PNG ou JPEG) ──────────────────────────

    def self.choose_logo_file
      path = UI.openpanel('Selecionar imagem', '', 'Imagens|*.png;*.jpg;*.jpeg||')
      return unless path
      data = image_data_url(path)
      @dialog.execute_script("window.setLogoFile(#{path.to_json}, #{data.to_json})")
    end

    # Lê um arquivo de imagem e devolve um data URL base64 (preview embutido).
    # CEF do HtmlDialog bloqueia file:///, então previews vão por data URL.
    def self.image_data_url(path)
      return '' unless File.exist?(path)
      ext  = File.extname(path).downcase
      mime = case ext
             when '.jpg', '.jpeg' then 'image/jpeg'
             else 'image/png'
             end
      b64 = [File.binread(path)].pack('m0')
      "data:#{mime};base64,#{b64}"
    rescue
      ''
    end

    # ── Aba Logos: remoção de fundo via remove.bg API ─────────────────────────
    # Usa System.Net.Http via PowerShell (compatível com PS 5.1+) para enviar
    # multipart form-data sem dependências externas.

    def self.handle_remove_bg(msg)
      config   = JSON.parse(msg)
      api_key  = config['apikey'].to_s.strip
      src_path = config['path'].to_s
      name     = (config['name'] || 'logo').gsub(/[^a-z0-9\-_]/i, '_')

      # remove.bg sempre devolve PNG (com transparência), independente da entrada.
      out_path = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_rmbg_#{name}.png")
      in_ext   = File.extname(src_path).downcase
      in_mime  = (in_ext == '.jpg' || in_ext == '.jpeg') ? 'image/jpeg' : 'image/png'
      in_fname = "image#{in_ext.empty? ? '.png' : in_ext}"

      err_path = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_rmbg_err_#{Process.pid}.txt")
      safe_in  = src_path.gsub("'", "''")
      safe_out = out_path.gsub("'", "''")
      safe_key = api_key.gsub("'", "''")
      safe_err = err_path.gsub("'", "''")

      ps = <<~PS
        Add-Type -AssemblyName System.Net.Http
        try {
          $client = [System.Net.Http.HttpClient]::new()
          $client.Timeout = [System.TimeSpan]::FromSeconds(60)
          $client.DefaultRequestHeaders.Add('X-Api-Key', '#{safe_key}')
          $content = [System.Net.Http.MultipartFormDataContent]::new()
          $bytes   = [System.IO.File]::ReadAllBytes('#{safe_in}')
          $fc      = [System.Net.Http.ByteArrayContent]::new($bytes)
          $fc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('#{in_mime}')
          $content.Add($fc, 'image_file', '#{in_fname}')
          $sc = [System.Net.Http.StringContent]::new('auto')
          $content.Add($sc, 'size')
          $resp = $client.PostAsync('https://api.remove.bg/v1.0/removebg', $content).GetAwaiter().GetResult()
          if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::OK) {
            $out = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            [System.IO.File]::WriteAllBytes('#{safe_out}', $out)
            exit 0
          } else {
            $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            [System.IO.File]::WriteAllText('#{safe_err}', [string]$resp.StatusCode + ': ' + $err)
            exit 1
          }
        } catch {
          [System.IO.File]::WriteAllText('#{safe_err}', $_.Exception.Message)
          exit 1
        }
      PS

      File.delete(out_path) rescue nil
      File.delete(err_path) rescue nil
      tmp_ps = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_rmbg_#{Process.pid}.ps1")
      File.write(tmp_ps, ps, encoding: 'UTF-8')
      ok = system("powershell -NonInteractive -ExecutionPolicy Bypass -File \"#{tmp_ps}\"")
      File.delete(tmp_ps) rescue nil

      if ok && File.exist?(out_path)
        data = image_data_url(out_path)
        @dialog.execute_script("window.removeBgDone(#{{ ok: true, path: out_path, data: data }.to_json})")
      else
        detail = (File.read(err_path) rescue nil) if File.exist?(err_path)
        File.delete(err_path) rescue nil
        msg_err = parse_rmbg_error(detail)
        @dialog.execute_script("window.removeBgDone(#{{ ok: false, error: msg_err }.to_json})")
      end
    rescue => e
      @dialog.execute_script("window.removeBgDone(#{{ ok: false, error: e.message }.to_json})")
    end

    # Traduz erros comuns da API remove.bg para mensagens claras em PT.
    def self.parse_rmbg_error(detail)
      d = detail.to_s
      return 'Falha na API. Verifique a key ou o crédito disponível.' if d.empty?
      return 'API key inválida. Confira a chave em remove.bg.'          if d =~ /403|401|invalid.*api.*key|Unauthorized/i
      return 'Crédito mensal esgotado (50 grátis/mês).'                 if d =~ /402|insufficient|credit/i
      return 'Tempo de conexão esgotado. Verifique a internet.'         if d =~ /timeout|timed out/i
      return 'Sem conexão com a internet.'                              if d =~ /resolve|connect|network/i
      d.length > 160 ? (d[0, 160] + '…') : d
    end

    # ── Aba Logos: conta-gotas — captura cor de uma face do modelo ────────────

    def self.start_color_pick
      model = Sketchup.active_model
      model.select_tool(ColorPickTool.new) if model
    end

    # Devolve a cor capturada (#RRGGBB) ao HTML; nil dispara mensagem de erro.
    def self.report_picked_color(hex)
      @dialog.execute_script("window.setPickedColor(#{hex.to_json})") if @dialog
    end

    # ── Aba Logos: tingir logo com cor sólida (preserva alfa) ─────────────────

    def self.handle_tint_logo(msg)
      config = JSON.parse(msg)
      src    = config['path'].to_s
      hex    = config['hex'].to_s.strip
      name   = (config['name'] || 'logo').gsub(/[^a-z0-9\-_]/i, '_')

      raise 'Cor inválida.'        unless hex =~ /\A#?[0-9a-fA-F]{6}\z/
      raise 'Arquivo não existe.'  unless File.exist?(src)
      hex = hex.delete('#')
      r = hex[0, 2].to_i(16)
      g = hex[2, 2].to_i(16)
      b = hex[4, 2].to_i(16)

      out_path = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_tint_#{name}.png")
      safe_in  = src.gsub("'", "''")
      safe_out = out_path.gsub("'", "''")

      ps = <<~PS
        Add-Type -AssemblyName System.Drawing
        try {
          $src = [System.Drawing.Bitmap]::FromFile('#{safe_in}')
          $w = $src.Width; $h = $src.Height
          $dst = [System.Drawing.Bitmap]::new($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
          $rect = [System.Drawing.Rectangle]::new(0, 0, $w, $h)
          $sd = $src.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
          $dd = $dst.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
          $n = $w * $h * 4
          $buf = New-Object byte[] $n
          [System.Runtime.InteropServices.Marshal]::Copy($sd.Scan0, $buf, 0, $n)
          for ($i = 0; $i -lt $n; $i += 4) {
            # Formato em memória (little-endian ARGB) = B,G,R,A
            $buf[$i]   = #{b}
            $buf[$i+1] = #{g}
            $buf[$i+2] = #{r}
            # $buf[$i+3] (alfa) preservado
          }
          [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $dd.Scan0, $n)
          $src.UnlockBits($sd)
          $dst.UnlockBits($dd)
          $src.Dispose()
          $dst.Save('#{safe_out}', [System.Drawing.Imaging.ImageFormat]::Png)
          $dst.Dispose()
          exit 0
        } catch {
          exit 1
        }
      PS

      File.delete(out_path) rescue nil
      tmp_ps = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_tint_#{Process.pid}.ps1")
      File.write(tmp_ps, ps, encoding: 'UTF-8')
      ok = system("powershell -NonInteractive -ExecutionPolicy Bypass -File \"#{tmp_ps}\"")
      File.delete(tmp_ps) rescue nil

      if ok && File.exist?(out_path)
        data = image_data_url(out_path)
        @dialog.execute_script("window.tintDone(#{{ ok: true, path: out_path, data: data }.to_json})")
      else
        @dialog.execute_script("window.tintDone(#{{ ok: false, error: 'Falha ao aplicar a cor.' }.to_json})")
      end
    rescue => e
      @dialog.execute_script("window.tintDone(#{{ ok: false, error: e.message }.to_json})")
    end

    # ── Aba Logos: importa PNG resultante como material no modelo ─────────────

    def self.handle_import_material(msg)
      config = JSON.parse(msg)
      path   = config['path'].to_s
      name   = config['name'].to_s
      name   = 'logo_sem_fundo' if name.empty?

      model = Sketchup.active_model
      existing = model.materials[name]
      model.materials.remove(existing) if existing
      mat = model.materials.add(name)
      mat.texture = path

      @dialog.execute_script("window.importMatDone(#{{ ok: true, name: name }.to_json})")
    rescue => e
      @dialog.execute_script("window.importMatDone(#{{ ok: false, error: e.message }.to_json})")
    end

    # ── Conta-gotas: ferramenta que captura a cor do material sob o cursor ────

    class ColorPickTool
      def activate
        Sketchup.set_status_text('Clique numa face para capturar a cor do material. ESC cancela.')
        @ph = Sketchup.active_model.active_view.pick_helper
      end

      def deactivate(view)
        Sketchup.set_status_text('')
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        @ph.do_pick(x, y)
        view.tooltip = color_under(view, x, y) ? 'Capturar esta cor' : 'Sem material aqui'
      end

      def onLButtonDown(_flags, x, y, view)
        color = color_under(view, x, y)
        hex   = color ? format('#%02X%02X%02X', color.red, color.green, color.blue) : nil
        STAND1::EVA.report_picked_color(hex)
        view.model.select_tool(nil)
      end

      def onCancel(_reason, view)
        STAND1::EVA.report_picked_color(nil)
        view.model.select_tool(nil)
      end

      # Resolve a cor do material da face sob o cursor (front, depois back).
      def color_under(view, x, y)
        @ph.do_pick(x, y)
        ent = @ph.best_picked
        return nil unless ent.is_a?(Sketchup::Face)
        mat = ent.material || ent.back_material
        mat && mat.color
      rescue
        nil
      end
    end

    # ── Menu + Toolbar ────────────────────────────────────────────────────────

    unless file_loaded?(__FILE__)
      icons_dir   = File.join(File.dirname(__FILE__), 'icons')
      icon_small  = File.join(icons_dir, 'eva_small.png')
      icon_large  = File.join(icons_dir, 'eva_large.png')

      cmd = UI::Command.new('EVA Stand1') { STAND1::EVA.open_dialog }
      cmd.tooltip         = 'EVA Stand1'
      cmd.status_bar_text = 'EVA — Export de Scenes e geração de prompts para render IA'
      cmd.small_icon = icon_small if File.exist?(icon_small)
      cmd.large_icon = icon_large if File.exist?(icon_large)

      # Menu
      menu = UI.menu('Plugins')
      sub  = menu.add_submenu('STAND1')
      sub.add_item(cmd)

      # Toolbar (barra de ícones)
      toolbar = UI::Toolbar.new('EVA Stand1')
      toolbar.add_item(cmd)
      toolbar.restore

      file_loaded(__FILE__)
    end

  end
end
