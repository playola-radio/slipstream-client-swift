require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

class PrepareReleaseTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BUNDLE_ENV = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }.freeze
  COPIED = %w[.gitignore project.yml fastlane/Fastfile packaging/release_notes.rb packaging/prepare-release.sh].freeze

  CHANGELOG = <<~MARKDOWN
    # Changelog

    ## [Unreleased]

    <!-- Don't add notes here: add a file to changelog.d/ (see changelog.d/README.md). -->

    ## [0.4.0] - 2026-11-10

    - Earlier work.
  MARKDOWN

  def setup
    @directory = Dir.mktmpdir
    @origin = File.join(@directory, "origin.git")
    @work = File.join(@directory, "work")
    git(@directory, "init", "--quiet", "--bare", "--initial-branch=develop", @origin)
    git(@directory, "clone", "--quiet", @origin, @work)
    configure(@work)
    COPIED.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@work, path)))
      FileUtils.cp(File.join(ROOT, path), File.join(@work, path))
    end
    project = File.join(@work, "project.yml")
    File.write(project, File.read(project)
      .sub(/MARKETING_VERSION: "[^"]*"/, 'MARKETING_VERSION: "0.4.0"')
      .sub(/CURRENT_PROJECT_VERSION: "\d+"/, 'CURRENT_PROJECT_VERSION: "4"'))
    File.write(File.join(@work, "CHANGELOG.md"), CHANGELOG)
    FileUtils.mkdir_p(File.join(@work, "changelog.d"))
    File.write(File.join(@work, "changelog.d/README.md"), "# Not a note\n")
    commit(@work, "chore: bump to 0.4.0 (4)")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_publishes_nothing_when_released_and_no_notes_wait
    tag("v0.4.0-b4")

    outputs, = prepare

    assert_equal({ "release" => "false" }, outputs)
  end

  def test_bumps_the_patch_and_pushes_it_when_notes_wait
    tag("v0.4.0-b4")
    add_note("fix.md", "### Changes\n\n- Fixed.\n")

    outputs, = prepare

    assert_equal "true", outputs["release"]
    assert_equal git(@origin, "rev-parse", "develop").strip, outputs["sha"]
    project = File.read(File.join(@work, "project.yml"))
    assert_match(/MARKETING_VERSION: "0\.4\.1"/, project)
    assert_match(/CURRENT_PROJECT_VERSION: "5"/, project)
    assert_equal ["README.md"], Dir.children(File.join(@work, "changelog.d"))
  end

  def test_publishes_an_unreleased_version_as_it_is
    add_note("later.md", "### Changes\n\n- Later.\n")

    outputs, = prepare

    assert_equal({ "release" => "true", "sha" => head(@work) }, outputs)
    assert_match(/MARKETING_VERSION: "0\.4\.0"/, File.read(File.join(@work, "project.yml")))
  end

  def test_leaves_the_release_to_a_newer_merge
    tag("v0.4.0-b4")
    add_note("fix.md", "### Changes\n\n- Fixed.\n")
    other = File.join(@directory, "other")
    git(@directory, "clone", "--quiet", @origin, other)
    configure(other)
    File.write(File.join(other, "newer.txt"), "newer\n")
    commit(other, "feature: newer merge")

    outputs, = prepare

    assert_equal({ "release" => "false" }, outputs)
    assert_equal head(other), git(@origin, "rev-parse", "develop").strip
  end

  def test_fails_on_a_malformed_note
    tag("v0.4.0-b4")
    add_note("bad.md", "Not a bullet.\n")

    outputs, stderr, status = prepare(expect_success: false)

    refute status.success?
    assert_empty outputs
    assert_match(/bad\.md:1/, stderr)
  end

  private

  def prepare(expect_success: true)
    output = File.join(@directory, "github-output")
    File.write(output, "")
    _stdout, stderr, status = Open3.capture3(
      BUNDLE_ENV.merge("GITHUB_OUTPUT" => output), "packaging/prepare-release.sh", chdir: @work
    )
    assert status.success?, stderr if expect_success
    [File.read(output).lines.to_h { |line| line.chomp.split("=", 2) }, stderr, status]
  end

  def add_note(name, text)
    File.write(File.join(@work, "changelog.d", name), text)
    commit(@work, "feature: #{name}")
  end

  def tag(name)
    git(@work, "tag", name)
    git(@work, "push", "--quiet", "origin", "refs/tags/#{name}")
  end

  def configure(directory)
    git(directory, "config", "user.name", "Release Test")
    git(directory, "config", "user.email", "release-test@example.com")
    git(directory, "config", "commit.gpgSign", "false")
    git(directory, "config", "tag.gpgSign", "false")
  end

  def commit(directory, message)
    git(directory, "add", ".")
    git(directory, "commit", "--quiet", "-m", message)
    git(directory, "push", "--quiet", "origin", "HEAD:develop")
  end

  def head(directory)
    git(directory, "rev-parse", "HEAD").strip
  end

  def git(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    assert status.success?, stderr
    stdout
  end
end
