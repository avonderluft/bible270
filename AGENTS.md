# Agent instructions

## Releases belong to the maintainer

The maintainer manages versions, tags, and gem publication with `gem-release`.

- Never bump or change the gem version, create or modify release tags, publish the gem, or trigger a release workflow.
- Do not run release commands such as `gem bump`, `gem release`, or `rake release`.
- Keep pending release notes under **Unreleased**. Branching, committing, and testing are not release actions.
