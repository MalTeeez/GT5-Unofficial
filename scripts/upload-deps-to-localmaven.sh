#!/bin/bash
set -ex

JSON_FILE=$1
GRADLE_DIR=~/.gradle
INIT_GRADLE=$GRADLE_DIR/init.gradle

# Exit early if there are no dependencies
DEP_COUNT=$(jq '.dependencies | length' "$JSON_FILE")
if [ "$DEP_COUNT" -eq 0 ]; then
    echo "No dependencies found, failure was probably not due to a required dependency. Failing to propagate initial failure."
    exit 1
fi

# Write init.gradle header to user gradle dir
mkdir -p $GRADLE_DIR
cat > $INIT_GRADLE << 'EOF'
allprojects {
    repositories {
        mavenLocal()
    }
    configurations.all {
        resolutionStrategy.eachDependency { details ->
EOF

# Process each dependency
jq -c '.dependencies[]' $JSON_FILE | while read -r dep; do
    JAR_PATH=$(echo $dep | jq -r '.jar_path')
    REPO_URL=$(echo $dep | jq -r '.repo_url')
    COMMIT_SHA=$(echo $dep | jq -r '.commit_sha')

    WORK_DIR=$(mktemp -d)
    echo "Processing $REPO_URL @ $COMMIT_SHA"

    # Shallow clone and checkout
    git clone --depth 1 $REPO_URL $WORK_DIR
    git -C $WORK_DIR fetch --depth 1 origin $COMMIT_SHA
    git -C $WORK_DIR checkout $COMMIT_SHA

    # Get coordinates
    ./gradlew :properties
    PROPS=$(cd $WORK_DIR && ./gradlew -q :properties 2>/dev/null)
    GROUP=$(echo "$PROPS" | grep '^group:' | awk '{print $2}')
    ARTIFACT=$(echo "$PROPS" | grep '^archivesBaseName:' | awk '{print $2}')
    [ -z "$ARTIFACT" ] && ARTIFACT=$(echo "$PROPS" | grep '^name:' | awk '{print $2}')
    VERSION=$(echo "$PROPS" | grep '^version:' | awk '{print $2}')

    echo "Coordinates: $GROUP:$ARTIFACT:$VERSION"

    # Install jar into mavenLocal
    MAVEN_PATH="${GROUP//.//}/$ARTIFACT/$VERSION"
    mkdir -p ~/.m2/repository/$MAVEN_PATH
    cp $JAR_PATH ~/.m2/repository/$MAVEN_PATH/$ARTIFACT-$VERSION-dev.jar

    # Write minimal POM so Gradle can find it
    cat > ~/.m2/repository/$MAVEN_PATH/$ARTIFACT-$VERSION.pom << POMEOF
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <groupId>$GROUP</groupId>
  <artifactId>$ARTIFACT</artifactId>
  <version>$VERSION</version>
</project>
POMEOF

    # Append override to init.gradle
    cat >> $INIT_GRADLE << EOF
            if (details.requested.module.toString() == '${GROUP}:${ARTIFACT}') {
                details.useVersion '${VERSION}'
                details.because 'PR dependency override'
            }
EOF

    rm -rf $WORK_DIR
done

# Close init.gradle
cat >> $INIT_GRADLE << 'EOF'
        }
    }
}
EOF