module Vaks
  module TUI
    # A modal list of text fields (the watch add/edit form).
    class Form
      Field = Struct.new(:key, :label, :value, :hint, :original, keyword_init: true)

      attr_reader :title, :fields, :index
      attr_accessor :error

      def initialize(title:, fields:)
        @title  = title
        @fields = fields
        @index  = 0
        @error  = nil
      end

      def current = @fields[@index]

      # Returns :submit or :cancel when the form is finished, nil otherwise.
      def handle(key)
        @error = nil
        case key
        when "esc", "ctrl+c" then return :cancel
        when "ctrl+s" then return :submit
        when "enter"
          return :submit if @index == @fields.length - 1
          @index += 1
        when "down", "tab" then @index = (@index + 1) % @fields.length
        when "up", "shift+tab" then @index = (@index - 1) % @fields.length
        when "backspace" then current.value = current.value.chop
        when "ctrl+u" then current.value = +""
        when "ctrl+w" then current.value = current.value.sub(/\S*\s*\z/, "")
        else
          current.value = current.value + key if key.length == 1 && key.ord >= 32
        end
        nil
      end

      # Fields whose value differs from what the form was opened with, as key => value
      # (nil when the user emptied a field that had a value).
      def changes
        @fields.each_with_object({}) do |f, h|
          next if f.value == f.original.to_s
          h[f.key] = f.value.strip.empty? ? nil : f.value.strip
        end
      end
    end
  end
end
