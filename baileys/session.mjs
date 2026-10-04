// One Baileys socket = one Channel::Whatsapp inbox (provider: baileys).
// Translates WhatsApp Web events into the 360dialog webhook shape that
// Whatsapp::IncomingMessageService already understands, so Rails needs no new parser.
import { EventEmitter } from 'node:events';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  ALL_WA_PATCH_NAMES,
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
// History sync on first link: how far back to import (0 disables) and how many messages per webhook.
const HISTORY_DAYS = Number(process.env.BAILEYS_HISTORY_DAYS ?? 30);
const HISTORY_BATCH_SIZE = 100;
const DIRECTORY_BATCH_SIZE = 500;

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

const norm = jid => (jid ? jidNormalizedUser(jid) || null : null);
const isLidJid = jid => !!jid && jid.endsWith('@lid');

// Address-book / contact-sync record -> directory entry. `name` is the linked phone's saved name, `notify`
// the name the person set themselves. `id` can be either their phone jid or their "@lid".
function identityOfContact(c) {
  const phone = [c.jid, c.phoneNumber, c.id].map(norm).map(jidToPhone).find(Boolean) || null;
  const lidJid = [c.lid, c.id].map(norm).find(isLidJid);
  if (!phone && !lidJid) return null;
  return { phone, lid: lidJid ? lidToAddress(lidJid) : null, name: c.name || null, push_name: c.notify || c.verifiedName || null };
}

