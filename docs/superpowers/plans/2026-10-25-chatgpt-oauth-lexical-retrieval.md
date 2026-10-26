# ChatGPT Sign-in and Lexical Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run AI Studio's draft agent on the owner's ChatGPT plan (Codex-style device login), replace embeddings with a lexical retriever, and hide the Captain features that still need an API key.

**Architecture:**
- A per-account `captain_chatgpt_connections` row holds encrypted OAuth tokens. They are obtained with the device-code flow and refreshed under a row lock.
- A custom `ruby_llm` provider (`:chatgpt`) speaks the streaming Responses API at `chatgpt.com/backend-api/codex/responses`. Draft runs select it.
- A lexical retriever (log-IDF scoring × trust) runs before the first turn, and the `product_lookup` / `faq_lookup` tools use the same retriever.

**Tech Stack:** Rails 7.1, enterprise overlay, `ai-agents` 0.12 + `ruby_llm` 1.15, Faraday, Sidekiq (+ `config/schedule.yml`), Vue 3 `<script setup>` + Vuex `createStore`, Tailwind.

**Spec:** `docs/superpowers/specs/2026-10-25-chatgpt-oauth-lexical-retrieval-design.md`. It builds on `docs/superpowers/specs/2026-10-23-ai-studio-product-drafts-design.md`.

## Global Constraints

- **Branch:** `feat/chatgpt-oauth-retrieval` off `fork/develop` (alezlam/chatwoot). Work in place.
- **No spec/test files.** Verify with one-off scripts in the session scratchpad (rails runner, curl, Playwright), and paste the output into the report.
- **Placement:** Captain code goes in `enterprise/`. No DB foreign keys. Migrations are `ActiveRecord::Migration[7.1]`, timestamps `20261025000001`+.
- **`db/schema.rb`:** commit only the version line and real additions. Revert dump churn.
- **Frontend:** Tailwind only, i18n in `en.json`/`en.yml` only, `<script setup>`, `components-next`, logical utilities.
- **Ruby:** rubocop clean (`--force-exclusion`), 150-char lines, compact `module/class`.
- **Staging:** explicit paths only. Never `AGENTS.md`, `CLAUDE.md`, `.claude/**`, `supabase/`, `.superpowers/`.
- **Commits:** Conventional Commits ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **OAuth constants** (one file, `enterprise/lib/captain/chatgpt/constants.rb`):
  - `ISSUER = 'https://auth.openai.com'`
  - `CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann'`
  - `VERIFICATION_URL = 'https://auth.openai.com/codex/device'`
  - `DEVICE_REDIRECT_URI = 'https://auth.openai.com/deviceauth/callback'`
  - `RESPONSES_URL = 'https://chatgpt.com/backend-api/codex/responses'`
  - `MODELS_URL = 'https://chatgpt.com/backend-api/codex/models'`
  - `ORIGINATOR = 'chatwoot-ai-studio'`
  - `USER_AGENT = 'ChatwootAIStudio/1.0'`
- **Secrets:** tokens use Rails `encrypts`. They must never appear in JSON, logs, `last_error` or exception messages.
- **No buyer impact:** a broken or expired connection or a quota error means no draft, never a message to the buyer, and never a silent failure (status/`last_error` set).
- **Retriever constants:**
  - `TOP_K = 5`
  - `CHAR_LIMIT = 4000`
  - `MIN_RELATIVE_SCORE = 0.3`
  - `CONFIRMED_FACTOR = 1.5`
  - hits factor `1 + min(0.3, 0.1 * ln(1 + hits))`
  - `MIN_TOKEN_LENGTH = 3`
  - query-common threshold `0.5`, over at least `200` messages and the last `30` days
- **Local env:** `eval "$(rbenv init -)"`. Postgres is on 5433 (Docker `chatwoot-postgres`). Dev Rails runs on :3000 and Vite on :3036. The seed admin is `john@acme.inc` / `Password1!`. There is no OpenAI key and no ChatGPT connection locally until the owner connects, so live LLM checks are marked `DEFERRED-LIVE` and get a self-contained scratchpad script.

## Review Focus

