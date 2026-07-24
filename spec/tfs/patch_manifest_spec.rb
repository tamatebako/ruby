# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::PatchManifest do
  let(:manifest_path) { File.join(SPEC_FIXTURES, "patches", "3.3", "patch-3.3.yaml") }

  it "parses version and entries in order" do
    manifest = described_class.new(manifest_path)
    expect(manifest.version).to eq("3.3")
    expect(manifest.entries.map(&:feature).first(3)).to eq(%w[alpha alpha configure_extstatic_darwin])
  end

  it "distinguishes whole-line and exact entries" do
    manifest = described_class.new(manifest_path)
    whole, exact = manifest.entries.first(2)
    expect(whole).to be_whole_line
    expect(exact).not_to be_whole_line
    expect(exact).to be_exact_for("7")
    expect(exact).not_to be_exact_for("3")
  end

  it "rejects a document without version and patches array" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "patch-1.1.yaml")
      File.write(path, "---\npatches: {}\n")
      expect { described_class.new(path) }.to raise_error(ArgumentError, /patches/)
    end
  end

  it "rejects an entry with a non-snake_case feature" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "patch-1.1.yaml")
      File.write(path, <<~YAML)
        version: "1.1"
        patches:
          - feature: Not-Snake
            file: x.patch
      YAML
      expect { described_class.new(path) }.to raise_error(ArgumentError, /Not-Snake/)
    end
  end

  it "rejects an entry with a non-string version" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "patch-1.1.yaml")
      File.write(path, <<~YAML)
        version: "1.1"
        patches:
          - feature: x
            file: x.patch
            version: 7
      YAML
      expect { described_class.new(path) }.to raise_error(ArgumentError)
    end
  end
end
