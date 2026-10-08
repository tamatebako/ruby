# frozen_string_literal: true

require "json"

RSpec.describe Tfs::ProvenanceFeed do
  let(:api) { "https://api.test/repos/x/y/releases" }
  let(:download) { "https://api.test/dl" }

  def release_json(tag, created_at, assets, draft: false)
    { "tag_name" => tag, "created_at" => created_at, "draft" => draft,
      "assets" => assets.map { |name| { "name" => name } } }
  end

  # A fetcher stub keyed by exact url, capturing the headers each call got
  # and raising like the real Tfs::HttpGet on unknown urls.
  def stub_fetcher(bodies, captured)
    lambda do |url, headers:|
      captured << [url, headers]
      bodies.fetch(url) { raise Tfs::HttpGet::Error, "HTTP 404 from #{url}" }
    end
  end

  it "lists published releases oldest-first with their asset names" do
    captured = []
    bodies = {
      "#{api}?per_page=100&page=1" => JSON.generate([
        release_json("v0.2.2", "2026-08-02T00:00:00Z", %w[SHA256SUMS provenance.yaml]),
        release_json("v0.2.1", "2026-08-01T00:00:00Z", %w[SHA256SUMS]),
        release_json("v0.2.3-draft", "2026-08-03T00:00:00Z", %w[SHA256SUMS], draft: true)
      ])
    }
    feed = described_class.new(api_url: api, download_url: download, fetcher: stub_fetcher(bodies, captured))
    expect(feed.releases).to eq([
                                  { "tag" => "v0.2.1", "created_at" => "2026-08-01T00:00:00Z", "assets" => %w[SHA256SUMS] },
                                  { "tag" => "v0.2.2", "created_at" => "2026-08-02T00:00:00Z", "assets" => %w[SHA256SUMS provenance.yaml] }
                                ])
    expect(captured.first[1]).to include("User-Agent" => Tfs::ProvenanceFeed::USER_AGENT)
    expect(captured.first[1]).not_to have_key("Authorization")
  end

  it "paginates until a short page and sends the token when given" do
    captured = []
    full_page = Array.new(100) { |i| release_json("v0.0.#{i}", "2026-08-01T00:00:#{i.to_s.rjust(2, '0')}Z", %w[SHA256SUMS]) }
    bodies = {
      "#{api}?per_page=100&page=1" => JSON.generate(full_page),
      "#{api}?per_page=100&page=2" => JSON.generate([release_json("v0.1.0", "2026-09-01T00:00:00Z", %w[SHA256SUMS])])
    }
    feed = described_class.new(api_url: api, download_url: download, token: "sekrit", fetcher: stub_fetcher(bodies, captured))
    expect(feed.releases.size).to eq(101)
    expect(feed.releases.last["tag"]).to eq("v0.1.0")
    expect(captured.map { |(_url, headers)| headers["Authorization"] }.uniq).to eq(["Bearer sekrit"])
  end

  it "fails named on a malformed releases response" do
    captured = []
    feed = described_class.new(api_url: api, download_url: download,
                               fetcher: stub_fetcher({ "#{api}?per_page=100&page=1" => "not json" }, captured))
    expect { feed.releases }.to raise_error(Tfs::ProvenanceFeed::Error, /cannot parse the releases API response/)

    feed = described_class.new(api_url: api, download_url: download,
                               fetcher: stub_fetcher({ "#{api}?per_page=100&page=1" => "{}" }, captured))
    expect { feed.releases }.to raise_error(Tfs::ProvenanceFeed::Error, /want an array/)
  end

  it "fetches an asset body and wraps failures naming the release and asset" do
    captured = []
    bodies = { "#{download}/v0.2.38/SHA256SUMS" => "abc  tfs-ruby-3.3.12-src.tar.gz\n" }
    feed = described_class.new(api_url: api, download_url: download, fetcher: stub_fetcher(bodies, captured))
    expect(feed.asset_body("v0.2.38", "SHA256SUMS")).to eq("abc  tfs-ruby-3.3.12-src.tar.gz\n")

    expect { feed.asset_body("v0.2.38", "provenance.yaml") }
      .to raise_error(Tfs::ProvenanceFeed::Error, /cannot fetch provenance\.yaml of release v0\.2\.38: HTTP 404/)
  end
end
