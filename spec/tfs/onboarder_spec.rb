# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe Tfs::Onboarder do
  let(:releases) { Tfs::RubyReleases.new(File.read(File.join(SPEC_FIXTURES, "releases.html"))) }

  # Builds a scratch repo: versions.yml from the fixture, a 3.3 line
  # manifest with one real patch (tiny), a complete-partition family (gnu),
  # and a 3.3.7 overlay (exact_only). Cache is seeded with a runtime-built
  # tarball for the new version, so nothing touches the network.
  def build_repo(dir, with_bogus: false)
    FileUtils.cp(File.join(SPEC_FIXTURES, "versions.yml"), File.join(dir, "versions.yml"))

    line_dir = File.join(dir, "patches", "3.3")
    FileUtils.mkdir_p(line_dir)
    FileUtils.cp(File.join(SPEC_FIXTURES, "patches", "9.9", "tiny.patch"), File.join(line_dir, "tiny.patch"))
    FileUtils.cp(File.join(SPEC_FIXTURES, "patches", "3.3", "gnu_3.patch"), File.join(line_dir, "gnu_3.patch"))
    FileUtils.cp(File.join(SPEC_FIXTURES, "patches", "3.3", "gnu_7.patch"), File.join(line_dir, "gnu_7.patch"))
    FileUtils.cp(File.join(SPEC_FIXTURES, "patches", "3.3", "exact_only.patch"), File.join(line_dir, "exact_only.patch"))

    manifest = ["version: \"3.3\"", "patches:",
                    "  - feature: tiny", "    file: tiny.patch",
                    "  - feature: gnu", "    file: gnu_3.patch", "    version: \"3\"",
                    "  - feature: gnu", "    file: gnu_3.patch", "    version: \"4\"",
                    "  - feature: gnu", "    file: gnu_3.patch", "    version: \"5\"",
                    "  - feature: gnu", "    file: gnu_3.patch", "    version: \"6\"",
                    "  - feature: gnu", "    file: gnu_7.patch", "    version: \"7\""]
    if with_bogus
      File.write(File.join(line_dir, "bogus.patch"), <<~PATCH)
        diff --git a/hello.txt b/hello.txt
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,3 +1,3 @@
        -this context does not exist in the fixture tree
        +patched
      PATCH
      manifest += ["  - feature: bogus", "    file: bogus.patch"]
    end
    File.write(File.join(line_dir, "patch-3.3.yaml"), manifest.join("\n") + "\n")
    File.write(File.join(line_dir, "patch-3.3.7.yaml"), <<~YAML)
      version: "3.3.7"
      patches:
        - feature: exact_only
          file: exact_only.patch
    YAML
  end

  def build_tarball(dir, version)
    src = File.join(dir, "ruby-#{version}")
    FileUtils.mkdir_p(File.join(src, "sub"))
    File.write(File.join(src, "hello.txt"), "line one\nline two\nline three\n")
    File.write(File.join(src, "sub", "inner.txt"), "inner file, untouched\n")
    tarball = File.join(dir, "ruby-#{version}.tar.gz")
    raise "tar failed" unless system("tar", "-czf", tarball, "-C", dir, "ruby-#{version}")

    tarball
  end

  def onboard_in(dir, version, with_bogus: false)
    build_repo(dir, with_bogus: with_bogus)
    cache = File.join(dir, "cache")
    FileUtils.mkdir_p(cache)
    tarball = build_tarball(dir, version)
    FileUtils.cp(tarball, File.join(cache, "ruby-#{version}.tar.gz"))
    result = described_class.new(releases: releases, repo_root: dir, cache_dir: cache).onboard(version)
    [result, tarball]
  end

  it "pins the new version into versions.yml and lints clean" do
    Dir.mktmpdir do |dir|
      result, tarball = onboard_in(dir, "3.3.8")

      expect(result).to be_applied
      expect(result.failing).to eq([])
      expect(result.written).to include(File.join(dir, "versions.yml"))

      text = File.read(File.join(dir, "versions.yml"))
      expect(text).to include("  3.3.8:\n")
      expect(text).to include("sha256: #{Digest::SHA256.file(tarball).hexdigest}")
      expect(text).to include("line: '3.3'")
      expect(text.index("  3.3.7:")).to be < text.index("  3.3.8:")
      expect(text.index("  3.3.8:")).to be < text.index("  3.4.1:")
    end
  end

  it "extends a complete-partition family to the new patch level" do
    Dir.mktmpdir do |dir|
      result, = onboard_in(dir, "3.3.8")

      expect(result).to be_applied
      expect(result.extended).to include("gnu")
      manifest = File.read(File.join(dir, "patches", "3.3", "patch-3.3.yaml"))
      expect(manifest).to match(/- feature: gnu\n    file: gnu_7\.patch\n    version: "8"/)
    end
  end

  it "carries the line's overlay forward when its patches apply" do
    Dir.mktmpdir do |dir|
      result, = onboard_in(dir, "3.3.8")

      expect(result).to be_applied
      overlay = File.join(dir, "patches", "3.3", "patch-3.3.8.yaml")
      expect(File.exist?(overlay)).to be(true)
      text = File.read(overlay)
      expect(text).to include('version: "3.3.8"')
      expect(text).to include("feature: exact_only")
    end
  end

  it "seeds a manifest for a new line from the nearest existing line" do
    Dir.mktmpdir do |dir|
      result, = onboard_in(dir, "3.4.2")

      expect(result).to be_applied
      seeded = File.join(dir, "patches", "3.4", "patch-3.4.yaml")
      text = File.read(seeded)
      expect(text).to include('version: "3.4"')
      expect(text).to include("file: ../3.3/tiny.patch")
      expect(text).not_to match(/version: "\d"/)
      expect(File.read(File.join(dir, "versions.yml"))).to include("  3.4.2:\n")
    end
  end

  it "fails loudly and restores every touched file when a patch does not apply" do
    Dir.mktmpdir do |dir|
      result, = onboard_in(dir, "3.3.8", with_bogus: true)

      expect(result).not_to be_applied
      expect(result.failing).to eq(["bogus.patch"])
      expect(result.written).to eq([])

      expect(File.read(File.join(dir, "versions.yml"))).not_to include("3.3.8")
      expect(File.read(File.join(dir, "patches", "3.3", "patch-3.3.yaml"))).not_to include('version: "8"')
      expect(File.exist?(File.join(dir, "patches", "3.3", "patch-3.3.8.yaml"))).to be(false)
    end
  end

  it "raises KeyError for a version that is not an official release" do
    Dir.mktmpdir do |dir|
      build_repo(dir)
      expect do
        described_class.new(releases: releases, repo_root: dir, cache_dir: dir).onboard("1.2.3")
      end.to raise_error(KeyError, /1\.2\.3/)
    end
  end
end
