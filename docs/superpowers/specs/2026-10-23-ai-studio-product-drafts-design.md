# AI Studio: product-aware reply drafts

Date: 2026-10-23
Status: draft for approval

## Intent

Buyers on Shopee (and later WhatsApp) ask questions about specific products. The owner
answers each one by hand today. We want an agent that notices each buyer enquiry, works out
which product it is about, loads that product's prompt and context, and writes a reply.
For now the owner approves every reply before it goes to the buyer.

We build on Chatwoot's existing Captain AI agent instead of starting from zero. Captain already
has the agent loop, LLM plumbing, FAQ search and an assistant UI. It is missing a per-product
knowledge model and a draft-first reply mode. This fork is self-hosted, so the premium and
enterprise gates on Captain are removed.

## Goals

1. Captain is available on this install with no paid plan or cloud check.
2. A new **AI Studio** area lists products. Clicking a product shows what the item is, its prompt
   and its context, all editable.
3. On every incoming buyer message in a linked inbox, the agent writes a **draft reply** that uses
   the matched product's prompt and context.
4. The owner sees the draft in the conversation and can **Send**, **Edit** or **Discard** it.

## Non-goals (for now)

- Auto-sending replies to buyers. Keep a per-assistant switch so it can be turned on later, but
  only draft mode ships now.
- Importing products from the Shopee catalog. Products are added by hand in AI Studio.
  (A port of `Shopee-Seller-Management-System/adapters/shopee/catalog.ts` is a later step.)
- Product images, prices or stock in the product record.
- WhatsApp product cards. WhatsApp inboxes are in scope at launch, but they match products by
  text search only.
- Fixing the Shopee seller-echo race (see Known risks).

## Anti-goals

- Anything reaching the buyer without the owner clicking Send.
- The agent changing conversation state on its own in draft mode: no handoff message, no
  resolve, no labels, no priority, no notes.
- A draft that answers about the wrong product with confidence. If no product matches, the
  draft must say so in its wording or stay generic, not invent product facts.

## Decisions made with the owner

- **LLM provider: OpenAI itself.** `CAPTAIN_OPEN_AI_API_KEY` with the default endpoint. Embeddings
  use `text-embedding-3-small` (1536 dims), which matches the existing `vector(1536)` columns.
- **Launch inboxes: Shopee and WhatsApp** (both Baileys and Cloud API providers on
  `Channel::Whatsapp`). Captain's inbox-linking UI must list Shopee and WhatsApp inboxes
  (check `InboxCard.vue` and the empty-state inbox list for channel-type allowlists).
- **A card-only buyer message still gets a draft.** When a buyer sends only a product card, the
  draft greets them about that product (for example, confirms the item and asks what they want
  to know) using its context.
- **Build on Captain.** Captain is built on the `ai-agents` gem for the agent loop and
  `ruby_llm` for the LLM calls. It is not LangChain. The provider is OpenAI or any
  OpenAI-compatible endpoint (`CAPTAIN_OPEN_AI_API_KEY`, `CAPTAIN_OPEN_AI_ENDPOINT`).
- **Remove the premium flag and the enterprise gate.** We host this ourselves.
- **Products are added by the owner** in AI Studio.
- **Event-driven, not cron.** The original idea was a cron that pulls messages every minute.
  Captain already reacts to each incoming message within seconds and skips the reply when a
  newer buyer message arrives. The owner accepted this.
- **Draft mode.** The owner approves every reply. The draft is shown as a card above the reply
  box with Send / Edit / Discard, and the conversation list shows a badge when a draft is
  waiting.

## Design

### 1. Remove the gates

Current gates (all must stop blocking on this install):

| Gate | Location |
| --- | --- |
| `captain_integration` is `premium: true`, `enabled: false` | `config/features.yml:143` |
| Flag auto-enabled only on paid self-hosted | `enterprise/app/models/enterprise/account.rb:105`, `ChatwootApp.self_hosted_paid?` in `lib/chatwoot_app.rb:28` |
| Sidebar routes allow only CLOUD / ENTERPRISE installs | `app/javascript/dashboard/routes/dashboard/captain/captain.routes.js:31,42` |
| Premium list on the frontend | `app/javascript/dashboard/featureFlags.js:62` |
| Tools page needs `custom_tools` flag | `enterprise/app/controllers/.../custom_tools_controller.rb:57` |
| Model forced to `gpt-5.2` when the flag is on | `lib/llm/feature_router.rb:4,50` |
| Installation model override honoured only when paid | `lib/llm/feature_router.rb` `installation_model_override` |
| Usage limits | `enterprise/app/models/enterprise/inbox.rb:22` (`more_responses?`) |

