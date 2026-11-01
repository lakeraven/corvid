# frozen_string_literal: true

require "fileutils"

# Changelog fragments: one file per PR in changelog.d/, assembled under `## [Unreleased]` in
# CHANGELOG.md at release. Each PR adds a uniquely named file, so two PRs never edit the same lines.
#
# A fragment is `<id>.<type>.md`: <id> is the issue or PR number, <type> one of TYPES. The first
# line is the entry's first line (a bullet under `### <Type>`); the rest of the file is the body,
# indented two spaces under that bullet when rendered.
module Fragments
  class Error < StandardError; end

  TYPES = %w[added changed deprecated removed fixed security].freeze
  NAME = /\A(\d+)\.([^.]+)\.md\z/
  UNRELEASED = /^## \[Unreleased\][ \t]*\r?$/
  IGNORED = %w[README.md .keep .gitkeep .DS_Store].freeze

  DEFAULT_DIR = File.expand_path("../changelog.d", __dir__)

  class << self
    # The directory the release guard inspects; settable so a test can point it elsewhere.
    attr_writer :release_dir

    def release_dir
      @release_dir || DEFAULT_DIR
    end
  end

  Fragment = Struct.new(:id, :type, :heading, :body, :path, keyword_init: true)
  Assembly = Struct.new(:text, :files, keyword_init: true)

  module_function

  # Every fragment in dir, validated, in render order (type, then numeric id).
  def load(dir)
    names = Dir.children(dir).reject { |n| IGNORED.include?(n) }
    list = names.map { |n| parse(File.join(dir, n)) }
    list.group_by { |f| [ f.type, f.id ] }.each_value do |same|
      next if same.size == 1

      raise Error, "#{same.map { |f| File.basename(f.path) }.sort.join(' and ')}: both are #{same.first.type} fragments for id #{same.first.id}"
    end
    list.sort_by { |f| [ TYPES.index(f.type), f.id ] }
  end

  def parse(path)
    name = File.basename(path)
    raise Error, "#{name}: not a fragment file (directories are not read)" if File.directory?(path)

    match = NAME.match(name) or raise Error, "#{name}: not named <id>.<type>.md with a numeric id"
    type = match[2]
    raise Error, "#{name}: unknown type #{type.inspect} (expected one of #{TYPES.join(', ')})" unless TYPES.include?(type)

    text = File.read(path, encoding: "UTF-8").gsub("\r\n", "\n")
    raise Error, "#{name}: file is empty" if text.strip.empty?

    heading, body = text.split("\n", 2)
    heading = heading.to_s.chomp("\r").strip
    raise Error, "#{name}: first line must be the heading text, not blank" if heading.empty?

    Fragment.new(id: match[1].to_i, type: type, heading: heading, body: body.to_s, path: path)
  end

  # Validates every fragment in dir (what `rake changelog:check` and the test suite run); returns the count.
  def check(dir)
    self.load(dir).size
  end

  # Names of everything in dir that the release must first fold into CHANGELOG.md.
  def pending(dir)
    Dir.children(dir).reject { |n| IGNORED.include?(n) }.sort
  end

  # One `### <Type>` heading per type, each fragment a bullet whose first line is the heading and whose
  # body continues the bullet indented two spaces, the shape CHANGELOG.md entries already have.
  # Blank body lines stay empty; each fragment ends in exactly one newline.
  def render(fragments)
    ordered = fragments.sort_by { |f| [ TYPES.index(f.type), f.id ] }
    ordered.chunk_while { |a, b| a.type == b.type }.map do |group|
      bullets = group.map do |f|
        lines = [ "- #{f.heading}" ]
        f.body.sub(/\n+\z/, "").split("\n", -1).each { |l| lines << (l.strip.empty? ? "" : "  #{l}") } unless f.body.strip.empty?
        lines.join("\n") + "\n"
      end
      "### #{group.first.type.capitalize}\n#{bullets.join}"
    end.join("\n")
  end

  # Inserts the rendered fragments immediately under `## [Unreleased]`, ahead of existing sections.
  def assemble(changelog_path:, dir:)
    text = File.read(changelog_path, encoding: "UTF-8")
    raise Error, "#{changelog_path}: no `## [Unreleased]` heading to insert under" unless text.match?(UNRELEASED)

    fragments = self.load(dir)
    return Assembly.new(text: text, files: []) if fragments.empty?

    match = UNRELEASED.match(text)
    rest = match.post_match.sub(/\A(?:[ \t]*\r?\n)+/, "")
    block = "#{match.pre_match}#{match[0]}\n\n#{render(fragments).chomp}\n"
    out = rest.empty? ? block : "#{block}\n#{rest}"
    Assembly.new(text: out, files: fragments.map(&:path))
  end

  # deleter and renamer are injectable so a test can simulate a failure at either step.
  # All-or-nothing assembly: afterwards either CHANGELOG.md holds every entry and every consumed
  # fragment is gone, or nothing changed. The new text goes to a temp file beside CHANGELOG.md; the
  # fragments are then deleted with their bytes held in memory; the temp file is renamed into place
  # (atomic). A failure at the write, a delete or the rename restores the fragments and removes the
  # temp file, so a re-run never sees an entry both in CHANGELOG.md and in changelog.d/.
  def apply(changelog_path:, dir:, deleter: File.method(:delete), renamer: File.method(:rename))
    result = assemble(changelog_path: changelog_path, dir: dir)
    return result if result.files.empty?

    temp = "#{changelog_path}.#{Process.pid}.tmp"
    saved = {}
    begin
      File.write(temp, result.text)
      File.chmod(File.stat(changelog_path).mode & 0o7777, temp) # keep the changelog's own permissions
      result.files.each do |path|
        bytes = File.binread(path)
        deleter.call(path)
        saved[path] = bytes
      end
      renamer.call(temp, changelog_path)
    rescue StandardError, ScriptError
      FileUtils.rm_f(temp) # first: a failure while restoring must not leave the temp file behind
      saved.each { |path, bytes| File.binwrite(path, bytes) }
      raise
    end
    result
  end
end