1. **Web and worker refresh at the same time with a rotating refresh token.** Exactly one refresh call is made, and both processes end up with the new token. Task 1 check (d).
2. **ChatGPT plan limit reached (429 `usage_limit_reached`).**
   - No draft is written.
   - `last_error` records `resets_at`.
   - The UI notice clears itself after `resets_at`.

   Covered by Task 3 check (c) and Task 7 check (c).
3. **A buyer message made only of stopwords or short words** ("ok", "hi sis", "?"). The retriever returns `nil` with no exception, and the draft still runs. Task 4 check (c).
4. **Device code expired or denied.** The connection returns to `disconnected` with a readable `last_error`, the UI offers Connect again, and the polling job stops. Task 1 check (c).
5. **Tokens leaking.** `GET` connection JSON, `last_error` and the Rails log never contain `access_token` / `refresh_token` values. Task 1 check (e).

---

### Task 1: ChatGPT connection — model, OAuth client, device login, API

**Files:**
- Create: `db/migrate/20261025000001_create_captain_chatgpt_connections.rb`
- Create: `enterprise/app/models/captain/chatgpt_connection.rb`
- Create: `enterprise/lib/captain/chatgpt/constants.rb`
- Create: `enterprise/lib/captain/chatgpt/auth_client.rb`
- Create: `enterprise/app/jobs/captain/chatgpt/device_login_job.rb`
- Create: `enterprise/app/controllers/api/v1/accounts/captain/chatgpt_connections_controller.rb`, plus a policy and a jbuilder view
- Modify: `config/routes.rb`, inside the captain namespace: `resource :chatgpt_connection, only: [:show, :create, :update, :destroy]`
- Modify: `enterprise/app/models/enterprise/account.rb` (or the concern it uses): `has_one :captain_chatgpt_connection, class_name: 'Captain::ChatgptConnection', dependent: :destroy`

**Migration:** `captain_chatgpt_connections`
- `account_id` (bigint, not null, unique index)
- `status` (integer, not null, default 0)
- `access_token` (text), `refresh_token` (text), `id_token` (text)
- `chatgpt_account_id` (string), `email` (string), `plan_type` (string)
- `model` (string)
- `expires_at` (datetime)
- `last_error` (jsonb, default `{}`)
- `pending_device` (jsonb, default `{}`), holding `{ device_auth_id, user_code, interval, expires_at }`
- timestamps

**Interfaces:**
- Produces: `Captain::ChatgptConnection`
  - `enum status: { disconnected: 0, pending: 1, connected: 2 }`
  - `encrypts :access_token, :refresh_token, :id_token`
  - `fresh_access_token! -> String` refreshes under `with_lock` when `expires_at < 5.minutes.from_now`, re-reading the row inside the lock. It raises `Captain::Chatgpt::AuthError` and sets `disconnected` + `last_error` when the refresh is rejected.
  - `record_error!(type:, message:, resets_at: nil)`
  - `rate_limited? -> Boolean`, true while `last_error['resets_at']` is in the future
  - `as_status_json -> Hash` with `{ status, email, plan_type, model, user_code, verification_url, last_error }` only. No tokens.
- Produces: `Captain::Chatgpt::AuthClient`, module functions using Faraday JSON/form:
  - `request_device_code -> { device_auth_id:, user_code:, interval: Integer }`. Raises `AuthError` with `type: 'device_login_disabled'` on 404.
  - `poll_device_token(device_auth_id:, user_code:) -> nil | { authorization_code:, code_verifier: }`. Returns nil on 403/404 (still pending).
  - `exchange_code(code:, code_verifier:) -> token_hash`
  - `refresh(refresh_token:) -> token_hash`
  - `decode_claims(id_or_access_token) -> Hash`. Decodes the JWT payload without verification. Reads `email`, `exp`, and `https://api.openai.com/auth` → `chatgpt_account_id`, `chatgpt_plan_type`.
- Produces: `Captain::Chatgpt::DeviceLoginJob#perform(connection_id)`
  - Polls every `interval` seconds within one job run, until success or the 15-minute expiry.
  - On success, stores the tokens, claims, `expires_at` (from JWT `exp`) and `status: connected`, and clears `pending_device`.
  - On expiry, sets `disconnected` with `last_error: { type: 'device_code_expired' }`.
  - The job stops early if the row is no longer `pending` (the user disconnected).
