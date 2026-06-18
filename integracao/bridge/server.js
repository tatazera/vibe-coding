'use strict';

const express = require('express');
const cors    = require('cors');
const fs      = require('fs');
const path    = require('path');
const crypto  = require('crypto');

const app   = express();
const PORT  = process.env.PORT  || 3000;
const TOKEN = process.env.BRIDGE_TOKEN || '';
const DATA  = path.join('/app/data', 'entradas.json');

app.use(cors());
app.use(express.json({ limit: '1mb' }));

// Carrega entradas persistidas em disco
function lerEntradas() {
  try {
    if (fs.existsSync(DATA)) return JSON.parse(fs.readFileSync(DATA, 'utf8'));
  } catch (e) {}
  return [];
}

// Persiste em disco para sobreviver a restart do container
function salvarEntradas(lista) {
  fs.mkdirSync(path.dirname(DATA), { recursive: true });
  fs.writeFileSync(DATA, JSON.stringify(lista, null, 2), 'utf8');
}

// Middleware de autenticação Bearer
function auth(req, res, next) {
  if (!TOKEN) return next(); // sem token configurado = aberto (não recomendado em prod)
  const header = req.headers['authorization'] || '';
  if (header !== `Bearer ${TOKEN}`) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

// ── GET /entradas ──────────────────────────────────────────────────────────────
// Dashboard faz polling nessa rota a cada N segundos
// Retorna apenas entradas com status "pendente" (não processadas ainda pelo dashboard)
app.get('/entradas', auth, (req, res) => {
  const todas = lerEntradas();
  res.json(todas.filter(e => e._status === 'pendente'));
});

// ── POST /entradas ─────────────────────────────────────────────────────────────
// n8n envia aqui após extrair os dados com Claude
// Aceita objeto único ou array
app.post('/entradas', auth, (req, res) => {
  const payload = req.body;
  if (!payload) return res.status(400).json({ error: 'Body vazio' });

  const lista  = Array.isArray(payload) ? payload : [payload];
  const novas  = [];
  const todas  = lerEntradas();
  const ids    = new Set(todas.map(e => e.id));

  lista.forEach(item => {
    if (!item.nome) return; // campo obrigatório mínimo
    const entrada = {
      id:      item.id    || ('wpp_' + crypto.randomUUID()),
      who:     item.who   || item.solic || 'WhatsApp',
      solic:   item.solic || item.who   || '',
      nome:    (item.nome || '').toUpperCase().trim(),
      prior:   ['Alta','Média','Nula'].includes(item.prior) ? item.prior : 'Nula',
      prazo:   item.prazo || '',
      nota:    item.nota  || '',
      msg:     item.msg   || '',
      time:    item.time  || new Date().toLocaleString('pt-BR', { timeZone: 'America/Bahia' }),
      _status: 'pendente',
      _ts:     Date.now()
    };
    if (!ids.has(entrada.id)) {
      todas.push(entrada);
      novas.push(entrada.id);
      ids.add(entrada.id);
    }
  });

  salvarEntradas(todas);
  res.json({ ok: true, inseridas: novas.length, ids: novas });
});

// ── DELETE /entradas/:id ───────────────────────────────────────────────────────
// Dashboard chama após processar uma entrada (marcar como consumida)
app.delete('/entradas/:id', auth, (req, res) => {
  let todas = lerEntradas();
  const antes = todas.length;
  todas = todas.filter(e => e.id !== req.params.id);
  salvarEntradas(todas);
  res.json({ ok: true, removidas: antes - todas.length });
});

// ── PATCH /entradas/:id ────────────────────────────────────────────────────────
// Marca entrada como processada sem remover (para auditoria)
app.patch('/entradas/:id', auth, (req, res) => {
  const todas = lerEntradas();
  const e = todas.find(x => x.id === req.params.id);
  if (!e) return res.status(404).json({ error: 'Não encontrada' });
  Object.assign(e, req.body, { id: e.id }); // não permite sobrescrever id
  salvarEntradas(todas);
  res.json({ ok: true });
});

// ── GET /health ────────────────────────────────────────────────────────────────
app.get('/health', (_, res) => res.json({ ok: true, ts: Date.now() }));

app.listen(PORT, () => console.log(`Stand1 Bridge rodando na porta ${PORT}`));
