# frozen_string_literal: true

require "open3"

module Tfs
  # The diff model behind release-src's per-line rebuild decisions: what
  # changed between the previous release tag and the tag being published
  # (or HEAD when that tag does not exist yet — a manual dispatch ahead of
  # tagging; every line when there is no previous tag).
  #
  # A version's source tarball is a function of exactly these inputs:
  #
  # * patches/<line>/**  — the line's patch set (a PER-LINE input)
  # * versions.yml       — the version's own url/sha256/line/scenarios
  #                        entry (a PER-VERSION input)
  # * tools/**, ci/**, schema/** — the shared machinery (apply, validate,
  #                        smoke): a change rebuilds EVERY line, correctly
  #
  # Any other changed path cannot be attributed to a line by construction,
  # so it counts as shared too (fail closed: an unrecognized input rebuilds
  # the full matrix rather than shipping possibly-stale verified copies).
  #
  # Consumers: tools/smoke_matrix (the compile-smoke gate — patch sets
  # only, shared tooling does not change what a patched .c compiles to) and
  # tools/build_matrix (the build/copy plan — patch lines + shared inputs +
  # per-version versions.yml entries).
  class ReleaseDiff
    # Release tags (v0.2.x), newest first.
    TAG_LIST_ARGS = %w[tag --list v* --sort=-version:refname].freeze

    LINE_PATH = %r{\Apatches/(\d+\.\d+)/}.freeze
    VERSIONS_MANIFEST = "versions.yml"

    # Raised on any git failure (named — never a silent fallback).
    class Error < StandardError; end

    # The production git runner: #call(*args) -> stdout, raises Error on
    # failure. Specs inject a fake responding to #call the same way.
    class Git
      def call(*args)
        out, err, status = Open3.capture3("git", *args)
        raise Error, "git #{args.join(' ')} failed: #{err.strip}" unless status.success?

        out
      end
    end

    def initialize(tag, git: Git.new)
      raise Error, "a release tag is required" if tag.nil? || tag.to_s.empty?

      @tag = tag
      @git = git
    end

    # The release tag immediately older than the one being published — the
    # diff base, and the copy source for unchanged versions. Nil when there
    # is no older release tag (the first release builds everything).
    def previous_tag
      return @previous_tag if defined?(@previous_tag)

      tags = release_tags
      @previous_tag =
        if tags.include?(@tag)
          tags[(tags.index(@tag) + 1)..]&.first
        else
          tags.first
        end
    end

    # "<previous>..<tag>" for a published tag, "<previous>..HEAD" ahead of
    # tagging; nil when there is no previous tag.
    def range
      previous_tag && "#{previous_tag}..#{release_tags.include?(@tag) ? @tag : 'HEAD'}"
    end

    # Paths changed in the range; empty on the first release.
    def changed_paths
      @changed_paths ||=
        if range.nil?
          []
        else
          @git.call("diff", "--name-only", range).lines.map(&:strip).reject(&:empty?)
        end
    end

    # Lines whose patch set changed. Nil means "every line" (no previous
    # tag — smoke/build everything).
    def patch_lines
      return nil if previous_tag.nil?

      changed_paths.filter_map { |path| path[LINE_PATH, 1] }.uniq
    end

    # A shared input changed (or there is no previous tag): every line
    # rebuilds. Only patches/<line>/** and versions.yml are attributable
    # inputs; anything else — tools/**, ci/**, schema/**, workflows, a
    # patches/ file outside a line directory — is shared by construction.
    def shared_change?
      return true if previous_tag.nil?

      changed_paths.any? { |path| shared_path?(path) }
    end

    # versions.yml changed at all (per-entry comparison in Tfs::BuildPlan
    # decides which versions actually rebuild).
    def versions_manifest_changed?
      return true if previous_tag.nil?

      changed_paths.include?(VERSIONS_MANIFEST)
    end

    # A file's content at the previous release tag (the previous
    # versions.yml feeding the per-entry comparison).
    def previous_file(path)
      raise Error, "no previous release tag — nothing to read #{path} from" if previous_tag.nil?

      @git.call("show", "#{previous_tag}:#{path}")
    end

    private

    def release_tags
      @release_tags ||= @git.call(*TAG_LIST_ARGS).lines.map(&:strip).reject(&:empty?)
    end

    def shared_path?(path)
      !(path.match?(LINE_PATH) || path == VERSIONS_MANIFEST)
    end
  end
end
