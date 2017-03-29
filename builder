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

log() {
  if [[ "$DEBUG" == "1" ]]; then
    echo $@
  fi
}

if [[ -n "$DOCKER_AUTH" ]]; then
  mkdir -p /root/.docker
  CONFIG_FILE=/root/.docker/config.json
  log "Using DOCKER_AUTH"
  cat > $CONFIG_FILE <<- EOM
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "$DOCKER_AUTH"
    }
  }
}
EOM
fi

if [[ -z "$PUSH" ]]; then
  if [[ -d "/root/.docker" || -n "$REGISTRY" ]]; then
    PUSH=1
  else
    PUSH=0
  fi
fi

REPOPATH="${REPOS}/${USER}_${REPO}"

if [[ ! -d "$REPOPATH" ]]; then
  git clone --quiet https://token:${TOKEN}@github.com/${USER}/${REPO}.git $REPOPATH
fi

cd $REPOPATH

log "fetching from repo"
git fetch --quiet
log "checking out ${BRANCH}"
git reset --hard --quiet origin/${BRANCH}
if [[ -z "$TAG" ]]; then
  TAG=$(git log --pretty=format:"%h" -n 1)
fi

IMAGE="${REPO}"
log "checking if ${IMAGE}:$TAG exists"
EXISTING=$(docker images -q $IMAGE:$TAG 2> /dev/null)

if [[ "$EXISTING" == "" ]]; then
  log "building $IMAGE:$TAG with $DOCKERFILE"
  IMAGE_ID=$(docker build --quiet -f $DOCKERFILE -t $IMAGE:$TAG .)
  if [[ "$?" != 0 ]]; then
    echo "error building"
    echo $IMAGE_ID
    exit 1
  fi
else
  log "image exists, skipping build"
fi

if [[ "$PUSH" == 1 ]]; then
  if [[ -n "$REGISTRY" ]]; then
    log "using registry: $REGISTRY"
    REGISTRY_IMAGE="${REGISTRY}/${IMAGE}"
  fi

  log "tagging image $REGISTRY_IMAGE:$TAG"
  docker tag $IMAGE:$TAG $REGISTRY_IMAGE:$TAG > /dev/null

  log "pushing $REGISTRY_IMAGE:$TAG"
  docker push $REGISTRY_IMAGE:$TAG > /dev/null

  if [[ "$?" != 0 ]]; then
    echo "Push failed"
    exit 1
  fi
  if [[ -n "$PUSH_LATEST" ]]; then
    log "tagging image $REGISTRY_IMAGE:latest"
    docker tag $IMAGE:$TAG $REGISTRY_IMAGE:latest > /dev/null

    log "pushing $REGISTRY_IMAGE:latest"
    docker push $REGISTRY_IMAGE:latest > /dev/null
    if [[ "$?" != 0 ]]; then
      echo "Push failed"
      exit 1
    fi
  fi
  IMAGE=$REGISTRY_IMAGE
fi

log "complete: $IMAGE"
echo $IMAGE:$TAG