- Produces API (admin only; agents get 401), under `/api/v1/accounts/:account_id/captain/chatgpt_connection`:
  - `GET` returns `as_status_json`, or `{ status: 'disconnected' }` when there is no row.
  - `POST` requests a device code, sets `pending`, enqueues the job, and returns `as_status_json`.
  - `PATCH { model }` sets the model.
  - `DELETE` clears the tokens and sets `disconnected`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks (rails runner and curl; HTTP to OpenAI only where stated).**
  - (a) Call `request_device_code` live once. It returns a `user_code` and an `interval`. A 404 must raise `device_login_disabled`, so show the handling with a stubbed Faraday adapter.
  - (b) The token flow with a stubbed Faraday adapter (`Faraday::Adapter::Test`): poll pending → poll success → exchange. The row becomes `connected` with email, plan and account id decoded from a crafted unsigned JWT.
  - (c) Expiry: an expiry in the past makes the job end `disconnected` with `device_code_expired`. A `DELETE` mid-poll stops the job.
  - (d) Two threads call `fresh_access_token!` against a stubbed refresh endpoint that counts calls and rotates the refresh token. Exactly 1 call is made, and both threads get the new token.
  - (e) `GET` JSON and `last_error` contain no token strings. Grep `log/development.log` for the fake token values: no hits.
  - (f) An agent token gets 401 on `POST`.
- [ ] **Step 3: Commit** `feat(captain): ChatGPT device-code connection`.

### Task 2: `:chatgpt` ruby_llm provider (Responses API, streaming)

**Files:**
- Create: `enterprise/lib/captain/chatgpt/provider.rb`
- Create: `enterprise/lib/captain/chatgpt/sse_parser.rb`
- Create: `enterprise/lib/captain/chatgpt/models_client.rb`
- Create: `config/initializers/captain_chatgpt_provider.rb`, which runs `RubyLLM::Provider.register :chatgpt, Captain::Chatgpt::Provider`
- Modify: the Task 1 controller. `GET` also returns `models: [...]` when connected, using `ModelsClient` and caching for 10 minutes.

**Interfaces:**
- Consumes: `Captain::ChatgptConnection#fresh_access_token!`, `chatgpt_account_id` and `record_error!` (Task 1).
- Produces: `Captain::Chatgpt::Provider < RubyLLM::Provider`.
  - Overrides `complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, tool_prefs: nil, &block) -> RubyLLM::Message`.
  - It always POSTs with `stream: true` and reads the SSE into one assistant message with `content`, `tool_calls` (a Hash `id => RubyLLM::ToolCall.new(id:, name:, arguments: Hash)`), `input_tokens` and `output_tokens`.
  - If a block is given, it yields text chunks.
  - `configuration_requirements` is `[]`, and `assume_models_exist?` is `true`.
  - The connection comes from `params[:chatgpt_connection_id]`, which is deleted from the payload before sending. Task 3 passes it through the agent's `params:`.
- Request body:
  - `model`, `instructions` (all system messages joined), `input` (user and assistant text items, assistant `function_call` items, and tool results as `{ type: 'function_call_output', call_id, output }`)
  - `tools` as Responses function tools (omitted when empty)
  - `tool_choice: 'auto'`, `parallel_tool_calls: false`, `store: false`, `stream: true`
- Headers:
  - `Authorization: Bearer`
  - `ChatGPT-Account-ID`
  - `originator: chatwoot-ai-studio`
  - `User-Agent: ChatwootAIStudio/1.0`
  - `session-id`: `headers['session-id']` if given, otherwise a SecureRandom uuid
- Errors:
  - A 401 refreshes once and retries once.
  - A 429 whose body `error.type` is `usage_limit_reached` or `workspace_member_usage_limit_reached` calls `record_error!(type: 'usage_limit', resets_at: Time.zone.at(resets_at))` and raises `Captain::Chatgpt::UsageLimitError`.
  - Other non-2xx responses and an SSE `type: 'error'` frame raise `Captain::Chatgpt::RequestError` with no token text.
  - A stream with no events within 60 s raises a timeout.
