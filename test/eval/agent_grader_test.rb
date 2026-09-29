# frozen_string_literal: true

require "test_helper"
require Rails.root.join("eval/agent/agent").to_s

# The agent grader decides every Day 3 verdict, so its rules are pinned here:
# where the answer is read from, how numbers written by a model are parsed,
# where each tolerance ends, and when a wrong answer is labelled as a
# different defined metric rather than just wrong.
class AgentGraderTest < ActiveSupport::TestCase
  Run = Struct.new(:tool_calls, :final_text)

  def question(id, answer, tools, key: nil)
    { "id" => id, "answer" => answer, "tools" => tools, "key" => key }.compact
  end

  def grade(q, text, calls: [], expected:, alternates: {}, picked: {})
    Eval::Agent::Grader.new(q, expected: expected, alternates: alternates, picked: picked)
                       .grade(Run.new(calls.map { |t, a| { tool: t, arguments: a } }, text))
  end

  test "the answer is the last answer object in the reply; prose is never mined for numbers" do
    assert_equal 7, Eval::Agent::Grader.extract(%(first {"answer": 3}\nthen {"answer": 7}))
    assert_nil Eval::Agent::Grader.extract("The store received 99,441 orders.")
    assert_nil Eval::Agent::Grader.extract(%({"answer": }))
  end

  test "a reply with no answer object is no_answer, not wrong" do
    g = grade(question("A01-orders-placed", "count", %w[search_orders]), "There are 99,441 orders.", expected: 99_441)
    assert_equal "no_answer", g[:verdict]
  end

  test "money written the way a model writes it is read correctly" do
    q = question("A03-revenue-nov-2017", "money", %w[revenue_report])
    ["1172191.68", "1,172,191.68", "R$ 1.172.191,68", "1.172.191", 1_172_191.68].each do |written|
      assert_equal "correct", grade(q, %({"answer": #{written.is_a?(String) ? %("#{written}") : written}}),
                                    expected: 1_172_191.68)[:verdict], written.inspect
    end
  end

  test "money within 0.1% is right; the item-revenue figure is labelled as the wrong metric" do
    q = question("A03-revenue-nov-2017", "money", %w[revenue_report])
    assert_equal "correct", grade(q, %({"answer": 1172000}), expected: 1_172_191.68)[:verdict]
    assert_equal "wrong", grade(q, %({"answer": 1170000}), expected: 1_172_191.68)[:verdict]
    assert_equal "alternate_metric:item_revenue",
                 grade(q, %({"answer": 1003862.14}), expected: 1_172_191.68,
                                                     alternates: { "item_revenue" => 1_003_862.14 })[:verdict]
  end

  test "counts are exact" do
    q = question("A02-cancelled-2018", "count", %w[search_orders])
    assert grade(q, %({"answer": 334}), expected: 334)[:correct]
    refute grade(q, %({"answer": 335}), expected: 334)[:correct]
  end

  test "a seller may be named by an id prefix of 8+ characters, as tool text truncates ids" do
    q = question("A06-top-seller", "key", %w[seller_performance], key: "seller")
    full = "4869f7a5dfa277a7dca6462dcf3b52b2"
    assert grade(q, %({"answer": "4869f7a5dfa2"}), expected: full)[:correct]
    assert grade(q, %({"answer": "4869f7a5dfa2..."}), expected: full)[:correct]
    refute grade(q, %({"answer": "4869f7"}), expected: full)[:correct]
  end

  test "a category matches however it is capitalised or spaced" do
    q = question("A04-top-category", "key", %w[list_categories], key: "category")
    assert grade(q, %({"answer": "Health Beauty"}), expected: "health_beauty")[:correct]
  end

  test "tool selection needs one call to a listed tool; argument rules are per question" do
    q = question("A02-cancelled-2018", "count", %w[search_orders])
    good = grade(q, %({"answer": 334}), expected: 334,
                                        calls: [["search_orders", { "status" => "canceled", "from" => "2018-01-01", "to" => "2018-12-31" }]])
    assert good[:tool_ok]
    assert good[:args_ok]

    no_year = grade(q, %({"answer": 334}), expected: 334, calls: [["search_orders", { "status" => "canceled" }]])
    assert no_year[:tool_ok]
    refute no_year[:args_ok], "without the year window the count covers every year"

    wrong_tool = grade(q, %({"answer": 334}), expected: 334, calls: [["revenue_report", {}]])
    refute wrong_tool[:tool_ok]
  end

  test "lookups must use the exact identifier from the question" do
    q = question("A11-customer-lifetime-value", "money", %w[find_customer])
    picked = { unique_id: "abc123" }
    assert grade(q, "", expected: 1.0, picked: picked, calls: [["find_customer", { "email" => "ABC123@olist.invalid" }]])[:args_ok]
    refute grade(q, "", expected: 1.0, picked: picked, calls: [["find_customer", { "email" => "abc123" }]])[:args_ok]
  end

  # F12: the server connected but exposed no tools, and the model wrote tool
  # calls as prose. A run like that must be an error, never a graded answer.
  test "a run is an error unless it sees exactly the nine read tools" do
    runner = Eval::Agent::ClaudeRunner.allocate
    connected = { "mcp_servers" => [{ "name" => "store", "status" => "connected" }] }
    all = StoreMcp::READ_TOOLS.map { |t| "mcp__store__#{t.name_value}" }

    assert_nil runner.send(:init_error, connected.merge("tools" => all))
    assert_match "0 of 9", runner.send(:init_error, connected.merge("tools" => []))
    assert_match "missing: search_orders", runner.send(:init_error, connected.merge("tools" => all - ["mcp__store__search_orders"]))
    assert_equal "MCP server not connected", runner.send(:init_error, { "mcp_servers" => [], "tools" => all })
  end

  test "every agent question has an argument rule" do
    ids = YAML.safe_load_file(Rails.root.join("eval/agent/questions.yml")).map { |q| q["id"] }
    assert_equal ids.sort, Eval::Agent::Grader::ARG_RULES.keys.sort
  end
end
