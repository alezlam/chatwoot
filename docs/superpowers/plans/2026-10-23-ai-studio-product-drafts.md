# AI Studio Product-Aware Reply Drafts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ungate Captain on this self-hosted fork, add a per-assistant product catalog (AI Studio → Products), and make Captain write product-aware **draft** replies that the owner sends, edits or discards from the conversation.

**Architecture:** Reuse Captain's existing pipeline: hook on incoming message, then `ResponseSchedulerService`, then a job, then `AgentRunnerService`. A per-assistant `config['reply_mode']` (`draft` | `auto`) routes draft-mode assistants to a new `DraftReplyJob`. That job matches a product, injects its prompt and context into the system prompt, runs the agent with read-only tools, and upserts one `captain_reply_drafts` row per conversation instead of posting a message. The frontend gets a Products list and detail page under the renamed "AI Studio" sidebar group, a draft card above the reply box, a list badge, and ActionCable events.

**Tech Stack:** Rails 7.1 (enterprise overlay under `enterprise/`), `ai-agents` + `ruby_llm`, pgvector via `neighbor`, Vue 3 `<script setup>` + Vuex `createStore` factory, Tailwind.

**Spec:** `docs/superpowers/specs/2026-10-23-ai-studio-product-drafts-design.md`

## Global Constraints

- Base branch is `fork/develop` (alezlam/chatwoot), **not** `origin/develop`. The working branch is `feat/ai-studio-products`.
- **No spec files.** The user's global rule and the repo rule ("Avoid writing specs unless explicitly asked") override TDD. Each task ends with a one-off check run from the scratchpad (rails runner script, curl, or browser), and its output is reported. Never commit those checks.
- Captain code goes under `enterprise/`. The Shopee change is OSS (`app/`).
- No DB foreign keys. Use Rails associations. Migrations are `ActiveRecord::Migration[7.1]`, timestamp after `20261014000000`.
- Embeddings: `vector(1536)`, `text-embedding-3-small`, ivfflat with `opclass: :vector_cosine_ops`.
- Draft mode never sends to the buyer, never posts a handoff message, and never changes conversation state.
- Frontend: `components-next`, Composition API `<script setup>`, Tailwind only, i18n in `en.json` / `en.yml` only, and logical utilities (`ms`/`me`/`start`/`end`).
- Ruby: RuboCop, 150-char lines, compact `module/class` definitions. Run `bundle exec rubocop -a <files>` and `pnpm eslint <files>` before each commit.
- Stage explicit paths only. Never stage `AGENTS.md`, `CLAUDE.md`, `.claude/**` or `supabase/`.
- Commit messages: Conventional Commits. End with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Local env: `eval "$(rbenv init -)"`, Postgres on 5433, `overmind start -f Procfile.dev`, seed login `john@acme.inc` / `Password1!`. The LLM needs `CAPTAIN_OPEN_AI_API_KEY` in InstallationConfig (Super Admin → Settings, or `InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_API_KEY')`).

## Review Focus

1. **Buyer sends 3 messages in quick succession.** Expect one draft that answers the latest exchange, not three drafts racing. Task 6 check (c).
2. **Owner answers from the Shopee seller app.** The imported echo (`external_echo: true`) deletes the waiting draft, so it can't be sent twice. Task 6 check (e).
3. **Product card for an unknown or disabled item id.** Expect no `current_product`, a fallback to `product_lookup` or FAQs, and no invented product facts. Task 5 check (b).
4. **LLM error in draft mode.** Expect no draft, no handoff message, the conversation still `open`, and the buyer receives nothing. Task 6 check (d).
5. **An agent without access to an inbox** must not see or send that inbox's drafts. Task 7 check (c).

---

### Task 1: Remove the premium and enterprise gates

**Files:**
- Modify: `config/features.yml:115-118` (`custom_tools`) and `:143-146` (`captain_integration`). Set `enabled: true` and remove `premium: true`.
- Modify: `enterprise/config/premium_features.yml`. Remove `captain_integration` so `Internal::ReconcilePlanConfigService` (run by `check_new_versions_job.rb:28` after every Hub sync) stops disabling it.
- Modify: `lib/llm/feature_router.rb`.
  - Delete `captain_assistant_model` and `CAPTAIN_V2_ASSISTANT_MODEL`.
  - `installation_model_override` applies to features `assistant` and `conversation_completion` with no `self_hosted_paid?` check.
