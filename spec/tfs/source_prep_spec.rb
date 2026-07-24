# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::SourcePrep do
  let(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  # Selection over the committed fixture patch set (contains the real tiny
  # patch for the 9.9.9 fixture tree via patches/9.9/patch-9.9.yaml).
  let(:selection) { Tfs::PatchSelection.new(File.join(SPEC_FIXTURES, "patches")) }

  def prep_with(cache_dir, patches_root)
    described_class.new(versions: versions,
                        selection: Tfs::PatchSelection.new(patches_root),
                        cache_dir: cache_dir)
  end

  def seeded_cache(dir)
    cache = File.join(dir, "cache")
    FileUtils.mkdir_p(cache)
    FileUtils.cp(File.join(SPEC_FIXTURES, "ruby-9.9.9.tar.gz"), cache)
    cache
  end

  # Builds a one-line manifest layout: <dir>/patches/9.9/patch-9.9.yaml
  # listing the given patch file, written next to it.
  def write_single_patch_layout(dir, patch_name, patch_text)
    line_dir = File.join(dir, "patches", "9.9")
    FileUtils.mkdir_p(line_dir)
    File.write(File.join(line_dir, patch_name), patch_text)
    File.write(File.join(line_dir, "patch-9.9.yaml"), <<~YAML)
      version: "9.9"
      patches:
        - feature: #{File.basename(patch_name, ".patch")}
          file: #{patch_name}
    YAML
    File.join(dir, "patches")
  end

  it "fetches from cache, verifies, extracts and applies the version's patch set" do
    Dir.mktmpdir do |dir|
      prep = described_class.new(versions: versions, selection: selection, cache_dir: seeded_cache(dir))
      outdir = File.join(dir, "out")
      tree = prep.prepare("9.9.9", outdir, platform: "linux-gnu", pass: 2)

      expect(tree).to eq(File.join(outdir, "tfs-ruby-9.9.9-src"))
      expect(File.read(File.join(tree, "hello.txt"))).to eq("line one\nline two (tebako patched)\nline three\n")
      expect(File.read(File.join(tree, "sub", "inner.txt"))).to eq("inner file, untouched\n")
    end
  end

  it "checks patches against the pristine tree without modifying it" do
    Dir.mktmpdir do |dir|
      prep = described_class.new(versions: versions, selection: selection, cache_dir: seeded_cache(dir))
      checked = prep.check("9.9.9", File.join(dir, "out"))

      expect(checked).to eq(["tiny.patch"])
      pristine = File.join(dir, "out", "ruby-9.9.9", "hello.txt")
      expect(File.read(pristine)).to eq("line one\nline two\nline three\n")
    end
  end

  it "defers a patch whose target file is not in the pristine tree" do
    Dir.mktmpdir do |dir|
      patches = write_single_patch_layout(dir, "deferred.patch", <<~PATCH)
        diff --git a/nope.txt b/nope.txt
        --- a/nope.txt
        +++ b/nope.txt
        @@ -1 +1 @@
        -old
        +new
      PATCH
      prep = prep_with(seeded_cache(dir), patches)

      expect do
        prep.prepare("9.9.9", File.join(dir, "out"), platform: "linux-gnu", pass: 2)
      end.to output(/DEFER 9\.9\.9 deferred\.patch/).to_stderr
    end
  end

  it "fails loudly naming version and patch when a patch does not apply" do
    Dir.mktmpdir do |dir|
      patches = write_single_patch_layout(dir, "bogus.patch", <<~PATCH)
        diff --git a/hello.txt b/hello.txt
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,3 +1,3 @@
        -this context does not exist in the fixture tree
        +patched
      PATCH
      prep = prep_with(seeded_cache(dir), patches)

      expect do
        prep.prepare("9.9.9", File.join(dir, "out"), platform: "linux-gnu", pass: 2)
      end.to raise_error(Tfs::SourcePrep::ApplyError, /FAIL 9\.9\.9 bogus\.patch/)
    end
  end

  it "applies patches even when the output tree sits inside a git work tree" do
    Dir.mktmpdir do |dir|
      # CI checks the workflow repo out at $GITHUB_WORKSPACE and builds under
      # it: git apply then resolves patch paths against that enclosing
      # repository root and silently SKIPS every target (exit 0, pristine
      # tree). The apply must be walled off from any enclosing work tree.
      system("git", "init", "-q", dir) || raise("git init failed")
      prep = described_class.new(versions: versions, selection: selection, cache_dir: seeded_cache(dir))
      tree = prep.prepare("9.9.9", File.join(dir, "out"), platform: "linux-gnu", pass: 2)

      expect(File.read(File.join(tree, "hello.txt"))).to include("(tebako patched)")
    end
  end

  it "rejects a cached tarball whose sha256 does not match the manifest" do
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      FileUtils.mkdir_p(cache)
      File.write(File.join(cache, "ruby-9.9.9.tar.gz"), "corrupted bytes")
      prep = described_class.new(versions: versions, selection: selection, cache_dir: cache)

      # the corrupt entry is discarded and re-downloaded; the dead fixture
      # URL (127.0.0.1:1) makes the download fail without any real network
      expect do
        prep.prepare("9.9.9", File.join(dir, "out"), platform: "linux-gnu", pass: 2)
      end.to raise_error(Tfs::SourcePrep::DownloadError, /9\.9\.9/)
    end
  end

  it "raises KeyError for a version outside the manifest" do
    Dir.mktmpdir do |dir|
      prep = described_class.new(versions: versions, selection: selection, cache_dir: dir)
      expect do
        prep.prepare("8.8.8", File.join(dir, "out"), platform: "linux-gnu", pass: 2)
      end.to raise_error(KeyError, /8\.8\.8/)
    end
  end
end
