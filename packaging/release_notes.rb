#!/usr/bin/env ruby

require "fileutils"

module ReleaseNotes
  class Error < StandardError; end

  VERSION = /\A\d+\.\d+\.\d+\z/
  RELEASE_HEADING = /\A## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\s*\z/
  USAGE = <<~TEXT.freeze
    usage:
      release_notes.rb extract <changelog> <version> <output>
  TEXT

  def self.extract(changelog, version)
    raise Error, "version must be semantic version X.Y.Z" unless VERSION.match?(version)

    lines = changelog.lines
    matches = []
    lines.each_index do |index|
      heading = RELEASE_HEADING.match(lines[index])
      next unless heading && heading[1] == version

      boundary = ((index + 1)...lines.length).find do |candidate|
        lines[candidate].start_with?("## ")
      end || lines.length
      matches << lines[(index + 1)...boundary].join.strip
    end

    raise Error, "release #{version} is missing from the changelog" if matches.empty?
    raise Error, "release #{version} appears more than once in the changelog" if matches.length > 1
    raise Error, "release #{version} has no notes" if matches.first.empty?

    matches.first
  end

  def self.set_description(item, notes)
    raise Error, "release notes are empty" if notes.strip.empty?

    description = item.add_element("description")
    description.add_attribute("sparkle:format", "markdown")
    description.add_text(notes)
    description
  end

  def self.run_cli(arguments)
    command = arguments.shift
    case command
    when "extract"
      raise Error, USAGE unless arguments.length == 3

      changelog_path, version, output_path = arguments
      notes = extract(File.read(changelog_path), version)
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, "#{notes}\n")
    else
      raise Error, USAGE
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ReleaseNotes.run_cli(ARGV.dup)
  rescue ReleaseNotes::Error, SystemCallError => error
    warn "error: #{error.message}"
    exit 1
  end
end
