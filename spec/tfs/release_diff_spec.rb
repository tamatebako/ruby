# frozen_string_literal: true

RSpec.describe Tfs::ReleaseDiff do
  # Fake git runner keyed on argv, in the shape ReleaseDiff calls it.
  def fake_git(tags:, diffs: {}, shows: {})
    lambda do |*args|
      case args[0]
      when "tag"
        tags.empty? ? "" : "#{tags.join("\n")}\n"
      when "diff"
        diffs.fetch(args[2]) { raise Tfs::ReleaseDiff::Error, "git diff --name-only #{args[2]} failed: unexpected range" }
      when "show"
        shows.fetch(args[1]) { raise Tfs::ReleaseDiff::Error, "git show #{args[1]} failed: not found" }
      else
        raise Tfs::ReleaseDiff::Error, "unexpected git #{args.join(' ')}"
      end
    end
  end

  let(:tags) { %w[v0.2.14 v0.2.13 v0.2.11] }

  it "requires a tag" do
    expect { described_class.new("") }.to raise_error(Tfs::ReleaseDiff::Error, /tag is required/)
  end

  describe "previous tag and range" do
    it "diffs an existing tag against the immediately older release tag" do
      diff = described_class.new("v0.2.13", git: fake_git(tags: tags))
      expect(diff.previous_tag).to eq("v0.2.11")
      expect(diff.range).to eq("v0.2.11..v0.2.13")
    end

    it "has no previous tag for the oldest release" do
      diff = described_class.new("v0.2.11", git: fake_git(tags: tags))
      expect(diff.previous_tag).to be_nil
      expect(diff.range).to be_nil
    end

    it "diffs HEAD against the newest tag when the tag does not exist yet (dispatch ahead of tagging)" do
      diff = described_class.new("v0.2.15", git: fake_git(tags: tags))
      expect(diff.previous_tag).to eq("v0.2.14")
      expect(diff.range).to eq("v0.2.14..HEAD")
    end

    it "treats the first-ever release as everything-changed" do
      diff = described_class.new("v0.0.1", git: fake_git(tags: []))
      expect(diff.previous_tag).to be_nil
      expect(diff.patch_lines).to be_nil
      expect(diff.shared_change?).to be(true)
      expect(diff.versions_manifest_changed?).to be(true)
    end
  end

  describe "change classification" do
    def diff_with(paths)
      described_class.new("v0.2.14", git: fake_git(tags: tags, diffs: { "v0.2.13..v0.2.14" => paths.join("\n") }))
    end

    it "maps patches/<line>/ paths to their line, once" do
      diff = diff_with(["patches/4.0/prism_compile_memfs.patch", "patches/4.0/other.patch", "patches/3.2/x.patch"])
      expect(diff.patch_lines).to eq(%w[4.0 3.2])
      expect(diff.shared_change?).to be(false)
    end

    it "sees versions.yml as a per-version input, never shared" do
      diff = diff_with(["versions.yml"])
      expect(diff.patch_lines).to eq([])
      expect(diff.versions_manifest_changed?).to be(true)
      expect(diff.shared_change?).to be(false)
    end

    it "treats the shared tooling trees as changing every line" do
      %w[tools/apply ci/include/tebako/fs/c_api.h schema/patches.schema.yml].each do |path|
        expect(diff_with([path]).shared_change?).to be(true), "expected #{path} to be a shared change"
      end
    end

    it "fails closed on paths it cannot attribute to a line (rebuilds every line)" do
      %w[README.md .github/workflows/release-src.yml patches/README.md Gemfile.lock].each do |path|
        expect(diff_with([path]).shared_change?).to be(true), "expected #{path} to be a shared change"
      end
    end

    it "reports no changes on an empty diff (re-run of an unchanged tree)" do
      diff = diff_with([])
      expect(diff.patch_lines).to eq([])
      expect(diff.shared_change?).to be(false)
      expect(diff.versions_manifest_changed?).to be(false)
    end
  end

  describe "#previous_file" do
    it "reads a file at the previous release tag" do
      git = fake_git(tags: tags, shows: { "v0.2.13:versions.yml" => "versions: {}\n" })
      expect(described_class.new("v0.2.14", git: git).previous_file("versions.yml")).to eq("versions: {}\n")
    end

    it "raises when there is no previous tag" do
      expect { described_class.new("v0.2.11", git: fake_git(tags: tags)).previous_file("versions.yml") }
        .to raise_error(Tfs::ReleaseDiff::Error, /no previous release tag/)
    end
  end
end
