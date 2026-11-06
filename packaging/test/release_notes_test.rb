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

  def write_executable(path, contents)
    File.write(path, contents)
    File.chmod(0o755, path)
  end
end