- Modify: `enterprise/app/models/enterprise/inbox.rb`. `captain_active?` becomes `captain_assistant.present?`. Delete `more_responses?`.
- Create: `db/migrate/20261023000001_enable_captain_for_existing_accounts.rb`. Copy the pattern of `20260120121402_enable_captain_tasks_for_existing_accounts.rb` and call `account.enable_features!('captain_integration', 'custom_tools')`.
- Modify: `app/javascript/dashboard/routes/dashboard/captain/captain.routes.js:30-51,175-180`. Add `INSTALLATION_TYPES.COMMUNITY` to every `installationTypes` array.
- Modify: `app/javascript/dashboard/featureFlags.js:66-78`. Remove `CAPTAIN` and `CAPTAIN_CUSTOM_TOOLS` from `PREMIUM_FEATURES`.

**Interfaces:**
- Produces: `Llm::FeatureRouter.resolve(feature: 'assistant', account:)[:model]` returns `CAPTAIN_OPEN_AI_MODEL` when it is set. `Inbox#captain_active?` is true whenever an assistant is linked.

- [ ] **Step 1: Make the edits above.** Run `bundle exec rails db:migrate`.
- [ ] **Step 2: Check (rails runner script in the scratchpad).**
  - `Account.all.all? { _1.feature_enabled?('captain_integration') && _1.feature_enabled?('custom_tools') }` returns `true`.
  - `Internal::ReconcilePlanConfigService.new.perform`, then the same check, still returns `true`.
  - With `CAPTAIN_OPEN_AI_MODEL=gpt-4.1-mini` in InstallationConfig, `Llm::FeatureRouter.resolve(feature: 'assistant', account: Account.first)[:model] == 'gpt-4.1-mini'`.
  - `Account.create!(name: 'x').feature_enabled?('captain_integration')` returns `true`. Destroy that account afterwards.
- [ ] **Step 3: Browser check.** Log in as the seed admin. The Captain sidebar group is visible, the assistants page shows no paywall, and the Tools page loads.
- [ ] **Step 4: Commit** `feat(captain): enable Captain on self-hosted installs without premium gate`.

### Task 2: Schema and models for products and drafts

**Files:**
- Create: `db/migrate/20261023000002_create_captain_products_and_reply_drafts.rb`
- Create: `enterprise/app/models/captain/product.rb`
- Create: `enterprise/app/models/captain/reply_draft.rb`
- Modify: `enterprise/app/models/captain/assistant.rb`
  - associations: `has_many :products, class_name: 'Captain::Product', dependent: :destroy_async` and `has_many :reply_drafts, class_name: 'Captain::ReplyDraft', dependent: :delete_all`
  - `store_accessor :config, :reply_mode` (`:54`)
  - validation `reply_mode` inclusion in `%w[draft auto]`, allow nil
  - `def draft_mode? = reply_mode.nil? || reply_mode == 'draft'`
  - add `:reply_mode` to the assistants controller's permitted config keys
- Modify: the enterprise conversation concern (`enterprise/app/models/enterprise/concerns/conversation.rb`). Add `has_one :captain_reply_draft, class_name: 'Captain::ReplyDraft', dependent: :delete`.

**Migration contents (spec §2):**
- `captain_products`: `account_id` (bigint, not null, indexed), `assistant_id` (bigint, not null, indexed), `name` (string, not null), `description` (text), `prompt` (text), `context` (text), `shopee_item_id` (string), `enabled` (boolean, default true, not null), `embedding` (vector, limit 1536), timestamps.
  - Unique index `[:assistant_id, :shopee_item_id]` `where: 'shopee_item_id IS NOT NULL'`.
  - ivfflat cosine index on `embedding`.
- `captain_reply_drafts`: `account_id`, `conversation_id` (unique index), `assistant_id`, `product_id` (nullable), `last_message_id` (bigint, not null), `content` (text, not null), timestamps.

