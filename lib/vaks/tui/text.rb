module Vaks
  module TUI
    # Display-width aware string helpers and value formatters. Strings may carry SGR colour
    # escapes, which take no screen space.
    module Text
      SGR = /\e\[[0-9;]*m/

      WIDE = [
        0x1100..0x115F, 0x2E80..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFE30..0xFE6F,
        0xFF00..0xFF60, 0xFFE0..0xFFE6, 0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x3FFFD
      ].freeze
      ZERO = [0x0300..0x036F, 0x200B..0x200F, 0xFE00..0xFE0F].freeze

      module_function

      def char_width(ch)
        cp = ch.ord
        return 0 if cp < 32 || ZERO.any? { |r| r.cover?(cp) }
        WIDE.any? { |r| r.cover?(cp) } ? 2 : 1
      end

      def width(str)
        str.gsub(SGR, "").each_char.sum { |c| char_width(c) }
      end

      # Truncates (with an ellipsis) or pads to exactly `cols` columns, keeping escapes intact.
      def fit(str, cols)
        return "" if cols <= 0
        cut   = width(str) > cols
        limit = cut ? cols - 1 : cols
        out   = +""
        used  = 0
        str.scan(/#{SGR}|./m) do |tok|
          if tok.start_with?("\e")
            out << tok
            next
          end
          w = char_width(tok)
          break if used + w > limit
          out << tok
          used += w
        end
        if cut
          out << "…"
          used += 1
        end
        out << "\e[0m" if out.include?("\e")
        out << " " * (cols - used)
      end

      def pad_left(str, cols) = " " * [cols - width(str), 0].max + str

      def style(str, *codes)
        codes.empty? ? str : "\e[#{codes.join(";")}m#{str}\e[0m"
      end

      def duration(seconds)
        return "--:--" unless seconds
        s = seconds.to_i
        h, m = s / 3600, (s % 3600) / 60
        h.positive? ? format("%d:%02d:%02d", h, m, s % 60) : format("%02d:%02d", m, s % 60)
      end

      def ago(epoch, now = Time.now.to_i)
        return "-" unless epoch
        d = [now - epoch.to_i, 0].max
        return "#{d}s ago" if d < 60
        return "#{d / 60}m ago" if d < 3600
        return "#{d / 3600}h ago" if d < 86_400
        "#{d / 86_400}d ago"
      end

      def size(bytes)
        return "-" unless bytes
        units = %w[B KiB MiB GiB TiB]
        value = bytes.to_f
        i = 0
        while value.abs >= 1024 && i < units.length - 1
          value /= 1024
          i += 1
        end
        i.zero? ? "#{bytes.to_i} B" : format("%.1f %s", value, units[i])
      end

      def bar(fraction, cols)
        return "" if cols <= 0
        filled = (fraction.to_f.clamp(0, 1) * cols).round
        "█" * filled + "░" * (cols - filled)
      end

      # ffmpeg reports speed as "1.6x" (media seconds per wall second)
      def parse_speed(speed)
        speed.to_s[/\A\s*([\d.]+)x?/, 1].to_f
      end
    end
  end
end
