// WhatsApp Web (Baileys) sidecar for Channel::Whatsapp provider "baileys".
// Rails talks to it through Whatsapp::Providers::WhatsappBaileysService; it posts inbound
// events back to Chatwoot's existing /webhooks/whatsapp/:phone_number route.
//
// Every route except GET /health needs `Authorization: Bearer $BAILEYS_API_KEY`.
//   PUT    /sessions/:id                 { webhook_url }  start (or resume) a session, idempotent
//   GET    /sessions/:id                 -> { status, qr, phone_number }
//   DELETE /sessions/:id                 unlink the device and forget the login
//   POST   /sessions/:id/messages        { to, type, text?, url?, caption?, filename? } -> { messages: [{ id }] }
//   GET    /sessions/:id/media/:media_id -> file bytes
import { readdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';
import pino from 'pino';
import { Session } from './session.mjs';

const API_KEY = process.env.BAILEYS_API_KEY;
const PORT = Number(process.env.BAILEYS_PORT || process.env.PORT || 4100);
// Defaults to the repo's gitignored storage/ folder in development; set it to the volume in production.
const SESSIONS_DIR = path.resolve(process.env.BAILEYS_SESSIONS_DIR || fileURLToPath(new URL('../storage/baileys', import.meta.url)));
const logger = pino({ level: process.env.LOG_LEVEL || 'info' });

if (!API_KEY) {
  logger.fatal('BAILEYS_API_KEY is required');
  process.exit(1);
}

const sessions = new Map();

function authorized(req) {
  const given = Buffer.from(req.headers.authorization || '');
  const expected = Buffer.from(`Bearer ${API_KEY}`);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

const error = message => ({ error: { message } });

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readJson(req) {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  return raw ? JSON.parse(raw) : {};
}

function sessionFor(id, webhookUrl) {
  let session = sessions.get(id);
  if (!session) {
    session = new Session({ id, dir: path.join(SESSIONS_DIR, id), webhookUrl, apiKey: API_KEY, logger });
    sessions.set(id, session);
  }
  if (webhookUrl) session.webhookUrl = webhookUrl;
  return session;
}

// Chatwoot message -> Baileys content. Media is fetched by Baileys from the attachment URL.
function outgoingContent({ type, text, url, caption, filename, mime_type }) {
  switch (type) {
    case 'text':
      return { text };
    case 'image':
      return { image: { url }, caption };
    case 'video':
      return { video: { url }, caption };
    case 'audio':
      return { audio: { url }, mimetype: mime_type || 'audio/mpeg' };
    case 'document':
      return { document: { url }, fileName: filename, mimetype: mime_type || 'application/octet-stream', caption };
    default:
      throw Object.assign(new Error(`unsupported type ${type}`), { status: 422 });
  }
}

const routes = [
  ['PUT', /^\/sessions\/([\w-]+)$/, async (req, res, [id]) => {
    const { webhook_url: webhookUrl } = await readJson(req);
    if (!webhookUrl) return json(res, 422, error('webhook_url is required'));
    const session = sessionFor(id, webhookUrl);
    await session.start();
    return json(res, 200, session);
  }],
  ['GET', /^\/sessions\/([\w-]+)$/, async (req, res, [id]) => {
    const session = sessions.get(id);
    return json(res, 200, session || { id, status: 'logged_out', qr: null, phone_number: null });
  }],
  ['DELETE', /^\/sessions\/([\w-]+)$/, async (req, res, [id]) => {
    await sessions.get(id)?.logout();
    sessions.delete(id);
    return json(res, 200, { id, status: 'logged_out' });
  }],
  ['POST', /^\/sessions\/([\w-]+)\/messages$/, async (req, res, [id]) => {
    const session = sessions.get(id);
    if (!session) return json(res, 404, error('session not found'));
    const body = await readJson(req);
    if (!body.to) return json(res, 422, error('to is required'));
    const messageId = await session.send(body.to, outgoingContent(body));
    return json(res, 200, { messages: [{ id: messageId }] });
  }],
  ['GET', /^\/sessions\/([\w-]+)\/media\/([\w-]+)$/, async (req, res, [id, mediaId]) => {
    const media = await sessions.get(id)?.downloadMedia(mediaId);
    if (!media) return json(res, 404, error('media not found'));
    res.writeHead(200, { 'Content-Type': media.mime, 'Content-Length': media.buffer.length });
    return res.end(media.buffer);
  }],
];

const server = createServer(async (req, res) => {
  const { pathname } = new URL(req.url, 'http://localhost');
  if (req.method === 'GET' && pathname === '/health') return json(res, 200, { ok: true, sessions: sessions.size });
  if (!authorized(req)) return json(res, 401, error('unauthorized'));

  for (const [method, pattern, handler] of routes) {
    const match = req.method === method && pattern.exec(pathname);
    if (!match) continue;
    try {
      return await handler(req, res, match.slice(1));
    } catch (err) {
      logger.error({ err: String(err), path: pathname }, 'request failed');
      return json(res, err.status || 500, error(err.message));
    }
  }
  return json(res, 404, error('not found'));
});

// Resume every linked number after a restart; logins live on disk, one folder per session.
async function resumeSessions() {
  const dirs = await readdir(SESSIONS_DIR, { withFileTypes: true }).catch(() => []);
  await Promise.all(
    dirs.filter(d => d.isDirectory()).map(async d => {
      try {
        const session = await Session.load({ id: d.name, dir: path.join(SESSIONS_DIR, d.name), apiKey: API_KEY, logger });
        sessions.set(d.name, session);
        await session.start();
      } catch (err) {
        logger.warn({ session: d.name, err: String(err) }, 'could not resume session');
      }
    })
  );
}

await resumeSessions();
server.listen(PORT, () => logger.info({ port: PORT, sessions: sessions.size, dir: SESSIONS_DIR }, 'baileys sidecar listening'));

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    await Promise.all([...sessions.values()].map(s => s.stop()));
    process.exit(0);
  });
}
