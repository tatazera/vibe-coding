require 'sketchup.rb'
require 'extensions.rb'

stand1_ext = SketchupExtension.new(
  "STAND1_Memorial",
  "STAND1_Memorial/core"
)

stand1_ext.version     = "7.2.1"
stand1_ext.creator     = "Stand1 Producoes"
stand1_ext.copyright   = "2025, Stand1 Producoes"
stand1_ext.description = "Gera Memorial Descritivo em PDF/TXT a partir de Componentes do modelo SketchUp, com identidade visual Stand1."

Sketchup.register_extension(stand1_ext, true)
