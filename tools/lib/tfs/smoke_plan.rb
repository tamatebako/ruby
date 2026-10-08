# frozen_string_literal: true

module Tfs
  # The compile-smoke leg plan (release-src's publish gate): one
  # representative leg per (changed line x affected scenario) at the
  # line's NEWEST version, computing from the same Tfs::ReleaseDiff the
  # build/copy plan uses.
  #
  # Two fault-isolation axes, both from the diff:
  #
  # * line: only lines whose patch set changed smoke at all;
  # * scenario: only the scenarios the changed patches FEED smoke
  #   (Tfs::ReleaseDiff#changed_scenarios — an msys patch never smokes
  #   linux). The universe is each version's shipped scenarios plus the
  #   smoke-only platforms (Tfs::Versions::SMOKE_ONLY_SCENARIOS): a
  #   darwin tree exists for every version (the base selection plus the
  #   _darwin features) even though no darwin tarball ships, so a
  #   darwin-only change smokes exactly the darwin leg and a base patch
  #   smokes every shipped scenario AND darwin.
  #
  # A line-wide patch set means a representative leg per (line, scenario)
  # covers the changed translation units; per-version legs would multiply
  # configure runs for no extra signal. msys legs compile at pass 2 (the
  # pass split selects GNUmakefile variants — no patched .c differs
  # between passes).
  class SmokePlan
    # versions: Tfs::Versions of the tag being published.
    # diff:     Tfs::ReleaseDiff for the tag being published.
    # line:     optional line filter ("3.4") — one line's legs only.
    def initialize(versions:, diff:, line: nil)
      @versions = versions
      @diff = diff
      @line = line
    end

    # The leg rows: {line:, version:, platform:} per (changed line x
    # affected scenario), the newest version of each.
    def legs
      per_line = @versions.flat_map do |entry|
        next [] unless include_entry?(entry)

        affected_scenarios(entry).map { |scenario| { line: entry.line, version: entry.name, platform: scenario } }
      end
      per_line.group_by { |leg| [leg[:line], leg[:platform]] }
              .map { |(_line, _platform), group| group.max_by { |leg| Gem::Version.new(leg[:version]) } }
    end

    private

    def include_entry?(entry)
      return false if @line && entry.line != @line
      return true if @diff.patch_lines.nil?

      @diff.patch_lines.include?(entry.line)
    end

    def affected_scenarios(entry)
      scenarios = @diff.changed_scenarios
      return smoke_universe(entry) if scenarios.nil?

      attributed = scenarios.fetch(entry.line, [])
      smoke_universe(entry) & attributed.map(&:first).uniq
    end

    # One version's smoke universe: the scenarios it ships plus the
    # smoke-only platforms — a darwin tree exists for every version
    # even though no darwin tarball ships.
    def smoke_universe(entry)
      entry.scenarios | Tfs::Versions::SMOKE_ONLY_SCENARIOS
    end
  end
end