- Produces: `Captain::Chatgpt::ModelsClient.list(connection) -> Array<String>` (model ids).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks.**
  - (a) Feed `SseParser` a fixture stream containing text deltas, one function call (name and JSON arguments split across deltas), and a completed event with usage. The result is one message with text, one tool call with parsed arguments, and the token counts.
  - (b) Stub HTTP at 401, then refresh, then 200. That makes exactly one retry.
  - (c) Stub a 429 body `{"error":{"type":"usage_limit_reached","resets_at":<now+3600>}}`. It raises `UsageLimitError`, and `connection.last_error['resets_at']` is set.
  - (d) The rendered request JSON for a 2-turn conversation with one tool result matches the body spec above. Print it with the token redacted.
  - (e) `DEFERRED-LIVE`: `scratchpad/chatgpt_live_check.rb` sends one plain prompt and one tool-calling prompt through `RubyLLM::Chat.new(model:, provider: :chatgpt, assume_model_exists: true)` using the owner's connection.
- [ ] **Step 3: Commit** `feat(captain): ChatGPT Responses provider`.

### Task 3: Run draft agents on the ChatGPT connection

**Files:**
- Modify: `enterprise/app/services/captain/assistant/agent_runner_service.rb`. Every agent in the `source: :draft` graph is cloned with `provider: :chatgpt`, `model: connection.model`, and `params: { chatgpt_connection_id: connection.id }`. Also set `assume_model_exists` if `ai-agents` exposes it; otherwise the provider's `assume_models_exist?` covers it.
- Modify: `enterprise/app/jobs/captain/conversation/draft_reply_job.rb`.
  - Load `account.captain_chatgpt_connection` first. If it is missing, not `connected`, or `rate_limited?`, log and return without running the agent and without writing a draft.
  - Rescue `Captain::Chatgpt::UsageLimitError` and `AuthError`: no draft, no retry.
- Modify: `enterprise/app/services/captain/assistant/response_rewriter.rb`, only if it builds its own agent outside the cloned graph. It must use the same provider in draft runs.
- Modify: `enterprise/app/services/captain/open_ai_message_builder_service.rb:~65`. In draft runs, audio attachments become the text `[voice message]`, with no transcription call.

**Interfaces:**
- Consumes: Task 1 connection and Task 2 provider.
- Produces: draft runs make zero calls to `api.openai.com`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks.**
  - (a) With no connection, an incoming message produces no draft and a log line, and makes no HTTP call.
  - (b) With a `connected` connection and the provider stubbed to return text, the draft is written. Instrument Faraday to show the request went to `chatgpt.com`.
  - (c) With the provider stub raising `UsageLimitError`, there is no draft, `last_error` has `resets_at`, and the conversation stays `open` with no messages.
  - (d) A message with an audio attachment puts `[voice message]` into the history.
  - (e) `DEFERRED-LIVE`: extend `scratchpad/chatgpt_live_check.rb` with one real draft run.
- [ ] **Step 3: Commit** `feat(captain): run drafts on ChatGPT plan`.

### Task 4: Lexical retriever

**Files:**
- Create: `db/migrate/20261025000002_add_retrieval_fields_to_captain.rb`
  - `captain_products` and `captain_assistant_responses`: `confirmed` (boolean, default false, not null) and `hits` (integer, default 0, not null)
  - `captain_reply_drafts`: `retrieved_product_ids` and `retrieved_faq_ids` (jsonb, default `[]`)
- Create: `enterprise/lib/captain/retrieval/tokenizer.rb`
- Create: `enterprise/lib/captain/retrieval/lexical_retriever.rb`
- Create: `enterprise/config/captain_stopwords.yml`, with `en:` and `ms:` lists
- Create: `enterprise/app/jobs/captain/retrieval/query_common_tokens_job.rb`. Add a nightly entry to `config/schedule.yml`.
- Modify: `enterprise/app/models/captain/product.rb` and `enterprise/app/models/captain/assistant_response.rb`. Remove embedding `search` and `UpdateEmbeddingJob` enqueues.
- Modify: `enterprise/lib/captain/tools/product_lookup_tool.rb` and `faq_lookup_tool.rb`, plus copilot callers of `responses.approved.search` (`search_documentation_service.rb:16`, `search_reply_documentation_service.rb:35,37`). Point them at the retriever. Copilot is hidden, but must not crash.

