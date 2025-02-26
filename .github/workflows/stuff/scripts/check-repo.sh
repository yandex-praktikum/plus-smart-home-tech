#!/bin/bash

REPO=$(gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "/repos/${GITHUB_REPOSITORY}")
FORK=$(jq -r '.fork' <<< "$REPO")
PRIVATE=$(jq -r '.private' <<< "$REPO")

echo "FORK='$FORK', PRIVATE='$PRIVATE', GITHUB_REPOSITORY_OWNER=${GITHUB_REPOSITORY_OWNER}"

if [[ "$FORK" == "true" ]]; then
  echo "Use the repository automatically created by Yandex Practicum (works in fork repositories are not accepted)"
  echo "Используйте только репозиторий созданный Yandex Practicum, работы в форк репозитории не принимаются"
  exit 1
fi

if [[ "$GITHUB_REPOSITORY_OWNER" == "yandex-praktikum" ]]; then
  echo "Use the repository automatically created by Yandex Practicum (works in fork repositories are not accepted)"
  echo "Используйте только репозиторий созданный Yandex Practicum, работы в форк репозитории не принимаются"
  exit 2
fi

if [[ "$PRIVATE" == "true" && "$GITHUB_REPOSITORY_OWNER" != "praktikum-java" ]]; then
  echo "Share your repository, make it public"
  echo "Откройте доступ к вашему репозиторию, сделайте его публичным"
  exit 3
fi