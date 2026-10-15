# Convert an OCR'd book PDF's text into CB-Essay chapter files.
#
# usage:
#   pdftotext -enc UTF-8 book.pdf book.txt
#   pdftotext -enc UTF-8 -layout book.pdf book-layout.txt
#   ruby scripts/convert-ocr.rb scripts/ocr-configs/<book>.yml book.txt book-layout.txt out_dir
#
# Book-specific settings (chapter pages, running header, OCR fixes, structure rules) live in the
# YAML config; see scripts/ocr-configs/in-nez-perce-country.yml for a documented example.
# Writes one .md file per chapter to out_dir, plus joins.txt (log of rejoined split words) beside out_dir.
# Output still needs a manual review pass before copying into _essay/.
require 'fileutils'
require 'yaml'

abort "usage: ruby #{$0} config.yml book.txt book-layout.txt out_dir" unless ARGV.size == 4
CONFIG_FILE, SRC, LAYOUT, OUT = ARGV
CONFIG = YAML.safe_load(File.read(CONFIG_FILE, encoding: 'UTF-8'))
pages = File.read(SRC, encoding: 'UTF-8').split("\f")
layout_pages = File.read(LAYOUT, encoding: 'UTF-8').split("\f")

# running header text as it appears in the OCR, e.g. "In Nez Perce Co\s*un\s*try"
RUNNING_HEADER = Regexp.new(CONFIG.fetch('running_header'))

