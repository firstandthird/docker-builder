#!/bin/bash

if [[ -z "$REPOS" ]]; then
  REPOS=/repos
fi

if [[ -z "$USER" ]]; then
  echo "github user must be passed in"
  exit 1
fi

if [[ -z "$REPO" ]]; then
  echo "github repo must be passed in"
  exit 1
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="master"
fi

if [[ -z "$DOCKERFILE" ]]; then
  DOCKERFILE=Dockerfile
fi

REPOPATH="${REPOS}/${USER}_${REPO}"

if [[ ! -d "$REPOPATH" ]]; then
  git clone --quiet https://token:${TOKEN}@github.com/${USER}/${REPO}.git $REPOPATH
fi

cd $REPOPATH

git fetch --quiet
git reset --hard --quiet origin/${BRANCH}
COMMIT=$(git log --pretty=format:"%h" -n 1)

IMAGE="${USER}_${REPO}_${BRANCH}:${COMMIT}"
IMAGE_ID=$(docker build . --quiet -f $DOCKERFILE -t $IMAGE)

if [[ "$?" != 0 ]]; then
  echo "error building"
  echo $IMAGE_ID
  exit 1
fi

echo $IMAGE

