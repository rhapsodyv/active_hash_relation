module ActiveHashRelation::ColumnFilters
  # O cliente nomeia os operadores como SQL (`gt`/`lt`) e abrevia os de
  # texto (`start`/`end`); este gem sempre os chamou de `ge`/`le` e
  # `starts_with`/`ends_with`. Aceitar os dois nomes evita o pior modo de
  # falhar que existe aqui: a chave desconhecida é descartada em silêncio,
  # a resposta volta 200 e a lista aparece sem o filtro aplicado.
  OPERATOR_ALIASES = {
    'gt'    => 'ge',
    'lt'    => 'le',
    'start' => 'starts_with',
    'end'   => 'ends_with'
  }.freeze

  # Devolve uma cópia com o nome canônico preenchido. O nome canônico
  # explícito vence o apelido; nada é mutado no hash do chamador.
  def with_operator_aliases(param)
    normalized = param.respond_to?(:with_indifferent_access) ? param.with_indifferent_access : param
    OPERATOR_ALIASES.each do |from, to|
      next if normalized[from].nil? || !normalized[to].nil?
      normalized[to] = normalized[from]
    end
    normalized
  end

  # "Diferente de", "não está em" e "não contém":
  #   {campo: {not_eq: X}}, {campo: {not_in: [X, Y]}}, {campo: {not_like: "x"}}
  #
  # O vazio ENTRA. O `not` deste gem segue o SQL — `campo <> X` deixa de
  # fora o registro com o campo NULL, porque comparar NULL não dá
  # verdadeiro —, e "Unidade diferente de 101" esconderia o que não tem
  # unidade. Quem filtra "tudo menos X" espera ver o que não é X, inclusive
  # o que está em branco (é o que fazem o Notion, o Airtable e o Metabase).
  # Pra deixar o vazio de fora, a pessoa combina com `{null: false}`.
  NEGATED_OPERATORS = %w[not_eq not_in not_like].freeze

  def negated_operators?(param)
    (param.keys.map(&:to_s) & NEGATED_OPERATORS).any?
  end

  # O resto do hash, pros outros operadores; nil quando não sobra nada —
  # o `with_ilike` sozinho não filtra.
  def without_negated_operators(param)
    rest = param.reject { |key, _| NEGATED_OPERATORS.include?(key.to_s) }
    (rest.keys.map(&:to_s) - ['with_ilike']).empty? ? nil : rest
  end

  def filter_negated(model, column, resource, param)
    attribute = resource.arel_table[column.name]
    clauses = []

    values = []
    values << param[:not_eq] unless param[:not_eq].nil? || param[:not_eq] == ''
    values.concat(Array(param[:not_in])) unless param[:not_in].nil?
    clauses << attribute.not_in(Array(normalize_value(model, column, values))) unless values.empty?

    unless param[:not_like].blank?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(param[:not_like].to_s)}%"
      clauses << attribute.does_not_match(pattern, nil, !param[:with_ilike])
    end

    return resource if clauses.empty?

    clause = clauses.reduce { |acc, node| acc.and(node) }.or(attribute.eq(nil))
    @is_not ? resource.where.not(clause) : resource.where(clause)
  end

  def normalize_value(model, column, value)
    return value if column.nil? || model.nil?
    if model.defined_enums[column.name]
      if value.is_a?(Array)
        value = value.map { |v| model.defined_enums[column.name][v] || v }
      else
        value = model.defined_enums[column.name][value] || value
      end
    end
    value
  end

  def filter_integer(model, column, resource, column_name, table_name, param)
    if param.is_a? Array
      n_param = param.to_s.gsub("\"","'").gsub("[","").gsub("]","") #fix this!
      n_param = normalize_value(model, column, n_param)
      if @is_not
        return resource.where.not("#{table_name}.#{column_name} IN (#{n_param})")
      else
        return resource.where("#{table_name}.#{column_name} IN (#{n_param})")
      end
    elsif param.is_a? Hash
      if !param[:null].nil?
        return null_filters(resource, table_name, column_name, param)
      else
        return apply_leq_geq_le_ge_filters(model, column, resource, table_name, column_name, param)
      end
    else
      param = normalize_value(model, column, param)
      if @is_not
        return resource.where.not("#{table_name}.#{column_name} = ?", param)
      else
        return resource.where("#{table_name}.#{column_name} = ?", param)
      end
    end
  end

  def filter_float(resource, column, table_name, param)
    filter_integer(nil, nil, resource, column, table_name, param)
  end

  def filter_decimal(resource, column, table_name, param)
    filter_integer(nil, nil, resource, column, table_name, param)
  end

  def filter_string(resource, column, table_name, param)
    if param.is_a? Array
      n_param = param.to_s.gsub("\"","'").gsub("[","").gsub("]","") #fix this!
      if @is_not
        return resource.where.not("#{table_name}.#{column} IN (#{n_param})")
      else
        return resource.where("#{table_name}.#{column} IN (#{n_param})")
      end
    elsif param.is_a? Hash
      if !param[:null].nil?
        return null_filters(resource, table_name, column, param)
      else
        return apply_like_filters(resource, table_name, column, param)
      end
    else
      if @is_not
        return resource.where.not("#{table_name}.#{column} = ?", param)
      else
        return resource.where("#{table_name}.#{column} = ?", param)
      end
    end
  end

  def filter_text(resource, column, table_name, param)
    return filter_string(resource, column, table_name, param)
  end

  def filter_date(resource, column, table_name, param)
    if param.is_a? Array
      n_param = param.to_s.gsub("\"","'").gsub("[","").gsub("]","") #fix this!
      if @is_not
        return resource.where.not("#{table_name}.#{column} IN (#{n_param})")
      else
        return resource.where("#{table_name}.#{column} IN (#{n_param})")
      end
    elsif param.is_a? Hash
      if !param[:null].nil?
        return null_filters(resource, table_name, column, param)
      else
        return apply_leq_geq_le_ge_filters(nil, nil, resource, table_name, column, param)
      end
    else
      if @is_not
        resource = resource.where.not(column => param)
      else
        resource = resource.where(column => param)
      end
    end

    return resource
  end

  def filter_datetime(resource, column, table_name, param)
    if param.is_a? Array
      n_param = param.to_s.gsub("\"","'").gsub("[","").gsub("]","") #fix this!
      if @is_not
        return resource = resource.where.not("#{table_name}.#{column} IN (#{n_param})")
      else
        return resource = resource.where("#{table_name}.#{column} IN (#{n_param})")
      end
    elsif param.is_a? Hash
      if !param[:null].nil?
        return null_filters(resource, table_name, column, param)
      else
        return apply_leq_geq_le_ge_filters(nil, nil, resource, table_name, column, param)
      end
    else
      if @is_not
        resource = resource.where.not(column => param)
      else
        resource = resource.where(column => param)
      end
    end

    return resource
  end

  def filter_boolean(resource, column, table_name, param)
    if param.is_a?(Hash) && !param[:null].nil?
      return null_filters(resource, table_name, column, param)
    else
      if ActiveRecord::VERSION::MAJOR >= 5
        b_param = ActiveRecord::Type::Boolean.new.cast(param)
      else
        b_param = ActiveRecord::Type::Boolean.new.type_cast_from_database(param)
      end

      if @is_not
        resource = resource.where.not(column => b_param)
      else
        resource = resource.where(column => b_param)
      end
    end
  end

  private

  def apply_leq_geq_le_ge_filters(model, column, resource, table_name, column_name, param)
    param = with_operator_aliases(param)

    return resource.where("#{table_name}.#{column_name} = ?", normalize_value(model, column, param[:eq])) if param[:eq]

    if !param[:leq].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column_name} <= ?", normalize_value(model, column, param[:leq]))
      else
        resource = resource.where("#{table_name}.#{column_name} <= ?", normalize_value(model, column, param[:leq]))
      end
    elsif !param[:le].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column_name} < ?", normalize_value(model, column, param[:le]))
      else
        resource = resource.where("#{table_name}.#{column_name} < ?", normalize_value(model, column, param[:le]))
      end
    end

    if !param[:geq].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column_name} >= ?", normalize_value(model, column, param[:geq]))
      else
        resource = resource.where("#{table_name}.#{column_name} >= ?", normalize_value(model, column, param[:geq]))
      end
    elsif !param[:ge].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column_name} > ?", normalize_value(model, column, param[:ge]))
      else
        resource = resource.where("#{table_name}.#{column_name} > ?", normalize_value(model, column, param[:ge]))
      end
    end

    return resource
  end

  def apply_like_filters(resource, table_name, column, param)
    param = with_operator_aliases(param)

    like_method = "LIKE"
    like_method = "ILIKE" if param[:with_ilike]

    if !param[:starts_with].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} #{like_method} ?", "#{param[:starts_with]}%")
      else
        resource = resource.where("#{table_name}.#{column} #{like_method} ?", "#{param[:starts_with]}%")
      end
    end

    if !param[:ends_with].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} #{like_method} ?", "%#{param[:ends_with]}")
      else
        resource = resource.where("#{table_name}.#{column} #{like_method} ?", "%#{param[:ends_with]}")
      end
    end

    if !param[:like].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} #{like_method} ?", "%#{param[:like]}%")
      else
        resource = resource.where("#{table_name}.#{column} #{like_method} ?", "%#{param[:like]}%")
      end
    end

    # `matches` usa o padrão exatamente como veio, sem os `%` que o `like`
    # acrescenta — mesma semântica do Arel#matches. É o operador para quem
    # quer escrever o próprio curinga ("Jo%o", "%@gmail.com").
    if !param[:matches].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} #{like_method} ?", param[:matches])
      else
        resource = resource.where("#{table_name}.#{column} #{like_method} ?", param[:matches])
      end
    end

    if !param[:eq].blank?
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} = ?", param[:eq])
      else
        resource = resource.where("#{table_name}.#{column} = ?", param[:eq])
      end
    end

    return resource
  end
  
  def null_filters(resource, table_name, column, param)
    if param[:null] == true || param[:null] == 'true' || param[:null] == 1 || param[:null] == '1'
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} IS NULL")
      else
        resource = resource.where("#{table_name}.#{column} IS NULL")
      end
    end
    
    if param[:null] == false || param[:null] == 'false' || param[:null] == 0 || param[:null] == '0'
      if @is_not
        resource = resource.where.not("#{table_name}.#{column} IS NOT NULL")
      else
        resource = resource.where("#{table_name}.#{column} IS NOT NULL")
      end
    end
    
    return resource
  end
end
