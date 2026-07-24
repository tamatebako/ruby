# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::PatchSelection do
  subject(:selection) { described_class.new(File.join(SPEC_FIXTURES, "patches")) }

  def slugs(version, **scenario)
    selection.for(version, **scenario).map(&:slug)
  end

  describe "patch metadata" do
    it "parses name, category, line, segment and target from the filename and header" do
      patch = selection.for("3.3.3").find { |candidate| candidate.slug == "alpha" }
      expect(patch.name).to eq("tfs-ruby-3-3-x-alpha.patch")
      expect(patch.category).to eq("build-config")
      expect(patch.line).to eq("3.3")
      expect(patch).to be_line_wide
      expect(patch.patchlevel).to be_nil
      expect(patch.target_file).to eq("lib/alpha.rb")
    end

    it "exposes the patchlevel of exact patches" do
      patch = selection.for("3.3.7").find { |candidate| candidate.slug == "beta" }
      expect(patch).not_to be_line_wide
      expect(patch.patchlevel).to eq("7")
    end

    it "rejects a malformed patch filename" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "build-config"))
        File.write(File.join(dir, "build-config", "not-a-tfs-name.patch"), "# x\n")
        expect { described_class.new(dir) }.to raise_error(ArgumentError, /not-a-tfs-name/)
      end
    end
  end

  describe "union selection (no scenario)" do
    it "selects the line-wide patches of the version's line only" do
      expect(slugs("3.3.3")).to eq(%w[alpha configure-extstatic-darwin dir-c-memfs
                                      thread-pthread-main-stack-musl dir-c-memfs-msys gamma])
    end

    it "excludes other lines" do
      expect(slugs("3.4.1")).to eq(%w[gamma])
    end

    it "includes exact patchlevel matches" do
      expect(slugs("3.3.7")).to include("beta", "gnumakefile-in-pass1-msys", "gnumakefile-in-pass2-msys")
    end

    it "lets an exact patch supersede the same-slug line-wide patch" do
      patches = selection.for("3.3.7").select { |candidate| candidate.slug == "alpha" }
      expect(patches.size).to eq(1)
      expect(patches.first.segment).to eq("7")
    end

    it "orders build-config before io-routing, slug-sorted within a category" do
      patches = selection.for("3.3.3")
      expect(patches.map(&:category)).to eq(%w[build-config build-config build-config
                                               build-config io-routing io-routing])
      patches.group_by(&:category).each_value do |group|
        expect(group.map(&:slug)).to eq(group.map(&:slug).sort)
      end
    end
  end

  describe "scenario selection" do
    it "drops other platforms' patches on linux-gnu" do
      expect(slugs("3.3.7", platform: "linux-gnu", pass: 2)).to eq(%w[alpha beta dir-c-memfs gamma])
    end

    it "keeps darwin patches on darwin" do
      expect(slugs("3.3.7", platform: "darwin", pass: 2)).to eq(%w[alpha beta configure-extstatic-darwin dir-c-memfs gamma])
    end

    it "keeps musl patches on linux-musl" do
      expect(slugs("3.3.7", platform: "linux-musl", pass: 2))
        .to eq(%w[alpha beta dir-c-memfs thread-pthread-main-stack-musl gamma])
    end

    it "on msys keeps msys variants and drops neutral variants of the same target" do
      expect(slugs("3.3.7", platform: "msys", pass: 2))
        .to eq(%w[alpha beta gnumakefile-in-pass2-msys dir-c-memfs-msys gamma])
    end

    it "switches the GNUmakefile pass variant" do
      expect(slugs("3.3.7", platform: "msys", pass: 1))
        .to eq(%w[alpha beta gnumakefile-in-pass1-msys dir-c-memfs-msys gamma])
    end

    it "rejects an unknown platform" do
      expect { selection.for("3.3.7", platform: "solaris") }.to raise_error(ArgumentError, /solaris/)
    end

    it "rejects an unknown pass" do
      expect { selection.for("3.3.7", pass: 3) }.to raise_error(ArgumentError, /pass/)
    end
  end
end
