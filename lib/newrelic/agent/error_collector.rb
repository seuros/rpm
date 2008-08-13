require 'newrelic/agent/synchronize'
require 'newrelic/noticed_error'
require 'logger'

module NewRelic::Agent
  class ErrorCollector
    include Synchronize
    
    MAX_ERROR_QUEUE_LENGTH = 20 unless defined? MAX_ERROR_QUEUE_LENGTH
    
    def initialize(agent = nil)
      @agent = agent
      @errors = []
      @ignore = {}
      @ignore_block = nil
    end
    
    
    def should_ignore_error(&block)
      @ignore_block = block
    end
    
    
    # errors is an array of String exceptions
    #
    def ignore(errors)
      errors.each { |error| @ignore[error] = true }
    end
   
    
    def notice_error(path, params, exception)
      
      return if @ignore[exception.class.name] || (@ignore_block && @ignore_block.call(exception))
      
      @@error_stat ||= NewRelic::Agent.get_stats("Errors/all")
      
      @@error_stat.increment_count
      
      synchronize do
        if @errors.length >= MAX_ERROR_QUEUE_LENGTH
          log.info("Not reporting error (queue exceeded maximum length): #{exception.message}")
        else
          @errors << NoticedError.new(path, params, exception)
        end
      end
    end
    
    def harvest_errors(unsent_errors)
      synchronize do
        errors = (unsent_errors || []) + @errors
        @errors = []
        return errors
      end
    end
    
  private
    def log 
      return @agent.log if @agent && @agent.log
      
      @backup_log ||= Logger.new(STDERR)
    end
  end
end