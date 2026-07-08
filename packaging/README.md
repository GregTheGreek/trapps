# Homebrew packaging

Trapps ships as a [Homebrew cask](https://docs.brew.sh/Cask-Cookbook) from a
personal tap so users can `brew install --cask gregthegreek/tap/trapps`.

`trapps.cask.tmpl` is the cask with `@@VERSION@@` / `@@SHA256@@` placeholders.
`make cask` renders it against the freshly built, notarized zip.

## Publishing a release to the tap

The tap is a separate repo named `GregTheGreek/homebrew-tap` (the `homebrew-`
prefix is what makes `brew tap gregthegreek/tap` resolve). Its casks live under
`Casks/`.

Prerequisite: a real notarized zip must already be attached to the GitHub
release (see the "Releasing" section in the top-level README) - the cask's
`sha256` is computed from it, and `brew install` downloads it from there.

```sh
make release && make notarize      # produces build/Trapps-<version>.zip
make cask                          # renders build/trapps.rb (version + sha256 filled in)

# One time, if the tap does not exist yet:
#   create the public repo GregTheGreek/homebrew-tap with a Casks/ dir.

# Copy the rendered cask into the tap and push:
cp build/trapps.rb /path/to/homebrew-tap/Casks/trapps.rb
# commit + push in the tap repo
```

Until the tap exists and a notarized asset is published, `brew install` will
not work - this directory is staged ahead of an Apple Developer account
clearing review.
