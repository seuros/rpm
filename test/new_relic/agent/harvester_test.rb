# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require File.expand_path(File.join(File.dirname(__FILE__),'..','..','test_helper'))
require 'new_relic/agent/harvester'

module NewRelic
  module Agent
    class HarvesterTest < Test::Unit::TestCase

      attr_reader :harvester
      def setup
        @after_forker = stub_everything
        @harvester = Harvester.new(nil, @after_forker)
      end

      def test_marks_started_in_process
        pretend_started_in_another_process

        with_config(:restart_thread_in_children => true) do
          harvester.on_transaction
        end

        assert_false harvester.needs_restart?
      end

      def test_skips_out_early_if_already_started
        harvester.mark_started
        ::Mutex.any_instance.expects(:synchronize).never

        with_config(:restart_thread_in_children => true) do
          harvester.on_transaction
        end
      end

      def test_doesnt_call_to_restart_by_default
        pretend_started_in_another_process
        @after_forker.expects(:after_fork).never

        harvester.on_transaction
      end

      def test_doesnt_call_to_restart_if_explicitly_disabled
        pretend_started_in_another_process
        @after_forker.expects(:after_fork).never

        with_config(:restart_thread_in_children => false) do
          harvester.on_transaction
        end
      end

      def test_calls_to_restart
        pretend_started_in_another_process
        @after_forker.expects(:after_fork).once

        with_config(:restart_thread_in_children => true) do
          harvester.on_transaction
        end
      end

      def test_calls_to_restart_only_once
        pretend_started_in_another_process
        @after_forker.expects(:after_fork).once

        with_config(:restart_thread_in_children => true) do
          threads = []
          100.times do
            threads << Thread.new do
              harvester.on_transaction
            end
          end

          threads.each do |thread|
            thread.join
          end
        end
      end

      def pretend_started_in_another_process
        harvester.mark_started(Process.pid - 1)
      end
    end
  end
end
