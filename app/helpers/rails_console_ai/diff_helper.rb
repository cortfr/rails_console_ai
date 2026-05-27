require 'erb'
require 'json'

module RailsConsoleAi
  module DiffHelper
    # Render a side-by-side line diff of two strings.
    #
    # Returns HTML-safe markup with <span class="diff-add"> and
    # <span class="diff-del"> rows. Uses a tiny LCS-based algorithm so we
    # avoid taking on the diff-lcs gem as a runtime dependency.
    def render_text_diff(left, right, left_label: 'Before', right_label: 'After')
      a = (left || '').split("\n", -1)
      b = (right || '').split("\n", -1)
      ops = diff_ops(a, b)

      rows = []
      ops.each do |op, l_line, r_line|
        rows << render_diff_row(op, l_line, r_line)
      end

      html = +%(<table class="diff-table">)
      html << %(<thead><tr><th>#{ERB::Util.h(left_label)}</th><th>#{ERB::Util.h(right_label)}</th></tr></thead>)
      html << %(<tbody>) << rows.join << %(</tbody>)
      html << %(</table>)
      html.respond_to?(:html_safe) ? html.html_safe : html
    end

    # Convenience for diffing two tag arrays / hashes as JSON.
    def render_json_diff(left_obj, right_obj, **opts)
      render_text_diff(
        JSON.pretty_generate(left_obj || []),
        JSON.pretty_generate(right_obj || []),
        **opts
      )
    end

    private

    def render_diff_row(op, l_line, r_line)
      l_cell = l_line ? %(<pre>#{ERB::Util.h(l_line)}</pre>) : ''
      r_cell = r_line ? %(<pre>#{ERB::Util.h(r_line)}</pre>) : ''
      case op
      when :equal
        %(<tr><td>#{l_cell}</td><td>#{r_cell}</td></tr>)
      when :del
        %(<tr><td class="diff-del">#{l_cell}</td><td></td></tr>)
      when :add
        %(<tr><td></td><td class="diff-add">#{r_cell}</td></tr>)
      when :change
        %(<tr><td class="diff-del">#{l_cell}</td><td class="diff-add">#{r_cell}</td></tr>)
      end
    end

    # Returns an array of [op, left_line, right_line] tuples using LCS.
    # ops: :equal, :del, :add, :change.
    def diff_ops(a, b)
      lcs = lcs_table(a, b)
      ops = []
      i = a.length
      j = b.length
      while i > 0 && j > 0
        if a[i - 1] == b[j - 1]
          ops.unshift([:equal, a[i - 1], b[j - 1]])
          i -= 1; j -= 1
        elsif lcs[i - 1][j] >= lcs[i][j - 1]
          ops.unshift([:del, a[i - 1], nil])
          i -= 1
        else
          ops.unshift([:add, nil, b[j - 1]])
          j -= 1
        end
      end
      while i > 0
        ops.unshift([:del, a[i - 1], nil])
        i -= 1
      end
      while j > 0
        ops.unshift([:add, nil, b[j - 1]])
        j -= 1
      end
      # Collapse adjacent del+add (or add+del) into a single :change row for readability.
      collapsed = []
      idx = 0
      while idx < ops.length
        cur, nxt = ops[idx], ops[idx + 1]
        if nxt && cur[0] == :del && nxt[0] == :add
          collapsed << [:change, cur[1], nxt[2]]
          idx += 2
        elsif nxt && cur[0] == :add && nxt[0] == :del
          collapsed << [:change, nxt[1], cur[2]]
          idx += 2
        else
          collapsed << cur
          idx += 1
        end
      end
      collapsed
    end

    def lcs_table(a, b)
      table = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
      (1..a.length).each do |i|
        (1..b.length).each do |j|
          table[i][j] = if a[i - 1] == b[j - 1]
                          table[i - 1][j - 1] + 1
                        else
                          [table[i - 1][j], table[i][j - 1]].max
                        end
        end
      end
      table
    end
  end
end
