# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::Versions do
  subject(:versions) { described_class.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  it "parses every manifest entry in file order" do
    expect(versions.names).to eq(["3.3.3", "3.3.7", "3.4.1", "9.9.9"])
  end

  it "is enumerable over entries" do
    expect(versions.map(&:name)).to eq(versions.names)
  end

  it "exposes url, sha256 and line of a version" do
    entry = versions.fetch("3.3.7")
    expect(entry.url).to eq("http://127.0.0.1:1/ruby-3.3.7.tar.gz")
    expect(entry.sha256).to eq("0000000000000000000000000000000000000000000000000000000000000002")
    expect(entry.line).to eq("3.3")
  end

  it "derives tarball and source-tree names from the version" do
    entry = versions.fetch("9.9.9")
    expect(entry.tarball_name).to eq("ruby-9.9.9.tar.gz")
    expect(entry.src_tree_name).to eq("tfs-ruby-9.9.9-src")
  end

  it "raises KeyError for a version that is not in the manifest" do
    expect { versions.fetch("1.0.0") }.to raise_error(KeyError, /1\.0\.0/)
  end

  it "rejects a manifest without a top-level versions mapping" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, "---\nnot_versions: {}\n")
      expect { described_class.new(path) }.to raise_error(ArgumentError, /versions/)
    end
  end

  it "rejects an entry with a malformed sha256" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, <<~YAML)
        versions:
          1.2.3:
            url: http://127.0.0.1:1/ruby-1.2.3.tar.gz
            sha256: not-hex
            line: "1.2"
      YAML
      expect { described_class.new(path) }.to raise_error(ArgumentError, /sha256/)
    end
  end

  it "rejects an entry with a malformed version name" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, <<~YAML)
        versions:
          "1.2":
            url: http://127.0.0.1:1/ruby-1.2.tar.gz
            sha256: #{"0" * 64}
            line: "1.2"
      YAML
      expect { described_class.new(path) }.to raise_error(ArgumentError, /1\.2/)
    end
  end
end
