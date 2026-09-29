# frozen_string_literal: true

# Day 3: the agent evaluation layer. Loaded by `rake eval:agent` on top of
# eval/harness.rb; nothing in the correctness harness depends on it.
%w[expected grader claude_runner markdown experiment].each { |f| require File.join(__dir__, f) }
