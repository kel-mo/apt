#!/bin/sh
# publish.sh - build the kel-mo/apt site from verified GitHub Releases
#
# usage: publish.sh [-f] [-p] SITE
#   -f  build even if the state matches the live site's state.txt
#   -p  prune pre/ and hand/ releases at or below their source's CI release
#
# Sets changed=true|false in $GITHUB_OUTPUT when that is set. See README.md.

set -eu

# pinned to the v1 tag; the pilot was kel-mo/apt/.github/workflows/deb.yml
SIGNER=${SIGNER:-fullstory/ci/.github/workflows/deb.yml@refs/tags/v1}
# holds the pre/ and hand/ releases; empty skips them
SELF=${SELF-kel-mo/apt}
URL=${URL:-https://kel-mo.github.io/apt}
KEY=${KEY:-B6F34F99EB56F0CB09A944242DF4B4E8ADBAF6E8}
here=$(cd "$(dirname "$0")" && pwd)
REPOS=${REPOS:-$here/repos.txt}
ISSUER=https://token.actions.githubusercontent.com
tab=$(printf '\t')

die() {
	echo "publish: $*" >&2
	exit 1
}

output() {
	[ -z "${GITHUB_OUTPUT:-}" ] || echo "changed=$1" >> "$GITHUB_OUTPUT"
}

# DEP-14 tag part to version
version() {
	printf '%s\n' "$1" | tr '%_' ':~'
}

# id, tag and asset count of each published release of $1
releases() {
	gh api --paginate "repos/$1/releases?per_page=100" \
		--jq '.[] | select(.draft | not) | [.id, .tag_name, (.assets | length)] | @tsv' < /dev/null
}

# single-line field $2 of control file $1
field() {
	sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n 1
}

# sha256, size and name of each file a .changes lists
files() {
	awk '/^Checksums-Sha256:/ { on = 1; next }
		on && /^[ \t]/ { print $1, $2, $3; next }
		{ on = 0 }' "$1"
}

# file $2 carries a provenance attestation from $SIGNER for repo $1
verify() {
	if [ -n "$gh_attest" ]; then
		gh attestation verify "$2" --repo "$1" --signer-workflow "$SIGNER" \
			--deny-self-hosted-runners < /dev/null > "$work/err" 2>&1 && return
	else
		# Debian's gh has no attestation command; same checks via cosign
		set -- "$1" "$2" "$(sha256sum < "$2" | cut -d' ' -f1)"
		if gh api "repos/$1/attestations/sha256:$3" \
			--jq '.attestations[].bundle' < /dev/null > "$work/bundles" 2> "$work/err"; then
			while read -r b; do
				printf '%s\n' "$b" > "$work/bundle.json"
				cosign verify-blob-attestation --bundle "$work/bundle.json" \
					--new-bundle-format --type slsaprovenance1 \
					--certificate-oidc-issuer "$ISSUER" \
					--certificate-identity-regexp "$san" \
					--certificate-github-workflow-repository "$1" \
					"$2" < /dev/null > "$work/err" 2>&1 && return
			done < "$work/bundles"
		fi
	fi
	cat "$work/err" >&2
	return 1
}

force='' prune=''
while getopts fp opt; do
	case $opt in
	f) force=1 ;;
	p) prune=1 ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { echo "usage: publish.sh [-f] [-p] SITE" >&2; exit 2; }
[ ! -e "$1" ] || die "$1 exists"
site=$1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh_attest=''
if gh attestation --help > /dev/null 2>&1; then
	gh_attest=1
fi
# gh's --signer-workflow match, for cosign
san="^https://github\\.com/$(printf %s "$SIGNER" | sed 's/[][\\.*+?(){}|^$]/\\&/g')"
case $SIGNER in
*@*) san="$san\$" ;;
*) san="$san@(refs/.*|[0-9a-fA-F]+)\$" ;;
esac

# candidates: src version kind repo id tag assets
: > "$work/cand"
sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$REPOS" > "$work/repos"
while read -r repo; do
	releases "$repo" > "$work/rel"
	best='' bv=''
	while IFS=$tab read -r id tag n; do
		case $tag in debian/*) ;; *) continue ;; esac
		v=$(version "${tag#debian/}")
		dpkg --validate-version "$v" 2> /dev/null || { echo "publish: $repo $tag: bad version, skipped" >&2; continue; }
		if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$bv"; then
			bv=$v best="${repo##*/}$tab$v${tab}ci$tab$repo$tab$id$tab$tag$tab$n"
		fi
	done < "$work/rel"
	[ -z "$best" ] || printf '%s\n' "$best" >> "$work/cand"
done < "$work/repos"

if [ -n "$SELF" ]; then
	releases "$SELF" > "$work/rel"
	while IFS=$tab read -r id tag n; do
		case $tag in pre/*/*|hand/*/*) ;; *) continue ;; esac
		kind=${tag%%/*} rest=${tag#*/}
		src=${rest%%/*} v=$(version "${rest#*/}")
		dpkg --validate-version "$v" 2> /dev/null || { echo "publish: $SELF $tag: bad version, skipped" >&2; continue; }
		printf '%s\n' "$src$tab$v$tab$kind$tab$SELF$tab$id$tab$tag$tab$n" >> "$work/cand"
	done < "$work/rel"
