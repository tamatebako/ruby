# frozen_string_literal: true

module Tfs
  # The release-src build/copy plan: which (version x scenario build) legs
  # must COMPILE for the tag being published, and which are CARRIED FORWARD
  # from the previous release as sha256-verified copies (tools/copy_asset).
  # Fault isolation: a patches/<line>/ change re-spends only that line's
  # versions, a shared tooling change correctly re-spends everything, and a
  # versions.yml change re-spends exactly the versions whose entry moved
  # (a new version has no previous asset to copy, so it always builds).
  #
  # The release's asset set stays complete either way — consumers fetch the
  # full matrix from any tag.
  class BuildPlan
    # versions:             Tfs::Versions of the tag being published.
    # diff:                 Tfs::ReleaseDiff for the tag being published.
    # previous_versions:    Tfs::Versions parsed at the previous release
    #                       tag; nil only when the diff has no previous tag.
    def initialize(versions:, diff:, previous_versions: nil)
      if diff.previous_tag && previous_versions.nil?
        raise ArgumentError, "previous_versions is required when the diff has a previous release tag"
      end

      @versions = versions
      @diff = diff
      @previous_versions = previous_versions
    end

    # Build rows in Versions#builds shape plus the asset/tree names the
    # release-src legs package (the naming rule lives here, not in YAML).
    def builds
      rows_for(:build).map do |row|
        entry = @versions.fetch(row[:version])
        row.merge(tree: entry.src_tree_name, asset: asset_name(row))
      end
    end

    # Copy rows: one per unchanged (version x scenario build) asset.
    def copies
      rows_for(:copy).map { |row| row.slice(:version, :suffix).merge(asset: asset_name(row)) }
    end

    private

    def rows_for(action)
      wanted = @versions.select { |entry| (action == :build) == build?(entry) }.map(&:name)
      @versions.builds.select { |row| wanted.include?(row[:version]) }
    end

    def asset_name(row)
      "#{@versions.fetch(row[:version]).src_tree_name}#{row[:suffix]}.tar.gz"
    end

    def build?(entry)
      return true if @diff.previous_tag.nil?
      return true if @diff.shared_change?
      return true if @diff.patch_lines.include?(entry.line)

      previous = previous_entry(entry.name)
      previous.nil? || state(previous) != state(entry)
    end

    def previous_entry(name)
      @previous_versions&.fetch(name)
    rescue KeyError
      nil
    end

    def state(entry)
      [entry.url, entry.sha256, entry.line, entry.scenarios]
    end
  end
end
