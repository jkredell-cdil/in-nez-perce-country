# List every page of pdftotext output with its word count and first two lines,
# to help fill in an ocr-configs/*.yml file (chapter start pages, running header,
# image-only pages, end page).
#
# usage: ruby scripts/ocr-pages.rb ocr-work/book.txt > ocr-work/pages.txt
#
# Columns: PDF page number, word count, first two lines of the page.

abort "usage: ruby #{$0} book.txt" unless ARGV.size == 1

File.read(ARGV[0], encoding: 'UTF-8').split("\f").each_with_index do |page, i|
  lines = page.lines.map(&:strip).reject(&:empty?)
  puts "#{i + 1}\t#{page.split.size}w\t#{lines.first(2).join(' | ')[0, 90]}"
end
