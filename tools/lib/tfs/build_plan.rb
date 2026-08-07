# frozen_string_literal: true

module Tfs
  # The release-src build/copy plan: which (version x scenario build) legs
  # must COMPILE for the tag being published, and which are CARRIED FORWARD
  # from the previous release as sha256-verified copies (tools/copy_asset).
  # Fault isolation: a patches/<line>/ change re-spends only that line's
  # versions AND ONLY THE SCENARIOS THE CHANGED PATCHES FEED (an msys
  # patch never re-rolls a POSIX tarball — the attribution is
  # ReleaseDiff#changed_scenarios); a shared tooling change correctly
  # re-spends everything, and a versions.yml change re-spends exactly
  # the versions whose entry moved
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
    # `line:` narrows the plan to one line's rows (the per-line release
    # workflows each plan their own).
    def builds(line: nil)
      rows_for(:build, line).map do |row|
        entry = @versions.fetch(row[:version])
        row.merge(tree: entry.src_tree_name, asset: asset_name(row))
      end
    end

    # Copy rows: one per unchanged (version x scenario build) asset.
    def copies(line: nil)
      rows_for(:copy, line).map { |row| row.slice(:version, :suffix).merge(asset: asset_name(row)) }
    end

    private

    def rows_for(action, line = nil)
      @versions.builds.select do |row|
        (line.nil? || @versions.fetch(row[:version]).line == line) && (action == :build) == build_row?(row)
      end
    end

    def asset_name(row)
      "#{@versions.fetch(row[:version]).src_tree_name}#{row[:suffix]}.tar.gz"
    end

    # The row-level decision: the version-level reasons (first release,
    # shared tooling, the versions.yml entry moving) build every row of
    # the version; otherwise the row builds iff the line's changed
    # patches feed the row's scenario (and pass, when the change is
    # pass-scoped).
    def build_row?(row)
      return true if @diff.previous_tag.nil?
      return true if @diff.shared_change?

      entry = @versions.fetch(row[:version])
      previous = previous_entry(entry.name)
      return true if previous.nil? || state(previous) != state(entry)

      attributed_scenarios(entry.line).any? do |scenario, pass|
        scenario == row[:platform] && (pass.nil? || pass == row[:pass])
      end
    end

    # The line's changed-scenario list, failing CLOSED: a line the diff
    # saw patch changes for but attributes nothing to (a shape the
    # suffix rules do not produce today) feeds every scenario — never
    # ship a possibly-stale copy. An explicitly EMPTY attribution (a
    # darwin-only change — no shipped scenario) builds nothing.
    def attributed_scenarios(line)
      scenarios = @diff.changed_scenarios
      return all_scenarios if scenarios.nil?

      rows = scenarios.fetch(line, nil)
      return rows unless rows.nil?

      @diff.patch_lines&.include?(line) ? all_scenarios : []
    end

    def all_scenarios
      Tfs::Versions::SCENARIOS.map { |scenario| [scenario, nil] }
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
