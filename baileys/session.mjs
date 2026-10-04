// One Baileys socket = one Channel::Whatsapp inbox (provider: baileys).
// Translates WhatsApp Web events into the 360dialog webhook shape that
// Whatsapp::IncomingMessageService already understands, so Rails needs no new parser.
import { EventEmitter } from 'node:events';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  DisconnectReason,
  downloadMediaMessage,
  fetchLatestBaileysVersion,
  jidNormalizedUser,
  makeWASocket,
  normalizeMessageContent,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';
import QRCode from 'qrcode';

const MAX_BACKOFF_MS = 60_000;
// ponytail: in-memory media index, lost on restart. Chatwoot downloads media right after the
// webhook, so a short-lived index is enough; persist to disk if downloads start missing.
const MEDIA_CACHE_SIZE = 500;
const SENT_IDS_SIZE = 1000;

const isDirectChat = jid => !!jid && (jid.endsWith('@s.whatsapp.net') || jid.endsWith('@lid'));
const jidToPhone = jid => /^(\d+)(?::\d+)?@s\.whatsapp\.net$/.exec(jid || '')?.[1] ?? null;

// Chatwoot only accepts digits or BSUID-shaped ids ("XX.abc") as WhatsApp source ids, so a contact
// hidden behind an "@lid" privacy id travels as "LI.<lid user>" and is turned back into the jid here.
const LID_PREFIX = 'LI.';
const lidToAddress = jid => `${LID_PREFIX}${jid.split('@')[0]}`;

export function toJid(address) {
  if (address.startsWith(LID_PREFIX)) return `${address.slice(LID_PREFIX.length)}@lid`;
  return `${address.replace(/\D/g, '')}@s.whatsapp.net`;
}

// For "@lid" chats WhatsApp often includes the real phone in key.senderPn / remoteJidAlt.
function contactIdentity(key) {
  const jid = key.remoteJid;
  const alt = [key.senderPn, key.remoteJidAlt].find(j => j?.endsWith('@s.whatsapp.net'));
  const phone = jidToPhone(jid) || jidToPhone(alt);
  const lid = jid.endsWith('@lid') ? lidToAddress(jidNormalizedUser(jid)) : null;
  return { phone, lid };
}

function receiptStatus(n) {
  if (n === 0) return 'failed';
  if (n === 2) return 'sent';
  if (n === 3) return 'delivered';
  if (n >= 4) return 'read';
  return null;
}

function contextId(content) {
  const inner = Object.values(content).find(v => v && typeof v === 'object' && v.contextInfo);
  return inner?.contextInfo?.stanzaId || null;
}

// Baileys message content -> 360dialog message body ({ type, text } / { type, image: {...} } ...).
function messageBody(m) {
  const c = normalizeMessageContent(m.message);
  if (!c) return null;
  const text = c.conversation || c.extendedTextMessage?.text;
  if (text) return { type: 'text', text: { body: text } };

  const media = (type, x) => ({
    type,
    [type]: { id: m.key.id, mime_type: x.mimetype || null, caption: x.caption || null, filename: x.fileName || null },
  });
  if (c.imageMessage) return media('image', c.imageMessage);
  if (c.videoMessage) return media('video', c.videoMessage);
  if (c.ptvMessage) return media('video', c.ptvMessage);
  if (c.audioMessage) return media('audio', c.audioMessage);
  if (c.documentMessage) return media('document', c.documentMessage);
  if (c.stickerMessage) return media('sticker', c.stickerMessage);

  const loc = c.locationMessage || c.liveLocationMessage;
  if (loc) {
    return {
      type: 'location',
      location: { latitude: loc.degreesLatitude, longitude: loc.degreesLongitude, name: loc.name || null, address: loc.address || null },
    };
  }
  // Contacts, polls, products, etc. land as Chatwoot's "unsupported message" placeholder.
  if (c.contactMessage || c.contactsArrayMessage || c.pollCreationMessage || c.pollCreationMessageV3 || c.productMessage) {
    return { type: 'unsupported' };
  }
  return null; // reactions, edits, revokes, key distribution: not chat messages
}

