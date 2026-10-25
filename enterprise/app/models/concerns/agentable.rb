module Concerns::Agentable
  extend ActiveSupport::Concern

  DEFAULT_TEMPERATURE = 0.5

  def agent(runtime_configuration: nil, runtime_agent_name: nil)
    Agents::Agent.new(
      name: runtime_agent_name || agent_name,
      instructions: ->(context) { agent_instructions(context, runtime_configuration: runtime_configuration) },
      tools: agent_tools,
      model: agent_model,
      temperature: temperature.presence&.to_f || DEFAULT_TEMPERATURE,
      response_schema: agent_response_schema
    )
  end

  def agent_instructions(context = nil, prompt_template: template_name, runtime_configuration: nil)
    enhanced_context = runtime_prompt_context(prompt_context, runtime_configuration)

    if context
      state = context.context[:state] || {}
      config = state[:assistant_config] || {}
      enhanced_context = enhanced_context.merge(
        current_time: format_current_time(state[:timezone]),
        conversation: state[:conversation] || {},
        contact: config['feature_contact_attributes'].present? ? state[:contact] : nil,
        campaign: state[:campaign] || {},
        message_length_limit: state[:message_length_limit]
      )
    end

    Captain::PromptRenderer.render(prompt_template, enhanced_context.with_indifferent_access)
  end

  def agent_model
    route = Llm::FeatureRouter.resolve(feature: 'assistant', account: account)
    return route[:model] if route[:source] == :account_override || account&.feature_enabled?('captain_integration')

    installation_model.presence || route[:model]
  end

  private

  def runtime_prompt_context(context, runtime_configuration)
    # A plain hash runtime configuration (draft runs) carries only per-run values such as current_product.
    return runtime_configuration.prompt_context_for(self, context) if runtime_configuration.respond_to?(:prompt_context_for)

    context.merge(current_product_context(runtime_configuration), retrieved_knowledge_context(runtime_configuration),
                  draft_context(runtime_configuration, context))
  end

  # Draft runs only get read-only tools and a human sends the reply, so the prompt drops handoff wording and other tools.
  def draft_context(runtime_configuration, context)
    return {} unless runtime_configuration.try(:dig, :draft)

    draft_tool_ids = Captain::Assistant::AgentRunnerService::DRAFT_TOOL_IDS
    { draft: true, tools: context[:tools]&.select { |tool| draft_tool_ids.include?(tool[:id]) } }.compact
  end

  def current_product_context(runtime_configuration)
    current_product = runtime_configuration.try(:dig, :current_product)
    return {} if current_product.blank?

    { current_product: current_product.to_h.symbolize_keys.slice(:name, :description, :prompt, :context) }
  end

  def retrieved_knowledge_context(runtime_configuration)
    retrieved_knowledge = runtime_configuration.try(:dig, :retrieved_knowledge)
    return {} if retrieved_knowledge.blank?

    { retrieved_knowledge: retrieved_knowledge }
  end

  def agent_name
    raise NotImplementedError, "#{self.class} must implement agent_name"
  end

  def template_name
    self.class.name.demodulize.underscore
  end

  def agent_tools
    []  # Default implementation, override if needed
  end

  def installation_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
  end

  def agent_response_schema
    Captain::ResponseSchema
  end

  def format_current_time(timezone)
    tz = ActiveSupport::TimeZone[timezone] if timezone.present?
    time = tz ? Time.current.in_time_zone(tz) : Time.current
    time.strftime('%A, %B %d, %Y %I:%M %p %Z')
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end
end