// History-sync chat -> directory entry. 1:1 chats carry both ids and the chat's (saved) name.
function identityOfChat(chat) {
  const id = norm(chat.id);
  const phone = jidToPhone(norm(chat.pnJid)) || jidToPhone(id);
  const lidJid = [chat.lidJid, id].map(norm).find(isLidJid);
  if (!phone && !lidJid) return null;
  return { phone, lid: lidJid ? lidToAddress(lidJid) : null, name: chat.name || null, push_name: null };
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
  // Who is who: phone <-> "@lid" and names, keyed "p:<phone>" or "l:<LI.id>". Persisted next to the login.
  directory = new Map();
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
    await this.loadDirectory();
    const { state, saveCreds } = await useMultiFileAuthState(this.dir);
    this.auth = state;
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
      // The phone streams its chat history once, right after a fresh link (messaging-history.set).
      syncFullHistory: HISTORY_DAYS > 0,
    });
    this.sock = sock;
    const current = () => this.sock === sock;

    sock.ev.on('creds.update', saveCreds);
    sock.ev.on('connection.update', update => current() && this.onConnectionUpdate(update));
    sock.ev.on('messages.upsert', ({ messages }) => current() && messages.forEach(m => this.onMessage(m)));
    sock.ev.on('messages.update', updates => current() && updates.forEach(u => this.onReceipt(u)));
    sock.ev.on('messaging-history.set', batch => current() && this.onHistory(batch));
    sock.ev.on('contacts.upsert', cs => current() && this.shareDirectory(this.mergeDirectory(cs.map(identityOfContact))));
    sock.ev.on('contacts.update', cs => current() && this.shareDirectory(this.mergeDirectory(cs.map(identityOfContact))));
    sock.ev.on('chats.phoneNumberShare', ({ lid, jid }) => current() && this.shareDirectory(this.mergeDirectory([identityOfContact({ id: lid, lid, jid })])));
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
      // Numbers linked before the directory existed never sent their contact list: ask the phone again once.
      if (this.directory.size === 0) setTimeout(() => this.resyncContacts(), 15_000);
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
      contacts: [{ profile: { name: m.pushName || this.nameFor(phone, lid) }, wa_id: phone, user_id: lid }],
      messages: [{ ...message, from: phone || lid }],
    });
  }

  onReceipt({ key, update }) {
    if (!key?.fromMe || update?.status == null) return;
    const status = receiptStatus(update.status);
    if (status) this.deliver({ statuses: [{ id: key.id, status, timestamp: String(Math.floor(Date.now() / 1000)) }] });
  }

  // Old messages from the phone's history sync. Media is not downloaded: Chatwoot stores a placeholder.
  onHistory({ messages, chats, contacts }) {
    if (HISTORY_DAYS <= 0 || !Array.isArray(messages)) return;
    const cutoff = Date.now() / 1000 - HISTORY_DAYS * 86_400;
    const changed = this.mergeDirectory([...(contacts || []).map(identityOfContact), ...(chats || []).map(identityOfChat)]);

    const history = messages.flatMap(m => {
      const timestamp = Number(m.messageTimestamp || 0);
      if (!m.key?.id || !isDirectChat(m.key.remoteJid) || timestamp < cutoff) return [];
      const body = messageBody(m);
      if (!body || body.type === 'unsupported') return [];
      const { phone, lid } = contactIdentity(m.key);
      const media = body[body.type];
      return [{
        id: m.key.id,
        timestamp,
        from_me: !!m.key.fromMe,
        phone,
        lid,
        name: this.nameFor(phone, lid) || (m.key.fromMe ? null : m.pushName || null),
        type: body.type,
        text: body.text?.body || media?.caption || null,
      }];
    });

    for (let i = 0; i < history.length; i += HISTORY_BATCH_SIZE) this.deliver({ history: history.slice(i, i + HISTORY_BATCH_SIZE) });
    if (history.length) this.log.info({ messages: history.length }, 'history batch queued');
    // After the history, so the contacts it creates exist when their names arrive.
    this.shareDirectory(changed);
  }

  nameFor(phone, lid) {
    const entry = (phone && this.directory.get(`p:${phone}`)) || (lid && this.directory.get(`l:${lid}`));
    return entry?.name || entry?.push_name || null;
  }

  // Folds new identities into the directory; returns the entries that changed.
  mergeDirectory(identities) {
    const changed = new Map();
    for (const identity of identities) {
      if (!identity) continue;
      const lidKey = identity.lid && `l:${identity.lid}`;
      const phone = identity.phone || (lidKey && this.directory.get(lidKey)?.phone) || null;
      const key = phone ? `p:${phone}` : lidKey;
      const previous = { ...(lidKey && this.directory.get(lidKey)), ...this.directory.get(key) };
      const next = {
        phone,
        lid: identity.lid || previous.lid || null,
        name: identity.name || previous.name || null,
        push_name: identity.push_name || previous.push_name || null,
      };
      if (JSON.stringify(next) === JSON.stringify({ phone: null, lid: null, name: null, push_name: null, ...previous })) continue;
      this.directory.set(key, next);
      // Keep the "@lid" alias pointing at the same entry, so lookups by either id agree.
      if (next.lid && key !== `l:${next.lid}`) this.directory.set(`l:${next.lid}`, next);
      changed.set(key, next);
    }
    if (changed.size) this.saveDirectory();
    return [...changed.values()];
  }

  shareDirectory(entries) {
    for (let i = 0; i < entries.length; i += DIRECTORY_BATCH_SIZE) this.deliver({ directory: entries.slice(i, i + DIRECTORY_BATCH_SIZE) });
  }

  async loadDirectory() {
    if (this.directory.size) return;
    try {
      const entries = JSON.parse(await readFile(path.join(this.dir, 'directory.json'), 'utf8'));
      for (const [key, value] of entries) this.directory.set(key, value);
    } catch {
      /* first run: no directory yet */
    }
  }

  saveDirectory() {
    writeFile(path.join(this.dir, 'directory.json'), JSON.stringify([...this.directory])).catch(err =>
      this.log.warn({ err: String(err) }, 'could not save directory')
    );
  }

  // Forget how far the contact list was synced, so the phone re-sends every contact (contacts.upsert).
  async resyncContacts() {
    if (!this.sock || !this.auth || this.status !== 'connected') return;
    try {
      await this.auth.keys.set({ 'app-state-sync-version': Object.fromEntries(ALL_WA_PATCH_NAMES.map(n => [n, null])) });
      await this.sock.resyncAppState(ALL_WA_PATCH_NAMES, true);
      this.log.info({ entries: this.directory.size }, 'contact list resynced');
    } catch (err) {
      this.log.warn({ err: String(err) }, 'contact resync failed');
    }
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
