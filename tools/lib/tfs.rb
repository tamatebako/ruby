# frozen_string_literal: true

# TFS — tooling around the canonical tfs-ruby patch set.
#
# Namespace parent: declares every in-library child via autoload.
# In-library files never require each other.
module Tfs
  autoload :Versions, "tfs/versions"
  autoload :PatchSelection, "tfs/patch_selection"
  autoload :SourcePrep, "tfs/source_prep"
end
