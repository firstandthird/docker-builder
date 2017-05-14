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
    echo $@
  fi
}

slack() {
  if [[ -n "$SLACK_HOOK" ]]; then
    local message=$1
    local color="${2:-good}"
    local username="${SLACK_NAME:-docker-builder}"
    local emoji="${SLACK_EMOJI:-:floppy_disk:}"
    local channel=$SLACK_CHANNEL
    curl --fail --silent --show-error -X POST \
      --data-urlencode "payload={\"attachments\": [{ \"title\": \"$message\",\"color\":\"$color\" }], \"username\": \"$username\", \"channel\":\"$channel\",\"icon_emoji\": \"$emoji\"}" \
      $SLACK_HOOK > /dev/null
    if [[ "$?" != 0 ]]; then
      log "!Error sending to slack"
    fi

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

attempts=0
maxattemps=10
lockfile=build.lock
while [ -f "$lockfile" ]; do
  log "Lock file exists, waiting for previous build to finish"
  sleep 10
  attempts=$(($attempts+1))
  if [[ "$maxattempts" == "$attempts" ]]; then
    log "Reached max attemps, exiting"
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
if [[ -z "$TAG" ]]; then
  TAG=$COMMIT
fi
if [[ "$TAG_PREFIX_BRANCH" == 1 ]]; then
  TAG=${BRANCH}_${TAG}
fi

IMAGE="${REPO}"

if [[ -n "$REGISTRY" ]]; then
  log "using registry: $REGISTRY"
  IMAGE="${REGISTRY}/${IMAGE}"
fi

log "checking if ${IMAGE}:$TAG exists"
EXISTING=$(docker images -q $IMAGE:$TAG 2> /dev/null)

if [[ "$EXISTING" == "" ]]; then
  log "building $IMAGE:$TAG with $DOCKERFILE"
  if [[ -f "pre-build.sh" ]]; then
    RES=$(. "pre-build.sh")
    if [[ "$?" != 0 ]]; then
      echo $RES
      echo "error running pre-build"
      slack "error running pre-build $IMAGE:TAG" "danger"
      exit 1
    fi
  fi
  IMAGE_ID=$(docker build --quiet -f $DOCKERFILE -t $IMAGE:$TAG .)
  if [[ "$?" != 0 ]]; then
    rm $lockfile
    echo "error building"
    slack "error building $IMAGE:$TAG" "danger"
    echo $IMAGE_ID
    exit 1
  fi
else
  log "image exists, skipping build"
fi

rm $lockfile

push() {
  local from=$1
  local to=$2
  if [[ -n "$to" ]]; then
    log "tagging image $to"
    docker tag $from $to > /dev/null
  else
    to=$from
  fi

  log "pushing $to"
  docker push $to > /dev/null

  if [[ "$?" != 0 ]]; then
    echo "Push failed"
    slack "error pushing $to" "danger"
    exit 1
  fi
}

push_tags() {
  local img=$1
  local tag=$2

  if [[ "$TAG_LATEST" == 1 ]]; then
    push $img:$tag $img:latest
  fi

  if [[ "$TAG_BRANCH" == 1 ]]; then 
    if [[ "$TAG_BRANCH_PREVIOUS" == 1 ]]; then
      log "Tagging previous branch as $img:${BRANCH}_previous"
      docker pull $img:$BRANCH > /dev/null
      if [[ "$?" == 0 ]]; then
        docker tag $img:$BRANCH $img:${BRANCH}_previous > /dev/null
        docker push $img:${BRANCH}_previous > /dev/null
      fi
    fi
    push $img:$tag $img:$BRANCH
  fi
}

if [[ "$PUSH" == 1 ]]; then

  if [[ "$SKIP_PUSH_COMMIT" != 1 ]]; then
    push $IMAGE:$TAG
  else
    log "Skipping commit tag"
  fi
  push_tags $IMAGE $TAG

fi

if [[ "$CLEAN" == 1 ]]; then
  log "Cleaning older images"
  docker rmi $(docker images | grep "${IMAGE} " | tail -n +3 | awk '{ print $3 }') > /dev/null 2>&1
fi

if [[ -n "$WEBHOOK" ]]; then
  for hook in $WEBHOOK; do
    log "triggering hook: $hook"
    curl \
      --fail --silent --show-error \
     -H "Content-Type: application/json" \
     -X POST \
     -d "{\"repo\":\"$REPO\",\"user\":\"$USER\",\"branch\":\"$BRANCH\",\"commit\": \"$COMMIT\",\"dockerImage\":\"$IMAGE:$TAG\"}" \
     "$hook" > /dev/null

    if [[ "$?" != 0 ]]; then
      slack "Hook errored: $hook" "danger"
      log "!Hook errored"
    fi
  done
fi

log "complete: $IMAGE"
DURATION=$SECONDS
log "finished in $SECONDS seconds"
slack "$IMAGE:$TAG built in $SECONDS seconds"
echo $IMAGE:$TAG

