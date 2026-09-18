# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

eva_ext = SketchupExtension.new('EVA Stand1', 'STAND1_EVA/core')
eva_ext.description = 'Exportador padronizado de Scenes, gerador de prompts para render com IA, tratamento de logos e Mapa de Artes.'
eva_ext.version     = '2.4.0'
eva_ext.creator     = 'Stand1 Producoes'
eva_ext.copyright   = '2025 Stand1 Producoes'

Sketchup.register_extension(eva_ext, true)
