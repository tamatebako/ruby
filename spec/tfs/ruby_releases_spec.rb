# frozen_string_literal: true

RSpec.describe Tfs::RubyReleases do
  subject(:releases) { described_class.new(File.read(File.join(SPEC_FIXTURES, "releases.html"))) }

  let(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  it "parses released versions from the download links, excluding previews" do
    expect(releases.names).to eq(%w[4.1.0 3.5.1 3.5.0 3.4.2 3.4.1 3.3.8 3.3.7 3.3.3 3.0.7 2.7.8])
  end

  it "exposes the official url and line of a release" do
    entry = releases.entry("3.3.8")
    expect(entry.url).to eq("https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.8.tar.gz")
    expect(entry.line).to eq("3.3")
  end

  it "raises KeyError for something that was not released" do
    expect { releases.entry("1.2.3") }.to raise_error(KeyError, /1\.2\.3/)
  end

  it "diffs new versions: newer patches of tracked lines and the latest of untracked lines in the window" do
    expect(releases.new_versions(versions).map(&:name)).to eq(%w[3.3.8 3.4.2 3.5.1 4.1.0])
  end

  it "is a no-op when nothing new was released" do
    html = <<~HTML
      <table>
      <tr><td>Ruby 3.3.7</td><td>2025-01-15</td><td><a href="https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.7.tar.gz">download</a></td></tr>
      <tr><td>Ruby 3.3.3</td><td>2024-06-12</td><td><a href="https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.3.tar.gz">download</a></td></tr>
      </table>
    HTML
    expect(described_class.new(html).new_versions(versions)).to eq([])
  end
end