export class Session extends EventEmitter {
  status = 'connecting';
  qr = null;
  phone = null;
  sock = null;
  stopped = false;
  attempts = 0;
  timer = null;
  everConnected = false;
  media = new Map();
  sentIds = new Set();
  queue = Promise.resolve();

  constructor({ id, dir, webhookUrl, apiKey, logger }) {
    super();
    this.id = id;
    this.dir = dir;
    this.webhookUrl = webhookUrl;
    this.apiKey = apiKey;
    this.log = logger.child({ session: id });
  }

  static async load({ id, dir, apiKey, logger }) {
    const meta = JSON.parse(await readFile(path.join(dir, 'meta.json'), 'utf8'));
    return new Session({ id, dir, webhookUrl: meta.webhook_url, apiKey, logger });
  }

  toJSON() {
    return { id: this.id, status: this.status, qr: this.qr, phone_number: this.phone };
  }

  async start() {
    if (this.sock) return;
    this.stopped = false;
    this.status = 'connecting';
    await mkdir(this.dir, { recursive: true });
    await writeFile(path.join(this.dir, 'meta.json'), JSON.stringify({ webhook_url: this.webhookUrl }));
    const { state, saveCreds } = await useMultiFileAuthState(this.dir);
    const { version } = await fetchLatestBaileysVersion();
    if (this.stopped) return;

    const sock = makeWASocket({
      version,
      auth: state,
      browser: ['Chatwoot', 'Chrome', '1.0.0'],
      logger: this.log.child({ component: 'baileys' }, { level: process.env.BAILEYS_LOG_LEVEL || 'warn' }),
      keepAliveIntervalMs: 30_000,
      // Not "online" on connect: keeps notifications flowing to the phone.
      markOnlineOnConnect: false,
      syncFullHistory: false,
    });
    this.sock = sock;
    const current = () => this.sock === sock;

    sock.ev.on('creds.update', saveCreds);
    sock.ev.on('connection.update', update => current() && this.onConnectionUpdate(update));
    sock.ev.on('messages.upsert', ({ messages }) => current() && messages.forEach(m => this.onMessage(m)));
    sock.ev.on('messages.update', updates => current() && updates.forEach(u => this.onReceipt(u)));
  }

  async onConnectionUpdate({ connection, lastDisconnect, qr }) {
    if (qr) {
      this.status = 'qr';
      this.qr = await QRCode.toDataURL(qr);
    }
    if (connection === 'open') {
      this.attempts = 0;
      this.everConnected = true;
      this.status = 'connected';
      this.qr = null;
      this.phone = jidToPhone(this.sock.user?.id);
      this.log.info({ phone: this.phone }, 'connected');
    }
    if (connection !== 'close') return;

    const code = lastDisconnect?.error?.output?.statusCode;
    this.sock = null;
    if (code === DisconnectReason.loggedOut) {
      // Device removed from the phone: saved creds are dead, a new QR scan is required.
      this.log.warn('logged out from phone');
      await this.reset();
      return;
    }
    if (!this.everConnected && code === DisconnectReason.timedOut) {
      // Nobody scanned the QR in time; stop instead of generating QR codes forever.
      this.status = 'disconnected';
      this.qr = null;
      return;
    }
    this.status = 'disconnected';
    this.scheduleReconnect(code === DisconnectReason.restartRequired);
  }

