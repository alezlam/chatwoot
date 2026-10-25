# Registers the ChatGPT (Codex Responses) provider with ruby_llm; re-registered on code reload.
Rails.application.config.to_prepare do
  RubyLLM::Provider.register :chatgpt, Captain::Chatgpt::Provider
end
