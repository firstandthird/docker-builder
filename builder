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

PUSH=0
if [[ -d "/root/.docker" || -n "$REGISTRY" ]]; then
  PUSH=1
fi

REPOPATH="${REPOS}/${USER}_${REPO}"

log() {
  if [[ "$DEBUG" == "1" ]]; then
    echo $@
  fi
}

if [[ ! -d "$REPOPATH" ]]; then
  git clone --quiet https://token:${TOKEN}@github.com/${USER}/${REPO}.git $REPOPATH
fi

cd $REPOPATH

log "fetching from repo"
git fetch --quiet
log "checking out ${BRANCH}"
git reset --hard --quiet origin/${BRANCH}
COMMIT=$(git log --pretty=format:"%h" -n 1)

IMAGE="${USER}/${REPO}:${COMMIT}"
log "checking if ${IMAGE} exists"
EXISTING=$(docker images -q $IMAGE 2> /dev/null)

if [[ "$EXISTING" == "" ]]; then
  log "building $IMAGE with $DOCKERFILE"
  IMAGE_ID=$(docker build . --quiet -f $DOCKERFILE -t $IMAGE)
  if [[ "$?" != 0 ]]; then
    echo "error building"
    echo $IMAGE_ID
    exit 1
  fi
else
  log "image exists, skipping build"
fi


if [[ "$PUSH" == 1 ]]; then
  if [[ -n "$DOCKERUSER" ]]; then
    DOCKER_IMAGE="${REGISTRY:+ ${REGISTRY}/}${DOCKERUSER}/${REPO}:${COMMIT}"
    log "tagging image $DOCKER_IMAGE"
    docker tag $IMAGE $DOCKER_IMAGE > /dev/null
    IMAGE=$DOCKER_IMAGE
  fi
  log "pushing $IMAGE"
  docker push $IMAGE > /dev/null
  if [[ "$?" != 0 ]]; then
    echo "Push failed"
    exit 1
  fi
fi

log "complete: $IMAGE"
echo $IMAGE

