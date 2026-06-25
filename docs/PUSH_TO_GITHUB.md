# Pushing DeskLink to GitHub

The repo is ready to push as-is. Pick one of the two options below. Once it's on
GitHub, the **Actions** tab builds the iOS IPA automatically (see
[`INSTALL_IOS.md`](INSTALL_IOS.md)).

> **Make it public.** GitHub Actions is **free and unlimited on public repos**,
> including the macOS runners that build the iOS app. On a private repo the free
> tier is 2,000 Linux minutes/month and **macOS counts at 10×** (~200 effective
> minutes), which an iOS build burns through in a few runs. The commands below
> use `--public`. There are no secrets/keys in this repo, so public is safe.

## Option A — GitHub CLI (easiest)

Install GitHub CLI (https://cli.github.com), then from the project folder:

```powershell
cd "C:\Users\dominicanish\Claude\Projects\DeskLink"
git init -b main
git add .
git commit -m "DeskLink v0.1: Windows audio server + iOS Liquid Glass client + CI"
gh auth login          # if not already authenticated
gh repo create DeskLink --public --source . --remote origin --push
```

That creates the repo under your account and pushes `main`.

## Option B — Manual

1. Create an empty repo on github.com named **DeskLink** (no README/license — this
   repo already has them).
2. From the project folder:

```powershell
cd "C:\Users\dominicanish\Claude\Projects\DeskLink"
git init -b main
git add .
git commit -m "DeskLink v0.1: Windows audio server + iOS Liquid Glass client + CI"
git remote add origin https://github.com/<your-username>/DeskLink.git
git push -u origin main
```

## After pushing

- Open the repo's **Actions** tab. The **iOS build** workflow runs on a macOS
  runner and, when finished, exposes a **`DeskLink-unsigned-ipa`** artifact to
  download. The **server** workflow lints and tests the Python on Linux.
- If `ios-build` doesn't trigger automatically, open it from the Actions tab and
  click **Run workflow** (it has `workflow_dispatch` enabled).

> Note: the first iOS build may need an Xcode version tweak in
> `.github/workflows/ios-build.yml` (`Xcode_26.app`) if GitHub's macOS runner
> image ships a different Xcode. The step falls back to the default Xcode, but
> Liquid Glass (`.glassEffect`) needs the iOS 26 SDK, so use a runner image that
> includes Xcode 26.