**Interfaces:**
- Produces: `Captain::Retrieval::Tokenizer.tokens(text, common: Set.new) -> Array<String>`
  - Lowercase, split on `/[^a-z0-9]+/`, drop tokens with length < 3, drop stopwords (en + ms), drop `common` tokens.
  - If dropping `common` empties the result, return the list without that filter.
- Produces: `Captain::Retrieval::LexicalRetriever.new(assistant:, kinds: %i[products faqs]).search(query, top_k: TOP_K, char_limit: CHAR_LIMIT, exclude_product_ids: []) -> Captain::Retrieval::Result | nil`
  - `Result` responds to `entries` (Array of `{ record:, kind:, score:, markdown: }`), `product_ids`, `faq_ids` and `to_markdown`.
  - Corpus: enabled products (disabled products are invalidated and excluded) plus all of the assistant's `AssistantResponse` rows.
  - Entry markdown: `## <name|question>`, the body (product: description, context, prompt; FAQ: answer), then `confirmed: true|false` and `hits: N` lines.
  - Score: the sum over distinct query tokens in the entry of `Math.log(N / doc_freq)`, × 1.5 if confirmed, × `(1 + [0.3, 0.1 * Math.log(1 + hits)].min)`.
  - Keep entries with score ≥ 30% of the top score and score > 0. Cap at `top_k`. Stop before the cumulative markdown passes `char_limit`. No entries means `nil`.
  - The corpus is loaded per call. That is fine at shop scale; add a `ponytail:` note naming the ceiling (about thousands of entries) and the upgrade path (`pg_trgm` / `tsvector` prefilter).
- Produces: `Captain::Retrieval::QueryCommonTokensJob#perform`. For each assistant, it caches `Set` tokens appearing in > 50% of incoming messages from the last 30 days in its linked inboxes. Card texts matching `/\A(Product|Order): \S+\z/` are excluded, and the cache is skipped when there are fewer than 200 messages. Cache key: `captain:retrieval:common:<assistant_id>` in `Rails.cache`, 2 days.
- Produces: `Captain::Retrieval::LexicalRetriever.common_tokens(assistant) -> Set`, read from the cache (empty if absent).
- Tools: append the ids they returned to `tool_context.state[:retrieved_product_ids]` / `[:retrieved_faq_ids]`. If the runner state isn't readable after the run, use a request-local `Current` attribute and note which one you used.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks (rails runner, no LLM).**
  - (a) Use 3 products: "Cat Tree Tower Grey", "Cat Litter Tofu 6L", "Dog Leash Nylon". Query "ada stock cat tree grey?" ranks the cat tree first. "litter tofu" ranks the litter first.
  - (b) A disabled product never appears. Confirming the litter product raises its score by ×1.5. `hits: 100` caps at +30%.
  - (c) The queries "ok", "hi sis" and "?" return `nil` and raise nothing.
  - (d) The `char_limit` of 200 trims the entries. `top_k: 1` returns 1.
  - (e) The job, on seeded messages where "boleh" appears in > 50% of them (with ≥ 200 messages), caches `boleh`. With 50 messages, nothing is cached.
  - (f) `ProductLookupTool` and `FaqLookupTool` return markdown entries and record ids.
- [ ] **Step 3: Commit** `feat(captain): lexical retriever replaces embeddings`.

### Task 5: Pre-first-turn injection and hits

**Files:**
- Modify: `enterprise/app/jobs/captain/conversation/draft_reply_job.rb`.
  - Before the run, set the query to the buyer messages since the last outgoing reply, joined with newlines, with card texts removed.
  - Run `LexicalRetriever#search(query, exclude_product_ids: [current_product&.id].compact)`, rescuing `StandardError` (log, then continue with `nil`).
  - Pass the result as `runtime_configuration[:retrieved_knowledge] = result&.to_markdown`.
  - After the run, store `retrieved_product_ids` / `retrieved_faq_ids` on the draft: injected plus tool-recorded ids, unique.
