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

  it "defaults scenarios to linux-gnu only when the key is absent" do
    expect(versions.fetch("9.9.9").scenarios).to eq(["linux-gnu"])
  end

  it "parses an explicit scenarios array in file order" do
    expect(versions.fetch("3.3.7").scenarios).to eq(["linux-gnu", "linux-musl", "msys"])
  end

  it "rejects a scenarios value that is not an array" do
    expect { manifest_with_scenarios("linux-gnu") }.to raise_error(ArgumentError, /scenarios/)
  end

  it "rejects an empty scenarios array" do
    expect { manifest_with_scenarios([]) }.to raise_error(ArgumentError, /scenarios/)
  end

  it "rejects unknown scenario names" do
    expect { manifest_with_scenarios(["linux-gnu", "plan9"]) }.to raise_error(ArgumentError, /plan9/)
  end

  it "rejects duplicate scenarios" do
    expect { manifest_with_scenarios(["linux-gnu", "linux-gnu"]) }.to raise_error(ArgumentError, /scenarios/)
  end

  it "rejects scenarios without linux-gnu (the unsuffixed back-compat asset)" do
    expect { manifest_with_scenarios(["msys"]) }.to raise_error(ArgumentError, /linux-gnu/)
  end

  describe "#builds" do
    subject(:builds) { versions.builds }

    it "emits one row per version x scenario build (msys expands to two passes)" do
      # 3.3.3, 3.4.1, 9.9.9 ship linux-gnu only; 3.3.7 ships all three scenarios.
      expect(builds.size).to eq(7)
      expect(builds.map { |row| row[:version] }.uniq).to eq(versions.names)
    end

    it "keeps the linux-gnu row unsuffixed for back-compat" do
      expect(builds.first).to eq(version: "3.3.3", platform: "linux-gnu", pass: 2, suffix: "")
    end

    it "emits the musl row suffixed, pass 2 (musl selection is pass-invariant)" do
      row = builds.find { |candidate| candidate[:platform] == "linux-musl" }
      expect(row).to eq(version: "3.3.7", platform: "linux-musl", pass: 2, suffix: "-linux-musl")
    end

    it "expands msys into pass1 and pass2 rows" do
      rows = builds.select { |candidate| candidate[:platform] == "msys" }
      expect(rows).to eq([
                           { version: "3.3.7", platform: "msys", pass: 1, suffix: "-msys-pass1" },
                           { version: "3.3.7", platform: "msys", pass: 2, suffix: "-msys-pass2" }
                         ])
    end
  end

  def manifest_with_scenarios(scenarios)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, <<~YAML)
        versions:
          1.2.3:
            url: http://127.0.0.1:1/ruby-1.2.3.tar.gz
            sha256: "#{'0' * 64}"
            line: "1.2"
            scenarios: #{scenarios.inspect.tr('"', "'")}
      YAML
      described_class.new(path)
    end
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
