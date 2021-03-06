require 'active_support/concern'

module Ripple

  class CriteriaError < StandardError; end

  # chainable Criteria methods such as :where, :lt, :lte, :gt, :gte, :between, 
  # with sort, :skip, :limit options
  class Criteria

    include Translation
    include Enumerable

    attr_accessor :selector, :klass, :options, :response, :cached, :total, :docs, :document_ids

    def initialize(klass)
      @selector, @klass, @options, @documents, @cached = "", klass, {}
      clear_cache
    end

    # Main criteria selector to search records
    #
    # === Example
    #
    #   Model.where(tags: "nerd", name: "Joe", something: 2)
    #
    # will append this selector:
    # "(tags:nerd AND name:Joe AND something:2)"
    def where(selector = nil)
      clone.tap do |crit|
        case selector
        when String
          crit.add_restriction selector
        when Hash
          crit.add_restriction to_lucene_pair(selector)
        end
      end
    end

    # Add an OR selector
    #
    # === Example
    #
    #   Product.or({name: "Pants"}, {name: "Shirt"})
    #
    # will append this selector:
    # "((name:Pants) OR (name:Shirt))"
    def or(*criterion)
      clone.tap do |crit|
        crit.add_restriction do
          criterion.each do |c|
            crit.add_restriction(to_lucene_pair(c, operator: "OR"), operator: "OR" )
          end
        end
      end
    end

    alias :any_of :or

    # Add an Range selector. Values in the passed hash can be either a Range or an Array.
    # of the passed hash has multiple elements, the condition will be AND.
    # The range is inclusive.
    #
    # === Example
    #
    #   Product.between(availibility: 1..3, price: [12, 20])
    #
    # will append this selector:
    # "((availibility:[1 TO 3] AND price:[12 TO 20]))"
    def between(*criterion)
      clone.tap do |crit|
        crit.add_restriction do
          criterion.each do |c|
            crit.add_restriction(to_lucene_pair(c, operator: "BETWEEN"))
          end
        end
      end
    end

    # Add a 'less or equal than' selector
    #
    # === Example
    #
    #   Product.lte(quantity: 10, ratings: 5)
    #
    # will append this selector:
    # "((quantity:[* TO 10] AND ratings:[* TO 5]))"
    def lte(*criterion)
      clone.tap do |crit|
        crit.add_restriction do
          crit.criterion.each do |c|
            c.each {|k,v| c[k]=Array.wrap(v).unshift(10**20)}
            crit.add_restriction(to_lucene_pair(c, operator: "BETWEEN"))
          end
        end
      end
    end

    # Add a 'greater or equal than' selector
    #
    # === Example
    #
    #   Product.gte(quantity: 0, ratings: 5)
    #
    # will append this selector:
    # "((quantity:[0 TO *] AND ratings:[5 TO *]))"
    def gte(*criterion)
      clone.tap do |crit|
        crit.add_restriction do
          crit.criterion.each do |c|
            c.each {|k,v| c[k]=Array.wrap(v).push(10**20)}
            crit.add_restriction(to_lucene_pair(c, operator: "BETWEEN"))
          end
        end
      end
    end

    # Add a 'less than' selector
    #
    # === Example
    #
    #   Product.lt(quantity: 10, ratings: 5)
    #
    # will append this selector:
    # "((quantity:{* TO 10} AND ratings:{* TO 5}))"
    def lt(*criterion)
      clone.tap do |crit|
        crit.add_restriction do
          criterion.each do |c|
            c.each {|k,v| c[k]=Array.wrap(v).unshift("*")}
            crit.add_restriction(to_lucene_pair(c, operator: "BETWEEN", exclusive: true))
          end
        end
      end
    end

    # Add a 'greater than' selector
    #
    # === Example
    #
    #   Product.gt(quantity: 0, ratings: 5)
    #
    # will append this selector:
    # "((quantity:{0 TO *} AND ratings:{5 TO *}))"
    def gt(*criterion)
      clone.tap do |crit|
        crit.add_restriction do
          criterion.each do |c|
            c.each {|k,v| c[k]=Array.wrap(v).push("*")}
            crit.add_restriction(to_lucene_pair(c, operator: "BETWEEN", exclusive: true))
          end
        end
      end
    end

    # Add sort options to criteria
    #
    # === Example
    #
    #   Product.between(availibility:[1,3]).sort(availibility: :asc, created_at: :desc)
    #
    # will append this sort option:
    # "availibility asc, created_at desc"
    def sort(sort_options)
      clone.tap do |crit|
        case sort_options
        when String
          crit.add_sort_option sort_options
        when Hash
          sort_options.each {|k,v| crit.add_sort_option "#{k} #{v.downcase}"}
        end
      end
    end

    alias :order_by :sort
    alias :order :sort

    # Add limit option to criteria. Useful for pagination. Default is 10.
    #
    # === Example
    #
    #   Product.between(availibility:[1,3]).limit(10)
    #
    # will limit the number of returned documetns to 10
    def limit(limit)
      clone.tap do |crit|
        crit.clear_cache
        crit.options[:rows] = limit
      end
    end

    alias :rows :limit

    # Add skip option to criteria. Useful for pagination. Default is 0.
    #
    # === Example
    #
    #   Product.between(availibility:[1,3]).skip(10)
    #
    def skip(skip)
      clone.tap do |crit|
        crit.clear_cache
        crit.options[:start] = skip
      end
    end

    alias :start :skip


    # Executes the search query
    def execute
      raise CriteriaError, t('empty_selector_error') if self.selector.blank?
      @response = @klass.search self.selector, self.options
    end

    # Returns the matched documents
    def documents
      if @cached
        @documents
      else
        parse_response
        @cached = true
        @documents = self.klass.find self.document_ids
      end
    end

    def each(&block)
      documents.each(&block)
    end

    # Total number of matching documents
    def total
      parse_response
      @total
    end

    # Array of matching document id's
    def document_ids
      parse_response
      @document_ids
    end

    def merge(criteria)
      crit = clone
      crit.merge!(criteria)
      crit
    end

    def merge!(criteria)
      add_restriction criteria.selector
      self.options.merge!(criteria.options)
      self
    end

    def to_proc
      ->{ self }
    end

    def ==(other)
      self.klass == other.klass && self.selector == other.selector && self.options == other.options
    end

    def initialize_copy(other)
      @selector = other.selector.dup
      @options = other.options.dup
      if other.response.present?
        @response = other.response.dup
        @documents = other.documents.dup
        @docs = other.docs.dup
        @document_ids = other.document_ids.dup
      end
      super
    end

    # Get the count of matching documents in the database for the context.
    #
    # @example Get the count without skip and limit taken into consideration.
    #   context.count
    #
    # @example Get the count with skip and limit applied.
    #   context.count(true)
    #
    # @param [Boolean] extras True to inclued previous skip/limit
    #   statements in the count; false to ignore them. Defaults to `false`.
    #
    # @return [ Integer ] The count of documents.
    def count(extras = false)
      if extras
        self.total
      else
        super()
      end
    end

    def in_batches(limit=1000)
      skip = 0
      objects = self.limit(limit).skip(skip*limit)
      while objects.count(true) > 0
        yield objects
        skip+=1
        objects = self.limit(limit).skip(skip*limit)
      end
    end

    def method_missing(name, *args, &block)
      if klass.respond_to?(name)
        klass.send(:with_scope, self) do
          klass.send(name, *args, &block)
        end
      else
        super
      end
    end

  protected

    def clear_cache
      @documents, @cached, @response, @total, @docs, @document_ids = [], false
    end

    def parse_response
      execute if @response.blank?
      self.total = @response["response"]["numFound"]
      self.docs = @response["response"]["docs"]
      self.document_ids = self.docs.map {|e| e["id"]}
    rescue
      clear_cache
      raise CriteriaError, t('failed_query')
    end

    def add_restriction(*args, &block)
      clear_cache
      options = args.extract_options!
      operator = options[:operator] || "AND"
      restriction = args.first
      separator = @selector.present? ? " #{operator} " : ""
      if block_given?
        @selector << "#{separator}("
        yield
        @selector << ")"
      else
        @selector << "#{separator unless @selector[-1] == '('}(#{restriction})"
      end
    end

    def add_sort_option(*args)
      clear_cache
      args.each do |s|
        if options[:sort].present?
          options[:sort] << ", #{s}"
        else
          options[:sort] = s
        end
      end
    end

    def to_lucene_pair(conditions, options = {})
      operator = options[:operator] || "AND"
      if operator == "BETWEEN"
        conditions.map do |k,v|
          case v
          when Range, Array
            "#{k}:#{options[:exclusive] ? '{' : '['}#{v.first} TO #{v.last}#{options[:exclusive] ? '}' : ']'}"
          when String
            "#{k}: #{v}"
          end
        end.join(" AND ")
      else
        conditions.map {|k,v| "#{k}:#{v}"}.join(" #{operator} ")
      end
    end
  end
end
