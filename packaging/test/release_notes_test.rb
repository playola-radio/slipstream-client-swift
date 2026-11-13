require "minitest/autorun"
require "base64"
require "open3"
require "openssl"
require "rexml/document"
require "rbconfig"
require "tmpdir"
require_relative "../release_notes"

class ReleaseNotesTest < Minitest::Test
  APPCAST_SCRIPT = File.expand_path("../appcast.rb", __dir__)
  SCRIPT = File.expand_path("../release_notes.rb", __dir__)
  # The repo's Gemfile, so bundler also finds gems installed under its local config (CI).
  BUNDLE_ENV = { "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }.freeze

  CHANGELOG = <<~MARKDOWN
    # Changelog

    ## [Unreleased]

    - Work in progress.

    ## [2.0.0] - 2026-09-08

    - Save and reopen `.pie` projects.
    - Review suggestions before export.

    ## [1.9.0] - 2026-08-01

    - Older work.
  MARKDOWN

  def test_extracts_only_the_exact_release_body
    assert_equal <<~MARKDOWN.strip, ReleaseNotes.extract(CHANGELOG, "2.0.0")
      - Save and reopen `.pie` projects.
      - Review suggestions before export.
    MARKDOWN
  end

  def test_rejects_invalid_version
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(CHANGELOG, "v2.0")
    end

    assert_match(/semantic version/, error.message)
  end

  def test_rejects_missing_version
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(CHANGELOG, "3.0.0")
    end

    assert_match(/missing/, error.message)
  end

  def test_rejects_duplicate_version
    duplicate = <<~MARKDOWN
      ## [2.0.0] - 2026-09-08

      - First copy.

      ## [2.0.0] - 2026-09-09

      - Second copy.
    MARKDOWN

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(duplicate, "2.0.0")
    end

    assert_match(/more than once/, error.message)
  end

  def test_rejects_empty_release
    empty = <<~MARKDOWN
      ## [2.0.0] - 2026-09-08

      ## [1.9.0] - 2026-08-01

      - Older work.
    MARKDOWN

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(empty, "2.0.0")
    end

    assert_match(/no notes/, error.message)
  end

  def test_promote_moves_unreleased_notes_under_a_dated_heading
    assert_equal <<~MARKDOWN, ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")
      # Changelog

      ## [Unreleased]

      #{ReleaseNotes::UNRELEASED_COMMENT}

      ## [2.1.0] - 2026-10-01

      - Work in progress.

      ## [2.0.0] - 2026-09-08

      - Save and reopen `.pie` projects.
      - Review suggestions before export.

      ## [1.9.0] - 2026-08-01

      - Older work.
    MARKDOWN
  end

  def test_promoted_notes_are_what_release_extracts
    promoted = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    assert_equal "- Work in progress.", ReleaseNotes.extract(promoted, "2.1.0")
  end

  def test_promote_rejects_empty_unreleased_notes
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.promote(ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01"), "2.2.0", "2026-10-02")
    end

    assert_match(/no ### Changes notes/, error.message)
  end

  def test_promote_puts_unreleased_bullets_ahead_of_fragments_and_keeps_wrapping
    changelog = CHANGELOG.sub("- Work in progress.\n", <<~MARKDOWN)
      ### Changes

      - From a branch opened before changelog.d/, wrapped
        onto a second line.
    MARKDOWN
    fragments = {
      "changelog.d/a.md" => "### Changes\n\n- First fragment.\n\n### Ops\n\n- Add the release secret.\n",
      "changelog.d/b.md" => "<!-- a note to the releaser -->\n### Changes\n\n- Second fragment.\n",
    }

    promoted = ReleaseNotes.promote(changelog, "2.1.0", "2026-10-01", fragments)

    assert_equal <<~MARKDOWN.strip, promoted[/## \[2\.1\.0\].*?(?=\n## \[2\.0\.0\])/m].strip
      ## [2.1.0] - 2026-10-01

      - From a branch opened before changelog.d/, wrapped
        onto a second line.
      - First fragment.
      - Second fragment.

      ### Ops

      - Add the release secret.
    MARKDOWN
  end

  def test_promote_releases_fragments_when_unreleased_is_empty
    changelog = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    promoted = ReleaseNotes.promote(changelog, "2.2.0", "2026-10-02", "changelog.d/a.md" => "### Changes\n\n- New.\n")

    assert_equal "- New.", ReleaseNotes.extract(promoted, "2.2.0")
  end

  def test_extract_leaves_ops_out_of_the_update_notes
    promoted = ReleaseNotes.promote(
      CHANGELOG, "2.1.0", "2026-10-01", "changelog.d/a.md" => "### Ops\n\n- Add the release secret.\n"
    )

    assert_equal "- Work in progress.", ReleaseNotes.extract(promoted, "2.1.0")
  end

  def test_promote_rejects_a_release_with_only_ops_notes
    changelog = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.promote(changelog, "2.2.0", "2026-10-02", "changelog.d/a.md" => "### Ops\n\n- Add the secret.\n")
    end

    assert_match(/no ### Changes notes/, error.message)
  end

  def test_rejects_an_unexpected_line_in_a_fragment_naming_file_and_line
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "### Changes\n\n- Fine.\nStray text.\n")
    end

    assert_match(%r{\Achangelog\.d/a\.md:4: }, error.message)
  end

  def test_rejects_an_unknown_heading
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "### Added\n\n- Something.\n")
    end

    assert_match(%r{\Achangelog\.d/a\.md:1: }, error.message)
  end

  def test_rejects_an_empty_bullet
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "### Changes\n\n- \n")
    end

    assert_match(%r{\Achangelog\.d/a\.md:3: }, error.message)
  end

  def test_rejects_an_indented_line_that_follows_no_bullet
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "### Changes\n\n  not a bullet\n")
    end

    assert_match(%r{\Achangelog\.d/a\.md:3: }, error.message)
  end

  def test_rejects_a_fragment_with_no_notes
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "### Changes\n\n<!-- nothing yet -->\n")
    end

    assert_match(%r{changelog\.d/a\.md:1: has no notes}, error.message)
  end

  def test_rejects_text_between_two_comments
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "- Fine.\n<!-- a --> - Lost. <!-- b -->\n")
    end

    assert_match(%r{\Achangelog\.d/a\.md:2: }, error.message)
  end

  def test_rejects_an_indented_heading_instead_of_continuing_the_bullet
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG, "changelog.d/a.md" => "- Visible.\n  ### Ops\n- Secret step.\n")
    end

    assert_match(%r{\Achangelog\.d/a\.md:2: }, error.message)
  end

  def test_rejects_a_stray_heading_that_would_end_unreleased_early
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG.sub("- Work in progress.\n", "- Work in progress.\n## Changes\n- Hidden.\n"), {})
    end

    assert_match(/\ACHANGELOG\.md:6: /, error.message)
  end

  def test_rejects_a_stray_line_under_unreleased_naming_its_changelog_line
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.collect(CHANGELOG.sub("- Work in progress.", "Work in progress."), {})
    end

    assert_match(/\ACHANGELOG\.md:5: /, error.message)
  end

  def test_promote_rejects_a_version_that_is_already_released
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.promote(CHANGELOG, "2.0.0", "2026-10-01")
    end

    assert_match(/already in the changelog/, error.message)
  end

  def test_promote_rejects_a_changelog_without_an_unreleased_section
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.promote(CHANGELOG.sub("## [Unreleased]\n", ""), "2.1.0", "2026-10-01")
    end

    assert_match(/no \[Unreleased\] section/, error.message)
  end

  def test_promote_rejects_a_malformed_date
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.promote(CHANGELOG, "2.1.0", "Oct 1")
    end

    assert_match(/YYYY-MM-DD/, error.message)
  end

  def test_promote_cli_rolls_fragments_into_the_changelog_and_deletes_only_them
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, CHANGELOG)
      File.write(File.join(fragments, "README.md"), "# Not a note\n")
      File.write(File.join(fragments, "new.md"), "### Changes\n\n- New.\n")

      _stdout, stderr, status = run_cli("promote", changelog, fragments, "2.1.0", "2026-10-01")

      assert status.success?, stderr
      assert_equal "- Work in progress.\n- New.", ReleaseNotes.extract(File.read(changelog), "2.1.0")
      assert_equal ["README.md"], Dir.children(fragments)
    end
  end

  def test_promote_cli_changes_nothing_when_a_fragment_is_malformed
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, CHANGELOG)
      File.write(File.join(fragments, "good.md"), "### Changes\n\n- Good.\n")
      File.write(File.join(fragments, "bad.md"), "Not a bullet.\n")

      _stdout, stderr, status = run_cli("promote", changelog, fragments, "2.1.0", "2026-10-01")

      refute status.success?
      assert_match(%r{bad\.md:1: }, stderr)
      assert_equal CHANGELOG, File.read(changelog)
      assert_equal ["bad.md", "good.md"], Dir.children(fragments).sort
    end
  end

  def test_promote_cli_rejects_a_file_that_is_not_a_markdown_note
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, CHANGELOG)
      File.write(File.join(fragments, "note.txt"), "- New.\n")

      _stdout, stderr, status = run_cli("promote", changelog, fragments, "2.1.0", "2026-10-01")

      refute status.success?
      assert_match(/note\.txt/, stderr)
      assert_equal CHANGELOG, File.read(changelog)
    end
  end

  def test_notes_cli_prints_what_promote_would_release
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, CHANGELOG)
      File.write(File.join(fragments, "new.md"), "### Changes\n\n- New.\n")

      stdout, stderr, status = run_cli("notes", changelog, fragments)

      assert status.success?, stderr
      assert_equal "- Work in progress.\n- New.\n", stdout
    end
  end

  def test_pending_when_a_fragment_has_changes
    changelog = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    assert ReleaseNotes.pending?(changelog, "changelog.d/a.md" => "### Changes\n\n- New.\n")
  end

  def test_pending_when_unreleased_still_has_bullets
    assert ReleaseNotes.pending?(CHANGELOG, {})
  end

  def test_not_pending_with_only_ops_notes
    changelog = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    refute ReleaseNotes.pending?(changelog, "changelog.d/a.md" => "### Ops\n\n- Add the secret.\n")
  end

  def test_pending_cli_fails_on_a_malformed_note
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, CHANGELOG)
      File.write(File.join(fragments, "bad.md"), "Not a bullet.\n")

      stdout, stderr, status = run_cli("pending", changelog, fragments)

      refute status.success?
      assert_empty stdout
      assert_match(/bad\.md:1/, stderr)
    end
  end

  def test_pending_cli_prints_whether_a_release_is_due
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01"))

      stdout, stderr, status = run_cli("pending", changelog, fragments)

      assert status.success?, stderr
      assert_equal "false\n", stdout
    end
  end

  def test_fold_adds_waiting_notes_to_the_newest_release
    changelog = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    folded = ReleaseNotes.fold(
      changelog, "2.1.0", "changelog.d/a.md" => "### Changes\n\n- Later.\n\n### Ops\n\n- Add the secret.\n"
    )

    assert_equal <<~MARKDOWN, folded
      # Changelog

      ## [Unreleased]

      #{ReleaseNotes::UNRELEASED_COMMENT}

      ## [2.1.0] - 2026-10-01

      - Work in progress.
      - Later.

      ### Ops

      - Add the secret.

      ## [2.0.0] - 2026-09-08

      - Save and reopen `.pie` projects.
      - Review suggestions before export.

      ## [1.9.0] - 2026-08-01

      - Older work.
    MARKDOWN
  end

  def test_fold_changes_nothing_when_no_notes_wait
    changelog = ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01")

    assert_equal changelog, ReleaseNotes.fold(changelog, "2.1.0")
  end

  def test_fold_rejects_a_release_that_is_not_the_newest
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.fold(CHANGELOG, "1.9.0")
    end

    assert_match(/1\.9\.0 is not the newest release/, error.message)
  end

  def test_fold_cli_moves_fragments_into_the_release_and_deletes_only_them
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      fragments = File.join(directory, "changelog.d")
      FileUtils.mkdir_p(fragments)
      File.write(changelog, ReleaseNotes.promote(CHANGELOG, "2.1.0", "2026-10-01"))
      File.write(File.join(fragments, "README.md"), "# Not a note\n")
      File.write(File.join(fragments, "later.md"), "### Changes\n\n- Later.\n")

      _stdout, stderr, status = run_cli("fold", changelog, fragments, "2.1.0")

      assert status.success?, stderr
      assert_equal "- Work in progress.\n- Later.", ReleaseNotes.extract(File.read(changelog), "2.1.0")
      assert_equal ["README.md"], Dir.children(fragments)
    end
  end

  def test_bump_restores_a_clean_tree_after_the_commit_fails
    Dir.mktmpdir do |directory|
      %w[.gitignore project.yml].each do |path|
        FileUtils.cp(File.expand_path("../../#{path}", __dir__), File.join(directory, path))
      end
      FileUtils.mkdir_p(File.join(directory, "fastlane"))
      FileUtils.mkdir_p(File.join(directory, "packaging"))
      FileUtils.cp(File.expand_path("../../fastlane/Fastfile", __dir__), File.join(directory, "fastlane/Fastfile"))
      FileUtils.cp(SCRIPT, File.join(directory, "packaging/release_notes.rb"))
      File.write(File.join(directory, "CHANGELOG.md"), CHANGELOG)
      FileUtils.mkdir_p(File.join(directory, "changelog.d"))
      File.write(File.join(directory, "changelog.d/README.md"), "# Not a note\n")
      File.write(File.join(directory, "changelog.d/new.md"), "### Changes\n\n- New.\n")
      run_git(directory, "init", "--quiet")
      run_git(directory, "config", "user.name", "Release Test")
      run_git(directory, "config", "user.email", "release-test@example.com")
      run_git(directory, "add", ".")
      run_git(directory, "-c", "commit.gpgSign=false", "commit", "-m", "chore: prepare release test")
      run_git(directory, "config", "commit.gpgSign", "true")
      run_git(directory, "config", "gpg.program", "false")

      _stdout, _stderr, status = Open3.capture3(BUNDLE_ENV, "bundle", "exec", "fastlane", "mac", "bump", "version:2.1.0", chdir: directory)

      refute status.success?
      assert_empty run_git(directory, "status", "--short")
      assert File.exist?(File.join(directory, "changelog.d/new.md"))

      run_git(directory, "config", "commit.gpgSign", "false")
      _stdout, stderr, status = Open3.capture3(BUNDLE_ENV, "bundle", "exec", "fastlane", "mac", "bump", "version:2.1.0", chdir: directory)

      assert status.success?, stderr
      assert_empty run_git(directory, "status", "--short")
      assert_equal ["README.md"], Dir.children(File.join(directory, "changelog.d"))
      assert_equal "- Work in progress.\n- New.",
        ReleaseNotes.extract(File.read(File.join(directory, "CHANGELOG.md")), "2.1.0")
    end
  end

  def test_sets_a_markdown_description_that_round_trips_special_text
    document = REXML::Document.new(<<~XML)
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><item><title>Version 2.0.0</title></item></channel>
      </rss>
    XML
    item = document.elements["rss/channel/item"]
    notes = "- Audio & export <work> safely.\n- A CDATA edge: ]]>"

    ReleaseNotes.set_description(item, notes)

    output = String.new
    document.write(output)
    reparsed = REXML::Document.new(output)
    description = reparsed.elements["rss/channel/item/description"]
    assert_equal "markdown", description.attribute("sparkle:format").value
    assert_equal notes, description.text
  end

  def test_rejects_a_blank_description
    document = REXML::Document.new("<item />")

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.set_description(document.root, " \n")
    end

    assert_match(/empty/, error.message)
  end

  def test_extract_cli_writes_only_the_selected_notes
    Dir.mktmpdir do |directory|
      changelog = File.join(directory, "CHANGELOG.md")
      output = File.join(directory, "dist", "notes.md")
      File.write(changelog, CHANGELOG)

      _stdout, stderr, status = run_cli("extract", changelog, "2.0.0", output)

      assert status.success?, stderr
      assert_equal "- Save and reopen `.pie` projects.\n- Review suggestions before export.\n",
        File.read(output)
    end
  end

  def test_cli_rejects_an_unknown_command
    _stdout, stderr, status = run_cli("publish")

    refute status.success?
    assert_match(/usage:/, stderr)
  end

  def test_cli_rejects_the_wrong_argument_count
    _stdout, stderr, status = run_cli("extract", "CHANGELOG.md")

    refute status.success?
    assert_match(/usage:/, stderr)
  end

  def test_appcast_script_embeds_the_required_markdown_notes
    Dir.mktmpdir do |directory|
      dmg, url, signer, notes_file, plist_buddy = appcast_inputs(directory)

      _stdout, stderr, status = Open3.capture3(
        { "PLIST_BUDDY" => plist_buddy },
        RbConfig.ruby, APPCAST_SCRIPT, dmg, url, signer, notes_file
      )

      assert status.success?, stderr
      appcast = REXML::Document.new(File.read(File.join(directory, "appcast.xml")))
      item = appcast.elements["rss/channel/item"]
      assert_equal "5", item.elements["sparkle:version"].text
      assert_equal "2.0.1", item.elements["sparkle:shortVersionString"].text
      assert_equal "- Visible & useful.\n", item.elements["description"].text
      assert_equal "markdown", item.elements["description"].attribute("sparkle:format").value
      assert_equal File.read(File.join(directory, "signature")),
                   item.elements["enclosure"].attribute("sparkle:edSignature").value
    end
  end

  def test_appcast_script_preserves_existing_feed_items
    Dir.mktmpdir do |directory|
      dmg, url, signer, notes_file, plist_buddy = appcast_inputs(directory)
      File.write(File.join(directory, "appcast.xml"), <<~XML)
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Version 2.0.0</title>
              <sparkle:version>4</sparkle:version>
              <description sparkle:format="markdown">- Older release.</description>
              <enclosure url="https://example.com/SlipstreamViewer-2.0.0-4.dmg" />
            </item>
          </channel>
        </rss>
      XML

      _stdout, stderr, status = Open3.capture3(
        { "PLIST_BUDDY" => plist_buddy },
        RbConfig.ruby, APPCAST_SCRIPT, dmg, url, signer, notes_file
      )

      assert status.success?, stderr
      appcast = REXML::Document.new(File.read(File.join(directory, "appcast.xml")))
      items = appcast.elements.to_a("rss/channel/item")
      assert_equal ["4", "5"], items.map { |item| item.elements["sparkle:version"].text }
      older = items.first
      assert_equal "- Older release.", older.elements["description"].text
      assert_equal "https://example.com/SlipstreamViewer-2.0.0-4.dmg",
                   older.elements["enclosure"].attribute("url").value
    end
  end

  def test_appcast_script_signs_with_the_slipstream_keychain_account_by_default
    Dir.mktmpdir do |directory|
      dmg, url, signer, notes_file, plist_buddy = appcast_inputs(directory)

      _stdout, stderr, status = Open3.capture3(
        { "PLIST_BUDDY" => plist_buddy, "SPARKLE_ED_KEY_FILE" => nil },
        RbConfig.ruby, APPCAST_SCRIPT, dmg, url, signer, notes_file
      )

      assert status.success?, stderr
      assert_equal ["--account", "slipstream-viewer", dmg], signer_arguments(directory)
    end
  end

  def test_appcast_script_signs_with_the_key_file_when_one_is_given
    Dir.mktmpdir do |directory|
      dmg, url, signer, notes_file, plist_buddy = appcast_inputs(directory)

      _stdout, stderr, status = Open3.capture3(
        { "PLIST_BUDDY" => plist_buddy, "SPARKLE_ED_KEY_FILE" => "/run/sparkle.key" },
        RbConfig.ruby, APPCAST_SCRIPT, dmg, url, signer, notes_file
      )

      assert status.success?, stderr
      assert_equal ["--ed-key-file", "/run/sparkle.key", dmg], signer_arguments(directory)
    end
  end

  def test_appcast_script_refuses_a_signature_the_built_app_cannot_verify
    Dir.mktmpdir do |directory|
      dmg, url, signer, notes_file, plist_buddy = appcast_inputs(directory, app_key: OpenSSL::PKey.generate_key("ED25519"))

      _stdout, stderr, status = Open3.capture3(
        { "PLIST_BUDDY" => plist_buddy },
        RbConfig.ruby, APPCAST_SCRIPT, dmg, url, signer, notes_file
      )

      refute status.success?
      assert_match(/does not verify against the app's SUPublicEDKey/, stderr)
      refute File.exist?(File.join(directory, "appcast.xml"))
    end
  end

  def test_appcast_script_refuses_a_build_that_is_not_newer_than_the_published_one
    Dir.mktmpdir do |directory|
      dmg, url, signer, notes_file, plist_buddy = appcast_inputs(directory)
      File.write(File.join(directory, "appcast.xml"), <<~XML)
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><sparkle:version>5</sparkle:version></item></channel>
        </rss>
      XML

      _stdout, stderr, status = Open3.capture3(
        { "PLIST_BUDDY" => plist_buddy },
        RbConfig.ruby, APPCAST_SCRIPT, dmg, url, signer, notes_file
      )

      refute status.success?
      assert_match(/not newer than published build 5/, stderr)
    end
  end

  private

  # The fake sign_update records its arguments and really signs the DMG, so the
  # script's check against the app's SUPublicEDKey runs for real.
  def appcast_inputs(directory, app_key: nil)
    dmg = File.join(directory, "SlipstreamViewer-2.0.1-5.dmg")
    notes_file = File.join(directory, "notes.md")
    signer = File.join(directory, "sign_update")
    plist_buddy = File.join(directory, "plist_buddy")
    signing_key = OpenSSL::PKey.generate_key("ED25519")
    File.write(File.join(directory, "signing_key.pem"), signing_key.private_to_pem)
    File.write(dmg, "disk image")
    File.write(notes_file, "- Visible & useful.\n")
    write_executable(signer, <<~RUBY)
      #!#{RbConfig.ruby}
      require "base64"
      require "openssl"
      directory = #{directory.inspect}
      File.write(File.join(directory, "signer_arguments"), ARGV.join("\n"))
      key = OpenSSL::PKey.read(File.read(File.join(directory, "signing_key.pem")))
      signature = Base64.strict_encode64(key.sign(nil, File.binread(ARGV.last)))
      File.write(File.join(directory, "signature"), signature)
      puts %(sparkle:edSignature="\#{signature}" length="\#{File.size(ARGV.last)}")
    RUBY
    write_executable(plist_buddy, <<~SH)
      #!/bin/sh
      case "$2" in
        "Print :CFBundleVersion") printf '5\n' ;;
        "Print :CFBundleShortVersionString") printf '2.0.1\n' ;;
        "Print :SUPublicEDKey") printf '%s\n' '#{public_key_base64(app_key || signing_key)}' ;;
        *) exit 1 ;;
      esac
    SH
    url = "https://example.com/#{File.basename(dmg)}"
    [dmg, url, signer, notes_file, plist_buddy]
  end

  def public_key_base64(key)
    Base64.strict_encode64(key.public_to_der[-32, 32])
  end

  def signer_arguments(directory)
    File.read(File.join(directory, "signer_arguments")).split("\n")
  end

  def run_cli(*arguments)
    Open3.capture3(RbConfig.ruby, SCRIPT, *arguments)
  end

  def run_git(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    assert status.success?, stderr
    stdout
  end

  def write_executable(path, contents)
    File.write(path, contents)
    File.chmod(0o755, path)
  end
end
