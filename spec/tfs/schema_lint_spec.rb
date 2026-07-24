# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::SchemaLint do
  it "validates the repository's versions.yml and every patch manifest" do
    expect(described_class.new.errors).to eq([])
  end

  it "names the offending manifest and rule on violations" do
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "patch-1.1.yaml")
      File.write(bad, <<~YAML)
        version: "1.1"
        patches:
          - feature: ok_feature
            file: ok_feature.patch
          - file: missing-feature-name.patch
      YAML
      lint = described_class.new(targets: { File.join(Tfs::SchemaLint::SCHEMA_ROOT, "patches.schema.yml") => [bad] })
      expect(lint).not_to be_valid
      expect(lint.errors.first).to include(bad)
    end
  end
end
