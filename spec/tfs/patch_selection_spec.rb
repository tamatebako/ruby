# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::PatchSelection do
  subject(:selection) { described_class.new(File.join(SPEC_FIXTURES, "patches")) }

  def resolved(version, **scenario)
    selection.for(version, **scenario)
  end

  describe "manifest resolution" do
    it "takes whole-line entries for any patch level of the line" do
      patches = resolved("3.3.3")
      expect(patches.map(&:feature)).to eq(%w[alpha configure_extstatic_darwin dir_c_memfs gnu
                                              gnumakefile_in_pass1_msys gnumakefile_in_pass2_msys
                                              thread_pthread_main_stack_musl dir_c_memfs_msys gamma])
    end

    it "picks the diverged body that covers the requested patch level" do
      expect(resolved("3.3.3").find { |p| p.feature == "gnu" }.name).to eq("gnu_3.patch")
      expect(resolved("3.3.5").find { |p| p.feature == "gnu" }.name).to eq("gnu_3.patch")
      expect(resolved("3.3.7").find { |p| p.feature == "gnu" }.name).to eq("gnu_7.patch")
    end

    it "lets a versioned entry supersede the whole-line entry for that patch level only" do
      expect(resolved("3.3.3").find { |p| p.feature == "alpha" }.name).to eq("alpha.patch")
      alpha = resolved("3.3.7").find { |p| p.feature == "alpha" }
      expect(alpha.name).to eq("alpha_7.patch")
      expect(alpha.version).to eq("7")
      expect(alpha).not_to be_line_wide
    end

    it "adds overlay entries only for their exact version" do
      expect(resolved("3.3.3").map(&:feature)).not_to include("exact_only")
      expect(resolved("3.3.7").map(&:feature)).to include("exact_only")
    end

    it "appends overlay-only features after the base order" do
      expect(resolved("3.3.7").map(&:feature).last).to eq("exact_only")
    end

    it "resolves ../<line>/ references into the referenced line's folder" do
      patches = resolved("3.4.1")
      expect(patches.map(&:feature)).to eq(%w[alpha gamma])
      expect(patches.map(&:path)).to all(include("#{File.join(SPEC_FIXTURES, "patches", "3.3")}/"))
    end

    it "raises for a feature whose versioned entries do not cover the patch level" do
      expect { resolved("8.8.5") }
        .to raise_error(Tfs::PatchSelection::SelectionError, /8\.8\.5.*partial|partial.*8\.8\.5/)
    end

    it "resolves a covered patch level of a versioned-only feature" do
      expect(resolved("8.8.4").map(&:name)).to eq(["partial_4.patch"])
    end

    it "raises for a line without a manifest" do
      expect { resolved("7.7.7") }
        .to raise_error(Tfs::PatchSelection::SelectionError, /patch-7\.7\.yaml/)
    end
  end

  describe "patch metadata" do
    it "exposes feature, version, name and target file" do
      patch = resolved("3.3.3").find { |p| p.feature == "dir_c_memfs" }
      expect(patch.version).to be_nil
      expect(patch).to be_line_wide
      expect(patch.patchlevel).to be_nil
      expect(patch.name).to eq("dir_c_memfs.patch")
      expect(patch.target_file).to eq("dir.c")
    end
  end

  describe "scenario selection" do
    it "drops other platforms' patches on linux-gnu" do
      expect(resolved("3.3.7", platform: "linux-gnu", pass: 2).map(&:feature))
        .to eq(%w[alpha dir_c_memfs gnu gamma exact_only])
    end

    it "keeps darwin patches on darwin" do
      expect(resolved("3.3.7", platform: "darwin", pass: 2).map(&:feature))
        .to eq(%w[alpha configure_extstatic_darwin dir_c_memfs gnu gamma exact_only])
    end

    it "keeps musl patches on linux-musl" do
      expect(resolved("3.3.7", platform: "linux-musl", pass: 2).map(&:feature))
        .to eq(%w[alpha dir_c_memfs gnu thread_pthread_main_stack_musl gamma exact_only])
    end

    it "on msys keeps msys variants and drops neutral variants of the same target" do
      expect(resolved("3.3.7", platform: "msys", pass: 2).map(&:feature))
        .to eq(%w[alpha gnu gnumakefile_in_pass2_msys dir_c_memfs_msys gamma exact_only])
    end

    it "switches the GNUmakefile pass variant" do
      expect(resolved("3.3.7", platform: "msys", pass: 1).map(&:feature))
        .to include("gnumakefile_in_pass1_msys")
    end

    it "rejects an unknown platform" do
      expect { resolved("3.3.7", platform: "solaris") }.to raise_error(ArgumentError, /solaris/)
    end

    it "rejects an unknown pass" do
      expect { resolved("3.3.7", pass: 3) }.to raise_error(ArgumentError, /pass/)
    end
  end
end
