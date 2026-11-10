#!/usr/bin/env ruby

require "fileutils"

module ReleaseNotes
  class Error < StandardError; end

  VERSION = /\A\d+\.\d+\.\d+\z/
  DATE = /\A\d{4}-\d{2}-\d{2}\z/
  RELEASE_HEADING = /\A## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\s*\z/
  UNRELEASED_HEADING = /\A## \[Unreleased\]\s*\z/
  OPS_HEADING = /\A### Ops\s*\z/
  SECTIONS = { "### Changes" => :changes, "### Ops" => :ops }.freeze
  NOT_FRAGMENTS = ["README.md", ".DS_Store"].freeze
  UNRELEASED_COMMENT =
    "<!-- Don't add notes here: add a file to changelog.d/ (see changelog.d/README.md). -->"
  USAGE = <<~TEXT.freeze
    usage:
      release_notes.rb extract <changelog> <version> <output>
      release_notes.rb notes <changelog> <fragments-dir>
      release_notes.rb pending <changelog> <fragments-dir>
      release_notes.rb promote <changelog> <fragments-dir> <version> <YYYY-MM-DD>
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
      # Ops notes are for whoever ships the release, not for the update dialog.
      ops = ((index + 1)...boundary).find { |candidate| OPS_HEADING.match?(lines[candidate]) } || boundary
      matches << lines[(index + 1)...ops].join.strip
    end

    raise Error, "release #{version} is missing from the changelog" if matches.empty?
    raise Error, "release #{version} appears more than once in the changelog" if matches.length > 1
    raise Error, "release #{version} has no notes" if matches.first.empty?

    matches.first
  end

  # Parses notes in the changelog.d/README.md format. Bullets before any heading
  # are Changes, as under [Unreleased] before changelog.d/ existed. Every line must
  # be blank, a heading, a "- " bullet or its indented continuation, or a one-line
  # <!-- comment -->; anything else is an error, so no note is silently dropped.
  def self.parse_notes(text, source, first_line = 1)
    notes = { changes: [], ops: [] }
    section = :changes
    bullet = nil
    text.lines.each_with_index do |raw, index|
      line = raw.rstrip
      stripped = line.strip
      if stripped.empty? || (stripped.start_with?("<!--") && stripped.index("-->") == stripped.length - 3)
        bullet = nil
      elsif SECTIONS.key?(line)
        section = SECTIONS[line]
        bullet = nil
      elsif line.start_with?("- ") && !line[2..].strip.empty?
        bullet = [line]
        notes[section] << bullet
      elsif bullet && line.start_with?(" ") && !stripped.start_with?("#")
        bullet << line
      else
        raise Error, "#{source}:#{first_line + index}: expected ### Changes, ### Ops, " \
                     "a \"- \" bullet, or a <!-- comment -->, got #{stripped.inspect}"
      end
    end
    notes.transform_values { |bullets| bullets.map { |lines| lines.join("\n") } }
  end

  # Gathers the bullets still under [Unreleased], then each fragment's, in order.
  # `fragments` maps a fragment's path to its contents.
  def self.collect(changelog, fragments)
    lines = changelog.lines
    start = lines.index { |line| UNRELEASED_HEADING.match?(line) }
    raise Error, "the changelog has no [Unreleased] section" unless start

    boundary = section_end(lines, start)
    if boundary < lines.length && !RELEASE_HEADING.match?(lines[boundary])
      raise Error, "CHANGELOG.md:#{boundary + 1}: [Unreleased] must be followed by a ## [X.Y.Z] - YYYY-MM-DD " \
                   "heading, got #{lines[boundary].strip.inspect}"
    end
    notes = parse_notes(lines[(start + 1)...boundary].join, "CHANGELOG.md", start + 2)
    fragments.each do |path, text|
      fragment = parse_notes(text, path)
      raise Error, "#{path}:1: has no notes; delete it if the change needs none" if fragment.values.all?(&:empty?)

      notes.each_key { |section| notes[section].concat(fragment[section]) }
    end
    notes
  end

  # Whether promote has ### Changes notes to release. Ops-only notes wait for one.
  def self.pending?(changelog, fragments)
    !collect(changelog, fragments)[:changes].empty?
  end

  def self.render(notes)
    sections = []
    sections << notes[:changes].join("\n") unless notes[:changes].empty?
    sections << "### Ops\n\n#{notes[:ops].join("\n")}" unless notes[:ops].empty?
    sections.join("\n\n")
  end

  # Moves the notes under [Unreleased] and in changelog.d/ into a new release
  # heading, leaving [Unreleased] with only a pointer to changelog.d/.
  def self.promote(changelog, version, date, fragments = {})
    raise Error, "version must be semantic version X.Y.Z" unless VERSION.match?(version)
    raise Error, "date must be YYYY-MM-DD" unless DATE.match?(date)

    lines = changelog.lines
    if lines.any? { |line| RELEASE_HEADING.match(line)&.[](1) == version }
      raise Error, "release #{version} is already in the changelog"
    end

    notes = collect(changelog, fragments)
    raise Error, "there are no ### Changes notes to show in the update dialog" if notes[:changes].empty?

    start = lines.index { |line| UNRELEASED_HEADING.match?(line) }
    rest = lines[section_end(lines, start)..].join
    promoted = "## [Unreleased]\n\n#{UNRELEASED_COMMENT}\n\n## [#{version}] - #{date}\n\n#{render(notes)}\n"
    lines[0...start].join + promoted + (rest.empty? ? "" : "\n#{rest}")
  end

  def self.section_end(lines, start)
    ((start + 1)...lines.length).find { |index| lines[index].start_with?("## ") } || lines.length
  end

  # Every note file in the directory, sorted, never its README. Any other file is
  # an error rather than a note that would be skipped.
  def self.read_fragments(directory)
    (Dir.children(directory) - NOT_FRAGMENTS).sort.to_h do |name|
      path = File.join(directory, name)
      raise Error, "#{path}: changelog.d/ holds only .md note files" unless name.end_with?(".md") && File.file?(path)

      [path, File.read(path)]
    end
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
    when "notes"
      raise Error, USAGE unless arguments.length == 2

      changelog_path, fragments_dir = arguments
      notes = render(collect(File.read(changelog_path), read_fragments(fragments_dir)))
      puts notes unless notes.empty?
    when "pending"
      raise Error, USAGE unless arguments.length == 2

      changelog_path, fragments_dir = arguments
      puts pending?(File.read(changelog_path), read_fragments(fragments_dir))
    when "promote"
      raise Error, USAGE unless arguments.length == 4

      changelog_path, fragments_dir, version, date = arguments
      fragments = read_fragments(fragments_dir)
      File.write(changelog_path, promote(File.read(changelog_path), version, date, fragments))
      File.delete(*fragments.keys)
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
