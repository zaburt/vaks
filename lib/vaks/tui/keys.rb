module Vaks
  module TUI
    # Turns raw terminal bytes into key names: printable characters as themselves, everything
    # else as a name ("up", "enter", "esc", "ctrl+c", ...).
    module Keys
      CSI = {
        "A" => "up", "B" => "down", "C" => "right", "D" => "left", "H" => "home", "F" => "end",
        "1~" => "home", "4~" => "end", "3~" => "delete", "5~" => "pgup", "6~" => "pgdn", "Z" => "shift+tab"
      }.freeze

      CONTROL = {
        "\r" => "enter", "\n" => "enter", "\t" => "tab", "\x7f" => "backspace", "\b" => "backspace",
        "\u0003" => "ctrl+c", "\u0015" => "ctrl+u", "\u0001" => "ctrl+a", "\u0005" => "ctrl+e",
        "\u0017" => "ctrl+w", "\u0013" => "ctrl+s", "\f" => "ctrl+l"
      }.freeze

      module_function

      # A chunk that is exactly ESC is the Escape key; ESC followed by more bytes is a sequence.
      def parse(bytes)
        keys = []
        s = bytes.dup.force_encoding(Encoding::UTF_8).scrub("")
        until s.empty?
          if s.start_with?("\e")
            if (m = s.match(/\A\e[\[O]([0-9;]*)([A-Za-z~])/))
              keys << (CSI[m[1] + m[2]] || CSI[m[2]] || "unknown")
              s = m.post_match
            elsif s == "\e"
              keys << "esc"
              s = ""
            else
              s = s[1..]
            end
            next
          end
          ch = s[0]
          s = s[1..]
          keys << (CONTROL[ch] || (ch.ord < 32 ? "ctrl" : ch))
        end
        keys
      end
    end
  end
end