Required outcome:
- `captain_integration` (and `custom_tools`) are on for every account, existing and new, with no
  paywall shown.
- Captain sidebar entries show on this install.
- `CAPTAIN_OPEN_AI_MODEL` decides the assistant model. No hardcoded `gpt-5.2`.
- Usage limits never block.

Watch out: setting `INSTALLATION_PRICING_PLAN=enterprise` in config alone is not enough.
`enterprise/app/jobs/enterprise/internal/check_new_versions_job.rb:13` overwrites it from
Chatwoot Hub on each version check. Use a code change, not config.

How to remove each gate (feature-flag default, a fork override of `self_hosted_paid?`, a data
migration that enables the flag on existing accounts, and so on) is left to the builder. Prefer
the fewest edits that make the outcome hold after a Hub sync.

### 2. Schema

New table `captain_products`:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigint PK | |
| `account_id` | bigint, not null, indexed | |
| `assistant_id` | bigint, not null, indexed | The product belongs to one assistant (one catalog per assistant) |
| `name` | string, not null | |
| `description` | text | What the item is. Shown on the product page |
| `prompt` | text | How to answer about this item: tone, what to push, what never to promise |
| `context` | text | Free-form facts: specs, sizing, variants, shipping, care, product FAQs |
| `shopee_item_id` | string, nullable | Unique per assistant when present |
| `enabled` | boolean, default true, not null | Disabled products are never matched |
| `embedding` | vector(1536) | Built from name + description + context. Used for text matching |
| timestamps | | |

Indexes: `(assistant_id, shopee_item_id)` unique where not null; ivfflat on `embedding`, the
same as `captain_assistant_responses`.

New table `captain_reply_drafts`:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigint PK | |
| `account_id` | bigint, not null | |
| `conversation_id` | bigint, not null, **unique** | One live draft per conversation |
| `assistant_id` | bigint, not null | |
| `product_id` | bigint, nullable | The matched product, shown on the card |
| `content` | text, not null | |
| `last_message_id` | bigint, not null | The buyer message this draft answers. Used to detect a stale draft |
| timestamps | | |

