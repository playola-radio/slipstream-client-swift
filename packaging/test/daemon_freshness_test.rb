require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../daemon_freshness"

class DaemonFreshnessTest < Minitest::Test
  def test_older_bundled_daemon_is_refused
    error = assert_raises(DaemonFreshness::Error) { DaemonFreshness.check("0.3.1", "0.3.2") }

    assert_includes error.message, "the bundled daemon is 0.3.1, older than @playola-radio/slipstream 0.3.2"
  end

  def test_versions_compare_numerically
    assert_raises(DaemonFreshness::Error) { DaemonFreshness.check("0.3.9", "0.3.10") }
  end

  def test_same_or_newer_bundled_daemon_passes
    assert_nil DaemonFreshness.check("0.3.2", "0.3.2")
    assert_nil DaemonFreshness.check("0.4.0", "0.3.2")
  end

  def test_reads_the_bundled_version_from_the_payload
    Dir.mktmpdir do |runtime|
      FileUtils.mkdir_p(File.join(runtime, "app"))
      File.write(File.join(runtime, "app/package.json"), '{"name":"@playola-radio/slipstream","version":"0.3.2"}')

      assert_equal "0.3.2", DaemonFreshness.bundled_version(runtime)
    end
  end

  def test_missing_payload_is_an_error
    Dir.mktmpdir do |runtime|
      error = assert_raises(DaemonFreshness::Error) { DaemonFreshness.bundled_version(runtime) }

      assert_includes error.message, "app/package.json"
    end
  end

  def test_reads_the_latest_version_from_the_registry
    assert_equal "0.3.2", DaemonFreshness.latest_version(->(_uri) { '{"version":"0.3.2"}' })
  end

  def test_registry_failure_is_an_error
    failing = ->(_uri) { raise DaemonFreshness::Error, "GET registry returned HTTP 503" }

    assert_raises(DaemonFreshness::Error) { DaemonFreshness.latest_version(failing) }
  end

  def test_registry_reply_without_a_version_is_an_error
    assert_raises(DaemonFreshness::Error) { DaemonFreshness.latest_version(->(_uri) { '{"error":"not found"}' }) }
    assert_raises(DaemonFreshness::Error) { DaemonFreshness.latest_version(->(_uri) { "<html>" }) }
  end
end