DATE_LINE = /\A\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/
WEEKDAY = /\A(?:\d{1,2}\s+)?(?:Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b/

# Pages where raw extraction gives one line per printed line instead of one per paragraph
def line_mode?(raw)
  ls = raw.lines.map(&:strip).reject(&:empty?)
  ls.size > 15 && ls.count { |l| l.length < 110 }.to_f / ls.size > 0.7
end

# Rebuild paragraphs from layout text using first-line indentation
def layout_paragraphs(text)
  ls = text.lines.map(&:rstrip).reject { |l| l.strip.empty? }
  return [] if ls.empty?
  min = ls.map { |l| l[/\A */].size }.min
  ls.each_with_object([]) do |l, acc|
    s = l.strip.gsub(/ {2,}/, ' ')
    starts = acc.empty? || l[/\A */].size >= min + 3 || s =~ WEEKDAY || s =~ /\A\d{1,2}["“]?[A-Z]/ || s =~ RUNNING_HEADER
    if starts then acc << s else acc[-1] = acc[-1] + ' ' + s end
  end
end
FileUtils.mkdir_p(OUT)

CHAPTERS = CONFIG.fetch('chapters')
END_PAGE = CONFIG.fetch('end_page')
SKIP_PAGES = CONFIG.fetch('skip_pages', [])

# running header with an optional page number and separator glyph on either side
HEADER = /(?:^|\A)\s*(?:[\dIlOo ]{1,5}\s*[•·■�]\s*)?(?:#{RUNNING_HEADER.source})(?:\s*[•·■�]\s*[\dIlOo ]{1,6}(?=\s|$))?\s*/

TEXT_FIXES = CONFIG.fetch('text_fixes', []).map { |f| [Regexp.new(f.fetch('find')), f.fetch('replace')] }
SECTIONS = CONFIG['quoted_sections']
SECTION_RE = SECTIONS && Regexp.new(SECTIONS.fetch('pattern'))
SOURCE_RE = SECTIONS && SECTIONS['source_label'] && /\s*#{Regexp.escape(SECTIONS['source_label'])}\s*/
READING_LIST_RE = CONFIG['reading_list_pattern'] && Regexp.new(CONFIG['reading_list_pattern'])

def garbage?(line)
  return true if line =~ /^Figure \d+\./
  return true if line =~ /^[-\s]+$/
  words = line.scan(/[A-Za-z]{3,}/)
  words.empty? && line !~ /^\d{1,3}$/
end

VOCAB = Hash.new(0)
File.read(SRC, encoding: 'UTF-8').scan(/[A-Za-z]+/) { |w| VOCAB[w.downcase] += 1 }
JOINS = Hash.new(0)
SHORT_WORDS = %w[a i o]

# rejoin words the OCR split in two ("enteri ng", "T hey")
def rejoin_split_words(s)
  toks = s.split(' ', -1)
  out = []
  toks.each do |t|
    prev = out.last
    if prev && prev =~ /\A["“(\[]?([A-Za-z]+)\z/ && t =~ /\A([a-z]+)([^A-Za-z]*)\z/
      b = Regexp.last_match(1)
      a = prev[/[A-Za-z]+\z/]
      joined = (a + b).downcase
      frag = ->(w) { VOCAB[w.downcase] < 3 && !SHORT_WORDS.include?(w.downcase) }
      ok = VOCAB[joined] >= 2 && a.downcase != 'of' && !SHORT_WORDS.include?(a.downcase) && !KEEP_APART.include?(joined) &&
           (frag.(a) || frag.(b) || VOCAB[joined] >= 5 * [VOCAB[a.downcase], VOCAB[b.downcase]].min)
      if ok
        JOINS[[a, b]] += 1
        out[-1] = prev + t
        next
      end
    end
    out << t
  end
  out.join(' ')
end
KEEP_APART = CONFIG.fetch('keep_apart', []).map(&:downcase)

OF_KEEP = /\A(of|off|offs|offer\w*|offic\w*|offend\w*|offens\w*|offspring\w*|offset\w*|offal|offhand\w*|offing|often\w*|oft|ofttimes)\z/i
def fix_text(s)
  s = s.dup
  s.gsub!(/­/, '')
  s.gsub!(/[■�]/, '')
  TEXT_FIXES.each { |re, rep| s.gsub!(re, rep) }
  s.gsub!(/\b(of|the|and|to|in|on|at|by|for|from|with)(?=[A-Z][a-z])/) { "#{$1} " }
  s.gsub!(/\bof([a-z]+)\b/) { w, rest = $&, $1; w.match?(OF_KEEP) ? w : "of #{rest}" }
  s.gsub!(/\b[Il](?=\d)/, '1')
  s.gsub!(/(?<=\d)[Il](?=\d)/, '1')
  s.gsub!(/\b(\d+) ?s[1t]\b/) { "#{$1}st" }
  s.gsub!(/ {2,}/, ' ')
  s.gsub!(/ ([,;:.])(?= |$)/) { $1 } # "word , next" -> "word, next"
  s = rejoin_split_words(s)
  s
end

def md_escape(s)
  s = s.gsub('<', '&lt;').gsub('](', ']\\(').gsub('{{', '{ {').gsub('{%', '{ %')
  s = s.sub(/\A(\s*)([*+#>-])(\s)/, '\1\\\\\2\3')
  s.sub(/\A(\d+)\.(\s)/, '\1\\.\2')
end

def def_start_re(n)
  n == 1 ? /\A(?:1|['‘’`])\s?(?=["“'‘(\[]?[A-Z])/ : /\A#{n}\s?(?=["“'‘(\[]?[A-Z])/
end

def ref_patterns(n)
  pats = [
    /(?<=[A-Za-z.,;:!?"”'’)\]])#{n}(?=\s|$|[;,.)])/,
    /(?<=[.,;:!?"”'’)\]]) #{n}(?=\s+["“]?[A-Z]|\s*$)/,
    /(?<=\s)#{n}(?=[A-Z][a-z])/,
  ]
  pats << /(?<=[,.]["”])['’](?=\s)/ if n == 1 # superscript 1 read as an apostrophe
  pats
end

# Index of the line where the footnote block for note n starts, or nil
def find_region(lines, prior, n)
  (1...lines.size).find do |i|
    l = lines[i]
    next false if l !~ def_start_re(n) && !(n == 1 && l =~ /\A['‘’`][A-Z]/)
    next false if l =~ WEEKDAY || l =~ DATE_LINE
    ref_patterns(n).any? { |re| (prior + lines[0...i]).join("\n") =~ re } ||
      lines[i + 1].to_s =~ def_start_re(n + 1) ||
      (n == 1 && l =~ /\A['‘’`][A-Z]/) ||
      # reference superscript lost in OCR: accept a citation-like numbered line at the page foot
      (i >= lines.size - 2 && l =~ /\(.*\d{4}.*\)|\b(?:Ibid|See)\b/)
  end
end

def split_notes(text, start_n)
  notes = {}
  n = start_n
  rest = text.sub(def_start_re(n), '')
  loop do
    idx = nil
    nxt = nil
    [n + 1, n + 2].each do |cand|
      rest.to_enum(:scan, /(?<=[\s.)\]"”;])#{cand}(?=\s?["“'‘(\[]?[A-Z])/).each do
        m = Regexp.last_match
        before = rest[0...m.begin(0)]
        next if before =~ /(?:Vol\.|no\.|No\.|Part|pp?\.|Chapter|Series,?|Number|Box|Folder)\s*\z/
        idx = m; break
      end
      if idx then nxt = cand; break end
    end
    if idx
      notes[n] = rest[0...idx.begin(0)].strip
      rest = rest[idx.end(0)..].lstrip
      n = nxt
    else
      notes[n] = rest.strip
      break
    end
  end
  notes
end

log = []
# 'per_chapter' (notes restart at 1 each chapter) or 'continuous' (numbered through the whole book)
CONTINUOUS_NOTES = CONFIG.fetch('footnote_numbering', 'per_chapter') == 'continuous'
book_next_note = 1
CHAPTERS.each_with_index do |ch, ci|
  title, first, slug = ch.fetch('title'), ch.fetch('page'), ch.fetch('slug')
  last = ci + 1 < CHAPTERS.size ? CHAPTERS[ci + 1].fetch('page') - 1 : END_PAGE
  body_pages = []
  notes = {}
  next_def = CONTINUOUS_NOTES ? book_next_note : 1
  (first..last).each do |pno|
    next if SKIP_PAGES.include?(pno)
    lines = line_mode?(pages[pno - 1]) ? layout_paragraphs(layout_pages[pno - 1]) : pages[pno - 1].lines.map(&:strip)
    if pno == first
      lines.shift while lines.any? && lines[0].empty?
      lines.shift # chapter number glyph
      lines.shift while lines.any? && (lines[0].empty? || (lines[0].length < 100 && lines[0] !~ /[.?!"”]\z/))
    else
      2.times do |k|
        next unless lines[k] && lines[k] =~ RUNNING_HEADER
        lines[k] = lines[k].sub(HEADER, '')
      end
    end
    lines.reject!(&:empty?)
    lines.reject! { |l| garbage?(l) }
    # merge lone footnote-number lines with the following line
    lines = lines.each_with_object([]) do |l, acc|
      if acc.last && acc.last =~ /\A\d{1,3}\z/ && l =~ /\A["“(\[]?[A-Z]/ then acc[-1] = acc.last + l else acc << l end
    end
    lines.reject! { |l| l =~ /\A\d{1,3}\z/ }
    # footnote region: a numbered line counts only if its reference appears in the text above it
    prior = body_pages.flatten.last(40)
    fi = nil
    # tolerate a note or two whose number was garbled by OCR
    [next_def, next_def + 1, next_def + 2].each do |cand|
      fi = find_region(lines, prior, cand)
      if fi then next_def = cand; break end
    end
    if fi
      found = split_notes(lines[fi..].join(' '), next_def)
      notes.merge!(found)
      next_def = found.keys.max + 1
      lines = lines[0...fi]
    end
    body_pages << lines
  end

  # join pages: continue a paragraph that runs over a page break
  paras = []
  body_pages.each do |lines|
    lines.each_with_index do |l, i|
      cont = paras.any? && (l =~ /\A[a-z(]/ || l =~ /\A\d{4}\)?:/ || (i == 0 && paras.last !~ /[.?!"”:)\]]\z/))
      if cont then paras[-1] = paras[-1] + ' ' + l else paras << l end
    end
  end
  text = paras.map { |p| fix_text(p) }

  # anchor footnote references, in order
  joined = text.join("\n")
  pos = 0
  unanchored = []
  notes.keys.sort.each do |n|
    pats = ref_patterns(n)
    best = pats.map { |re| joined.index(re, pos) && [joined.index(re, pos), re] }.compact.min_by(&:first)
    if best
      m = joined.match(best[1], best[0])
      rep = "[^#{n}]"
      rep += ' ' if joined[m.end(0)] =~ /[A-Za-z]/
      joined = joined[0...m.begin(0)] + rep + joined[m.end(0)..]
      pos = m.begin(0) + rep.length
    else
      log << "#{slug}: no reference found for note #{n}"
      unanchored << n
    end
  end
  joined.gsub!(/ (\[\^\d+\])/) { $1 }
  text = joined.split("\n")

  # structure: quoted sections (e.g. primary-source accounts), further-reading lists
  out = []
  mode = nil
  text.each do |p|
    if SECTION_RE && p =~ SECTION_RE
      head, rest = $1, $2
      desc, source = SOURCE_RE ? rest.split(SOURCE_RE, 2) : [rest, nil]
      out << "{% include essay/new-section.html %}" << "### #{head}" << "*#{md_escape(desc.to_s.strip)}*"
      out << "**#{SECTIONS['source_label'].chomp(':')}:** #{md_escape(source.strip)}" if source
      mode = :quote
    elsif READING_LIST_RE && p =~ READING_LIST_RE
      out << "#### #{$1}"
      out << "- #{md_escape($2.strip)}" unless $2.strip.empty?
      mode = :list
    elsif mode == :list && p.length < 450 && p =~ /\(.*\d{4}.*\)|\d{4}\)?[.,]/
      out << "- #{md_escape(p)}"
    else
      mode = nil if mode == :list
      out << (mode == :quote ? "> #{md_escape(p)}" : md_escape(p))
    end
  end

  # defaults follow list position: 01-slug.md, order 10, "Chapter 1"
  pos_n = ci + 1
  order = ch.fetch('order', pos_n * 10)
  part = ch.fetch('part', "Chapter #{pos_n}")
  fname = format("%02d-%s.md", pos_n, slug)
  fm = "---\ntitle: \"#{title.gsub('"', '\"')}\"\norder: #{order}\npart: #{part}\n---\n\n"
  foot = (notes.keys.sort - unanchored).map { |n| "[^#{n}]: #{md_escape(fix_text(notes[n]))}" }
  unless unanchored.empty?
    out << "#### Notes"
    unanchored.each { |n| out << "<!-- OCR lost the reference mark for this note -->\n**#{n}.** #{md_escape(fix_text(notes[n]))}" }
  end
  body = out.join("\n\n").gsub(/\n\n(?=> )/) { |m| m } # keep blank line between quote paragraphs
  File.write(File.join(OUT, fname), fm + body + "\n" + (foot.empty? ? "" : "\n" + foot.join("\n\n") + "\n"))
  book_next_note = notes.keys.max + 1 if notes.any?
  log << "#{fname}: #{text.size} paras, #{notes.size} notes (#{notes.keys.minmax.join('-')})"
end
puts log
File.write(File.join(File.dirname(OUT), 'joins.txt'), JOINS.sort_by { |k, v| -v }.map { |(a, b), v| "#{v}\t#{a} #{b}" }.join("\n"))
