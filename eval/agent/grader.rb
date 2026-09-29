# frozen_string_literal: true

require "json"

module Eval
  module Agent
    # Deterministic grading of one agent run. There is no model in the loop:
    #
    # - The answer is the last {"answer": ...} JSON object in the final
    #   message. The prompt asks for one. If there isn't one, the run is
    #   `no_answer`. Prose is never parsed for numbers, because guessing which
    #   number in a paragraph was "the answer" would make the grader a judge.
    # - Correctness compares that value with the oracle's by the question's
    #   answer type (see questions.yml for tolerances).
    # - Tool selection: at least one call to a tool listed for the question.
    # - Argument correctness: at least one such call satisfies the question's
    #   rule in ARG_RULES below, fixed before any run.
    class Grader
      MONEY_TOLERANCE = 0.001 # relative
      SCORE_TOLERANCE = 0.01
      PERCENT_TOLERANCE = 0.1

      LAST_DAY = "2018-10-17" # last purchase date in the dataset

      # One rule per question. `calls` are [tool_name, arguments] pairs from
      # the run; a rule passes if any call satisfies it.
      ARG_RULES = {
        "A01-orders-placed" => lambda { |c, _|
          c.any? { |t, a| t == "search_orders" && (a.keys - %w[limit sort]).empty? }
        },
        "A02-cancelled-2018" => lambda { |c, _|
          c.any? do |t, a|
            t == "search_orders" && a["status"] == "canceled" && a["from"] == "2018-01-01" &&
              (a["to"].nil? || a["to"] >= LAST_DAY)
          end
        },
        "A03-revenue-nov-2017" => lambda { |c, _|
          c.any? do |t, a|
            t == "revenue_report" && [nil, "month"].include?(a["group_by"]) &&
              (a["from"].nil? || a["from"] <= "2017-11-01") && (a["to"].nil? || a["to"] >= "2017-11-30")
          end
        },
        "A04-top-category" => lambda { |c, _|
          c.any? do |t, a|
            (t == "revenue_report" && a["group_by"] == "category" && a["from"].nil? && a["to"].nil?) ||
              (t == "list_categories" && [nil, "revenue"].include?(a["sort"]))
          end
        },
        "A05-health-beauty-merchandise" => lambda { |c, _|
          c.any? do |t, a|
            t == "list_categories" ||
              (t == "revenue_report" && a["group_by"] == "category" && a["from"].nil? && a["to"].nil?)
          end
        },
        "A06-top-seller" => lambda { |c, _|
          c.any? do |t, a|
            (t == "seller_performance" && [nil, "revenue"].include?(a["sort"]) && a["state"].nil?) ||
              (t == "revenue_report" && a["group_by"] == "seller" && a["from"].nil? && a["to"].nil?)
          end
        },
        "A07-credit-card-2018" => lambda { |c, _|
          c.any? do |t, a|
            t == "revenue_report" && a["group_by"] == "payment_method" && a["from"] == "2018-01-01" &&
              (a["to"].nil? || a["to"] >= LAST_DAY)
          end
        },
        "A08-very-late-review" => lambda { |c, _|
          c.any? { |t, a| t == "delivery_performance" && [nil, "bucket"].include?(a["group_by"]) && a["from"].nil? && a["to"].nil? }
        },
        "A09-late-rate" => lambda { |c, _|
          c.any? { |t, a| t == "delivery_performance" && [nil, "bucket"].include?(a["group_by"]) && a["from"].nil? && a["to"].nil? }
        },
        "A10-worst-state-reviews" => lambda { |c, _|
          c.any? { |t, a| t == "delivery_performance" && a["group_by"] == "state" && a["from"].nil? && a["to"].nil? }
        },
        "A11-customer-lifetime-value" => lambda { |c, picked|
          c.any? { |t, a| t == "find_customer" && a["email"].to_s.strip.casecmp?("#{picked[:unique_id]}@olist.invalid") }
        },
        "A12-order-review-score" => lambda { |c, picked|
          c.any? { |t, a| t == "get_order" && a["order_number"].to_s.strip == picked[:number] }
        },
        "A13-product-units" => lambda { |c, picked|
          c.any? do |t, a|
            (t == "get_product" && a["sku"].to_s.strip == picked[:sku]) ||
              (t == "search_products" && a["query"].to_s.strip.casecmp?(picked[:sku]))
          end
        },
        "A14-worst-seller" => lambda { |c, _|
          c.any? { |t, a| t == "seller_performance" && a["sort"] == "avg_review" && a["min_orders"].to_i == 100 }
        },
        "A15-big-sao-paulo-orders" => lambda { |c, _|
          c.any? do |t, a|
            t == "search_orders" && a["customer_state"].to_s.upcase == "SP" && a["min_total"].to_f == 1000.0
          end
        }
      }.freeze

      # The value of the last {"answer": ...} object in the text, or nil.
      def self.extract(text)
        candidates = text.to_s.scan(/\{[^{}]*"answer"[^{}]*\}/m)
        candidates.reverse_each do |raw|
          parsed = JSON.parse(raw)
          return parsed["answer"] if parsed.key?("answer")
        rescue JSON::ParserError
          next
        end
        nil
      end

      def initialize(question, expected:, alternates:, picked:)
        @q = question
        @expected = expected
        @alternates = alternates
        @picked = picked
      end

      def grade(run)
        calls = run.tool_calls.map { |tc| [tc[:tool], tc[:arguments] || {}] }
        answer = self.class.extract(run.final_text)
        verdict = if answer.nil? then "no_answer"
                  elsif matches?(answer, @expected) then "correct"
                  elsif (alt = @alternates.find { |_, v| matches?(answer, v) }) then "alternate_metric:#{alt.first}"
                  else "wrong"
                  end
        {
          answer: answer, expected: @expected, verdict: verdict, correct: verdict == "correct",
          tool_ok: calls.any? { |t, _| @q.fetch("tools").include?(t) },
          args_ok: ARG_RULES.fetch(@q.fetch("id")).call(calls, @picked),
          tools_called: calls.map(&:first)
        }
      end

      private

      def matches?(answer, expected)
        case @q.fetch("answer")
        when "count", "integer" then (n = number(answer)) && n == expected.to_f && n == n.round
        when "money" then (n = number(answer)) && (n - expected).abs <= [expected.abs * MONEY_TOLERANCE, 0.01].max
        when "score" then (n = number(answer)) && (n - expected).abs <= SCORE_TOLERANCE + 1e-9
        when "percent" then (n = number(answer)) && (n - expected).abs <= PERCENT_TOLERANCE + 1e-9
        when "key" then key_match?(answer, expected)
        else raise ArgumentError, "unknown answer type #{@q['answer']}"
        end
      end

      # Numbers as the model may write them: 1172191.68, "1,172,191.68",
      # "R$ 1.172.191,68", "7.9%". A string with both separators is resolved
      # by whichever comes last being the decimal mark.
      def number(value)
        return value.to_f if value.is_a?(Numeric)
        return nil unless value.is_a?(String)

        s = value.gsub(/[^\d.,\-]/, "")
        return nil if s.empty?

        if s.include?(",") && s.include?(".")
          s = s.rindex(",") > s.rindex(".") ? s.delete(".").tr(",", ".") : s.delete(",")
        elsif s.count(",") == 1 && s.split(",").last.length != 3
          s = s.tr(",", ".")
        elsif s.count(".") > 1
          s = s.delete(".") # "1.172.191": Brazilian thousands separators
        else
          s = s.delete(",")
        end
        Float(s)
      rescue ArgumentError
        nil
      end

      def key_match?(answer, expected)
        a = answer.to_s.strip.downcase
        e = expected.to_s.downcase
        case @q["key"]
        when "seller" then a.length >= 8 && e.start_with?(a.delete("."))
        when "category" then a.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "") == e
        else a == e
        end
      end
    end
  end
end