  scheduleReconnect(immediate) {
    if (this.stopped || this.timer) return;
    const delay = immediate ? 0 : Math.min(2_500 * 2 ** this.attempts, MAX_BACKOFF_MS);
    if (!immediate) this.attempts += 1;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.start().catch(err => {
        this.log.error({ err: String(err) }, 'reconnect failed');
        this.scheduleReconnect(false);
      });
    }, delay);
  }

  onMessage(m) {
    if (!m.key?.id || !isDirectChat(m.key.remoteJid)) return;
    const body = messageBody(m);
    if (!body) return;
    // Our own API sends come back as fromMe upserts; Chatwoot already has those messages.
    if (m.key.fromMe && this.sentIds.has(m.key.id)) return;

    if (body[body.type]?.id) this.rememberMedia(m, body[body.type].mime_type);

    const { phone, lid } = contactIdentity(m.key);
    const message = { id: m.key.id, timestamp: String(m.messageTimestamp || Math.floor(Date.now() / 1000)), ...body };
    const quoted = contextId(normalizeMessageContent(m.message) || {});
    if (quoted) message.context = { id: quoted };

    if (m.key.fromMe) {
      // Sent from the phone itself: echo it so the agent sees the whole thread.
      this.deliver({ message_echoes: [{ ...message, from: this.phone, to: phone, to_user_id: lid }] });
      return;
    }
    this.deliver({
      contacts: [{ profile: { name: m.pushName || null }, wa_id: phone, user_id: lid }],
      messages: [{ ...message, from: phone || lid }],
    });
  }

  onReceipt({ key, update }) {
    if (!key?.fromMe || update?.status == null) return;
    const status = receiptStatus(update.status);
    if (status) this.deliver({ statuses: [{ id: key.id, status, timestamp: String(Math.floor(Date.now() / 1000)) }] });
  }

  rememberMedia(m, mime) {
    this.media.set(m.key.id, { message: m, mime });
    if (this.media.size > MEDIA_CACHE_SIZE) this.media.delete(this.media.keys().next().value);
  }

  async downloadMedia(mediaId) {
    const entry = this.media.get(mediaId);
    if (!entry || !this.sock) return null;
    const buffer = await downloadMediaMessage(entry.message, 'buffer', {}, {
      logger: this.log,
      reuploadRequest: this.sock.updateMediaMessage,
    });
    return { buffer, mime: entry.mime || 'application/octet-stream' };
  }

  // Webhooks go out one at a time per session so Chatwoot sees messages in order.
  deliver(payload) {
    this.queue = this.queue.then(() => this.post(payload)).catch(err => this.log.error({ err: String(err) }, 'webhook failed'));
  }

  // ponytail: 3 attempts then drop. Add a durable outbox if Chatwoot downtime starts losing messages.
  async post(payload, attempt = 1) {
    const res = await fetch(this.webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${this.apiKey}` },
      body: JSON.stringify(payload),
    }).catch(err => ({ ok: false, status: String(err) }));
    if (res.ok) return;
    if (attempt >= 3) throw new Error(`webhook ${res.status}`);
    await new Promise(r => setTimeout(r, 1_000 * attempt));
    await this.post(payload, attempt + 1);
  }

  async send(to, content) {
    if (this.status !== 'connected' || !this.sock) {
      throw Object.assign(new Error('WhatsApp is not linked. Scan the QR code in the inbox settings.'), { status: 409 });
    }
    const jid = toJid(to);
    await this.simulateTyping(jid);
    const sent = await this.sock.sendMessage(jid, content);
    const id = sent?.key?.id;
    if (!id) throw new Error('WhatsApp returned no message id');
    this.sentIds.add(id);
    if (this.sentIds.size > SENT_IDS_SIZE) this.sentIds.delete(this.sentIds.values().next().value);
    return id;
  }

  // Anti-ban: show "typing…" briefly before sending, like a person would.
  async simulateTyping(jid) {
    try {
      await this.sock.sendPresenceUpdate('composing', jid);
      await new Promise(r => setTimeout(r, 600 + Math.random() * 900));
      await this.sock.sendPresenceUpdate('paused', jid);
    } catch {
      /* presence is best-effort */
    }
  }

  async stop() {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const sock = this.sock;
    this.sock = null;
    try {
      sock?.end(undefined);
    } catch {
      /* already closed */
    }
    if (this.status !== 'logged_out') this.status = 'disconnected';
  }

  // Unlinks the device (if still linked) and deletes the login, so the next start shows a fresh QR.
  async logout() {
    try {
      await this.sock?.logout();
    } catch {
      /* already unlinked */
    }
    await this.reset();
  }

  async reset() {
    await this.stop();
    await rm(this.dir, { recursive: true, force: true });
    this.status = 'logged_out';
    this.qr = null;
    this.phone = null;
    this.everConnected = false;
  }
}
