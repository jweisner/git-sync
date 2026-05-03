# Releasing git-sync

## 1. Commit and tag

```sh
git add -A
git commit -m "your commit message"
git tag v1.x.0
```

## 2. Push to all remotes

```sh
git push origin main --tags
git push gitlab main --tags
git push codeberg main --tags
```

## 3. Create a GitHub release

```sh
gh release create v1.x.0 --title "v1.x.0" --generate-notes
```

## 4. Get the tarball SHA256

```sh
curl -sL https://github.com/jweisner/git-sync/archive/refs/tags/v1.x.0.tar.gz | sha256sum
```

## 5. Update the Homebrew tap

Clone or pull the tap repo:

```sh
cd /path/to/homebrew-git-sync   # or: gh repo clone jweisner/homebrew-git-sync
```

Edit `Formula/git-sync.rb` — update `url` and `sha256`:

```ruby
url "https://github.com/jweisner/git-sync/archive/refs/tags/v1.x.0.tar.gz"
sha256 "<sha256 from step 4>"
```

Commit and push:

```sh
git add Formula/git-sync.rb
git commit -m "Update git-sync to v1.x.0"
git push
```

## 6. Verify

```sh
brew update
brew upgrade git-sync
git-sync --help
```
