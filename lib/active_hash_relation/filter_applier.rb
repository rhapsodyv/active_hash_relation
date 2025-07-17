module ActiveHashRelation
  class FilterApplier
    include Helpers
    include ColumnFilters
    include AssociationFilters
    include ScopeFilters
    include SortFilters
    include LimitFilters

    attr_reader :configuration

    def initialize(resource, params, include_associations: false, model: nil, is_not: false)
      @configuration = Module.nesting.last.configuration
      @resource = resource
      if params.respond_to?(:to_unsafe_h)
        @params = HashWithIndifferentAccess.new(params.to_unsafe_h)
      else
        @params = HashWithIndifferentAccess.new(params)
      end
      @include_associations = include_associations
      @model = find_model(model)
      is_not ? @is_not = true : @is_not = false
    end

    def apply_filters
      run_or_filters
      run_not_filters

      table_name = @model.table_name
      @model.columns.each do |c|
        next if @params[c.name.to_s].nil?
        next if @params[c.name.to_s].is_a?(String) && @params[c.name.to_s].blank?

        # handle or filter for a single column using Arel: "name": ["value1", {"null": "true"}]
        # TODO: refactor this to use Arel for everything
        if @params[c.name.to_s].is_a?(Array)
          new_value = []
          @params[c.name.to_s].each do |v|
            if v.is_a?(Hash) && !v[:null].nil?
              if v[:null] == true || v[:null] == 'true' || v[:null] == 1 || v[:null] == '1'
                if @is_not
                  new_value << @resource.arel_table[c.name.to_s].not_eq(nil)
                  #resource = resource.where.not("#{table_name}.#{column} IS NULL")
                else
                  new_value << @resource.arel_table[c.name.to_s].eq(nil)
                  #resource = resource.where("#{table_name}.#{column} IS NULL")
                end
              end

              if v[:null] == false || v[:null] == 'false' || v[:null] == 0 || v[:null] == '0'
                if @is_not
                  new_value << @resource.arel_table[c.name.to_s].eq(nil)
                  # resource = resource.where.not("#{table_name}.#{column} IS NOT NULL")
                else
                  new_value << @resource.arel_table[c.name.to_s].not_eq(nil)
                  # resource = resource.where("#{table_name}.#{column} IS NOT NULL")
                end
              end
            else
              new_value << @resource.arel_table[c.name.to_s].eq(v)
            end
          end
          new_value = new_value.reduce(:or)
          if @is_not
            @resource = @resource.where.not(new_value)
          else
            @resource = @resource.where(new_value)
          end
          next
        end

        case c.type
        when :integer
          if @model.defined_enums[c.name] && @model.defined_enums[c.name][@params[c.name]]
            @params[c.name] = @model.defined_enums[c.name][@params[c.name]]
          end
          @resource = filter_integer(@resource, c.name, table_name, @params[c.name])
        when :float
          @resource = filter_float(@resource, c.name, table_name, @params[c.name])
        when :decimal
          @resource = filter_decimal(@resource, c.name, table_name, @params[c.name])
        when :string, :uuid, :text
          @resource = filter_string(@resource, c.name, table_name, @params[c.name])
        when :date
          @resource = filter_date(@resource, c.name, table_name, @params[c.name])
        when :datetime, :timestamp
          @resource = filter_datetime(@resource, c.name, table_name, @params[c.name])
        when :boolean
          @resource = filter_boolean(@resource, c.name, table_name, @params[c.name])
        end
      end

      if @params.include?(:scopes)
        if ActiveHashRelation.configuration.filter_active_record_scopes
          @resource = filter_scopes(@resource, @params[:scopes], @model)
        else
          Rails.logger.warn('Ignoring ActiveRecord scope filters because they are not enabled')
        end
      end
      @resource = filter_associations(@resource, @params, @model) if @include_associations
      @resource = apply_limit(@resource, @params[:limit]) if @params.include?(:limit)
      @resource = apply_sort(@resource, @params[:sort], @model) if @params.include?(:sort)

      return @resource
    end

    def filter_class(resource_name)
      "#{configuration.filter_class_prefix}#{resource_name.pluralize}#{configuration.filter_class_suffix}".constantize
    end

    def run_or_filters
      if @params[:or].is_a?(Array)
        if ActiveRecord::VERSION::MAJOR < 5
          return Rails.logger.warn("OR query is supported on ActiveRecord 5+")
        end

        if @params[:or].length >= 2
          array = @params[:or].map do |or_param|
            self.class.new(@resource, or_param, include_associations: @include_associations).apply_filters
          end

          @resource = @resource.merge(array[0])
          array[1..-1].each{|query| @resource = @resource.or(query)}
        else
          Rails.logger.warn("Can't run an OR with 1 element!")
        end
      end
    end

    def run_not_filters
      if @params[:not].is_a?(Hash) && !@params[:not].blank?
        @resource = self.class.new(
          @resource,
          @params[:not],
          include_associations: @include_associations,
          is_not: true
        ).apply_filters
      end
    end
  end
end
