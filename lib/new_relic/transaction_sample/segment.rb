require 'new_relic/transaction_sample'
module NewRelic
  class TransactionSample
    class Segment
      attr_reader :entry_timestamp
      # The exit timestamp will be relative except for the outermost sample which will
      # have a timestamp.
      attr_reader :exit_timestamp
      attr_reader :parent_segment
      attr_reader :metric_name
      attr_reader :segment_id

      def initialize(timestamp, metric_name, segment_id)
        @entry_timestamp = timestamp
        @metric_name = metric_name || '<unknown>'
        @segment_id = segment_id || object_id
      end

      def end_trace(timestamp)
        @exit_timestamp = timestamp
      end

      def add_called_segment(s)
        @called_segments ||= []
        @called_segments << s
        s.parent_segment = self
      end

      def to_s
        to_debug_str(0)
      end

      def to_json
        map = {:entry_timestamp => @entry_timestamp,
          :exit_timestamp => @exit_timestamp,
          :metric_name => @metric_name,
          :segment_id => @segment_id}
        if @called_segments && !@called_segments.empty?
          map[:called_segments] = @called_segments
        end
        if @params && !@params.empty?
          map[:params] = @params
        end
        map.to_json
      end

      def path_string
        "#{metric_name}[#{called_segments.collect {|segment| segment.path_string }.join('')}]"
      end
      def to_s_compact
        str = ""
        str << metric_name
        if called_segments.any?
          str << "{#{called_segments.map { | cs | cs.to_s_compact }.join(",")}}"
        end
        str
      end
      def to_debug_str(depth)
        tab = "  " * depth
        s = tab.clone
        s << ">> #{'%3i ms' % (@entry_timestamp*1000)} [#{self.class.name.split("::").last}] #{metric_name} \n"
        unless params.empty?
          params.each do |k,v|
            s << "#{tab}    -#{'%-16s' % k}: #{v.to_s[0..80]}\n"
          end
        end
        called_segments.each do |cs|
          s << cs.to_debug_str(depth + 1)
        end
        s << tab + "<< "
        s << case @exit_timestamp
             when nil then ' n/a'
             when Numeric then '%3i ms' % (@exit_timestamp*1000)
             else @exit_timestamp.to_s
             end
        s << " #{metric_name}\n"
      end

      def called_segments
        @called_segments || []
      end

      # return the total duration of this segment
      def duration
        (@exit_timestamp - @entry_timestamp).to_f
      end

      # return the duration of this segment without
      # including the time in the called segments
      def exclusive_duration
        d = duration

        if @called_segments
          @called_segments.each do |segment|
            d -= segment.duration
          end
        end
        d
      end
      def count_segments
        count = 1
        @called_segments.each { | seg | count  += seg.count_segments } if @called_segments
        count
      end
      # Walk through the tree and truncate the segments
      def truncate(max)
        return max unless @called_segments
        i = 0
        @called_segments.each do | segment |
          max = segment.truncate(max)
          max -= 1
          if max <= 0
            @called_segments = @called_segments[0..i]
            break
          else
            i += 1
          end
        end
        max
      end

      def []=(key, value)
        # only create a parameters field if a parameter is set; this will save
        # bandwidth etc as most segments have no parameters
        params[key] = value
      end

      def [](key)
        params[key]
      end

      def params
        @params ||= {}
      end

      # call the provided block for this segment and each
      # of the called segments
      def each_segment(&block)
        block.call self

        if @called_segments
          @called_segments.each do |segment|
            segment.each_segment(&block)
          end
        end
      end

      def find_segment(id)
        return self if @segment_id == id
        called_segments.each do |segment|
          found = segment.find_segment(id)
          return found if found
        end
        nil
      end

      # perform this in the runtime environment of a managed application, to explain the sql
      # statement(s) executed within a segment of a transaction sample.
      # returns an array of explanations (which is an array rows consisting of
      # an array of strings for each column returned by the the explain query)
      # Note this happens only for statements whose execution time exceeds a threshold (e.g. 500ms)
      # and only within the slowest transaction in a report period, selected for shipment to RPM
      def explain_sql
        sql = params[:sql]
        return nil unless sql && params[:connection_config]
        statements = sql.split(";\n")
        explanations = []
        statements.each do |statement|
          if statement.split($;, 2)[0].upcase == 'SELECT'
            explain_resultset = []
            begin
              connection = NewRelic::TransactionSample.get_connection(params[:connection_config])
              if connection
                # The resultset type varies for different drivers.  Only thing you can count on is
                # that it implements each.  Also: can't use select_rows because the native postgres
                # driver doesn't know that method.
                explain_resultset = connection.execute("EXPLAIN #{statement}") if connection
                rows = []
                # Note: we can't use map.
                # Note: have to convert from native column element types to string so we can
                # serialize.  Esp. for postgresql.
                # Can't use map.  Suck it up.
                # Can too use map. Lrn2prgm
                if explain_resultset.respond_to?(:each)
                  explain_resultset.extend Enumerable unless explain_resultset.respond_to?(:map)
                  rows = explain_resultset.map { | row | row.map(&:to_s) }
                else
                  rows << [ explain_resultset ]
                end
                explanations << rows
                # sleep for a very short period of time in order to yield to the main thread
                # this is because a remote database call will likely hang the VM
                sleep 0.05
              end
            rescue => e
              handle_exception_in_explain(e)
            end
          end
        end

        explanations
      end

      def params=(p)
        @params = p
      end


      def handle_exception_in_explain(e)
        x = 1 # this is here so that code coverage knows we've entered this block
        # swallow failed attempts to run an explain.  One example of a failure is the
        # connection for the sql statement is to a different db than the default connection
        # specified in AR::Base
      end
      def obfuscated_sql
        TransactionSample.obfuscate_sql(params[:sql])
      end

      def called_segments=(segments)
        @called_segments = segments
      end

      protected
      def parent_segment=(s)
        @parent_segment = s
      end
    end
  end
end