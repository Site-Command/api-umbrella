require "active_record"

class LogSearchSql
  attr_accessor :query, :query_options
  attr_reader :client, :start_time, :end_time, :interval, :region, :country, :state, :result_processors

  CASE_SENSITIVE_FIELDS = [
    "api_key",
    "request_ip_country",
    "request_ip_region",
    "request_ip_city",
  ]

  LEGACY_FIELDS = {
    "request_scheme" => "request_url_scheme",
    "request_host" => "request_url_host",
    "request_path" => "request_url_path",
    "response_time" => "timer_response",
    "backend_response_time" => "timer_backend_response",
    "internal_gatekeeper_time" => "timer_internal",
    "proxy_overhead" => "timer_proxy_overhead",
    "gatekeeper_denied_code" => "denied_reason",
    "imported" => "log_imported",
  }

  FIELD_TYPES = {
    "response_status" => :int,
  }

  def initialize(options = {})
    @sequel = Sequel.connect("mock://postgresql")

    @client = Elasticsearch::Client.new({
      :hosts => ApiUmbrellaConfig[:elasticsearch][:hosts],
      :logger => Rails.logger
    })

    @start_time = options[:start_time]
    unless(@start_time.kind_of?(Time))
      @start_time = Time.zone.parse(@start_time)
    end

    @end_time = options[:end_time]
    unless(@end_time.kind_of?(Time))
      @end_time = Time.zone.parse(@end_time).end_of_day
    end

    if(@end_time > Time.zone.now)
      @end_time = Time.zone.now
    end

    @interval = options[:interval]
    case(@interval)
    when "minute"
      raise "TODO"
    when "hour"
      @interval_field = "CAST(request_at_date AS CHAR(10)) || '-' || CAST(request_at_hour AS CHAR(2))"
      @interval_field_format = "%Y-%m-%d-%H"
    when "day"
      @interval_field = "request_at_date"
      @interval_field_format = "%Y-%m-%d"
    when "week"
      raise "TODO"
    when "month"
      @interval_field = "CAST(request_at_year AS CHAR(4)) || '-' || CAST(request_at_month AS CHAR(2))"
      @interval_field_format = "%Y-%m"
    end

    @region = options[:region]

    @query = {
      :select => [],
      :where => [],
      :group_by => [],
      :order_by => [],
    }

    @query_results = {}

    @query_options = {
      :size => 0,
      :ignore_unavailable => "missing",
      :allow_no_indices => true,
    }

    @result_processors = []
  end

  def execute_query(query_name, query = {})
    unless @query_results[query_name]
      select = @query[:select] + (query[:select] || [])
      sql = "SELECT #{select.join(", ")} FROM api_umbrella.logs"

      where = @query[:where] + (query[:where] || [])
      if(where.present?)
        sql << " WHERE #{where.map { |clause| "(#{clause})" }.join(" AND ")}"
      end

      group_by = @query[:group_by] + (query[:group_by] || [])
      if(group_by.present?)
        sql << " GROUP BY #{group_by.join(", ")}"
      end

      order_by = @query[:order_by] + (query[:order_by] || [])
      if(order_by.present?)
        sql << " ORDER BY #{order_by.join(", ")}"
      end

      conn = Faraday.new(:url => "http://kylin.host") do |faraday|
        faraday.response :logger
        faraday.adapter Faraday.default_adapter
        faraday.basic_auth "ADMIN", "KYLIN"
      end

      Rails.logger.info(sql)
      response = conn.post do |req|
        req.url "/kylin/api/query"
        req.headers["Content-Type"] = "application/json"
        req.body = MultiJson.dump({
          :acceptPartial => false,
          :project => "api_umbrella",
          :sql => sql,
        })
      end

      if(response.status != 200)
        Rails.logger.error(response.body)
        raise "Error"
      end

      @query_results[query_name] = MultiJson.load(response.body)
    end

    @query_results[query_name]
  end

  def result
    if(@query_results.empty?)
      execute_query(:default)
    end

    @result = LogResultSql.new(self, @query_results)
  end

  def permission_scope!(scopes)
    filter = {
      :bool => {
        :should => []
      },
    }

    scopes.each do |scope|
      filter[:bool][:should] << scope
    end

    @query[:query][:filtered][:filter][:bool][:must] << filter
  end

  def search_type!(search_type)
    @query_options[:search_type] = search_type
  end

  def search!(query_string)
    if(query_string.present?)
      @query[:query][:filtered][:query] = {
        :query_string => {
          :query => query_string
        },
      }
    end
  end

  def query!(query)
    if(query.kind_of?(String) && query.present?)
      query = MultiJson.load(query)
    end

    if(query.present?)
      filters = []
      query["rules"].each do |rule|
        filter = {}

        field = rule["field"]
        if(LEGACY_FIELDS[field])
          field = LEGACY_FIELDS[field]
        end

        filter = nil
        operator = nil
        value = rule["value"]

        if(!CASE_SENSITIVE_FIELDS.include?(rule["field"]) && value.kind_of?(String))
          value.downcase!
        end

        if(value.present?)
          case(FIELD_TYPES[field])
          when :int
            value = Integer(value)
          when :double
            value = Float(value)
          end
        end

        case(field)
        when "request_method"
          value.upcase!
        end

        case(rule["operator"])
        when "equal"
          operator = "="
        when "not_equal"
          operator = "<>"
        when "begins_with"
          operator = "LIKE"
          value = "#{value}%"
        when "not_begins_with"
          operator = "NOT LIKE"
          value = "#{value}%"
        when "contains"
          operator = "LIKE"
          value = "%#{value}%"
        when "not_contains"
          operator = "NOT LIKE"
          value = "%#{value}%"
        when "is_null"
          operator = "IS NULL"
          value = nil
        when "is_not_null"
          operator = "IS NOT NULL"
          value = nil
        when "less"
          operator = "<"
        when "less_or_equal"
          operator = "<="
        when "greater"
          operator = ">"
        when "greater_or_equal"
          operator = ">="
        when "between"
          values = rule["value"].map { |v| v.to_f }.sort
          filter = "#{@sequel.quote_identifier(field)} >= #{@sequel.literal(values[0])} AND #{@sequel.quote_identifier(field)} <= #{@sequel.literal(values[1])}"
        else
          raise "unknown filter operator: #{rule["operator"]} (rule: #{rule.inspect})"
        end

        unless(filter)
          filter = "#{@sequel.quote_identifier(field)} #{operator}"
          unless(value.nil?)
            filter << " #{@sequel.literal(value)}"
          end
        end

        filters << filter
      end

      if(filters.present?)
        where = filters.map { |where| "(#{where})" }
        if(query["condition"] == "OR")
          @query[:where] << where.join(" OR ")
        else
          @query[:where] << where.join(" AND ")
        end
      end
    end
  end

  def offset!(from)
    @query_options[:from] = from
  end

  def limit!(size)
    @query_options[:size] = size
  end

  def sort!(sort)
    @query[:sort] = sort
  end

  def exclude_imported!
    @query[:query][:filtered][:filter][:bool][:must_not] << {
      :exists => {
        :field => "imported",
      },
    }
  end

  def filter_by_date_range!
    @query[:where] << @sequel.literal(Sequel.lit("request_at_date >= :start_time_date AND request_at_date <= :end_time_date", {
      :start_time_date => @start_time.strftime("%Y-%m-%d"),
      :end_time_date => @end_time.strftime("%Y-%m-%d"),
    }))
  end

  def filter_by_request_path!(request_path)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :request_path => request_path,
      },
    }
  end

  def filter_by_api_key!(api_key)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :api_key => api_key,
      },
    }
  end

  def filter_by_user!(user_email)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :user => {
          :user_email => user_email,
        },
      },
    }
  end

  def filter_by_user_ids!(user_ids)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :terms => {
        :user_id => user_ids,
      },
    }
  end

  def aggregate_by_drilldown!(prefix, size = 0)
    @drilldown_prefix_segments = prefix.split("/")
    @drilldown_depth = @drilldown_prefix_segments[0].to_i

    # Define the hierarchy of fields that will be involved in this query given
    # the depth.
    @drilldown_fields = ["request_url_host"]
    (1..@drilldown_depth).each do |i|
      @drilldown_fields << "request_url_path_level#{i}"
    end
    @drilldown_depth_field = @drilldown_fields.last

    # Define common parts of the query for all drilldown queries.
    @drilldown_common_query = {
      :select => ["COUNT(*) AS hits"],
      :where => [],
      :group_by => [],
    }
    @drilldown_fields.each_with_index do |field, index|
      # If we're grouping by the top-level of the hierarchy (the hostname), we
      # need to perform some custom logic to determine whether the hostname has
      # any children data.
      #
      # For all the request_url_path_level* fields, we store the value with a
      # trailing slash if there's further parts of the hierarchy. This gives us
      # an easy way to determine whether the specific level is the terminating
      # level of the hierarchy. In other words, this gives us a way to
      # distinguish traffic ending in /foo versus /foo/bar (where /foo is a
      # parent level). Since the host field doesn't follow this convention, we
      # must emulate it here by looking at the level1 path to see if it's NULL
      # or NOT NULL, and append the appropriate slash.
      if(@drilldown_depth == 0)
        @drilldown_common_query[:select] << "request_url_host || CASE WHEN request_url_path_level1 IS NULL THEN '' ELSE '/' END AS request_url_host"
        @drilldown_common_query[:group_by] << "request_url_host, CASE WHEN request_url_path_level1 IS NULL THEN '' ELSE '/' END"
      else
        @drilldown_common_query[:select] << field
        @drilldown_common_query[:group_by] << field
      end
      @drilldown_common_query[:where] << "#{field} IS NOT NULL"

      # Match all the parts of the host and path that are part of the prefix.
      prefix_match_value = @drilldown_prefix_segments[index + 1]
      if prefix_match_value
        # Since we're only interested in matching the parent values, all of the
        # request_url_path_level* fields should have trailing slashes (since
        # that denotes that there's child data). request_url_path_level1 should
        # also have a slash prefix (since it's the beginning of the path).
        if(index == 1)
          prefix_match_value = "/#{prefix_match_value}/"
        elsif(index > 1)
          prefix_match_value = "#{prefix_match_value}/"
        end
        @drilldown_common_query[:where] << @sequel.literal(Sequel.lit("#{field} = ?", prefix_match_value))
      end
    end

    execute_query(:drilldown, {
      :select => @drilldown_common_query[:select],
      :where => @drilldown_common_query[:where],
      :group_by => @drilldown_common_query[:group_by],
      :order_by => ["hits DESC"],
    })

    # Massage the query into the aggregation format matching our old
    # elasticsearch queries.
    @result_processors << Proc.new do |result|
      buckets = []
      column_indexes = result.column_indexes(:drilldown)
      result.raw_result[:drilldown]["results"].each do |row|
        buckets << {
          "key" => build_drilldown_prefix_from_result(row, column_indexes),
          "doc_count" => row[column_indexes["hits"]].to_i,
        }
      end

      result.raw_result["aggregations"] ||= {}
      result.raw_result["aggregations"]["drilldown"] ||= {}
      result.raw_result["aggregations"]["drilldown"]["buckets"] = buckets
    end
  end

  def aggregate_by_drilldown_over_time!(prefix)
    # Grab the top 10 paths out of the query previously done inside
    # #aggregate_by_drilldown!
    #
    # A sub-query would probably be more efficient, but I'm still experiencing
    # this error in Kylin 1.2: https://issues.apache.org/jira/browse/KYLIN-814
    top_paths = []
    top_path_indexes = {}
    column_indexes = result.column_indexes(:drilldown)
    @query_results[:drilldown]["results"][0,10].each_with_index do |row, index|
      value = row[column_indexes[@drilldown_depth_field]]
      top_path_indexes[value] = index
      if(@drilldown_depth == 0)
        value = value.chomp("/")
      end
      top_paths << value
    end

    # Get a date-based breakdown of the traffic to the top 10 paths.
    execute_query(:top_path_hits_over_time, {
      :select => @drilldown_common_query[:select] + ["#{@interval_field} AS interval_field"],
      :where => @drilldown_common_query[:where] + [
        @sequel.literal(Sequel.lit("#{@drilldown_depth_field} IN ?", top_paths)),
      ],
      :group_by => @drilldown_common_query[:group_by] + [@interval_field],
      :order_by => ["interval_field"],
    })

    # Get a date-based breakdown of the traffic to all paths. This is used to
    # come up with how much to allocate to the "Other" category (by subtracting
    # away the top 10 traffic). This probably isn't the best way to go about
    # this in SQL-land, but this is how we did things in ElasticSearch, so for
    # now, keep with that same approach.
    #
    # Since we want a sum of all the traffic, we need to remove the last level
    # of group by and selects (since that would give us per-path breakdowns,
    # and we only want totals).
    all_drilldown_select = @drilldown_common_query[:select][0..-2]
    all_drilldown_group_by = @drilldown_common_query[:group_by][0..-2]
    execute_query(:hits_over_time, {
      :select => all_drilldown_select + ["#{@interval_field} AS interval_field"],
      :where => @drilldown_common_query[:where],
      :group_by => all_drilldown_group_by + [@interval_field],
      :order_by => ["interval_field"],
    })

    # Massage the top_path_hits_over_time query into the aggregation format
    # matching our old elasticsearch queries.
    @result_processors << Proc.new do |result|
      buckets = []
      column_indexes = result.column_indexes(:top_path_hits_over_time)
      result.raw_result[:top_path_hits_over_time]["results"].each do |row|
        # Store the hierarchy breakdown in the order of overall traffic (so the
        # path with the most traffic is always at the bottom of the graph).
        path_index = top_path_indexes[row[column_indexes[@drilldown_depth_field]]]
        unless buckets[path_index]
          buckets[path_index] = {
            "key" => build_drilldown_prefix_from_result(row, column_indexes),
            "doc_count" => 0,
            "drilldown_over_time" => {
              "time_buckets" => {},
            },
          }
        end

        hits = row[column_indexes["hits"]].to_i
        time = Time.strptime(row[column_indexes["interval_field"]], @interval_field_format)

        buckets[path_index]["doc_count"] += hits
        buckets[path_index]["drilldown_over_time"]["time_buckets"][time.to_i] = {
          "key" => time.to_i * 1000,
          "key_as_string" => time.utc.iso8601,
          "doc_count" => hits,
        }
      end

      buckets.each do |bucket|
        bucket["drilldown_over_time"]["buckets"] = fill_in_time_buckets(bucket["drilldown_over_time"].delete("time_buckets"))
      end

      result.raw_result["aggregations"] ||= {}
      result.raw_result["aggregations"]["top_path_hits_over_time"] ||= {}
      result.raw_result["aggregations"]["top_path_hits_over_time"]["buckets"] = buckets
    end

    # Massage the hits_over_time query into the aggregation format matching our
    # old elasticsearch queries.
    @result_processors << Proc.new do |result|
      time_buckets = {}
      column_indexes = result.column_indexes(:hits_over_time)
      result.raw_result[:hits_over_time]["results"].each do |row|
        time = Time.strptime(row[column_indexes["interval_field"]], @interval_field_format)
        time_buckets[time.to_i] = {
          "key" => time.to_i * 1000,
          "key_as_string" => time.utc.iso8601,
          "doc_count" => row[column_indexes["hits"]].to_i,
        }
      end

      result.raw_result["aggregations"] ||= {}
      result.raw_result["aggregations"]["hits_over_time"] ||= {}
      result.raw_result["aggregations"]["hits_over_time"]["buckets"] = fill_in_time_buckets(time_buckets)
    end
  end

  def aggregate_by_interval!
    @query[:aggregations][:hits_over_time] = {
      :date_histogram => {
        :field => "request_at",
        :interval => @interval,
        :time_zone => Time.zone.name,
        :pre_zone_adjust_large_interval => true,
        :min_doc_count => 0,
        :extended_bounds => {
          :min => @start_time.iso8601,
          :max => @end_time.iso8601,
        },
      },
    }
  end

  def aggregate_by_region!
    case(@region)
    when "world"
      aggregate_by_country!
    when "US"
      @country = @region
      aggregate_by_country_regions!(@region)
    when /^(US)-([A-Z]{2})$/
      @country = Regexp.last_match[1]
      @state = Regexp.last_match[2]
      aggregate_by_us_state_cities!(@country, @state)
    else
      @country = @region
      aggregate_by_country_cities!(@region)
    end
  end

  def aggregate_by_region_field!(field)
    @query[:aggregations][:regions] = {
      :terms => {
        :field => field.to_s,
        :size => 500,
      },
    }

    @query[:aggregations][:missing_regions] = {
      :missing => {
        :field => field.to_s,
      },
    }
  end

  def aggregate_by_country!
    aggregate_by_region_field!(:request_ip_country)
  end

  def aggregate_by_country_regions!(country)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }

    aggregate_by_region_field!(:request_ip_region)
  end

  def aggregate_by_us_state_cities!(country, state)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_region => state },
    }

    aggregate_by_region_field!(:request_ip_city)
  end

  def aggregate_by_country_cities!(country)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }

    aggregate_by_region_field!(:request_ip_city)
  end

  def aggregate_by_term!(field, size)
    @query[:aggregations]["top_#{field.to_s.pluralize}"] = {
      :terms => {
        :field => field.to_s,
        :size => size,
        :shard_size => size * 4,
      },
    }

    @query[:aggregations]["value_count_#{field.to_s.pluralize}"] = {
      :value_count => {
        :field => field.to_s,
      },
    }

    @query[:aggregations]["missing_#{field.to_s.pluralize}"] = {
      :missing => {
        :field => field.to_s,
      },
    }
  end

  def aggregate_by_cardinality!(field)
    @query[:aggregations]["unique_#{field.to_s.pluralize}"] = {
      :cardinality => {
        :field => field.to_s,
        :precision_threshold => 100,
      },
    }
  end

  def aggregate_by_users!(size)
    aggregate_by_term!(:user_email, size)
    aggregate_by_cardinality!(:user_email)
  end

  def aggregate_by_request_ip!(size)
    aggregate_by_term!(:request_ip, size)
    aggregate_by_cardinality!(:request_ip)
  end

  def aggregate_by_user_stats!(options = {})
    @query[:select] << "COUNT(*) AS hits"
    @query[:select] << "MAX(request_at) AS last_request_at"
    @query[:select] << "user_id"
    @query[:group_by] << "user_id"

    if(options[:order])
      if(options[:order]["_count"] == "asc")
        @query[:order_by] << "hits ASC"
      elsif(options[:order]["_count"] == "desc")
        @query[:order_by] << "hits DESC"
      elsif(options[:order]["last_request_at"] == "asc")
        @query[:order_by] << "last_request_at ASC"
      elsif(options[:order]["last_request_at"] == "desc")
        @query[:order_by] << "last_request_at DESC"
      end
    end

    @result_processors << Proc.new do |result|
      buckets = []
      column_indexes = result.column_indexes(:default)
      result.raw_result[:default]["results"].each do |row|
        last_request_at = Time.at(row[column_indexes["last_request_at"]].to_i / 1000.0)
        buckets << {
          "key" => row[column_indexes["user_id"]],
          "doc_count" => row[column_indexes["hits"]].to_i,
          "last_request_at" => {
            "value" => row[column_indexes["last_request_at"]].to_f,
            "value_as_string" => Time.at(row[column_indexes["last_request_at"]].to_i / 1000.0).iso8601,
          },
        }
      end

      result.raw_result["aggregations"] ||= {}
      result.raw_result["aggregations"]["user_stats"] ||= {}
      result.raw_result["aggregations"]["user_stats"]["buckets"] = buckets
    end
  end

  def aggregate_by_response_time_average!
    @query[:select] << "AVG(timer_response)"
  end

  private

  def indexes
    unless @indexes
      date_range = @start_time.utc.to_date..@end_time.utc.to_date
      @indexes = date_range.map { |date| "api-umbrella-logs-#{date.strftime("%Y-%m")}" }
      @indexes.uniq!
    end

    @indexes
  end

  def fill_in_time_buckets(time_buckets)
    time = @start_time
    case @interval
    when "minute"
      time = time.change(:sec => 0)
    else
      time = time.send(:"beginning_of_#{@interval}")
    end

    buckets = []
    while(time <= @end_time)
      time_bucket = time_buckets[time.to_i]
      unless time_bucket
        time_bucket = {
          "key" => time.to_i * 1000,
          "key_as_string" => time.utc.iso8601,
          "doc_count" => 0,
        }
      end

      buckets << time_bucket

      time += 1.send(:"#{@interval}")
    end

    buckets
  end

  def build_drilldown_prefix_from_result(row, column_indexes)
    key = [@drilldown_depth.to_s]
    @drilldown_fields.each do |field|
      key << row[column_indexes[field]]
    end
    File.join(key)
  end
end
