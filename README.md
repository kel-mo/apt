# kel-mo/apt

A development apt repository for aptosid, served at
<https://kel-mo.github.io/apt/>. It carries CI builds of the fullstory
packages plus pre-release builds, mostly for Kel's own testing and the
nightly ISO builds. It is not the aptosid repository: slh builds
and signs the official packages himself, and nothing here is ever
uploaded there.

## Using it

Put the source file in place and update:

    sudo curl -fsSLo /etc/apt/sources.list.d/kel-mo-apt.sources \
        https://kel-mo.github.io/apt/kel-mo-apt.sources
    sudo apt update

There is one suite, `sid`, with the component `main` for amd64 and
arm64, plus sources. The repository's public key is embedded in the
file's `Signed-By` field, so apt trusts that key for this repository
only, and no keyring package is needed.

Think about what that trust means before adding it. Whoever can sign for
a repository decides what apt installs as root on your machine. Here
that is the dev key below, which lives in this repository's Actions
secrets and signs whatever the publish run picks up. So in practice the
people you trust are those who can change or run this repository's
workflows, and those who can push a `debian/*` tag to any repository in
`repos.txt`. Use it on machines you test on, not on ones
you depend on.

## What it serves

`publish.yml` runs every hour, and whenever a build finishes. It takes
the newest `debian/*` Release of each repository in `repos.txt`, plus
this repository's own `pre/*` Releases. Every file must carry a GitHub
build provenance attestation made by the signer workflow named at the
top of `publish.sh`, for the repository the Release belongs to; one that
does not fails the run and nothing is deployed.

For each source the highest version wins, and the CI build wins a tie.
The repository is rebuilt from scratch with reprepro on each change and
signed with the dev key. `state.txt` on the site records what was
published, so a run that finds nothing new deploys nothing. The run also
deletes `pre/` Releases, and their tags, once their version is at or
below the source's newest CI release.

`publish.sh` does all of this and runs locally too; see its header for
the options and environment overrides. Debian's `gh` has no
`attestation` command, so there it checks the attestations with cosign
instead.

## Versions

A pre-release build must sort below the release that follows it, so that release replaces it without anyone removing it. Take the top
changelog version V: if its entry is still UNRELEASED, use
`V~pre<UTC %Y%m%d%H%M>.g<sha7>`; if V is already released, use
`V+pre…`. Release tags here are `pre/<source>/<version>`, with the
version mangled as in DEP-14 (`:` becomes `%`, `~` becomes `_`).

## Pre-release builds

A pre-release build of any public branch or commit:

    gh workflow run pre -R kel-mo/apt -f repo=fll-live-boot -f ref=<branch>

linux-aptosid is a debian-only tree, so its pre-release needs the
`prepare` input to fetch and unpack the kernel source. `prepare/` holds
the same lines its caller in fullstory/linux-aptosid uses:

    gh workflow run pre -R kel-mo/apt -f repo=linux-aptosid -f ref=master \
      -f prepare="$(cat prepare/linux-aptosid)"

A patched Debian package builds the same way from a public packaging
branch outside fullstory: `owner` names its account, and `prepare`
fetches the orig and checks it against the checksum in Debian's .dsc.
plymouth carries an NMU on kel-mo/plymouth's `kelmo` branch:

    gh workflow run pre -R kel-mo/apt -f owner=kel-mo -f repo=plymouth \
      -f ref=kelmo -f prepare="$(cat prepare/plymouth)"

Its version comes out as `V+pre…`, so Debian's next upload replaces it:
rebase the branch onto that upload and update `prepare/plymouth`.

## The signing key

    pub   ed25519 2026-10-07 [SC] [expires: 2028-10-06]
          B6F34F99EB56F0CB09A944242DF4B4E8ADBAF6E8
    uid   aptosid dev repo (Kel) <kelvmod@gmail.com>

The key is used for this repository and nothing else. It is not Kel's
personal key. The secret key is the Actions secret `APT_SIGNING_KEY`,
with an offline backup. `kel-mo-apt.asc` and `kel-mo-apt.sources` carry
the public key.

The key expires on 2028-10-06. Renew it a month or two ahead: extend the
expiry (or make a new key), export the public key into both files, update
the secret, and tell consumers to fetch `kel-mo-apt.sources` again.
apt only knows the copy of the key embedded in their file, so the old
copy stops working on the expiry date even if the key was extended.

## The build workflow

Builds come from `fullstory/ci`'s reusable `deb.yml`, pinned at `v1`.
`publish.sh` trusts attestations signed by that workflow at that tag,
for CI releases and for this repository's own pre-releases alike. It
was piloted here as `.github/workflows/deb.yml` before it moved.
