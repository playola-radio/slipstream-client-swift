#!/usr/bin/env ruby
# Refuses a release whose bundled daemon is older than the newest @playola-radio/slipstream
# on npm. The app never takes over a recorder newer than its own, so an npm install ahead of
# the bundle keeps recording but leaves the app without its `slipstream` command.
#
#   ruby packaging/daemon_freshness.rb <runtime-dir>

require "json"
require "net/http"

module DaemonFreshness
  class Error < StandardError; end

  PACKAGE = "@playola-radio/slipstream"
  LATEST = URI("https://registry.npmjs.org/@playola-radio%2Fslipstream/latest")
  VERSION = /\A\d+\.\d+\.\d+\z/

  def self.bundled_version(runtime)
    path = File.join(runtime, "app/package.json")
    version = JSON.parse(File.read(path))["version"]
    raise Error, "#{path} has no X.Y.Z version: #{version.inspect}" unless VERSION.match?(version.to_s)

    version
  rescue Errno::ENOENT, JSON::ParserError => error
    raise Error, "couldn't read the bundled daemon version from #{path}: #{error.message}"
  end

  # `fetch` returns the registry response body for LATEST, or raises.
  def self.latest_version(fetch = method(:get))
    body = fetch.call(LATEST)
    version = JSON.parse(body)["version"]
    raise Error, "#{LATEST} has no X.Y.Z version: #{version.inspect}" unless VERSION.match?(version.to_s)

    version
  rescue JSON::ParserError => error
    raise Error, "#{LATEST} didn't return JSON: #{error.message}"
  end

  def self.check(bundled, latest)
    return if Gem::Version.new(bundled) >= Gem::Version.new(latest)

    raise Error, "the bundled daemon is #{bundled}, older than #{PACKAGE} #{latest} on npm. " \
                 "Set DAEMON_COMMIT in packaging/runtime.env to the v#{latest} release commit."
  end

  def self.get(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
      http.get(uri.request_uri, "Accept" => "application/json")
    end
    raise Error, "GET #{uri} returned HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  rescue SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError => error
    raise Error, "GET #{uri} failed: #{error.class}: #{error.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  abort("usage: daemon_freshness.rb <runtime-dir>") unless ARGV.length == 1
  begin
    bundled = DaemonFreshness.bundled_version(ARGV[0])
    latest = DaemonFreshness.latest_version
    DaemonFreshness.check(bundled, latest)
    puts "==> Bundled daemon #{bundled} is current (npm latest is #{latest})"
  rescue DaemonFreshness::Error => error
    abort("error: #{error.message}")
  end
end
