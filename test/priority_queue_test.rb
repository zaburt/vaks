require_relative "test_helper"

class PriorityQueueTest < Minitest::Test
  def test_higher_priority_first_then_fifo
    q = Vaks::PriorityQueue.new
    q.push("a", priority: 0)
    q.push("b", priority: 5)
    q.push("c", priority: 0)
    assert_equal %w[b a c], 3.times.map { q.pop(true) }
  end

  def test_reorder_moves_listed_items_first
    q = Vaks::PriorityQueue.new
    %w[a b c d].each { |i| q.push(i) }
    q.reorder!(%w[c a])
    assert_equal %w[c a b d], q.snapshot
  end

  def test_delete_if
    q = Vaks::PriorityQueue.new
    %w[a b c].each { |i| q.push(i) }
    assert q.delete_if { |i| i == "b" }
    assert_equal %w[a c], q.snapshot
  end
end
