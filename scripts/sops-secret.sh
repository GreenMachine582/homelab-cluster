#!/usr/bin/env bash
# scripts/sops-secret.sh
#
# Creates (or replaces) a SOPS-encrypted Kubernetes Secret in one step. Run in
# WSL from the root of the Windows (OneDrive) clone, then commit from Windows:
# WSL can't sign. See docs/SECRETS.md.
#
#   scripts/sops-secret.sh <file> <secret-name> <namespace> KEY=SOURCE [KEY=SOURCE...]
#
# SOURCE is one of:
#   gen[:N]          random, N characters (default 40) of A-Z a-z 0-9
#   ask              hidden prompt, asked twice
#   file:<path>      the contents of a file, e.g. a JSON credentials file
#   sops:<file>:<k>  key <k> copied out of another *.sops.yaml (needs the private key)
#
# Values only ever sit in a private temp directory, removed on exit. They are
# never on a command line or printed; only their lengths are.

set -euo pipefail

usage() {
  sed -n '8,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

die() { echo "sops-secret: $*" >&2; exit 1; }

[[ ${1:-} == -h || ${1:-} == --help ]] && usage 0
(( $# >= 4 )) || usage

file=$1 name=$2 namespace=$3
shift 3

[[ -f .sops.yaml ]] || die "run from the repo root (no .sops.yaml here)"
[[ $file == *.sops.yaml ]] || die "$file: the name must end in .sops.yaml, or .sops.yaml's rule won't encrypt it"
for tool in kubectl sops openssl; do
  command -v "$tool" >/dev/null || die "$tool isn't installed (HomeLab controller.yml -K installs it)"
done

tmp=$(mktemp -d)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

gen() {
  local n=$1 out=""
  while (( ${#out} < n )); do
    out+=$(openssl rand -base64 $(( n * 2 )) | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${out:0:n}"
}

from_files=()
for arg in "$@"; do
  [[ $arg == *=* ]] || die "'$arg': expected KEY=SOURCE"
  key=${arg%%=*} src=${arg#*=}
  [[ $key =~ ^[-._a-zA-Z0-9]+$ ]] || die "'$key' isn't a valid Secret key"
  out="$tmp/$key"
  case $src in
    gen)   gen 40 >"$out" ;;
    gen:*) n=${src#gen:}; [[ $n =~ ^[0-9]+$ ]] && (( n >= 16 )) || die "$key: gen:N needs N >= 16"
           gen "$n" >"$out" ;;
    ask)   read -rsp "$key: " v1; echo
           read -rsp "$key (again): " v2; echo
           [[ $v1 == "$v2" ]] || die "$key: the two entries differ"
           printf '%s' "$v1" >"$out"; unset v1 v2 ;;
    file:*) path=${src#file:}; [[ -r $path ]] || die "$key: can't read $path"
            cp -- "$path" "$out" ;;
    sops:*) rest=${src#sops:}; other=${rest%:*} okey=${rest##*:}
            [[ -f $other && $other != "$rest" ]] || die "$key: expected sops:<file>:<key>, got '$src'"
            sops -d --extract "[\"data\"][\"$okey\"]" "$other" | base64 -d >"$out" \
              || die "$key: couldn't read $okey from $other (is the age key at ~/.config/sops/age/keys.txt?)" ;;
    *)     die "$key: unknown source '$src' (gen, gen:N, ask, file:<path>, sops:<file>:<key>)" ;;
  esac
  [[ -s $out ]] || die "$key: the value is empty"
  echo "  $key: ${src%%:*}, $(wc -c <"$out" | tr -d ' ') characters"
  from_files+=(--from-file="$key=$out")
done

if [[ -e $file ]]; then
  read -rp "$file exists. Replace it? [y/N] " yes
  [[ $yes == [yY] ]] || die "left $file as it was"
fi
mkdir -p "$(dirname "$file")"

kubectl create secret generic "$name" -n "$namespace" "${from_files[@]}" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$file" --input-type yaml --output-type yaml /dev/stdin >"$tmp/out.yaml"

# Every value plus the sops MAC must be encrypted, and nothing under data
# may be left in the clear.
want=$(( $# + 1 ))
got=$(grep -c 'ENC\[' "$tmp/out.yaml" || true)
(( got >= want )) || die "only $got of $want values encrypted; $file not written"
if awk '/^data:/{d=1;next} /^[^ ]/{d=0} d && !/ENC\[/' "$tmp/out.yaml" | grep -q .; then
  die "a data value isn't encrypted; $file not written"
fi
mv "$tmp/out.yaml" "$file"

echo "Wrote $file ($# keys, encrypted). Commit it from Windows, and update docs/SECRETS.md."