fi

# per source the highest version wins, CI on a tie; ci sorts before hand and pre
sort -t "$tab" -k1,1 -k3,3 "$work/cand" > "$work/sorted"
: > "$work/win"
: > "$work/prune"
cur='' ci='' bv='' best=''
while IFS=$tab read -r src v kind repo id tag n; do
	if [ "$src" != "$cur" ]; then
		[ -z "$best" ] || printf '%s\n' "$best" >> "$work/win"
		cur=$src ci='' bv='' best=''
	fi
	if [ "$kind" = ci ]; then
		ci=$v
	elif [ -n "$ci" ] && dpkg --compare-versions "$v" le "$ci"; then
		printf '%s\t%s\n' "$id" "$tag" >> "$work/prune"
		continue
	fi
	if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$bv"; then
		bv=$v best="$src$tab$v$tab$kind$tab$repo$tab$id$tab$tag$tab$n"
	fi
done < "$work/sorted"
[ -z "$best" ] || printf '%s\n' "$best" >> "$work/win"

# by id: gh release delete puts the tag unescaped in the URL, breaking on %
while IFS=$tab read -r id tag; do
	if [ -z "$prune" ]; then
		echo "publish: would prune $SELF $tag"
		continue
	fi
	echo "publish: pruning $SELF $tag"
	gh api -X DELETE "repos/$SELF/releases/$id" < /dev/null
	gh api -X DELETE "repos/$SELF/git/refs/tags/$(printf %s "$tag" | sed 's/%/%25/g')" < /dev/null
done < "$work/prune"

{
	echo "key $KEY"
	echo "files $(cat "$here/publish.sh" "$here/kel-mo-apt.asc" "$here/kel-mo-apt.sources" | sha256sum | cut -c1-16)"
	awk -F "$tab" '{ print $4, $6, "id=" $5, "assets=" $7 }' "$work/win"
} > "$work/state"
cat "$work/state"
curl -fsSL "$URL/state.txt?t=$(date +%s)" -o "$work/live" 2> /dev/null || : > "$work/live"
if [ -z "$force" ] && cmp -s "$work/state" "$work/live"; then
	echo "publish: $URL is up to date"
	output false
	exit 0
fi

db=$work/db
out=$work/site
mkdir -p "$db/conf" "$out"
cat > "$db/conf/distributions" << EOF
Origin: kel-mo
Label: kel-mo/apt
Codename: sid
Architectures: amd64 arm64 source
Components: main
Description: aptosid development builds, not the official aptosid repo
DscIndices: Sources Release . .gz
SignWith: $KEY
EOF

while IFS=$tab read -r src v kind repo id tag n; do
	echo "publish: $src $v from $repo $tag"
	dl=$work/dl/$id stage=$work/stage/$id
	mkdir -p "$dl" "$stage"
	gh api --paginate "repos/$repo/releases/$id/assets?per_page=100" \
		--jq '.[] | [.id, .name] | @tsv' < /dev/null > "$work/assets"
	while IFS=$tab read -r aid name; do
		case $name in */*|.*|'') die "$repo $tag: odd asset name '$name'" ;; esac
		gh api -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$aid" < /dev/null > "$dl/$name"
	done < "$work/assets"
	# hand/ releases are trusted as Kel's uploads
	if [ "$kind" != hand ]; then
		for f in "$dl"/*; do
			verify "$repo" "$f" || die "$repo $tag: ${f##*/}: no attestation by $SIGNER"
		done
	fi
	# by digest: GitHub renames assets with ~ and other odd characters
	(cd "$dl" && sha256sum -- *) > "$work/sums"
	found=''
	for c in "$dl"/*.changes; do
		[ -e "$c" ] || break
		[ "$(field "$c" Source | cut -d' ' -f1)" = "$src" ] || die "$repo $tag: ${c##*/} is not $src"
		[ "$(field "$c" Version)" = "$v" ] || die "$repo $tag: ${c##*/} is not $v"
		files "$c" > "$work/files"
		while read -r sum size name; do
			case $name in */*|.*|'') die "$repo $tag: ${c##*/}: odd file name '$name'" ;; esac
			asset=$(awk -v s="$sum" '$1 == s { sub(/^[*]/, "", $2); print $2; exit }' "$work/sums")
			[ -n "$asset" ] || die "$repo $tag: ${c##*/} lists $name ($size bytes), not in the release"
			ln -f "$dl/$asset" "$stage/$name"
		done < "$work/files"
		cp "$c" "$stage/"
		reprepro --basedir "$db" --outdir "$out" --export=silent-never \
			--ignore=wrongdistribution include sid "$stage/${c##*/}"
		found=1
	done
	[ -n "$found" ] || die "$repo $tag: no .changes"
done < "$work/win"

reprepro --basedir "$db" --outdir "$out" export sid
cp "$here/kel-mo-apt.asc" "$here/kel-mo-apt.sources" "$out/"
: > "$out/.nojekyll"
cp "$work/state" "$out/state.txt"
mv "$out" "$site"
output true
echo "publish: built $site"