**Interfaces:**
- Produces: `Captain::Product`.
  - `belongs_to :account`, `belongs_to :assistant, class_name: 'Captain::Assistant'`.
  - `has_neighbors :embedding, normalize: true`.
  - Scope `enabled`.
  - `after_commit` enqueues `Captain::Llm::UpdateEmbeddingJob.perform_later(self, embedding_text)` when `name`, `description` or `context` changed.
  - `embedding_text`: `"#{name}: #{description}\n#{context}"`.
  - `self.search(query, assistant:) -> Relation`: the top 3 enabled products of that assistant by cosine distance, using `Captain::Llm::EmbeddingService.new(account_id: assistant.account_id).get_embedding(query)`.
  - Validations: `name` presence; `shopee_item_id` uniqueness scoped to `assistant_id`, allow blank.
- Produces: `Captain::ReplyDraft`.
  - `belongs_to :account`, `:conversation`, `:assistant`, `:product` (optional).
  - `after_commit` dispatches `Events::Types::CAPTAIN_REPLY_DRAFT_UPDATED` on create/update and `CAPTAIN_REPLY_DRAFT_DELETED` on destroy. The constants are defined in Task 6; until then, add them to `lib/events/types.rb` in this task: `'captain.reply_draft.updated'` and `'captain.reply_draft.deleted'`.
  - Payload: `{ reply_draft: self }`.
  - `push_event_data -> Hash`: `{ id, conversation_id, inbox_id: conversation.inbox_id, product_id, product_name: product&.name, content, updated_at: updated_at.to_i }`.

- [ ] **Step 1: Write the migration and models.** Run `bundle exec rails db:migrate`. Confirm `db/schema.rb` shows both tables.
- [ ] **Step 2: Check (rails runner).**
  - Create a product with `shopee_item_id: '123'`. A second product with the same id on the same assistant raises `ActiveRecord::RecordInvalid`.
  - Run the embedding job inline (`perform_now`). `product.reload.embedding.size == 1536`.
  - `Captain::Product.search('<a word from its context>', assistant:).first == product`.
  - `assistant.draft_mode?` is `true` with no `reply_mode` set.
- [ ] **Step 3: Commit** `feat(captain): add products and reply drafts tables`.

### Task 3: Products REST API

**Files:**
- Modify: `config/routes.rb:83` (captain namespace). Inside `resources :assistants`, add `resources :products, only: [:index, :show, :create, :update, :destroy]`.
- Create: `enterprise/app/controllers/api/v1/accounts/captain/products_controller.rb`. Copy `scenarios_controller.rb`: `check_authorization(Captain::Product)`, `set_assistant`, `set_product`, `create!` with `.merge(account: Current.account)`.
  - Permit: `params.require(:product).permit(:name, :description, :prompt, :context, :shopee_item_id, :enabled)`.
  - Index ordered by `name`. Optional `searchKey` filters with `name ILIKE`.
- Create: `enterprise/app/policies/captain/product_policy.rb`. `index?`/`show?` return `true`; `create?`/`update?`/`destroy?` return `@account_user.administrator?`.
- Create: `enterprise/app/views/api/v1/accounts/captain/products/{index,show,create,update}.json.jbuilder` and partial `enterprise/app/views/api/v1/models/captain/_product.json.jbuilder`.
  - Fields: id, assistant_id, name, description, prompt, context, shopee_item_id, enabled, created_at, updated_at (as `.to_i`, matching the scenario partial).
  - Index shape: `{ payload: [...], meta: { total_count } }`.