- Modify: `enterprise/app/models/concerns/agentable.rb`. Merge `retrieved_knowledge` into the template context, the same way `current_product` is merged.
- Create: `enterprise/lib/captain/prompts/snippets/retrieved_knowledge.liquid`, included in `assistant.liquid` and `scenario.liquid` right after `current_product`. Heading `## Relevant products and FAQs`, followed by "Use these facts when relevant. They may not all apply." and the markdown. It renders nothing when blank, and auto mode with no products stays byte-identical.
- Modify: `enterprise/app/controllers/api/v1/accounts/captain/reply_drafts_controller.rb` `send_reply`. Inside the existing lock and after the message is created, run one `update_all('hits = hits + 1')` per table, scoped to the draft's stored ids.

**Interfaces:**
- Consumes: Task 4 `LexicalRetriever` and `Result`, and the tool-recorded ids.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks.**
  - (a) With the provider stubbed, a buyer message "cat tree grey ada?" gives a rendered system prompt that contains the section with the cat-tree entry. The draft stores its id.
  - (b) When the retriever raises (stub), the draft is still written and the error is logged.
  - (c) A Shopee-card-matched product is not duplicated in the retrieved list.
  - (d) `send_reply` raises the stored entries' `hits` by 1. `DELETE` and a manual reply don't change hits.
  - (e) Auto mode with no products renders identically to HEAD (byte compare).
- [ ] **Step 3: Commit** `feat(captain): inject retrieved knowledge and count hits`.

### Task 6: Hide Captain features outside the draft path

**Files (backend):**
- Data migration `20261025000003_disable_captain_extras.rb`:
  - For every account, `disable_features!('captain_tasks')` and remove it from `ACCOUNT_LEVEL_FEATURE_DEFAULTS` (follow the pattern of `20261023000001`).
  - Set `feature_faq`/`feature_memory` to false on every assistant's config.
- `enterprise/app/listeners/captain_listener.rb`: return early before FAQ generation or memory. Add a `ponytail:` comment: these wait for the ChatGPT provider.

**Files (frontend):**
- `app/javascript/dashboard/routes/dashboard/captain/captain.routes.js` and `components-next/sidebar/Sidebar.vue`: remove the Documents, FAQ suggestions (`faqs/pending`) and Playground entries and routes from navigation. Add a route guard or remove them from `AssistantsIndexPage.vue` `isAValidRoute`.
- `AssistantBasicSettingsForm.vue` and `AssistantForm.vue`: remove the `feature_faq`/`feature_memory` toggles.
- Copilot:
  - `Dashboard.vue` `CopilotLauncher` / `CopilotContainer`, and `ReplyBox.vue` `CopilotEditorSection`: hide them.
  - Gate on a single constant, `CAPTAIN_EXTRAS_ENABLED = false`, in `app/javascript/dashboard/helper/captainExtras.js` instead of scattering conditions.
  - Captain tasks UI already follows `captainTasksEnabled`, so it is off once the flag is off.
- Overview AI summary (`assistant_stats_controller.rb:48`, frontend caller): hide it behind the same constant.
- Audio transcription setting (`settings/account/.../AudioTranscription.vue` via `Index.vue:250`): hide it.
- Article bulk translation action: hide it.
- Keep: Products, FAQs (manual), Scenarios, Guardrails, Guidelines, Inboxes, Settings, Tools.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks.**
  - (a) After the migration, `captain_tasks` is off on all accounts and in the defaults. Every assistant has `feature_faq` and `feature_memory` false.
  - (b) Resolving a conversation in a linked inbox enqueues no `ConversationFaqJob` or contact-notes job.
  - (c) Playwright: the AI Studio sidebar shows exactly Products, Overview, FAQs, Scenarios, Inboxes, Tools, Settings (plus Guardrails and Guidelines inside Settings). There is no Copilot launcher on the dashboard, no Copilot in the reply editor, and no FAQ or memory toggles. Visiting `/captain/<id>/documents` directly redirects.
  - (d) `npx eslint` is clean.
- [ ] **Step 3: Commit** `feat(captain): hide features that need an OpenAI API key`.

### Task 7: ChatGPT connection UI, status notices, `confirmed` toggles

