# =============================================================================
# Stand1 Memorial Descritivo — core.rb v7.0.3
# Novidades: Multi-Espaço · Diff de Revisão · Cálculo de KVA
# =============================================================================

require 'sketchup.rb'
require 'json'
require 'fileutils'
require 'digest'
require 'tmpdir'
require_relative 'dimensoes'

module STAND1_Memorial

  POLEGADA_PARA_METRO = 0.0254
  POL2_PARA_M2        = 0.0254 * 0.0254

  # ── VERSÃO + AUTO-UPDATE (via GitHub público) ───────────────────────────────
  VERSAO        = "7.0.6"
  URL_MANIFESTO = "https://raw.githubusercontent.com/tatazera/vibe-coding/main/STAND1_Memorial_Plugin/latest.json"

  # ── KVA ─────────────────────────────────────────────────────────────────────
  URL_KVA_RAW = "https://raw.githubusercontent.com/tatazera/vibe-coding/main/STAND1_Memorial_Plugin/kva_table.json"
  URL_KVA_API = "https://api.github.com/repos/tatazera/vibe-coding/contents/STAND1_Memorial_Plugin/kva_table.json"
  KVA_SECOES  = ["EQUIPAMENTOS", "ELÉTRICA"].freeze

  # Compara "a.b.c" numericamente: remota > local?
  def self.versao_maior?(remota, local)
    r = remota.to_s.split(".").map { |x| x.to_i }
    l = local.to_s.split(".").map { |x| x.to_i }
    n = [r.size, l.size].max
    r += [0] * (n - r.size)
    l += [0] * (n - l.size)
    (r <=> l) > 0
  end

  # GET assíncrono. Prioriza Sketchup::Http (pilha de rede nativa do Windows —
  # respeita proxy/TLS do sistema, sem depender do OpenSSL do SketchUp, que falha
  # o handshake com o GitHub em muitas builds). Faz fallback para Net::HTTP.
  # Chama on_body.call(corpo_string_ou_nil, ok_booleano).
  def self.http_async(url, &on_body)
    if defined?(Sketchup::Http) && defined?(Sketchup::Http::Request)
      req = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
      # Retém a requisição: sem isso o GC a coleta antes do callback assíncrono
      # disparar e a chamada morre em silêncio (bug clássico do Sketchup::Http).
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

  # Fallback síncrono (SketchUp sem Sketchup::Http): Net::HTTP com cert tolerante.
  def self.http_get_net(url, limite = 4)
    require 'net/http'
    require 'openssl'
    raise "muitos redirecionamentos" if limite <= 0
    uri  = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == "https")
    http.verify_mode  = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = 8
    http.read_timeout = 60
    resp = http.get(uri.request_uri)
    case resp
    when Net::HTTPSuccess     then resp.body
    when Net::HTTPRedirection then http_get_net(resp["location"], limite - 1)
    else raise "HTTP #{resp.code}"
    end
  end

  # Verifica versão e sinaliza o diálogo. manual=true mostra também "sem update".
  def self.verificar_atualizacao(manual = false)
    return unless @dialog
    http_async(URL_MANIFESTO) do |body, ok|
      next (@dialog.execute_script("avisoUpdateErro()") rescue nil) if (!ok || body.nil?) && manual
      next unless ok && body
      begin
        # Remove BOM (UTF-8) eventual no inicio — senao o JSON.parse falha.
        limpo = body.to_s.dup.force_encoding("UTF-8").sub(/\A\xEF\xBB\xBF/n, "").sub(/\A﻿/, "")
        info = JSON.parse(limpo)
        nova = info["versao"].to_s
        if versao_maior?(nova, VERSAO)
          payload = { versao: nova, notas: info["notas"].to_s, rbz: info["rbz"].to_s }.to_json
          @dialog.execute_script("mostrarUpdate(#{payload})") rescue nil
        elsif manual
          @dialog.execute_script("avisoSemUpdate(#{VERSAO.to_json})") rescue nil
        end
      rescue
        @dialog.execute_script("avisoUpdateErro()") rescue nil if manual
      end
    end
  end

  # Baixa o .rbz e instala via API nativa; fallback abre a URL no navegador.
  def self.baixar_e_instalar_update(url)
    http_async(url) do |body, ok|
      if !ok || body.nil?
        UI.messagebox("Não foi possível baixar a atualização.\nAbrindo o download no navegador.")
        UI.openURL(url) rescue nil
        next
      end
      begin
        destino = File.join(Dir.tmpdir, "STAND1_Memorial_update.rbz")
        File.open(destino, "wb") { |f| f.write(body) }
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

  # Persistência robusta de listas de palavras-chave em Sketchup defaults.
  # Armazena uma palavra por linha (sem aspas/colchetes): o registro do SketchUp
  # aplica escaping em strings JSON, fazendo a releitura falhar e resetar para o
  # padrão (bug do reset ao "Adicionar Tudo"). Lê o formato legado JSON também.
  def self.ler_lista(chave, padrao)
    raw = Sketchup.read_default("STAND1_Memorial", chave, nil)
    return padrao.dup if raw.nil?
    s = raw.to_s
    if s.lstrip.start_with?("[")
      begin
        v = JSON.parse(s)
        return v if v.is_a?(Array)
      rescue
      end
      return padrao.dup # JSON legado corrompido pelo registro → padrão
    end
    s.split("\n").map { |x| x.strip }.reject(&:empty?)
  rescue
    padrao.dup
  end

  def self.salvar_lista(chave, lista)
    arr = Array(lista).map { |x| x.to_s.strip }.reject(&:empty?)
    Sketchup.write_default("STAND1_Memorial", chave, arr.join("\n"))
  end

  def self.palavras_mobiliario
    ler_lista("palavras_mobiliario", PALAVRAS_MOBILIARIO_DEFAULT)
  end

  def self.salvar_palavras_mobiliario(lista)
    salvar_lista("palavras_mobiliario", lista)
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

  # ── REGRAS DE MEDIÇÃO (ESTRUTURAS) ──────────────────────────────────────────
  # Editor único: cada regra mapeia uma palavra-chave → fórmula de medição.
  # A 1ª regra (de cima p/ baixo) cujo nome do item contenha a palavra vence;
  # itens sem regra usam o fallback "face" (largura × altura).
  # Fórmulas (= dropdown na interface):
  #   horizontal       L×P                  m²   piso/forro/teto
  #   face             largura×altura       m²   painel/backdrop/parede (fallback)
  #   recinto          2×(L+P)×altura       m²   sala/cabine (fechado)*
  #   faixa            (L+P)×altura         m²   testeira/fachada*
  #   comprimento      maior dimensão       m    coluna/viga/pilar
  #   perimetro        2×(2 maiores)        m    moldura/sanca
  #   desenvolvimento  L+P                  m    trilho/barra aberta
  #   volume           L×P×altura           m³   blocos/bases
  #   unidade          —                    und. item avulso
  # * recinto/faixa só aplicam a fórmula de perímetro se a menor dimensão
  #   horizontal ≥ GUARDA_FOOTPRINT_M (footprint real); abaixo disso caem em
  #   "face" — protege painel/parede fino de dobrar a área indevidamente.
  GUARDA_FOOTPRINT_M = 0.30

  FORMULAS_VALIDAS = %w[
    horizontal face recinto faixa comprimento perimetro desenvolvimento volume unidade
  ].freeze

  REGRAS_MEDICAO_DEFAULT = [
    ["piso", "horizontal"], ["forro", "horizontal"], ["teto", "horizontal"],
    ["deck", "horizontal"], ["tablado", "horizontal"], ["palco", "horizontal"],
    ["estrado", "horizontal"],
    ["coluna", "comprimento"], ["viga", "comprimento"], ["pilar", "comprimento"],
    ["brise", "comprimento"], ["ripa", "comprimento"], ["pergola", "comprimento"],
    ["barrote", "comprimento"], ["montante", "comprimento"], ["travessa", "comprimento"],
    ["moldura", "perimetro"], ["sanca", "perimetro"], ["rodapé", "perimetro"],
    ["friso", "perimetro"], ["arremate", "perimetro"],
    ["sala", "recinto"], ["cabine", "recinto"], ["depósito", "recinto"], ["copa", "recinto"],
    ["testeira", "faixa"], ["fachada", "faixa"],
    ["painel", "face"], ["backdrop", "face"], ["parede", "face"], ["placa", "face"],
    ["fechamento", "face"], ["caixaria", "face"], ["divisória", "face"], ["totem", "face"]
  ].freeze

  # Regras lidas do registro como "palavra=formula" por linha (formato à prova do
  # escaping que corrompe JSON no registro do SketchUp — ver ler_lista).
  def self.regras_medicao
    raw = Sketchup.read_default("STAND1_Memorial", "regras_medicao", nil)
    return REGRAS_MEDICAO_DEFAULT.map(&:dup) if raw.nil?
    pares = raw.to_s.split("\n").map do |ln|
      k, v = ln.split("=", 2)
      [k.to_s.strip.downcase, v.to_s.strip]
    end.reject { |k, v| k.empty? || !FORMULAS_VALIDAS.include?(v) }
    pares.empty? ? REGRAS_MEDICAO_DEFAULT.map(&:dup) : pares
  rescue
    REGRAS_MEDICAO_DEFAULT.map(&:dup)
  end

  def self.salvar_regras_medicao(pares)
    linhas = Array(pares).map do |par|
      pal = par[0].to_s.strip.downcase
      frm = par[1].to_s.strip
      (pal.empty? || !FORMULAS_VALIDAS.include?(frm)) ? nil : "#{pal}=#{frm}"
    end.compact
    Sketchup.write_default("STAND1_Memorial", "regras_medicao", linhas.join("\n"))
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
    ler_lista("palavras_revestimento", PALAVRAS_REVESTIMENTO_DEFAULT)
  end

  def self.salvar_palavras_revestimento(lista)
    salvar_lista("palavras_revestimento", lista)
  end

  # ── PERSISTÊNCIA DE ESTADO (arquivo por projeto) ────────────────────────────

  @ultimo_estado_json = nil
  @cache = {}

  def self.limpar_cache
    @cache = {}
  end

  def self.scale_sig(tr)
    m = tr.to_a
    [(m[0]**2+m[1]**2+m[2]**2).round(4),
     (m[4]**2+m[5]**2+m[6]**2).round(4),
     (m[8]**2+m[9]**2+m[10]**2).round(4)]
  end

  # Regras de medição lidas do registro são cacheadas durante o scan.
  def self.regras_medicao_cached
    @cache[:regras] ||= regras_medicao
  end

  # Fórmula da 1ª regra cujo nome contenha a palavra (ou "face" como fallback).
  def self.formula_do_item(nome_lower)
    regra = regras_medicao_cached.find { |pal, _f| nome_lower.include?(pal) }
    regra ? regra[1] : "face"
  end

  # Monta a descrição de um item de ESTRUTURAS conforme a fórmula da regra.
  # l = largura (maior horizontal), p = profundidade (menor horizontal),
  # a = altura (eixo vertical Z do modelo — lógica construtiva, não a menor dim).
  def self.descricao_estrutura(nome, l, p, a)
    formula = formula_do_item(nome.downcase)
    d       = [l, p, a].sort.reverse        # 3 dimensões, maior → menor
    dim3    = "(#{fmt(l)}m x #{fmt(p)}m x #{fmt(a)}m)"

    # Recinto/Faixa exigem footprint real; senão viram face (não dobram peça fina).
    if (formula == "recinto" || formula == "faixa") && [l, p].min < GUARDA_FOOTPRINT_M
      formula = "face"
    end

    case formula
    when "horizontal"
      "#{nome} (#{fmt(l)}m x #{fmt(p)}m) - #{fmt((l * p).round(2))}m²"
    when "recinto"
      "#{nome} #{dim3} - #{fmt((2 * (l + p) * a).round(2))}m²"
    when "faixa"
      "#{nome} #{dim3} - #{fmt(((l + p) * a).round(2))}m²"
    when "comprimento"
      "#{nome} #{dim3} - #{fmt(d[0])}m"
    when "perimetro"
      "#{nome} #{dim3} - #{fmt((2 * (d[0] + d[1])).round(2))}m"
    when "desenvolvimento"
      "#{nome} #{dim3} - #{fmt((l + p).round(2))}m"
    when "volume"
      "#{nome} #{dim3} - #{fmt((l * p * a).round(2))}m³"
    when "unidade"
      nome
    else # face: largura × altura
      "#{nome} #{dim3} - #{fmt((l * a).round(2))}m²"
    end
  end

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
      @dialog.execute_script("definirRegrasMedicao(#{regras_medicao.to_json})") rescue nil
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
      # Checagem de atualização adiada (não bloqueia a abertura do diálogo).
      UI.start_timer(1.5, false) { verificar_atualizacao(false) } rescue nil
      # Enviar tabela KVA local (sem bloquear) + buscar versão mais nova no GitHub
      begin
        tabela_local = kva_table_local
        unless tabela_local.empty?
          @dialog.execute_script("receberTabelaKVA(#{tabela_local.to_json},#{token_github.to_json})") rescue nil
        end
        UI.start_timer(3.0, false) { buscar_kva_github } rescue nil
      rescue; end
      # Restaurar estado do modo Multi-Espaço (botão + lista de grupos)
      begin
        grupos = listar_grupos_raiz(model)
        @dialog.execute_script("receberGruposEspaco(#{grupos.to_json},#{modo_multi_espaco?.to_json})") rescue nil
      rescue; end
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

    @dialog.add_action_callback("salvar_regras_medicao") do |_ctx, json_regras|
      salvar_regras_medicao(JSON.parse(json_regras))
    end

    @dialog.add_action_callback("restaurar_regras_medicao") do |_ctx, _arg|
      Sketchup.write_default("STAND1_Memorial", "regras_medicao", nil)
      @dialog.execute_script("definirRegrasMedicao(#{REGRAS_MEDICAO_DEFAULT.to_json}); renderizarRegras();") rescue nil
    end

    @dialog.add_action_callback("verificar_update") do |_ctx, _arg|
      verificar_atualizacao(true)
    end

    @dialog.add_action_callback("baixar_update") do |_ctx, url|
      baixar_e_instalar_update(url)
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
        # ── FLUXO PRINCIPAL — idêntico à v6.7.15 ─────────────────────────────
        dados = coletar_dados(model_atual)
        nome  = nome_do_arquivo(model_atual)
        payload = { secoes: dados, nome_arquivo: nome }.to_json
        @dialog.execute_script("carregarDados(#{payload})")
        reenviar_listas
        # ── FEATURES ADICIONAIS — isoladas, falha silenciosa ─────────────────
        begin
          tirar_snapshot(@ultimo_resultado) if @ultimo_resultado
          @ultimo_resultado = dados
          diff = snapshot_anterior ? comparar_memoriais(snapshot_anterior, dados) : []
          @dialog.execute_script("receberDiffRevisao(#{diff.to_json})")
        rescue; end
        begin
          resultado_kva = calcular_kva(dados)
          @dialog.execute_script("receberResultadoKVA(#{resultado_kva.to_json})")
        rescue; end
      end
    end

    # ── Multi-Espaço ─────────────────────────────────────────────────────────
    @dialog.add_action_callback("toggle_multi_espaco") do |_ctx, ativo|
      salvar_modo_multi_espaco(ativo == true || ativo == "true")
      model_atual = Sketchup.active_model
      grupos = model_atual ? listar_grupos_raiz(model_atual) : []
      @dialog.execute_script("receberGruposEspaco(#{grupos.to_json},#{modo_multi_espaco?.to_json})")
    end

    @dialog.add_action_callback("listar_grupos_espaco") do |_ctx|
      model_atual = Sketchup.active_model
      grupos = model_atual ? listar_grupos_raiz(model_atual) : []
      @dialog.execute_script("receberGruposEspaco(#{grupos.to_json},#{modo_multi_espaco?.to_json})")
    end

    @dialog.add_action_callback("marcar_grupo_espaco") do |_ctx, pid, ativo|
      model_atual = Sketchup.active_model
      marcar_grupo_espaco(pid, ativo == true || ativo == "true", model_atual) if model_atual
    end

    @dialog.add_action_callback("carregar_multi_espaco") do |_ctx|
      model_atual = Sketchup.active_model
      next unless model_atual
      # ── FLUXO MULTI — não interfere no fluxo principal ────────────────────
      begin
        dados_multi = coletar_dados_multi_espaco(model_atual)
        if dados_multi && !dados_multi.empty?
          payload = { espacos: dados_multi, nome_arquivo: nome_do_arquivo(model_atual) }.to_json
          @dialog.execute_script("carregarDadosMultiEspaco(#{payload})")
          begin
            tirar_snapshot(@ultimo_resultado_multi) if @ultimo_resultado_multi
            @ultimo_resultado_multi = dados_multi
            diff = snapshot_anterior ? comparar_memoriais_multi(snapshot_anterior, dados_multi) : []
            @dialog.execute_script("receberDiffRevisao(#{diff.to_json})")
          rescue; end
          begin
            secoes_flat = dados_multi.flat_map { |e| e["secoes"] }
            resultado_kva = calcular_kva(secoes_flat)
            @dialog.execute_script("receberResultadoKVA(#{resultado_kva.to_json})")
          rescue; end
        else
          @dialog.execute_script("alertaSemGruposEspaco()")
        end
      rescue => e
        @dialog.execute_script("UI.messagebox('Erro Multi-Espaço: #{e.message}')")
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

    # ── CALLBACKS KVA ─────────────────────────────────────────────────────────
    @dialog.add_action_callback("salvar_token_github") do |_ctx, token|
      begin; salvar_token_github(token); rescue; end
    end

    @dialog.add_action_callback("buscar_kva_github") do |_ctx|
      begin; buscar_kva_github; rescue; end
    end

    @dialog.add_action_callback("publicar_kva_github") do |_ctx, tabela_json|
      begin; publicar_kva_github(tabela_json); rescue; end
    end

    @dialog.add_action_callback("calcular_kva_atual") do |_ctx|
      begin
        secoes = @ultimo_resultado || []
        resultado_kva = calcular_kva(secoes)
        @dialog.execute_script("receberResultadoKVA(#{resultado_kva.to_json})")
      rescue; end
    end

    @dialog.add_action_callback("carregar_kva_table_local") do |_ctx|
      begin
        tabela = kva_table_local
        @dialog.execute_script("receberTabelaKVA(#{tabela.to_json},#{token_github.to_json})") unless tabela.empty?
      rescue; end
    end

    @dialog.add_action_callback("exportar_relatorio_kva") do |_ctx, html_conteudo, nome_sug|
      begin; exportar_pdf_headless(html_conteudo, nome_sug || "relatorio_kva"); rescue; end
    end

    @dialog.add_action_callback("exportar_relatorio_kva_txt") do |_ctx, texto, nome_sug|
      begin; exportar_arquivo_txt(texto, nome_sug || "relatorio_kva"); rescue; end
    end

    @dialog.add_action_callback("exportar_pdf_revisao") do |_ctx, html_conteudo, nome_sug|
      begin; exportar_pdf_headless(html_conteudo, nome_sug || "revisao_memorial"); rescue; end
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

    # ── FLUXO PRINCIPAL — idêntico à v6.7.15 ──────────────────────────────
    nome = nome_do_arquivo(model)
    payload = { secoes: dados, nome_arquivo: nome }.to_json
    @dialog.execute_script("atualizarDados(#{payload})")
    reenviar_listas
    # ── FEATURES ADICIONAIS — isoladas, falha silenciosa ──────────────────
    begin
      tirar_snapshot(@ultimo_resultado) if @ultimo_resultado
      @ultimo_resultado = dados
      diff = snapshot_anterior ? comparar_memoriais(snapshot_anterior, dados) : []
      @dialog.execute_script("receberDiffRevisao(#{diff.to_json})")
    rescue; end
    begin
      resultado_kva = calcular_kva(dados)
      @dialog.execute_script("receberResultadoKVA(#{resultado_kva.to_json})")
    rescue; end
  end

  # Reenvia as listas de palavras-chave salvas para a interface após cada scan,
  # garantindo que elas nunca "sumam" ao rodar Adicionar Tudo/Atualizar.
  def self.reenviar_listas
    return unless @dialog
    @dialog.execute_script("definirRegrasMedicao(#{regras_medicao.to_json})") rescue nil
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
    limpar_cache
    secoes_raw = {}
    SECOES_PERMITIDAS.each { |s| secoes_raw[s] = {} }

    model.entities.each do |ent|
      processar_entidade(ent, secoes_raw)
    end

    # listar_materiais_revestimentos é chamado uma única vez e reaproveitado
    materiais = listar_materiais_revestimentos(model)
    adicionar_revestimentos_auto(secoes_raw, materiais)
    adicionar_fita_led_auto(secoes_raw, materiais)

    montar_resultado(secoes_raw)
  end

  def self.adicionar_revestimentos_auto(secoes_raw, materiais)
    kws = palavras_revestimento.map { |k| k.to_s.downcase }.reject(&:empty?)
    return if kws.empty?

    materiais.each do |m|
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

  def self.adicionar_fita_led_auto(secoes_raw, materiais)
    larg = largura_fita_led
    return if larg <= 0

    # Uma entrada por material de fita, usando o NOME REAL da textura
    # (ex.: "Fita LED COB branco quente") em vez de um rótulo genérico.
    materiais.each do |m|
      nome_mat = m["nome"].to_s
      next unless PALAVRAS_FITA_LED.any? { |kw| nome_mat.downcase.include?(kw) }
      area = m["area"].to_f
      next if area <= 0

      metros = (area / larg).round(2)
      chave  = "fita_led_auto__#{nome_mat.downcase}"
      next if secoes_raw["ELÉTRICA"][chave]

      secoes_raw["ELÉTRICA"][chave] = {
        nome:               nome_mat,
        largura:            0.0,
        profund:            0.0,
        altura:             0.0,
        area_face_frontal:  0.0,
        area_material:      area.round(2),
        comprimento_linear: metros,
        metros_fita:        metros,
        quantidade:         1,
        chave:              chave
      }
    end
  end

  # ── COLETA DE DADOS (SELEÇÃO) ──────────────────────────────────────────────

  def self.coletar_dados_selecao(model, selection)
    @ultimo_modo = :selecao
    limpar_cache
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
    comprimento_linear = _ck[0]  # maior dimensão (fallback de m linear p/ fita LED)

    # area_face_frontal: usado só por COMUNICAÇÃO VISUAL ("2 maiores dimensões":
    # lonas/logos, espessura é a menor dim). ESTRUTURAS calcula a medida na
    # formatação, via regras de medição (descricao_estrutura).
    area_face_frontal = secao == "COMUNICAÇÃO VISUAL" ? (_ck[0] * _ck[1]).round(2) : 0.0

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
        area_material:      0.0,  # não usado nesta seção; mantido por compatibilidade do estado
        comprimento_linear: comprimento_linear,
        metros_fita:        metros_fita,
        quantidade:         1,
        chave:              chave
      }
    end
  end

  # ── CÁLCULO DE ÁREA (m²) A PARTIR DAS TEXTURAS/MATERIAIS ──────────────────

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
    comp  = item[:comprimento_linear]
    nome_lower = nome.downcase

    case secao

    # ESTRUTURAS: medida definida pelas Regras de Medição (palavra-chave → fórmula).
    when "ESTRUTURAS"
      build_item(descricao_estrutura(nome, l, p, a), qtd, "und.")

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

    # MOBILIÁRIO: mostra dimensões apenas para itens com palavras-chave configuradas.
    # Carrega nome_base + dims crus p/ a interface reformatar sem reler o modelo.
    when "MOBILIÁRIO"
      tem = palavras_mobiliario.any? { |kw| nome_lower.include?(kw) }
      desc = tem ? "#{nome} (#{fmt(l)}m x #{fmt(p)}m x #{fmt(a)}m)" : nome
      it = build_item(desc, qtd, "und.")
      it["nome_base"] = nome
      it["dim_l"] = l; it["dim_p"] = p; it["dim_a"] = a
      it

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
    k = [:afm, inst.definition.object_id, scale_sig(tr), kws ? kws.sort : nil]
    return @cache[k] if @cache.key?(k)
    planos = {}
    acumular_faces_material(inst.definition.entities, tr, planos, kws)
    total_pol2 = planos.values.inject(0.0) { |s, a| s + a }
    @cache[k] = (total_pol2 * POL2_PARA_M2).round(2)
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

  # ── MULTI-ESPAÇO ─────────────────────────────────────────────────────────────

  def self.modo_multi_espaco?
    Sketchup.read_default("STAND1_Memorial", "modo_multi_espaco", "0") == "1"
  end

  def self.salvar_modo_multi_espaco(ativo)
    Sketchup.write_default("STAND1_Memorial", "modo_multi_espaco", ativo ? "1" : "0")
  end

  # Um "espaço" pode ser um Group OU um ComponentInstance de primeiro nível.
  def self.container_espaco?(ent)
    ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
  end

  # Conteúdo (entities) de um container, seja Group ou ComponentInstance.
  def self.entities_do_container(ent)
    ent.is_a?(Sketchup::ComponentInstance) ? ent.definition.entities : ent.entities
  end

  # Nome de exibição do espaço: nome da instância → nome da definição → vazio.
  def self.nome_container_espaco(ent)
    n = ent.name.to_s.strip
    return n unless n.empty?
    if ent.is_a?(Sketchup::ComponentInstance)
      dn = ent.definition.name.to_s.strip
      return dn unless dn.empty?
    end
    ""
  end

  def self.listar_grupos_raiz(model)
    grupos = []
    model.entities.each do |ent|
      next unless container_espaco?(ent)
      nome    = nome_container_espaco(ent)
      nome    = "(sem nome)" if nome.empty?
      marcado = ent.get_attribute("STAND1_Memorial", "espaco", false)
      grupos << { "id" => ent.persistent_id.to_s, "nome" => nome, "marcado" => (marcado == true || marcado == "true") }
    end
    grupos
  end

  def self.marcar_grupo_espaco(pid, ativo, model)
    model.start_operation("STAND1 — Marcar Espaço", true)
    model.entities.each do |ent|
      next unless container_espaco?(ent)
      if ent.persistent_id.to_s == pid.to_s
        ent.set_attribute("STAND1_Memorial", "espaco", ativo)
        model.commit_operation
        return true
      end
    end
    model.abort_operation
    false
  end

  # Processa o conteúdo de um espaço aplicando a transformação e a tag do próprio
  # container — idêntico ao que o fluxo padrão faz ao encontrar o container no topo.
  def self.processar_conteudo_espaco(container, secoes_raw)
    tag = container.layer&.name.to_s
    tag = "" if tag == "Untagged" || tag == "Layer0"
    tr  = container.transformation
    entities_do_container(container).each do |sub|
      processar_entidade(sub, secoes_raw, tag, tr)
    end
  end

  def self.coletar_dados_multi_espaco(model)
    limpar_cache
    grupos = []
    model.entities.each do |ent|
      next unless container_espaco?(ent)
      marcado = ent.get_attribute("STAND1_Memorial", "espaco", false)
      next unless marcado == true || marcado == "true"
      nome = nome_container_espaco(ent)
      nome = "Espaço #{grupos.size + 1}" if nome.empty?
      grupos << { grupo: ent, nome: nome }
    end
    return nil if grupos.empty?
    resultado = []
    grupos.each do |gs|
      secoes_raw = {}
      SECOES_PERMITIDAS.each { |s| secoes_raw[s] = {} }
      processar_conteudo_espaco(gs[:grupo], secoes_raw)
      materiais = listar_materiais_revestimentos_grupo(gs[:grupo])
      adicionar_revestimentos_auto(secoes_raw, materiais)
      adicionar_fita_led_auto(secoes_raw, materiais)
      secoes = montar_resultado(secoes_raw)
      resultado << { "espaco" => gs[:nome], "secoes" => secoes } unless secoes.empty?
    end
    resultado
  end

  # Materiais de revestimento dentro de um espaço — varre as faces imediatas do
  # container E recursivamente as aninhadas (igual ao que o fluxo global faz ao
  # mergulhar no container), com o material herdado do próprio container.
  def self.listar_materiais_revestimentos_grupo(container)
    materiais_pol2 = Hash.new(0.0)
    varrer_faces_rev(entities_do_container(container), container.material, materiais_pol2)
    materiais_pol2.map do |mat, area|
      c = mat.color
      cor = '#%02x%02x%02x' % [c.red, c.green, c.blue]
      { "nome" => mat.display_name, "area" => (area * POL2_PARA_M2).round(2), "cor" => cor }
    end.sort_by { |m| m["nome"] }
  end

  # ── DIFF DE REVISÃO ───────────────────────────────────────────────────────────

  @snapshot_anterior  = nil
  @ultimo_resultado   = nil
  @ultimo_resultado_multi = nil

  def self.snapshot_anterior;       @snapshot_anterior;       end
  def self.ultimo_resultado;        @ultimo_resultado;        end
  def self.ultimo_resultado_multi;  @ultimo_resultado_multi;  end

  def self.tirar_snapshot(resultado)
    @snapshot_anterior = Marshal.load(Marshal.dump(resultado)) rescue resultado.dup
  rescue
    @snapshot_anterior = nil
  end

  def self.comparar_memoriais(anterior, novo)
    return [] if anterior.nil? || novo.nil?
    mapa_ant = {}; mapa_nov = {}
    Array(anterior).each do |sec|
      sn = (sec["secao"] || sec[:secao]).to_s
      Array(sec["itens"] || sec[:itens]).each { |it| mapa_ant["#{sn}||#{it['chave']}"] = { secao: sn, desc: it["descricao"], qtd: it["quantidade"] } }
    end
    Array(novo).each do |sec|
      sn = (sec["secao"] || sec[:secao]).to_s
      Array(sec["itens"] || sec[:itens]).each { |it| mapa_nov["#{sn}||#{it['chave']}"] = { secao: sn, desc: it["descricao"], qtd: it["quantidade"] } }
    end
    alteracoes = []
    (mapa_ant.keys - mapa_nov.keys).each { |k| d = mapa_ant[k]; alteracoes << { tipo: "removido", secao: d[:secao], desc: d[:desc], qtd_ant: d[:qtd] } }
    (mapa_nov.keys - mapa_ant.keys).each { |k| d = mapa_nov[k]; alteracoes << { tipo: "novo",     secao: d[:secao], desc: d[:desc], qtd_nov: d[:qtd] } }
    (mapa_ant.keys & mapa_nov.keys).each do |k|
      a = mapa_ant[k]; n = mapa_nov[k]
      next if a[:desc] == n[:desc] && a[:qtd] == n[:qtd]
      alteracoes << { tipo: "alterado", secao: a[:secao], desc_ant: a[:desc], desc_nov: n[:desc], qtd_ant: a[:qtd], qtd_nov: n[:qtd] }
    end
    alteracoes
  end

  def self.comparar_memoriais_multi(anterior, novo)
    return [] if anterior.nil? || novo.nil?
    ant_map = {}; anterior.each { |e| ant_map[e["espaco"]] = e["secoes"] }
    nov_map = {}; novo.each     { |e| nov_map[e["espaco"]] = e["secoes"] }
    (ant_map.keys + nov_map.keys).uniq.flat_map do |esp|
      comparar_memoriais(ant_map[esp], nov_map[esp]).map { |d| d.merge(espaco: esp) }
    end
  end

  # ── KVA ───────────────────────────────────────────────────────────────────────

  def self.token_github
    Sketchup.read_default("STAND1_Memorial", "github_token", "").to_s.strip
  end

  def self.salvar_token_github(token)
    Sketchup.write_default("STAND1_Memorial", "github_token", token.to_s.strip)
  end

  # Normaliza qualquer formato (flat array ou nested por categoria) para flat.
  def self.normalizar_kva(parsed)
    if parsed.is_a?(Array)
      parsed
    else
      entradas = []
      parsed.each { |_cat, lista| Array(lista).each { |e| entradas << e if e["nome"] && e["kva"] } }
      entradas
    end
  end

  # Tabela embutida no plugin (ships no .rbz) — baseline sempre disponível, sem rede.
  def self.kva_table_bundled
    path = File.join(__dir__, 'kva_table.json')
    return [] unless File.exist?(path)
    normalizar_kva(JSON.parse(File.read(path)))
  rescue
    []
  end

  def self.kva_table_local
    raw = Sketchup.read_default("STAND1_Memorial", "kva_table", nil)
    # Sem tabela salva pelo usuário → usa a embutida no plugin (do disco).
    return kva_table_bundled if raw.nil? || raw.strip.empty?
    normalizar_kva(JSON.parse(raw))
  rescue
    kva_table_bundled
  end

  def self.salvar_kva_table_local(tabela)
    Sketchup.write_default("STAND1_Memorial", "kva_table", normalizar_kva(tabela).to_json)
  end

  def self.buscar_kva_github
    http_async(URL_KVA_RAW) do |body, ok|
      next unless ok && body
      begin
        tabela = JSON.parse(body)
        salvar_kva_table_local(tabela)
        flat = kva_table_local
        @dialog.execute_script("receberTabelaKVA(#{flat.to_json},#{token_github.to_json})") rescue nil
        # Recalcula badge (JS agora faz o cálculo, mas mantemos callback para compatibilidade)
        secoes = if modo_multi_espaco? && @ultimo_resultado_multi
          @ultimo_resultado_multi.flat_map { |e| e["secoes"] }
        else
          @ultimo_resultado || []
        end
        resultado_kva = calcular_kva(secoes)
        @dialog.execute_script("receberResultadoKVA(#{resultado_kva.to_json})") rescue nil
      rescue
      end
    end
  end

  def self.publicar_kva_github(tabela_json)
    # Salva local imediatamente (JS enviou flat array)
    begin
      tabela_obj = JSON.parse(tabela_json)
      salvar_kva_table_local(tabela_obj)
    rescue; end
    token = token_github
    if token.empty?
      # Sem token: salva só local, não tenta GitHub
      return
    end
    Thread.new do
      begin
        require 'net/http'; require 'openssl'; require 'base64'
        uri  = URI(URL_KVA_API)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true; http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.open_timeout = 10; http.read_timeout = 30
        req_get = Net::HTTP::Get.new(uri.request_uri)
        req_get["Authorization"] = "token #{token}"; req_get["User-Agent"] = "STAND1_Memorial/#{VERSAO}"
        sha = JSON.parse(http.request(req_get).body)["sha"] rescue nil
        tabela_obj = JSON.parse(tabela_json)
        body_put = { message: "kva_table: atualizado pelo plugin v#{VERSAO}", content: Base64.strict_encode64(JSON.pretty_generate(tabela_obj)) }
        body_put[:sha] = sha if sha
        req_put = Net::HTTP::Put.new(uri.request_uri)
        req_put["Authorization"] = "token #{token}"; req_put["User-Agent"] = "STAND1_Memorial/#{VERSAO}"
        req_put["Content-Type"] = "application/json"; req_put.body = body_put.to_json
        resp = http.request(req_put)
        if resp.code.to_i.between?(200, 201)
          @dialog.execute_script("sucessoKVAGitHub()") rescue nil
        else
          msg = JSON.parse(resp.body)["message"] rescue resp.body
          @dialog.execute_script("erroKVAGitHub(#{msg.to_json})") rescue nil
        end
      rescue => e
        @dialog.execute_script("erroKVAGitHub(#{e.message.to_json})") rescue nil
      end
    end
  end

  def self.calcular_kva(secoes_resultado)
    tabela = kva_table_local  # já retorna flat [{nome,kva,por}]
    return { "total" => 0, "secoes" => [], "sem_tabela" => true } if tabela.empty?
    entradas = tabela.select { |e| e["nome"] && e["kva"] }
    entradas.sort_by! { |e| -e["nome"].to_s.length }
    total_geral = 0.0
    secoes_kva  = []
    KVA_SECOES.each do |nome_secao|
      secao = secoes_resultado.find { |s| (s["secao"] || s[:secao]).to_s == nome_secao }
      next unless secao
      itens_kva = []
      Array(secao["itens"] || secao[:itens]).each do |item|
        desc = (item["descricao"] || item[:descricao]).to_s
        qtd  = (item["quantidade"] || item[:quantidade]).to_f
        entrada = entradas.find { |e| desc.downcase.include?(e["nome"].to_s.downcase) }
        if entrada
          kva_unit = entrada["kva"].to_f
          por      = entrada["por"].to_s
          if por == "metro"
            metros = desc.match(/\(([\d.,]+)\s*m\)/)&.captures&.first&.tr(",", ".")&.to_f || qtd
            kva_total = (kva_unit * metros).round(3)
          else
            kva_total = (kva_unit * qtd).round(3)
          end
          itens_kva << { "desc" => desc, "qtd" => qtd, "kva_unit" => kva_unit, "por" => por, "kva_total" => kva_total, "match" => entrada["nome"] }
          total_geral += kva_total
        else
          itens_kva << { "desc" => desc, "qtd" => qtd, "kva_total" => 0, "sem_cadastro" => true }
        end
      end
      subtotal = itens_kva.sum { |i| i["kva_total"].to_f }.round(3)
      secoes_kva << { "secao" => nome_secao, "itens" => itens_kva, "subtotal" => subtotal }
    end
    { "total" => total_geral.round(3), "secoes" => secoes_kva }
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
    puts "✅ STAND1_Memorial v#{VERSAO} carregado"
  end

end
