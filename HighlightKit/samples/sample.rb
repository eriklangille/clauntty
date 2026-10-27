require "json"

# A review's notes, as Claude writes them
class Notes
  PRIORITIES = %w[critical review skim mechanical].freeze

  attr_reader :files

  def initialize(path)
    @files = JSON.parse(File.read(path)).fetch("files", [])
  end

  def critical?
    @files.any? { |f| f["priority"] == :critical.to_s }
  end
end

puts "#{Notes.new("notes.json").files.size} files" if __FILE__ == $0
