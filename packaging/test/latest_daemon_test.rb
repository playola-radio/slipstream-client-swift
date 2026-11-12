require "minitest/autorun"
require_relative "../latest_daemon"

class LatestDaemonTest < Minitest::Test
  SHA = "56e171aad69706c061549502f0e8cfd0b948d8ae"

  def resolve(body)
    LatestDaemon.resolve(->(_uri) { body })
  end

  def test_reads_the_latest_version_and_commit_from_the_registry
    assert_equal ["0.3.2", SHA], resolve(%({"name":"@playola-radio/slipstream","version":"0.3.2","gitHead":"#{SHA}"}))
  end

  def test_a_release_without_a_full_commit_is_an_error
    error = assert_raises(LatestDaemon::Error) { resolve('{"name":"@playola-radio/slipstream","version":"0.3.2"}') }

    assert_includes error.message, "@playola-radio/slipstream 0.3.2 has no 40-character gitHead"
    assert_raises(LatestDaemon::Error) { resolve('{"name":"@playola-radio/slipstream","version":"0.3.2","gitHead":"56e171a"}') }
  end

  def test_registry_reply_without_a_version_is_an_error
    assert_raises(LatestDaemon::Error) { resolve(%({"name":"@playola-radio/slipstream","gitHead":"#{SHA}"})) }
    assert_raises(LatestDaemon::Error) { resolve("<html>") }
  end

  def test_another_package_is_an_error
    assert_raises(LatestDaemon::Error) { resolve(%({"name":"slipstream","version":"0.3.2","gitHead":"#{SHA}"})) }
  end
end
