# frozen_string_literal: true

require "yaml"

module Tfs
  # The src-tarball provenance ledger — a cumulative, append-only YAML
  # record of every (asset, sha256) pair this factory has ever published,
  # carried as the `provenance.yaml` asset of every release.
  #
  # The model (ruby#100): the authoritative provenance of a runtime build is
  # the CONTENT DIGEST of each consumed tarball (tebako-runtime-ruby records
  # it as built_from.sources[].sha256; the deterministic-roll rule makes it
  # content-addressed). A release NAME is only fetch metadata — rolling
  # releases re-roll a tarball under the same version pin whenever the
  # line's patches move, and a deleted release leaves the recorded name
  # dangling. The ledger is what makes the digest verifiable after the
  # fact: once a pair is recorded it is never removed or altered, so a
  # re-rolled (or even deleted) tarball cannot silently invalidate a
  # published runtime's provenance.
  #
  # Invariants the publish gate asserts (release-src.yml):
  # - append-only: the previous release's ledger is an exact PREFIX of the
  #   new one (nothing dropped, nothing reordered, nothing re-attributed);
  # - completeness: every asset of the release being published is recorded.
  #
  # This class is the pure model: no network, no filesystem. Entry shape is
  # a plain hash — "asset", "sha256", "first_release" — so entries
  # serialize to YAML directly.
  class Provenance
    # Raised on any ledger violation, naming the offending entry.
    class Error < StandardError; end

    VERSION = 1
    ASSET_PATTERN = /\Atfs-ruby-\d+\.\d+\.\d+-src(?:-[a-z0-9-]+)?\.tar\.gz\z/
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    TAG_PATTERN = /\Av\d+\.\d+\.\d+\z/

    HEADER = <<~TEXT
      # tfs-ruby src-tarball provenance ledger — cumulative, append-only.
      # Every (asset, sha256) pair this factory has ever published, with the
      # release that FIRST carried those bytes. Published tarballs are
      # content-addressed (deterministic roll), so the sha256 is the
      # authoritative provenance of any downstream build input; this ledger
      # attests that the factory published it. Entries are never removed or
      # altered — the publish gate rejects a ledger that does not extend the
      # previous release's as an exact prefix.
    TEXT

    class << self
      # Parses and strictly validates a ledger document, returning its
      # entries. Every violation is a named error — a malformed ledger is
      # never silently trusted.
      def parse(text)
        document = YAML.safe_load(text)
        unless document.is_a?(Hash) && document.keys.sort == %w[entries version]
          raise Error, "provenance ledger must be a mapping of exactly version/entries"
        end
        unless document["version"] == VERSION
          raise Error, "provenance ledger version #{document['version'].inspect} (this reader understands #{VERSION})"
        end

        entries = document["entries"]
        raise Error, "provenance ledger entries must be an array" unless entries.is_a?(Array)

        seen = {}
        entries.each_with_index.map do |entry, index|
          validate_entry(entry, index)
          key = [entry["asset"], entry["sha256"]]
          if seen.key?(key)
            raise Error, "duplicate provenance entry ##{seen[key] + 1} and ##{index + 1}: " \
                         "#{entry['asset']} sha256 #{entry['sha256'][0, 12]}…"
          end
          seen[key] = index
          entry
        end
      end

      # Serializes entries to the published ledger form: the header comment
      # over the version/entries mapping, keys in canonical order.
      def serialize(entries)
        seen = {}
        entries.each_with_index do |entry, index|
          validate_entry(entry, index)
          key = [entry["asset"], entry["sha256"]]
          raise Error, "duplicate provenance entry: #{entry['asset']} sha256 #{entry['sha256'][0, 12]}…" if seen.key?(key)

          seen[key] = index
        end
        document = {
          "version" => VERSION,
          "entries" => entries.map do |entry|
            {
              "asset" => entry["asset"],
              "sha256" => entry["sha256"],
              "first_release" => entry["first_release"]
            }
          end
        }
        HEADER + YAML.dump(document)
      end

      # The entries one release's SHA256SUMS contributes: one per line,
      # first_release pinned to that release's tag. Malformed lines are a
      # named error (the published SHA256SUMS is machine-generated — a bad
      # line is a bug, never something to skip).
      def entries_from_sums(tag, sums_text)
        unless tag.is_a?(String) && tag.match?(TAG_PATTERN)
          raise Error, "malformed release tag #{tag.inspect} (want v<major>.<minor>.<patch>)"
        end

        sums_text.each_line.map do |line|
          sha256, file = line.strip.split(/\s+/, 2)
          asset = file&.sub(/\A\*/, "")
          unless sha256&.match?(/\A[0-9a-f]{64}\z/i) && asset&.match?(ASSET_PATTERN)
            raise Error, "malformed SHA256SUMS line in release #{tag}: #{line.strip.inspect}"
          end

          { "asset" => asset, "sha256" => sha256.downcase, "first_release" => tag }
        end
      end

      # Chains a previous ledger with one release's entries: pairs already
      # recorded keep their first_release; new pairs append (a re-rolled
      # tarball appends a new entry — the old bytes stay recorded forever).
      def chain(previous_entries, new_entries)
        recorded = previous_entries.map { |entry| [entry["asset"], entry["sha256"]] }.to_h { |key| [key, true] }
        appended = new_entries.reject { |entry| recorded.key?([entry["asset"], entry["sha256"]]) }
        previous_entries + appended
      end

      # The append-only assertion: the previous ledger must be an exact
      # prefix of the merged one. Raises naming the first divergence.
      def assert_prefix(previous_entries, merged_entries)
        previous_entries.each_with_index do |entry, index|
          next if merged_entries[index] == entry

          got = merged_entries[index]
          raise Error,
                "provenance ledger is not append-only: entry ##{index + 1} " \
                "(#{entry['asset']} sha256 #{entry['sha256'][0, 12]}…, first_release #{entry['first_release']}) " \
                "#{got.nil? ? 'was dropped' : "became #{got['asset']} sha256 #{got['sha256'][0, 12]}…"} — " \
                "a published digest must never be removed or altered"
        end
        true
      end

      # The completeness assertion: every entry of the release being
      # published must be recorded in the ledger. Raises naming the first
      # unrecorded asset.
      def assert_complete(ledger_entries, sums_entries)
        recorded = ledger_entries.map { |entry| [entry["asset"], entry["sha256"]] }.to_h { |key| [key, true] }
        sums_entries.each do |entry|
          next if recorded.key?([entry["asset"], entry["sha256"]])

          raise Error,
                "provenance ledger incomplete: #{entry['asset']} sha256 #{entry['sha256'][0, 12]}… " \
                "(release #{entry['first_release']}) is published but unrecorded"
        end
        true
      end

      # The audit lookup: every entry attesting this digest. Raises a named
      # error when the digest is unattested — loud, never a silent dangle.
      def verify(entries, sha256, source: "the ledger")
        unless sha256.is_a?(String) && sha256.match?(SHA256_PATTERN)
          raise Error, "malformed sha256 #{sha256.inspect} (want 64 lowercase hex)"
        end

        matches = entries.select { |entry| entry["sha256"] == sha256 }
        return matches unless matches.empty?

        raise Error,
              "sha256 #{sha256} is unattested in #{source}: no factory release ever published " \
              "these bytes — provenance is unresolvable, do not trust a build input claiming it"
      end

      private

      def validate_entry(entry, index)
        unless entry.is_a?(Hash) && entry.keys.sort == %w[asset first_release sha256]
          raise Error, "provenance entry ##{index + 1} must be a mapping of exactly asset/sha256/first_release"
        end
        unless entry["asset"].is_a?(String) && entry["asset"].match?(ASSET_PATTERN)
          raise Error, "provenance entry ##{index + 1}: malformed asset #{entry['asset'].inspect}"
        end
        unless entry["sha256"].is_a?(String) && entry["sha256"].match?(SHA256_PATTERN)
          raise Error, "provenance entry ##{index + 1} (#{entry['asset']}): malformed sha256 #{entry['sha256'].inspect}"
        end
        unless entry["first_release"].is_a?(String) && entry["first_release"].match?(TAG_PATTERN)
          raise Error, "provenance entry ##{index + 1} (#{entry['asset']}): malformed first_release #{entry['first_release'].inspect}"
        end
      end
    end
  end
end
