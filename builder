#!/bin/bash

SECONDS=0
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
    echo "$@"
  fi
}

if [[ -n "$DOCKER_AUTH" ]]; then
  mkdir -p $HOME/.docker
  CONFIG_FILE=$HOME/.docker/config.json
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

if [[ -d "$HOME/.docker" || -n "$REGISTRY" ]]; then
  PUSH=1
else
  PUSH=0
fi

REPOPATH="${REPOS}/${USER}_${REPO}"

if [[ ! -d "$REPOPATH" ]]; then
  git clone --quiet https://token:${TOKEN}@github.com/${USER}/${REPO}.git $REPOPATH
  if [[ "$?" != 0 ]]; then
    echo "failed to clone"
    exit 1
  fi
fi

cd $REPOPATH

attempts=0
maxattemps=10
lockfile=build.lock
while [ -f "$lockfile" ]; do
  log "Lock file exists, waiting for previous build to finish"
  sleep 10
  attempts=$(($attempts+1))
  if [[ "$maxattempts" == "$attempts" ]]; then
    echo "Reached max attemps, exiting"
    exit 1
  fi
done
touch $lockfile

log "fetching from repo"
git fetch --quiet
log "checking out ${BRANCH}"
git reset --hard --quiet origin/${BRANCH} > /dev/null 2>&1
if [[ "$?" != 0 ]]; then
  #maybe it's a tag
  git reset --hard --quiet ${BRANCH}
fi
if [[ "$?" != 0 ]]; then
  echo "error checking out $BRANCH"
  rm $lockfile
  exit 1
fi
git submodule foreach "git reset --hard"
git submodule update --init --recursive
COMMIT=$(git log --pretty=format:"%h" -n 1)

if [[ -z "$IMAGE_NAME" ]]; then
  IMAGE_NAME="${REPO}_${BRANCH}:${COMMIT}"
fi

if [[ -n "$CONTEXT" ]]; then
  log "switching to $CONTEXT to build"
  cd "$CONTEXT"
fi

log "building $IMAGE_NAME with $DOCKERFILE"
if [[ -f "pre-build.sh" ]]; then
  RES=$(. "pre-build.sh")
  if [[ "$?" != 0 ]]; then
    echo $RES
    rm $lockfile
    echo "error running pre-build"
    exit 1
  fi
fi
IMAGE_ID=$(docker build --quiet -f $DOCKERFILE -t $IMAGE_NAME .)
if [[ "$?" != 0 ]]; then
  rm $lockfile
  echo "error building $IMAGE_NAME"
  echo $IMAGE_ID
  exit 1
fi

rm $lockfile


if [[ "$PUSH" == 1 ]]; then

  log "pushing $IMAGE_NAME"
  docker push $IMAGE_NAME > /dev/null

  if [[ "$?" != 0 ]]; then
    echo "Push failed"
    exit 1
  fi
fi

if [[ "$CLEAN" == 1 ]]; then
  log "Cleaning older images"
  docker rmi $(docker images | grep "${IMAGE} " | tail -n +3 | awk '{ print $3 }') > /dev/null 2>&1
fi

log "complete: $IMAGE_NAME"
DURATION=$SECONDS
log "finished in $SECONDS seconds"
echo $IMAGE_NAME

