#!/bin/bash

BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}

check_prerequisite_branch() {
  local branch=$1
  local prerequisite=$2
  local error_code=$3

  PULL=$(gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "/repos/${GITHUB_REPOSITORY}/pulls?head=${GITHUB_REPOSITORY_OWNER}:${prerequisite}" || true)
  OPEN=$(jq '. | length' <<< "$PULL")

  if [[ "$OPEN" != "0" && "$GITHUB_REPOSITORY_OWNER" != "praktikum-java" ]]; then
    PULL_URL=$(jq -r '.[0].html_url' <<< "$PULL")
    echo "❗ Merge the $prerequisite branch pull request: ${PULL_URL}"
    echo "❗ Объедините pull request ветки $prerequisite: ${PULL_URL}"
    exit "$error_code"
  fi

  echo "$prerequisite - Merged"
}

check_target_branch() {
  local expected_branch=$1
  if [[ "$GITHUB_BASE_REF" != "$expected_branch" && "$GITHUB_REPOSITORY_OWNER" != "praktikum-java" ]]; then
    echo "❗ Set the pull request to merge branch '$expected_branch'"
    echo "❗ Задайте в Pull request ветку слияния '$expected_branch' (вместо '$GITHUB_BASE_REF')"
    exit 2
  fi
}

branch_exists() {
  local branch=$1
  gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    "/repos/${GITHUB_REPOSITORY}/branches/${branch}" > /dev/null 2>&1
}

case "$BRANCH_NAME" in
  "1-collector-json")
    echo "✅ Collector json service - OK"
    check_target_branch "main"
    ;;

  "2-collector-grpc")
    echo "✅ Collector grpc service - OK"
    check_prerequisite_branch "2-collector-grpc" "1-collector-json" 3
    check_target_branch "develop"
    ;;

  "3-aggregator")
    echo "✅ Aggregator service - OK"
    check_prerequisite_branch "3-aggregator" "2-collector-grpc" 4
    check_target_branch "develop"
    ;;

  "4-analyzer")
    echo "✅ Analyzer service - OK"
    check_prerequisite_branch "4-analyzer" "3-aggregator" 5
    check_target_branch "develop"
    ;;

  "develop")
    echo "✅ Develop branch - OK"
    # develop собирается дважды: после 4-analyzer (телеметрия)
    # и после ветки микросервисов (7-spring-cloud-microservices или 7-microservices)
    check_prerequisite_branch "develop" "4-analyzer" 6
    for microservices_branch in "7-spring-cloud-microservices" "7-microservices"; do
      if branch_exists "$microservices_branch"; then
        check_prerequisite_branch "develop" "$microservices_branch" 6
      fi
    done
    check_target_branch "main"
    ;;

  "5-config-server")
    echo "Config server - OK"
    check_prerequisite_branch "5-config-server" "4-analyzer" 7
    check_target_branch "develop"
    ;;

  "6-discovery-server")
    echo "✅ Discovery server - OK"
    check_prerequisite_branch "6-discovery-server" "5-config-server" 8
    check_target_branch "develop"
    ;;

  "7-spring-cloud-microservices")
    echo "✅ Cloud microservices - OK"
    check_prerequisite_branch "7-spring-cloud-microservices" "6-discovery-server" 9
    check_target_branch "develop"
    ;;

  "7-microservices")
    echo "✅ Microservices - OK"
    check_prerequisite_branch "7-microservices" "6-discovery-server" 9
    check_target_branch "develop"
    ;;

  "8-gateway")
    echo "✅ API Gateway - OK"
    check_prerequisite_branch "8-gateway" "7-spring-cloud-microservices" 10
    check_target_branch "develop"
    ;;

  "9-gateway-microservices")
    echo "✅ API Gateway microservices - OK"
    check_prerequisite_branch "9-gateway-microservices" "8-gateway" 11
    check_target_branch "main"
    ;;

  "8-open-feign")
    echo "✅ Open feign - OK"
    check_prerequisite_branch "8-open-feign" "7-microservices" 10
    check_target_branch "development"
    ;;

  "9-circuit-breaker")
    echo "✅ Circuit breaker - OK"
    check_prerequisite_branch "9-circuit-breaker" "8-open-feign" 11
    check_target_branch "development"
    ;;

  "11-security")
    echo "✅ API Gateway security - OK"
    check_prerequisite_branch "11-security" "10-gateway-load-balancing" 13
    check_target_branch "main"
    ;;

  *)
    echo "❌ Unknown branch: $BRANCH_NAME"
    exit 14
    ;;
esac

echo "✅ Github target '$GITHUB_BASE_REF' - OK"
exit 0