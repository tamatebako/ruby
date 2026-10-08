# frozen_string_literal: true

require "json"

module Tfs
  # The GitHub-facing feed for the provenance ledger: lists this
  # factory's published releases (oldest first) with their asset names and
  # fetches per-release SHA256SUMS / provenance.yaml bodies. All HTTP goes
  # through an injectable fetcher (Tfs::HttpGet in production, a stub in
  # specs) — the class itself is pure request planning and response
  # parsing. Every failure is a named error naming the release.
  class ProvenanceFeed
    # Raised on any feed failure, naming the release where relevant.
    class Error < StandardError; end

    API_URL = "https://api.github.com/repos/tamatebako/ruby/releases"
    DOWNLOAD_URL = "https://github.com/tamatebako/ruby/releases/download"
    USER_AGENT = "tfs-ruby-provenance (tamatebako/ruby)"
    PER_PAGE = 100

    # token:   optional GitHub token (Authorization header for the releases
    #          API; the public rate limit already covers the handful of
    #          calls a publish makes).
    # fetcher: #call(url, headers:) -> String body.
    def initialize(token: nil, fetcher: nil, api_url: API_URL, download_url: DOWNLOAD_URL)
      @fetcher = fetcher || HttpGet.method(:body)
      @api_url = api_url
      @download_url = download_url
      @headers = { "User-Agent" => USER_AGENT }
      @headers["Authorization"] = "Bearer #{token}" if token
    end

    # Every published release, oldest first: {"tag", "created_at",
    # "assets"}. Drafts are not publications and never attest anything.
    def releases
      page = 1
      listing = []
      loop do
        batch = JSON.parse(@fetcher.call("#{@api_url}?per_page=#{PER_PAGE}&page=#{page}", headers: @headers))
        raise Error, "unexpected releases API response (want an array)" unless batch.is_a?(Array)

        listing.concat(batch.reject { |release| release["draft"] })
        break if batch.size < PER_PAGE

        page += 1
      end
      listing.sort_by { |release| release.fetch("created_at") }.map do |release|
        {
          "tag" => release.fetch("tag_name"),
          "created_at" => release.fetch("created_at"),
          "assets" => release.fetch("assets").map { |asset| asset.fetch("name") }
        }
      end
    rescue JSON::ParserError => e
      raise Error, "cannot parse the releases API response: #{e.message}"
    rescue KeyError => e
      raise Error, "unexpected releases API response (missing key #{e.key})"
    end

    # The named asset's body from one release's download area.
    def asset_body(tag, name)
      @fetcher.call("#{@download_url}/#{tag}/#{name}", headers: @headers)
    rescue HttpGet::Error => e
      raise Error, "cannot fetch #{name} of release #{tag}: #{e.message}"
    end
  end
end
