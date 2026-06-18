# Testes do módulo puro de dimensões — rodar fora do SketchUp:
#   ruby tests/test_dimensoes.rb
# Unidades dos testes: metros (o módulo é agnóstico de unidade em calcular/
# dims_lineares/chave_dims; metro() converte polegadas).

require_relative '../dimensoes'

D = STAND1_Memorial::Dimensoes

$falhas = 0
$num = 0

def teste(nome)
  $num += 1
  ok = yield
  if ok
    puts "  ok  #{$num}. #{nome}"
  else
    $falhas += 1
    puts "FALHA #{$num}. #{nome}"
  end
end

def aprox(a, b, tol = 0.001)
  (a - b).abs < tol
end

IDENT = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

def rot_z(graus)
  r = graus * Math::PI / 180
  c, s = Math.cos(r), Math.sin(r)
  [[c, s, 0], [-s, c, 0], [0, 0, 1]]
end

# eixo local Y apontando para Z do mundo (peça "deitada": local Z vira -Y mundo)
ROT_X90 = [[1, 0, 0], [0, 0, 1], [0, -1, 0]]

puts "── Dimensoes.calcular ──"

teste("painel alinhado 2.0×0.5×2.5: altura = 2.5 (bug antigo dizia 0.5)") do
  d = D.calcular(IDENT, [2.0, 0.5, 2.5])
  aprox(d[:largura], 2.0) && aprox(d[:profund], 0.5) && aprox(d[:altura], 2.5)
end

teste("brise 3.0×0.1×2.2 rot 45° em Z mantém dims reais (AABB inflava)") do
  d = D.calcular(rot_z(45), [3.0, 0.1, 2.2])
  aprox(d[:largura], 3.0) && aprox(d[:profund], 0.1) && aprox(d[:altura], 2.2)
end

teste("coluna deitada (local Z horizontal): altura = 0.3, largura = 2.5") do
  # peça modelada 0.3×0.3×2.5 (Z local = comprimento), rotacionada deitada
  d = D.calcular(ROT_X90, [0.3, 0.3, 2.5])
  aprox(d[:altura], 0.3) && aprox(d[:largura], 2.5) && aprox(d[:profund], 0.3)
end

teste("coluna em pé: altura = 2.5") do
  d = D.calcular(IDENT, [0.3, 0.3, 2.5])
  aprox(d[:altura], 2.5) && aprox(d[:largura], 0.3)
end

teste("espelhada (escala -1 em X) = mesmas dims e mesma chave") do
  esp = [[-1, 0, 0], [0, 1, 0], [0, 0, 1]]
  d1 = D.calcular(IDENT, [2.0, 0.5, 2.5])
  d2 = D.calcular(esp,   [2.0, 0.5, 2.5])
  d1 == d2 &&
    D.chave_dims(d1[:largura], d1[:profund], d1[:altura]) ==
    D.chave_dims(d2[:largura], d2[:profund], d2[:altura])
end

teste("grupo pai escalado 2×: dims dobram") do
  dupla = [[2, 0, 0], [0, 2, 0], [0, 0, 2]]
  d = D.calcular(dupla, [1.0, 0.5, 2.0])
  aprox(d[:largura], 2.0) && aprox(d[:profund], 1.0) && aprox(d[:altura], 4.0)
end

teste("escala não-uniforme só em X") do
  sx = [[3, 0, 0], [0, 1, 0], [0, 0, 1]]
  d = D.calcular(sx, [1.0, 0.5, 2.0])
  aprox(d[:largura], 3.0) && aprox(d[:profund], 0.5) && aprox(d[:altura], 2.0)
end

teste("pai rot +45° + instância rot -45° = peça reta exata") do
  # composição das duas rotações = identidade
  a = rot_z(45); b = rot_z(-45)
  comp = Array.new(3) { |i|
    Array.new(3) { |j| (0..2).sum { |k| a[k][j] * b[i][k] } }
  }
  d = D.calcular(comp, [3.0, 0.1, 2.2])
  aprox(d[:largura], 3.0) && aprox(d[:profund], 0.1) && aprox(d[:altura], 2.2)
end

teste("piso 4.0×3.0×0.05: horizontais 4×3, espessura 0.05, área 12 m²") do
  d = D.calcular(IDENT, [4.0, 3.0, 0.05])
  aprox(d[:largura], 4.0) && aprox(d[:profund], 3.0) && aprox(d[:altura], 0.05) &&
    aprox(d[:largura] * d[:profund], 12.0)
end

teste("tablado alto 3.0×0.4×0.6: caso onde '2 maiores' errava") do
  # '2 maiores' daria 3.0×0.6; horizontais corretas são 3.0×0.4
  d = D.calcular(IDENT, [3.0, 0.4, 0.6])
  aprox(d[:largura], 3.0) && aprox(d[:profund], 0.4) && aprox(d[:altura], 0.6)
end

puts "── Dimensoes.dims_lineares (7B) ──"

teste("coluna em pé 0.3×0.3×2.5 → 2.5 × 0.3") do
  d1, d2 = D.dims_lineares(0.3, 0.3, 2.5)
  aprox(d1, 2.5) && aprox(d2, 0.3)
end

teste("viga deitada 3.0×0.15×0.15 → 3.0 × 0.15") do
  d1, d2 = D.dims_lineares(3.0, 0.15, 0.15)
  aprox(d1, 3.0) && aprox(d2, 0.15)
end

puts "── Dimensoes.chave_dims ──"

teste("mesma peça em 3 orientações → 1 chave única") do
  pecas = [IDENT, ROT_X90, rot_z(90)].map { |m| D.calcular(m, [0.3, 0.3, 2.5]) }
  chaves = pecas.map { |d| D.chave_dims(d[:largura], d[:profund], d[:altura]) }
  chaves.uniq.size == 1
end

puts "── Dimensoes.metro ──"

teste("conversão polegada→metro com arredondamento") do
  aprox(D.metro(39.3701), 1.0) && aprox(D.metro(118.11), 3.0)
end

teste("eixo degenerado (escala 0) sem divisão por zero") do
  zero = [[0, 0, 0], [0, 1, 0], [0, 0, 1]]
  d = D.calcular(zero, [2.0, 0.5, 2.5])
  d[:altura] >= 0 && d[:largura] >= 0
end

puts ""
if $falhas.zero?
  puts "#{$num}/#{$num} testes OK"
else
  puts "#{$falhas} FALHA(S) em #{$num} testes"
  exit 1
end
