module RailsConsoleAi
  module SessionsHelper
    def estimated_cost(session)
      pricing = Configuration::PRICING[session.model]
      return nil unless pricing

      (session.input_tokens * pricing[:input]) + (session.output_tokens * pricing[:output])
    end

    def format_cost(session)
      cost = estimated_cost(session)
      return '-' unless cost

      cost < 0.01 ? "<$0.01" : "$#{'%.2f' % cost}"
    end

    # Convert ANSI escape codes to HTML spans for terminal-style rendering
    def ansi_to_html(text)
      return '' if text.nil? || text.empty?

      color_map = {
        '30' => '#000', '31' => '#e74c3c', '32' => '#2ecc71', '33' => '#f39c12',
        '34' => '#3498db', '35' => '#9b59b6', '36' => '#1abc9c', '37' => '#ecf0f1',
        '90' => '#888', '91' => '#ff6b6b', '92' => '#69db7c', '93' => '#ffd43b',
        '94' => '#74c0fc', '95' => '#da77f2', '96' => '#63e6be', '97' => '#fff'
      }

      escaped = h(text).to_str

      # Process ANSI codes: colors, bold, dim, reset
      escaped.gsub!(/\e\[([0-9;]+)m/) do
        codes = $1.split(';')
        if codes.include?('0') || $1 == '0'
          '</span>'
        else
          styles = []
          codes.each do |code|
            case code
            when '1' then styles << 'font-weight:bold'
            when '2' then styles << 'opacity:0.6'
            when '4' then styles << 'text-decoration:underline'
            else
              styles << "color:#{color_map[code]}" if color_map[code]
            end
          end
          styles.empty? ? '' : "<span style=\"#{styles.join(';')}\">"
        end
      end

      # Clean up any remaining escape sequences
      escaped.gsub!(/\e\[[0-9;]*[A-Za-z]/, '')

      escaped.html_safe
    end
  end
end
