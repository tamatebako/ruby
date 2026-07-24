# frozen_string_literal: true

module Tfs
  # Implements the canonical patch-filename rule:
  #   tfs-ruby-<major>-<minor>-<seg>-<slug>.patch
  # where <seg> is "x" (whole major.minor line) or a patchlevel (exact
  # release only). A version's patch set is the line-wide patches of its
  # line plus the exact patchlevel matches; an exact patch SUPERSEDES the
  # same-slug line-wide patch for that version.
  class PatchSelection
    # One patch file, identified by its parsed filename.
    class Patch
      NAME_FORMAT = /\Atfs-ruby-(\d+)-(\d+)-(x|\d+)-(.+)\.patch\z/.freeze

      def self.parse(path, category)
        match = NAME_FORMAT.match(File.basename(path))
        raise ArgumentError, "malformed patch filename: #{path}" if match.nil?

        new(path: path, category: category, major: match[1], minor: match[2], segment: match[3], slug: match[4])
      end

      def initialize(path:, category:, major:, minor:, segment:, slug:)
        @path = path
        @category = category
        @major = major
        @minor = minor
        @segment = segment
        @slug = slug
      end

      attr_reader :path, :category, :major, :minor, :segment, :slug

      def name
        File.basename(@path)
      end

      def line
        "#{major}.#{minor}"
      end

      def line_wide?
        segment == "x"
      end

      def patchlevel
        segment unless line_wide?
      end

      # Target file inside the ruby source tree (from the patch header).
      def target_file
        @target_file ||= begin
          header = File.foreach(@path).find { |line| line.start_with?("+++ b/") }
          raise ArgumentError, "#{@path}: no '+++ b/' header found" if header.nil?

          header.strip.sub(%r{\A\+\+\+ b/}, "")
        end
      end
    end

    DEFAULT_ROOT = File.expand_path("../../../patches", __dir__).freeze

    # Platform suffixes used by slug convention (-msys / -darwin / -musl).
    # A slug without a platform suffix is platform-neutral, except when it
    # shares its target file with a platform-suffixed patch: then it is the
    # complementary variant (e.g. dir-c-memfs vs dir-c-memfs-msys).
    PLATFORM_SUFFIXES = %w[msys darwin musl].freeze
    PLATFORM_TAGS = {
      "linux" => nil, "linux-gnu" => nil,
      "darwin" => "darwin", "macos" => "darwin",
      "linux-musl" => "musl", "musl" => "musl",
      "msys" => "msys", "mingw" => "msys"
    }.freeze
    PASS_FORMAT = /-pass([12])(?:-|\z)/.freeze

    def initialize(patches_root = DEFAULT_ROOT)
      @patches = Dir.glob(File.join(patches_root, "*", "*.patch")).sort.map do |path|
        Patch.parse(path, File.basename(File.dirname(path)))
      end.freeze
    end

    attr_reader :patches

    # The ordered patch set for one version, e.g. for("3.3.7").
    # Filename rule: the line-wide patches of the version's line plus its
    # exact patchlevel matches, where an exact patch supersedes the
    # same-slug line-wide patch. Ordered by category then slug.
    #
    # With no scenario arguments the full union is returned (every variant;
    # suitable for checking each patch independently). With +platform:+
    # and/or +pass:+ the set is narrowed to one coherent build scenario:
    # platform-suffixed patches for other platforms are dropped, on msys the
    # neutral variants of msys-patched files are dropped too, and -pass1/-pass2
    # alternatives are reduced to the requested pass.
    def for(version_name, platform: nil, pass: nil)
      candidates = union(version_name)
      candidates = filter_platform(candidates, platform) unless platform.nil?
      candidates = filter_pass(candidates, pass) unless pass.nil?
      candidates
    end

    private

    def union(version_name)
      line, patchlevel = version_name.split(".").then { |parts| [parts[0..1].join("."), parts[2]] }
      of_line = @patches.select { |patch| patch.line == line }
      exact = of_line.select { |patch| patch.patchlevel == patchlevel }
      superseded = exact.map(&:slug)
      line_wide = of_line.select { |patch| patch.line_wide? && !superseded.include?(patch.slug) }
      (line_wide + exact).sort_by { |patch| [patch.category, patch.slug] }
    end

    def filter_platform(candidates, platform)
      tag = PLATFORM_TAGS.fetch(platform) { raise ArgumentError, "unknown platform #{platform.inspect}" }
      kept = candidates.reject do |patch|
        suffix = platform_suffix(patch)
        !suffix.nil? && suffix != tag
      end
      return kept unless tag == "msys"

      msys_targets = kept.select { |patch| platform_suffix(patch) == "msys" }.map(&:target_file).uniq
      kept.reject { |patch| platform_suffix(patch).nil? && msys_targets.include?(patch.target_file) }
    end

    def filter_pass(candidates, pass)
      wanted = pass.to_s
      raise ArgumentError, "pass must be 1 or 2" unless %w[1 2].include?(wanted)

      candidates.reject do |patch|
        match = PASS_FORMAT.match(patch.slug)
        !match.nil? && match[1] != wanted
      end
    end

    def platform_suffix(patch)
      PLATFORM_SUFFIXES.find { |suffix| patch.slug.end_with?("-#{suffix}") }
    end
  end
end
