module Vaks
  # Thread-safe priority queue. Higher priority integer = dequeued first.
  # Equal-priority items are dequeued FIFO. Supports the same interface as
  # Ruby's stdlib Queue (push/<<, pop, length, empty?) plus non-blocking pop.
  class PriorityQueue
    def initialize
      @items = []   # [[priority, seq, item], ...]  sorted descending by priority, then ascending by seq
      @mutex = Mutex.new
      @cond  = ConditionVariable.new
      @seq   = 0
    end

    def push(item, priority: 0)
      @mutex.synchronize do
        @items << [priority, @seq, item]
        @seq += 1
        @items.sort_by! { |p, s, _| [-p, s] }
        @cond.signal
      end
      self
    end

    def <<(item)
      # :stop tokens drain last so all real jobs finish before workers exit
      pri = item == :stop ? -Float::INFINITY : (item.respond_to?(:priority) ? item.priority : 0)
      push(item, priority: pri)
    end

    # Pop the highest-priority item.
    # Pass true for non-blocking mode (raises ThreadError if empty).
    def pop(non_block = false)
      @mutex.synchronize do
        if non_block
          raise ThreadError, "queue empty" if @items.empty?
        else
          @cond.wait(@mutex) while @items.empty?
        end
        @items.shift[2]
      end
    end

    def length
      @mutex.synchronize { @items.size }
    end

    def empty?
      @mutex.synchronize { @items.empty? }
    end

    # Returns queued items (excluding :stop tokens) in current dequeue order.
    def snapshot
      @mutex.synchronize { @items.reject { |_, _, item| item == :stop }.map { |_, _, item| item } }
    end

    # Removes items matching the block. Returns true if anything was removed.
    def delete_if
      @mutex.synchronize do
        before = @items.length
        @items.reject! { |_, _, item| item != :stop && yield(item) }
        @items.length != before
      end
    end

    # Reorders queued items to match the given list of identifiers (e.g. job paths),
    # where earlier entries in `order` are dequeued first. Items not present in `order`
    # keep their relative position after the reordered ones. `id_for` extracts the
    # comparison key from a queue item (defaults to the item itself).
    def reorder!(order, id_for: ->(item) { item })
      @mutex.synchronize do
        rank = order.each_with_index.to_h
        @items.each do |entry|
          item = entry[2]
          next if item == :stop
          key = id_for.call(item)
          entry[0] = rank.key?(key) ? (order.length - rank[key]) : 0
        end
        @items.sort_by! { |p, s, _| [-p, s] }
        @cond.signal
      end
    end
  end
end
