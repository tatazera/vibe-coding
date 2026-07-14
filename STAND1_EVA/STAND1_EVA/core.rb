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
      @dialog.add_action_callback('list_folder_images')   { |_, path| list_folder_images(path)   }
      @dialog.add_action_callback('replace_folder_image') { |_, path| replace_folder_image(path) }
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
      @dialog.add_action_callback('save_logo_png')    { |_, msg| save_logo_png(msg)         }
      @dialog.add_action_callback('load_logo_data')   { |_, msg| load_logo_data(msg)        }
      @dialog.add_action_callback('save_gemini_key')  { |_, key| save_gemini_key(key)       }
      @dialog.add_action_callback('studio_generate')  { |_, msg| studio_generate(msg)       }
      @dialog.add_action_callback('save_studio_png')  { |_, msg| save_studio_png(msg)       }
      @dialog.add_action_callback('choose_ref_image') { |_, _|   choose_ref_image           }
      @dialog.add_action_callback('pick_color')       { |_, _|   start_color_pick           }
      @dialog.add_action_callback('tint_logo')        { |_, msg| handle_tint_logo(msg)       }
      @dialog.add_action_callback('save_api_key')     { |_, key| save_api_key(key)           }
      @dialog.add_action_callback('open_url')         { |_, url| UI.openURL(url)             }
      @dialog.add_action_callback('save_scene_criticals') { |_, msg| save_scene_criticals(msg) }
      @dialog.add_action_callback('save_scene_camera')    { |_, msg| save_scene_camera(msg)    }
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

    # ── Store por cena: { sid => { criticals, prompt, camera } } ───────────────
    # Gravado no modelo (.skp) + sidecar POR PROJETO (não usa mais registro
    # global — o fallback global vazava dados entre projetos e era sobrescrito
    # pelo último projeto aberto).
    def self.read_scene_store(model)
      raw = (model && model.get_attribute(SETTINGS_KEY, 'scene_store', nil) rescue nil)
      if raw.nil? || raw.to_s.empty?
        f = project_text_file(model, 'scene_store')
        raw = (File.read(f, encoding: 'UTF-8') rescue '') if File.file?(f)
      end
      h = (raw.nil? || raw.to_s.empty?) ? {} : (JSON.parse(raw) rescue {})
      h.is_a?(Hash) ? h : {}
    end

    def self.write_scene_store(model, store)
      json = store.to_json
      model.set_attribute(SETTINGS_KEY, 'scene_store', json) if model
      File.open(project_text_file(model, 'scene_store'), 'w:UTF-8') { |f| f.write(json) } rescue nil
      # Limpa o resíduo global antigo (não é mais usado).
      Sketchup.write_default(SETTINGS_KEY, 'last_scene_store', '') rescue nil
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

    # Salva o override de ângulo de UMA cena (por sid). msg = { sid, camera }.
    # camera = '' (automático) ou uma das chaves de PromptBuilder::CAMERA_OVERRIDES.
    def self.save_scene_camera(msg)
      data  = JSON.parse(msg) rescue nil
      return unless data && data['sid']
      model = Sketchup.active_model
      store = read_scene_store(model)
      entry = store[data['sid']] || {}
      entry['camera'] = data['camera'].to_s
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

    # Chave estável POR PROJETO: hash do caminho do .skp. Modelo nunca salvo
    # usa 'unsaved' (compartilhado entre não-salvos — melhor que perder o texto).
    def self.project_key(model)
      path = (model && model.path.to_s) || ''
      return 'unsaved' if path.strip.empty?
      require 'digest'
      Digest::MD5.hexdigest(path.downcase)
    end

    # ── Sidecar POR PROJETO (%APPDATA%/STAND1_EVA/<campo>_<hash-do-path>.txt) ──
    # Regra de sincronização por projeto: cada campo por-projeto grava no .skp
    # (attr) E no sidecar; leitura tenta o .skp e cai no sidecar. Assim o dado
    # sobrevive mesmo sem salvar o .skp e NUNCA vaza entre projetos.
    def self.project_text_file(model, attr)
      File.join(backup_dir, "#{attr}_#{project_key(model)}.txt")
    end

    def self.read_project_text(model, attr)
      val = (model && model.get_attribute(SETTINGS_KEY, attr, '').to_s rescue '')
      if val.empty?
        f = project_text_file(model, attr)
        val = (File.read(f, encoding: 'UTF-8').to_s rescue '') if File.file?(f)
      end
      val
    end

    def self.write_project_text(model, attr, val)
      return if val.nil?
      if model
        cur = (model.get_attribute(SETTINGS_KEY, attr, '').to_s rescue '')
        # Só grava (e "suja" o .skp) se realmente mudou.
        model.set_attribute(SETTINGS_KEY, attr, val.to_s) if cur != val.to_s
      end
      File.open(project_text_file(model, attr), 'w:UTF-8') { |f| f.write(val.to_s) } rescue nil
    end

    def self.send_settings
      raw = Sketchup.read_default(SETTINGS_KEY, 'settings', '')
      obj = (raw.nil? || raw.to_s.empty?) ? {} : (JSON.parse(raw) rescue {})
      model = Sketchup.active_model
      # Descrição e CRITICALs são POR-PROJETO: .skp + sidecar do projeto.
      # Sem fallback global — não vazam entre projetos e não somem sem salvar o .skp.
      obj['description'] = read_project_text(model, 'description')
      obj['criticals']   = read_project_text(model, 'criticals')
      # API key: registro dedicado + fallback em arquivo (robusto contra reset).
      key = (Sketchup.read_default(SETTINGS_KEY, 'rbg_api_key', '').to_s rescue '')
      if key.empty? && File.file?(api_key_backup_file)
        key = (File.read(api_key_backup_file).to_s.strip rescue '')
        # recuperou do arquivo → regrava no registro
        Sketchup.write_default(SETTINGS_KEY, 'rbg_api_key', key) unless key.empty?
      end
      obj['rbgApiKey'] = key
      obj['geminiApiKey'] = read_gemini_key
      # Store por cena (criticals + últimos prompts), chaveado por sid.
      obj['sceneStore'] = read_scene_store(model)
      @dialog.execute_script("window.applySettings(#{obj.to_json})")
    end

    def self.save_settings(json)
      return if json.nil? || json.to_s.empty?
      parsed = JSON.parse(json) rescue nil
      return unless parsed
      model = Sketchup.active_model
      # Descrição e CRITICALs: POR-PROJETO (.skp + sidecar do projeto), sem
      # registro global — não vazam entre projetos e não somem sem salvar o .skp.
      write_project_text(model, 'description', parsed.delete('description'))
      write_project_text(model, 'criticals',   parsed.delete('criticals'))
      # Limpa resíduos globais antigos (não são mais usados).
      Sketchup.write_default(SETTINGS_KEY, 'last_criticals', '')   rescue nil
      Sketchup.write_default(SETTINGS_KEY, 'last_description', '') rescue nil
      # API key: NUNCA sobrescreve com vazio aqui (evita apagar a chave numa
      # gravação geral disparada por outro campo). Limpar só pelo onApiKeyInput.
      api_key = parsed.delete('rbgApiKey')
      save_api_key(api_key) unless api_key.nil? || api_key.to_s.strip.empty?
      Sketchup.write_default(SETTINGS_KEY, 'settings', parsed.to_json)
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

    # ── Aba Apresentação: lista PNG/JPG da pasta p/ grid clicável ──────────────
    # Aditivo/isolado — não altera o fluxo de export.
    def self.list_folder_images(folder)
      unless folder && !folder.to_s.empty? && File.directory?(folder)
        @dialog.execute_script("window.setFolderImages([])")
        return
      end
      exts = %w[png jpg jpeg]
      files = Dir.entries(folder).select do |f|
        File.file?(File.join(folder, f)) && exts.include?(f.split('.').last.to_s.downcase)
      end.sort_by { |f| f.downcase }
      data = files.map do |f|
        full = File.join(folder, f)
        {
          name:  f,
          path:  full.tr('\\', '/'),
          size:  (File.size(full)  rescue 0),
          mtime: (File.mtime(full).to_i rescue 0)
        }
      end
      @dialog.execute_script("window.setFolderImages(#{data.to_json})")
    rescue => e
      @dialog.execute_script("window.setFolderImages([])")
    end

    # Substitui um arquivo da pasta por outro escolhido no PC (mantém o nome do alvo).
    def self.replace_folder_image(target)
      return if target.nil? || target.to_s.empty?
      src = UI.openpanel('Escolher imagem para substituir', '', 'Imagens|*.png;*.jpg;*.jpeg||')
      return unless src
      # Sobrescreve o alvo com os bytes do arquivo escolhido (preserva nome/extensão do alvo).
      File.open(target, 'wb') { |o| File.open(src, 'rb') { |i| o.write(i.read) } }
      list_folder_images(File.dirname(target))
      @dialog.execute_script("window.folderImageReplaced(#{File.basename(target).to_json})")
    rescue => e
      @dialog.execute_script("window.folderImageError(#{e.message.to_json})")
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
      # E mapa nome-da-cena => override de ângulo (do store, por sid).
      scene_crit = {}
      scene_cam  = {}
      model.pages.each do |p|
        next unless scene_names.include?(p.name)
        entry = store[scene_sid(p)]
        next unless entry
        txt = entry['criticals']
        scene_crit[p.name] = txt.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?) unless txt.nil? || txt.to_s.strip.empty?
        cam = entry['camera']
        scene_cam[p.name] = cam.to_s unless cam.nil? || cam.to_s.strip.empty?
      end

      shared = {
        lighting:        config[:lighting]     || 'frio',
        environment:     config[:environment]  || 'feira',
        env_custom:      config[:env_custom]   || '',
        booth_type:      config[:booth_type]   || 'ilha',
        people:          config[:people],
        description:     config[:description]   || '',
        criticals_pt:    config[:criticals_pt] || [], # gerais (todas as cenas)
        scene_criticals: scene_crit,                   # específicos por cena
        scene_cameras:   scene_cam,                    # override de ângulo por cena
        # O EVA sempre gera prompt ancorado na imagem exportada (config[:image_mode]
        # não vem mais do HTML desde a simplificação do toggle "Texto puro"; default true).
        image_mode:      config.key?(:image_mode) ? !!config[:image_mode] : true
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

    # Executa um script PowerShell SEM piscar janela de console. `system` abre um
    # console (mesmo com -WindowStyle Hidden o conhost aparece por um instante);
    # o WScript.Shell.Run com estilo 0 roda totalmente oculto. Espera terminar
    # (bWaitOnReturn=true) e devolve true se o código de saída for 0.
    def self.run_ps_hidden(tmp_ps)
      cmd = "powershell -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"#{tmp_ps}\""
      require 'win32ole'
      shell = WIN32OLE.new('WScript.Shell')
      shell.Run(cmd, 0, true) == 0
    rescue
      system(cmd)
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
      ok = run_ps_hidden(tmp_ps)
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

    # ── Aba Logos: conta-gotas GLOBAL — captura a cor de QUALQUER pixel da tela ─
    # Funciona dentro do SketchUp OU em qualquer outro programa. Um processo
    # PowerShell fica em segundo plano aguardando o próximo clique (ou ESC) e lê
    # a cor do pixel sob o cursor. O SketchUp não trava: acompanhamos por timer.

    def self.start_color_pick
      out    = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_pick_#{Process.pid}.txt")
      tmp_ps = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_pick_#{Process.pid}.ps1")
      File.delete(out) rescue nil
      safe_out = out.gsub("'", "''")

      ps = <<~PS
        Add-Type -AssemblyName System.Drawing
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        public class EvaPick {
          [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
          [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
          [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
          public struct POINT { public int X; public int Y; }
        }
        "@
        [void][EvaPick]::SetProcessDPIAware()
        Start-Sleep -Milliseconds 350   # ignora o clique que abriu o modo
        $hex = 'CANCEL'
        while ($true) {
          if (([EvaPick]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) { break }   # ESC cancela
          if (([EvaPick]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0) {           # clique esquerdo
            $p = New-Object EvaPick+POINT
            [void][EvaPick]::GetCursorPos([ref]$p)
            $bmp = New-Object System.Drawing.Bitmap 1,1
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($p.X, $p.Y, 0, 0, (New-Object System.Drawing.Size 1,1))
            $c   = $bmp.GetPixel(0,0)
            $hex = ('{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
            $g.Dispose(); $bmp.Dispose()
            break
          }
          Start-Sleep -Milliseconds 20
        }
        [System.IO.File]::WriteAllText('#{safe_out}', $hex)
      PS

      File.write(tmp_ps, ps, encoding: 'UTF-8')
      # Lança em segundo plano (não bloqueia o SketchUp) e sem piscar console.
      Thread.new { run_ps_hidden(tmp_ps) }

      # Cancela um pick anterior ainda pendente (evita timer órfão).
      UI.stop_timer(@pick_timer) if @pick_timer
      ticks = 0
      @pick_timer = UI.start_timer(0.25, true) do
        ticks += 1
        done = File.exist?(out)
        # Timeout de segurança (~30s) caso o PowerShell não escreva o resultado.
        if done || ticks > 120
          UI.stop_timer(@pick_timer) rescue nil
          @pick_timer = nil
          val = done ? (File.read(out).strip rescue '') : ''
          File.delete(out) rescue nil
          File.delete(tmp_ps) rescue nil
          hex = (val =~ /\A#?[0-9A-Fa-f]{6}\z/) ? ('#' + val.delete('#').upcase) : nil
          report_picked_color(hex)
        end
      end
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
      ok = run_ps_hidden(tmp_ps)
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

    # ── Aba Logos: carrega imagem arrastada (drag-and-drop) ───────────────────
    # O HTML lê o arquivo solto como data URL base64 e manda pra cá; gravamos
    # num temp e devolvemos como se tivesse sido escolhido pelo seletor.

    def self.load_logo_data(msg)
      config = JSON.parse(msg)
      data   = config['data'].to_s
      raw    = config['name'].to_s
      base   = File.basename(raw, File.extname(raw))
      base   = 'logo' if base.strip.empty?
      base   = base.gsub(/[^a-z0-9\-_]/i, '_')
      ext    = data =~ %r{image/jpe?g} ? '.jpg' : '.png'
      b64    = data.sub(/\Adata:[^,]*,/, '')
      path   = File.join(ENV['TEMP'] || Dir.tmpdir, "eva_drop_#{base}#{ext}")
      File.binwrite(path, b64.unpack1('m0'))
      @dialog.execute_script("window.setLogoFile(#{path.to_json}, #{data.to_json})")
    rescue => e
      @dialog.execute_script("window.dropError(#{e.message.to_json})")
    end

    # ── Aba Estúdio: geração de render via API Gemini (Nano Banana) ───────────
    # Fluxo: captura a viewport da cena (PNG temp) → monta o prompt em modo
    # imagem → POST à API (imagem base64 + texto) via PowerShell em segundo
    # plano → resposta traz a imagem gerada em base64 → devolve ao HTML.

    def self.gemini_key_backup_file
      File.join(backup_dir, 'gemini_api_key.txt')
    end

    def self.save_gemini_key(key)
      k = key.to_s
      Sketchup.write_default(SETTINGS_KEY, 'gemini_api_key', k)
      File.open(gemini_key_backup_file, 'w:UTF-8') { |f| f.write(k) } rescue nil
    rescue
    end

    def self.read_gemini_key
      key = (Sketchup.read_default(SETTINGS_KEY, 'gemini_api_key', '').to_s rescue '')
      if key.empty? && File.file?(gemini_key_backup_file)
        key = (File.read(gemini_key_backup_file).to_s.strip rescue '')
        Sketchup.write_default(SETTINGS_KEY, 'gemini_api_key', key) unless key.empty?
      end
      key
    end

    # Captura a viewport de uma cena em PNG (câmera restaurada ao final).
    # Largura máx. 1600px, mantendo a proporção da viewport atual.
    def self.capture_scene_png(page, out_path)
      model = Sketchup.active_model
      view  = model.active_view
      orig  = view.camera
      w = 1600
      h = (w * view.vpheight.to_f / [view.vpwidth.to_f, 1].max).round
      begin
        view.camera = page.camera
        view.write_image(filename: out_path, width: w, height: h, antialias: true)
      ensure
        view.camera = orig
        view.invalidate
      end
      File.exist?(out_path)
    end

    def self.studio_generate(msg)
      config = JSON.parse(msg, symbolize_names: true)
      model  = Sketchup.active_model
      name   = config[:scene].to_s
      page   = model.pages.find { |p| p.name == name }
      api_key = read_gemini_key
      raise 'Informe a API key do Gemini.'    if api_key.strip.empty?
      raise 'Cena não encontrada.'            unless page

      # 1) Captura da viewport
      cap = File.join(ENV['TEMP'] || Dir.tmpdir, 'eva_studio_cap.png')
      File.delete(cap) rescue nil
      raise 'Falha ao capturar a viewport.' unless capture_scene_png(page, cap)
      @dialog.execute_script("window.studioOrig(#{image_data_url(cap).to_json})")

      # 2) Prompt em modo imagem (mesma lógica do build, uma cena)
      store = read_scene_store(model)
      entry = store[scene_sid(page)]
      per_scene = (entry && entry['criticals'].to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)) || []
      refs = (config[:refs] || []).select { |d| d.to_s.start_with?('data:image') }
      shared = {
        lighting:     config[:lighting]    || 'frio',
        environment:  config[:environment] || 'feira',
        env_custom:   config[:env_custom]  || '',
        booth_type:   config[:booth_type]  || 'ilha',
        people:       config[:people],
        description:  config[:description] || '',
        criticals_pt: (config[:criticals_pt] || []) + per_scene,
        page:         page,
        image_mode:   true,
        ref_count:    refs.size
      }
      prompt = PromptBuilder.build(shared)

      # 3) Chamada assíncrona à API (viewport + referências)
      gem_model = config[:model].to_s.strip
      gem_model = 'gemini-3.1-flash-image-preview' if gem_model.empty?
      call_gemini_async(api_key, gem_model, prompt, cap, refs)
    rescue => e
      @dialog.execute_script("window.studioDone(#{{ ok: false, error: e.message }.to_json})")
    end

    # refs = array de data URLs (imagens de referência opcionais). O body JSON é
    # montado no RUBY (texto + viewport + N referências) e gravado num arquivo; o
    # PowerShell só lê o arquivo e faz o POST — evita escapar JSON no PS e permite
    # número variável de imagens (o Nano Banana aceita várias inline_data).
    def self.call_gemini_async(api_key, gem_model, prompt, img_path, refs = [])
      base    = ENV['TEMP'] || Dir.tmpdir
      # Nomes ÚNICOS por execução: um run antigo (timeout) nunca contamina o
      # resultado do run atual, e o timer só enxerga os arquivos deste run.
      run      = "#{Process.pid}_#{(Time.now.to_f * 1000).to_i}"
      out      = File.join(base, "eva_studio_out_#{run}.png")
      err      = File.join(base, "eva_studio_err_#{run}.txt")
      bodyfile = File.join(base, "eva_studio_body_#{run}.json")
      tmp_ps   = File.join(base, "eva_studio_#{run}.ps1")

      # Monta as parts: texto + viewport + referências.
      parts = [{ text: prompt }]
      parts << { inline_data: { mime_type: 'image/png', data: [File.binread(img_path)].pack('m0') } }
      (refs || []).each do |durl|
        m = durl.to_s.match(%r{\Adata:(image/[a-zA-Z0-9.+\-]+);base64,(.+)\z}m)
        next unless m
        parts << { inline_data: { mime_type: m[1], data: m[2] } }
      end
      File.write(bodyfile, { contents: [{ parts: parts }] }.to_json, encoding: 'UTF-8')

      url = "https://generativelanguage.googleapis.com/v1beta/models/#{gem_model}:generateContent?key=#{api_key}"
      safe = ->(s) { s.gsub("'", "''") }

      ps = <<~PS
        Add-Type -AssemblyName System.Net.Http
        try {
          $body   = [System.IO.File]::ReadAllText('#{safe.call(bodyfile)}', [System.Text.Encoding]::UTF8)
          $client = [System.Net.Http.HttpClient]::new()
          $client.Timeout = [System.TimeSpan]::FromSeconds(180)
          $content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
          $resp = $client.PostAsync('#{safe.call(url)}', $content).GetAwaiter().GetResult()
          $rtxt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          if ($resp.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
            [System.IO.File]::WriteAllText('#{safe.call(err)}', [string]$resp.StatusCode + ': ' + $rtxt.Substring(0, [Math]::Min(800, $rtxt.Length)))
            exit 1
          }
          # Extrai o maior blob base64 da resposta por regex (evita o limite de
          # tamanho do ConvertFrom-Json no PS 5.1 com JSONs de varios MB).
          $m = [regex]::Matches($rtxt, '"data"\\s*:\\s*"([A-Za-z0-9+/=]{500,})"')
          if ($m.Count -eq 0) {
            [System.IO.File]::WriteAllText('#{safe.call(err)}', 'Resposta sem imagem: ' + $rtxt.Substring(0, [Math]::Min(800, $rtxt.Length)))
            exit 1
          }
          $best = ($m | Sort-Object { $_.Groups[1].Value.Length } -Descending)[0].Groups[1].Value
          # Escreve em .tmp e renomeia: o Ruby nunca lê um PNG pela metade.
          [System.IO.File]::WriteAllBytes('#{safe.call(out)}.tmp', [System.Convert]::FromBase64String($best))
          [System.IO.File]::Move('#{safe.call(out)}.tmp', '#{safe.call(out)}')
          exit 0
        } catch {
          [System.IO.File]::WriteAllText('#{safe.call(err)}', $_.Exception.Message)
          exit 1
        }
      PS
      File.write(tmp_ps, ps, encoding: 'UTF-8')
      Thread.new { run_ps_hidden(tmp_ps) }

      # Espera resultado por timer (sem travar a UI). Timeout ~3min.
      UI.stop_timer(@studio_timer) if @studio_timer
      ticks = 0
      @studio_timer = UI.start_timer(0.5, true) do
        ticks += 1
        done_ok  = File.exist?(out) && File.size(out).to_i > 0
        done_err = File.exist?(err)
        if done_ok || done_err || ticks > 380
          UI.stop_timer(@studio_timer) rescue nil
          @studio_timer = nil
          File.delete(tmp_ps)   rescue nil
          File.delete(bodyfile) rescue nil
          if done_ok
            data = image_data_url(out)
            @dialog.execute_script("window.studioDone(#{{ ok: true, path: out, data: data }.to_json})")
          else
            detail = done_err ? (File.read(err).to_s rescue '') : 'Tempo esgotado (3min).'
            File.delete(err) rescue nil
            @dialog.execute_script("window.studioDone(#{{ ok: false, error: parse_gemini_error(detail) }.to_json})")
          end
        end
      end
    end

    # Traduz erros comuns da API Gemini para PT.
    def self.parse_gemini_error(detail)
      d = detail.to_s
      return 'Falha na API. Verifique a key e o billing.'                if d.empty?
      return 'API key inválida. Confira em aistudio.google.com.'         if d =~ /API_KEY_INVALID|401|403|PERMISSION_DENIED/i
      return 'Cota/crédito esgotado ou billing não configurado.'          if d =~ /RESOURCE_EXHAUSTED|429|quota|billing/i
      return 'Modelo indisponível para esta key (tente o outro modelo).'  if d =~ /NOT_FOUND|404|not supported/i
      return 'Bloqueado por política de conteúdo — ajuste o prompt.'      if d =~ /SAFETY|blocked/i
      return 'Tempo de conexão esgotado. Verifique a internet.'           if d =~ /timeout|timed out|Tempo esgotado/i
      d.length > 200 ? (d[0, 200] + '…') : d
    end

    # Escolhe uma imagem de referência (openpanel) e devolve o data URL ao HTML.
    def self.choose_ref_image
      path = UI.openpanel('Imagem de referência', '', 'Imagens|*.png;*.jpg;*.jpeg||')
      return unless path
      @dialog.execute_script("window.addStudioRef(#{image_data_url(path).to_json})")
    end

    def self.save_studio_png(msg)
      config = JSON.parse(msg)
      src    = config['path'].to_s
      raise 'Nenhum render para salvar.' unless File.exist?(src)
      name = (config['name'].to_s.strip.empty? ? 'render' : config['name'].to_s).gsub(/[^a-z0-9\-_ ]/i, '_')
      dest = UI.savepanel('Salvar render', @last_logo_dir || '', "#{name}.png")
      return unless dest
      dest += '.png' unless dest.downcase.end_with?('.png')
      @last_logo_dir = File.dirname(dest)
      File.binwrite(dest, File.binread(src))
      @dialog.execute_script("window.saveStudioDone(#{{ ok: true, path: dest }.to_json})")
    rescue => e
      @dialog.execute_script("window.saveStudioDone(#{{ ok: false, error: e.message }.to_json})")
    end

    # ── Aba Logos: salva o PNG resultante numa pasta escolhida ────────────────

    def self.save_logo_png(msg)
      config = JSON.parse(msg)
      src    = config['path'].to_s
      name   = (config['name'].to_s.strip.empty? ? 'logo' : config['name'].to_s)
      raise 'Nenhuma imagem para salvar.' unless File.exist?(src)

      dest = UI.savepanel('Salvar PNG', @last_logo_dir || '', "#{name}.png")
      return unless dest
      dest += '.png' unless dest.downcase.end_with?('.png')
      @last_logo_dir = File.dirname(dest)
      File.binwrite(dest, File.binread(src))

      @dialog.execute_script("window.saveLogoDone(#{{ ok: true, path: dest }.to_json})")
    rescue => e
      @dialog.execute_script("window.saveLogoDone(#{{ ok: false, error: e.message }.to_json})")
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
