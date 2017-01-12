# docker-builder
Build a docker image from a github repo

# Usage

```sh
docker run \
  --rm \
  -e USER=[github user] \
  -e REPO=[github repo] \
  -e TOKEN=[github token - optional] \
  -v /var/run/docker.sock:/var/run/docker.sock \
  firstandthird/builder
```

## Caching repos

You can pass in `-v /path/to/repos:/repos` so you can save some time cloning the repo every time