A draft row is deleted on Send, on Discard, and when a human sends any reply in the conversation.
*(My call: delete instead of keeping status history. We don't need draft analytics now.)*

Assistant setting: `captain_assistants.config['reply_mode']` is `'draft'` or `'auto'`, default
`'draft'`. Only `'draft'` is exposed in the UI for now. `'auto'` keeps today's Captain behaviour.

Follow repo rules: Rails associations, no new DB foreign keys. Tables stay in the `chatwoot`
schema on Supabase.

### 3. Shopee: keep the item id

`app/services/shopee/conversation_sync_service.rb:83` turns a product card into the text
`"Product: <item_id>"` and drops the id. Also store it as
`content_attributes['shopee_item_id']` on the message. Keep the text, because the LLM reads the
text. *(My call: a structured attribute is more reliable than parsing the text later.)*

Older messages imported before this change carry the id only as the text. Product matching
falls back to parsing `Product: <item_id>` from message content when the attribute is missing.
No backfill. *(My call.)*

### 4. Reply flow in draft mode

Today (`enterprise/app/services/enterprise/message_templates/hook_execution_service.rb`): an
incoming message in a Captain inbox, with the conversation `pending`, calls
`Captain::Conversation::ResponseSchedulerService`. That schedules `ResponseBuilderJob`, which
runs `AgentRunnerService` and posts the reply.

In draft mode:
1. **Conversation stays with humans.** The inbox must not count Captain as an active bot.
   `Enterprise::Inbox#active_bot?` includes `captain_active?`, which makes new conversations
   `pending`. In draft mode, conversations open as `open`. No greeting or out-of-office
   suppression applies.
2. **Trigger.** Every incoming buyer message (same `captain_response_triggering?` rule) in a
   conversation of any non-resolved status schedules a draft job, with the same short delay
   Captain uses for attachments.
   *(My call: drafts also run for `open` and `snoozed` conversations, since in draft mode a
   human always owns the conversation.)*
3. **Staleness.** Like `ResponseBuilderJob`, the job exits if a newer buyer message exists, so
   only the latest message gets a draft. The draft answers the whole recent exchange, not just
   the last line. A new draft replaces the old row.
4. **Product match**, in order:
   - The most recent message in the conversation with `content_attributes['shopee_item_id']`.
     If a product with that id exists and is enabled, it is used. Buyers usually send the card
     first and the question after, so this looks back over the conversation, not only at the
     current message.
   - Otherwise the agent calls a new `product_lookup` tool. It runs a vector search over the
     assistant's enabled products, the same way `faq_lookup` searches FAQs, and returns the top
     few with name, description, prompt and context.
   - If no product matches, the agent answers from FAQs and general guidelines only, and must
     not invent product facts.
5. **Prompt.** When a product is matched up front, its `description`, `prompt` and `context` go
   into the system prompt as a "Current product" section (extend
   `enterprise/lib/captain/prompts/assistant.liquid`). The product `prompt` sits under the
   assistant's guardrails: guardrails win on conflict.
6. **Tools in draft mode:** read-only only, which means `faq_lookup` and `product_lookup`.
   No `handoff`, `resolve_conversation`, labels, priority, notes or custom HTTP tools.
   *(My call, per the anti-goal.)* Scenarios still apply as sub-agents with the same read-only
   restriction.
7. **Output.** The runner's final reply is upserted into `captain_reply_drafts`. Nothing is
   posted to the conversation. `MessageBuilder` is not called, so no message is created.
   A realtime event is broadcast to the account so the open conversation and the list update.
8. **Failure.** If generation fails, there is no draft and no handoff message. Log it. The owner
   just replies by hand.

Reuse `AgentRunnerService` and the assistant's agent setup. Don't fork the agent loop. How
draft mode is threaded through (a flag, a separate job class that reuses the runner) is left to
the builder.

### 5. Owner actions (API)

Under the existing account/conversation routes:
- `GET` the conversation's draft (also embedded in the conversation payload, or fetched on open:
  builder's choice).
- **Send:** creates a normal outgoing message from the current user with the draft content (or
  edited content sent in the request), then deletes the draft. It goes out through the usual
  `SendReplyJob` path, so Shopee and WhatsApp work unchanged.
- **Discard:** deletes the draft.
- Any outgoing, non-private message in the conversation that is not the draft itself deletes its
  draft. This includes Shopee seller-app echoes (`external_echo: true`), so a draft the owner
  already answered from the Shopee app can't be sent twice. Hook it on message create, not
  only on dashboard sends. *(My call.)*
- Access: any user who can reply in the conversation can see, send, edit and discard its draft.
  Product and assistant editing in AI Studio keeps Captain's current access rules.
  *(My call.)*

### 6. UI

**AI Studio.** The Captain sidebar group is renamed **AI Studio** *(My call: the owner asked for
"an AI Studio tab", and the product list belongs with the assistant it serves.)* Inside it, add
**Products** as the first item, scoped to the selected assistant like the other Captain pages
(`captain.routes.js`).
- **Product list:** name, a short description, a Shopee item id badge if set, and an enabled
  toggle. Includes search by name and an "Add product" button.
- **Product page** (click an item): editable fields for name, description ("what the item is
  about"), prompt, context, Shopee item id, and enabled. Plain textareas are fine.
- Assistant settings: show the reply mode (Draft) as read-only text for now.

**Conversation.** When a draft exists, show a card above the reply box:
- the draft text, and the matched product name if one matched;
- **Send** posts it;
- **Edit** loads the text into the reply editor and removes the card (sending from the editor
  then deletes the draft);
- **Discard** deletes it.

The card updates live when a newer draft arrives. **Conversation list:** a small "Draft" badge on
conversations with a waiting draft.

Follow repo frontend rules: `components-next`, Composition API with `<script setup>`, Tailwind
only, and i18n strings in `en.json` / `en.yml` only.

## Constraints

- Postgres is Supabase (pgvector available, in the `chatwoot` schema, session pooler). The
  embedding model must exist on whatever endpoint `CAPTAIN_OPEN_AI_ENDPOINT` points to.
- Deploy is Railway web + worker. Draft jobs run in Sidekiq on the worker.
- Enterprise overlay rules from `CLAUDE.md` apply. Captain code lives under `enterprise/`, so
  new Captain models, jobs and controllers go there. The Shopee change is OSS (`app/`).
- No specs unless asked (repo rule). Verify by running the flow once locally.

## Known risks

- **Shopee seller-echo race.** A seller message echoed back by Shopee is matched by `source_id`.
  That id is set only after the send completes (`app/services/shopee/send_on_shopee_service.rb:12`).
  An early echo could import a duplicate outgoing message. In draft mode this is mostly harmless:
  a human already owns the conversation, and the duplicate would only delete an already-sent
  draft. It is out of scope here and should be tracked separately.

## Left to the builder

- The exact mechanism for removing each gate.
- How draft mode plugs into the existing scheduler, job and runner.
- When to compute embeddings (sync or job on save) and the top-N for `product_lookup`.
- The realtime event name and payload.
- The exact endpoint paths and serializer shape.
- Component structure for the product pages and the draft card.
