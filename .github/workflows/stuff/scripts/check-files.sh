#!/bin/bash

PULL=$(gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${GITHUB_REPOSITORY}/pulls/${PULL_NUMBER}/files?per_page=100" || true)

FILENAMES=$(jq -r '.[].filename' <<< "$PULL")

declare -A FORBIDDEN_FILES=(
  "api-tests.yml",
  "checkstyle.xml",
  "hub-router.jar"
)

for FILE in "${FORBIDDEN_FILES[@]}"; do
  if grep -q "$FILE" <<< "$FILENAMES"; then
    echo "The pull request contains the $FILE file and cannot be modified. Remove it from PR"
    echo "Pull request содержит файл $FILE, его изменять нельзя. Удалите его из PR"
    exit 1
  fi
done

# Проверка на запрещенные файлы и директории
if grep -E -q "(\.class|\.jar|mvn|\.DS_Store|\.idea|\.iws|\.iml|\.ipr|\.db|\.log|out/|target/)" <<< "$FILENAMES"; then
  echo "The pull request contains binary files. Remove them (*.class, *.jar, *.DS_Store ...) from PR"
  echo "Pull request содержит двоичные файлы. Удалите их (*.class, *.jar, *.DS_Store ...) из PR"
  exit 1
fi

echo "PR files - OK"
exit 0