**Interfaces:**
- Produces:
  - `GET|POST /api/v1/accounts/:account_id/captain/assistants/:assistant_id/products` with body `{ product: {...} }`
  - `GET|PATCH|DELETE /api/v1/accounts/:account_id/captain/assistants/:assistant_id/products/:id`

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Check (curl with the seed admin's `api_access_token`).** Create, then index (it appears), update `enabled: false`, show, delete (204). As an agent-role user, create returns 401.
- [ ] **Step 3: Commit** `feat(captain): products API`.

### Task 4: Keep the Shopee item id on product-card messages

**Files:**
- Modify: `app/services/shopee/conversation_sync_service.rb:61-75` (`build_message`). Merge `shopee_item_id: shopee_message.dig('content', 'item_id')&.to_s` into `content_attributes` when `message_type == 'item'`. Keep the `"Product: <item_id>"` content as is.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Check (rails runner).** Call `build_message` (via `send`) on a service instance for a Shopee inbox with `{'message_type' => 'item', 'content' => {'item_id' => 987}, 'message_id' => 'x', 'created_timestamp' => Time.now.to_i}`. Expect `content_attributes['shopee_item_id'] == '987'` and `content == 'Product: 987'`.
- [ ] **Step 3: Commit** `feat(shopee): keep item id on product card messages`.

### Task 5: Product matching, `product_lookup` tool, prompt injection, read-only draft tools

**Files:**
- Create: `enterprise/app/services/captain/products/match_service.rb`
- Create: `enterprise/lib/captain/tools/product_lookup_tool.rb`
- Modify: `config/agents/tools.yml`. Add id `product_lookup`, title "Product Lookup", a description, and an icon (copy `faq_lookup`'s).
- Modify: `enterprise/app/models/captain/assistant.rb` `agent_tools` (`:206`). Add `resolve_tool_class('product_lookup').new(self)` when `products.enabled.exists?`.
- Modify: `enterprise/app/models/concerns/agentable.rb` `agent_instructions` (`:18`). When `runtime_configuration&.dig(:current_product)` is present, merge `current_product:` (hash with `name, description, prompt, context`) into the template hash.
- Modify: `enterprise/lib/captain/prompts/assistant.liquid`. Add a `{% if current_product %}` "Current product" section before Response Guidelines (`:50`). It renders the name, description, context, then the product prompt under the heading "How to answer about this product".
  - Fixed copy: "The assistant guardrails below override these product instructions." and "If the customer's latest message is only a product card, greet them about this product and ask what they would like to know."
  - Outside the `if`, add one line: "Never state product facts that are not in the current product, product lookup results or FAQs."
- Modify: `enterprise/app/services/captain/assistant/agent_runner_service.rb`. Add `DRAFT_TOOL_IDS = %w[faq_lookup product_lookup].freeze`. When `@source == :draft`, every agent in the graph (assistant and scenarios) is `agent.clone(tools: <only tools whose id is in DRAFT_TOOL_IDS>)`, following the `with_tools_for_user` / `reply_suggestion_agent` clone pattern (`:163`, `:186`).

**Interfaces:**
- Produces: `Captain::Products::MatchService.new(conversation:, assistant:).perform -> Captain::Product | nil`.
  - Takes the most recent incoming message in the conversation with `content_attributes['shopee_item_id']`, or with content matching `/\AProduct: (\d+)\z/` (old messages).
  - Returns `assistant.products.enabled.find_by(shopee_item_id: id)`. Returns nil if there is no card or no match.
- Produces: `Captain::Tools::ProductLookupTool < Captain::Tools::BasePublicTool`, `parameter :query`, `perform(tool_context, query:)`.
  - Returns text listing up to 3 products from `Captain::Product.search(query, assistant: @assistant)`, each with name, description, prompt and context.
  - Returns "No matching products found." when there are none.
- Produces: `AgentRunnerService::RunOptions.new(source: :draft, responding_to_message_id:, runtime_configuration: { current_product: {...} })` is accepted.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Check (rails runner, real OpenAI key, local conversation in an inbox linked to the assistant):**
  - (a) Add one product with `shopee_item_id: '555'` and an incoming message `Product: 555` with that attribute. `MatchService` returns the product. `AgentRunnerService.new(assistant:, conversation:, run_options: RunOptions.new(source: :draft, runtime_configuration: { current_product: ... })).generate_response(message_history: MessageHistoryBuilderService.new(conversation:).perform)` returns a `response` that mentions the product and asks what the buyer wants.
  - (b) Message `Product: 999` (no such product), and separately the same message for a disabled product. `MatchService` returns nil, and the response states no product facts.
  - (c) Text-only message naming the product. The run log shows `product_lookup` being called.
  - (d) In draft source, the agent's tool names contain no `handoff` and no `resolve_conversation`. Print `agent.tools.map(&:name)`.
- [ ] **Step 3: Commit** `feat(captain): product matching and lookup tool for drafts`.

### Task 6: Draft generation flow, deletion on reply, realtime events

**Files:**
- Modify: `enterprise/app/models/enterprise/inbox.rb:11`. `active_bot?` becomes `super || (captain_active? && !captain_assistant.draft_mode?)`, so draft-mode conversations are created `open`.
- Modify: `enterprise/app/services/enterprise/message_templates/hook_execution_service.rb` `trigger_templates`. After `track_captain_eligibility`, add `return Captain::Conversation::ResponseSchedulerService.new(message: message).perform if inbox.captain_assistant.draft_mode?`, placed before the `pending?` and handoff lines.
- Modify: `enterprise/app/services/captain/conversation/response_scheduler_service.rb:10`. Enqueue `DraftReplyJob` instead of `ResponseBuilderJob` when `@assistant.draft_mode?`. Same args, same delay.
- Create: `enterprise/app/jobs/captain/conversation/draft_reply_job.rb`
- Modify: `lib/events/types.rb` (constants, if Task 2 did not add them) and `enterprise/app/listeners/enterprise/action_cable_listener.rb`.
  - Add `captain_reply_draft_updated(event)` and `captain_reply_draft_deleted(event)`, following `copilot_message_created`.
  - Broadcast `draft.push_event_data` to `user_tokens(account, conversation.inbox.members)`, plus admins via the existing helper.
- Modify: `enterprise/app/models/enterprise/message.rb`. Add an after-create-commit hook that runs `conversation.captain_reply_draft&.destroy!` when `outgoing? && !private?`. This covers dashboard sends, Shopee/WhatsApp echoes (`external_echo`) and sending the draft itself. Hook into the existing `execute_after_create_commit_callbacks` chain (`app/models/message.rb:333`) through the enterprise prepend.

**Interfaces:**
- Consumes: `Captain::Products::MatchService` and `RunOptions(source: :draft, ...)` (Task 5); `Captain::ReplyDraft` (Task 2).
- Produces: `Captain::Conversation::DraftReplyJob#perform(conversation, assistant, responding_to_message_id = nil)`. Queue and `retry_on` are the same as `ResponseBuilderJob`. Steps:
  1. Return if a newer `captain_response_triggering` message exists (copy `newer_customer_message_arrived?`, `response_builder_job.rb:167`).
  2. `product = MatchService...perform`.
  3. Run the runner with `source: :draft`, `responding_to_message_id`, and `runtime_configuration: { current_product: product&.slice(:name, :description, :prompt, :context) }`.
  4. If the result has `'error'` or `'handoff_tool_called'`, log at `warn` and return. No message, no handoff.
  5. Re-check for a newer message.
  6. `Captain::ReplyDraft.find_or_initialize_by(conversation:)`, then `.update!(account:, assistant:, product:, content: result['response'], last_message_id: responding_to_message_id)`.
  - Other `StandardError`s are logged and swallowed, except the two that `ResponseBuilderJob` re-raises for `retry_on`.
- Produces: ActionCable events `captain.reply_draft.updated` (payload: `push_event_data`) and `captain.reply_draft.deleted` (payload: `{ id, conversation_id }`).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Check (local stack running, assistant in draft mode linked to a WhatsApp or API inbox):**
  - (a) Create a new conversation with an incoming message. Its status is `open`, not `pending`. After Sidekiq runs, `conversation.captain_reply_draft.content` is present and no outgoing message was created.
  - (b) Switch the assistant to `reply_mode: 'auto'`. A new conversation is `pending` and Captain posts an outgoing reply, which is today's behaviour. Switch it back.
  - (c) Create 3 incoming messages within 1 second. Exactly one `captain_reply_drafts` row exists, and its `last_message_id` is the third message's id.
  - (d) Temporarily set an invalid `CAPTAIN_OPEN_AI_API_KEY`, then send an incoming message. No draft is created, there is no new outgoing message, and the status stays `open`. Restore the key.
  - (e) With a draft present, create an outgoing message with `content_attributes: { external_echo: true }`. The draft is gone. Repeat with a private note: the draft stays.
  - (f) With the browser open on the account, `ActionCable` frames show `captain.reply_draft.updated` and `captain.reply_draft.deleted` (DevTools → WS).
- [ ] **Step 3: Commit** `feat(captain): draft reply mode`.

### Task 7: Reply drafts REST API

**Files:**
- Modify: `config/routes.rb` captain namespace. Add `resources :reply_drafts, only: [:index, :destroy] do member { post :send_reply } end`.
- Create: `enterprise/app/controllers/api/v1/accounts/captain/reply_drafts_controller.rb`
- Create: `enterprise/app/policies/captain/reply_draft_policy.rb`, with all actions returning `true`. Inbox access is enforced in the controller.
- Create: `enterprise/app/views/api/v1/accounts/captain/reply_drafts/index.json.jbuilder`, which renders `payload` as an array of `push_event_data`.

**Interfaces:**
- Produces:
  - `GET /api/v1/accounts/:account_id/captain/reply_drafts` lists drafts whose `conversation.inbox_id` is in `Current.user.assigned_inboxes` (all inboxes for administrators, following how `ConversationFinder` scopes inboxes).
  - `POST /captain/reply_drafts/:id/send_reply` with body `{ content?: string }`. It calls `Messages::MessageBuilder.new(Current.user, draft.conversation, { content: params[:content].presence || draft.content }).perform`. The Task 6 hook deletes the draft. It renders the message with the existing message partial (`api/v1/accounts/conversations/messages/create` shape).
  - `DELETE /captain/reply_drafts/:id` destroys the draft and returns 204.
  - Show, send_reply and destroy run `authorize draft.conversation.inbox, :show?` (InboxPolicy), so an agent without inbox access gets 401.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Check (curl):**
  - (a) Index as an admin lists the Task 6 draft.
  - (b) `send_reply` with edited content creates an outgoing message with that content, the draft row is gone, and a WhatsApp or API inbox receives it through `SendReplyJob` (check the logs).
  - (c) Create an agent who is not a member of that inbox. Index does not include the draft, and `send_reply`/`DELETE` return 401.
- [ ] **Step 3: Commit** `feat(captain): reply drafts API`.

### Task 8: AI Studio sidebar and Products pages

**Files:**
- Modify: `app/javascript/dashboard/i18n/locale/en/settings.json:335`. Set `"CAPTAIN": "AI Studio"` and add `"CAPTAIN_PRODUCTS": "Products"`.
- Modify: `app/javascript/dashboard/components-next/sidebar/Sidebar.vue:511-590`. Add a Products child **first**, with `navigationPath: 'captain_assistants_products_index'` and `activeOn: ['captain_assistants_products_index', 'captain_assistants_products_show']`.
- Modify: `app/javascript/dashboard/routes/dashboard/captain/captain.routes.js`. Add `captain_assistants_products_index` (`.../captain/:assistantId/products`) and `captain_assistants_products_show` (`.../captain/:assistantId/products/:productId`), both with `meta`.
- Modify: `app/javascript/dashboard/routes/dashboard/captain/pages/AssistantsIndexPage.vue:55-64`. Add `captain_assistants_products_index` to `isAValidRoute`.
- Create: `app/javascript/dashboard/api/captain/products.js`. Copy `api/captain/scenarios.js`, with the path `products` and the body key `product`.
- Create: `app/javascript/dashboard/store/captain/products.js`. `createStore({ name: 'CaptainProduct', API: CaptainProducts })` with the same `update` action shape as `store/captain/scenarios.js`. Register it as `captainProducts` in `store/index.js`.
- Create: `app/javascript/dashboard/routes/dashboard/captain/products/Index.vue`.
  - `PageLayout` with a header "Products", a search slot, and an "Add product" button that opens a create dialog (name and description only, then route to the detail page).
  - Rows show the name, the description truncated to one line, a Shopee item id badge, and an enabled `Switch`. Clicking a row goes to the show route.
  - An empty state.
- Create: `app/javascript/dashboard/routes/dashboard/captain/products/Show.vue`.
  - A form with `Input` (name, Shopee item id), `TextArea` (description "What this item is", prompt "How to answer about this item", context "Product facts"), `Switch` (enabled), and Save and Delete (`DeleteDialog`) buttons.
  - A back link to the index.
  - Save and Delete are disabled for non-admins.
- Modify: `app/javascript/dashboard/i18n/locale/en/integrations.json`. Add a `CAPTAIN.PRODUCTS` block with all the strings above.
- Modify: assistant settings `AssistantBasicSettingsForm.vue`. Show a read-only line "Reply mode: Draft (owner approves every reply)" (i18n key `CAPTAIN.ASSISTANTS.FORM.REPLY_MODE_DRAFT`).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Browser check.**
  - The sidebar shows "AI Studio" with Products first.
  - You can add a product, open it, edit all fields, save, reload and see the values persist, toggle enabled from the list, and delete it.
  - Search filters the list.
  - Agent login: the list is viewable, and saving is disabled.
  - Run `pnpm eslint` on the touched files.
- [ ] **Step 3: Commit** `feat(captain): AI Studio products pages`.

### Task 9: Draft card, list badge, realtime wiring

**Files:**
- Create: `app/javascript/dashboard/api/captain/replyDrafts.js`.
  - `ApiClient('captain/reply_drafts', { accountScoped: true })`
  - `get()`
  - `sendReply(id, content)` → `POST ${url}/${id}/send_reply { content }`
  - `delete(id)`
- Create: `app/javascript/dashboard/store/captain/replyDrafts.js`. Use `createStore({ name: 'CaptainReplyDraft', API })` plus:
  - action `upsert(draft)`, which replaces the record with the same `conversation_id`
  - action `removeByConversation(conversationId)`
  - getter `getByConversationId(id)`
  - Register as `captainReplyDrafts`.
- Modify: `app/javascript/dashboard/helper/actionCable.js:41-77`.
  - Map `'captain.reply_draft.updated'` to dispatch `captainReplyDrafts/upsert`.
  - Map `'captain.reply_draft.deleted'` to dispatch `captainReplyDrafts/removeByConversation` with `data.conversation_id`.
- Create: `app/javascript/dashboard/components-next/captain/ReplyDraftCard.vue`.
  - Props: `conversationId`.
  - Reads the draft from the getter and renders nothing if there is none.
  - Shows a "Draft reply" label, the matched product name if present, and the content.
  - Buttons:
    - **Send**: `sendReply(id)`, then remove from the store.
    - **Edit**: `emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, content)` and hide the card locally for this conversation. The server draft stays until a reply is sent.
    - **Discard**: `delete(id)`, then remove from the store.
- Modify: `app/javascript/dashboard/components/widgets/conversation/MessagesView.vue`. Render `<ReplyDraftCard :conversation-id="currentChat.id" />` directly above the reply box, between `</MessageList>` (`:642`) and the wrapper at `:643`.
- Modify: `app/javascript/dashboard/components/widgets/conversation/ConversationCard.vue:150-179` (meta row). Add a small "Draft" badge when `captainReplyDrafts/getByConversationId(chat.id)` exists.
- Modify: the conversation list container (`ChatList.vue` mount). Dispatch `captainReplyDrafts/get` once on mount.
- Modify: `integrations.json`. Add a `CAPTAIN.REPLY_DRAFT` block: `LABEL`, `SEND`, `EDIT`, `DISCARD`, `BADGE`, `SEND_ERROR`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Browser check (local stack, draft-mode assistant):**
  - Send an incoming message by API. Without a reload, the card appears above the reply box and the list shows the "Draft" badge.
  - **Send** delivers the message, and the card and badge disappear.
  - A new incoming message makes a new card. **Edit** puts the text in the editor and hides the card; sending from the editor clears the badge.
  - **Discard** removes the card and the badge.
  - Two buyer messages in a row: the card updates in place, and there is only ever one card.
  - Run `pnpm eslint` on the touched files.
- [ ] **Step 3: Commit** `feat(captain): reply draft card and badge`.

---

**Already verified, no task needed:** Captain's inbox linking has no channel-type allowlist (`inboxes_controller.rb:9-13`, `ConnectInboxForm.vue:42`), so Shopee and WhatsApp inboxes can already be linked. Task 6's checks run on a WhatsApp or API inbox. One live Shopee pass happens after deploy.
