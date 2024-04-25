#!/bin/bash

set -o pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG:-}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-true}

# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
if [[ "${source}" =~ ^\.$ ]]
then
    git config --global --add safe.directory "${GITHUB_WORKSPACE}"
else
    git config --global --add safe.directory "${GITHUB_WORKSPACE}/${source}"
fi

cd "${GITHUB_WORKSPACE}/${source}" || exit

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"
echo -e "\tGITHUB_WORKSPACE: ${GITHUB_WORKSPACE}"

prefix=""
if ${with_v}
then
    prefix="v"
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    echo "Is ${b} a match for ${current_branch}"
    if [[ "${current_branch}" =~ ${b} ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = ${pre_release}"

# fetch tags
git fetch --tags

tagFmt="^${prefix}[0-9]+\.[0-9]+\.[0-9]+$"
preTagFmt="^${prefix}[0-9]+\.[0-9]+\.[0-9]+(-${suffix}\.[0-9]+)?$"

# get latest tag that looks like a semver (with or without v)
case "${tag_context}" in
    *repo*)
        mapfile -t taglist < <(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "${tagFmt}")
        tag="${prefix}$(semver "${taglist[@]}" | tail -n 1)"

        mapfile -t pre_taglist < <(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "${preTagFmt}")
        pre_tag="${prefix}$(semver "${pre_taglist[@]}" | tail -n 1)"
        ;;
    *branch*)
        mapfile -t taglist < <(git tag --list --merged HEAD --sort=-v:refname | grep -E "${tagFmt}")
        tag="${prefix}$(semver "${taglist[@]}" | tail -n 1)"

        mapfile -t taglist < <(git tag --list --merged HEAD --sort=-v:refname | grep -E "${preTagFmt}")
        pre_tag="${prefix}$(semver "${pre_taglist[@]}" | tail -n 1)"
        ;;
    * )
        echo "Unrecognised context";
        exit 1
        ;;
esac


# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [[ -z "${tag}" ]]
then
    log=$(git log --pretty='%B')
    tag="${initial_version}"
    if [[ -z "${pre_tag}" ]] && ${pre_release}
    then
      pre_tag="${initial_version}"
    fi
else
    log=$(git log "${tag}"..HEAD --pretty='%B')
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 "${tag}")

# get current commit hash
commit=$(git rev-parse HEAD)

if [[ "${tag_commit}" == "${commit}" ]]
then
    echo "No new commits since previous tag. Skipping..."
    echo "tag=${tag}" >> "${GITHUB_OUTPUT}"
    exit 0
fi

# echo log if verbose is wanted
if ${verbose}
then
  echo "${log}"
fi

case "${log}" in
    *#major* ) new=$(semver -i major "${tag}"); part="major";;
    *#minor* ) new=$(semver -i minor "${tag}"); part="minor";;
    *#patch* ) new=$(semver -i patch "${tag}"); part="patch";;
    *#none* )
        echo "Default bump was set to none. Skipping..."
        echo "new_tag=${tag}" >> "${GITHUB_OUTPUT}"
        echo "tag=${tag}" >> "${GITHUB_OUTPUT}"
        exit 0
        ;;
    * )
        if [[ "${default_semvar_bump}" == "none" ]]
        then
            echo "Default bump was set to none. Skipping..."
            echo "new_tag=${tag}" >> "${GITHUB_OUTPUT}"
            echo "tag=${tag}" >> "${GITHUB_OUTPUT}"
            exit 0
        else
            new=$(semver -i "${default_semvar_bump}" "${tag}"); part=${default_semvar_bump}
        fi
        ;;
esac

if ${pre_release}
then
    # Already a prerelease available, bump it
    if [[ "${pre_tag}" == *"${new}"* ]]
    then
        new=$(semver -i prerelease "${pre_tag}" --preid "${suffix}"); part="pre-${part}"
    else
        new="${new}-${suffix}.1"; part="pre-${part}"
    fi
fi

echo "${part}"

# prefix with 'v'
if ${with_v}
then
	new="v${new}"
fi

if [[ -n "${custom_tag}" ]]
then
    echo "Use custom tag ${custom_tag} instead of ${new}"
    new="${custom_tag}"
fi

if ${pre_release}
then
    echo -e "Bumping tag ${pre_tag}. \n\tNew tag ${new}"
else
    echo -e "Bumping tag ${tag}. \n\tNew tag ${new}"
fi

# set outputs
echo "new_tag=${new}" >> "${GITHUB_OUTPUT}"
echo "part=${part}" >> "${GITHUB_OUTPUT}"

# use dry run to determine the next tag
if ${dryrun}
then
    echo "tag=${tag}" >> "${GITHUB_OUTPUT}"
    exit 0
fi

echo "tag=${new}" >> "${GITHUB_OUTPUT}"

# create local git tag
git tag "${new}"

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=${GITHUB_REPOSITORY}
git_refs_url=$(jq .repository.git_refs_url "${GITHUB_EVENT_PATH}" | tr -d '"' | sed 's/{\/sha}//g')

echo "${dt}: **pushing tag ${new} to repo ${full_name}"

git_refs_response=$(
curl -s -X POST "${git_refs_url}" \
-H "Authorization: token ${GITHUB_TOKEN}" \
-d @- << EOF

{
  "ref": "refs/tags/${new}",
  "sha": "${commit}"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [[ "${git_ref_posted}" == "refs/tags/${new}" ]]
then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
