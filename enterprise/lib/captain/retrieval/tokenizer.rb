module Captain::Retrieval::Tokenizer
  MIN_TOKEN_LENGTH = 3
  STOPWORDS = YAML.load_file(Rails.root.join('enterprise/config/captain_stopwords.yml')).values.flatten.to_set.freeze

  def self.tokens(text, common: Set.new)
    all = text.to_s.downcase.split(/[^a-z0-9]+/).select { |t| t.length >= MIN_TOKEN_LENGTH && STOPWORDS.exclude?(t) }
    return all if common.blank?

    filtered = all.reject { |t| common.include?(t) }
    filtered.presence || all
  end
end
