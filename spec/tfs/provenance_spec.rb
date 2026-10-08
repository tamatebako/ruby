# frozen_string_literal: true

RSpec.describe Tfs::Provenance do
  let(:sha_a) { "a" * 64 }
  let(:sha_b) { "b" * 64 }
  let(:sha_c) { "c" * 64 }
  let(:entry_a) { { "asset" => "tfs-ruby-3.3.12-src.tar.gz", "sha256" => sha_a, "first_release" => "v0.2.21" } }
  let(:entry_b) { { "asset" => "tfs-ruby-3.3.12-src.tar.gz", "sha256" => sha_b, "first_release" => "v0.2.27" } }
  let(:entry_c) { { "asset" => "tfs-ruby-3.4.10-src.tar.gz", "sha256" => sha_c, "first_release" => "v0.2.21" } }

  describe ".parse + .serialize" do
    it "round-trips entries through the published document form" do
      entries = described_class.parse(described_class.serialize([entry_a, entry_b, entry_c]))
      expect(entries).to eq([entry_a, entry_b, entry_c])
    end

    it "emits the header comment and the version/entries mapping" do
      text = described_class.serialize([entry_a])
      expect(text).to start_with("# tfs-ruby src-tarball provenance ledger")
      expect(text).to include("version: 1\n")
    end

    it "rejects a document that is not exactly version/entries" do
      expect { described_class.parse("entries: []\n") }
        .to raise_error(Tfs::Provenance::Error, /must be a mapping of exactly version\/entries/)
      expect { described_class.parse("version: 1\nentries: []\nextra: true\n") }
        .to raise_error(Tfs::Provenance::Error, /must be a mapping of exactly version\/entries/)
    end

    it "rejects a ledger of an unknown version" do
      expect { described_class.parse("version: 2\nentries: []\n") }
        .to raise_error(Tfs::Provenance::Error, /version 2.*understands 1/)
    end

    it "rejects a non-array entries value" do
      expect { described_class.parse("version: 1\nentries: {}\n") }
        .to raise_error(Tfs::Provenance::Error, /entries must be an array/)
    end

    it "rejects an entry with a malformed asset, sha256, or first_release" do
      bad_asset = entry_a.merge("asset" => "ruby-3.3.12.tar.gz")
      expect { described_class.serialize([bad_asset]) }
        .to raise_error(Tfs::Provenance::Error, /entry #1: malformed asset/)

      bad_sha = entry_a.merge("sha256" => "abc")
      expect { described_class.serialize([bad_sha]) }
        .to raise_error(Tfs::Provenance::Error, /entry #1 \(tfs-ruby-3\.3\.12-src\.tar\.gz\): malformed sha256/)

      bad_tag = entry_a.merge("first_release" => "3.3.12")
      expect { described_class.serialize([bad_tag]) }
        .to raise_error(Tfs::Provenance::Error, /malformed first_release/)

      extra_key = entry_a.merge("note" => "hand-edited")
      expect { described_class.serialize([extra_key]) }
        .to raise_error(Tfs::Provenance::Error, /must be a mapping of exactly asset\/sha256\/first_release/)
    end

    it "rejects a duplicate (asset, sha256) pair, naming both positions" do
      expect { described_class.serialize([entry_a, entry_b, entry_a]) }
        .to raise_error(Tfs::Provenance::Error, /duplicate provenance entry.*tfs-ruby-3\.3\.12-src\.tar\.gz/)

      text = "version: 1\nentries:\n" \
             "- {asset: #{entry_a['asset']}, sha256: #{sha_a}, first_release: v0.2.21}\n" \
             "- {asset: tfs-ruby-3.4.10-src.tar.gz, sha256: #{sha_c}, first_release: v0.2.21}\n" \
             "- {asset: #{entry_a['asset']}, sha256: #{sha_a}, first_release: v0.2.22}\n"
      expect { described_class.parse(text) }
        .to raise_error(Tfs::Provenance::Error, /duplicate provenance entry #1 and #3/)
    end
  end

  describe ".entries_from_sums" do
    it "parses sha256sum lines, one entry per line pinned to the tag" do
      entries = described_class.entries_from_sums("v0.2.38", "#{sha_a}  tfs-ruby-3.3.12-src.tar.gz\n#{sha_c}  tfs-ruby-3.4.10-src.tar.gz\n")
      expect(entries).to eq([
                              { "asset" => "tfs-ruby-3.3.12-src.tar.gz", "sha256" => sha_a, "first_release" => "v0.2.38" },
                              { "asset" => "tfs-ruby-3.4.10-src.tar.gz", "sha256" => sha_c, "first_release" => "v0.2.38" }
                            ])
    end

    it "accepts the binary-mode marker and an uppercase sum" do
      entries = described_class.entries_from_sums("v0.2.38", "#{sha_a.upcase} *tfs-ruby-3.3.12-src.tar.gz\n")
      expect(entries).to eq([entry_a.merge("first_release" => "v0.2.38")])
    end

    it "rejects a malformed line, naming the release" do
      expect { described_class.entries_from_sums("v0.2.38", "#{sha_a}  not-a-tarball.txt\n") }
        .to raise_error(Tfs::Provenance::Error, /malformed SHA256SUMS line in release v0\.2\.38/)
    end

    it "rejects a malformed tag" do
      expect { described_class.entries_from_sums("latest", "#{sha_a}  tfs-ruby-3.3.12-src.tar.gz\n") }
        .to raise_error(Tfs::Provenance::Error, /malformed release tag "latest"/)
    end
  end

  describe ".chain" do
    it "appends new digests and keeps recorded pairs' first_release" do
      merged = described_class.chain([entry_a], [entry_b])
      expect(merged).to eq([entry_a, entry_b])
    end

    it "does not duplicate a carried-forward pair" do
      carry = entry_a.merge("first_release" => "v0.2.22")
      merged = described_class.chain([entry_a], [carry])
      expect(merged).to eq([entry_a])
    end

    it "is a prefix extension of the previous ledger" do
      previous = [entry_a, entry_c]
      merged = described_class.chain(previous, [entry_b])
      expect(merged.first(previous.size)).to eq(previous)
    end
  end

  describe ".assert_prefix" do
    it "passes when the previous ledger is an exact prefix" do
      expect(described_class.assert_prefix([entry_a], [entry_a, entry_b])).to be(true)
      expect(described_class.assert_prefix([], [entry_a])).to be(true)
    end

    it "raises naming the dropped entry" do
      expect { described_class.assert_prefix([entry_a, entry_b], [entry_a]) }
        .to raise_error(Tfs::Provenance::Error, /not append-only: entry #2 .*was dropped/)
    end

    it "raises on an altered entry, showing what it became" do
      replaced = entry_b.merge("first_release" => "v0.9.9")
      expect { described_class.assert_prefix([entry_a, entry_b], [entry_a, replaced]) }
        .to raise_error(Tfs::Provenance::Error, /not append-only: entry #2 .*became/)
    end

    it "raises on a reordered ledger" do
      expect { described_class.assert_prefix([entry_a, entry_b], [entry_b, entry_a]) }
        .to raise_error(Tfs::Provenance::Error, /not append-only: entry #1/)
    end
  end

  describe ".assert_complete" do
    it "passes when every published asset is recorded" do
      expect(described_class.assert_complete([entry_a, entry_b], [entry_b])).to be(true)
    end

    it "raises naming the first unrecorded asset" do
      expect { described_class.assert_complete([entry_a], [entry_b]) }
        .to raise_error(Tfs::Provenance::Error, /incomplete: tfs-ruby-3\.3\.12-src\.tar\.gz.*\(release v0\.2\.27\) is published but unrecorded/)
    end
  end

  describe ".verify" do
    it "returns every entry attesting the digest" do
      expect(described_class.verify([entry_a, entry_b], sha_a)).to eq([entry_a])
    end

    it "returns multiple entries when one digest ships under two assets" do
      twin = entry_a.merge("asset" => "tfs-ruby-3.3.12-src-linux-musl.tar.gz")
      expect(described_class.verify([entry_a, twin], sha_a)).to eq([entry_a, twin])
    end

    it "raises a named error on an unattested digest — loud, never a silent dangle" do
      expect { described_class.verify([entry_a], sha_b, source: "release v0.2.38") }
        .to raise_error(Tfs::Provenance::Error, /sha256 #{sha_b} is unattested in release v0\.2\.38.*provenance is unresolvable/)
    end

    it "rejects a malformed digest" do
      expect { described_class.verify([entry_a], "ABC") }
        .to raise_error(Tfs::Provenance::Error, /malformed sha256 "ABC"/)
    end
  end
end
