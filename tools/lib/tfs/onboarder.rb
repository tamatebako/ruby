# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"

module Tfs
  # Onboards one new official ruby release end-to-end:
  #   1. pin the release into versions.yml (official URL from the releases
  #      listing, sha256 of the fetched tarball, line);
  #   2. ensure the line has a patch manifest -- a NEW line is seeded from
  #      the nearest existing line's base manifest (whole-line entries,
  #      local files rewritten to ../<line>/ references);
  #   3. extend complete-partition features whose versioned entries stop
  #      short of the new patch level (candidate: the newest existing body;
  #      kept only if it applies);
  #   4. carry the line's nearest lower overlay forward (e.g. the ruby3x7
  #      onigmo/winmain fixes) as a new patch-<line>.<z>.yaml, kept only
  #      if its patches apply;
  #   5. lint: git apply --check of the whole selected set against the
  #      sha256-verified official tarball.
  # On any failure every touched file is restored; nothing is released
  # silently.
  class Onboarder
    # The outcome of one onboarding attempt.
    class Result
      def initialize(version:, applied:, failing:, written:, extended:)
        @version = version
        @applied = applied
        @failing = failing
        @written = written
        @extended = extended
      end

      attr_reader :version, :failing, :written, :extended

      def applied?
        @applied
      end

      def to_h
        { "version" => @version, "applied" => applied?, "failing" => @failing,
          "extended" => @extended, "written" => @written }
      end
    end

    DEFAULT_REPO_ROOT = File.expand_path("../../..", __dir__).freeze

    def initialize(releases:, repo_root: DEFAULT_REPO_ROOT, cache_dir: SourcePrep::DEFAULT_CACHE_DIR)
      @releases = releases
      @versions_path = File.join(repo_root, "versions.yml")
      @patches_root = File.join(repo_root, "patches")
      @cache_dir = cache_dir
    end

    def onboard(version_name)
      line, patchlevel = version_name.split(".").then { |parts| [parts[0..1].join("."), parts[2]] }
      originals = {}
      written = []
      release = @releases.entry(version_name)

      _tarball, sha256 = build_prep.fetch_tarball(release.url, "ruby-#{version_name}.tar.gz")
      add_version_entry(version_name, release.url, sha256, line, originals, written)
      ensure_line_manifest(line, originals, written)
      extended = extend_partitions(version_name, originals, written)

      candidates = overlay_candidates(line, patchlevel)
      outcomes = Dir.mktmpdir do |dir|
        build_prep.audit(version_name, dir, patches: selected_patches(version_name) + candidates)
      end

      failing = outcomes.select(&:failed?).map { |outcome| outcome.patch.name }
      applied = failing.empty?
      carry_overlay(line, patchlevel, candidates, originals, written) if applied && candidates.any?
      restore(originals) unless applied

      Result.new(version: version_name, applied: applied, failing: failing,
                 written: applied ? written.uniq : [], extended: extended)
    end

    private

    def build_prep
      SourcePrep.new(versions: Versions.new(@versions_path),
                   selection: PatchSelection.new(@patches_root),
                   cache_dir: @cache_dir)
    end

    def selected_patches(version_name)
      PatchSelection.new(@patches_root).for(version_name)
    end

    def stash(originals, path)
      originals[path] = File.exist?(path) ? File.read(path) : nil unless originals.key?(path)
    end

    def restore(originals)
      originals.each do |path, content|
        if content.nil?
          FileUtils.rm_f(path)
          dir = File.dirname(path)
          Dir.rmdir(dir) if File.directory?(dir) && Dir.empty?(dir)
        else
          File.write(path, content)
        end
      end
    end

    # --- versions.yml ------------------------------------------------------

    def add_version_entry(version_name, url, sha256, line, originals, written)
      text = File.read(@versions_path)
      return if text.match?(/^  #{Regexp.escape(version_name)}:$/)

      stash(originals, @versions_path)
      lines = text.lines
      entry = ["  #{version_name}:\n",
               "    url: #{url}\n",
               "    sha256: #{sha256}\n",
               "    line: '#{line}'\n"]
      idx = lines.index do |l|
        match = l.match(/^  (\d+\.\d+\.\d+):$/)
        match && Gem::Version.new(match[1]) > Gem::Version.new(version_name)
      end
      idx ? lines.insert(idx, *entry) : entry.each { |l| lines << l }
      File.write(@versions_path, lines.join)
      written << @versions_path
    end

    # --- line manifest seeding (new line) -----------------------------------

    def ensure_line_manifest(line, originals, written)
      path = File.join(@patches_root, line, "patch-#{line}.yaml")
      return if File.exist?(path)

      nearest = existing_lines
                .select { |candidate| Gem::Version.new(candidate) < Gem::Version.new(line) }
                .max_by { |candidate| Gem::Version.new(candidate) }
      raise PatchSelection::SelectionError, "no existing line to seed #{line} from" if nearest.nil?

      source = PatchManifest.new(File.join(@patches_root, nearest, "patch-#{nearest}.yaml"))
      out = ["# ruby #{line} patch manifest (canonical tfs-ruby layout).",
             "# Seeded from patch-#{nearest}.yaml by the release monitor; whole-line entries",
             "# reference their home files in #{nearest}.",
             "version: \"#{line}\"",
             "patches:"]
      source.entries.each do |entry|
        next unless entry.whole_line?

        file = entry.file.start_with?("../") ? entry.file : "../#{nearest}/#{entry.file}"
        out << "  - feature: #{entry.feature}"
        out << "    file: #{file}"
      end
      FileUtils.mkdir_p(File.dirname(path))
      stash(originals, path)
      File.write(path, out.join("\n") + "\n")
      written << path
    end

    def existing_lines
      Dir.children(@patches_root).select do |child|
        child.match?(/^\d+\.\d+$/) && File.directory?(File.join(@patches_root, child))
      end
    end

    # --- complete-partition extension ----------------------------------------

    def extend_partitions(version_name, originals, written)
      extended = []
      loop do
        begin
          selected_patches(version_name)
          return extended
        rescue PatchSelection::SelectionError => e
          raise if e.feature.nil?

          extend_entry(e.feature, version_name, originals, written)
          extended << e.feature
        end
      end
    end

    def extend_entry(feature, version_name, originals, written)
      line, patchlevel = version_name.split(".").then { |parts| [parts[0..1].join("."), parts[2]] }
      path = File.join(@patches_root, line, "patch-#{line}.yaml")
      stash(originals, path)

      entries = PatchManifest.new(path).entries.select { |entry| entry.feature == feature && !entry.whole_line? }
      if entries.empty?
        raise PatchSelection::SelectionError, "#{version_name}: cannot extend #{feature} (no versioned entries)"
      end

      newest = entries.max_by { |entry| entry.version.to_i }
      lines = File.read(path).lines
      anchor = lines.rindex { |l| l.strip == "- feature: #{feature}" }
      stop = anchor + 1
      stop += 1 while stop < lines.size && lines[stop].start_with?("    ")
      lines.insert(stop,
                   "  - feature: #{feature}\n",
                   "    file: #{newest.file}\n",
                   "    version: \"#{patchlevel}\"\n")
      File.write(path, lines.join)
      written << path
    end

    # --- overlay carry-forward ------------------------------------------------

    def overlay_candidates(line, patchlevel)
      return [] if File.exist?(File.join(@patches_root, line, "patch-#{line}.#{patchlevel}.yaml"))

      overlays = Dir.glob(File.join(@patches_root, line, "patch-#{line}.*.yaml")).filter_map do |path|
        overlay_z = path[/#{Regexp.escape(line)}\.(\d+)\.yaml\z/, 1]
        overlay_z if overlay_z && overlay_z.to_i < patchlevel.to_i
      end
      return [] if overlays.empty?

      nearest_z = overlays.max_by(&:to_i)
      manifest = PatchManifest.new(File.join(@patches_root, line, "patch-#{line}.#{nearest_z}.yaml"))
      line_dir = File.join(@patches_root, line)
      manifest.entries.map do |entry|
        PatchSelection::Patch.new(path: File.expand_path(entry.file, line_dir),
                                  feature: entry.feature, version: entry.version)
      end
    end

    def carry_overlay(line, patchlevel, candidates, originals, written)
      path = File.join(@patches_root, line, "patch-#{line}.#{patchlevel}.yaml")
      return if File.exist?(path)

      line_dir = File.join(@patches_root, line)
      stash(originals, path)
      out = ["# ruby #{line}.#{patchlevel} patch manifest (canonical tfs-ruby layout).",
             "# Carried forward by the release monitor (patches verified to apply to #{line}.#{patchlevel}).",
             "version: \"#{line}.#{patchlevel}\"",
             "patches:"]
      candidates.each do |patch|
        out << "  - feature: #{patch.feature}"
        out << "    file: #{Pathname.new(patch.path).relative_path_from(Pathname.new(line_dir))}"
      end
      File.write(path, out.join("\n") + "\n")
      written << path
    end
  end
end
