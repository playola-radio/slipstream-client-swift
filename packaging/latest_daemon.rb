#!/usr/bin/env ruby
# Prints the version and commit of the newest @playola-radio/slipstream on npm, which every
# release bundles. The daemon tags its release after publishing, so the commit comes from the
# registry's gitHead rather than the tag.
#
#   ruby packaging/latest_daemon.rb   # => "0.3.2 56e171aad69706c061549502f0e8cfd0b948d8ae"

require "json"
require "net/http"

module LatestDaemon
  class Error < StandardError; end

  PACKAGE = "@playola-radio/slipstream"
  LATEST = URI("https://registry.npmjs.org/@playola-radio%2Fslipstream/latest")
  VERSION = /\A\d+\.\d+\.\d+\z/
  COMMIT = /\A\h{40}\z/

  # `fetch` returns the registry response body for LATEST, or raises.
  def self.resolve(fetch = method(:get))
    body = fetch.call(LATEST)
    latest = JSON.parse(body)
    raise Error, "#{LATEST} is for #{latest["name"].inspect}, not #{PACKAGE}" unless latest["name"] == PACKAGE

    version = latest["version"]
    commit = latest["gitHead"]
    raise Error, "#{LATEST} has no X.Y.Z version: #{version.inspect}" unless VERSION.match?(version.to_s)
    raise Error, "#{PACKAGE} #{version} has no 40-character gitHead: #{commit.inspect}" unless COMMIT.match?(commit.to_s)

    [version, commit]
  rescue JSON::ParserError => error
    raise Error, "#{LATEST} didn't return JSON: #{error.message}"
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
  abort("usage: latest_daemon.rb") unless ARGV.empty?
  begin
    puts LatestDaemon.resolve.join(" ")
  rescue LatestDaemon::Error => error
    abort("error: #{error.message}")
  end
end
