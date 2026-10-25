# AI Studio: ChatGPT sign-in and lexical retrieval

Date: 2026-10-25
Status: draft for approval
Builds on: `2026-10-23-ai-studio-product-drafts-design.md` (shipped in alezlam/chatwoot#11)

## Intent

AI Studio drafts replies with an OpenAI API key today. The owner wants to use their ChatGPT
plan instead, the way open-source agents such as Hermes Agent and OpenClaw do ("Codex
OAuth"). That login gives model calls but no embeddings, so product and FAQ search move to a
simple lexical retriever that follows the owner's recipe. Captain features that still need an
API key or embeddings are hidden for now.

## Goals

1. The owner clicks **Connect ChatGPT** in AI Studio, approves a device code on
   auth.openai.com, and the draft agent then runs on that ChatGPT plan with no API key.
2. Product and FAQ retrieval need no embeddings: a lexical retriever (recipe below) runs before
   the agent's first turn, and the `product_lookup` / `faq_lookup` tools use the same retriever.
3. Captain features outside the draft path are hidden from the UI and do not run.
4. An eval script measures retriever hit rate and MRR against an agent-only baseline.

## Non-goals

- Moving the hidden features (documents → FAQ, FAQ suggestions, memory, Copilot, Playground,
  Captain tasks, article translation, overview summary, speech-to-text) to the new login.
- Chinese tokenization. Buyers write English and Malay.
- Auto-send. Draft mode stays the only mode.
- Supporting both login and API key for the draft agent at once. The ChatGPT connection is the
  draft agent's only model source.

## Anti-goals

- A broken or expired connection must never reach the buyer, and must never fail silently:
  no draft is written and the owner sees a reconnect banner.
- Tokens must never appear in logs, API responses, the frontend or error trackers.
- Our requests identify themselves honestly (`originator` / `User-Agent` name this app), never
  as `codex_cli_rs`.

## Decisions made with the owner

- **Codex-style device login is acceptable.** OpenClaw and Hermes use it. The owner accepts that
  the connected ChatGPT account carries the risk.
- **No embeddings.** Build the lexical retriever below instead.
- **Only the draft path moves.** Other Captain features are hidden.
- **English and Malay only.** No CJK handling.
- **Login UI place:** a "Connect ChatGPT" control in AI Studio settings, with a "connected as X"
  state and Disconnect.

## Design

### 1. ChatGPT connection (device-code OAuth)

Facts from the Codex CLI and Hermes source (`openai/codex` `codex-rs/login`, `hermes-agent`
`hermes_cli/auth_codex.py`, `agent/codex_headers.py`):

- Issuer `https://auth.openai.com`. Client id `app_EMoamEEZ73f0CkXaXp7hrann` (the Codex public
  client, also used by Hermes). Keep it in one constant.
- Step 1: `POST /api/accounts/deviceauth/usercode` with JSON `{ client_id }`. The response has
  `device_auth_id`, `user_code`, `interval` (a string; use at least 3 s). A 404 means device
  login is off for the ChatGPT account, so tell the owner to enable it in ChatGPT security
  settings.
- The owner opens `https://auth.openai.com/codex/device` and enters `user_code`. The code
  expires after 15 minutes.
- Step 2: poll `POST /api/accounts/deviceauth/token` with JSON `{ device_auth_id, user_code }`
  every `interval` seconds. 403/404 means pending. 200 returns
  `{ authorization_code, code_verifier }`.
- Step 3: `POST /oauth/token` (form) with `grant_type=authorization_code`, `code`,
  `redirect_uri=https://auth.openai.com/deviceauth/callback`, `client_id` and `code_verifier`.
  The response has `access_token`, `refresh_token` and `id_token`.
- Account id: the JWT claim `https://api.openai.com/auth` → `chatgpt_account_id` (also
  `chatgpt_plan_type`). Expiry: the JWT `exp` claim.
- Refresh: `POST /oauth/token` (form) with `grant_type=refresh_token`, `client_id` and
  `refresh_token`, when `exp` is within 5 minutes. Store a rotated `refresh_token` if one is
  returned. Expired, reused or revoked means disconnected (reconnect needed). 429 means quota,
  not auth.

Storage: one connection per **account** *(my call: it matches the account-scoped API and keeps
multi-account installs from sharing one admin's plan)*, in a new table
`captain_chatgpt_connections` (unique `account_id`) with `access_token`, `refresh_token`, `account_id`, `email`, `plan_type`,
`expires_at`, `status` (`connected` | `disconnected`) and `last_error`. Tokens use Rails
`encrypts`. Refresh happens under a row lock so the web and worker processes don't race on a
rotating refresh token.

Device-flow polling runs server-side in a Sidekiq job started by the "Connect" request. The UI
polls the connection status endpoint. The pending `device_auth_id` and `user_code` live in
Redis for 15 minutes.

API (admin only), under `api/v1/accounts/:account_id/captain/chatgpt_connection`:
- `GET` returns the status: `{ status, email, plan_type, user_code?, verification_url?, last_error? }`.
- `POST` starts the device flow and returns `user_code` and `verification_url`.
- `DELETE` disconnects (deletes the tokens).

### 2. ChatGPT model provider for the agent loop

`ai-agents` builds `RubyLLM::Chat.new(model:, provider:)` per agent, and `ruby_llm` 1.15 only
speaks Chat Completions. Add a custom provider registered with
`RubyLLM::Provider.register(:chatgpt, ...)`:

- Endpoint: `POST https://chatgpt.com/backend-api/codex/responses`, `stream: true` (required),
  `store: false`, `instructions` carrying the system prompt, `input[]` carrying the messages,
  standard Responses function `tools` (omit when empty), `tool_choice: "auto"`, and
  `parallel_tool_calls: false`.
- Headers: `Authorization: Bearer <access_token>`, `ChatGPT-Account-ID`,
  `originator: chatwoot-ai-studio`, `User-Agent: ChatwootAIStudio/<version>`, and a
  `session-id` per draft run.
- Read the SSE events into one completion: text, function calls (name, arguments, call id),
  and usage. Tool results go back as `function_call_output` input items.
- Access token comes from the connection, refreshed first if needed. On a 401, refresh once and
  retry once.
- Errors:
  - 429 with `usage_limit_reached`: store `last_error` with `resets_at`, no draft.
  - Refresh failure: status `disconnected`, no draft.
  - Any other error: log it, no draft.

  Never raise into a handoff. The existing `DraftReplyJob` already swallows errors.
- Model: the owner picks one from `GET https://chatgpt.com/backend-api/codex/models` (send
  `ChatGPT-Account-ID`) in the connection UI. Store it on the connection. Default to the first
  listed model.

Wiring: draft runs (`AgentRunnerService` with `source: :draft`) set `provider: :chatgpt` and
`assume_model_exists: true` on every agent. That covers the assistant, scenarios and the
`ResponseRewriter` re-run. Auto-mode code paths keep their current provider, but auto mode is
not exposed.

Inside a draft run, audio transcription (`open_ai_message_builder_service.rb:65`) needs the API
key. With no key, voice notes enter history as a "[voice message]" placeholder, never an
exception *(my call)*.

### 3. Lexical retriever (owner's recipe)

Corpus:
- Each enabled `Captain::Product` and each `Captain::AssistantResponse` (FAQ) of the assistant
  is one entry, rendered as markdown at query time: `## <name or question>`, then the body
  (description, context and prompt, or the answer), then `key: value` metadata lines.
- Storage stays in the database.

Metadata:
- **invalidated:** a disabled product. It is excluded.
- **confirmed:** a new boolean `confirmed` on both tables, default `false`, toggled in AI
  Studio. ×1.5.
- **hits:** a new integer `hits` on both tables, default `0`. The draft stores the entries it
  was given: add `retrieved_product_ids` and `retrieved_faq_ids` (jsonb arrays) to
  `captain_reply_drafts`, filled from injection plus tool results. When the owner clicks **Send**
  on the draft card (the `send_reply` endpoint), each stored id gets `hits + 1`. Edit-then-send,
  manual replies and Shopee echoes credit nothing, because they can't be tied to the draft.
  *(My call: one clear signal; the +30% cap bounds any feedback loop.)*
- **FAQ corpus:** every `AssistantResponse` of the assistant. The table only has the `approved`
  status. Pending suggestions live in `captain_faq_suggestions` and are not in the corpus.
- Existing rows: `confirmed` false, `hits` 0.

Tokenize (same function for queries and entries):
- Lowercase, split on `/[^a-z0-9]+/`, drop tokens shorter than 3 characters.
- Drop stopwords from fixed English and Malay lists, kept in one file.
- Drop "query-common" tokens: tokens in more than 50% of recent buyer messages. Use incoming
  messages from the last 30 days in inboxes linked to the assistant, excluding product-card
  texts (`Product: <id>` / `Order: <sn>`). Compute nightly per assistant and cache it. Skip the
  filter until there are at least 200 such messages. If filtering would remove every query
  token, use the unfiltered tokens. *(My call: protects short queries in a small shop.)*

Score: for each distinct query token in the entry, add `log(N / docFreq)`. N and docFreq come
from the assistant's current corpus. Then multiply by trust:
- `invalidated`: 0
- `confirmed`: ×1.5
- hits: × `(1 + min(0.3, 0.1 * ln(1 + hits)))`

Select: keep entries scoring at least 30% of the top score, at most `topK = 5`, and under
`4000` characters in total, dropping lower-scored entries first. Nothing scores → `nil`.
`topK` and the character limit are named constants.

Inject: `DraftReplyJob` runs the retriever on the buyer's latest message(s) (the messages since
the last outgoing reply, joined) before the first turn. It passes the result as
`runtime_configuration[:retrieved_knowledge]`, rendered by a new liquid snippet next to
`current_product`. A Shopee-card product match still wins: it stays `current_product` and is
excluded from the retrieved list. If retrieval raises, log it and continue without it.

Tools: `product_lookup` and `faq_lookup` call the same retriever (products-only and FAQs-only)
and return its entries. They keep recording ids for `hits`.

Remove embedding use from the draft path: `Captain::Product.search`, `AssistantResponse.search`
and their `UpdateEmbeddingJob` enqueues. Embedding columns stay (no destructive migration).
Existing queued `UpdateEmbeddingJob`s may fail once with no key, which is harmless.

### 4. Hide everything else

Turn off and hide, with the API key unset:
- Documents (route, sidebar)
- FAQ suggestions / pending FAQs page
- `feature_faq` and `feature_memory` toggles (force off; the listener skips)
- Copilot launcher and editor Copilot
- Playground
- `captain_tasks` (rewrite, summarize, reply and label suggestion)
- Article bulk translation
- Overview AI summary
- Audio transcription setting

Keep: Products, FAQs (manual add/edit, now without embeddings), Scenarios, Guardrails,
Guidelines, Inboxes, Settings, Tools.

Prefer the existing switches: turn feature flags off (for example `captain_tasks`) and use
route `meta` / sidebar gating. Delete no code. Mark each hide with a `ponytail:` comment
explaining it waits for the new provider. The hiding must hold whether or not
`CAPTAIN_OPEN_AI_API_KEY` is set (gate on flags/config, not on key presence). Prod has no key
today.

### 4b. Connection status in the UI

- AI Studio settings: a "ChatGPT" card with Connect / device code / connected as `email` (plan)
  / model picker / Disconnect.
- Banner on AI Studio pages and a one-line notice in the conversation view (where the draft
  card would be) when the connection is `disconnected` or rate-limited. A rate-limit notice
  shows `resets_at` and clears itself once that time passes (compare on render; no job).

### 5. Verify

`script/` or a rake task `captain:retrieval_eval[assistant_id]`:
- Labelled set: buyer messages in conversations that also have a Shopee product card, labelled
  with that card's product, plus an optional hand-labelled YAML file of `{ query, expected:
  product|faq id }`.
- Retriever: hit@topK and MRR.
- Agent-only baseline: run the draft agent with injection off and record which entries its
  tools returned, then hit@topK and MRR on those. It needs the ChatGPT connection, so it is
  optional with `--with-agent`.
- Print a small table. No spec files (repo rule).

## Constraints

- Same as the previous spec: enterprise code in `enterprise/`, no DB foreign keys, Tailwind and
  en.json only, no spec files unless asked, explicit-path staging, deploy by `railway api` call.
- Base branch `fork/develop` (alezlam/chatwoot). Push and PR with the `aspoofer0224`
  credential.
- Tokens are secrets. Use Rails encryption (check `ActiveRecord::Encryption` keys exist in
  prod; if not, the builder adds the three `ACTIVE_RECORD_ENCRYPTION_*` variables on Railway and
  says so).

## Known risks

- The Codex client id and backend are not a published API. They can change or be blocked. The
  owner accepts this. Keep all protocol details in one provider file and one auth service.
- Plan quota: heavy draft volume can exhaust the ChatGPT plan. Surface `resets_at` in the
  banner.
- Workspaces with data residency need `x-openai-internal-codex-residency`. Not handled in v1.

## Left to the builder

- Table vs InstallationConfig for the connection.
- The SSE parser structure and the exact ruby_llm provider hook methods.
- Stopword list contents.
- Banner placement and copy (i18n).
- Eval script output format.
