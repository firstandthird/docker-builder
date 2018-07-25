#!/bin/bash

BUILDER=$0

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

if [[ -n "$DOCKER_REGISTRY" ]]; then
  RAW_REGISTRY=$DOCKER_REGISTRY
  DOCKER_REGISTRY="${DOCKER_REGISTRY}/"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="master"
fi

if [[ -z "$DOCKERFILE" ]]; then
  DOCKERFILE=Dockerfile
fi

if [[ -z "$BUILD_ARGS" ]]; then
  BUILD_ARGS=""
fi

if [[ -n "$CPU_SHARES" ]]; then
  BUILD_ARGS="${BUILD_ARGS} --cpu-shares $CPU_SHARES"
fi

if [[ -n "$MEM_LIMIT" ]]; then
  BUILD_ARGS="${BUILD_ARGS} --memory $MEM_LIMIT"
fi

log() {
  if [[ "$DEBUG" == "1" ]]; then
    echo -e "  \e[33m$@\e[39m"
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

if [[ -d "$HOME/.docker" && -n "$DOCKER_REGISTRY" ]]; then
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
COMMIT=$(git log --pretty=format:"%h" -n 1)

if [[ "$MONOREPO" == "true" ]]; then
  log "Building as monorepo...."
  log "pre-fetching from repo branch ${BRANCH}"
  git fetch --quiet

  git reset --hard --quiet origin/${BRANCH} > /dev/null 2>&1
  if [[ "$?" != 0 ]]; then
    #maybe it's a tag
    git reset --hard --quiet ${BRANCH}
  fi
  if [[ "$?" != 0 ]]; then
    echo "error checking out $BRANCH"
    exit 1
  fi

  log ""
  MONOREPO=
  REPODIR="${REPOPATH}/*"
  
  for FILENAME in $REPODIR; do
    if [[ -d "${FILENAME}" ]]; then
      if [[ -f "${FILENAME}/${DOCKERFILE}" ]]; then
        FOLDER="${FILENAME/$REPOPATH\//}"
        log "Building folder ${FILENAME}";
        (DOCKER_REGISTRY=${RAW_REGISTRY} DOCKERFILE="${FILENAME}/${DOCKERFILE}" CONTEXT=${FILENAME} TAG_PREFIX=${FOLDER} $BUILDER)
        if [[ "$?" != 0 ]]; then
          log "There was an error building $IMAGE_NM"
          exit 1
        fi
        log ""
      fi
    fi
  done

  if [[ -n "$WEBHOOK_MONOREPO" ]]; then
    for hook in $WEBHOOK_MONOREPO; do
      log "triggering monorepo hook: $hook"
      curl \
        --fail --silent --show-error \
       -X POST \
       -d "repo=$REPO&user=$USER&branch=$BRANCH&commit=$COMMIT&monorepo=true&$WEBHOOK_DATA" \
       "$hook" > /dev/null

      if [[ "$?" != 0 ]]; then
        log "!Hook errored"
      fi
    done
  fi
  exit 0
fi

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

log "fetching from repo branch ${BRANCH}"
git fetch --quiet

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

if [[ -n "$TAG_PREFIX" ]]; then
  TAG_PREFIX="${TAG_PREFIX}_"
fi

if [[ -z "$IMAGE_NAME" ]]; then
  IMAGE_NAME="${DOCKER_REGISTRY}${REPO}:${TAG_PREFIX}${BRANCH}"
fi

if [[ -z "$CONTEXT" ]]; then
  CONTEXT='.'
fi

#do we even need to build
if [[ -n "$BEFORE" ]]; then
  DIFF=$(git diff --name-only ${BEFORE} ${COMMIT} ${CONTEXT})

  if [[ -z "$DIFF" && "$(docker images -q $IMAGE_NAME 2> /dev/null)" != "" ]]; then
    #check if image exists, if it doesn't exist in registry, we should still build
    echo "No difference in context and image exists"
    rm $lockfile
    exit 0
  fi
fi

log "building $IMAGE_NAME with $DOCKERFILE using args $BUILD_ARGS"
PREBUILD_FILE="${CONTEXT}/pre-build.sh"
if [[ -f $PREBUILD_FILE ]]; then
  log "running pre-build"
  RES=$(. $PREBUILD_FILE)
  if [[ "$?" != 0 ]]; then
    echo $RES
    rm $lockfile
    echo "error running pre-build"
    exit 1
  fi
fi
if [[ "$DEBUG" == "1" ]]; then
  docker build -f $DOCKERFILE -t $IMAGE_NAME --build-arg GIT_COMMIT=$(git log -1 --format=%h) --build-arg GIT_BRANCH=$BRANCH $BUILD_ARGS $CONTEXT
else
  IMAGE_ID=$(docker build --quiet -f $DOCKERFILE -t $IMAGE_NAME --build-arg GIT_COMMIT=$(git log -1 --format=%h) --build-arg GIT_BRANCH=$BRANCH $BUILD_ARGS $CONTEXT)
fi
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

if [[ -n "$POST_HOOK" ]]; then
  log "running post hook: $POST_HOOK"
  . $POST_HOOK $IMAGE_NAME
fi

if [[ -n "$WEBHOOK" ]]; then
  for hook in $WEBHOOK; do
    log "triggering hook: $hook"
    curl \
      --fail --silent --show-error \
     -X POST \
     -d "repo=$REPO&user=$USER&branch=$BRANCH&commit=$COMMIT&image=$IMAGE_NAME&$WEBHOOK_DATA" \
     "$hook" > /dev/null

    if [[ "$?" != 0 ]]; then
      log "!Hook errored"
    fi
  done
fi

log "complete: $IMAGE_NAME"
DURATION=$SECONDS
log "finished in $SECONDS seconds"
echo $IMAGE_NAME

