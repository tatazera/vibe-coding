# =============================================================================
# Stand1 Memorial Descritivo — core.rb v5.5.0
# =============================================================================

require 'sketchup.rb'
require 'json'
require 'fileutils'
require 'digest'
require_relative 'dimensoes'

module STAND1_Memorial

  POLEGADA_PARA_METRO = 0.0254
  POL2_PARA_M2        = 0.0254 * 0.0254

  # Apenas estas 6 tags são exportadas — na ordem correta
  SECOES_PERMITIDAS = [
    "ESTRUTURAS",
    "REVESTIMENTOS",
    "COMUNICAÇÃO VISUAL",
    "MOBILIÁRIO",
    "EQUIPAMENTOS",
    "ELÉTRICA"
  ]

  # Padrão de fábrica para Mobiliário — editável dentro do plugin
  PALAVRAS_MOBILIARIO_DEFAULT = [
    "mdf", "compensado", "alumínio", "aluminio", "metalon"
  ]

  def self.palavras_mobiliario
    json = Sketchup.read_default("STAND1_Memorial", "palavras_mobiliario", nil)
    json ? JSON.parse(json) : PALAVRAS_MOBILIARIO_DEFAULT.dup
  rescue
    PALAVRAS_MOBILIARIO_DEFAULT.dup
  end

  def self.salvar_palavras_mobiliario(lista)
    Sketchup.write_default("STAND1_Memorial", "palavras_mobiliario", lista.to_json)
  end

  # Palavras-chave para identificar fitas LED na seção Elétrica
  PALAVRAS_FITA_LED = ["fita led", "fita_led", "led cob", "led fita"]

  # Largura da fita LED (m) — usada para converter área da textura em metro linear.
  # metro linear = área da textura (um lado) ÷ largura. Editável no mini-painel.
  LARGURA_FITA_LED_DEFAULT = 0.02
  def self.largura_fita_led
    v = Sketchup.read_default("STAND1_Memorial", "largura_fita_led", nil)
    larg = v ? v.to_f : LARGURA_FITA_LED_DEFAULT
    larg > 0 ? larg : LARGURA_FITA_LED_DEFAULT
  rescue
    LARGURA_FITA_LED_DEFAULT
  end

  def self.salvar_largura_fita_led(valor)
    larg = valor.to_f
    larg = LARGURA_FITA_LED_DEFAULT if larg <= 0
    Sketchup.write_default("STAND1_Memorial", "largura_fita_led", larg)
  end

  # Padrão de fábrica — editável pelo usuário dentro do plugin
  PALAVRAS_LINEAR_DEFAULT = [
    "brise", "coluna", "ts", "pergola", "sanca",
    "ripa", "pilar", "viga", "vidro", "barrote"
  ]

  def self.palavras_linear_estrutural
    json = Sketchup.read_default("STAND1_Memorial", "palavras_linear", nil)
    json ? JSON.parse(json) : PALAVRAS_LINEAR_DEFAULT.dup
  rescue
    PALAVRAS_LINEAR_DEFAULT.dup
  end

  def self.salvar_palavras_linear(lista)
    Sketchup.write_default("STAND1_Memorial", "palavras_linear", lista.to_json)
  end

  # Padrão de fábrica — itens de ESTRUTURAS cujo m² é "metro linear × altura",
  # ou seja, projeção frontal = maior dimensão horizontal × altura. Editável no plugin.
  PALAVRAS_LINEAR_ALTURA_DEFAULT = [
    "parede", "sanca", "testeira", "mureta", "rodapé", "rodape"
  ]

  def self.palavras_linear_altura
    json = Sketchup.read_default("STAND1_Memorial", "palavras_linear_altura", nil)
    json ? JSON.parse(json) : PALAVRAS_LINEAR_ALTURA_DEFAULT.dup
  rescue
    PALAVRAS_LINEAR_ALTURA_DEFAULT.dup
  end

  def self.salvar_palavras_linear_altura(lista)
    Sketchup.write_default("STAND1_Memorial", "palavras_linear_altura", lista.to_json)
  end

  # ── TAGS PADRÃO STAND1 (integrado do plugin STAND1_Tags) ────────────────────
  NOME_GRUPO_TAGS = "0. Descritivo"
  TAGS_PADRAO = [
    { nome: "ESTRUTURAS",         cor: [43, 109, 184] },
    { nome: "REVESTIMENTOS",      cor: [52, 168, 83]  },
    { nome: "COMUNICAÇÃO VISUAL", cor: [234, 67, 53]  },
    { nome: "MOBILIÁRIO",         cor: [251, 188, 5]  },
    { nome: "EQUIPAMENTOS",       cor: [102, 60, 163] },
    { nome: "ELÉTRICA",           cor: [255, 109, 0]  },
    { nome: "LOCAÇÃO",            cor: [0, 188, 212]  },
    { nome: "REFERÊNCIA",         cor: [158, 158, 158] }
  ]

  # Cria as Tags padrão Stand1 no modelo ativo, agrupadas na pasta "0. Descritivo".
  # Tags existentes não são removidas (só têm a cor atualizada).
  def self.criar_tags_padrao
    model = Sketchup.active_model
    return UI.messagebox("Nenhum modelo aberto.") unless model

    suporta_folders = model.layers.respond_to?(:add_folder)
    criadas = []; existentes = []
    model.start_operation("Stand1 — Criar Tags", true)
    begin
      pasta = nil
      if suporta_folders
        pasta = model.layers.folders.find { |f| f.name == NOME_GRUPO_TAGS }
        pasta ||= model.layers.add_folder(NOME_GRUPO_TAGS)
        pasta.visible = true if pasta.respond_to?(:visible=)
      end

      TAGS_PADRAO.each do |cfg|
        layer = model.layers[cfg[:nome]]
        if layer
          existentes << cfg[:nome]
        else
          layer = model.layers.add(cfg[:nome])
          criadas << cfg[:nome]
        end
        layer.color = Sketchup::Color.new(*cfg[:cor])
        layer.visible = true
        if suporta_folders && pasta
          begin
            pasta.add_layer(layer) if layer.folder != pasta
          rescue
            # algumas versões usam API diferente para mover tag — ignora
          end
        end
      end

      model.commit_operation
    rescue => e
      model.abort_operation
      return UI.messagebox("Erro ao criar tags:\n#{e.message}")
    end

    # Pós-operação (não afeta o commit): abre painel de Tags e informa o resultado.
    Sketchup.send_action("showLayerManager:") rescue nil
    msg = "✅ Tags Stand1 prontas!\n\n"
    msg += "Criadas (#{criadas.length}): #{criadas.join(', ')}\n\n" unless criadas.empty?
    msg += "Já existiam (#{existentes.length}): #{existentes.join(', ')}\n\n" unless existentes.empty?
    msg += "Sem suporte a pastas de Tags (SketchUp < 2021): tags criadas soltas.\n" unless suporta_folders
    UI.messagebox(msg)
  end

  # Padrão de fábrica para Revestimentos automáticos — editável dentro do plugin.
  # Materiais do modelo cujo nome contém estas palavras entram automaticamente
  # na seção REVESTIMENTOS ao usar "Adicionar Tudo".
  PALAVRAS_REVESTIMENTO_DEFAULT = [
    "lona impressa", "napa", "pintura", "ripado"
  ]

  def self.palavras_revestimento
    json = Sketchup.read_default("STAND1_Memorial", "palavras_revestimento", nil)
    json ? JSON.parse(json) : PALAVRAS_REVESTIMENTO_DEFAULT.dup
  rescue
    PALAVRAS_REVESTIMENTO_DEFAULT.dup
  end

  def self.salvar_palavras_revestimento(lista)
    Sketchup.write_default("STAND1_Memorial", "palavras_revestimento", lista.to_json)
  end

  # ── PERSISTÊNCIA DE ESTADO (arquivo por projeto) ────────────────────────────

  @ultimo_estado_json = nil

  def self.pasta_estados
    dir = File.join(ENV['APPDATA'] || Dir.tmpdir, "STAND1_Memorial", "estados")
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    dir
  rescue
    Dir.tmpdir
  end

  def self.arquivo_estado(model)
    chave = if model && !model.path.to_s.strip.empty?
      Digest::MD5.hexdigest(model.path.downcase)
    else
      "untitled"
    end
    File.join(pasta_estados, "#{chave}.json")
  end

  def self.salvar_estado_arquivo(json, model)
    path = arquivo_estado(model)
    rotacionar_backup(path)
    File.open(path, "w:UTF-8") { |f| f.write(json) }
    # também salva nos atributos do modelo (backup para modelos salvos)
    model.set_attribute("STAND1_Memorial", "estado_memorial", json) if model
  rescue => e
    # silently ignore file errors; try model attribute only
    model.set_attribute("STAND1_Memorial", "estado_memorial", json) rescue nil
  end

  # Mantém até 5 backups (.bak1 mais recente … .bak5 mais antigo).
  # Rotaciona no máximo a cada 10 min para não encher de cópias quase idênticas.
  def self.rotacionar_backup(path)
    return unless File.exist?(path)
    bak1 = "#{path}.bak1"
    return if File.exist?(bak1) && (Time.now - File.mtime(bak1)) < 600
    4.downto(1) do |i|
      de = "#{path}.bak#{i}"
      FileUtils.mv(de, "#{path}.bak#{i + 1}") if File.exist?(de)
    end
    FileUtils.cp(path, bak1)
  rescue
    # backup é melhor-esforço; nunca impede o salvamento principal
  end

  def self.carregar_estado_arquivo(model)
    # tenta arquivo primeiro (não depende de o SKP estar salvo)
    path = arquivo_estado(model)
    if File.exist?(path)
      conteudo = File.read(path, encoding: 'utf-8')
      return conteudo unless conteudo.strip.empty?
    end
    # fallback: atributo do modelo
    model ? model.get_attribute("STAND1_Memorial", "estado_memorial", nil) : nil
  rescue
    model ? model.get_attribute("STAND1_Memorial", "estado_memorial", nil) : nil
  end

  # ── DIALOG ──────────────────────────────────────────────────────────────────

  @dialog = nil

  def self.abrir_dialog
    model = Sketchup.active_model
    unless model
      UI.messagebox("Nenhum modelo aberto.")
      return
    end

    if @dialog && @dialog.visible?
      @dialog.bring_to_front
      return
    end

    html_path = File.join(__dir__, 'dialog.html')
    unless File.exist?(html_path)
      UI.messagebox("Arquivo dialog.html não encontrado em:\n#{__dir__}")
      return
    end

    @dialog = UI::HtmlDialog.new(
      dialog_title:    "STAND1_Memorial",
      preferences_key: "STAND1_Memorial",
      width:           940,
      height:          720,
      min_width:       700,
      min_height:      500,
      resizable:       true
    )

    @dialog.set_file(html_path)

    # Interface abre VAZIA — o usuário escolhe como carregar
    @dialog.add_action_callback("dialog_pronto") do |_ctx|
      nome_arquivo = nome_do_arquivo(model)
      @dialog.execute_script("definirNomeArquivo('#{nome_arquivo.gsub("'","\\\\'")}')") rescue nil
      lista_lin = palavras_linear_estrutural.to_json
      @dialog.execute_script("definirPalavrasLinear(#{lista_lin})") rescue nil
      lista_lin_alt = palavras_linear_altura.to_json
      @dialog.execute_script("definirPalavrasLinearAltura(#{lista_lin_alt})") rescue nil
      lista_mob = palavras_mobiliario.to_json
      @dialog.execute_script("definirPalavrasMobiliario(#{lista_mob})") rescue nil
      lista_rev = palavras_revestimento.to_json
      @dialog.execute_script("definirPalavrasRevestimento(#{lista_rev})") rescue nil
      @dialog.execute_script("definirLarguraFita(#{largura_fita_led})") rescue nil
      tema = Sketchup.read_default("STAND1_Memorial", "tema_dark", "0")
      @dialog.execute_script("definirTema(#{tema == '1' ? 'true' : 'false'})") rescue nil
      # Restaurar estado salvo (arquivo AppData ou atributo do modelo)
      estado_json = carregar_estado_arquivo(model)
      if estado_json && !estado_json.strip.empty?
        begin
          parsed = JSON.parse(estado_json)
          @dialog.execute_script("restaurarEstado(#{parsed.to_json})")
        rescue => e
          # JSON inválido — ignora e abre em branco
        end
      end
    end

    @dialog.add_action_callback("salvar_estado") do |_ctx, json|
      @ultimo_estado_json = json
      salvar_estado_arquivo(json, model)
    end

    @dialog.set_on_closed do
      # garante persistência mesmo se o diálogo for fechado de forma inesperada
      if @ultimo_estado_json
        salvar_estado_arquivo(@ultimo_estado_json, Sketchup.active_model)
      end
    end

    @dialog.add_action_callback("salvar_palavras_linear") do |_ctx, json_lista|
      salvar_palavras_linear(JSON.parse(json_lista))
    end

    @dialog.add_action_callback("salvar_palavras_linear_altura") do |_ctx, json_lista|
      salvar_palavras_linear_altura(JSON.parse(json_lista))
    end

    @dialog.add_action_callback("salvar_palavras_mobiliario") do |_ctx, json_lista|
      salvar_palavras_mobiliario(JSON.parse(json_lista))
    end

    @dialog.add_action_callback("salvar_palavras_revestimento") do |_ctx, json_lista|
      salvar_palavras_revestimento(JSON.parse(json_lista))
    end

    @dialog.add_action_callback("salvar_tema") do |_ctx, dark|
      Sketchup.write_default("STAND1_Memorial", "tema_dark", dark ? "1" : "0")
    end

    @dialog.add_action_callback("salvar_largura_fita") do |_ctx, valor|
      salvar_largura_fita_led(valor)
    end

    # Carregar TUDO automaticamente (lê todas as tags)
    @dialog.add_action_callback("carregar_tudo") do |_ctx|
      model_atual = Sketchup.active_model
      if model_atual
        dados = coletar_dados(model_atual)
        nome  = nome_do_arquivo(model_atual)
        payload = { secoes: dados, nome_arquivo: nome }.to_json
        @dialog.execute_script("carregarDados(#{payload})")
        reenviar_listas
      end
    end

    # Carregar somente a SELEÇÃO atual do modelo (ACUMULA com dados existentes)
    @dialog.add_action_callback("carregar_selecao") do |_ctx|
      model_atual = Sketchup.active_model
      if model_atual
        sel = model_atual.selection
        if sel.empty?
          @dialog.execute_script("alertaSemSelecao()")
        else
          dados = coletar_dados_selecao(model_atual, sel)
          nome  = nome_do_arquivo(model_atual)
          payload = { secoes: dados, nome_arquivo: nome }.to_json
          @dialog.execute_script("adicionarDados(#{payload})")
          reenviar_listas
        end
      end
    end

    # Atualizar manualmente (re-lê usando o último modo)
    @dialog.add_action_callback("atualizar") do |_ctx|
      enviar_atualizacao
    end

    # Selecionar componente no modelo (lupa)
    @dialog.add_action_callback("selecionar_item") do |_ctx, chave_item|
      selecionar_componente_no_modelo(chave_item)
    end

    # Exportar TXT
    @dialog.add_action_callback("exportar_txt") do |_ctx, texto_memorial, nome_sug|
      exportar_arquivo_txt(texto_memorial, nome_sug)
    end

    # Listar materiais para seleção pelo usuário
    @dialog.add_action_callback("listar_revestimentos") do |_ctx|
      model = Sketchup.active_model
      if model
        lista = listar_materiais_revestimentos(model)
        @dialog.execute_script("mostrarPainelRevestimentos(#{lista.to_json})")
      end
    end

    # Exportar PDF via Edge/Chrome headless (recebe HTML completo do JS)
    @dialog.add_action_callback("exportar_pdf_direto") do |_ctx, html_conteudo, nome_sug|
      exportar_pdf_headless(html_conteudo, nome_sug)
    end

    @dialog.add_action_callback("copiar_clipboard") do |_ctx, texto|
      copiar_para_clipboard(texto)
    end

    @dialog.add_action_callback("criar_tags") do |_ctx|
      criar_tags_padrao
    end

    @dialog.add_action_callback("fechar") do |_ctx|
      @dialog.close
    end

    @dialog.set_on_closed do
      @dialog = nil
    end

    @dialog.show
  end

  # ── ATUALIZAÇÃO MANUAL ──────────────────────────────────────────────────────

  @ultimo_modo = :tudo  # :tudo ou :selecao

  def self.enviar_atualizacao
    return unless @dialog && @dialog.visible?
    model = Sketchup.active_model
    return unless model

    if @ultimo_modo == :selecao && !model.selection.empty?
      dados = coletar_dados_selecao(model, model.selection)
    else
      dados = coletar_dados(model)
    end

    nome = nome_do_arquivo(model)
    payload = { secoes: dados, nome_arquivo: nome }.to_json
    @dialog.execute_script("atualizarDados(#{payload})")
    reenviar_listas
  end

  # Reenvia as listas de palavras-chave salvas para a interface após cada scan,
  # garantindo que elas nunca "sumam" ao rodar Adicionar Tudo/Atualizar.
  def self.reenviar_listas
    return unless @dialog
    @dialog.execute_script("definirPalavrasLinear(#{palavras_linear_estrutural.to_json})") rescue nil
    @dialog.execute_script("definirPalavrasLinearAltura(#{palavras_linear_altura.to_json})") rescue nil
    @dialog.execute_script("definirPalavrasMobiliario(#{palavras_mobiliario.to_json})") rescue nil
    @dialog.execute_script("definirPalavrasRevestimento(#{palavras_revestimento.to_json})") rescue nil
    @dialog.execute_script("definirLarguraFita(#{largura_fita_led})") rescue nil
  end

  # ── EXPORTAR PDF HEADLESS ────────────────────────────────────────────────────

  BROWSER_PATHS = [
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe'
  ].freeze

  def self.exportar_pdf_headless(html_conteudo, nome_sug = nil)
    unless nome_sug && !nome_sug.strip.empty?
      model     = Sketchup.active_model
      nome_base = model ? nome_do_arquivo(model).gsub(/\s+/, '_') : "Memorial"
      nome_sug  = "Memorial_#{nome_base}_Stand1.pdf"
    end

    destino = UI.savepanel("Salvar PDF", "", nome_sug)
    return unless destino

    destino = destino.gsub('/', '\\')
    destino += ".pdf" unless destino.end_with?(".pdf", ".PDF")

    tmp_html = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "stand1_memorial_tmp.html")
    File.write(tmp_html, html_conteudo, encoding: 'utf-8')

    browser = BROWSER_PATHS.find { |p| File.exist?(p) }
    unless browser
      UI.messagebox("Edge ou Chrome não encontrado.\nInstale o Microsoft Edge para exportar PDF diretamente.")
      return
    end

    tmp_html_uri = "file:///#{tmp_html.gsub('\\', '/')}"
    # --headless=new: novo headless do Edge/Chrome, que NÃO imprime cabeçalho/rodapé
    # (URL + nº da página) — o flag --print-to-pdf-no-header é ignorado no headless antigo.
    cmd = "\"#{browser}\" --headless=new --disable-gpu --no-sandbox" \
          " --print-to-pdf=\"#{destino}\"" \
          " --print-to-pdf-no-header --no-pdf-header-footer \"#{tmp_html_uri}\""

    result = system(cmd)

    # Fallback: se o novo headless falhar (Edge muito antigo), tenta o headless clássico.
    unless result && File.exist?(destino)
      cmd_old = "\"#{browser}\" --headless --disable-gpu --no-sandbox" \
                " --print-to-pdf=\"#{destino}\"" \
                " --print-to-pdf-no-header \"#{tmp_html_uri}\""
      result = system(cmd_old)
    end

    File.delete(tmp_html) rescue nil

    if result && File.exist?(destino)
      UI.messagebox("PDF salvo em:\n#{destino}")
    else
      UI.messagebox("Falha ao gerar o PDF.\nVerifique se o Edge está instalado e tente novamente.")
    end
  end

  # ── EXPORTAR TXT ─────────────────────────────────────────────────────────────

  def self.exportar_arquivo_txt(texto, nome_sugerido = nil)
    unless nome_sugerido && !nome_sugerido.strip.empty?
      model = Sketchup.active_model
      nome_modelo = model ? nome_do_arquivo(model) : "Memorial"
      nome_sugerido = "Memorial_#{nome_modelo.gsub(/\s+/, '_')}.txt"
    end

    caminho = UI.savepanel("Salvar Memorial como TXT", "", nome_sugerido)
    return unless caminho

    caminho += ".txt" unless caminho.downcase.end_with?(".txt")

    begin
      File.open(caminho, "w:UTF-8") do |f|
        f.write(texto)
      end
      UI.messagebox("Memorial exportado com sucesso!\n\n#{caminho}")
    rescue => e
      UI.messagebox("Erro ao exportar:\n#{e.message}")
    end
  end

  # ── COPIAR PARA A ÁREA DE TRANSFERÊNCIA ─────────────────────────────────────
  # Escreve o texto no clipboard do Windows preservando acentos e ² (UTF-8 → Set-Clipboard).
  def self.copiar_para_clipboard(texto)
    tmp = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "stand1_memorial_clip.txt")
    File.write(tmp, texto.to_s, encoding: 'utf-8')
    ps = "Get-Content -LiteralPath '#{tmp}' -Raw -Encoding UTF8 | Set-Clipboard"
    system("powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps)
    File.delete(tmp) rescue nil
  rescue => e
    UI.messagebox("Não foi possível copiar:\n#{e.message}")
  end

  # ── SELEÇÃO DE COMPONENTE NO MODELO (LUPA) ──────────────────────────────────

  def self.selecionar_componente_no_modelo(chave_item)
    model = Sketchup.active_model
    return unless model

    # Itens agrupados por nome (MOBILIÁRIO/ELÉTRICA): chave "grp__nome" → seleciona
    # todas as instâncias com aquele nome (qualquer tamanho).
    if chave_item.to_s.start_with?("grp__")
      nome_alvo = chave_item.to_s.sub("grp__", "")
      encontrados = []
      procurar_por_nome(model.entities, nome_alvo, encontrados)
      if encontrados.empty?
        UI.messagebox("Componente não encontrado no modelo:\n\n#{nome_alvo}")
        return
      end
      model.selection.clear
      model.selection.add(encontrados)
      bounds = Geom::BoundingBox.new
      encontrados.each { |e| bounds.add(e.bounds) }
      model.active_view.zoom(bounds)
      Sketchup.status_text = "STAND1: #{encontrados.size} componente(s) '#{nome_alvo}' selecionado(s)"
      return
    end

    partes = chave_item.to_s.split("__")
    return if partes.size < 4

    nome_alvo    = partes[0]
    largura_alvo = partes[1].to_f
    profund_alvo = partes[2].to_f
    altura_alvo  = partes[3].to_f

    encontrados = []
    procurar_componente(model.entities, nome_alvo,
                        largura_alvo, profund_alvo, altura_alvo,
                        encontrados)

    if encontrados.empty?
      UI.messagebox("Componente não encontrado no modelo:\n\n#{nome_alvo}")
      return
    end

    model.selection.clear
    model.selection.add(encontrados)

    view = model.active_view
    bounds = Geom::BoundingBox.new
    encontrados.each { |e| bounds.add(e.bounds) }
    view.zoom(bounds)

    Sketchup.status_text = "STAND1: #{encontrados.size} componente(s) '#{nome_alvo}' selecionado(s)"
  end

  def self.procurar_componente(entities, nome_alvo, l_alvo, p_alvo, a_alvo, resultado, tr_pai = nil)
    entities.each do |ent|
      if ent.is_a?(Sketchup::ComponentInstance)
        nome = ent.definition.name
        # mesma fonte de dimensões do memorial — as chaves batem
        dims = dimensoes_reais(ent, tr_pai)
        _ck = [dims[:largura], dims[:profund], dims[:altura]].sort.reverse
        l   = _ck[0]
        p   = _ck[1]
        a   = _ck[2]

        if nome == nome_alvo && (l - l_alvo).abs < 0.01 &&
                                 (p - p_alvo).abs < 0.01 &&
                                 (a - a_alvo).abs < 0.01
          resultado << ent
        end

        unless resultado.include?(ent)
          tr = tr_pai ? tr_pai * ent.transformation : ent.transformation
          procurar_componente(ent.definition.entities, nome_alvo, l_alvo, p_alvo, a_alvo, resultado, tr)
        end

      elsif ent.is_a?(Sketchup::Group)
        tr = tr_pai ? tr_pai * ent.transformation : ent.transformation
        procurar_componente(ent.entities, nome_alvo, l_alvo, p_alvo, a_alvo, resultado, tr)
      end
    end
  end

  # Busca instâncias por nome (qualquer dimensão) — para itens agrupados por nome.
  def self.procurar_por_nome(entities, nome_alvo, resultado)
    nome_lc = nome_alvo.to_s.downcase
    entities.each do |ent|
      if ent.is_a?(Sketchup::ComponentInstance)
        if ent.definition.name.to_s.downcase == nome_lc
          resultado << ent
        else
          procurar_por_nome(ent.definition.entities, nome_alvo, resultado)
        end
      elsif ent.is_a?(Sketchup::Group)
        procurar_por_nome(ent.entities, nome_alvo, resultado)
      end
    end
  end

  # ── NOME DO ARQUIVO .SKP ─────────────────────────────────────────────────────

  def self.nome_do_arquivo(model)
    path = model.path
    (path && !path.empty?) ? File.basename(path, ".skp") : "Novo Modelo"
  end

  # ── COLETA DE DADOS (TUDO) ─────────────────────────────────────────────────

  def self.coletar_dados(model)
    @ultimo_modo = :tudo
    secoes_raw = {}
    SECOES_PERMITIDAS.each { |s| secoes_raw[s] = {} }

    model.entities.each do |ent|
      processar_entidade(ent, secoes_raw)
    end

    # Revestimentos automáticos por palavra-chave (não substitui o fluxo manual
    # nem os componentes com tag REVESTIMENTOS — só complementa)
    adicionar_revestimentos_auto(model, secoes_raw)

    # Fita LED automática: lê a textura "Fita LED" no modelo (mesmo sem tag) e
    # adiciona em ELÉTRICA como metro linear (área ÷ largura).
    adicionar_fita_led_auto(model, secoes_raw)

    montar_resultado(secoes_raw)
  end

  # Varre os materiais do modelo e adiciona à seção REVESTIMENTOS os que casam
  # com as palavras-chave configuradas. Usa a mesma chave do fluxo por tag
  # (rev_mat__nome) — se o material já entrou via componente taggeado, não duplica.
  def self.adicionar_revestimentos_auto(model, secoes_raw)
    kws = palavras_revestimento.map { |k| k.to_s.downcase }.reject(&:empty?)
    return if kws.empty?

    listar_materiais_revestimentos(model).each do |m|
      nome = m["nome"].to_s
      next unless kws.any? { |kw| nome.downcase.include?(kw) }

      chave = "rev_mat__#{nome}"
      next if secoes_raw["REVESTIMENTOS"][chave]

      secoes_raw["REVESTIMENTOS"][chave] = {
        nome:          nome,
        material_id:   nome,
        area_material: m["area"],
        quantidade:    1,
        chave:         chave
      }
    end
  end

  # Varre os materiais do modelo procurando a textura de Fita LED (pelo nome) e
  # adiciona um item em ELÉTRICA em metro linear = área da textura ÷ largura.
  # Funciona mesmo sem o componente estar tagueado (a fita é só textura).
  def self.adicionar_fita_led_auto(model, secoes_raw)
    larg = largura_fita_led
    return if larg <= 0

    area_total = 0.0
    listar_materiais_revestimentos(model).each do |m|
      nome = m["nome"].to_s.downcase
      area_total += m["area"].to_f if PALAVRAS_FITA_LED.any? { |kw| nome.include?(kw) }
    end
    return if area_total <= 0

    metros = (area_total / larg).round(2)
    chave  = "fita_led_auto"
    return if secoes_raw["ELÉTRICA"][chave]

    secoes_raw["ELÉTRICA"][chave] = {
      nome:               "Fita LED",
      largura:            0.0,
      profund:            0.0,
      altura:             0.0,
      area_face_frontal:  0.0,
      area_material:      area_total.round(2),
      comprimento_linear: metros,
      metros_fita:        metros,
      quantidade:         1,
      chave:              chave
    }
  end

  # ── COLETA DE DADOS (SELEÇÃO) ──────────────────────────────────────────────

  def self.coletar_dados_selecao(model, selection)
    @ultimo_modo = :selecao
    secoes_raw = {}
    SECOES_PERMITIDAS.each { |s| secoes_raw[s] = {} }

    selection.each do |ent|
      processar_entidade(ent, secoes_raw)
    end

    montar_resultado(secoes_raw)
  end

  def self.montar_resultado(secoes_raw)
    resultado = []
    SECOES_PERMITIDAS.each do |nome_secao|
      itens = secoes_raw[nome_secao]
      next if itens.nil? || itens.empty?

      resultado << {
        "secao" => nome_secao,
        "itens" => itens.values
          .sort_by { |item| item[:nome].to_s.downcase }
          .map { |item|
            formatado = formatar_item(item, nome_secao)
            formatado["chave"] = item[:chave]
            formatado
          }
      }
    end
    resultado
  end

  # ── PROCESSAMENTO DE ENTIDADES ─────────────────────────────────────────────

  def self.processar_entidade(entidade, secoes_raw, tag_herdada = nil, tr_pai = nil)
    # Layer própria tem prioridade; Untagged/Layer0 herda do pai
    tag_propria = entidade.layer&.name || ""
    tag_nome    = (tag_propria != "" && tag_propria != "Untagged" && tag_propria != "Layer0") \
                  ? tag_propria : (tag_herdada || "")
    tag_upper   = tag_nome.upcase

    secao_match = SECOES_PERMITIDAS.find { |s| tag_upper == s.upcase }

    if entidade.is_a?(Sketchup::ComponentInstance)
      if secao_match
        adicionar_componente(entidade, secao_match, secoes_raw, tr_pai)
      else
        # acumula a transformação do pai (decisão 4: escala de pais aninhados)
        tr = tr_pai ? tr_pai * entidade.transformation : entidade.transformation
        entidade.definition.entities.each do |sub|
          processar_entidade(sub, secoes_raw, tag_nome, tr)
        end
      end

    elsif entidade.is_a?(Sketchup::Group)
      tr = tr_pai ? tr_pai * entidade.transformation : entidade.transformation
      entidade.entities.each do |sub|
        processar_entidade(sub, secoes_raw, tag_nome, tr)
      end
    end
  end

  # Ponte SketchUp → módulo puro de dimensões.
  # Usa definition.bounds (dims reais da peça) + transformação composta,
  # nunca inst.bounds (caixa do mundo, que infla peças rotacionadas).
  # API SketchUp: BoundingBox#width = X, #height = Y, #depth = Z.
  def self.dimensoes_reais(inst, tr_pai = nil)
    tr = tr_pai ? tr_pai * inst.transformation : inst.transformation
    db = inst.definition.bounds
    dims_locais = [db.width.to_f, db.height.to_f, db.depth.to_f]

    m = tr.to_a
    eixos = [
      [m[0], m[1], m[2]],
      [m[4], m[5], m[6]],
      [m[8], m[9], m[10]]
    ]

    d = Dimensoes.calcular(eixos, dims_locais)
    {
      largura: Dimensoes.metro(d[:largura]),
      profund: Dimensoes.metro(d[:profund]),
      altura:  Dimensoes.metro(d[:altura])
    }
  end

  def self.adicionar_componente(inst, secao, secoes_raw, tr_pai = nil)
    nome = inst.definition.name
    nome = "Componente sem nome" if nome.nil? || nome.strip.empty?

    dims    = dimensoes_reais(inst, tr_pai)
    largura = dims[:largura]   # maior horizontal
    profund = dims[:profund]   # menor horizontal
    altura  = dims[:altura]    # eixo mais vertical (Z) — sempre por último

    # Chave: dims ordenadas — agrupa a mesma peça em qualquer orientação/espelho
    chave_dims = Dimensoes.chave_dims(largura, profund, altura)
    _ck = [largura, profund, altura].sort.reverse

    eh_piso = secao == "ESTRUTURAS" && nome.downcase.include?("piso")

    area_face_frontal = if secao == "COMUNICAÇÃO VISUAL"
      # CV mantém "2 maiores dimensões" (lonas/logos: espessura é a menor dim)
      (_ck[0] * _ck[1]).round(2)
    elsif secao == "ESTRUTURAS"
      if eh_piso
        # Piso (5B): projeção horizontal = largura × profundidade reais (prioridade)
        (largura * profund).round(2)
      else
        # m² = tudo que está revestido: soma as faces com material de revestimento
        # (geometria real, uma por plano, escala aplicada). Lida com salas, paredes
        # em L, depósitos, backdrops revestidos — identifica pelas faces pintadas.
        a_rev = area_faces_revestidas_m2(inst, tr_pai)
        if a_rev > 0
          a_rev
        elsif palavras_linear_altura.any? { |kw| nome.downcase.include?(kw) }
          # Sem revestimento detectado, mas é peça linear (parede/sanca): L × altura.
          (largura * altura).round(2)
        else
          # Sem revestimento e não-linear: superfície total das faces (comportamento antigo).
          area_total_faces_m2(inst)
        end
      end
    else
      (largura * altura).round(2)
    end
    area_material = calcular_area_material(inst).round(2)
    comprimento_linear = [largura, profund, altura].max

    # ── REVESTIMENTOS: agrupa por ID do MATERIAL (não por componente) ──
    if secao == "REVESTIMENTOS"
      area_por_mat = calcular_area_por_material(inst)

      if area_por_mat.empty?
        # Nenhum material encontrado → usa o nome do componente como fallback
        chave = "rev_#{nome}__sem_material"
        area_fb = (largura * profund).round(2)
        if secoes_raw[secao][chave]
          secoes_raw[secao][chave][:quantidade] += 1
          secoes_raw[secao][chave][:area_material] += area_fb
        else
          secoes_raw[secao][chave] = {
            nome:          nome,
            material_id:   "Sem material",
            area_material: area_fb,
            quantidade:    1,
            chave:         chave
          }
        end
      else
        # Um item por material encontrado
        area_por_mat.each do |mat_nome, mat_area|
          chave = "rev_mat__#{mat_nome}"
          if secoes_raw[secao][chave]
            secoes_raw[secao][chave][:area_material] += mat_area
            secoes_raw[secao][chave][:quantidade] += 1
          else
            secoes_raw[secao][chave] = {
              nome:          mat_nome,
              material_id:   mat_nome,
              area_material: mat_area,
              quantidade:    1,
              chave:         chave
            }
          end
        end
      end
      return
    end

    # ── FITA LED (ELÉTRICA): metro linear = área da textura (um lado) ÷ largura ──
    eh_fita = secao == "ELÉTRICA" && PALAVRAS_FITA_LED.any? { |kw| nome.downcase.include?(kw) }
    metros_fita = 0.0
    if eh_fita
      area_tex = area_faces_material_m2(inst, tr_pai)  # qualquer face com textura
      metros_fita = (area_tex / largura_fita_led).round(2) if area_tex > 0
    end

    # ── AGRUPAMENTO ──
    # MOBILIÁRIO e ELÉTRICA agrupam só pelo NOME (medida = 1ª peça com aquele nome).
    # Demais seções agrupam por nome + dimensões (tamanhos diferentes = linhas distintas).
    chave = if ["MOBILIÁRIO", "ELÉTRICA"].include?(secao)
      "grp__#{nome.downcase}"
    else
      "#{nome}__#{chave_dims}"
    end

    if secoes_raw[secao][chave]
      secoes_raw[secao][chave][:quantidade] += 1
      # Fita LED: soma o comprimento real de cada instância
      secoes_raw[secao][chave][:metros_fita] += metros_fita if eh_fita
    else
      secoes_raw[secao][chave] = {
        nome:               nome,
        largura:            largura,
        profund:            profund,
        altura:             altura,
        area_face_frontal:  area_face_frontal,
        area_material:      area_material,
        comprimento_linear: comprimento_linear,
        metros_fita:        metros_fita,
        quantidade:         1,
        chave:              chave
      }
    end
  end

  # ── CÁLCULO DE ÁREA (m²) A PARTIR DAS TEXTURAS/MATERIAIS ──────────────────

  # Retorna a área total de todas as faces com material (recursivo)
  def self.calcular_area_material(inst)
    total = 0.0
    mat_instancia = inst.material
    inst.definition.entities.each do |ent|
      total += somar_area_entidade(ent, mat_instancia)
    end
    total.round(2)
  end

  # Retorna hash { "nome_material" => area_m2 } agrupado por material
  # Leva em conta:
  #   1) Material da instância do componente (aplicado no exterior)
  #   2) Material aplicado diretamente nas faces internas
  #   3) Materiais em grupos/componentes aninhados
  def self.calcular_area_por_material(inst)
    materiais_pol2 = Hash.new(0.0)
    mat_instancia = inst.material

    coletar_materiais_recursivo(inst.definition.entities, mat_instancia, materiais_pol2)

    # Converte polegadas² → m² e arredonda
    resultado = {}
    materiais_pol2.each do |nome, area_pol2|
      resultado[nome] = (area_pol2 * POL2_PARA_M2).round(2)
    end
    resultado
  end

  def self.somar_area_entidade(ent, mat_herdado)
    total = 0.0
    if ent.is_a?(Sketchup::Face)
      mat = ent.material || ent.back_material || mat_herdado
      total += ent.area * POL2_PARA_M2 if mat
    elsif ent.is_a?(Sketchup::Group)
      mat_grupo = ent.material || mat_herdado
      ent.entities.each { |sub| total += somar_area_entidade(sub, mat_grupo) }
    elsif ent.is_a?(Sketchup::ComponentInstance)
      mat_comp = ent.material || mat_herdado
      ent.definition.entities.each { |sub| total += somar_area_entidade(sub, mat_comp) }
    end
    total
  end

  def self.coletar_materiais_recursivo(entities, mat_herdado, resultado)
    entities.each do |ent|
      if ent.is_a?(Sketchup::Face)
        # Conta todas as faces pintadas: material da face (front), ou verso, ou
        # herdado da instância/grupo pai.
        mat = ent.material || ent.back_material || mat_herdado
        if mat
          nome = mat.respond_to?(:display_name) ? mat.display_name : mat.name
          resultado[nome] += ent.area
        end
      elsif ent.is_a?(Sketchup::Group)
        mat_grupo = ent.material || mat_herdado
        coletar_materiais_recursivo(ent.entities, mat_grupo, resultado)
      elsif ent.is_a?(Sketchup::ComponentInstance)
        mat_comp = ent.material || mat_herdado
        coletar_materiais_recursivo(ent.definition.entities, mat_comp, resultado)
      end
    end
  end

  # ── FORMATAÇÃO POR SEÇÃO ─────────────────────────────────────────────────────

  # Toda medida exibida com 2 casas decimais: 5.00, 50.00, 500.00
  def self.fmt(v)
    format('%.2f', v.to_f)
  end

  def self.formatar_item(item, secao)
    nome  = item[:nome]
    l     = item[:largura]
    p     = item[:profund]
    a     = item[:altura]
    qtd   = item[:quantidade]
    af    = item[:area_face_frontal]
    am    = item[:area_material]
    comp  = item[:comprimento_linear]
    nome_lower = nome.downcase

    case secao

    # ESTRUTURAS: piso só L×P (horizontais); linear = 2 maiores dims (7B); demais = L×P×A
    when "ESTRUTURAS"
      eh_piso   = nome_lower.include?("piso")
      eh_linear = palavras_linear_estrutural.any? { |kw| nome_lower.include?(kw) }
      if eh_piso
        desc = "#{nome} (#{fmt(l)}m x #{fmt(p)}m) - #{fmt(af)}m²"
      elsif eh_linear
        d1, d2 = Dimensoes.dims_lineares(l, p, a)
        desc = "#{nome} (#{fmt(d1)}m x #{fmt(d2)}m) - #{fmt(af)}m²"
      else
        desc = "#{nome} (#{fmt(l)}m x #{fmt(p)}m x #{fmt(a)}m) - #{fmt(af)}m²"
      end
      build_item(desc, qtd, "und.")

    # REVESTIMENTOS: Nome do Material (ID da textura) + m² + und.
    when "REVESTIMENTOS"
      mat_id = item[:material_id] || ""
      area   = (item[:area_material] || 0.0).round(2)
      if !mat_id.empty? && mat_id != "Sem material"
        desc = "#{mat_id} - #{fmt(area)}m²"
      else
        desc = "#{nome} - #{fmt(area)}m²"
      end
      build_item(desc, qtd, "und.")

    # COMUNICAÇÃO VISUAL: L x A (bounding box) + área real da maior face
    when "COMUNICAÇÃO VISUAL"
      d1, d2, _esp = [l, p, a].sort.reverse
      desc = "#{nome} (#{fmt(d1)}m x #{fmt(d2)}m) - #{fmt(af)}m²"
      build_item(desc, qtd, "und.")

    # MOBILIÁRIO: mostra dimensões apenas para itens com palavras-chave configuradas
    when "MOBILIÁRIO"
      tem = palavras_mobiliario.any? { |kw| nome_lower.include?(kw) }
      desc = tem ? "#{nome} (#{fmt(l)}m x #{fmt(p)}m x #{fmt(a)}m)" : nome
      build_item(desc, qtd, "und.")

    # EQUIPAMENTOS: apenas nome + quantidade
    when "EQUIPAMENTOS"
      build_item(nome, qtd, "und.")

    # ELÉTRICA: fitas LED em metro linear (área da textura ÷ largura), demais em und.
    when "ELÉTRICA"
      eh_fita = PALAVRAS_FITA_LED.any? { |kw| nome_lower.include?(kw) }
      if eh_fita
        total_m = (item[:metros_fita] || 0.0).round(2)
        total_m = (comp * qtd).round(2) if total_m <= 0  # fallback: sem textura detectada
        desc = "#{nome} (#{fmt(total_m)}m)"
        build_item(desc, 1, "und.")
      else
        build_item(nome, qtd, "und.")
      end

    else
      build_item(nome, qtd, "und.")
    end
  end

  def self.build_item(descricao, quantidade, unidade)
    {
      "descricao"  => descricao,
      "quantidade" => quantidade,
      "unidade"    => unidade
    }
  end

  def self.metro(polegadas)
    (polegadas.to_f * POLEGADA_PARA_METRO).round(2)
  end

  # ── LISTAR MATERIAIS DE REVESTIMENTOS (para painel de seleção) ───────────────

  def self.listar_materiais_revestimentos(model)
    # Chaveado pelo objeto Material — nome idêntico ao painel de Materiais do SketchUp
    materiais_pol2 = Hash.new(0.0)
    model.entities.each { |ent| varrer_para_revestimentos(ent, materiais_pol2) }
    materiais_pol2
      .map do |mat, area|
        c   = mat.color
        cor = '#%02x%02x%02x' % [c.red, c.green, c.blue]
        { "nome" => mat.display_name, "area" => (area * POL2_PARA_M2).round(2), "cor" => cor }
      end
      .sort_by { |m| m["nome"] }
  end

  def self.varrer_para_revestimentos(ent, resultado)
    if ent.is_a?(Sketchup::ComponentInstance)
      varrer_faces_rev(ent.definition.entities, ent.material, resultado)
    elsif ent.is_a?(Sketchup::Group)
      varrer_faces_rev(ent.entities, ent.material, resultado)
    end
  end

  def self.varrer_faces_rev(entities, mat_herdado, resultado)
    entities.each do |ent|
      if ent.is_a?(Sketchup::Face)
        # Conta todas as faces pintadas: front, verso ou herdado.
        mat = ent.material || ent.back_material || mat_herdado
        resultado[mat] += ent.area if mat.is_a?(Sketchup::Material)
      elsif ent.is_a?(Sketchup::Group)
        varrer_faces_rev(ent.entities, ent.material || mat_herdado, resultado)
      elsif ent.is_a?(Sketchup::ComponentInstance)
        varrer_faces_rev(ent.definition.entities, ent.material || mat_herdado, resultado)
      end
    end
  end

  # ── MAIOR FACE (para Comunicação Visual) ────────────────────────────────────

  def self.maior_face_area_m2(inst)
    max_pol2 = maior_face_recursivo(inst.definition.entities)
    (max_pol2 * POL2_PARA_M2).round(2)
  end

  def self.maior_face_recursivo(entities)
    max = 0.0
    entities.each do |ent|
      if ent.is_a?(Sketchup::Face)
        max = ent.area if ent.area > max
      elsif ent.is_a?(Sketchup::Group)
        sub = maior_face_recursivo(ent.entities)
        max = sub if sub > max
      elsif ent.is_a?(Sketchup::ComponentInstance)
        sub = maior_face_recursivo(ent.definition.entities)
        max = sub if sub > max
      end
    end
    max
  end

  # Soma a área de TODAS as faces do componente (superfície total)
  def self.area_total_faces_m2(inst)
    total_pol2 = somar_faces_recursivo(inst.definition.entities)
    (total_pol2 * POL2_PARA_M2).round(2)
  end

  def self.somar_faces_recursivo(entities)
    total = 0.0
    entities.each do |ent|
      if ent.is_a?(Sketchup::Face)
        total += ent.area
      elsif ent.is_a?(Sketchup::Group)
        total += somar_faces_recursivo(ent.entities)
      elsif ent.is_a?(Sketchup::ComponentInstance)
        total += somar_faces_recursivo(ent.definition.entities)
      end
    end
    total
  end

  # ── ÁREA REAL DAS FACES REVESTIDAS (paredes/sancas/testeiras em L) ───────────
  # Soma a área real das faces que têm material aplicado (a "pintura"/lona),
  # uma face por plano (remove faces coplanares duplicadas), com a escala da
  # instância/pais aplicada. Lida com paredes em L, com retorno e várias paredes,
  # pois mede a geometria real — não a caixa delimitadora.
  # Área (m²) das faces com material, uma por plano, escala aplicada.
  # kws = nil  → qualquer face com material (ex.: textura da fita LED).
  # kws = [..] → só faces cujo material casa com as palavras (ex.: revestimentos).
  def self.area_faces_material_m2(inst, tr_pai = nil, kws = nil)
    tr = tr_pai ? tr_pai * inst.transformation : inst.transformation
    planos = {}
    acumular_faces_material(inst.definition.entities, tr, planos, kws)
    total_pol2 = planos.values.inject(0.0) { |s, a| s + a }
    (total_pol2 * POL2_PARA_M2).round(2)
  end

  # Área das faces revestidas = faces com material da lista de Revestimentos.
  def self.area_faces_revestidas_m2(inst, tr_pai = nil)
    kws = palavras_revestimento.map { |k| k.to_s.downcase }.reject(&:empty?)
    return 0.0 if kws.empty?
    area_faces_material_m2(inst, tr_pai, kws)
  end

  # Face com material? Se kws dado, exige que o nome do material case com alguma.
  def self.face_tem_material?(face, kws)
    mats = [face.material, face.back_material].compact
    return false if mats.empty?
    return true if kws.nil?
    mats.any? do |m|
      nome = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s.downcase
      kws.any? { |kw| nome.include?(kw) }
    end
  end

  def self.acumular_faces_material(entities, tr, planos, kws)
    entities.each do |ent|
      if ent.is_a?(Sketchup::Face)
        next unless face_tem_material?(ent, kws)
        pts  = ent.outer_loop.vertices.map { |v| v.position.transform(tr) }
        area = area_poligono_3d(pts)
        next if area <= 1e-9
        chave = assinatura_plano(pts)
        # uma face por plano: mantém a maior área no mesmo plano (descarta duplicadas)
        planos[chave] = area if area > (planos[chave] || 0.0)
      elsif ent.is_a?(Sketchup::Group)
        acumular_faces_material(ent.entities, tr * ent.transformation, planos, kws)
      elsif ent.is_a?(Sketchup::ComponentInstance)
        acumular_faces_material(ent.definition.entities, tr * ent.transformation, planos, kws)
      end
    end
  end

  # Área de polígono 3D (fórmula de Newell) — pontos já transformados (com escala).
  def self.area_poligono_3d(pts)
    n = pts.length
    return 0.0 if n < 3
    nx = ny = nz = 0.0
    n.times do |i|
      p = pts[i]; q = pts[(i + 1) % n]
      nx += (p.y - q.y) * (p.z + q.z)
      ny += (p.z - q.z) * (p.x + q.x)
      nz += (p.x - q.x) * (p.y + q.y)
    end
    Math.sqrt(nx * nx + ny * ny + nz * nz) / 2.0
  end

  # Assinatura do plano (normal normalizada + deslocamento), arredondada.
  # Mantém o sinal da normal: frente e verso ficam em planos diferentes (a face do
  # verso, sem material, nem entra na conta).
  def self.assinatura_plano(pts)
    a, b, c = pts[0], pts[1], pts[2]
    ux = b.x - a.x; uy = b.y - a.y; uz = b.z - a.z
    vx = c.x - a.x; vy = c.y - a.y; vz = c.z - a.z
    nx = uy * vz - uz * vy
    ny = uz * vx - ux * vz
    nz = ux * vy - uy * vx
    len = Math.sqrt(nx * nx + ny * ny + nz * nz)
    return [0, 0, 0, 0] if len < 1e-9
    nx /= len; ny /= len; nz /= len
    d = nx * a.x + ny * a.y + nz * a.z
    [nx.round(3), ny.round(3), nz.round(3), d.round(2)]
  end

  # ── DIAGNÓSTICO DE REVESTIMENTOS ────────────────────────────────────────────
  # Mostra, por material, quantas faces entram na conta e de onde vem a área
  # (front da face, verso/back, ou herdado da instância/grupo). Ajuda a achar a
  # origem de m² excedente (verso + bordas de sólidos, ou tinta na instância).
  def self.nome_material(m)
    m.respond_to?(:display_name) ? m.display_name : m.name
  end

  def self.diag_varrer(ent, mat_herdado, dados)
    if ent.is_a?(Sketchup::Face)
      nome = nil; origem = nil
      if ent.material
        nome = nome_material(ent.material); origem = :front
      elsif ent.back_material
        nome = nome_material(ent.back_material); origem = :back
      elsif mat_herdado.is_a?(Sketchup::Material)
        nome = nome_material(mat_herdado); origem = :herdado
      end
      if nome
        d = (dados[nome] ||= { faces: 0, area: 0.0, maior: 0.0, front: 0, back: 0, herdado: 0 })
        d[:faces]  += 1
        d[:area]   += ent.area
        d[:maior]   = ent.area if ent.area > d[:maior]
        d[origem]  += 1
      end
    elsif ent.is_a?(Sketchup::Group)
      ent.entities.each { |s| diag_varrer(s, ent.material || mat_herdado, dados) }
    elsif ent.is_a?(Sketchup::ComponentInstance)
      ent.definition.entities.each { |s| diag_varrer(s, ent.material || mat_herdado, dados) }
    end
  end

  def self.diagnostico_revestimentos(model = Sketchup.active_model)
    dados = {}
    model.entities.each { |e| diag_varrer(e, nil, dados) }
    puts "── Diagnóstico de Revestimentos — #{model.title} ──"
    puts format("%-30s %5s %11s %11s   %s", "MATERIAL", "faces", "total m²", "maior m²", "[front/back/herdado]")
    dados.sort_by { |n, _| n.to_s.downcase }.each do |nome, d|
      puts format("%-30s %5d %11.2f %11.2f   [%d/%d/%d]",
                  nome[0, 30], d[:faces],
                  d[:area]  * POL2_PARA_M2,
                  d[:maior] * POL2_PARA_M2,
                  d[:front], d[:back], d[:herdado])
    end
    puts "─────────────────────────────────────────────────────────────"
    puts "Dica: se 'total' >> 'maior' e há faces em back/herdado, o excedente"
    puts "vem do verso/bordas do sólido ou da tinta aplicada na instância."
    dados.size
  end

  # ── MENU E BARRA DE FERRAMENTAS ─────────────────────────────────────────────

  unless file_loaded?(__FILE__)
    cmd = UI::Command.new("STAND1_Memorial") { STAND1_Memorial.abrir_dialog }
    cmd.tooltip          = "STAND1_Memorial"
    cmd.status_bar_text  = "Gerar Memorial Descritivo PDF/TXT"
    cmd.menu_text        = "STAND1_Memorial"

    icon_dir = File.join(__dir__, 'icons')
    cmd.small_icon = File.join(icon_dir, 'icon_24.png')
    cmd.large_icon = File.join(icon_dir, 'icon_32.png')

    menu = UI.menu("Plugins")
    menu.add_item(cmd)
    menu.add_item("STAND1_Memorial — Diagnóstico de Revestimentos") do
      STAND1_Memorial.diagnostico_revestimentos
      UI.messagebox("Diagnóstico impresso na Janela > Ruby Console.\nCopie e me envie as linhas dos revestimentos que estão excedendo.")
    end

    toolbar = UI::Toolbar.new("STAND1_Memorial")
    toolbar.add_item(cmd)
    toolbar.restore

    file_loaded(__FILE__)
    puts "✅ STAND1_Memorial v6.5.0 carregado"
  end

end