**Files:**
- Create: `app/javascript/dashboard/api/captain/chatgptConnection.js` (`get`, `connect`, `update(model)`, `disconnect`) and `store/captain/chatgptConnection.js` (Vuex module `captainChatgptConnection`, single record).
- Create: `components-next/captain/pageComponents/assistant/settings/ChatgptConnectionCard.vue`, shown at the top of the assistant settings page. States:
  - **Disconnected:** Connect button. `last_error` is shown as text, with `device_login_disabled` explained as "Turn on device code login in ChatGPT → Settings → Security".
  - **Pending:** the large `user_code`, a link to the `verification_url`, and "Waiting for approval…". Poll `GET` every 5 s while pending, and stop on unmount.
  - **Connected:** "Connected as `email` (`plan_type`)", a model `<select>` from `models` (PATCH on change), and Disconnect.
- Create: `components-next/captain/ChatgptStatusNotice.vue`. One line, shown when the status is not `connected` or when rate-limited. The rate-limit form reads "ChatGPT limit reached — drafts resume at <local time>". It hides when `Date.now() > resets_at`, checked on render with a 60 s ticking ref. Render it:
  - at the top of AI Studio pages (`PageLayout` or the captain route view);
  - in `MessagesView.vue` above the reply box, only when the inbox is linked to an assistant. Use the existing captain inbox data; if that data is not in the store, show it only on AI Studio pages and say so.
- Modify: Products list and Show pages (Task 8 of the previous plan) and the FAQ list/form. Add a `confirmed` `Switch` (admin only), and allow `:confirmed` in `products_controller` and `assistant_responses_controller` params plus their jbuilder partials.
- i18n: `CAPTAIN.CHATGPT.*`, `CAPTAIN.PRODUCTS.FORM.CONFIRMED`, `CAPTAIN.RESPONSES.FORM.CONFIRMED` in `integrations.json`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks (Playwright with the API stubbed through rails runner state changes; no real login).**
  - (a) Disconnected → click Connect. With the backend `POST` hitting OpenAI live, a real `user_code` appears, then Disconnect. Alternatively, set `pending` with a fake code via runner and confirm the card renders it.
  - (b) Set the row to `connected` with a fake email, plan and models. The card shows them, and changing the model persists.
  - (c) Set `last_error` with `resets_at` 2 minutes ahead: the notice shows on AI Studio and in the conversation view. Then set it 1 minute in the past and reload: the notice is gone.
  - (d) Toggle `confirmed` on a product and on an FAQ, then reload: the value persists.
  - (e) Agent login: the connection card is read-only or hidden (admin-only API).
  - (f) `npx eslint` is clean.
- [ ] **Step 3: Commit** `feat(captain): ChatGPT connection UI and confirmed toggles`.

### Task 8: Retrieval eval

**Files:**
- Create: `enterprise/lib/tasks/captain_retrieval_eval.rake`, task `captain:retrieval_eval[assistant_id]`, with ENV `LABELS=path.yml` and `WITH_AGENT=1`.

**Interfaces:**
- Labelled set:
  - For each conversation in the assistant's linked inboxes that has a product-card message whose `shopee_item_id` matches an enabled product, take the incoming text messages in that conversation (excluding card texts) as queries, labelled with that product.
  - Plus optional YAML `[{ query:, expected_type: product|faq, expected_id: }]`.
- Retriever metrics: hit@`TOP_K` and MRR (the reciprocal rank of the expected entry, 0 if absent).
- `WITH_AGENT=1`: run the draft agent with injection off and record the ids its tools returned in order. Compute the same metrics. This needs the ChatGPT connection; skip it with a message if the connection is absent.
- Output: a plain table, `variant | n | hit@5 | MRR`, plus the 10 worst misses (query → expected, got).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Checks.**
  - (a) On seeded local data (3 products, 3 card conversations with 2 text questions each, and a YAML with 2 FAQ queries), the task prints the table with n = 8 and plausible values.
  - (b) Without a connection, `WITH_AGENT=1` prints the skip message and exits 0.
  - (c) `DEFERRED-LIVE`: the owner runs it on prod data after connecting.
- [ ] **Step 3: Commit** `feat(captain): retrieval eval task`.
